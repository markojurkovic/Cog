//
//  OutputCoreAudio.m
//  Cog
//
//  Created by Christopher Snowhill on 7/25/23.
//  Copyright 2023-2024 Christopher Snowhill. All rights reserved.
//

#import "OutputCoreAudio.h"
#import "AudioChunk.h"
#import "OutputNode.h"

#ifdef _DEBUG
#import "BadSampleCleaner.h"
#endif

#import "Logging.h"

#import <Accelerate/Accelerate.h>
#import <limits.h>
#import <unistd.h>

#import <CogAudio/VisualizationController.h>

#ifdef OUTPUT_LOG
#import <NSFileHandle+CreateFile.h>
#endif

static NSNotificationName CogPlaybackDidPrebufferNotification = @"CogPlaybackDidPrebufferNotification";

extern void scale_by_volume_double(double *buffer, size_t count, double volume);

static NSNotificationName CogPlaybackDidBeginNotificiation = @"CogPlaybackDidBeginNotificiation";

NSNotificationName const CogCoreAudioOutputFormatDidChangeNotification = @"CogCoreAudioOutputFormatDidChangeNotification";
NSString *const CogCoreAudioOutputFormatDescriptionKey = @"CogCoreAudioOutputFormatDescription";
NSString *const CogCoreAudioOutputStatusFormatDescriptionKey = @"CogCoreAudioOutputStatusFormatDescription";
NSString *const CogCoreAudioSourceFormatDescriptionKey = @"CogCoreAudioSourceFormatDescription";
NSString *const CogCoreAudioVirtualFormatDescriptionKey = @"CogCoreAudioVirtualFormatDescription";
NSString *const CogCoreAudioDeviceFormatDescriptionKey = @"CogCoreAudioDeviceFormatDescription";
NSString *const CogCoreAudioEndToEndIntegerTransportKey = @"CogCoreAudioEndToEndIntegerTransport";
NSString *const CogCoreAudioExclusiveTransportKey = @"CogCoreAudioExclusiveTransport";
NSString *const CogCoreAudioHogModeOwnedKey = @"CogCoreAudioHogModeOwned";
NSString *const CogCoreAudioSignalIntegrityLosslessKey = @"CogCoreAudioSignalIntegrityLossless";
NSString *const CogCoreAudioSignalIntegrityDetailsKey = @"CogCoreAudioSignalIntegrityDetails";

static BOOL playbackFadesEnabled(void) {
	NSNumber *enabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"enableFading"];
	return !enabled || [enabled boolValue];
}

static NSArray<NSString *> *signalIntegrityPreferenceKeyPaths(void) {
	static NSArray<NSString *> *keyPaths;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		keyPaths = @[
			@"values.volumeScaling",
			@"values.enableFading",
			@"values.enableHDCD",
			@"values.GraphicEQenable",
			@"values.enableHrtf",
			@"values.enableFSurround",
			@"values.pitch",
			@"values.tempo",
			@"values.rubberbandEngine",
		];
	});
	return keyPaths;
}

static BOOL pcmRepresentationPreservesSamples(AudioStreamBasicDescription source,
                                               AudioStreamBasicDescription destination) {
	if(source.mFormatID != kAudioFormatLinearPCM ||
	   destination.mFormatID != kAudioFormatLinearPCM ||
	   !source.mBitsPerChannel || !destination.mBitsPerChannel) {
		return NO;
	}

	const BOOL sourceIsFloat = !!(source.mFormatFlags & kAudioFormatFlagIsFloat);
	const BOOL destinationIsFloat = !!(destination.mFormatFlags & kAudioFormatFlagIsFloat);
	if(sourceIsFloat) {
		// Arbitrary floating-point samples are not generally integer-grid values.
		return destinationIsFloat && destination.mBitsPerChannel >= source.mBitsPerChannel;
	}

	if(destinationIsFloat) {
		const UInt32 significandBits = destination.mBitsPerChannel == 32 ? 24 :
		                               destination.mBitsPerChannel == 64 ? 53 : 0;
		return significandBits >= source.mBitsPerChannel;
	}

	return destination.mBitsPerChannel >= source.mBitsPerChannel;
}

static BOOL channelMappingPreservesSamples(AudioStreamBasicDescription source,
                                           uint32_t sourceConfig,
                                           AudioStreamBasicDescription destination,
                                           uint32_t destinationConfig) {
	if(source.mChannelsPerFrame != destination.mChannelsPerFrame) {
		return NO;
	}

	// Decoder metadata may omit a channel mask even though AudioChunk assigns
	// the conventional layout from the channel count before playback. Compare
	// the effective layouts used by the audio chain, not the raw missing mask.
	if(!sourceConfig) {
		sourceConfig = [AudioChunk guessChannelConfig:source.mChannelsPerFrame];
	}
	if(!destinationConfig) {
		destinationConfig = [AudioChunk guessChannelConfig:destination.mChannelsPerFrame];
	}

	return sourceConfig == destinationConfig ||
	       (source.mChannelsPerFrame == 2 &&
	        sourceConfig == (AudioChannelSideLeft | AudioChannelSideRight) &&
	        destinationConfig == AudioConfigStereo);
}

static NSString *outputSampleRateDescription(double sampleRate) {
	if(sampleRate >= 1000.0) {
		const double sampleRateKHz = sampleRate / 1000.0;
		if(fabs(sampleRateKHz - round(sampleRateKHz)) < 0.0001) {
			return [NSString stringWithFormat:@"%.0f kHz", sampleRateKHz];
		}
		return [NSString stringWithFormat:@"%.1f kHz", sampleRateKHz];
	}
	return [NSString stringWithFormat:@"%.0f Hz", sampleRate];
}

static NSString *outputFormatDescriptionWithName(AudioStreamBasicDescription format, NSString *formatName) {
	const BOOL nonInterleaved = !!(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
	const UInt32 bytesPerSample = nonInterleaved ? format.mBytesPerFrame :
	                                              (format.mChannelsPerFrame ? format.mBytesPerFrame / format.mChannelsPerFrame : 0);
	const UInt32 containerBits = bytesPerSample * 8;
	NSString *bitDepthDescription;
	if(containerBits > format.mBitsPerChannel) {
		bitDepthDescription = [NSString stringWithFormat:@"%u-bit (%u-bit container)",
		                                                      (unsigned int)format.mBitsPerChannel,
		                                                      (unsigned int)containerBits];
	} else {
		bitDepthDescription = [NSString stringWithFormat:@"%u-bit", (unsigned int)format.mBitsPerChannel];
	}

	NSString *description = [NSString stringWithFormat:@"%@ · %@ · %@",
	                                                        formatName,
	                                                        outputSampleRateDescription(format.mSampleRate),
	                                                        bitDepthDescription];
	if(format.mFormatFlags & kAudioFormatFlagIsNonMixable) {
		description = [description stringByAppendingString:NSLocalizedString(@" · Non-mixable", @"Non-mixable Core Audio stream format")];
	}
	return description;
}

static NSString *outputFormatDescription(AudioStreamBasicDescription format, BOOL isDoP) {
	NSString *formatName;
	if(isDoP) {
		formatName = @"DoP";
	} else if(format.mFormatID == kAudioFormatLinearPCM) {
		if(format.mFormatFlags & kAudioFormatFlagIsFloat) {
			formatName = [NSString stringWithFormat:@"Float%u PCM", (unsigned int)format.mBitsPerChannel];
		} else if(format.mFormatFlags & kAudioFormatFlagIsSignedInteger) {
			formatName = [NSString stringWithFormat:@"Int%u PCM", (unsigned int)format.mBitsPerChannel];
		} else {
			formatName = [NSString stringWithFormat:@"UInt%u PCM", (unsigned int)format.mBitsPerChannel];
		}
	} else {
		formatName = @"Core Audio";
	}
	return outputFormatDescriptionWithName(format, formatName);
}

static NSString *outputStatusFormatDescription(AudioStreamBasicDescription format, BOOL isDoP) {
	NSString *formatName;
	if(isDoP) {
		formatName = @"DoP";
	} else if(format.mFormatID == kAudioFormatLinearPCM) {
		if(format.mFormatFlags & kAudioFormatFlagIsFloat) {
			formatName = [NSString stringWithFormat:@"Float%u", (unsigned int)format.mBitsPerChannel];
		} else if(format.mFormatFlags & kAudioFormatFlagIsSignedInteger) {
			formatName = [NSString stringWithFormat:@"Int%u", (unsigned int)format.mBitsPerChannel];
		} else {
			formatName = [NSString stringWithFormat:@"UInt%u", (unsigned int)format.mBitsPerChannel];
		}
	} else {
		formatName = @"Core Audio";
	}
	NSString *description = [NSString stringWithFormat:@"%@ · %@",
	                                                        formatName,
	                                                        outputSampleRateDescription(format.mSampleRate)];
	if(format.mFormatFlags & kAudioFormatFlagIsNonMixable) {
		description = [description stringByAppendingString:NSLocalizedString(@" · Non-mixable", @"Non-mixable Core Audio stream format")];
	}
	return description;
}

static NSString *sourceFormatDescription(AudioStreamBasicDescription format) {
	if(format.mBitsPerChannel != 1) {
		return outputFormatDescription(format, NO);
	}
	return [NSString stringWithFormat:@"DSD · %@ · 1-bit",
	                                  outputSampleRateDescription(format.mSampleRate)];
}

static NSString *streamOutputFormatDescription(AudioDeviceID deviceID,
                                                AudioObjectPropertySelector formatSelector) {
	if(deviceID == kAudioObjectUnknown || deviceID == (AudioDeviceID)-1) {
		return nil;
	}

	AudioObjectPropertyAddress streamsAddress = {
		.mSelector = kAudioDevicePropertyStreams,
		.mScope = kAudioDevicePropertyScopeOutput,
		.mElement = kAudioObjectPropertyElementMaster
	};
	UInt32 streamsSize = 0;
	OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, NULL, &streamsSize);
	if(status != noErr || streamsSize < sizeof(AudioStreamID)) {
		return nil;
	}

	AudioStreamID *streams = (AudioStreamID *)malloc(streamsSize);
	if(!streams) {
		return nil;
	}
	status = AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, NULL, &streamsSize, streams);
	if(status != noErr) {
		free(streams);
		return nil;
	}

	NSMutableOrderedSet<NSString *> *descriptions = [NSMutableOrderedSet orderedSet];
	const UInt32 streamCount = streamsSize / (UInt32)sizeof(AudioStreamID);
	AudioObjectPropertyAddress formatAddress = {
		.mSelector = formatSelector,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	for(UInt32 i = 0; i < streamCount; ++i) {
		AudioStreamBasicDescription format = { 0 };
		UInt32 formatSize = sizeof(format);
		status = AudioObjectGetPropertyData(streams[i], &formatAddress, 0, NULL, &formatSize, &format);
		if(status == noErr && formatSize == sizeof(format) && format.mFormatID) {
			[descriptions addObject:outputFormatDescription(format, NO)];
		}
	}
	free(streams);

	return descriptions.count ? [[descriptions array] componentsJoinedByString:@" / "] : nil;
}

static NSString *physicalOutputFormatDescription(AudioDeviceID deviceID) {
	return streamOutputFormatDescription(deviceID, kAudioStreamPropertyPhysicalFormat);
}

static NSString *virtualOutputFormatDescription(AudioDeviceID deviceID) {
	return streamOutputFormatDescription(deviceID, kAudioStreamPropertyVirtualFormat);
}

@interface OutputCoreAudio ()
- (double)currentDeviceSampleRate;
- (BOOL)ensureMixableStreamFormatsForAUHAL;
- (BOOL)ensureAUHALBoundToOutputDevice;
- (BOOL)createExclusiveIOProc;
- (void)destroyExclusiveIOProc;
- (void)setDeviceVolumeTo100ForExclusiveOutputIfSupported;
- (BOOL)startCurrentHardware:(NSError **)error;
- (void)stopCurrentHardware;
- (BOOL)currentOutputUsesExclusiveTransport;
- (BOOL)currentOutputIsEndToEndInteger;
- (BOOL)currentProcessOwnsHogMode;
- (void)configurePreferredFloatOutputForConvertedDSDInputFormat:(AudioStreamBasicDescription)inputFormat
	                                                sampleRate:(double)sampleRate;
- (BOOL)prepareForInputFormatLocked:(AudioStreamBasicDescription)inputFormat;
@end

@implementation OutputCoreAudio {
	VisualizationController *visController;
	BOOL streamReplacementPending;
	BOOL outputDeviceIDChanged;
}

static void *kOutputCoreAudioContext = &kOutputCoreAudioContext;

- (AudioChunk *)renderInput:(int)amountToRead {
	if(stopping == YES || [outputController shouldContinue] == NO) {
		// Chain is dead, fill out the serial number pointer forever with silence
		stopping = YES;
		return [AudioChunk new];
	}

	AudioStreamBasicDescription format;
	uint32_t config;
	if([outputController peekFormat:&format channelConfig:&config]) {
		if(!streamFormatStarted || config != realStreamChannelConfig || memcmp(&realStreamFormat, &format, sizeof(format)) != 0) {
			realStreamFormat = format;
			realStreamChannelConfig = config;
			streamFormatStarted = YES;
			streamFormatChanged = YES;
		}
	}

	if(streamFormatChanged) {
		return [AudioChunk new];
	}

	return [outputController readChunk:amountToRead];
}

- (id)initWithController:(OutputNode *)c {
	self = [super init];
	if(self) {
		buffer = [[ChunkList alloc] initWithMaximumDuration:2.0f * (fadeTimeMS / 1000.0f)];
		writeSemaphore = [Semaphore new];
		readSemaphore = [Semaphore new];

		outputController = c;
		volume = 1.0;
		outputDeviceID = -1;
		sampleRateSupportCache = [NSMutableDictionary new];
		streamReplacementPending = NO;

		secondsHdcdSustained = 0;

		outputLock = [NSLock new];

#ifdef OUTPUT_LOG
		NSString *logName = [NSTemporaryDirectory() stringByAppendingPathComponent:@"CogAudioLog.raw"];
		_logFile = [NSFileHandle fileHandleForWritingAtPath:logName createFile:YES];
#endif
	}

	return self;
}

- (NSDictionary *)signalIntegrityInfo {
	if(!sourceFormatValid) {
		return @{
			CogCoreAudioSignalIntegrityDetailsKey: NSLocalizedString(@"Source sample information is not available.", @"Unknown Cog signal-integrity details")
		};
	}

	NSMutableArray<NSString *> *reasons = [NSMutableArray array];
	const BOOL sourceIsDSD = sourceFormat.mBitsPerChannel == 1;
	if(sourceIsDSD) {
		if(!renderFormatDoPInteger) {
			[reasons addObject:NSLocalizedString(@"DSD-to-PCM conversion", @"Cog signal-integrity modification reason")];
		}
		if(sourceFormat.mChannelsPerFrame != renderFormat.mChannelsPerFrame) {
			[reasons addObject:NSLocalizedString(@"channel conversion", @"Cog signal-integrity modification reason")];
		}
	} else {
		if(fabs(sourceFormat.mSampleRate - renderFormat.mSampleRate) >= 0.5) {
			[reasons addObject:[NSString stringWithFormat:NSLocalizedString(@"resampling from %@ to %@", @"Cog signal-integrity resampling reason"),
			                                                    outputSampleRateDescription(sourceFormat.mSampleRate),
			                                                    outputSampleRateDescription(renderFormat.mSampleRate)]];
		}
		if(!channelMappingPreservesSamples(sourceFormat,
		                                  sourceChannelConfig,
		                                  renderFormat,
		                                  deviceChannelConfig)) {
			[reasons addObject:NSLocalizedString(@"channel-layout conversion", @"Cog signal-integrity modification reason")];
		}
		if(!pcmRepresentationPreservesSamples(sourceFormat, renderFormat)) {
			[reasons addObject:NSLocalizedString(@"sample-format precision reduction", @"Cog signal-integrity modification reason")];
		}

		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		if([outputController currentConverterAppliesVolumeScaling]) {
			[reasons addObject:NSLocalizedString(@"ReplayGain or tagged volume scaling", @"Cog signal-integrity modification reason")];
		}
		if(volume != 1.0f) {
			[reasons addObject:NSLocalizedString(@"Cog volume is not 100%", @"Cog signal-integrity modification reason")];
		}
		if(playbackFadesEnabled()) {
			[reasons addObject:NSLocalizedString(@"transition fading is enabled", @"Cog signal-integrity modification reason")];
		}
		if([defaults boolForKey:@"GraphicEQenable"]) {
			[reasons addObject:NSLocalizedString(@"equalizer processing", @"Cog signal-integrity modification reason")];
		}
		if([defaults boolForKey:@"enableHrtf"]) {
			[reasons addObject:NSLocalizedString(@"HRTF processing", @"Cog signal-integrity modification reason")];
		}
		if([defaults boolForKey:@"enableFSurround"] && sourceFormat.mChannelsPerFrame == 2) {
			[reasons addObject:NSLocalizedString(@"FreeSurround processing", @"Cog signal-integrity modification reason")];
		}

		NSNumber *pitchSetting = [defaults objectForKey:@"pitch"];
		NSNumber *tempoSetting = [defaults objectForKey:@"tempo"];
		const double pitch = pitchSetting ? [pitchSetting doubleValue] : 1.0;
		const double tempo = tempoSetting ? [tempoSetting doubleValue] : 1.0;
		NSString *stretchEngine = [defaults stringForKey:@"rubberbandEngine"];
		if(![stretchEngine isEqualToString:@"disabled"] &&
		   (fabs(pitch - 1.0) >= 1e-7 || fabs(tempo - 1.0) >= 1e-7)) {
			[reasons addObject:NSLocalizedString(@"time or pitch processing", @"Cog signal-integrity modification reason")];
		}
		if([outputController currentInputHDCDDetected] && [defaults boolForKey:@"enableHDCD"]) {
			[reasons addObject:NSLocalizedString(@"HDCD decoding", @"Cog signal-integrity modification reason")];
		}
	}

	const BOOL lossless = reasons.count == 0;
	NSString *details;
	if(lossless) {
		details = NSLocalizedString(@"Decoded source sample values are preserved through Cog; representation-only changes may still be shown.", @"Lossless Cog signal-integrity details");
	} else {
		details = [NSString stringWithFormat:NSLocalizedString(@"Cog changes the decoded source samples: %@.", @"Modified Cog signal-integrity details"),
		                                           [reasons componentsJoinedByString:@"; "]];
	}
	return @{
		CogCoreAudioSignalIntegrityLosslessKey: @(lossless),
		CogCoreAudioSignalIntegrityDetailsKey: details,
	};
}

- (void)postOutputFormatDescription:(NSString *)description {
	NSDictionary *userInfo = nil;
	if(description) {
		const AudioDeviceID activeDeviceID = exclusiveIOProcID ? exclusiveIOProcDeviceID : _au.deviceID;
		NSString *virtualDescription = virtualOutputFormatDescription(activeDeviceID);
		NSString *deviceDescription = physicalOutputFormatDescription(activeDeviceID);
		NSMutableDictionary *formatInfo = [@{ CogCoreAudioOutputFormatDescriptionKey: description } mutableCopy];
		formatInfo[CogCoreAudioOutputStatusFormatDescriptionKey] =
		    outputStatusFormatDescription(renderFormat, renderFormatDoPInteger);
		[formatInfo addEntriesFromDictionary:[self signalIntegrityInfo]];
		if(sourceFormatValid) {
			formatInfo[CogCoreAudioSourceFormatDescriptionKey] = sourceFormatDescription(sourceFormat);
		}
		if(virtualDescription) {
			formatInfo[CogCoreAudioVirtualFormatDescriptionKey] = virtualDescription;
		}
		if(deviceDescription) {
			formatInfo[CogCoreAudioDeviceFormatDescriptionKey] = deviceDescription;
		}
		formatInfo[CogCoreAudioEndToEndIntegerTransportKey] = @([self currentOutputIsEndToEndInteger]);
		formatInfo[CogCoreAudioExclusiveTransportKey] = @([self currentOutputUsesExclusiveTransport]);
		formatInfo[CogCoreAudioHogModeOwnedKey] = @([self currentProcessOwnsHogMode]);
		userInfo = formatInfo;
	}
	dispatch_block_t postNotification = ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:CogCoreAudioOutputFormatDidChangeNotification
		                                                    object:self
		                                                  userInfo:userInfo];
	};
	if([NSThread isMainThread]) {
		postNotification();
	} else {
		dispatch_async(dispatch_get_main_queue(), postNotification);
	}
}

static OSStatus
default_device_changed(AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses, void *inUserData) {
	OutputCoreAudio *_self = (__bridge OutputCoreAudio *)inUserData;
	return [_self setOutputDeviceByID:-1];
}

static OSStatus
current_device_listener(AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses, void *inUserData) {
	OutputCoreAudio *_self = (__bridge OutputCoreAudio *)inUserData;
	for(UInt32 i = 0; i < inNumberAddresses; ++i) {
		switch(inAddresses[i].mSelector) {
			case kAudioDevicePropertyDeviceIsAlive: {
				// Core Audio can send this notification while a live device changes
				// ownership or stream format. Only abandon the selected device after
				// reading an actual dead state; treating every notification as removal
				// tears down Cog's own hog-mode transition.
				AudioObjectPropertyAddress aliveAddress = {
					.mSelector = kAudioDevicePropertyDeviceIsAlive,
					.mScope = kAudioObjectPropertyScopeGlobal,
					.mElement = kAudioObjectPropertyElementMaster
				};
				UInt32 alive = 0;
				UInt32 size = sizeof(alive);
				if(AudioObjectGetPropertyData(inObjectID, &aliveAddress, 0, NULL, &size, &alive) == noErr && alive) {
					return noErr;
				}
				return [_self setOutputDeviceByID:-1];
			}

			case kAudioDevicePropertyNominalSampleRate:
			case kAudioDevicePropertyStreamFormat:
				_self->outputdevicechanged = YES;
				return noErr;
		}
	}
	return noErr;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if(context != kOutputCoreAudioContext) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}

	if([keyPath isEqualToString:@"values.outputDevice"]) {
		NSDictionary *device = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] objectForKey:@"outputDevice"];

		[self setOutputDeviceWithDeviceDict:device];
	} else if([keyPath isEqualToString:@"values.suspendOutputOnPause"]) {
		suspendOutputOnPause = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] boolForKey:@"suspendOutputOnPause"];
		[self stopIdle];
		if(fading || faded) {
			if(suspendOutputOnPause)
				[self timeOut];
			else
				[self resume];
		}
	} else if([keyPath isEqualToString:@"values.exclusiveIntegerOutput"]) {
		exclusiveOutputEnabled = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] boolForKey:@"exclusiveIntegerOutput"];
		if(!stopping) outputdevicechanged = YES;
	} else if([keyPath isEqualToString:@"values.setDeviceVolumeTo100ForExclusiveOutput"]) {
		setDeviceVolumeTo100ForExclusiveOutput = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] boolForKey:@"setDeviceVolumeTo100ForExclusiveOutput"];
		if(setDeviceVolumeTo100ForExclusiveOutput && exclusiveIOProcRunning &&
		   [self currentOutputUsesExclusiveTransport]) {
			[self setDeviceVolumeTo100ForExclusiveOutputIfSupported];
		}
	} else if([signalIntegrityPreferenceKeyPaths() containsObject:keyPath]) {
		// ConverterNode and the DSP nodes observe the same preferences. Defer the
		// refresh by one main-queue turn so their active state is updated first.
		dispatch_async(dispatch_get_main_queue(), ^{
			if(!self->stopping) {
				[self refreshOutputStatus];
			}
		});
	}
}

- (BOOL)signalEndOfStream:(double)latency {
	stopped = YES;
	BOOL ret = [outputController selectNextBuffer];
	stopped = ret;
	if(!stopping) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC * latency)), dispatch_get_main_queue(), ^{
			if(!self->stopping) {
				[self->outputController endOfInputPlayed];
				[self->outputController resetAmountPlayed];
			}
		});
	}
	return ret;
}

- (BOOL)processEndOfStream {
	if(stopping) {
		return YES;
	}
	if([outputController endOfStream] != YES) {
		return NO;
	}

	// Serialize the final end-of-stream decision with manual replacement. The
	// old chain may publish EOS after the replacement has already begun; in
	// that case it must not shut down the retained AUHAL render thread.
	@synchronized(self) {
		if(stopping) {
			return YES;
		}
		if(streamReplacementPending || [outputController endOfStream] != YES) {
			return NO;
		}
		if([self signalEndOfStream:[outputController getTotalLatency]]) {
			stopping = YES;
			return YES;
		}
	}
	return NO;
}

- (NSArray *)DSPs {
	if(DSPsLaunched) {
		return @[hrtfNode, downmixNode, faderNode];
	} else {
		return @[];
	}
}

- (DSPDownmixNode *)downmix {
	return downmixNode;
}

- (DSPFaderNode *)fader {
	return faderNode;
}

- (void)launchDSPs {
	NSArray *DSPs = [self DSPs];

	for (Node *node in DSPs) {
		[node launchThread];
	}
}

- (void)threadEntry:(id)arg {
	@autoreleasepool {
		NSThread *currentThread = [NSThread currentThread];
		[currentThread setThreadPriority:0.75];
		[currentThread setQualityOfService:NSQualityOfServiceUserInitiated];
	}

	running = YES;
	started = NO;
	shouldPlayOutBuffer = NO;
	BOOL rendered = NO;

	while(!stopping) {
		@autoreleasepool {
			if(outputdevicechanged) {
				// Re-run source-aware negotiation after a device or stream-format
				// change so a newly selected DAC can enter its integer physical mode.
				// Take the source-format snapshot under the same lock used by manual
				// stream replacement. Otherwise a callback raised by that replacement
				// can capture the outgoing DoP format, wait for the PCM transaction, and
				// then restore the stale DoP clock as soon as the lock becomes available.
				BOOL devicePrepared = NO;
				@synchronized(self) {
					devicePrepared = sourceFormatValid ? [self prepareForInputFormatLocked:sourceFormat] :
					                                               [self updateDeviceFormat];
					if(devicePrepared && !exclusiveIOProcID && !_au.renderResourcesAllocated) {
						NSError *resourceError = nil;
						devicePrepared = [_au allocateRenderResourcesAndReturnError:&resourceError] && resourceError == nil;
					}
					if(devicePrepared) {
						outputdevicechanged = NO;
					}
				}
				if(!devicePrepared) {
					usleep(2000);
					continue;
				}
			}

			if([outputController shouldReset]) {
				[outputController setShouldReset:NO];
				[outputLock lock];
				started = NO;
				restarted = NO;
				[buffer reset];
				[self setShouldReset:YES];
				[outputLock unlock];
			}

			if(stopping)
				break;

			if(!cutOffInput && ![buffer isFull]) {
				[self renderAndConvert];
				rendered = YES;
			} else {
				rendered = NO;
			}

			if(!started && !paused && !streamReplacementPending) {
				// Prevent this call from hanging when used in this thread, when buffer may be empty
				// and waiting for this very thread to fill it
				resetting = YES;
				[self resume];
				resetting = NO;
			}

			if(prebufferReached && !prebufferSignaled) {
				prebufferSignaled = YES;
				[[NSNotificationCenter defaultCenter] postNotificationName:CogPlaybackDidPrebufferNotification object:nil];
			}

			if([outputController shouldContinue] == NO) {
				break;
			}
		}

		if(!rendered) {
			usleep(5000);
		}
	}

	stopped = YES;
	if(!stopInvoked) {
		[self doStop];
	}
}

- (OSStatus)setOutputDeviceByID:(int)deviceIDIn {
	OSStatus err;
	BOOL defaultDevice = NO;
	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioHardwarePropertyDefaultOutputDevice,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};

	AudioDeviceID deviceID = (AudioDeviceID)deviceIDIn;

	if(deviceIDIn == -1) {
		defaultDevice = YES;
		UInt32 size = sizeof(AudioDeviceID);
		err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &theAddress, 0, NULL, &size, &deviceID);

		if(err != noErr) {
			DLog(@"THERE'S NO DEFAULT OUTPUT DEVICE");

			return err;
		}
		if(deviceID == kAudioObjectUnknown) {
			// Some HAL drivers temporarily remove a hogged device from the shared
			// system-default slot. That is not a real output-device change. Keep the
			// device Cog already owns; a later valid default notification will still
			// be handled normally.
			if(outputDeviceID != kAudioObjectUnknown && outputDeviceID != (AudioDeviceID)-1 &&
			   [self currentProcessOwnsHogMode]) {
				DLog(@"Ignoring transient unknown default output while Cog owns device %u",
				     (unsigned int)outputDeviceID);
				return noErr;
			}
			DLog(@"THERE'S NO DEFAULT OUTPUT DEVICE");
			return kAudioHardwareBadDeviceError;
		}
	}

	if(_au) {
		if(defaultdevicelistenerapplied && !defaultDevice) {
			/* Already set above
			 * theAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice; */
			AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &theAddress, default_device_changed, (__bridge void *_Nullable)(self));
			defaultdevicelistenerapplied = NO;
		}

		outputdevicechanged = NO;
		@synchronized(sampleRateSupportCache) {
			[sampleRateSupportCache removeAllObjects];
		}

		if(outputDeviceID != deviceID) {
			const BOOL hardwareWasRunning = [self hardwareIsRunning];
			if((savedPhysicalFormatValid && savedPhysicalFormatDeviceID == outputDeviceID) ||
			   (savedVirtualFormatValid && savedVirtualFormatDeviceID == outputDeviceID) ||
			   (hogModeOwned && hogModeDeviceID == outputDeviceID)) {
				resetting = YES;
				[self stopCurrentHardware];
				if(_au.renderResourcesAllocated) {
					[_au deallocateRenderResources];
				}
				[self destroyExclusiveIOProc];
				BOOL restored = [self restoreSavedPhysicalFormatSetAtCurrentSampleRate];
				if(!restored) {
					ALog(@"Unable to restore the previous physical format before changing output devices");
				}
				restored = [self restoreSavedVirtualFormatSetAtCurrentSampleRate] && restored;
				if(!restored) {
					ALog(@"Unable to restore the previous virtual format before changing output devices");
					[self ensureMixableStreamFormatsForAUHAL];
				}
				if(![self releaseHogModeForCurrentDevice]) {
					ALog(@"Unable to release exclusive ownership before changing output devices");
				}
				savedPhysicalFormatValid = NO;
				savedPhysicalFormats = nil;
				savedVirtualFormatValid = NO;
				savedVirtualFormats = nil;
				hogModeOwned = NO;
				hogModeDeviceID = kAudioObjectUnknown;
				if(hardwareWasRunning) {
					started = NO;
					restarted = NO;
				}
				resetting = NO;
			}
			preferIntegerPhysicalOutput = NO;
			preferredIntegerPhysicalFormats = nil;
			preferExclusiveIntegerTransport = NO;
			preferredIntegerTransportRequiresHog = NO;
			preferredIntegerVirtualFormats = nil;
			preferExclusiveFloatTransport = NO;
			preferredFloatVirtualFormats = nil;
			bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
			renderFormatEndToEndInteger = NO;
			bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));

			if(currentdevicelistenerapplied) {
				if(devicealivelistenerapplied) {
					theAddress.mSelector = kAudioDevicePropertyDeviceIsAlive;
					AudioObjectRemovePropertyListener(outputDeviceID, &theAddress, current_device_listener, (__bridge void *_Nullable)(self));
					devicealivelistenerapplied = NO;
				}
				theAddress.mSelector = kAudioDevicePropertyStreamFormat;
				AudioObjectRemovePropertyListener(outputDeviceID, &theAddress, current_device_listener, (__bridge void *_Nullable)(self));
				theAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
				AudioObjectRemovePropertyListener(outputDeviceID, &theAddress, current_device_listener, (__bridge void *_Nullable)(self));
				currentdevicelistenerapplied = NO;
			}

			DLog(@"Device: %i\n", deviceID);
			outputDeviceID = deviceID;

			// AUHAL is a shared-mode output unit unless Cog has explicitly acquired
			// exclusive ownership of the device. A stale non-mixable stream format
			// makes AUHAL declare the selected device unusable and silently fall back
			// to another output. Restore an equivalent mixable representation before
			// attaching AUHAL. Non-mixable formats must be reserved for a real
			// exclusive/hog-mode implementation.
			if(![self ensureMixableStreamFormatsForAUHAL]) {
				ALog(@"Unable to restore mixable stream formats before selecting output device %u",
				     (unsigned int)outputDeviceID);
			}

			// AUHAL may immediately restart the new device with the old input-bus
			// format. Keep that short transition silent until the output thread has
			// renegotiated the active source for the new device capabilities.
			resetting = YES;
			if(![self ensureAUHALBoundToOutputDevice]) {
				resetting = NO;
				return kAudioHardwareUnspecifiedError;
			}

			outputDeviceIDChanged = YES;
			outputdevicechanged = YES;
		}

		if(!currentdevicelistenerapplied) {
			if(!devicealivelistenerapplied && !defaultDevice) {
				theAddress.mSelector = kAudioDevicePropertyDeviceIsAlive;
				AudioObjectAddPropertyListener(outputDeviceID, &theAddress, current_device_listener, (__bridge void *_Nullable)(self));
				devicealivelistenerapplied = YES;
			}
			theAddress.mSelector = kAudioDevicePropertyStreamFormat;
			AudioObjectAddPropertyListener(outputDeviceID, &theAddress, current_device_listener, (__bridge void *_Nullable)(self));
			theAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
			AudioObjectAddPropertyListener(outputDeviceID, &theAddress, current_device_listener, (__bridge void *_Nullable)(self));
			currentdevicelistenerapplied = YES;
		}

		if(!defaultdevicelistenerapplied && defaultDevice) {
			theAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
			AudioObjectAddPropertyListener(kAudioObjectSystemObject, &theAddress, default_device_changed, (__bridge void *_Nullable)(self));
			defaultdevicelistenerapplied = YES;
		}
	}

	return noErr;
}

- (BOOL)setOutputDeviceWithDeviceDict:(NSDictionary *)deviceDict {
	NSNumber *deviceIDNum = deviceDict ? [deviceDict objectForKey:@"deviceID"] : @(-1);
	int outputDeviceID = deviceIDNum ? [deviceIDNum intValue] : -1;

	__block OSStatus err = [self setOutputDeviceByID:outputDeviceID];

	if(err != noErr) {
		// Try matching by name.
		NSString *userDeviceName = deviceDict[@"name"];

		[self enumerateAudioOutputsUsingBlock:
			  ^(NSString *deviceName, AudioDeviceID deviceID, AudioDeviceID systemDefaultID, BOOL *stop) {
				  if([deviceName isEqualToString:userDeviceName]) {
					  err = [self setOutputDeviceByID:deviceID];

#if 0
				// Disable. Would cause loop by triggering `-observeValueForKeyPath:ofObject:change:context:` above.
				// Update `outputDevice`, in case the ID has changed.
				NSDictionary *deviceInfo = @{
					@"name": deviceName,
					@"deviceID": @(deviceID),
				};
				[[NSUserDefaults standardUserDefaults] setObject:deviceInfo forKey:@"outputDevice"];
#endif

					  DLog(@"Found output device: \"%@\" (%d).", deviceName, deviceID);

					  *stop = YES;
				  }
			  }];
	}

	if(err != noErr) {
		ALog(@"No output device could be found, your random error code is %d. Have a nice day!", err);

		return NO;
	}

	return YES;
}

// The following is largely a copy pasta of -awakeFromNib from "OutputsArrayController.m".
// TODO: Share the code. (How to do this across xcodeproj?)
- (void)enumerateAudioOutputsUsingBlock:(void(NS_NOESCAPE ^ _Nonnull)(NSString *deviceName, AudioDeviceID deviceID, AudioDeviceID systemDefaultID, BOOL *stop))block {
	UInt32 propsize;
	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioHardwarePropertyDevices,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};

	OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &theAddress, 0, NULL, &propsize);
	if(status != noErr) return;
	UInt32 nDevices = propsize / (UInt32)sizeof(AudioDeviceID);
	AudioDeviceID *devids = (AudioDeviceID *)malloc(propsize);
	status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &theAddress, 0, NULL, &propsize, devids);
	if(status != noErr) return;

	theAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
	AudioDeviceID systemDefault;
	propsize = sizeof(systemDefault);
	status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &theAddress, 0, NULL, &propsize, &systemDefault);
	if(status != noErr) return;

	theAddress.mScope = kAudioDevicePropertyScopeOutput;

	for(UInt32 i = 0; i < nDevices; ++i) {
		UInt32 isAlive = 0;
		propsize = sizeof(isAlive);
		theAddress.mSelector = kAudioDevicePropertyDeviceIsAlive;
		status = AudioObjectGetPropertyData(devids[i], &theAddress, 0, NULL, &propsize, &isAlive);
		if(status != noErr) return;
		if(!isAlive) continue;

		CFStringRef name = NULL;
		propsize = sizeof(name);
		theAddress.mSelector = kAudioDevicePropertyDeviceNameCFString;
		status = AudioObjectGetPropertyData(devids[i], &theAddress, 0, NULL, &propsize, &name);
		if(status != noErr) return;

		propsize = 0;
		theAddress.mSelector = kAudioDevicePropertyStreamConfiguration;
		status = AudioObjectGetPropertyDataSize(devids[i], &theAddress, 0, NULL, &propsize);
		if(status != noErr) {
			if(name) CFRelease(name);
			return;
		}

		if(propsize < sizeof(UInt32)) {
			if(name) CFRelease(name);
			continue;
		}

		AudioBufferList *bufferList = (AudioBufferList *)malloc(propsize);
		if(!bufferList) {
			if(name) CFRelease(name);
			return;
		}
		status = AudioObjectGetPropertyData(devids[i], &theAddress, 0, NULL, &propsize, bufferList);
		if(status != noErr) {
			if(name) CFRelease(name);
			return;
		}
		UInt32 bufferCount = bufferList->mNumberBuffers;
		free(bufferList);

		if(!bufferCount) {
			if(name) CFRelease(name);
			continue;
		}

		BOOL stop = NO;
		NSString *deviceName = name ? [NSString stringWithString:(__bridge NSString *)name] : [NSString stringWithFormat:@"Unknown device %u", (unsigned int)devids[i]];

		block(deviceName,
			  devids[i],
			  systemDefault,
			  &stop);

		if(name) CFRelease(name);

		if(stop) {
			break;
		}
	}

	free(devids);
}

static double preferredDeviceSampleRateForInputFormat(AudioStreamBasicDescription inputFormat) {
	if(inputFormat.mBitsPerChannel == 1) {
		return inputFormat.mSampleRate / 16.0;
	}
	return inputFormat.mSampleRate;
}

static AudioStreamBasicDescription DoPIntegerRenderFormatForDeviceFormat(AudioStreamBasicDescription deviceFormat) {
	AudioStreamBasicDescription outputFormat = deviceFormat;
	outputFormat.mFormatID = kAudioFormatLinearPCM;
	outputFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsAlignedHigh | kAudioFormatFlagsNativeEndian;
	outputFormat.mBitsPerChannel = 24;
	outputFormat.mFramesPerPacket = 1;
	outputFormat.mBytesPerFrame = (UInt32)(sizeof(int32_t) * outputFormat.mChannelsPerFrame);
	outputFormat.mBytesPerPacket = outputFormat.mBytesPerFrame * outputFormat.mFramesPerPacket;
	outputFormat.mReserved = 0;
	return outputFormat;
}

static BOOL AudioFormatIsSignedIntegerPCM(AudioStreamBasicDescription format) {
	return format.mFormatID == kAudioFormatLinearPCM &&
	       !(format.mFormatFlags & kAudioFormatFlagIsFloat) &&
	       !!(format.mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
	       format.mBitsPerChannel > 0 && format.mBitsPerChannel <= 32 &&
	       format.mFramesPerPacket == 1;
}

static BOOL AudioFormatIsIntegerPCM(AudioStreamBasicDescription format) {
	return format.mFormatID == kAudioFormatLinearPCM &&
	       !(format.mFormatFlags & kAudioFormatFlagIsFloat) &&
	       !(format.mFormatFlags & kLinearPCMFormatFlagsSampleFractionMask) &&
	       format.mBitsPerChannel > 0 && format.mBitsPerChannel <= 64 &&
	       format.mFramesPerPacket == 1;
}

static UInt32 AudioFormatBytesPerSample(AudioStreamBasicDescription format) {
	if(!format.mChannelsPerFrame || !format.mBytesPerFrame) {
		return 0;
	}
	if(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) {
		return format.mBytesPerFrame;
	}
	if(format.mBytesPerFrame % format.mChannelsPerFrame) {
		return 0;
	}
	return format.mBytesPerFrame / format.mChannelsPerFrame;
}

static AudioStreamBasicDescription IntegerClientFormatForSourceBits(UInt32 sourceBits,
	                                                                 double sampleRate,
	                                                                 UInt32 channels) {
	AudioStreamBasicDescription clientFormat = { 0 };
	clientFormat.mSampleRate = sampleRate;
	clientFormat.mFormatID = kAudioFormatLinearPCM;
	clientFormat.mChannelsPerFrame = channels;
	clientFormat.mFramesPerPacket = 1;
	if(sourceBits <= 16) {
		clientFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
		clientFormat.mBitsPerChannel = 16;
		clientFormat.mBytesPerFrame = (UInt32)(sizeof(int16_t) * channels);
	} else if(sourceBits <= 24) {
		// 24 valid bits in a 32-bit high-aligned client slot is accepted by
		// AUHAL across macOS versions. It does not imply that the DAC uses the
		// same container; HAL performs an exact integer representation change.
		clientFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh | kAudioFormatFlagsNativeEndian;
		clientFormat.mBitsPerChannel = 24;
		clientFormat.mBytesPerFrame = (UInt32)(sizeof(int32_t) * channels);
	} else {
		clientFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
		clientFormat.mBitsPerChannel = 32;
		clientFormat.mBytesPerFrame = (UInt32)(sizeof(int32_t) * channels);
	}
	clientFormat.mBytesPerPacket = clientFormat.mBytesPerFrame;
	return clientFormat;
}

static NSValue *PhysicalFormatValue(AudioStreamBasicDescription format) {
	return [NSValue valueWithBytes:&format objCType:@encode(AudioStreamBasicDescription)];
}

static BOOL GetPhysicalFormatValue(NSValue *value, AudioStreamBasicDescription *format) {
	if(!value || !format || strcmp(value.objCType, @encode(AudioStreamBasicDescription)) != 0) {
		return NO;
	}
	[value getValue:format size:sizeof(*format)];
	return YES;
}

static NSValue *RangedFormatValue(AudioStreamRangedDescription format) {
	return [NSValue valueWithBytes:&format objCType:@encode(AudioStreamRangedDescription)];
}

static BOOL GetRangedFormatValue(NSValue *value, AudioStreamRangedDescription *format) {
	if(!value || !format || strcmp(value.objCType, @encode(AudioStreamRangedDescription)) != 0) {
		return NO;
	}
	[value getValue:format size:sizeof(*format)];
	return YES;
}

static BOOL PhysicalFormatsHaveSameRepresentation(AudioStreamBasicDescription first,
	                                                 AudioStreamBasicDescription second) {
	const AudioFormatFlags relevantFlags = kAudioFormatFlagIsFloat |
	                                       kAudioFormatFlagIsBigEndian |
	                                       kAudioFormatFlagIsSignedInteger |
	                                       kAudioFormatFlagIsPacked |
	                                       kAudioFormatFlagIsAlignedHigh |
	                                       kAudioFormatFlagIsNonInterleaved |
	                                       kAudioFormatFlagIsNonMixable |
	                                       kLinearPCMFormatFlagsSampleFractionMask;
	return first.mFormatID == second.mFormatID &&
	       (first.mFormatFlags & relevantFlags) == (second.mFormatFlags & relevantFlags) &&
	       first.mBytesPerPacket == second.mBytesPerPacket &&
	       first.mFramesPerPacket == second.mFramesPerPacket &&
	       first.mBytesPerFrame == second.mBytesPerFrame &&
	       first.mChannelsPerFrame == second.mChannelsPerFrame &&
	       first.mBitsPerChannel == second.mBitsPerChannel;
}

static BOOL PhysicalFormatsMatch(AudioStreamBasicDescription first,
	                              AudioStreamBasicDescription second) {
	return PhysicalFormatsHaveSameRepresentation(first, second) &&
	       fabs(first.mSampleRate - second.mSampleRate) < 1.0;
}

static BOOL StreamFormatsHaveSameSampleRepresentation(AudioStreamBasicDescription first,
	                                                    AudioStreamBasicDescription second,
	                                                    BOOL compareNonMixable) {
	AudioFormatFlags relevantFlags = kAudioFormatFlagIsFloat |
	                                 kAudioFormatFlagIsBigEndian |
	                                 kAudioFormatFlagIsSignedInteger |
	                                 kAudioFormatFlagIsPacked |
	                                 kAudioFormatFlagIsAlignedHigh |
	                                 kAudioFormatFlagIsNonInterleaved |
	                                 kLinearPCMFormatFlagsSampleFractionMask;
	if(compareNonMixable) relevantFlags |= kAudioFormatFlagIsNonMixable;
	return first.mFormatID == second.mFormatID &&
	       (first.mFormatFlags & relevantFlags) == (second.mFormatFlags & relevantFlags) &&
	       first.mFramesPerPacket == second.mFramesPerPacket &&
	       first.mBitsPerChannel == second.mBitsPerChannel &&
	       AudioFormatBytesPerSample(first) == AudioFormatBytesPerSample(second);
}

static BOOL RangedPhysicalFormatSupportsSampleRate(AudioStreamRangedDescription description,
	                                                double sampleRate) {
	return sampleRate >= description.mSampleRateRange.mMinimum - 1.0 &&
	       sampleRate <= description.mSampleRateRange.mMaximum + 1.0;
}

static BOOL convertFloat64BufferToIntegerPCM(void *output,
	                                         const double *input,
	                                         size_t count,
	                                         AudioStreamBasicDescription format) {
	if(!AudioFormatIsSignedIntegerPCM(format)) {
		return NO;
	}
	const UInt32 bytesPerSample = AudioFormatBytesPerSample(format);
	const UInt32 containerBits = bytesPerSample * 8;
	const UInt32 validBits = format.mBitsPerChannel;
	if(bytesPerSample < 2 || bytesPerSample > 4 || validBits > containerBits) {
		return NO;
	}

	const BOOL alignedHigh = !(format.mFormatFlags & kAudioFormatFlagIsPacked) &&
	                         !!(format.mFormatFlags & kAudioFormatFlagIsAlignedHigh);
	const BOOL bigEndian = !!(format.mFormatFlags & kAudioFormatFlagIsBigEndian);
	const UInt32 alignmentShift = alignedHigh ? containerBits - validBits : 0;
	const int64_t minimum = -(INT64_C(1) << (validBits - 1));
	const int64_t maximum = (INT64_C(1) << (validBits - 1)) - 1;
	const double scale = ldexp(1.0, (int)validBits - 1);
	const uint64_t containerMask = (UINT64_C(1) << containerBits) - 1;
	uint8_t *bytes = (uint8_t *)output;

	for(size_t i = 0; i < count; ++i) {
		const double sample = input[i];
		int64_t quantized;
		if(!isfinite(sample)) {
			quantized = 0;
		} else if(sample >= 1.0) {
			quantized = maximum;
		} else if(sample <= -1.0) {
			quantized = minimum;
		} else {
			// Cog's integer-to-Float64 normalization divides by 2^(bits-1).
			// This exact inverse restores every Int16 and Int24 source value.
			quantized = llrint(sample * scale);
		}

		uint64_t encoded = (((uint64_t)quantized) << alignmentShift) & containerMask;
		for(UInt32 byte = 0; byte < bytesPerSample; ++byte) {
			const UInt32 destinationByte = bigEndian ? bytesPerSample - byte - 1 : byte;
			bytes[i * bytesPerSample + destinationByte] = (uint8_t)(encoded >> (byte * 8));
		}
	}
	return YES;
}

static int32_t convertPCMFloat64ToFullS32(double sample) {
	if(isnan(sample)) return 0;
	if(sample >= 1.0) return INT32_MAX;
	if(sample <= -1.0) return INT32_MIN;
	int64_t scaled = llrint(sample * 2147483648.0);
	if(scaled > INT32_MAX) return INT32_MAX;
	if(scaled < INT32_MIN) return INT32_MIN;
	return (int32_t)scaled;
}

static void convertFloat64BufferToFullS32(int32_t *output, const double *input, size_t count) {
	for(size_t i = 0; i < count; ++i) {
		output[i] = convertPCMFloat64ToFullS32(input[i]);
	}
}

static void convertFloat64BufferToF32(float *output, const double *input, size_t count) {
	vDSP_vdpsp(input, 1, output, 1, count);
}

static BOOL convertPCMBufferToFloat64(double *output, const void *input, AudioStreamBasicDescription format, size_t count) {
	if(AudioFormatIsFloat64(format)) {
		memcpy(output, input, count * sizeof(double));
		return YES;
	}
	if(AudioFormatIsFloat32(format)) {
		vDSP_vspdp((const float *)input, 1, output, 1, count);
		return YES;
	}
	if(!AudioFormatIsHighPrecisionPCM(format)) {
		return NO;
	}

	vDSP_vflt32D((const int32_t *)input, 1, output, 1, count);
	const double scale = 2147483648.0;
	vDSP_vsdivD(output, 1, &scale, output, 1, count);
	return YES;
}

static BOOL highPrecisionRepresentationsMatch(AudioStreamBasicDescription first, AudioStreamBasicDescription second) {
	if(!AudioFormatIsHighPrecisionPCM(first) || !AudioFormatIsHighPrecisionPCM(second)) {
		return NO;
	}
	const AudioStreamBasicDescription canonicalFirst = AudioFormatAsCanonicalHighPrecisionPCM(first);
	if(first.mFormatFlags != canonicalFirst.mFormatFlags ||
	   first.mBitsPerChannel != canonicalFirst.mBitsPerChannel ||
	   first.mBytesPerFrame != canonicalFirst.mBytesPerFrame ||
	   first.mBytesPerPacket != canonicalFirst.mBytesPerPacket) {
		return NO;
	}
	return first.mChannelsPerFrame == second.mChannelsPerFrame &&
	       first.mBytesPerPacket == second.mBytesPerPacket &&
	       !!(first.mFormatFlags & kAudioFormatFlagIsFloat) ==
	       !!(second.mFormatFlags & kAudioFormatFlagIsFloat);
}

- (BOOL)prepareOutputDoubleScratchForRenderFormat:(AudioStreamBasicDescription)format {
	const size_t maximumFrames = MAX((size_t)_au.maximumFramesToRender,
	                                 (size_t)exclusiveMaximumFramesToRender);
	const size_t channels = (size_t)format.mChannelsPerFrame;
	if(!maximumFrames || !channels || maximumFrames > SIZE_MAX / channels) {
		return NO;
	}

	const size_t requiredSamples = maximumFrames * channels;
	if(requiredSamples > SIZE_MAX / sizeof(double)) {
		return NO;
	}
	if(outputDoubleScratch && inputDoubleScratch && outputDoubleScratchCapacity >= requiredSamples) {
		return YES;
	}

	double *outputScratch = (double *)realloc(outputDoubleScratch, requiredSamples * sizeof(double));
	if(!outputScratch) {
		return NO;
	}
	outputDoubleScratch = outputScratch;

	double *inputScratch = (double *)realloc(inputDoubleScratch, requiredSamples * sizeof(double));
	if(!inputScratch) {
		return NO;
	}
	inputDoubleScratch = inputScratch;
	outputDoubleScratchCapacity = requiredSamples;
	return YES;
}

- (BOOL)readStreamFormat:(AudioStreamBasicDescription *)format
	          fromStream:(AudioStreamID)streamID
	            selector:(AudioObjectPropertySelector)selector {
	if(streamID == kAudioObjectUnknown || !format) {
		return NO;
	}
	AudioObjectPropertyAddress address = {
		.mSelector = selector,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	UInt32 size = sizeof(*format);
	bzero(format, sizeof(*format));
	OSStatus status = AudioObjectGetPropertyData(streamID, &address, 0, NULL, &size, format);
	return status == noErr && size == sizeof(*format) && format->mFormatID != 0;
}

- (BOOL)readPhysicalFormat:(AudioStreamBasicDescription *)format fromStream:(AudioStreamID)streamID {
	return [self readStreamFormat:format fromStream:streamID selector:kAudioStreamPropertyPhysicalFormat];
}

- (BOOL)readVirtualFormat:(AudioStreamBasicDescription *)format fromStream:(AudioStreamID)streamID {
	return [self readStreamFormat:format fromStream:streamID selector:kAudioStreamPropertyVirtualFormat];
}

- (BOOL)findStreamFormatMatchingRepresentation:(AudioStreamBasicDescription)representation
	                                  atSampleRate:(double)sampleRate
	                                      streamID:(AudioStreamID)streamID
	                               currentSelector:(AudioObjectPropertySelector)currentSelector
	                             availableSelector:(AudioObjectPropertySelector)availableSelector
	                                         format:(AudioStreamBasicDescription *)selectedFormat {
	AudioStreamBasicDescription currentFormat = { 0 };
	if([self readStreamFormat:&currentFormat fromStream:streamID selector:currentSelector] &&
	   PhysicalFormatsHaveSameRepresentation(currentFormat, representation) &&
	   fabs(currentFormat.mSampleRate - sampleRate) < 1.0) {
		if(selectedFormat) *selectedFormat = currentFormat;
		return YES;
	}
	AudioObjectPropertyAddress address = {
		.mSelector = availableSelector,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	UInt32 size = 0;
	OSStatus status = AudioObjectGetPropertyDataSize(streamID, &address, 0, NULL, &size);
	if(status != noErr || size < sizeof(AudioStreamRangedDescription)) {
		return NO;
	}
	AudioStreamRangedDescription *descriptions = (AudioStreamRangedDescription *)malloc(size);
	if(!descriptions) {
		return NO;
	}
	status = AudioObjectGetPropertyData(streamID, &address, 0, NULL, &size, descriptions);
	if(status != noErr) {
		free(descriptions);
		return NO;
	}

	BOOL found = NO;
	const UInt32 count = size / (UInt32)sizeof(AudioStreamRangedDescription);
	for(UInt32 i = 0; i < count; ++i) {
		if(RangedPhysicalFormatSupportsSampleRate(descriptions[i], sampleRate) &&
		   PhysicalFormatsHaveSameRepresentation(descriptions[i].mFormat, representation)) {
			if(selectedFormat) {
				*selectedFormat = descriptions[i].mFormat;
				selectedFormat->mSampleRate = sampleRate;
			}
			found = YES;
			break;
		}
	}
	free(descriptions);
	return found;
}

- (BOOL)findPhysicalFormatMatchingRepresentation:(AudioStreamBasicDescription)representation
	                                  atSampleRate:(double)sampleRate
	                                      streamID:(AudioStreamID)streamID
	                                         format:(AudioStreamBasicDescription *)selectedFormat {
	return [self findStreamFormatMatchingRepresentation:representation
	                                      atSampleRate:sampleRate
	                                          streamID:streamID
	                                   currentSelector:kAudioStreamPropertyPhysicalFormat
	                                 availableSelector:kAudioStreamPropertyAvailablePhysicalFormats
	                                             format:selectedFormat];
}

- (BOOL)findVirtualFormatMatchingRepresentation:(AudioStreamBasicDescription)representation
	                                 atSampleRate:(double)sampleRate
	                                     streamID:(AudioStreamID)streamID
	                                        format:(AudioStreamBasicDescription *)selectedFormat {
	return [self findStreamFormatMatchingRepresentation:representation
	                                      atSampleRate:sampleRate
	                                          streamID:streamID
	                                   currentSelector:kAudioStreamPropertyVirtualFormat
	                                 availableSelector:kAudioStreamPropertyAvailableVirtualFormats
	                                             format:selectedFormat];
}

- (BOOL)setStreamFormat:(AudioStreamBasicDescription)format
	       onStream:(AudioStreamID)streamID
	       selector:(AudioObjectPropertySelector)selector {
	AudioObjectPropertyAddress address = {
		.mSelector = selector,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	AudioStreamBasicDescription currentFormat = { 0 };
	if([self readStreamFormat:&currentFormat fromStream:streamID selector:selector] &&
	   PhysicalFormatsMatch(currentFormat, format)) {
		return YES;
	}
	Boolean settable = false;
	OSStatus status = AudioObjectIsPropertySettable(streamID, &address, &settable);
	if(status != noErr || !settable) {
		return NO;
	}
	status = AudioObjectSetPropertyData(streamID, &address, 0, NULL, sizeof(format), &format);
	if(status != noErr) {
		return NO;
	}

	// Hardware drivers commonly apply physical-format changes asynchronously.
	for(size_t attempt = 0; attempt < 50; ++attempt) {
		if([self readStreamFormat:&currentFormat fromStream:streamID selector:selector] &&
		   PhysicalFormatsMatch(currentFormat, format)) {
			return YES;
		}
		usleep(10000);
	}
	return NO;
}

- (BOOL)setPhysicalFormat:(AudioStreamBasicDescription)format onStream:(AudioStreamID)streamID {
	return [self setStreamFormat:format onStream:streamID selector:kAudioStreamPropertyPhysicalFormat];
}

- (BOOL)setVirtualFormat:(AudioStreamBasicDescription)format onStream:(AudioStreamID)streamID {
	return [self setStreamFormat:format onStream:streamID selector:kAudioStreamPropertyVirtualFormat];
}

- (NSArray<NSNumber *> *)activeOutputPhysicalStreams {
	if(outputDeviceID == kAudioObjectUnknown || outputDeviceID == (AudioDeviceID)-1) return @[];
	AudioObjectPropertyAddress address = {
		.mSelector = kAudioDevicePropertyStreams,
		.mScope = kAudioDevicePropertyScopeOutput,
		.mElement = kAudioObjectPropertyElementMaster
	};
	UInt32 size = 0;
	OSStatus status = AudioObjectGetPropertyDataSize(outputDeviceID, &address, 0, NULL, &size);
	if(status != noErr || size < sizeof(AudioStreamID)) return @[];
	AudioStreamID *streams = (AudioStreamID *)malloc(size);
	if(!streams) return @[];
	status = AudioObjectGetPropertyData(outputDeviceID, &address, 0, NULL, &size, streams);
	if(status != noErr) {
		free(streams);
		return @[];
	}

	NSMutableArray<NSNumber *> *activeStreams = [NSMutableArray array];
	AudioObjectPropertyAddress activeAddress = {
		.mSelector = kAudioStreamPropertyIsActive,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	const UInt32 count = size / (UInt32)sizeof(AudioStreamID);
	for(UInt32 i = 0; i < count; ++i) {
		UInt32 active = 1;
		UInt32 activeSize = sizeof(active);
		status = AudioObjectGetPropertyData(streams[i], &activeAddress, 0, NULL, &activeSize, &active);
		if(status != noErr || active) [activeStreams addObject:@(streams[i])];
	}
	free(streams);
	return activeStreams;
}

- (NSDictionary<NSNumber *, NSValue *> *)currentStreamFormatSetForStreams:(NSArray<NSNumber *> *)streams
	                                                               selector:(AudioObjectPropertySelector)selector {
	if(!streams.count) return nil;
	NSMutableDictionary<NSNumber *, NSValue *> *formats = [NSMutableDictionary dictionary];
	for(NSNumber *streamNumber in streams) {
		AudioStreamBasicDescription format = { 0 };
		if(![self readStreamFormat:&format fromStream:streamNumber.unsignedIntValue selector:selector]) return nil;
		formats[streamNumber] = PhysicalFormatValue(format);
	}
	return formats;
}

- (NSDictionary<NSNumber *, NSValue *> *)currentPhysicalFormatSetForStreams:(NSArray<NSNumber *> *)streams {
	return [self currentStreamFormatSetForStreams:streams selector:kAudioStreamPropertyPhysicalFormat];
}

- (NSDictionary<NSNumber *, NSValue *> *)currentVirtualFormatSetForStreams:(NSArray<NSNumber *> *)streams {
	return [self currentStreamFormatSetForStreams:streams selector:kAudioStreamPropertyVirtualFormat];
}

- (NSArray<NSValue *> *)availableStreamFormatsForStream:(AudioStreamID)streamID
	                                           selector:(AudioObjectPropertySelector)selector
	                                    currentSelector:(AudioObjectPropertySelector)currentSelector {
	AudioObjectPropertyAddress address = {
		.mSelector = selector,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	UInt32 size = 0;
	OSStatus status = AudioObjectGetPropertyDataSize(streamID, &address, 0, NULL, &size);
	if(status == noErr && size >= sizeof(AudioStreamRangedDescription)) {
		AudioStreamRangedDescription *descriptions = (AudioStreamRangedDescription *)malloc(size);
		if(!descriptions) return @[];
		status = AudioObjectGetPropertyData(streamID, &address, 0, NULL, &size, descriptions);
		if(status == noErr) {
			NSMutableArray<NSValue *> *values = [NSMutableArray array];
			const UInt32 count = size / (UInt32)sizeof(AudioStreamRangedDescription);
			for(UInt32 i = 0; i < count; ++i) [values addObject:RangedFormatValue(descriptions[i])];
			free(descriptions);
			return values;
		}
		free(descriptions);
	}

	// A few drivers expose only their current stream format. Treat it as a
	// single-point capability instead of rejecting an otherwise usable device.
	AudioStreamBasicDescription current = { 0 };
	if(![self readStreamFormat:&current fromStream:streamID selector:currentSelector]) return @[];
	AudioStreamRangedDescription description = {
		.mFormat = current,
		.mSampleRateRange = { current.mSampleRate, current.mSampleRate }
	};
	return @[ RangedFormatValue(description) ];
}

static BOOL IntegerTransportFormatIsUsable(AudioStreamBasicDescription format,
	                                        UInt32 requiredBits,
	                                        BOOL requireDoPCarrier) {
	const UInt32 bytesPerSample = AudioFormatBytesPerSample(format);
	if(!AudioFormatIsSignedIntegerPCM(format) ||
	   (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ||
	   bytesPerSample < 2 || bytesPerSample > 4 ||
	   format.mBitsPerChannel < requiredBits ||
	   format.mBitsPerChannel > bytesPerSample * 8) return NO;
	if(!requireDoPCarrier) return YES;

	// Cog's native DoP carrier is the standard 24 valid bits in a high-aligned
	// 32-bit integer slot. Requiring the exact representation avoids inserting
	// a converter or guessing a driver's private Int32 DoP byte placement.
	return AudioFormatIsDoPInteger(format);
}

- (NSArray<NSDictionary<NSString *, id> *> *)integerTransportPairsForStream:(AudioStreamID)streamID
	                                                            sampleRate:(double)sampleRate
	                                                          requiredBits:(UInt32)requiredBits
	                                                     requireDoPCarrier:(BOOL)requireDoPCarrier {
	NSArray<NSValue *> *virtualFormats = [self availableStreamFormatsForStream:streamID
	                                                                  selector:kAudioStreamPropertyAvailableVirtualFormats
	                                                           currentSelector:kAudioStreamPropertyVirtualFormat];
	NSArray<NSValue *> *physicalFormats = [self availableStreamFormatsForStream:streamID
	                                                                   selector:kAudioStreamPropertyAvailablePhysicalFormats
	                                                            currentSelector:kAudioStreamPropertyPhysicalFormat];
	NSMutableArray<NSDictionary<NSString *, id> *> *pairs = [NSMutableArray array];
	for(NSValue *virtualValue in virtualFormats) {
		AudioStreamRangedDescription virtualDescription = { 0 };
		if(!GetRangedFormatValue(virtualValue, &virtualDescription) ||
		   !RangedPhysicalFormatSupportsSampleRate(virtualDescription, sampleRate)) continue;
		AudioStreamBasicDescription virtualFormat = virtualDescription.mFormat;
		virtualFormat.mSampleRate = sampleRate;
		if(!IntegerTransportFormatIsUsable(virtualFormat, requiredBits, requireDoPCarrier) ||
		   !(virtualFormat.mFormatFlags & kAudioFormatFlagIsNonMixable)) continue;

		for(NSValue *physicalValue in physicalFormats) {
			AudioStreamRangedDescription physicalDescription = { 0 };
			if(!GetRangedFormatValue(physicalValue, &physicalDescription) ||
			   !RangedPhysicalFormatSupportsSampleRate(physicalDescription, sampleRate)) continue;
			AudioStreamBasicDescription physicalFormat = physicalDescription.mFormat;
			physicalFormat.mSampleRate = sampleRate;
			if(!IntegerTransportFormatIsUsable(physicalFormat, requiredBits, requireDoPCarrier) ||
			   !PhysicalFormatsHaveSameRepresentation(virtualFormat, physicalFormat)) continue;

			const UInt32 containerBits = AudioFormatBytesPerSample(virtualFormat) * 8;
			const BOOL requiresHog = YES;
			uint64_t score = (uint64_t)(virtualFormat.mBitsPerChannel - requiredBits) * UINT64_C(1000000000);
			score += (uint64_t)(containerBits - virtualFormat.mBitsPerChannel) * UINT64_C(1000000);
			if(virtualFormat.mFormatFlags & kAudioFormatFlagIsBigEndian) score += 1;
			[pairs addObject:@{
				@"virtual": PhysicalFormatValue(virtualFormat),
				@"physical": PhysicalFormatValue(physicalFormat),
				@"requiresHog": @(requiresHog),
				@"score": @(score),
			}];
		}
	}
	[pairs sortUsingComparator:^NSComparisonResult(NSDictionary<NSString *, id> *first,
	                                               NSDictionary<NSString *, id> *second) {
		return [first[@"score"] compare:second[@"score"]];
	}];
	return pairs;
}

- (BOOL)findEndToEndIntegerFormatSetsForSampleRate:(double)sampleRate
	                                    requiredBits:(UInt32)requiredBits
	                               requireDoPCarrier:(BOOL)requireDoPCarrier
	                                  virtualFormats:(NSDictionary<NSNumber *, NSValue *> **)selectedVirtualFormats
	                                 physicalFormats:(NSDictionary<NSNumber *, NSValue *> **)selectedPhysicalFormats
	                                     clientFormat:(AudioStreamBasicDescription *)selectedClientFormat
	                                      requiresHog:(BOOL *)selectedRequiresHog {
	NSArray<NSNumber *> *streams = [self activeOutputPhysicalStreams];
	// The direct HAL callback below currently renders one interleaved buffer.
	// Multi-stream/aggregate devices remain on AUHAL until Cog can map their
	// individual channel buffers without making device-specific assumptions.
	if(streams.count != 1) return NO;
	NSArray<NSDictionary<NSString *, id> *> *firstPairs =
	    [self integerTransportPairsForStream:streams.firstObject.unsignedIntValue
	                            sampleRate:sampleRate
	                          requiredBits:requiredBits
	                     requireDoPCarrier:requireDoPCarrier];
	for(NSDictionary<NSString *, id> *firstPair in firstPairs) {
		AudioStreamBasicDescription baseline = { 0 };
		if(!GetPhysicalFormatValue(firstPair[@"virtual"], &baseline)) continue;
		NSMutableDictionary<NSNumber *, NSValue *> *virtualSet = [NSMutableDictionary dictionary];
		NSMutableDictionary<NSNumber *, NSValue *> *physicalSet = [NSMutableDictionary dictionary];
		virtualSet[streams.firstObject] = firstPair[@"virtual"];
		physicalSet[streams.firstObject] = firstPair[@"physical"];
		BOOL allStreamsMatch = YES;
		for(NSUInteger streamIndex = 1; streamIndex < streams.count; ++streamIndex) {
			NSNumber *streamNumber = streams[streamIndex];
			NSArray<NSDictionary<NSString *, id> *> *pairs =
			    [self integerTransportPairsForStream:streamNumber.unsignedIntValue
			                            sampleRate:sampleRate
			                          requiredBits:requiredBits
			                     requireDoPCarrier:requireDoPCarrier];
			NSDictionary<NSString *, id> *matchingPair = nil;
			for(NSDictionary<NSString *, id> *pair in pairs) {
				AudioStreamBasicDescription candidate = { 0 };
				if(GetPhysicalFormatValue(pair[@"virtual"], &candidate) &&
				   StreamFormatsHaveSameSampleRepresentation(baseline, candidate, YES)) {
					matchingPair = pair;
					break;
				}
			}
			if(!matchingPair) {
				allStreamsMatch = NO;
				break;
			}
			virtualSet[streamNumber] = matchingPair[@"virtual"];
			physicalSet[streamNumber] = matchingPair[@"physical"];
		}
		if(!allStreamsMatch) continue;

		AudioStreamBasicDescription clientFormat = baseline;
		clientFormat.mFormatFlags &= ~kAudioFormatFlagIsNonMixable;
		clientFormat.mChannelsPerFrame = deviceFormat.mChannelsPerFrame;
		const UInt32 bytesPerSample = AudioFormatBytesPerSample(baseline);
		clientFormat.mBytesPerFrame = bytesPerSample * clientFormat.mChannelsPerFrame;
		clientFormat.mBytesPerPacket = clientFormat.mBytesPerFrame * clientFormat.mFramesPerPacket;
		clientFormat.mReserved = 0;
		if(!clientFormat.mChannelsPerFrame ||
		   (requireDoPCarrier && !AudioFormatIsDoPInteger(clientFormat))) continue;

		if(selectedVirtualFormats) *selectedVirtualFormats = virtualSet;
		if(selectedPhysicalFormats) *selectedPhysicalFormats = physicalSet;
		if(selectedClientFormat) *selectedClientFormat = clientFormat;
		if(selectedRequiresHog) *selectedRequiresHog = [firstPair[@"requiresHog"] boolValue];
		return YES;
	}
	return NO;
}

- (BOOL)findExclusiveFloatVirtualFormatSetForInputFormat:(AudioStreamBasicDescription)inputFormat
	                                           sampleRate:(double)sampleRate
	                                        virtualFormats:(NSDictionary<NSNumber *, NSValue *> **)selectedVirtualFormats
	                                           clientFormat:(AudioStreamBasicDescription *)selectedClientFormat {
	const BOOL sourceIsFloat32 = AudioFormatIsFloat32(inputFormat);
	const BOOL sourceIsFloat64 = AudioFormatIsFloat64(inputFormat);
	if(!sourceIsFloat32 && !sourceIsFloat64) {
		DLog(@"Exclusive float skipped: source is not canonical interleaved Float32/Float64 (%@)",
		     outputFormatDescription(inputFormat, NO));
		return NO;
	}
	if(inputFormat.mChannelsPerFrame != deviceFormat.mChannelsPerFrame) {
		DLog(@"Exclusive float skipped: source has %u channels but the output client has %u",
		     (unsigned int)inputFormat.mChannelsPerFrame,
		     (unsigned int)deviceFormat.mChannelsPerFrame);
		return NO;
	}

	NSArray<NSNumber *> *streams = [self activeOutputPhysicalStreams];
	// The direct callback currently maps exactly one interleaved output buffer.
	// Aggregate and multi-stream devices keep using AUHAL until their individual
	// channel buffers can be described without device-specific assumptions.
	if(streams.count != 1) {
		DLog(@"Exclusive float skipped: direct output requires one active stream, found %lu",
		     (unsigned long)streams.count);
		return NO;
	}
	const NSNumber *streamNumber = streams.firstObject;
	NSArray<NSValue *> *availableFormats =
	    [self availableStreamFormatsForStream:streamNumber.unsignedIntValue
	                               selector:kAudioStreamPropertyAvailableVirtualFormats
	                        currentSelector:kAudioStreamPropertyVirtualFormat];
	BOOL found = NO;
	AudioStreamBasicDescription bestFormat = { 0 };
	uint64_t bestScore = UINT64_MAX;
	for(NSValue *value in availableFormats) {
		AudioStreamRangedDescription description = { 0 };
		if(!GetRangedFormatValue(value, &description) ||
		   !RangedPhysicalFormatSupportsSampleRate(description, sampleRate)) continue;
		AudioStreamBasicDescription candidate = description.mFormat;
		candidate.mSampleRate = sampleRate;
		if(candidate.mChannelsPerFrame != inputFormat.mChannelsPerFrame ||
		   (sourceIsFloat32 ? !AudioFormatIsFloat32(candidate) : !AudioFormatIsFloat64(candidate))) continue;

		// Prefer a driver's explicitly non-mixable float mode, while accepting its
		// ordinary float virtual format under verified hog ownership as well.
		const uint64_t score = (candidate.mFormatFlags & kAudioFormatFlagIsNonMixable) ? 0 : 1;
		if(!found || score < bestScore) {
			found = YES;
			bestScore = score;
			bestFormat = candidate;
		}
	}
	if(!found) {
		DLog(@"Exclusive float skipped: no matching Float%u virtual format at %.0f Hz with %u channels",
		     sourceIsFloat32 ? 32u : 64u,
		     sampleRate,
		     (unsigned int)inputFormat.mChannelsPerFrame);
		return NO;
	}

	AudioStreamBasicDescription clientFormat = bestFormat;
	clientFormat.mFormatFlags &= ~kAudioFormatFlagIsNonMixable;
	clientFormat.mReserved = 0;
	if(selectedVirtualFormats) *selectedVirtualFormats = @{ streamNumber: PhysicalFormatValue(bestFormat) };
	if(selectedClientFormat) *selectedClientFormat = clientFormat;
	DLog(@"Exclusive float selected: %@", outputFormatDescription(clientFormat, NO));
	return YES;
}

- (BOOL)findIntegerPhysicalFormatForPhysicalStream:(AudioStreamID)streamID
	                                    sampleRate:(double)sampleRate
	                                  requiredBits:(UInt32)requiredBits
	                             requireDoPCarrier:(BOOL)requireDoPCarrier
	                                         format:(AudioStreamBasicDescription *)selectedFormat {
	AudioStreamBasicDescription currentFormat = { 0 };
	if(![self readPhysicalFormat:&currentFormat fromStream:streamID]) return NO;
	AudioObjectPropertyAddress address = {
		.mSelector = kAudioStreamPropertyAvailablePhysicalFormats,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	UInt32 size = 0;
	OSStatus status = AudioObjectGetPropertyDataSize(streamID, &address, 0, NULL, &size);
	if(status != noErr || size < sizeof(AudioStreamRangedDescription)) {
		const UInt32 currentContainerBits = AudioFormatBytesPerSample(currentFormat) * 8;
		const BOOL currentSupportsDoP = !requireDoPCarrier ||
		                                ((currentFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
		                                 (currentFormat.mBitsPerChannel == 24 || currentFormat.mBitsPerChannel == 32) &&
		                                 (currentContainerBits == 24 || currentContainerBits == 32) &&
		                                 (currentContainerBits == currentFormat.mBitsPerChannel ||
		                                  (currentFormat.mFormatFlags & kAudioFormatFlagIsAlignedHigh)));
		if(AudioFormatIsIntegerPCM(currentFormat) &&
		   !(currentFormat.mFormatFlags & kAudioFormatFlagIsNonMixable) &&
		   currentSupportsDoP &&
		   currentFormat.mBitsPerChannel >= requiredBits &&
		   fabs(currentFormat.mSampleRate - sampleRate) < 1.0) {
			if(selectedFormat) *selectedFormat = currentFormat;
			return YES;
		}
		return NO;
	}

	AudioStreamRangedDescription *descriptions = (AudioStreamRangedDescription *)malloc(size);
	if(!descriptions) return NO;
	status = AudioObjectGetPropertyData(streamID, &address, 0, NULL, &size, descriptions);
	if(status != noErr) {
		free(descriptions);
		return NO;
	}
	BOOL found = NO;
	uint64_t bestScore = UINT64_MAX;
	AudioStreamBasicDescription bestFormat = { 0 };
	const UInt32 count = size / (UInt32)sizeof(AudioStreamRangedDescription);
	for(UInt32 i = 0; i < count; ++i) {
		AudioStreamBasicDescription candidate = descriptions[i].mFormat;
		const UInt32 bytesPerSample = AudioFormatBytesPerSample(candidate);
		const UInt32 containerBits = bytesPerSample * 8;
		if(!RangedPhysicalFormatSupportsSampleRate(descriptions[i], sampleRate) ||
		   !AudioFormatIsIntegerPCM(candidate) ||
		   (candidate.mFormatFlags & kAudioFormatFlagIsNonMixable) ||
		   (requireDoPCarrier &&
		    (!(candidate.mFormatFlags & kAudioFormatFlagIsSignedInteger) ||
		     (candidate.mBitsPerChannel != 24 && candidate.mBitsPerChannel != 32) ||
		     (containerBits != 24 && containerBits != 32) ||
		     (containerBits != candidate.mBitsPerChannel &&
		      !(candidate.mFormatFlags & kAudioFormatFlagIsAlignedHigh)))) ||
		   candidate.mBitsPerChannel < requiredBits ||
		   candidate.mBitsPerChannel > containerBits ||
		   !bytesPerSample || bytesPerSample > 8 ||
		   candidate.mChannelsPerFrame != currentFormat.mChannelsPerFrame) continue;

		// Match the source precision first, then prefer the least padded
		// container. Non-mixable variants were excluded above because AUHAL does
		// not own the device exclusively. Thus native Int16 wins over a wider
		// Int24/Int32 mode when the DAC genuinely exposes Int16.
		uint64_t score = (uint64_t)(candidate.mBitsPerChannel - requiredBits) * UINT64_C(1000000);
		score += containerBits - candidate.mBitsPerChannel;
		if(!(candidate.mFormatFlags & kAudioFormatFlagIsSignedInteger)) score += 1;
		if(!found || score < bestScore) {
			found = YES;
			bestScore = score;
			bestFormat = candidate;
			bestFormat.mSampleRate = sampleRate;
		}
	}
	free(descriptions);
	if(found && selectedFormat) *selectedFormat = bestFormat;
	return found;
}

- (NSDictionary<NSNumber *, NSValue *> *)integerPhysicalFormatSetForSampleRate:(double)sampleRate
	                                                               requiredBits:(UInt32)requiredBits
	                                                          requireDoPCarrier:(BOOL)requireDoPCarrier {
	NSArray<NSNumber *> *streams = [self activeOutputPhysicalStreams];
	if(!streams.count) return nil;
	NSMutableDictionary<NSNumber *, NSValue *> *formats = [NSMutableDictionary dictionary];
	for(NSNumber *streamNumber in streams) {
		AudioStreamBasicDescription format = { 0 };
		if(![self findIntegerPhysicalFormatForPhysicalStream:streamNumber.unsignedIntValue
		                                           sampleRate:sampleRate
		                                         requiredBits:requiredBits
		                                    requireDoPCarrier:requireDoPCarrier
		                                                format:&format]) return nil;
		formats[streamNumber] = PhysicalFormatValue(format);
	}
	return formats;
}

- (BOOL)setStreamFormatSet:(NSDictionary<NSNumber *, NSValue *> *)formats
	                selector:(AudioObjectPropertySelector)selector {
	for(NSNumber *streamNumber in formats) {
		AudioStreamBasicDescription format = { 0 };
		if(!GetPhysicalFormatValue(formats[streamNumber], &format) ||
		   ![self setStreamFormat:format onStream:streamNumber.unsignedIntValue selector:selector]) return NO;
	}
	for(NSNumber *streamNumber in formats) {
		AudioStreamBasicDescription expected = { 0 }, current = { 0 };
		if(!GetPhysicalFormatValue(formats[streamNumber], &expected) ||
		   ![self readStreamFormat:&current fromStream:streamNumber.unsignedIntValue selector:selector] ||
		   !PhysicalFormatsMatch(current, expected)) return NO;
	}
	return YES;
}

- (BOOL)setPhysicalFormatSet:(NSDictionary<NSNumber *, NSValue *> *)formats {
	return [self setStreamFormatSet:formats selector:kAudioStreamPropertyPhysicalFormat];
}

- (BOOL)setVirtualFormatSet:(NSDictionary<NSNumber *, NSValue *> *)formats {
	return [self setStreamFormatSet:formats selector:kAudioStreamPropertyVirtualFormat];
}

- (BOOL)findMixableFormatForStream:(AudioStreamID)streamID
	                     currentFormat:(AudioStreamBasicDescription)currentFormat
	                 availableSelector:(AudioObjectPropertySelector)availableSelector
	                            format:(AudioStreamBasicDescription *)selectedFormat {
	AudioObjectPropertyAddress address = {
		.mSelector = availableSelector,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	UInt32 size = 0;
	OSStatus status = AudioObjectGetPropertyDataSize(streamID, &address, 0, NULL, &size);
	if(status != noErr || size < sizeof(AudioStreamRangedDescription)) return NO;

	AudioStreamRangedDescription *descriptions = (AudioStreamRangedDescription *)malloc(size);
	if(!descriptions) return NO;
	status = AudioObjectGetPropertyData(streamID, &address, 0, NULL, &size, descriptions);
	if(status != noErr) {
		free(descriptions);
		return NO;
	}

	BOOL found = NO;
	uint64_t bestScore = UINT64_MAX;
	AudioStreamBasicDescription bestFormat = { 0 };
	const BOOL currentIsFloat = !!(currentFormat.mFormatFlags & kAudioFormatFlagIsFloat);
	const BOOL currentIsSigned = !!(currentFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger);
	const UInt32 currentBytes = AudioFormatBytesPerSample(currentFormat);
	const UInt32 count = size / (UInt32)sizeof(AudioStreamRangedDescription);
	for(UInt32 i = 0; i < count; ++i) {
		AudioStreamBasicDescription candidate = descriptions[i].mFormat;
		const UInt32 candidateBytes = AudioFormatBytesPerSample(candidate);
		if(!RangedPhysicalFormatSupportsSampleRate(descriptions[i], currentFormat.mSampleRate) ||
		   candidate.mFormatID != kAudioFormatLinearPCM ||
		   (candidate.mFormatFlags & kAudioFormatFlagIsNonMixable) ||
		   !candidateBytes ||
		   candidate.mFramesPerPacket != 1 ||
		   candidate.mChannelsPerFrame != currentFormat.mChannelsPerFrame) continue;

		// Prefer the exact shared-mode twin of the current representation. If a
		// driver does not expose one, choose its closest mixable PCM format at the
		// same clock so AUHAL can attach and perform its normal safe fallback.
		const BOOL candidateIsFloat = !!(candidate.mFormatFlags & kAudioFormatFlagIsFloat);
		const BOOL candidateIsSigned = !!(candidate.mFormatFlags & kAudioFormatFlagIsSignedInteger);
		const uint64_t bitDelta = currentFormat.mBitsPerChannel > candidate.mBitsPerChannel ?
		                                  currentFormat.mBitsPerChannel - candidate.mBitsPerChannel :
		                                  candidate.mBitsPerChannel - currentFormat.mBitsPerChannel;
		const uint64_t byteDelta = currentBytes > candidateBytes ?
		                                   currentBytes - candidateBytes : candidateBytes - currentBytes;
		uint64_t score = (candidateIsFloat != currentIsFloat) ? UINT64_C(1000000000000) : 0;
		score += (candidateIsSigned != currentIsSigned) ? UINT64_C(1000000000) : 0;
		score += bitDelta * UINT64_C(1000000);
		score += byteDelta * UINT64_C(1000);
		if(!!(candidate.mFormatFlags & kAudioFormatFlagIsBigEndian) !=
		   !!(currentFormat.mFormatFlags & kAudioFormatFlagIsBigEndian)) score += 100;
		if(!!(candidate.mFormatFlags & kAudioFormatFlagIsPacked) !=
		   !!(currentFormat.mFormatFlags & kAudioFormatFlagIsPacked)) score += 10;
		if(!!(candidate.mFormatFlags & kAudioFormatFlagIsAlignedHigh) !=
		   !!(currentFormat.mFormatFlags & kAudioFormatFlagIsAlignedHigh)) score += 1;

		if(!found || score < bestScore) {
			found = YES;
			bestScore = score;
			bestFormat = candidate;
			bestFormat.mSampleRate = currentFormat.mSampleRate;
		}
	}
	free(descriptions);
	if(found && selectedFormat) *selectedFormat = bestFormat;
	return found;
}

- (BOOL)ensureMixableStreamFormatsForAUHAL {
	NSArray<NSNumber *> *streams = [self activeOutputPhysicalStreams];
	if(!streams.count) return YES;

	const AudioObjectPropertySelector currentSelectors[] = {
		kAudioStreamPropertyPhysicalFormat,
		kAudioStreamPropertyVirtualFormat,
	};
	const AudioObjectPropertySelector availableSelectors[] = {
		kAudioStreamPropertyAvailablePhysicalFormats,
		kAudioStreamPropertyAvailableVirtualFormats,
	};
	for(size_t selectorIndex = 0; selectorIndex < 2; ++selectorIndex) {
		NSMutableDictionary<NSNumber *, NSValue *> *mixableFormats = [NSMutableDictionary dictionary];
		for(NSNumber *streamNumber in streams) {
			const AudioStreamID streamID = streamNumber.unsignedIntValue;
			AudioStreamBasicDescription current = { 0 };
			if(![self readStreamFormat:&current fromStream:streamID selector:currentSelectors[selectorIndex]]) return NO;
			if(!(current.mFormatFlags & kAudioFormatFlagIsNonMixable)) continue;

			AudioStreamBasicDescription mixableFormat = { 0 };
			if(![self findMixableFormatForStream:streamID
			                            currentFormat:current
			                        availableSelector:availableSelectors[selectorIndex]
			                                   format:&mixableFormat]) {
				return NO;
			}
			mixableFormats[streamNumber] = PhysicalFormatValue(mixableFormat);
		}
		if(mixableFormats.count &&
		   ![self setStreamFormatSet:mixableFormats selector:currentSelectors[selectorIndex]]) return NO;
	}
	return YES;
}

- (BOOL)ensureAUHALBoundToOutputDevice {
	if(!_au || outputDeviceID == kAudioObjectUnknown || outputDeviceID == (AudioDeviceID)-1) return NO;
	if(_au.deviceID == outputDeviceID) return YES;

	NSError *error = nil;
	if(![_au setDeviceID:outputDeviceID error:&error] || error != nil || _au.deviceID != outputDeviceID) {
		ALog(@"Unable to bind AUHAL to output device %u (actual device %u): %@",
		     (unsigned int)outputDeviceID,
		     (unsigned int)_au.deviceID,
		     error);
		return NO;
	}
	return YES;
}

- (BOOL)exclusiveOutputLayoutSupportsClientFormat:(AudioStreamBasicDescription)clientFormat {
	NSArray<NSNumber *> *streams = [self activeOutputPhysicalStreams];
	if(streams.count != 1) return NO;

	AudioStreamBasicDescription virtualFormat = { 0 };
	if(![self readVirtualFormat:&virtualFormat fromStream:streams.firstObject.unsignedIntValue] ||
	   !StreamFormatsHaveSameSampleRepresentation(clientFormat, virtualFormat, NO) ||
	   virtualFormat.mChannelsPerFrame != clientFormat.mChannelsPerFrame) return NO;

	AudioObjectPropertyAddress address = {
		.mSelector = kAudioDevicePropertyStreamConfiguration,
		.mScope = kAudioDevicePropertyScopeOutput,
		.mElement = kAudioObjectPropertyElementMaster
	};
	UInt32 size = 0;
	if(AudioObjectGetPropertyDataSize(outputDeviceID, &address, 0, NULL, &size) != noErr ||
	   size < sizeof(AudioBufferList)) return NO;
	AudioBufferList *configuration = (AudioBufferList *)malloc(size);
	if(!configuration) return NO;
	OSStatus status = AudioObjectGetPropertyData(outputDeviceID, &address, 0, NULL, &size, configuration);
	const BOOL supported = status == noErr && configuration->mNumberBuffers == 1 &&
	                       configuration->mBuffers[0].mNumberChannels == clientFormat.mChannelsPerFrame;
	free(configuration);
	return supported;
}

- (UInt32)maximumFramesForExclusiveIOProc {
	UInt32 maximumFrames = 0;
	AudioObjectPropertyAddress address = {
		.mSelector = kAudioDevicePropertyBufferFrameSize,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	UInt32 size = sizeof(maximumFrames);
	AudioObjectGetPropertyData(outputDeviceID, &address, 0, NULL, &size, &maximumFrames);

	address.mSelector = kAudioDevicePropertyBufferFrameSizeRange;
	AudioValueRange range = { 0 };
	size = sizeof(range);
	if(AudioObjectGetPropertyData(outputDeviceID, &address, 0, NULL, &size, &range) == noErr &&
	   range.mMaximum > 0.0 && range.mMaximum <= UINT32_MAX) {
		maximumFrames = MAX(maximumFrames, (UInt32)ceil(range.mMaximum));
	}
	return maximumFrames;
}

- (void)setDeviceVolumeTo100ForExclusiveOutputIfSupported {
	if(!setDeviceVolumeTo100ForExclusiveOutput ||
	   outputDeviceID == kAudioObjectUnknown || outputDeviceID == (AudioDeviceID)-1) return;

	// The virtual main control maps to a device's main volume when present, or
	// to its relevant per-channel controls while preserving their balance.
	const AudioObjectPropertySelector selectors[] = {
		kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
		kAudioDevicePropertyVolumeScalar,
	};
	BOOL foundSettableControl = NO;
	OSStatus lastStatus = noErr;
	for(size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); ++i) {
		AudioObjectPropertyAddress address = {
			.mSelector = selectors[i],
			.mScope = kAudioDevicePropertyScopeOutput,
			.mElement = kAudioObjectPropertyElementMaster
		};
		if(!AudioObjectHasProperty(outputDeviceID, &address)) continue;

		Boolean settable = false;
		lastStatus = AudioObjectIsPropertySettable(outputDeviceID, &address, &settable);
		if(lastStatus != noErr || !settable) continue;
		foundSettableControl = YES;

		Float32 maximumVolume = 1.0f;
		lastStatus = AudioObjectSetPropertyData(outputDeviceID,
		                                            &address,
		                                            0,
		                                            NULL,
		                                            sizeof(maximumVolume),
		                                            &maximumVolume);
		if(lastStatus == noErr) {
			DLog(@"Set output device %u volume to 100%% for exclusive output",
			     (unsigned int)outputDeviceID);
			return;
		}
	}

	if(foundSettableControl) {
		ALog(@"Unable to set output device %u volume to 100%% for exclusive output: %d",
		     (unsigned int)outputDeviceID, (int)lastStatus);
	}
}

- (BOOL)createExclusiveIOProc {
	if(exclusiveIOProcID) {
		return exclusiveIOProcDeviceID == outputDeviceID;
	}
	if(!_outputRenderBlock || ![self exclusiveOutputLayoutSupportsClientFormat:renderFormat]) return NO;

	exclusiveMaximumFramesToRender = [self maximumFramesForExclusiveIOProc];
	if(!exclusiveMaximumFramesToRender || ![self prepareOutputDoubleScratchForRenderFormat:renderFormat]) {
		exclusiveMaximumFramesToRender = 0;
		return NO;
	}

	const UInt32 bytesPerFrame = renderFormat.mBytesPerFrame;
	const UInt32 channels = renderFormat.mChannelsPerFrame;
	AURenderPullInputBlock renderBlock = [_outputRenderBlock copy];
	AudioDeviceIOProcID ioProcID = NULL;
	OSStatus status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID,
	                                                    outputDeviceID,
	                                                    NULL,
	                                                    ^(const AudioTimeStamp *inNow,
	                                                      const AudioBufferList *inInputData,
	                                                      const AudioTimeStamp *inInputTime,
	                                                      AudioBufferList *outOutputData,
	                                                      const AudioTimeStamp *inOutputTime) {
		if(!outOutputData || outOutputData->mNumberBuffers != 1 ||
		   !outOutputData->mBuffers[0].mData ||
		   outOutputData->mBuffers[0].mNumberChannels != channels || !bytesPerFrame) return;
		const AUAudioFrameCount frameCount = outOutputData->mBuffers[0].mDataByteSize / bytesPerFrame;
		if(!frameCount) return;
		AudioUnitRenderActionFlags actionFlags = 0;
		const AudioTimeStamp *timestamp = inOutputTime ?: inNow;
		renderBlock(&actionFlags, timestamp, frameCount, 0, outOutputData);
	});
	if(status != noErr || !ioProcID) {
		ALog(@"Unable to create direct HAL output callback for device %u: %d",
		     (unsigned int)outputDeviceID, (int)status);
		exclusiveMaximumFramesToRender = 0;
		return NO;
	}

	exclusiveIOProcID = ioProcID;
	exclusiveIOProcDeviceID = outputDeviceID;
	exclusiveIOProcRunning = NO;
	return YES;
}

- (void)destroyExclusiveIOProc {
	if(!exclusiveIOProcID) return;
	if(exclusiveIOProcRunning) {
		AudioDeviceStop(exclusiveIOProcDeviceID, exclusiveIOProcID);
		exclusiveIOProcRunning = NO;
	}
	OSStatus status = AudioDeviceDestroyIOProcID(exclusiveIOProcDeviceID, exclusiveIOProcID);
	if(status != noErr) {
		ALog(@"Unable to destroy direct HAL output callback for device %u: %d",
		     (unsigned int)exclusiveIOProcDeviceID, (int)status);
	}
	exclusiveIOProcID = NULL;
	exclusiveIOProcDeviceID = kAudioObjectUnknown;
	exclusiveMaximumFramesToRender = 0;
}

- (BOOL)startCurrentHardware:(NSError **)error {
	if(exclusiveIOProcID) {
		if(exclusiveIOProcRunning) {
			[self setDeviceVolumeTo100ForExclusiveOutputIfSupported];
			return YES;
		}
		OSStatus status = AudioDeviceStart(exclusiveIOProcDeviceID, exclusiveIOProcID);
		if(status == noErr) {
			exclusiveIOProcRunning = YES;
			[self setDeviceVolumeTo100ForExclusiveOutputIfSupported];
			return YES;
		}
		if(error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
		return NO;
	}
	return [_au startHardwareAndReturnError:error];
}

- (void)stopCurrentHardware {
	if(exclusiveIOProcID) {
		if(exclusiveIOProcRunning) {
			AudioDeviceStop(exclusiveIOProcDeviceID, exclusiveIOProcID);
			exclusiveIOProcRunning = NO;
		}
		return;
	}
	[_au stopHardware];
}

- (BOOL)hogModeOwner:(pid_t *)owner forDevice:(AudioDeviceID)deviceID {
	if(!owner || deviceID == kAudioObjectUnknown || deviceID == (AudioDeviceID)-1) return NO;
	AudioObjectPropertyAddress address = {
		.mSelector = kAudioDevicePropertyHogMode,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	if(!AudioObjectHasProperty(deviceID, &address)) return NO;
	UInt32 size = sizeof(*owner);
	*owner = -1;
	return AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, owner) == noErr &&
	       size == sizeof(*owner);
}

- (BOOL)currentProcessOwnsHogMode {
	pid_t owner = -1;
	return [self hogModeOwner:&owner forDevice:outputDeviceID] && owner == getpid();
}

- (BOOL)acquireHogModeForCurrentDevice {
	pid_t owner = -1;
	if(![self hogModeOwner:&owner forDevice:outputDeviceID]) return NO;
	if(owner == getpid()) {
		hogModeOwned = YES;
		hogModeDeviceID = outputDeviceID;
		return YES;
	}
	if(owner != -1) return NO;

	AudioObjectPropertyAddress address = {
		.mSelector = kAudioDevicePropertyHogMode,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	Boolean settable = false;
	if(AudioObjectIsPropertySettable(outputDeviceID, &address, &settable) != noErr || !settable) return NO;
	pid_t request = getpid();
	if(AudioObjectSetPropertyData(outputDeviceID, &address, 0, NULL, sizeof(request), &request) != noErr ||
	   ![self hogModeOwner:&owner forDevice:outputDeviceID] || owner != getpid()) return NO;
	hogModeOwned = YES;
	hogModeDeviceID = outputDeviceID;
	return YES;
}

- (BOOL)releaseHogModeForCurrentDevice {
	if(!hogModeOwned || hogModeDeviceID != outputDeviceID) return YES;
	pid_t owner = -1;
	if(![self hogModeOwner:&owner forDevice:outputDeviceID]) return NO;
	if(owner != getpid()) {
		hogModeOwned = NO;
		hogModeDeviceID = kAudioObjectUnknown;
		return owner == -1;
	}

	AudioObjectPropertyAddress address = {
		.mSelector = kAudioDevicePropertyHogMode,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	pid_t request = getpid();
	if(AudioObjectSetPropertyData(outputDeviceID, &address, 0, NULL, sizeof(request), &request) != noErr ||
	   ![self hogModeOwner:&owner forDevice:outputDeviceID] || owner == getpid()) return NO;
	hogModeOwned = NO;
	hogModeDeviceID = kAudioObjectUnknown;
	return YES;
}

- (BOOL)currentOutputUsesExclusiveTransport {
	if(!exclusiveIOProcID || exclusiveIOProcDeviceID != outputDeviceID) return NO;
	const AudioStreamBasicDescription clientFormat = renderFormat;

	NSArray<NSNumber *> *streams = [self activeOutputPhysicalStreams];
	if(!streams.count) return NO;
	for(NSNumber *streamNumber in streams) {
		AudioStreamBasicDescription virtualFormat = { 0 };
		const AudioStreamID streamID = streamNumber.unsignedIntValue;
		if(![self readVirtualFormat:&virtualFormat fromStream:streamID] ||
		   !StreamFormatsHaveSameSampleRepresentation(clientFormat, virtualFormat, NO) ||
		   fabs(clientFormat.mSampleRate - virtualFormat.mSampleRate) >= 1.0) return NO;
	}
	return [self currentProcessOwnsHogMode];
}

- (BOOL)currentOutputIsEndToEndInteger {
	if(![self currentOutputUsesExclusiveTransport] || !AudioFormatIsSignedIntegerPCM(renderFormat)) return NO;

	NSArray<NSNumber *> *streams = [self activeOutputPhysicalStreams];
	for(NSNumber *streamNumber in streams) {
		AudioStreamBasicDescription virtualFormat = { 0 }, physicalFormat = { 0 };
		const AudioStreamID streamID = streamNumber.unsignedIntValue;
		if(![self readVirtualFormat:&virtualFormat fromStream:streamID] ||
		   ![self readPhysicalFormat:&physicalFormat fromStream:streamID] ||
		   !AudioFormatIsSignedIntegerPCM(virtualFormat) ||
		   !AudioFormatIsSignedIntegerPCM(physicalFormat) ||
		   !PhysicalFormatsMatch(virtualFormat, physicalFormat) ||
		   !(virtualFormat.mFormatFlags & kAudioFormatFlagIsNonMixable)) return NO;
	}
	return YES;
}

- (BOOL)applyPreferredVirtualFormatSetAtSampleRate:(double)sampleRate {
	NSDictionary<NSNumber *, NSValue *> *preferredVirtualFormats = preferExclusiveIntegerTransport ?
	                                                                  preferredIntegerVirtualFormats :
	                                                                  (preferExclusiveFloatTransport ? preferredFloatVirtualFormats : nil);
	if(preferredVirtualFormats.count) {
		NSArray<NSNumber *> *streams = preferredVirtualFormats.allKeys;
		NSDictionary<NSNumber *, NSValue *> *currentFormats = [self currentVirtualFormatSetForStreams:streams];
		if(currentFormats.count != preferredVirtualFormats.count) return NO;
		BOOL alreadyConfigured = YES;
		for(NSNumber *streamNumber in preferredVirtualFormats) {
			AudioStreamBasicDescription current = { 0 }, target = { 0 };
			if(!GetPhysicalFormatValue(currentFormats[streamNumber], &current) ||
			   !GetPhysicalFormatValue(preferredVirtualFormats[streamNumber], &target)) return NO;
			target.mSampleRate = sampleRate;
			if(!PhysicalFormatsMatch(current, target)) alreadyConfigured = NO;
		}
		if(alreadyConfigured) return YES;

		const BOOL capturedOriginal = !savedVirtualFormatValid;
		if(capturedOriginal) {
			savedVirtualFormatValid = YES;
			savedVirtualFormatDeviceID = outputDeviceID;
			savedVirtualFormats = currentFormats;
		}
		if([self setVirtualFormatSet:preferredVirtualFormats]) return YES;
		if(capturedOriginal) {
			savedVirtualFormatValid = NO;
			savedVirtualFormats = nil;
		}
		return NO;
	}

	if(!savedVirtualFormatValid || savedVirtualFormatDeviceID != outputDeviceID) return YES;
	NSMutableDictionary<NSNumber *, NSValue *> *restoreFormats = [NSMutableDictionary dictionary];
	for(NSNumber *streamNumber in savedVirtualFormats) {
		AudioStreamBasicDescription representation = { 0 }, restoreFormat = { 0 };
		if(!GetPhysicalFormatValue(savedVirtualFormats[streamNumber], &representation) ||
		   ![self findVirtualFormatMatchingRepresentation:representation
		                                     atSampleRate:sampleRate
		                                         streamID:streamNumber.unsignedIntValue
		                                            format:&restoreFormat]) return NO;
		restoreFormats[streamNumber] = PhysicalFormatValue(restoreFormat);
	}
	if(![self setVirtualFormatSet:restoreFormats]) return NO;
	savedVirtualFormatValid = NO;
	savedVirtualFormats = nil;
	return YES;
}

- (BOOL)restoreSavedVirtualFormatSetAtCurrentSampleRate {
	if(!savedVirtualFormatValid || savedVirtualFormatDeviceID != outputDeviceID) return YES;
	const BOOL previousIntegerPreference = preferExclusiveIntegerTransport;
	const BOOL previousFloatPreference = preferExclusiveFloatTransport;
	preferExclusiveIntegerTransport = NO;
	preferExclusiveFloatTransport = NO;
	const double sampleRate = [self currentDeviceSampleRate];
	const BOOL restored = sampleRate > 0.0 && [self applyPreferredVirtualFormatSetAtSampleRate:sampleRate];
	preferExclusiveIntegerTransport = previousIntegerPreference;
	preferExclusiveFloatTransport = previousFloatPreference;
	return restored;
}

- (BOOL)applyPreferredPhysicalFormatSetAtSampleRate:(double)sampleRate {
	if(preferIntegerPhysicalOutput) {
		NSArray<NSNumber *> *streams = preferredIntegerPhysicalFormats.allKeys;
		NSDictionary<NSNumber *, NSValue *> *currentFormats = [self currentPhysicalFormatSetForStreams:streams];
		if(currentFormats.count != preferredIntegerPhysicalFormats.count) return NO;
		BOOL alreadyConfigured = YES;
		for(NSNumber *streamNumber in preferredIntegerPhysicalFormats) {
			AudioStreamBasicDescription current = { 0 }, target = { 0 };
			if(!GetPhysicalFormatValue(currentFormats[streamNumber], &current) ||
			   !GetPhysicalFormatValue(preferredIntegerPhysicalFormats[streamNumber], &target)) return NO;
			target.mSampleRate = sampleRate;
			if(!PhysicalFormatsMatch(current, target)) alreadyConfigured = NO;
		}
		if(alreadyConfigured) return YES;

		const BOOL capturedOriginal = !savedPhysicalFormatValid;
		if(capturedOriginal) {
			savedPhysicalFormatValid = YES;
			savedPhysicalFormatDeviceID = outputDeviceID;
			savedPhysicalFormats = currentFormats;
		}
		if([self setPhysicalFormatSet:preferredIntegerPhysicalFormats]) return YES;
		if(capturedOriginal) {
			savedPhysicalFormatValid = NO;
			savedPhysicalFormats = nil;
		}
		return NO;
	}

	if(!savedPhysicalFormatValid || savedPhysicalFormatDeviceID != outputDeviceID) return YES;
	NSMutableDictionary<NSNumber *, NSValue *> *restoreFormats = [NSMutableDictionary dictionary];
	for(NSNumber *streamNumber in savedPhysicalFormats) {
		AudioStreamBasicDescription representation = { 0 }, restoreFormat = { 0 };
		if(!GetPhysicalFormatValue(savedPhysicalFormats[streamNumber], &representation) ||
		   ![self findPhysicalFormatMatchingRepresentation:representation
		                                      atSampleRate:sampleRate
		                                          streamID:streamNumber.unsignedIntValue
		                                             format:&restoreFormat]) return NO;
		restoreFormats[streamNumber] = PhysicalFormatValue(restoreFormat);
	}
	if(![self setPhysicalFormatSet:restoreFormats]) return NO;
	savedPhysicalFormatValid = NO;
	savedPhysicalFormats = nil;
	return YES;
}

- (BOOL)restoreSavedPhysicalFormatSetAtCurrentSampleRate {
	if(!savedPhysicalFormatValid || savedPhysicalFormatDeviceID != outputDeviceID) return YES;
	const BOOL previousPreference = preferIntegerPhysicalOutput;
	preferIntegerPhysicalOutput = NO;
	const double sampleRate = [self currentDeviceSampleRate];
	const BOOL restored = sampleRate > 0.0 && [self applyPreferredPhysicalFormatSetAtSampleRate:sampleRate];
	preferIntegerPhysicalOutput = previousPreference;
	return restored;
}

- (void)configureSharedIntegerOutputAtSampleRate:(double)sampleRate
	                                  requiredBits:(UInt32)requiredBits
	                             requireDoPCarrier:(BOOL)requireDoPCarrier {
	preferExclusiveFloatTransport = NO;
	preferredFloatVirtualFormats = nil;
	bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
	preferExclusiveIntegerTransport = NO;
	preferredIntegerTransportRequiresHog = NO;
	preferredIntegerVirtualFormats = nil;
	preferredIntegerPhysicalFormats = [self integerPhysicalFormatSetForSampleRate:sampleRate
	                                                                  requiredBits:requiredBits
	                                                             requireDoPCarrier:requireDoPCarrier];
	preferIntegerPhysicalOutput = preferredIntegerPhysicalFormats.count > 0;
	if(!preferIntegerPhysicalOutput) {
		preferredIntegerPhysicalFormats = nil;
		bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));
	} else if(requireDoPCarrier) {
		preferredIntegerClientFormat = DoPIntegerRenderFormatForDeviceFormat(deviceFormat);
	} else {
		preferredIntegerClientFormat = IntegerClientFormatForSourceBits(requiredBits,
		                                                              sampleRate,
		                                                              deviceFormat.mChannelsPerFrame);
	}
}

- (void)configurePreferredIntegerOutputAtSampleRate:(double)sampleRate
	                                     requiredBits:(UInt32)requiredBits
	                                requireDoPCarrier:(BOOL)requireDoPCarrier {
	preferExclusiveFloatTransport = NO;
	preferredFloatVirtualFormats = nil;
	bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
	if(exclusiveOutputEnabled) {
		NSDictionary<NSNumber *, NSValue *> *virtualFormats = nil;
		NSDictionary<NSNumber *, NSValue *> *physicalFormats = nil;
		AudioStreamBasicDescription clientFormat = { 0 };
		BOOL requiresHog = NO;
		if([self findEndToEndIntegerFormatSetsForSampleRate:sampleRate
		                                          requiredBits:requiredBits
		                                     requireDoPCarrier:requireDoPCarrier
		                                        virtualFormats:&virtualFormats
		                                       physicalFormats:&physicalFormats
		                                           clientFormat:&clientFormat
		                                            requiresHog:&requiresHog]) {
			preferExclusiveIntegerTransport = YES;
			preferredIntegerTransportRequiresHog = requiresHog;
			preferredIntegerVirtualFormats = virtualFormats;
			preferredIntegerPhysicalFormats = physicalFormats;
			preferredIntegerClientFormat = clientFormat;
			preferIntegerPhysicalOutput = YES;
			return;
		}
	}
	[self configureSharedIntegerOutputAtSampleRate:sampleRate
	                                      requiredBits:requiredBits
	                                 requireDoPCarrier:requireDoPCarrier];
}

- (void)configurePreferredFloatOutputForInputFormat:(AudioStreamBasicDescription)inputFormat
	                                      sampleRate:(double)sampleRate {
	preferExclusiveFloatTransport = NO;
	preferredFloatVirtualFormats = nil;
	bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
	if(!exclusiveOutputEnabled) return;

	NSDictionary<NSNumber *, NSValue *> *virtualFormats = nil;
	AudioStreamBasicDescription clientFormat = { 0 };
	if([self findExclusiveFloatVirtualFormatSetForInputFormat:inputFormat
	                                              sampleRate:sampleRate
	                                           virtualFormats:&virtualFormats
	                                              clientFormat:&clientFormat]) {
		preferExclusiveFloatTransport = YES;
		preferredFloatVirtualFormats = virtualFormats;
		preferredFloatClientFormat = clientFormat;
	}
}

- (void)configurePreferredFloatOutputForConvertedDSDInputFormat:(AudioStreamBasicDescription)inputFormat
	                                                sampleRate:(double)sampleRate {
	// DSD-to-PCM conversion produces Float64 internally. Prefer an equally precise
	// direct device stream, but allow Float32 when that is the only float client
	// representation exposed by the device (as with Apple USB-C EarPods). The
	// render callback already performs the final Float64-to-Float32 conversion.
	AudioStreamBasicDescription convertedPCMFormat = AudioFormatAsFloat64(inputFormat);
	convertedPCMFormat.mSampleRate = sampleRate;
	[self configurePreferredFloatOutputForInputFormat:convertedPCMFormat sampleRate:sampleRate];
	if(preferExclusiveFloatTransport) return;

	convertedPCMFormat = AudioFormatAsFloat32(convertedPCMFormat);
	[self configurePreferredFloatOutputForInputFormat:convertedPCMFormat sampleRate:sampleRate];
}

- (BOOL)deviceSupportsSampleRate:(double)sampleRate {
	NSNumber *cacheKey = @(sampleRate);
	@synchronized(sampleRateSupportCache) {
		NSNumber *cached = sampleRateSupportCache[cacheKey];
		if(cached) {
			return [cached boolValue];
		}
	}

	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioDevicePropertyAvailableNominalSampleRates,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};

	UInt32 propsize = 0;
	OSStatus status = AudioObjectGetPropertyDataSize(outputDeviceID, &theAddress, 0, NULL, &propsize);
	if(status != noErr || !propsize) {
		return YES;
	}

	AudioValueRange *ranges = (AudioValueRange *)malloc(propsize);
	if(!ranges) {
		return NO;
	}

	status = AudioObjectGetPropertyData(outputDeviceID, &theAddress, 0, NULL, &propsize, ranges);
	if(status != noErr) {
		free(ranges);
		return YES;
	}

	const UInt32 rangeCount = propsize / (UInt32)sizeof(AudioValueRange);
	BOOL supported = NO;
	for(UInt32 i = 0; i < rangeCount; ++i) {
		if(sampleRate >= ranges[i].mMinimum - 1.0 && sampleRate <= ranges[i].mMaximum + 1.0) {
			supported = YES;
			break;
		}
	}

	free(ranges);
	@synchronized(sampleRateSupportCache) {
		sampleRateSupportCache[cacheKey] = @(supported);
	}
	return supported;
}

- (double)bestPCMDeviceSampleRateForDSDInputFormat:(AudioStreamBasicDescription)inputFormat {
	if(inputFormat.mBitsPerChannel != 1 || inputFormat.mSampleRate <= 0.0 ||
	   outputDeviceID == (AudioDeviceID)-1) {
		return 0.0;
	}

	// The DSD decoder's first PCM representation runs at one eighth of the
	// 1-bit source clock. Rates above it add no source information, so prefer
	// its power-of-two family (352.8, 176.4, 88.2, 44.1 kHz for DSD64) when the
	// device exposes an exact match at or below that rate.
	const double decodedPCMRate = inputFormat.mSampleRate / 8.0;
	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioDevicePropertyAvailableNominalSampleRates,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};

	UInt32 propsize = 0;
	OSStatus status = AudioObjectGetPropertyDataSize(outputDeviceID, &theAddress, 0, NULL, &propsize);
	if(status != noErr || !propsize) {
		return [self currentDeviceSampleRate];
	}

	AudioValueRange *ranges = (AudioValueRange *)malloc(propsize);
	if(!ranges) {
		return [self currentDeviceSampleRate];
	}
	status = AudioObjectGetPropertyData(outputDeviceID, &theAddress, 0, NULL, &propsize, ranges);
	if(status != noErr) {
		free(ranges);
		return [self currentDeviceSampleRate];
	}

	const UInt32 rangeCount = propsize / (UInt32)sizeof(AudioValueRange);
	double highestUsefulRate = 0.0;
	for(UInt32 i = 0; i < rangeCount; ++i) {
		if(ranges[i].mMinimum <= decodedPCMRate + 1.0) {
			highestUsefulRate = MAX(highestUsefulRate, MIN(ranges[i].mMaximum, decodedPCMRate));
		}
	}
	if(highestUsefulRate <= 0.0) {
		free(ranges);
		return [self currentDeviceSampleRate];
	}

	double matchingRate = decodedPCMRate;
	while(matchingRate > highestUsefulRate + 1.0) {
		matchingRate *= 0.5;
	}
	if([self deviceSupportsSampleRate:matchingRate]) {
		free(ranges);
		return matchingRate;
	}

	// Some devices advertise only 48 kHz-family rates. In that case choose the
	// supported rate nearest the ideal DSD-family target rather than dropping
	// all the way to a much lower 44.1 kHz-family rate.
	double closestRate = 0.0;
	double closestDistance = INFINITY;
	for(UInt32 i = 0; i < rangeCount; ++i) {
		if(ranges[i].mMinimum > decodedPCMRate + 1.0) {
			continue;
		}
		const double rangeMaximum = MIN(ranges[i].mMaximum, decodedPCMRate);
		const double candidate = MIN(MAX(matchingRate, ranges[i].mMinimum), rangeMaximum);
		const double distance = fabs(candidate - matchingRate);
		if(distance < closestDistance ||
		   (fabs(distance - closestDistance) < 1.0 && candidate > closestRate)) {
			closestRate = candidate;
			closestDistance = distance;
		}
	}

	free(ranges);
	return closestRate > 0.0 ? closestRate : [self currentDeviceSampleRate];
}

- (BOOL)setDeviceSampleRate:(double)sampleRate {
	if(outputDeviceID == (AudioDeviceID)-1 || sampleRate <= 0.0) {
		return NO;
	}

	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioDevicePropertyNominalSampleRate,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};

	Float64 currentRate = 0.0;
	UInt32 propsize = sizeof(currentRate);
	OSStatus status = AudioObjectGetPropertyData(outputDeviceID, &theAddress, 0, NULL, &propsize, &currentRate);
	if(status == noErr && fabs(currentRate - sampleRate) < 1.0) {
		return YES;
	}

	if(![self deviceSupportsSampleRate:sampleRate]) {
		return NO;
	}

	Float64 requestedRate = sampleRate;
	status = AudioObjectSetPropertyData(outputDeviceID, &theAddress, 0, NULL, sizeof(requestedRate), &requestedRate);
	if(status != noErr) {
		return NO;
	}

	for(size_t attempt = 0; attempt < 50; ++attempt) {
		currentRate = 0.0;
		propsize = sizeof(currentRate);
		status = AudioObjectGetPropertyData(outputDeviceID, &theAddress, 0, NULL, &propsize, &currentRate);
		if(status == noErr && fabs(currentRate - sampleRate) < 1.0) {
			return YES;
		}
		usleep(10000);
	}

	return NO;
}

- (double)currentDeviceSampleRate {
	if(outputDeviceID == (AudioDeviceID)-1) {
		return 0.0;
	}

	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioDevicePropertyNominalSampleRate,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	Float64 sampleRate = 0.0;
	UInt32 propsize = sizeof(sampleRate);
	OSStatus status = AudioObjectGetPropertyData(outputDeviceID, &theAddress, 0, NULL, &propsize, &sampleRate);
	return status == noErr ? sampleRate : 0.0;
}

- (BOOL)updateDeviceFormatLockedNotifyingController:(BOOL)notifyController requestedSampleRate:(double)requestedSampleRate {
	const BOOL targetDoPInteger = preferDoPIntegerOutput;
	const BOOL targetNativeHighPrecision = preferNativeHighPrecisionOutput && !targetDoPInteger;
	const BOOL targetIntegerPhysical = preferIntegerPhysicalOutput;
	const BOOL targetEndToEndInteger = preferExclusiveIntegerTransport;
	const BOOL targetExclusiveFloat = preferExclusiveFloatTransport && preferredFloatVirtualFormats.count > 0;
	const BOOL targetExclusiveTransport = targetEndToEndInteger || targetExclusiveFloat;
	AVAudioFormat *format = nil;
	if(targetEndToEndInteger) {
		AudioStreamBasicDescription exclusiveFormat = preferredIntegerClientFormat;
		if(requestedSampleRate > 0.0) exclusiveFormat.mSampleRate = requestedSampleRate;
		format = [[AVAudioFormat alloc] initWithStreamDescription:&exclusiveFormat];
	} else if(targetExclusiveFloat) {
		AudioStreamBasicDescription exclusiveFormat = preferredFloatClientFormat;
		if(requestedSampleRate > 0.0) exclusiveFormat.mSampleRate = requestedSampleRate;
		format = [[AVAudioFormat alloc] initWithStreamDescription:&exclusiveFormat];
	} else {
		format = _au.outputBusses[0].format;
	}
	if(!format) {
		return NO;
	}

	const BOOL nativeFormatChanged = targetNativeHighPrecision &&
	                                memcmp(&renderFormat, &preferredNativeHighPrecisionFormat, sizeof(renderFormat)) != 0;
	const BOOL integerPhysicalFormatChanged = targetIntegerPhysical &&
	                                          !PhysicalFormatsHaveSameRepresentation(renderFormat, preferredIntegerClientFormat);
	const BOOL requestedSampleRateChanged = requestedSampleRate > 0.0 &&
	                                        fabs(renderFormat.mSampleRate - requestedSampleRate) >= 1.0;
	if(outputDeviceIDChanged || !_deviceFormat || ![_deviceFormat isEqual:format] ||
	   renderFormatDoPInteger != targetDoPInteger ||
	   renderFormatNativeHighPrecision != targetNativeHighPrecision ||
	   renderFormatIntegerPhysical != targetIntegerPhysical ||
	   renderFormatEndToEndInteger != targetEndToEndInteger ||
	   nativeFormatChanged || integerPhysicalFormatChanged || requestedSampleRateChanged) {
		NSError *err = nil;
		AVAudioFormat *renderAVFormat;

		_deviceFormat = format;
		deviceFormat = *(format.streamDescription);
		const UInt32 bytesPerSample = AudioFormatBytesPerSample(deviceFormat);

		/// Seems some 3rd party devices return incorrect stuff...or I just don't like noninterleaved data.
		deviceFormat.mFormatFlags &= ~kLinearPCMFormatFlagIsNonInterleaved;
		if(requestedSampleRate > 0.0) {
			// The device's nominal clock changes before AUHAL necessarily refreshes
			// its output-bus AVAudioFormat. Bind the input bus to the clock requested
			// by this transaction instead of copying a stale DoP carrier rate.
			deviceFormat.mSampleRate = requestedSampleRate;
		} else if(preferDoPIntegerOutput && preferredDoPCarrierSampleRate > 0.0) {
			deviceFormat.mSampleRate = preferredDoPCarrierSampleRate;
		} else if(targetNativeHighPrecision && preferredNativeHighPrecisionFormat.mSampleRate > 0.0) {
			deviceFormat.mSampleRate = preferredNativeHighPrecisionFormat.mSampleRate;
		}
		//    deviceFormat.mFormatFlags &= ~kLinearPCMFormatFlagIsFloat;
		//    deviceFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger;
		// We don't want more than 8 channels
		if(deviceFormat.mChannelsPerFrame > 8) {
			deviceFormat.mChannelsPerFrame = 8;
		}
		deviceFormat.mBytesPerFrame = deviceFormat.mChannelsPerFrame * bytesPerSample;
		deviceFormat.mBytesPerPacket = deviceFormat.mBytesPerFrame * deviceFormat.mFramesPerPacket;

		/* Set the channel layout for the audio queue */
		AudioChannelLayoutTag tag = 0;
		switch(deviceFormat.mChannelsPerFrame) {
			case 1:
				tag = kAudioChannelLayoutTag_Mono;
				deviceChannelConfig = AudioConfigMono;
				break;
			case 2:
				tag = kAudioChannelLayoutTag_Stereo;
				deviceChannelConfig = AudioConfigStereo;
				break;
			case 3:
				tag = kAudioChannelLayoutTag_DVD_4;
				deviceChannelConfig = AudioConfig3Point0;
				break;
			case 4:
				tag = kAudioChannelLayoutTag_Quadraphonic;
				deviceChannelConfig = AudioConfig4Point0;
				break;
			case 5:
				tag = kAudioChannelLayoutTag_MPEG_5_0_A;
				deviceChannelConfig = AudioConfig5Point0;
				break;
			case 6:
				tag = kAudioChannelLayoutTag_MPEG_5_1_A;
				deviceChannelConfig = AudioConfig5Point1;
				break;
			case 7:
				tag = kAudioChannelLayoutTag_MPEG_6_1_A;
				deviceChannelConfig = AudioConfig6Point1;
				break;
			case 8:
				tag = kAudioChannelLayoutTag_MPEG_7_1_A;
				deviceChannelConfig = AudioConfig7Point1;
				break;
		}

		if(targetDoPInteger) {
			renderFormat = DoPIntegerRenderFormatForDeviceFormat(deviceFormat);
		} else if(targetNativeHighPrecision) {
			renderFormat = preferredNativeHighPrecisionFormat;
			renderFormat.mSampleRate = deviceFormat.mSampleRate;
			renderFormat.mChannelsPerFrame = deviceFormat.mChannelsPerFrame;
			renderFormat.mBytesPerFrame = (UInt32)((renderFormat.mBitsPerChannel / 8) * renderFormat.mChannelsPerFrame);
			renderFormat.mBytesPerPacket = renderFormat.mBytesPerFrame * renderFormat.mFramesPerPacket;
		} else if(targetIntegerPhysical) {
			renderFormat = preferredIntegerClientFormat;
			renderFormat.mSampleRate = deviceFormat.mSampleRate;
			renderFormat.mChannelsPerFrame = deviceFormat.mChannelsPerFrame;
			renderFormat.mBytesPerFrame = AudioFormatBytesPerSample(preferredIntegerClientFormat) * renderFormat.mChannelsPerFrame;
			renderFormat.mBytesPerPacket = renderFormat.mBytesPerFrame * renderFormat.mFramesPerPacket;
		} else {
			renderFormat = deviceFormat;
		}
		renderAVFormat = [[AVAudioFormat alloc] initWithStreamDescription:&renderFormat channelLayout:[[AVAudioChannelLayout alloc] initWithLayoutTag:tag]];
		resetting = YES;
		[self stopCurrentHardware];
		if(renderAVFormat && !targetExclusiveTransport) {
			[_au.inputBusses[0] setFormat:renderAVFormat error:&err];
		}
		// DoP is already a packed bitstream at this point. A float fallback would
		// corrupt it, so leave the previous bus representation in place and let the
		// enclosing transaction restore the previous device clock.
		if((!renderAVFormat || err != nil) && targetDoPInteger) {
			resetting = NO;
			return NO;
		}
		if((!renderAVFormat || err != nil) && targetIntegerPhysical) {
			resetting = NO;
			return NO;
		}
		if((!renderAVFormat || err != nil) && targetNativeHighPrecision) {
			preferDoPIntegerOutput = NO;
			preferNativeHighPrecisionOutput = NO;
			renderFormat = deviceFormat;
			renderAVFormat = [[AVAudioFormat alloc] initWithStreamDescription:&renderFormat channelLayout:[[AVAudioChannelLayout alloc] initWithLayoutTag:tag]];
			err = nil;
			if(renderAVFormat) {
				[_au.inputBusses[0] setFormat:renderAVFormat error:&err];
			}
		}
		if(!renderAVFormat || err != nil) {
			resetting = NO;
			return NO;
		}
		if(![self prepareOutputDoubleScratchForRenderFormat:renderFormat]) {
			resetting = NO;
			return NO;
		}
		renderFormatDoPInteger = targetDoPInteger && preferDoPIntegerOutput;
		renderFormatNativeHighPrecision = targetNativeHighPrecision && preferNativeHighPrecisionOutput;
		renderFormatIntegerPhysical = targetIntegerPhysical && preferIntegerPhysicalOutput;
		if(!targetEndToEndInteger) renderFormatEndToEndInteger = NO;

		if(notifyController) {
			[outputController setFormat:&deviceFormat channelConfig:deviceChannelConfig];
		}
		
		[outputLock lock];
		[buffer reset];
		[self setShouldReset:YES];
		[outputLock unlock];

		resetting = NO;
	}

	return YES;
}

- (BOOL)applyDeviceSampleRateAndFormat:(double)sampleRate {
	@synchronized(self) {
		// AUHAL owns the device stream while its render resources are allocated,
		// even after a long pause has stopped the hardware. Release that ownership
		// before asking the DAC to change clocks or carrier representation.
		const BOOL hardwareWasRunning = [self hardwareIsRunning];
		const BOOL renderResourcesWereAllocated = _au.renderResourcesAllocated;
		const BOOL previousExclusiveIOProcCreated = exclusiveIOProcID != NULL;
		const BOOL previousPaused = paused;
		const double previousSampleRate = [self currentDeviceSampleRate];
		AVAudioFormat *previousInputFormat = _au.inputBusses[0].format;
		AVAudioFormat *previousDeviceAVFormat = _deviceFormat;
		const AudioStreamBasicDescription previousDeviceFormat = deviceFormat;
		const AudioStreamBasicDescription previousRenderFormat = renderFormat;
		const uint32_t previousDeviceChannelConfig = deviceChannelConfig;
		const BOOL previousRenderFormatDoPInteger = renderFormatDoPInteger;
		const BOOL previousRenderFormatNativeHighPrecision = renderFormatNativeHighPrecision;
		const BOOL previousRenderFormatIntegerPhysical = renderFormatIntegerPhysical;
		const BOOL previousRenderFormatEndToEndInteger = renderFormatEndToEndInteger;
		const BOOL previousHogModeOwned = [self currentProcessOwnsHogMode];
		const BOOL previousExclusiveFloat = previousExclusiveIOProcCreated && previousHogModeOwned &&
		                                    (AudioFormatIsFloat32(previousRenderFormat) ||
		                                     AudioFormatIsFloat64(previousRenderFormat));
		if(previousHogModeOwned) {
			hogModeOwned = YES;
			hogModeDeviceID = outputDeviceID;
		}
		NSArray<NSNumber *> *previousPhysicalStreams = [self activeOutputPhysicalStreams];
		NSDictionary<NSNumber *, NSValue *> *previousPhysicalFormats =
		    [self currentPhysicalFormatSetForStreams:previousPhysicalStreams];
		NSDictionary<NSNumber *, NSValue *> *previousVirtualFormats =
		    [self currentVirtualFormatSetForStreams:previousPhysicalStreams];
		const BOOL previousPhysicalFormatsValid =
		    previousPhysicalStreams.count && previousPhysicalFormats.count == previousPhysicalStreams.count;
		const BOOL previousVirtualFormatsValid =
		    previousPhysicalStreams.count && previousVirtualFormats.count == previousPhysicalStreams.count;
		const BOOL previousSavedPhysicalFormatValid = savedPhysicalFormatValid;
		const AudioDeviceID previousSavedPhysicalFormatDeviceID = savedPhysicalFormatDeviceID;
		NSDictionary<NSNumber *, NSValue *> *previousSavedPhysicalFormats = savedPhysicalFormats;
		const BOOL previousSavedVirtualFormatValid = savedVirtualFormatValid;
		const AudioDeviceID previousSavedVirtualFormatDeviceID = savedVirtualFormatDeviceID;
		NSDictionary<NSNumber *, NSValue *> *previousSavedVirtualFormats = savedVirtualFormats;
		const BOOL targetEndToEndInteger = preferExclusiveIntegerTransport &&
		                                     preferredIntegerVirtualFormats.count > 0 &&
		                                     preferredIntegerPhysicalFormats.count > 0;
		const BOOL targetExclusiveFloat = preferExclusiveFloatTransport &&
		                                  preferredFloatVirtualFormats.count > 0 &&
		                                  (AudioFormatIsFloat32(preferredFloatClientFormat) ||
		                                   AudioFormatIsFloat64(preferredFloatClientFormat));
		const BOOL targetExclusiveTransport = targetEndToEndInteger || targetExclusiveFloat;
		const BOOL targetRequiresHog = targetExclusiveFloat ||
		                              (targetEndToEndInteger && preferredIntegerTransportRequiresHog);

		resetting = YES;
		if(hardwareWasRunning) {
			[self stopCurrentHardware];
		}
		if(renderResourcesWereAllocated) {
			[_au deallocateRenderResources];
		}
		if(previousExclusiveIOProcCreated) {
			[self destroyExclusiveIOProc];
		}

		BOOL prepared = !targetRequiresHog || [self acquireHogModeForCurrentDevice];
		if(prepared && targetExclusiveTransport) {
			// Integer transport changes both sides of the stream. Float-exclusive
			// transport changes only the client/virtual representation, leaving the
			// driver's physical representation under its own generic negotiation.
			if(targetEndToEndInteger && !savedPhysicalFormatValid && previousPhysicalFormatsValid) {
				savedPhysicalFormatValid = YES;
				savedPhysicalFormatDeviceID = outputDeviceID;
				savedPhysicalFormats = previousPhysicalFormats;
			}
			if(!savedVirtualFormatValid && previousVirtualFormatsValid) {
				savedVirtualFormatValid = YES;
				savedVirtualFormatDeviceID = outputDeviceID;
				savedVirtualFormats = previousVirtualFormats;
			}
		}
		if(prepared) {
			prepared = [self setDeviceSampleRate:sampleRate];
		}
		if(prepared) {
			prepared = [self applyPreferredPhysicalFormatSetAtSampleRate:sampleRate];
		}
		if(prepared) {
			prepared = [self applyPreferredVirtualFormatSetAtSampleRate:sampleRate];
		}
		if(prepared && !targetRequiresHog && hogModeOwned) {
			prepared = [self releaseHogModeForCurrentDevice];
		}
		if(prepared && !targetExclusiveTransport) {
			prepared = [self ensureAUHALBoundToOutputDevice];
		}
		if(prepared) {
			outputdevicechanged = YES;
			prepared = [self updateDeviceFormatLockedNotifyingController:NO requestedSampleRate:sampleRate];
		}

		NSError *resourceError = nil;
		if(prepared) {
			if(targetExclusiveTransport) {
				prepared = [self createExclusiveIOProc];
			} else {
				prepared = [_au allocateRenderResourcesAndReturnError:&resourceError] && resourceError == nil;
			}
		}
		AVAudioFormat *configuredInputFormat = targetExclusiveTransport ? nil : _au.inputBusses[0].format;
		if(prepared && !targetExclusiveTransport &&
		   (!configuredInputFormat || fabs(configuredInputFormat.sampleRate - sampleRate) >= 1.0)) {
			ALog(@"Core Audio retained a stale input-bus rate (requested %.0f Hz, got %.0f Hz)",
			     sampleRate, configuredInputFormat ? configuredInputFormat.sampleRate : 0.0);
			prepared = NO;
		}
		if(prepared && targetExclusiveTransport && ![self currentOutputUsesExclusiveTransport]) {
			ALog(@"Core Audio did not retain the requested exclusive client and virtual format");
			prepared = NO;
		}
		if(prepared && targetEndToEndInteger && ![self currentOutputIsEndToEndInteger]) {
			ALog(@"Core Audio did not retain a matching integer virtual and physical format");
			prepared = NO;
		}

		if(!prepared) {
			ALog(@"Unable to apply Core Audio device format; restoring the previous output: %@", resourceError);
			[self stopCurrentHardware];
			if(_au.renderResourcesAllocated) {
				[_au deallocateRenderResources];
			}
			[self destroyExclusiveIOProc];

			// Restore the preferences that describe the last backend that actually
			// rendered, rather than leaving a rejected DoP request latched.
			preferDoPIntegerOutput = previousRenderFormatDoPInteger;
			preferredDoPCarrierSampleRate = previousRenderFormatDoPInteger ? previousRenderFormat.mSampleRate : 0.0;
			preferNativeHighPrecisionOutput = previousRenderFormatNativeHighPrecision;
			if(previousRenderFormatNativeHighPrecision) {
				preferredNativeHighPrecisionFormat = previousRenderFormat;
			} else {
				bzero(&preferredNativeHighPrecisionFormat, sizeof(preferredNativeHighPrecisionFormat));
			}
			preferIntegerPhysicalOutput = previousRenderFormatIntegerPhysical;
			if(previousRenderFormatIntegerPhysical && previousPhysicalFormatsValid) {
				preferredIntegerPhysicalFormats = previousPhysicalFormats;
				preferredIntegerClientFormat = previousRenderFormat;
			} else {
				preferredIntegerPhysicalFormats = nil;
				bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));
			}
			preferExclusiveIntegerTransport = previousRenderFormatEndToEndInteger;
			preferredIntegerTransportRequiresHog = previousHogModeOwned;
			preferredIntegerVirtualFormats = previousRenderFormatEndToEndInteger && previousVirtualFormatsValid ?
			                                     previousVirtualFormats : nil;
			preferExclusiveFloatTransport = previousExclusiveFloat;
			preferredFloatVirtualFormats = previousExclusiveFloat && previousVirtualFormatsValid ?
			                                  previousVirtualFormats : nil;
			if(previousExclusiveFloat) {
				preferredFloatClientFormat = previousRenderFormat;
			} else {
				bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
			}

			BOOL restored = YES;
			if(previousHogModeOwned && ![self currentProcessOwnsHogMode]) {
				restored = [self acquireHogModeForCurrentDevice];
			}
			if(previousSampleRate > 0.0 && fabs(previousSampleRate - [self currentDeviceSampleRate]) >= 1.0) {
				restored = [self setDeviceSampleRate:previousSampleRate] && restored;
			}
			if(previousPhysicalFormatsValid) {
				restored = [self setPhysicalFormatSet:previousPhysicalFormats] && restored;
			}
			if(previousVirtualFormatsValid) {
				restored = [self setVirtualFormatSet:previousVirtualFormats] && restored;
			}
			savedPhysicalFormatValid = previousSavedPhysicalFormatValid;
			savedPhysicalFormatDeviceID = previousSavedPhysicalFormatDeviceID;
			savedPhysicalFormats = previousSavedPhysicalFormats;
			savedVirtualFormatValid = previousSavedVirtualFormatValid;
			savedVirtualFormatDeviceID = previousSavedVirtualFormatDeviceID;
			savedVirtualFormats = previousSavedVirtualFormats;
			if(!previousHogModeOwned && hogModeOwned) {
				restored = [self releaseHogModeForCurrentDevice] && restored;
			}

			_deviceFormat = previousDeviceAVFormat;
			deviceFormat = previousDeviceFormat;
			renderFormat = previousRenderFormat;
			deviceChannelConfig = previousDeviceChannelConfig;
			renderFormatDoPInteger = previousRenderFormatDoPInteger;
			renderFormatNativeHighPrecision = previousRenderFormatNativeHighPrecision;
			renderFormatIntegerPhysical = previousRenderFormatIntegerPhysical;
			renderFormatEndToEndInteger = previousRenderFormatEndToEndInteger;
			NSError *rollbackError = nil;
			if(previousExclusiveIOProcCreated) {
				restored = [self createExclusiveIOProc] && restored;
			} else {
				restored = [self ensureAUHALBoundToOutputDevice] && restored;
				if(previousInputFormat) {
					[_au.inputBusses[0] setFormat:previousInputFormat error:&rollbackError];
					restored = restored && rollbackError == nil;
				} else {
					restored = NO;
				}
				rollbackError = nil;
				restored = [_au allocateRenderResourcesAndReturnError:&rollbackError] &&
				           rollbackError == nil && restored;
			}
			doPActive = previousRenderFormatDoPInteger;
			doPSeekPending = previousRenderFormatDoPInteger;
			doPMarker = 0x05;
			[faderNode setDoPMode:previousRenderFormatDoPInteger];

			// Let the output thread (or the replacement prebuffer callback) perform
			// the hardware start outside this synchronous format transaction.
			paused = previousPaused;
			outputdevicechanged = !restored;
			resetting = NO;
			started = NO;
			return NO;
		}

		renderFormatEndToEndInteger = targetEndToEndInteger;
		outputdevicechanged = NO;
		restarted = NO;
		resetting = NO;
		started = NO;
		// A manual replacement resumes only after its new chain has prebuffered.
		// Natural gapless transitions are restarted by the persistent output thread;
		// neither path calls a potentially blocking driver start on the UI thread.
		return YES;
	}
}

- (BOOL)updateDeviceFormatNotifyingController:(BOOL)notifyController {
	@synchronized(self) {
		const BOOL hardwareWasRunning = [self hardwareIsRunning];
		const BOOL renderResourcesWereAllocated = _au.renderResourcesAllocated;
		const BOOL exclusiveIOProcWasCreated = exclusiveIOProcID != NULL;
		if(hardwareWasRunning) {
			[self stopCurrentHardware];
		}
		if(renderResourcesWereAllocated) {
			[_au deallocateRenderResources];
		}
		if(exclusiveIOProcWasCreated) {
			[self destroyExclusiveIOProc];
		}

		double requestedSampleRate = 0.0;
		if(outputDeviceIDChanged && sourceFormatValid && sourceFormat.mBitsPerChannel == 1) {
			// A device selection can cross the DoP capability boundary while a raw
			// DSD track is active. Re-evaluate the representation before configuring
			// AUHAL; retaining the old DoP input format makes Core Audio resample the
			// carrier, which destroys its marker and payload bytes.
			const double doPCarrierSampleRate = preferredDeviceSampleRateForInputFormat(sourceFormat);
			const BOOL supportsDoPCarrier = [self deviceSupportsSampleRate:doPCarrierSampleRate];

			preferNativeHighPrecisionOutput = NO;
			bzero(&preferredNativeHighPrecisionFormat, sizeof(preferredNativeHighPrecisionFormat));
			if(supportsDoPCarrier && [self setDeviceSampleRate:doPCarrierSampleRate]) {
				preferDoPIntegerOutput = YES;
				preferredDoPCarrierSampleRate = doPCarrierSampleRate;
				requestedSampleRate = doPCarrierSampleRate;
				doPSeekPending = YES;
				if(!doPActive) {
					doPMarker = 0x05;
				}
			} else {
				double pcmSampleRate = [self bestPCMDeviceSampleRateForDSDInputFormat:sourceFormat];
				if(pcmSampleRate > 0.0 && [self setDeviceSampleRate:pcmSampleRate]) {
					requestedSampleRate = pcmSampleRate;
				} else {
					pcmSampleRate = [self currentDeviceSampleRate];
				}
				DLog(@"DoP carrier rate %.0f Hz is unavailable after the output-device change; converting native DSD to %.0f Hz PCM", doPCarrierSampleRate, pcmSampleRate);
				preferDoPIntegerOutput = NO;
				preferredDoPCarrierSampleRate = 0.0;
				doPSeekPending = NO;
				doPActive = NO;
				doPMarker = 0x05;
				[faderNode setDoPMode:NO];
			}
		}

		const BOOL preferExclusiveTransport = preferExclusiveIntegerTransport || preferExclusiveFloatTransport;
		BOOL prepared = [self updateDeviceFormatLockedNotifyingController:notifyController requestedSampleRate:requestedSampleRate];
		if(prepared && preferExclusiveTransport) {
			prepared = [self createExclusiveIOProc];
		} else if(renderResourcesWereAllocated) {
			NSError *resourceError = nil;
			prepared = [_au allocateRenderResourcesAndReturnError:&resourceError] && resourceError == nil && prepared;
		}
		AVAudioFormat *configuredInputFormat = preferExclusiveTransport ? nil : _au.inputBusses[0].format;
		if(prepared && !preferExclusiveTransport && (!configuredInputFormat ||
		                fabs(configuredInputFormat.sampleRate - renderFormat.mSampleRate) >= 1.0)) {
			prepared = NO;
		}
		if(hardwareWasRunning) {
			started = NO;
			restarted = NO;
		}
		if(prepared) {
			outputDeviceIDChanged = NO;
			resetting = NO;
			[faderNode setDoPMode:renderFormatDoPInteger];
		}
		return prepared;
	}
}

- (BOOL)updateDeviceFormat {
	BOOL prepared = [self updateDeviceFormatNotifyingController:YES];
	if(prepared) {
		[self refreshOutputStatus];
	}
	return prepared;
}

- (AudioStreamBasicDescription)outputFormatForInputFormat:(AudioStreamBasicDescription)inputFormat {
	AudioStreamBasicDescription outputFormat = deviceFormat;
	double sampleRate = preferredDeviceSampleRateForInputFormat(inputFormat);
	const BOOL nativeDSD = inputFormat.mBitsPerChannel == 1;
	if(nativeDSD && ![self deviceSupportsSampleRate:sampleRate]) {
		sampleRate = [self bestPCMDeviceSampleRateForDSDInputFormat:inputFormat];
	}
	// Preloaded chains are built before they become the active output. Build
	// them at the best source-family rate the device supports; selectNextBuffer
	// switches the hardware at the actual track boundary.
	if(sampleRate > 0.0 && [self deviceSupportsSampleRate:sampleRate]) {
		outputFormat.mSampleRate = sampleRate;
	}
	return outputFormat;
}

- (BOOL)prepareForInputFormat:(AudioStreamBasicDescription)inputFormat {
	// Treat the source description and the corresponding hardware transaction as
	// one handoff. Changing a device clock/stream format invokes Core Audio
	// listeners asynchronously; without this outer lock, the output thread can
	// observe that notification before sourceFormat is committed and immediately
	// renegotiate the outgoing track's format over the replacement track.
	@synchronized(self) {
		return [self prepareForInputFormatLocked:inputFormat];
	}
}

- (BOOL)prepareForInputFormatLocked:(AudioStreamBasicDescription)inputFormat {
	const uint32_t inputChannelConfig = [outputController currentInputChannelConfig];
	const BOOL inputFormatValid = inputFormat.mFormatID != 0 &&
	                              inputFormat.mSampleRate > 0.0 &&
	                              inputFormat.mBitsPerChannel > 0 &&
	                              inputFormat.mChannelsPerFrame > 0;
	const BOOL sameInputFormat = sourceFormatValid && inputFormatValid &&
	                             sourceChannelConfig == inputChannelConfig &&
	                             memcmp(&sourceFormat, &inputFormat, sizeof(inputFormat)) == 0;

	// Keep AUHAL and the DAC clock untouched when the replacement stream has
	// exactly the same source format. The output path was already negotiated
	// for this representation, and fadeOutBackground has replaced its buffers.
	if(sameInputFormat && _au && !outputdevicechanged) {
		DLog(@"Input format unchanged; retaining AUHAL and the current device clock");
		[faderNode setDoPMode:renderFormatDoPInteger];
		[self refreshOutputStatus];
		return YES;
	}

	const BOOL nativeDSD = inputFormat.mBitsPerChannel == 1;
	const BOOL highPrecisionPCM = AudioFormatIsHighPrecisionPCM(inputFormat);
	const double sampleRate = preferredDeviceSampleRateForInputFormat(inputFormat);
	const BOOL sampleRateSupported = [self deviceSupportsSampleRate:sampleRate];
	const double outputSampleRate = (nativeDSD && !sampleRateSupported) ?
	                                    [self bestPCMDeviceSampleRateForDSDInputFormat:inputFormat] :
	                                    sampleRate;
	const BOOL outputSampleRateSupported = outputSampleRate > 0.0 &&
	                                           [self deviceSupportsSampleRate:outputSampleRate];
	const BOOL convertsDSDToPCM = nativeDSD && !sampleRateSupported && outputSampleRateSupported;
	// Only a native DSD source requires Cog to establish a DoP carrier here.
	// Sample rate and integer depth alone cannot distinguish DoP from ordinary
	// high-resolution PCM; treating every 24-bit stream at 176.4 kHz or above
	// as DoP replaces valid PCM with carrier silence.
	const BOOL usesDoPCarrier = nativeDSD && sampleRateSupported;
	if(nativeDSD && !sampleRateSupported) {
		DLog(@"DoP carrier rate %.0f Hz is unavailable; converting native DSD to %.0f Hz PCM", sampleRate, outputSampleRate);
	}

	if(!usesDoPCarrier) {
		DLog(@"Preparing PCM source %@ (exclusive enabled: %@, source rate supported: %@)",
		     outputFormatDescription(inputFormat, NO),
		     exclusiveOutputEnabled ? @"yes" : @"no",
		     sampleRateSupported ? @"yes" : @"no");
		// A pending DoP seek is only meaningful while another DoP carrier is
		// expected. If playback moves to PCM before that carrier arrives, do not
		// keep replacing PCM buffers with DoP silence indefinitely.
		doPSeekPending = NO;
		doPActive = NO;
		doPMarker = 0x05;
		[faderNode setDoPMode:NO];

		preferDoPIntegerOutput = NO;
		preferredDoPCarrierSampleRate = 0.0;
		preferNativeHighPrecisionOutput = highPrecisionPCM && sampleRateSupported &&
		                                    inputFormat.mChannelsPerFrame == deviceFormat.mChannelsPerFrame;
		if(preferNativeHighPrecisionOutput) {
			preferredNativeHighPrecisionFormat = AudioFormatAsCanonicalHighPrecisionPCM(inputFormat);
			preferredNativeHighPrecisionFormat.mSampleRate = sampleRate;
		} else {
			bzero(&preferredNativeHighPrecisionFormat, sizeof(preferredNativeHighPrecisionFormat));
		}
		if(convertsDSDToPCM) {
			preferExclusiveIntegerTransport = NO;
			preferredIntegerTransportRequiresHog = NO;
			preferredIntegerVirtualFormats = nil;
			preferIntegerPhysicalOutput = NO;
			preferredIntegerPhysicalFormats = nil;
			bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));
			[self configurePreferredFloatOutputForConvertedDSDInputFormat:inputFormat
			                                                   sampleRate:outputSampleRate];
		} else if(sampleRateSupported && AudioFormatIsIntegerPCM(inputFormat) && inputFormat.mBitsPerChannel <= 32) {
			[self configurePreferredIntegerOutputAtSampleRate:sampleRate
			                                       requiredBits:inputFormat.mBitsPerChannel
			                                  requireDoPCarrier:NO];
		} else if(sampleRateSupported &&
		          (AudioFormatIsFloat32(inputFormat) || AudioFormatIsFloat64(inputFormat))) {
			preferExclusiveIntegerTransport = NO;
			preferredIntegerTransportRequiresHog = NO;
			preferredIntegerVirtualFormats = nil;
			preferIntegerPhysicalOutput = NO;
			preferredIntegerPhysicalFormats = nil;
			bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));
			[self configurePreferredFloatOutputForInputFormat:inputFormat sampleRate:sampleRate];
		} else {
			preferExclusiveIntegerTransport = NO;
			preferredIntegerTransportRequiresHog = NO;
			preferredIntegerVirtualFormats = nil;
			preferExclusiveFloatTransport = NO;
			preferredFloatVirtualFormats = nil;
			preferIntegerPhysicalOutput = NO;
			preferredIntegerPhysicalFormats = nil;
			bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));
			bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
		}

		// A matching hardware clock is a prerequisite for bit-perfect PCM.
		// Unsupported rates still play through the existing converter fallback.
		if(outputSampleRateSupported) {
			// The queued converter was intentionally configured for this source
			// rate. Do not silently hand it to AUHAL for hidden SRC if the clock
			// and render-format transition cannot be completed together.
			const BOOL requestedExclusiveOutput = preferExclusiveIntegerTransport || preferExclusiveFloatTransport;
			const BOOL requestedIntegerPhysicalOutput = preferIntegerPhysicalOutput;
			BOOL prepared = [self applyDeviceSampleRateAndFormat:outputSampleRate];
			if(!prepared && requestedExclusiveOutput) {
				ALog(@"Exclusive output was unavailable; retrying with shared Core Audio output");
				preferDoPIntegerOutput = NO;
				preferredDoPCarrierSampleRate = 0.0;
				preferNativeHighPrecisionOutput = highPrecisionPCM && sampleRateSupported &&
				                                    inputFormat.mChannelsPerFrame == deviceFormat.mChannelsPerFrame;
				if(preferNativeHighPrecisionOutput) {
					preferredNativeHighPrecisionFormat = AudioFormatAsCanonicalHighPrecisionPCM(inputFormat);
					preferredNativeHighPrecisionFormat.mSampleRate = sampleRate;
				}
				if(AudioFormatIsIntegerPCM(inputFormat)) {
					[self configureSharedIntegerOutputAtSampleRate:sampleRate
					                                      requiredBits:inputFormat.mBitsPerChannel
					                                 requireDoPCarrier:NO];
				} else {
					preferExclusiveIntegerTransport = NO;
					preferredIntegerTransportRequiresHog = NO;
					preferredIntegerVirtualFormats = nil;
					preferExclusiveFloatTransport = NO;
					preferredFloatVirtualFormats = nil;
					preferIntegerPhysicalOutput = NO;
					preferredIntegerPhysicalFormats = nil;
					bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));
					bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
				}
				prepared = [self applyDeviceSampleRateAndFormat:outputSampleRate];
			}
			if(!prepared && requestedIntegerPhysicalOutput) {
				// A driver can advertise a physical format but reject it while another
				// client owns the device. Preserve ordinary PCM playback in that case.
				ALog(@"Integer physical output was rejected; retrying with the Core Audio mixable format");
				preferDoPIntegerOutput = NO;
				preferredDoPCarrierSampleRate = 0.0;
				preferNativeHighPrecisionOutput = highPrecisionPCM && sampleRateSupported &&
				                                    inputFormat.mChannelsPerFrame == deviceFormat.mChannelsPerFrame;
				if(preferNativeHighPrecisionOutput) {
					preferredNativeHighPrecisionFormat = AudioFormatAsCanonicalHighPrecisionPCM(inputFormat);
					preferredNativeHighPrecisionFormat.mSampleRate = sampleRate;
				}
				preferIntegerPhysicalOutput = NO;
				preferredIntegerPhysicalFormats = nil;
				preferExclusiveIntegerTransport = NO;
				preferredIntegerTransportRequiresHog = NO;
				preferredIntegerVirtualFormats = nil;
				preferExclusiveFloatTransport = NO;
				preferredFloatVirtualFormats = nil;
				bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));
				bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
				prepared = [self applyDeviceSampleRateAndFormat:outputSampleRate];
			}
			if(prepared) {
				sourceFormat = inputFormat;
				sourceChannelConfig = inputChannelConfig;
				sourceFormatValid = inputFormatValid;
				[self refreshOutputStatus];
			}
			return prepared;
		}

		if(renderFormatDoPInteger || renderFormatNativeHighPrecision || renderFormatIntegerPhysical ||
		   renderFormatEndToEndInteger || exclusiveIOProcID || savedPhysicalFormatValid ||
		   savedVirtualFormatValid || hogModeOwned) {
			const double currentSampleRate = [self currentDeviceSampleRate];
			BOOL prepared = currentSampleRate > 0.0 ? [self applyDeviceSampleRateAndFormat:currentSampleRate] :
			                                                [self updateDeviceFormatNotifyingController:NO];
			if(!prepared) {
				return NO;
			}
		}
		sourceFormat = inputFormat;
		sourceChannelConfig = inputChannelConfig;
		sourceFormatValid = inputFormatValid;
		[self refreshOutputStatus];
		return YES;
	}

	// The hardware may start before the decoder's first DoP frame has reached
	// the final output buffer. Emit a valid carrier from the very first render
	// instead of ordinary PCM zeroes, which some DSD DACs will not lock onto.
	if(!doPActive) {
		doPMarker = 0x05;
	}
	doPSeekPending = YES;

	preferDoPIntegerOutput = YES;
	preferNativeHighPrecisionOutput = NO;
	bzero(&preferredNativeHighPrecisionFormat, sizeof(preferredNativeHighPrecisionFormat));
	preferredDoPCarrierSampleRate = sampleRate;
	if(sampleRateSupported) {
		[self configurePreferredIntegerOutputAtSampleRate:sampleRate
		                                       requiredBits:24
		                                  requireDoPCarrier:YES];
	} else {
		preferExclusiveIntegerTransport = NO;
		preferredIntegerTransportRequiresHog = NO;
		preferredIntegerVirtualFormats = nil;
		preferExclusiveFloatTransport = NO;
		preferredFloatVirtualFormats = nil;
		preferIntegerPhysicalOutput = NO;
		preferredIntegerPhysicalFormats = nil;
		bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));
		bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
	}
	const BOOL requestedExclusiveIntegerOutput = preferExclusiveIntegerTransport;
	const BOOL requestedIntegerPhysicalOutput = preferIntegerPhysicalOutput;
	BOOL prepared = [self applyDeviceSampleRateAndFormat:sampleRate];
	if(!prepared && requestedExclusiveIntegerOutput) {
		ALog(@"Exclusive DoP output was unavailable; retrying with shared integer Core Audio output");
		preferDoPIntegerOutput = YES;
		preferredDoPCarrierSampleRate = sampleRate;
		preferNativeHighPrecisionOutput = NO;
		bzero(&preferredNativeHighPrecisionFormat, sizeof(preferredNativeHighPrecisionFormat));
		[self configureSharedIntegerOutputAtSampleRate:sampleRate
		                                      requiredBits:24
		                                 requireDoPCarrier:YES];
		prepared = [self applyDeviceSampleRateAndFormat:sampleRate];
	}
	if(!prepared && requestedIntegerPhysicalOutput) {
		preferDoPIntegerOutput = YES;
		preferredDoPCarrierSampleRate = sampleRate;
		preferNativeHighPrecisionOutput = NO;
		bzero(&preferredNativeHighPrecisionFormat, sizeof(preferredNativeHighPrecisionFormat));
		preferIntegerPhysicalOutput = NO;
		preferredIntegerPhysicalFormats = nil;
		preferExclusiveIntegerTransport = NO;
		preferredIntegerTransportRequiresHog = NO;
		preferredIntegerVirtualFormats = nil;
		preferExclusiveFloatTransport = NO;
		preferredFloatVirtualFormats = nil;
		bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));
		bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
		prepared = [self applyDeviceSampleRateAndFormat:sampleRate];
	}
	if(prepared && renderFormatDoPInteger) {
		sourceFormat = inputFormat;
		sourceChannelConfig = inputChannelConfig;
		sourceFormatValid = inputFormatValid;
		[faderNode setDoPMode:YES];
		[self refreshOutputStatus];
		return YES;
	}

	// Native DSD has already been packed as a DoP carrier by the converter.
	// Continuing through a float fallback would corrupt its marker and payload
	// bytes while still presenting the stream as successfully prepared.
	doPSeekPending = NO;
	preferDoPIntegerOutput = NO;
	preferredDoPCarrierSampleRate = 0.0;
	preferIntegerPhysicalOutput = NO;
	preferredIntegerPhysicalFormats = nil;
	preferExclusiveIntegerTransport = NO;
	preferredIntegerTransportRequiresHog = NO;
	preferredIntegerVirtualFormats = nil;
	preferExclusiveFloatTransport = NO;
	preferredFloatVirtualFormats = nil;
	bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));
	bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
	[faderNode setDoPMode:NO];
	return NO;
}

- (void)refreshOutputStatus {
	if(renderFormat.mFormatID) {
		[self postOutputFormatDescription:outputFormatDescription(renderFormat, renderFormatDoPInteger)];
	}
}

- (void)updateStreamFormat {
	/* Set the channel layout for the audio queue */
	resetStreamFormat = NO;

	uint32_t channels = realStreamFormat.mChannelsPerFrame;
	uint32_t channelConfig = realStreamChannelConfig;

	streamFormat = realStreamFormat;
	streamFormat.mChannelsPerFrame = channels;
	streamChannelConfig = channelConfig;

	AudioChannelLayoutTag tag = 0;

	AudioChannelLayout layout = { 0 };
	switch(streamChannelConfig) {
		case AudioConfigMono:
			tag = kAudioChannelLayoutTag_Mono;
			break;
		case AudioConfigStereo:
			tag = kAudioChannelLayoutTag_Stereo;
			break;
		case AudioConfig3Point0:
			tag = kAudioChannelLayoutTag_WAVE_3_0;
			break;
		case AudioConfig4Point0:
			tag = kAudioChannelLayoutTag_WAVE_4_0_A;
			break;
		case AudioConfig5Point0:
			tag = kAudioChannelLayoutTag_WAVE_5_0_A;
			break;
		case AudioConfig5Point1:
			tag = kAudioChannelLayoutTag_WAVE_5_1_A;
			break;
		case AudioConfig6Point1:
			tag = kAudioChannelLayoutTag_WAVE_6_1;
			break;
		case AudioConfig7Point1:
			tag = kAudioChannelLayoutTag_WAVE_7_1;
			break;

		default:
			tag = 0;
			break;
	}

	if(tag) {
		layout.mChannelLayoutTag = tag;
	} else {
		layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap;
		layout.mChannelBitmap = streamChannelConfig;
	}
}

- (void)renderAndConvert {
	if(resetStreamFormat) {
		[self updateStreamFormat];
		if([self processEndOfStream]) {
			return;
		}
	}

	AudioChunk *chunk = [self renderInput:512];
	size_t frameCount = 0;
	if(chunk && (frameCount = [chunk frameCount])) {
		[outputLock lock];
		[buffer addChunk:chunk];
		[outputLock unlock];
		[readSemaphore signal];
	}
	
	if(streamFormatChanged) {
		streamFormatChanged = NO;
		if(frameCount) {
			resetStreamFormat = YES;
		} else {
			[self updateStreamFormat];
		}
	}
	[self processEndOfStream];
}

- (void)audioOutputBlock {
	__block AudioStreamBasicDescription *format = &deviceFormat;
	__block AudioStreamBasicDescription *renderASBD = &renderFormat;
	__block void *refCon = (__bridge void *)self;
	__block NSLock *refLock = self->outputLock;

#ifdef OUTPUT_LOG
	__block NSFileHandle *logFile = _logFile;
#endif

	_outputRenderBlock = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *_Nonnull actionFlags, const AudioTimeStamp *_Nonnull timestamp, AUAudioFrameCount frameCount, NSInteger inputBusNumber, AudioBufferList *_Nonnull inputData) {
		if(!frameCount) return 0;

		const int channels = format->mChannelsPerFrame;
		if(!channels) return 0;

		if(!inputData->mNumberBuffers || !inputData->mBuffers[0].mData) return 0;

		OutputCoreAudio *_self = (__bridge OutputCoreAudio *)refCon;
		int renderedSamples = 0;
		BOOL outputContainsDoP = NO;

		inputData->mBuffers[0].mDataByteSize = frameCount * renderASBD->mBytesPerPacket;
		bzero(inputData->mBuffers[0].mData, inputData->mBuffers[0].mDataByteSize);
		inputData->mBuffers[0].mNumberChannels = channels;
		
		if(_self->resetting) {
			return 0;
		}

		const BOOL renderDirectDoP = _self->renderFormatDoPInteger && AudioFormatIsDoPInteger(*renderASBD);
		if(renderDirectDoP) {
			@autoreleasepool {
				if(!_self->faded) {
					while(renderedSamples < frameCount) {
						[refLock lock];
						AudioChunk *chunk = nil;
						if(![_self->bufferNode.buffer isEmpty]) {
							chunk = [_self->bufferNode.buffer removeSamples:frameCount - renderedSamples];
						}
						[refLock unlock];

						size_t chunkFrames = chunk ? [chunk frameCount] : 0;
						if(chunkFrames) {
							_self->prebufferReached = YES;
							double streamTimestamp = [chunk streamTimestamp];
							if(!streamTimestamp || _self->streamTimestamp > streamTimestamp) {
								_self->prebufferSignaled = NO;
							}
							_self->streamTimestamp = streamTimestamp;

							const AudioStreamBasicDescription chunkFormat = [chunk format];
							NSData *sampleData = [chunk removeSamples:chunkFrames];
							size_t inputTodo = MIN(chunkFrames, frameCount - renderedSamples);
							uint8_t *destination = (uint8_t *)inputData->mBuffers[0].mData +
							                       renderedSamples * renderASBD->mBytesPerPacket;
							uint8_t nextDoPMarker = 0x05;
							const BOOL compatibleCarrier = AudioFormatIsDoPInteger(chunkFormat) &&
							                               chunkFormat.mChannelsPerFrame == (UInt32)channels &&
							                               chunkFormat.mBytesPerPacket == renderASBD->mBytesPerPacket;
							const BOOL inputIsDoP = [chunk isDoP] && compatibleCarrier &&
							                          audioBufferIsDoP([sampleData bytes], chunkFormat, inputTodo, &nextDoPMarker);

							if(!inputIsDoP) {
								// Never feed PCM or a damaged marker sequence to a DAC that is
								// currently locked to DoP. Consume the transition and substitute
								// valid DoP silence with the expected marker phase.
								fillDoPSilence(destination, *renderASBD, inputTodo, &_self->doPMarker);
							} else {
								const uint8_t firstDoPMarker = (inputTodo % 2) ?
								                                     ((nextDoPMarker == 0x05) ? 0xFA : 0x05) :
								                                     nextDoPMarker;
								const uint8_t *source = (const uint8_t *)[sampleData bytes];
								if(firstDoPMarker != _self->doPMarker) {
									// Drop a repeated marker at a buffer join instead of making the
									// DAC lose DoP lock.
									source += chunkFormat.mBytesPerPacket;
									--inputTodo;
								}
								memcpy(destination, source, inputTodo * renderASBD->mBytesPerPacket);
								_self->doPActive = YES;
								_self->doPSeekPending = NO;
								_self->doPMarker = nextDoPMarker;
								if(_self->fading) {
									_self->faded = _self->fadeStep < 0.0;
									_self->fading = NO;
									_self->fadeStep = 0.0f;
									_self->fadeLevel = _self->faded ? 0.0f : 1.0f;
								}
							}
							renderedSamples += (int)inputTodo;
						}

						if((_self->stopping && !_self->fadingstop) || _self->resetting ||
						   _self->faded || !chunk || !chunkFrames) break;
					}
				}

				if(renderedSamples < frameCount) {
					uint8_t *destination = (uint8_t *)inputData->mBuffers[0].mData +
					                       renderedSamples * renderASBD->mBytesPerPacket;
					fillDoPSilence(destination, *renderASBD, frameCount - renderedSamples, &_self->doPMarker);
				}

				[_self updateLatency:(double)renderedSamples / format->mSampleRate];
#ifdef OUTPUT_LOG
				NSData *outData = [NSData dataWithBytes:inputData->mBuffers[0].mData length:inputData->mBuffers[0].mDataByteSize];
				[logFile writeData:outData];
#endif
			}
			return 0;
		}
		
		const BOOL renderAsFloat32 = AudioFormatIsFloat32(*renderASBD);
		const BOOL renderAsFloat64 = AudioFormatIsFloat64(*renderASBD);
		const BOOL renderAsHighPrecision = AudioFormatIsHighPrecisionPCM(*renderASBD);
		const size_t scratchSamples = (size_t)frameCount * channels;
		if(!_self->inputDoubleScratch || !_self->outputDoubleScratch ||
		   _self->outputDoubleScratchCapacity < scratchSamples) {
			return 0;
		}
		double *outSamples = _self->outputDoubleScratch;
		bzero(outSamples, scratchSamples * sizeof(double));

		const BOOL directHighPrecision = _self->renderFormatNativeHighPrecision &&
		                                 renderAsHighPrecision &&
		                                 !_self->fading && !_self->faded &&
		                                 !_self->doPActive && !_self->doPSeekPending &&
		                                 _self->volume == 1.0;

		@autoreleasepool {
			if(directHighPrecision) {
				while(renderedSamples < frameCount) {
					[refLock lock];
					AudioChunk *chunk = nil;
					if(![_self->bufferNode.buffer isEmpty]) {
						chunk = [_self->bufferNode.buffer removeSamples:frameCount - renderedSamples];
					}
					[refLock unlock];

					size_t chunkFrames = chunk ? [chunk frameCount] : 0;
					if(chunkFrames) {
						_self->prebufferReached = YES;
						double streamTimestamp = [chunk streamTimestamp];
						if(!streamTimestamp || _self->streamTimestamp > streamTimestamp) {
							_self->prebufferSignaled = NO;
						}
						_self->streamTimestamp = streamTimestamp;

						const AudioStreamBasicDescription chunkFormat = [chunk format];
						NSData *sampleData = [chunk removeSamples:chunkFrames];
						const size_t inputTodo = MIN(chunkFrames, frameCount - renderedSamples);
						const size_t sampleCount = inputTodo * channels;
						uint8_t *destination = (uint8_t *)inputData->mBuffers[0].mData +
						                       renderedSamples * renderASBD->mBytesPerPacket;
						BOOL renderedChunk = NO;

						if(chunkFormat.mChannelsPerFrame != (UInt32)channels) {
							chunkFrames = 0;
						} else if(highPrecisionRepresentationsMatch(chunkFormat, *renderASBD)) {
							memcpy(destination, [sampleData bytes], inputTodo * renderASBD->mBytesPerPacket);
							renderedChunk = YES;
						} else if(convertPCMBufferToFloat64(_self->inputDoubleScratch, [sampleData bytes], chunkFormat, sampleCount)) {
							if(renderASBD->mFormatFlags & kAudioFormatFlagIsFloat) {
								memcpy(destination, _self->inputDoubleScratch, sampleCount * sizeof(double));
							} else {
								convertFloat64BufferToFullS32((int32_t *)destination, _self->inputDoubleScratch, sampleCount);
							}
							renderedChunk = YES;
						}
						if(renderedChunk) {
							renderedSamples += (int)inputTodo;
						} else {
							chunkFrames = 0;
						}
					}

					if((_self->stopping && !_self->fadingstop) || _self->resetting || !chunk || !chunkFrames) {
						break;
					}
				}
			} else if(!_self->faded) {
				while(renderedSamples < frameCount) {
					[refLock lock];
					AudioChunk *chunk = nil;
					if(![_self->bufferNode.buffer isEmpty]) {
						chunk = [_self->bufferNode.buffer removeSamples:frameCount - renderedSamples];
					}
					[refLock unlock];

					size_t _frameCount = 0;

					if(chunk && [chunk frameCount]) {
						_self->prebufferReached = YES;

						double streamTimestamp = [chunk streamTimestamp];
						if(!streamTimestamp || _self->streamTimestamp > streamTimestamp) {
							_self->prebufferSignaled = NO;
						}
						_self->streamTimestamp = streamTimestamp;

						_frameCount = [chunk frameCount];
						const AudioStreamBasicDescription chunkFormat = [chunk format];
						NSData *sampleData = [chunk removeSamples:_frameCount];
						size_t inputTodo = MIN(_frameCount, frameCount - renderedSamples);
						if(chunkFormat.mChannelsPerFrame != (UInt32)channels) {
							break;
						}
						double *samplePtr = NULL;
						if(convertPCMBufferToFloat64(_self->inputDoubleScratch, [sampleData bytes], chunkFormat, inputTodo * channels)) {
							samplePtr = _self->inputDoubleScratch;
						}
						if(!samplePtr) {
							break;
						}
						uint8_t nextDoPMarker = 0x05;
						AudioStreamBasicDescription floatDoPFormat = AudioFormatAsFloat64(chunkFormat);
						BOOL inputIsDoP = [chunk isDoP] &&
						                  audioBufferIsDoP(samplePtr, floatDoPFormat, inputTodo, &nextDoPMarker);

						if(_self->doPSeekPending && !inputIsDoP) {
							// Never expose transitional or stale PCM-looking data while a
							// DoP seek is waiting for the first verified post-seek carrier.
							fillDoPSilence(outSamples + renderedSamples * channels, floatDoPFormat, inputTodo, &_self->doPMarker);
							outputContainsDoP = YES;
						} else if(inputIsDoP) {
							// A DoP carrier must remain bit-perfect. Complete a pending
							// fade as a hard transition and preserve the marker phase.
							const uint8_t firstDoPMarker = (inputTodo % 2) ? ((nextDoPMarker == 0x05) ? 0xFA : 0x05) : nextDoPMarker;
							if(_self->doPActive && firstDoPMarker != _self->doPMarker) {
								// Dropping one carrier frame is preferable to repeating a marker,
								// which can make the DAC lose DoP lock at the join.
								samplePtr += channels;
								--inputTodo;
							}
							cblas_dcopy((int)(inputTodo * channels), samplePtr, 1, outSamples + renderedSamples * channels, 1);
							_self->doPActive = YES;
							_self->doPSeekPending = NO;
							_self->doPMarker = nextDoPMarker;
							outputContainsDoP = YES;
							if(_self->fading) {
								_self->faded = _self->fadeStep < 0.0;
								_self->fading = NO;
								_self->fadeStep = 0.0;
								_self->fadeLevel = _self->faded ? 0.0 : 1.0;
							}
						} else if(!_self->fading) {
							_self->doPActive = NO;
							cblas_dcopy((int)(inputTodo * channels), samplePtr, 1, outSamples + renderedSamples * channels, 1);
						} else {
							_self->doPActive = NO;
							BOOL faded = fadeAudio64(samplePtr, outSamples + renderedSamples * channels, channels, inputTodo, &_self->fadeLevel, _self->fadeStep, _self->fadeTarget);
							if(faded) {
								if(_self->fadeStep < 0.0) {
									_self->faded = YES;
								}
								_self->fading = NO;
								_self->fadeStep = 0.0;
							}
						}

						renderedSamples += inputTodo;
					}

					if((_self->stopping && !_self->fadingstop) || _self->resetting || _self->faded || !chunk || !_frameCount) {
						break;
					}
				}
			}
			if(!directHighPrecision && (_self->doPActive || _self->doPSeekPending) && renderedSamples < frameCount) {
				// PCM zeroes make a DoP DAC lose lock. Keep it locked across pause,
				// initial startup, track changes, and brief underruns with standard
				// DSD silence.
				AudioStreamBasicDescription floatDoPFormat = AudioFormatAsFloat64(*renderASBD);
				fillDoPSilence(outSamples + renderedSamples * channels, floatDoPFormat, frameCount - renderedSamples, &_self->doPMarker);
				outputContainsDoP = YES;
			}

			double secondsRendered = (double)renderedSamples / format->mSampleRate;

			if(!directHighPrecision && !outputContainsDoP) {
				scale_by_volume_double(outSamples, frameCount * channels, _self->volume);
			}

			if(!directHighPrecision) {
				const size_t outputSampleCount = (size_t)frameCount * channels;
				if(renderAsFloat32) {
					convertFloat64BufferToF32((float *)inputData->mBuffers[0].mData, outSamples, outputSampleCount);
				} else if(renderAsFloat64) {
					memcpy(inputData->mBuffers[0].mData, outSamples, outputSampleCount * sizeof(double));
				} else if(_self->renderFormatNativeHighPrecision) {
					convertFloat64BufferToFullS32((int32_t *)inputData->mBuffers[0].mData, outSamples, outputSampleCount);
				} else {
					if(!convertFloat64BufferToIntegerPCM(inputData->mBuffers[0].mData,
					                                          outSamples,
					                                          outputSampleCount,
					                                          *renderASBD)) {
						bzero(inputData->mBuffers[0].mData, inputData->mBuffers[0].mDataByteSize);
					}
				}
			}

			[_self updateLatency:secondsRendered];

#ifdef OUTPUT_LOG
			NSData *outData = [NSData dataWithBytes:inputData->mBuffers[0].mData length:inputData->mBuffers[0].mDataByteSize];
			[logFile writeData:outData];
#endif
		}

#ifdef _DEBUG
		if(renderAsFloat32) {
			[BadSampleCleaner cleanSamples:(float *)inputData->mBuffers[0].mData
									amount:inputData->mBuffers[0].mDataByteSize / sizeof(float)
								  location:@"final output"];
		} else if(renderAsFloat64) {
			[BadSampleCleaner cleanSamples64:(double *)inputData->mBuffers[0].mData
									 amount:inputData->mBuffers[0].mDataByteSize / sizeof(double)
								   location:@"final output"];
		}
#endif

		return 0;
	};
	_au.outputProvider = _outputRenderBlock;
}

- (BOOL)setup {
	if(_au)
		[self stop];

	@synchronized(self) {
		stopInvoked = NO;
		stopCompleted = NO;
		commandStop = NO;
		shouldPlayOutBuffer = NO;

		resetStreamFormat = NO;
		streamFormatChanged = NO;
		streamFormatStarted = NO;

		running = NO;
		stopping = NO;
		stopped = NO;
		streamReplacementPending = NO;
		outputDeviceIDChanged = NO;
		paused = NO;
		outputDeviceID = -1;
		restarted = NO;
		preferDoPIntegerOutput = NO;
		renderFormatDoPInteger = NO;
		preferredDoPCarrierSampleRate = 0.0;
		preferNativeHighPrecisionOutput = NO;
		renderFormatNativeHighPrecision = NO;
		bzero(&preferredNativeHighPrecisionFormat, sizeof(preferredNativeHighPrecisionFormat));
		preferIntegerPhysicalOutput = NO;
		renderFormatIntegerPhysical = NO;
		preferredIntegerPhysicalFormats = nil;
		preferExclusiveIntegerTransport = NO;
		renderFormatEndToEndInteger = NO;
		preferredIntegerTransportRequiresHog = NO;
		preferredIntegerVirtualFormats = nil;
		bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));
		preferExclusiveFloatTransport = NO;
		preferredFloatVirtualFormats = nil;
		bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
		savedPhysicalFormatValid = NO;
		savedPhysicalFormatDeviceID = kAudioObjectUnknown;
		savedPhysicalFormats = nil;
		savedVirtualFormatValid = NO;
		savedVirtualFormatDeviceID = kAudioObjectUnknown;
		savedVirtualFormats = nil;
		hogModeOwned = NO;
		hogModeDeviceID = kAudioObjectUnknown;
		exclusiveIOProcID = NULL;
		exclusiveIOProcDeviceID = kAudioObjectUnknown;
		exclusiveIOProcRunning = NO;
		exclusiveMaximumFramesToRender = 0;
		bzero(&renderFormat, sizeof(renderFormat));
		bzero(&sourceFormat, sizeof(sourceFormat));
		sourceChannelConfig = 0;
		sourceFormatValid = NO;

		cutOffInput = NO;
		fadeTarget = 1.0;
		fadeLevel = 1.0;
		fadeStep = 0.0;
		fading = NO;
		faded = NO;
		fadingstop = YES;
		doPActive = NO;
		doPSeekPending = NO;
		doPMarker = 0x05;

		streamTimestamp = 0.0;
		prebufferReached = NO;
		prebufferSignaled = NO;

		AudioComponentDescription desc;
		NSError *err;

		desc.componentType = kAudioUnitType_Output;
		desc.componentSubType = kAudioUnitSubType_HALOutput;
		desc.componentManufacturer = kAudioUnitManufacturer_Apple;
		desc.componentFlags = 0;
		desc.componentFlagsMask = 0;

		_au = [[AUAudioUnit alloc] initWithComponentDescription:desc error:&err];
		if(err != nil)
			return NO;

		// Setup the output device before mucking with settings
		NSDictionary *device = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] objectForKey:@"outputDevice"];
		if(device) {
			BOOL ok = [self setOutputDeviceWithDeviceDict:device];
			if(!ok) {
				// Ruh roh.
				[self setOutputDeviceWithDeviceDict:nil];

				[[[NSUserDefaultsController sharedUserDefaultsController] defaults] removeObjectForKey:@"outputDevice"];
			}
		} else {
			[self setOutputDeviceWithDeviceDict:nil];
		}

		suspendOutputOnPause = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] boolForKey:@"suspendOutputOnPause"];
		exclusiveOutputEnabled = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] boolForKey:@"exclusiveIntegerOutput"];
		setDeviceVolumeTo100ForExclusiveOutput = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] boolForKey:@"setDeviceVolumeTo100ForExclusiveOutput"];

		[self audioOutputBlock];

		if(![self updateDeviceFormat]) {
			return NO;
		}

		err = nil;
		if(![_au allocateRenderResourcesAndReturnError:&err] || err != nil) {
			return NO;
		}

		visController = [VisualizationController sharedController];

		hrtfNode = [[DSPHRTFNode alloc] initWithController:self previous:self latency:0.03];
		downmixNode = [[DSPDownmixNode alloc] initWithController:self previous:hrtfNode latency:0.03];
		faderNode = [[DSPFaderNode alloc] initWithController:self previous:downmixNode latency:0.03];

		bufferNode = [[SimpleBuffer alloc] initWithController:self previous:faderNode latency:0.1];

		[self setShouldContinue:YES];
		[self setEndOfStream:NO];

		[hrtfNode setResetBarrier:YES];
		[downmixNode setOutputFormat:deviceFormat withChannelConfig:deviceChannelConfig];

		DSPsLaunched = YES;
		[self launchDSPs];
		[bufferNode launchThread];

		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.outputDevice" options:0 context:kOutputCoreAudioContext];
		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.suspendOutputOnPause" options:0 context:kOutputCoreAudioContext];
		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.exclusiveIntegerOutput" options:0 context:kOutputCoreAudioContext];
		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.setDeviceVolumeTo100ForExclusiveOutput" options:0 context:kOutputCoreAudioContext];
		for(NSString *keyPath in signalIntegrityPreferenceKeyPaths()) {
			[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:keyPath options:0 context:kOutputCoreAudioContext];
		}

		observersapplied = YES;
		
		return (err == nil);
	}
}

- (void)updateLatency:(double)secondsPlayed {
	double visLatency = [outputController getVisLatency];
	double fullLatency = [outputController getTotalLatency];
	// A manual replacement reuses this Core Audio output while the outgoing
	// render callback may still be completing. Do not let its final timestamp
	// repopulate the new track's position after AudioPlayer reset it to zero;
	// a concurrent device-format notification would otherwise seek the new
	// decoder to that stale position (for example, 15 seconds into PCM after
	// switching from a DSD track played for 15 seconds).
	if(secondsPlayed > 0 && !streamReplacementPending) {
		[outputController setAmountPlayed:streamTimestamp];
	}
	[visController postLatency:visLatency];
	[visController postFullLatency:fullLatency];
}

- (double)volume {
	return volume * 100.0;
}

- (void)setVolume:(double)v {
	volume = v * 0.01;
	[self refreshOutputStatus];
}

- (double)latency {
	return [buffer listDuration] + [[hrtfNode buffer] listDuration] + [[downmixNode buffer] listDuration] + [[faderNode buffer] listDuration] + [[bufferNode buffer] listDuration];
}

- (void)start {
	[self threadEntry:nil];
}

- (void)stop {
	commandStop = YES;
	[self doStop];
}

- (BOOL)beginStreamReplacement {
	@synchronized(self) {
		if(_au == nil || !running || stopping || stopped || stopInvoked || streamReplacementPending) {
			return NO;
		}
		streamReplacementPending = YES;
		return YES;
	}
}

- (void)finishStreamReplacement {
	@synchronized(self) {
		streamReplacementPending = NO;
	}
}

- (void)doStop {
	if(stopInvoked) {
		return;
	}
	@synchronized(self) {
		stopInvoked = YES;
		[self stopIdle];
		if(observersapplied) {
			[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.outputDevice" context:kOutputCoreAudioContext];
			[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.suspendOutputOnPause" context:kOutputCoreAudioContext];
			[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.exclusiveIntegerOutput" context:kOutputCoreAudioContext];
			[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.setDeviceVolumeTo100ForExclusiveOutput" context:kOutputCoreAudioContext];
			for(NSString *keyPath in signalIntegrityPreferenceKeyPaths()) {
				[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:keyPath context:kOutputCoreAudioContext];
			}
			observersapplied = NO;
		}
		stopping = YES;
		paused = NO;
		if(defaultdevicelistenerapplied || currentdevicelistenerapplied || devicealivelistenerapplied) {
			AudioObjectPropertyAddress theAddress = {
				.mScope = kAudioObjectPropertyScopeGlobal,
				.mElement = kAudioObjectPropertyElementMaster
			};
			if(defaultdevicelistenerapplied) {
				theAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
				AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &theAddress, default_device_changed, (__bridge void *_Nullable)(self));
				defaultdevicelistenerapplied = NO;
			}
			if(devicealivelistenerapplied) {
				theAddress.mSelector = kAudioDevicePropertyDeviceIsAlive;
				AudioObjectRemovePropertyListener(outputDeviceID, &theAddress, current_device_listener, (__bridge void *_Nullable)(self));
				devicealivelistenerapplied = NO;
			}
			if(currentdevicelistenerapplied) {
				theAddress.mSelector = kAudioDevicePropertyStreamFormat;
				AudioObjectRemovePropertyListener(outputDeviceID, &theAddress, current_device_listener, (__bridge void *_Nullable)(self));
				theAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
				AudioObjectRemovePropertyListener(outputDeviceID, &theAddress, current_device_listener, (__bridge void *_Nullable)(self));
				currentdevicelistenerapplied = NO;
			}
		}
		if(_au) {
			if(shouldPlayOutBuffer && !commandStop) {
				double compareVal = 0;
				double secondsLatency = [outputController getTotalLatency];
				int compareMax = (((1000000 / 5000) * secondsLatency) + (10000 / 5000)); // latency plus 10ms, divide by sleep intervals
				do {
					compareVal = [outputController getTotalLatency];
					usleep(5000);
				} while(!commandStop && compareVal > 0 && compareMax-- > 0);
			} else {
				[self fadeOut];
				BOOL faderNodeFading = [faderNode fading];
				if(faderNodeFading) {
					while(!faded && [faderNode fading]) {
						usleep(10000);
					}
				} else {
					while(!faded && ![[bufferNode buffer] isEmpty]) {
						usleep(10000);
					}
				}
				if(faderNodeFading) {
					[faderNode setEndOfStream:YES];
					[faderNode setShouldContinue:NO];
					while(!faded && ![bufferNode endOfStream]) {
						usleep(10000);
					}
				}
			}
			[self stopCurrentHardware];
			if(_au.renderResourcesAllocated) {
				[_au deallocateRenderResources];
			}
			[self destroyExclusiveIOProc];
			BOOL restoredStreamFormats = [self restoreSavedPhysicalFormatSetAtCurrentSampleRate];
			if(!restoredStreamFormats) {
				ALog(@"Unable to restore the device's previous physical output format");
			}
			restoredStreamFormats = [self restoreSavedVirtualFormatSetAtCurrentSampleRate] && restoredStreamFormats;
			if(!restoredStreamFormats) {
				ALog(@"Unable to restore all previous device stream formats; selecting mixable fallbacks");
				[self ensureMixableStreamFormatsForAUHAL];
			}
			if(![self releaseHogModeForCurrentDevice]) {
				ALog(@"Unable to release exclusive ownership of the output device");
			}
			_au = nil;
			_outputRenderBlock = nil;
		}
		if(outputDoubleScratch) {
			free(outputDoubleScratch);
			outputDoubleScratch = NULL;
		}
		if(inputDoubleScratch) {
			free(inputDoubleScratch);
			inputDoubleScratch = NULL;
		}
		outputDoubleScratchCapacity = 0;
		if(running) {
			while(!stopped) {
				stopping = YES;
				usleep(5000);
			}
		}
		if(DSPsLaunched) {
			[self setShouldContinue:NO];
			[hrtfNode setShouldContinue:NO];
			[downmixNode setShouldContinue:NO];
			[faderNode setShouldContinue:NO];
			hrtfNode = nil;
			downmixNode = nil;
			faderNode = nil;
			DSPsLaunched = NO;
		}
		if(bufferNode) {
			[bufferNode setShouldContinue:NO];
			bufferNode = nil;
		}
#ifdef OUTPUT_LOG
		if(_logFile) {
			[_logFile closeFile];
			_logFile = NULL;
		}
#endif
		outputController = nil;
		if(visController) {
			[visController reset];
			visController = nil;
		}
		prebufferReached = NO;
		prebufferSignaled = NO;
		[self postOutputFormatDescription:nil];
		stopCompleted = YES;
	}
}

- (void)dealloc {
	fadingstop = NO;
	[self stop];
	// In case stop called on another thread first
	while(!stopCompleted) {
		usleep(500);
	}
}

- (void)pause {
	paused = YES;
	if(started)
		[self stopCurrentHardware];
}

- (BOOL)hardwareIsRunning {
	return exclusiveIOProcID ? exclusiveIOProcRunning : (_au != nil && _au.isRunning);
}

- (void)resume {
	[self stopIdle];
	NSError *err = nil;
	if(_au && !exclusiveIOProcID && !_au.renderResourcesAllocated) {
		if(![_au allocateRenderResourcesAndReturnError:&err] || err != nil) {
			ALog(@"Unable to restore Core Audio render resources: %@", err);
			paused = NO;
			started = NO;
			return;
		}
		err = nil;
	}
	BOOL hardwareStarted = [self hardwareIsRunning];
	if(!hardwareStarted) {
		hardwareStarted = [self startCurrentHardware:&err];
		if(!hardwareStarted && exclusiveIOProcID && sourceFormatValid) {
			// Registration can succeed even when a driver rejects AudioDeviceStart.
			// Restore the device's mixable virtual format and retry through AUHAL so
			// opting into exclusive mode can never turn a playable track into silence.
			ALog(@"Direct HAL output could not start; retrying with shared Core Audio output: %@", err);
			const BOOL sourceConvertsDSDToPCM = sourceFormat.mBitsPerChannel == 1 && !renderFormatDoPInteger;
			if(AudioFormatIsFloat32(sourceFormat) || AudioFormatIsFloat64(sourceFormat) || sourceConvertsDSDToPCM) {
				preferExclusiveFloatTransport = NO;
				preferredFloatVirtualFormats = nil;
				bzero(&preferredFloatClientFormat, sizeof(preferredFloatClientFormat));
				preferExclusiveIntegerTransport = NO;
				preferredIntegerTransportRequiresHog = NO;
				preferredIntegerVirtualFormats = nil;
				preferIntegerPhysicalOutput = NO;
				preferredIntegerPhysicalFormats = nil;
				bzero(&preferredIntegerClientFormat, sizeof(preferredIntegerClientFormat));
			} else {
				const BOOL requireDoPCarrier = renderFormatDoPInteger;
				const UInt32 requiredBits = requireDoPCarrier ? 24 : sourceFormat.mBitsPerChannel;
				[self configureSharedIntegerOutputAtSampleRate:renderFormat.mSampleRate
				                                      requiredBits:requiredBits
				                                 requireDoPCarrier:requireDoPCarrier];
			}
			if([self applyDeviceSampleRateAndFormat:renderFormat.mSampleRate]) {
				[self refreshOutputStatus];
				err = nil;
				hardwareStarted = [self startCurrentHardware:&err];
			}
		}
		if(!hardwareStarted) {
			hardwareStarted = [self hardwareIsRunning];
		}
	}
	paused = NO;
	started = hardwareStarted;
	if(started) {
		restarted = NO;
	} else {
		// Do not cache a track as successfully prepared when AUHAL cannot start.
		// Re-run device-format discovery on the output thread and force the next
		// manual attempt to negotiate its source format again.
		sourceFormatValid = NO;
		outputdevicechanged = YES;
		if(!restarted) {
			ALog(@"Unable to start Core Audio output; playback thread will retry: %@", err);
			restarted = YES;
		}
		// Avoid a tight retry loop while a device is still settling after its
		// sample-rate and integer-carrier format transition.
		usleep(10000);
	}
}

- (void)sustainHDCD {
	secondsHdcdSustained = 10.0;
	[self refreshOutputStatus];
}

- (void)setShouldPlayOutBuffer:(BOOL)s {
	shouldPlayOutBuffer = s;
}

- (AudioStreamBasicDescription)deviceFormat {
	return deviceFormat;
}

- (uint32_t)deviceChannelConfig {
	return deviceChannelConfig;
}

- (void)fadeOut {
	if(!playbackFadesEnabled()) {
		fadeTarget = 0.0;
		fadeLevel = 0.0;
		fadeStep = 0.0;
		fading = NO;
		faded = YES;
		return;
	}
	fadeTarget = 0.0;
	fadeStep = ((fadeTarget - fadeLevel) / deviceFormat.mSampleRate) * (1000.0 / fadeTimeMS);
	fading = YES;
}

- (void)fadeOutBackground {
	cutOffInput = YES;

	[bufferNode setPreviousNode:nil];
	[hrtfNode setPreviousNode:nil];

	DSPHRTFNode *oldHrtf = hrtfNode;
	DSPDownmixNode *oldDownmix = downmixNode;
	DSPFaderNode *oldFader = faderNode;

	double fadeLevel = [oldFader fadeLevel];

	hrtfNode = [[DSPHRTFNode alloc] initWithController:self previous:nil latency:0.03];
	downmixNode = [[DSPDownmixNode alloc] initWithController:self previous:hrtfNode latency:0.03];
	faderNode = [[DSPFaderNode alloc] initWithController:self previous:nil latency:0.03];
	[faderNode setDoPMode:doPActive];
	[hrtfNode setResetBarrier:YES];
	[downmixNode setOutputFormat:deviceFormat withChannelConfig:deviceChannelConfig];
	faderNode.timestamp = oldFader.timestamp;

	ChunkList *oldBuffer = buffer;
	buffer = [[ChunkList alloc] initWithMaximumDuration:2.0f * (fadeTimeMS / 1000.0f)];
	// DoP cannot be crossfaded: a seek may otherwise combine buffered frames
	// from before and after the discontinuity, corrupting the DSD payload.
	const BOOL fadesEnabled = playbackFadesEnabled() && !doPActive;
	FadedBuffer *fbuffer = nil;
	if(fadesEnabled) {
		fbuffer = [[FadedBuffer alloc] initWithBuffer:oldBuffer withDSPs:@[oldHrtf, oldDownmix, oldFader] fadeStart:fadeLevel fadeTarget:0.0 sampleRate:deviceFormat.mSampleRate];
	}

	[hrtfNode setPreviousNode:self];
	[bufferNode setPreviousNode:faderNode];
	[self launchDSPs];

	if(fadesEnabled) {
		[faderNode appendFadeOut:fbuffer];
	} else {
		[oldHrtf setShouldContinue:NO];
		[oldDownmix setShouldContinue:NO];
		[oldFader setShouldContinue:NO];
		[bufferNode resetBuffer];
		fbuffer = nil;
	}
	oldBuffer = nil;
	oldHrtf = nil;
	oldDownmix = nil;
	oldFader = nil;

	cutOffInput = NO;
}

- (void)beginSeek {
	// fadeOutBackground has already detached and drained the old path. If the
	// active stream is DoP, keep emitting valid DoP silence until the new path
	// supplies a completely verified carrier buffer.
	doPSeekPending = doPActive;
}

- (void)fadeIn {
	[self stopIdle];
	if(!playbackFadesEnabled()) {
		fadeLevel = 1.0;
		fadeTarget = 1.0;
		fadeStep = 0.0;
		fading = NO;
		faded = NO;
		return;
	}
	if(fading || faded) {
		fadeLevel = 0.0;
		fadeTarget = 1.0;
		fadeStep = ((fadeTarget - fadeLevel) / deviceFormat.mSampleRate) * (1000.0 / fadeTimeMS);
		fading = YES;
		faded = NO;
	} else {
		[self faderFadeIn];
	}
}

- (void)faderFadeIn {
	[self stopIdle];
	// Stream replacement fades the new input at the DSP fader. Make sure the
	// separate final-output fade gate is open as well: a DSD pause completes
	// that gate as a hard fade, and reusing the output without clearing it
	// otherwise leaves AUHAL running while it emits only carrier silence.
	fadeLevel = 1.0;
	fadeTarget = 1.0;
	fadeStep = 0.0;
	fading = NO;
	faded = NO;
	if(playbackFadesEnabled() || doPActive) {
		[faderNode fadeIn];
	} else {
		[faderNode waitForReset];
	}
	[faderNode setPreviousNode:downmixNode];
	prebufferSignaled = NO;
}

- (void)timeOut {
	if(!suspendOutputOnPause)
		return;

	idleTimer = [NSTimer timerWithTimeInterval:10.0
									   repeats:NO
										 block:^(NSTimer * _Nonnull timer) {
		[self pause];
	}];
	[[NSRunLoop currentRunLoop] addTimer:idleTimer forMode:NSRunLoopCommonModes];
}

- (void)stopIdle {
	if(idleTimer) {
		[idleTimer invalidate];
		idleTimer = nil;
	}
}

@end
