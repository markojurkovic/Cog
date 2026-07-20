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

#import <CogAudio/VisualizationController.h>

#ifdef OUTPUT_LOG
#import <NSFileHandle+CreateFile.h>
#endif

static NSNotificationName CogPlaybackDidPrebufferNotification = @"CogPlaybackDidPrebufferNotification";

extern void scale_by_volume_double(double *buffer, size_t count, double volume);

static NSNotificationName CogPlaybackDidBeginNotificiation = @"CogPlaybackDidBeginNotificiation";

NSNotificationName const CogCoreAudioOutputFormatDidChangeNotification = @"CogCoreAudioOutputFormatDidChangeNotification";
NSString *const CogCoreAudioOutputFormatDescriptionKey = @"CogCoreAudioOutputFormatDescription";
NSString *const CogCoreAudioDeviceFormatDescriptionKey = @"CogCoreAudioDeviceFormatDescription";
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

	return [NSString stringWithFormat:@"%@ · %@ · %@",
	                                  formatName,
	                                  outputSampleRateDescription(format.mSampleRate),
	                                  bitDepthDescription];
}

static NSString *physicalOutputFormatDescription(AudioDeviceID deviceID) {
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
		.mSelector = kAudioStreamPropertyPhysicalFormat,
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

@interface OutputCoreAudio ()
- (double)currentDeviceSampleRate;
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
		if(hdcdDetected && [defaults boolForKey:@"enableHDCD"]) {
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
		NSString *deviceDescription = physicalOutputFormatDescription(outputDeviceID);
		NSMutableDictionary *formatInfo = [@{ CogCoreAudioOutputFormatDescriptionKey: description } mutableCopy];
		[formatInfo addEntriesFromDictionary:[self signalIntegrityInfo]];
		if(deviceDescription) {
			formatInfo[CogCoreAudioDeviceFormatDescriptionKey] = deviceDescription;
		}
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
			case kAudioDevicePropertyDeviceIsAlive:
				return [_self setOutputDeviceByID:-1];

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
				BOOL devicePrepared = [self updateDeviceFormat];
				if(devicePrepared && !_au.renderResourcesAllocated) {
					NSError *resourceError = nil;
					devicePrepared = [_au allocateRenderResourcesAndReturnError:&resourceError] && resourceError == nil;
				}
				if(devicePrepared) {
					outputdevicechanged = NO;
				} else {
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

			// AUHAL may immediately restart the new device with the old input-bus
			// format. Keep that short transition silent until the output thread has
			// renegotiated the active source for the new device capabilities.
			resetting = YES;
			NSError *nserr;
			[_au setDeviceID:outputDeviceID error:&nserr];
			if(nserr != nil) {
				resetting = NO;
				return (OSErr)[nserr code];
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

static BOOL inputFormatUsesDoPCarrierRate(AudioStreamBasicDescription inputFormat) {
	if(inputFormat.mBitsPerChannel == 1) {
		return YES;
	}

	const BOOL isFloat = !!(inputFormat.mFormatFlags & kAudioFormatFlagIsFloat);
	return !isFloat &&
	       inputFormat.mBitsPerChannel >= 24 &&
	       inputFormat.mSampleRate >= 176400.0;
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

static int32_t convertDoPFloat64ToS32(double sample) {
	const double scaled = sample * 2147483648.0;
	int32_t packed = (int32_t)llrint(scaled);
	return (int32_t)(((uint32_t)packed) & 0xFFFFFF00U);
}

static int32_t convertPCMFloat64ToS32(double sample) {
	if(isnan(sample)) return 0;
	if(sample >= 1.0) return (int32_t)(((uint32_t)INT32_MAX) & 0xFFFFFF00U);
	if(sample <= -1.0) return INT32_MIN;
	// Integer PCM is normalized by dividing by 2^31. Use the exact inverse
	// here: multiplying by INT32_MAX loses one 24-bit LSB in the upper half
	// of the positive range before the 24-bit carrier mask is applied.
	int64_t scaled = llrint(sample * 2147483648.0);
	if(scaled > INT32_MAX) scaled = INT32_MAX;
	if(scaled < INT32_MIN) scaled = INT32_MIN;
	return (int32_t)(((uint32_t)scaled) & 0xFFFFFF00U);
}

static void convertFloat64BufferToS32(int32_t *output, const double *input, size_t count, BOOL isDoP) {
	for(size_t i = 0; i < count; ++i) {
		output[i] = isDoP ? convertDoPFloat64ToS32(input[i]) : convertPCMFloat64ToS32(input[i]);
	}
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
	const size_t maximumFrames = (size_t)_au.maximumFramesToRender;
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
	AVAudioFormat *format = _au.outputBusses[0].format;
	if(!format) {
		return NO;
	}

	const BOOL targetDoPInteger = preferDoPIntegerOutput;
	const BOOL targetNativeHighPrecision = preferNativeHighPrecisionOutput && !targetDoPInteger;
	const BOOL nativeFormatChanged = targetNativeHighPrecision &&
	                                memcmp(&renderFormat, &preferredNativeHighPrecisionFormat, sizeof(renderFormat)) != 0;
	const BOOL requestedSampleRateChanged = requestedSampleRate > 0.0 &&
	                                        fabs(renderFormat.mSampleRate - requestedSampleRate) >= 1.0;
	if(outputDeviceIDChanged || !_deviceFormat || ![_deviceFormat isEqual:format] ||
	   renderFormatDoPInteger != targetDoPInteger ||
	   renderFormatNativeHighPrecision != targetNativeHighPrecision ||
	   nativeFormatChanged || requestedSampleRateChanged) {
		NSError *err = nil;
		AVAudioFormat *renderAVFormat;

		_deviceFormat = format;
		deviceFormat = *(format.streamDescription);

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
		deviceFormat.mBytesPerFrame = deviceFormat.mChannelsPerFrame * (deviceFormat.mBitsPerChannel / 8);
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
		} else {
			renderFormat = deviceFormat;
		}
		renderAVFormat = [[AVAudioFormat alloc] initWithStreamDescription:&renderFormat channelLayout:[[AVAudioChannelLayout alloc] initWithLayoutTag:tag]];
		resetting = YES;
		[_au stopHardware];
		if(renderAVFormat) {
			[_au.inputBusses[0] setFormat:renderAVFormat error:&err];
		}
		// DoP is already a packed bitstream at this point. A float fallback would
		// corrupt it, so leave the previous bus representation in place and let the
		// enclosing transaction restore the previous device clock.
		if((!renderAVFormat || err != nil) && targetDoPInteger) {
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

		if(notifyController) {
			[outputController setFormat:&deviceFormat channelConfig:deviceChannelConfig];
		}
		
		[outputLock lock];
		[buffer reset];
		[self setShouldReset:YES];
		[outputLock unlock];

		resetting = NO;
	}

	// Logical tracks from the same source (for example, adjacent entries in a
	// cue sheet) normally keep the existing AUHAL format. Re-publish it after
	// every successful preparation so a track transition cannot leave a stale
	// stopped-state indication merely because no hardware format changed.
	[self postOutputFormatDescription:outputFormatDescription(renderFormat, renderFormatDoPInteger)];
	return YES;
}

- (BOOL)applyDeviceSampleRateAndFormat:(double)sampleRate {
	@synchronized(self) {
		// AUHAL owns the device stream while its render resources are allocated,
		// even after a long pause has stopped the hardware. Release that ownership
		// before asking the DAC to change clocks or carrier representation.
		const BOOL hardwareWasRunning = [self hardwareIsRunning];
		const BOOL renderResourcesWereAllocated = _au.renderResourcesAllocated;
		const BOOL previousPaused = paused;
		const double previousSampleRate = [self currentDeviceSampleRate];
		AVAudioFormat *previousInputFormat = _au.inputBusses[0].format;
		AVAudioFormat *previousDeviceAVFormat = _deviceFormat;
		const AudioStreamBasicDescription previousDeviceFormat = deviceFormat;
		const AudioStreamBasicDescription previousRenderFormat = renderFormat;
		const uint32_t previousDeviceChannelConfig = deviceChannelConfig;
		const BOOL previousRenderFormatDoPInteger = renderFormatDoPInteger;
		const BOOL previousRenderFormatNativeHighPrecision = renderFormatNativeHighPrecision;

		resetting = YES;
		if(hardwareWasRunning) {
			[_au stopHardware];
		}
		if(renderResourcesWereAllocated) {
			[_au deallocateRenderResources];
		}

		BOOL prepared = [self setDeviceSampleRate:sampleRate];
		if(prepared) {
			outputdevicechanged = YES;
			prepared = [self updateDeviceFormatLockedNotifyingController:NO requestedSampleRate:sampleRate];
		}

		NSError *resourceError = nil;
		if(prepared) {
			prepared = [_au allocateRenderResourcesAndReturnError:&resourceError] && resourceError == nil;
		}
		AVAudioFormat *configuredInputFormat = _au.inputBusses[0].format;
		if(prepared && (!configuredInputFormat || fabs(configuredInputFormat.sampleRate - sampleRate) >= 1.0)) {
			ALog(@"Core Audio retained a stale input-bus rate (requested %.0f Hz, got %.0f Hz)",
			     sampleRate, configuredInputFormat ? configuredInputFormat.sampleRate : 0.0);
			prepared = NO;
		}

		if(!prepared) {
			ALog(@"Unable to apply Core Audio device format; restoring the previous output: %@", resourceError);
			[_au stopHardware];
			if(_au.renderResourcesAllocated) {
				[_au deallocateRenderResources];
			}

			// Restore the preferences that describe the last format AUHAL actually
			// rendered, rather than leaving a rejected DoP request latched.
			preferDoPIntegerOutput = previousRenderFormatDoPInteger;
			preferredDoPCarrierSampleRate = previousRenderFormatDoPInteger ? previousRenderFormat.mSampleRate : 0.0;
			preferNativeHighPrecisionOutput = previousRenderFormatNativeHighPrecision;
			if(previousRenderFormatNativeHighPrecision) {
				preferredNativeHighPrecisionFormat = previousRenderFormat;
			} else {
				bzero(&preferredNativeHighPrecisionFormat, sizeof(preferredNativeHighPrecisionFormat));
			}

			BOOL restored = YES;
			if(previousSampleRate > 0.0 && fabs(previousSampleRate - [self currentDeviceSampleRate]) >= 1.0) {
				restored = [self setDeviceSampleRate:previousSampleRate];
			}
			NSError *rollbackError = nil;
			if(previousInputFormat) {
				[_au.inputBusses[0] setFormat:previousInputFormat error:&rollbackError];
				restored = restored && rollbackError == nil;
			} else {
				restored = NO;
			}

			_deviceFormat = previousDeviceAVFormat;
			deviceFormat = previousDeviceFormat;
			renderFormat = previousRenderFormat;
			deviceChannelConfig = previousDeviceChannelConfig;
			renderFormatDoPInteger = previousRenderFormatDoPInteger;
			renderFormatNativeHighPrecision = previousRenderFormatNativeHighPrecision;
			rollbackError = nil;
			restored = [_au allocateRenderResourcesAndReturnError:&rollbackError] && rollbackError == nil && restored;
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
		if(hardwareWasRunning) {
			[_au stopHardware];
		}
		if(renderResourcesWereAllocated) {
			[_au deallocateRenderResources];
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

		BOOL prepared = [self updateDeviceFormatLockedNotifyingController:notifyController requestedSampleRate:requestedSampleRate];
		if(renderResourcesWereAllocated) {
			NSError *resourceError = nil;
			prepared = [_au allocateRenderResourcesAndReturnError:&resourceError] && resourceError == nil && prepared;
		}
		AVAudioFormat *configuredInputFormat = _au.inputBusses[0].format;
		if(prepared && (!configuredInputFormat ||
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
	return [self updateDeviceFormatNotifyingController:YES];
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
	// Native DSD can be converted to PCM when the selected device cannot run
	// the required DoP carrier clock. An already packed DoP/PCM stream cannot
	// be resampled without corrupting its marker and payload bytes, so keep the
	// strict failure behavior for that representation.
	const BOOL usesDoPCarrier = !highPrecisionPCM &&
	                            inputFormatUsesDoPCarrierRate(inputFormat) &&
	                            (!nativeDSD || sampleRateSupported);
	if(nativeDSD && !sampleRateSupported) {
		DLog(@"DoP carrier rate %.0f Hz is unavailable; converting native DSD to %.0f Hz PCM", sampleRate, outputSampleRate);
	}

	if(!usesDoPCarrier) {
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

		// A matching hardware clock is a prerequisite for bit-perfect PCM.
		// Unsupported rates still play through the existing converter fallback.
		if(outputSampleRateSupported) {
			// The queued converter was intentionally configured for this source
			// rate. Do not silently hand it to AUHAL for hidden SRC if the clock
			// and render-format transition cannot be completed together.
			BOOL prepared = [self applyDeviceSampleRateAndFormat:outputSampleRate];
			if(prepared) {
				sourceFormat = inputFormat;
				sourceChannelConfig = inputChannelConfig;
				sourceFormatValid = inputFormatValid;
				hdcdDetected = NO;
			}
			return prepared;
		}

		if(renderFormatDoPInteger || renderFormatNativeHighPrecision) {
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
		hdcdDetected = NO;
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
	BOOL prepared = [self applyDeviceSampleRateAndFormat:sampleRate];
	if(prepared && renderFormatDoPInteger) {
		sourceFormat = inputFormat;
		sourceChannelConfig = inputChannelConfig;
		sourceFormatValid = inputFormatValid;
		hdcdDetected = NO;
		[faderNode setDoPMode:YES];
		return YES;
	}

	// Native DSD has already been packed as a DoP carrier by the converter.
	// Continuing through a float fallback would corrupt its marker and payload
	// bytes while still presenting the stream as successfully prepared.
	doPSeekPending = NO;
	preferDoPIntegerOutput = NO;
	preferredDoPCarrierSampleRate = 0.0;
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

	_au.outputProvider = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *_Nonnull actionFlags, const AudioTimeStamp *_Nonnull timestamp, AUAudioFrameCount frameCount, NSInteger inputBusNumber, AudioBufferList *_Nonnull inputData) {
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
						chunk = [self->bufferNode.buffer removeSamples:frameCount - renderedSamples];
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
						chunk = [self->bufferNode.buffer removeSamples:frameCount - renderedSamples];
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
						BOOL inputIsDoP = audioBufferIsDoP64(samplePtr, channels, inputTodo, &nextDoPMarker);

						if(_self->doPSeekPending && !inputIsDoP) {
							// Never expose transitional or stale PCM-looking data while a
							// DoP seek is waiting for the first verified post-seek carrier.
							fillDoPSilence64(outSamples + renderedSamples * channels, channels, inputTodo, &_self->doPMarker);
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
				fillDoPSilence64(outSamples + renderedSamples * channels, channels, frameCount - renderedSamples, &_self->doPMarker);
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
					convertFloat64BufferToS32((int32_t *)inputData->mBuffers[0].mData, outSamples, outputSampleCount, outputContainsDoP);
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
		bzero(&renderFormat, sizeof(renderFormat));
		bzero(&sourceFormat, sizeof(sourceFormat));
		sourceChannelConfig = 0;
		sourceFormatValid = NO;
		hdcdDetected = NO;

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
			[_au stopHardware];
			_au = nil;
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
		[_au stopHardware];
}

- (BOOL)hardwareIsRunning {
	return _au != nil && _au.isRunning;
}

- (void)resume {
	[self stopIdle];
	NSError *err = nil;
	if(_au && !_au.renderResourcesAllocated) {
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
		hardwareStarted = [_au startHardwareAndReturnError:&err];
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
	if(!hdcdDetected) {
		hdcdDetected = YES;
		[self refreshOutputStatus];
	}
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
