//
//  OutputAVFoundation.m
//  Cog
//
//  Created by Christopher Snowhill on 6/23/22.
//  Copyright 2022 Christopher Snowhill. All rights reserved.
//

#import "OutputAVFoundation.h"
#import "OutputNode.h"

#ifdef _DEBUG
#import "BadSampleCleaner.h"
#endif

#import "Logging.h"

#import <Accelerate/Accelerate.h>
#import <CogAudio/soxr.h>

#import "AudioChunk.h"
#import "FSurroundFilter.h"

extern void scale_by_volume_double(double *buffer, size_t count, double volume);

typedef struct {
	int channelCount;
	uint64_t inProcessed;
	uint64_t outProcessed;
	double sampleRatio;
	double dstRate;
	double *silenceBuffer;
	soxr_t resampler;
} AVFFloat64Resampler;

static void *AVFFloat64ResamplerCreate(int channelCount, double srcRate, double dstRate) {
	AVFFloat64Resampler *state = calloc(1, sizeof(*state));
	if(!state) return NULL;

	state->channelCount = channelCount;
	state->sampleRatio = dstRate / srcRate;
	state->dstRate = dstRate;
	state->silenceBuffer = calloc((size_t)1024 * channelCount, sizeof(double));
	if(!state->silenceBuffer) {
		free(state);
		return NULL;
	}

	soxr_error_t error = NULL;
	soxr_io_spec_t ioSpec = soxr_io_spec(SOXR_FLOAT64_I, SOXR_FLOAT64_I);
	soxr_quality_spec_t qualitySpec = soxr_quality_spec(SOXR_HQ, SOXR_DOUBLE_PRECISION);
	soxr_runtime_spec_t runtimeSpec = soxr_runtime_spec(0);
	state->resampler = soxr_create(srcRate, dstRate, (unsigned)channelCount, &error, &ioSpec, &qualitySpec, &runtimeSpec);
	if(error || !state->resampler) {
		free(state->silenceBuffer);
		free(state);
		return NULL;
	}

	return state;
}

static void AVFFloat64ResamplerDelete(void *opaqueState) {
	AVFFloat64Resampler *state = opaqueState;
	if(!state) return;
	if(state->resampler) soxr_delete(state->resampler);
	free(state->silenceBuffer);
	free(state);
}

static double AVFFloat64ResamplerLatency(void *opaqueState) {
	AVFFloat64Resampler *state = opaqueState;
	if(!state || state->dstRate <= 0.0) return 0.0;
	return (((double)state->inProcessed * state->sampleRatio) - (double)state->outProcessed) / state->dstRate;
}

static int AVFFloat64ResamplerProcess(void *opaqueState, const double *input, size_t inCount, size_t *inDone, double *output, size_t outMax) {
	AVFFloat64Resampler *state = opaqueState;
	if(!state || !inDone) return 0;

	size_t outDone = 0;
	soxr_error_t error = soxr_process(state->resampler, input, inCount, inDone, output, outMax, &outDone);
	if(error) return 0;

	state->inProcessed += *inDone;
	state->outProcessed += outDone;
	return (int)outDone;
}

static int AVFFloat64ResamplerFlush(void *opaqueState, double *output, size_t outMax, BOOL *drained) {
	AVFFloat64Resampler *state = opaqueState;
	if(drained) *drained = YES;
	if(!state) return 0;

	size_t outTotal = 0;
	const uint64_t outputWanted = (uint64_t)ceil((double)state->inProcessed * state->sampleRatio);
	while(state->outProcessed < outputWanted && outMax) {
		size_t outWanted = (size_t)(outputWanted - state->outProcessed);
		outWanted = MIN(outWanted, outMax);

		size_t inDone = 0;
		size_t outDone = 0;
		soxr_error_t error = soxr_process(state->resampler, state->silenceBuffer, 1024, &inDone, output, outWanted, &outDone);
		if(error || (!inDone && !outDone)) break;

		state->outProcessed += outDone;
		outTotal += outDone;
		output += outDone * state->channelCount;
		outMax -= outDone;
	}

	if(drained) *drained = state->outProcessed >= outputWanted;
	return (int)outTotal;
}

static NSString *CogPlaybackDidBeginNotficiation = @"CogPlaybackDidBeginNotficiation";

@implementation OutputAVFoundation

static void *kOutputAVFoundationContext = &kOutputAVFoundationContext;

static void fillBuffers(AudioBufferList *ioData, const double *inbuffer, size_t count, size_t offset) {
	const size_t channels = ioData->mNumberBuffers;
	for(int i = 0; i < channels; ++i) {
		const size_t maxCount = (ioData->mBuffers[i].mDataByteSize / sizeof(float)) - offset;
		float *output = ((float *)ioData->mBuffers[i].mData) + offset;
		const double *input = inbuffer + i;
		vDSP_vdpsp(input, channels, output, 1, MIN(count, maxCount));
		ioData->mBuffers[i].mNumberChannels = 1;
	}
}

static void clearBuffers(AudioBufferList *ioData, size_t count, size_t offset) {
	for(int i = 0; i < ioData->mNumberBuffers; ++i) {
		memset(((uint8_t *)ioData->mBuffers[i].mData) + offset * sizeof(float), 0, count * sizeof(float));
		ioData->mBuffers[i].mNumberChannels = 1;
	}
}

static OSStatus eqRenderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
	if(inNumberFrames > 4096 || !inRefCon) {
		clearBuffers(ioData, inNumberFrames, 0);
		return 0;
	}

	OutputAVFoundation *_self = (__bridge OutputAVFoundation *)inRefCon;

	fillBuffers(ioData, _self->samplePtr, inNumberFrames, 0);

	return 0;
}

- (int)renderInput:(int)amountToRead toBuffer:(double *)buffer {
	int amountRead = 0;

	if(stopping == YES || [outputController shouldContinue] == NO) {
		// Chain is dead, fill out the serial number pointer forever with silence
		stopping = YES;
		return 0;
	}

	AudioStreamBasicDescription format;
	uint32_t config;
	if([outputController peekFormat:&format channelConfig:&config]) {
		format = AudioFormatAsFloat64(format);

		// XXX ERROR with AirPods - Can't go higher than CD*8 surround - 192k stereo
		// Emits to console: [AUScotty] Initialize: invalid FFT size 16384
		// DSD256 stereo emits: [AUScotty] Initialize: invalid FFT size 65536

		BOOL formatClipped = NO;
		BOOL isSurround = format.mChannelsPerFrame > 2;
		const double maxSampleRate = isSurround ? 352800.0 : 192000.0;
		double srcRate = format.mSampleRate;
		double dstRate = srcRate;
			if(format.mSampleRate > maxSampleRate) {
				format.mSampleRate = maxSampleRate;
				dstRate = maxSampleRate;
				formatClipped = YES;
			}
			const BOOL resamplerConfigurationChanged = formatClipped ?
			                                                  (!rsstate || srcRate != lastClippedSampleRate) :
			                                                  (rsstate != NULL);
			if(!streamFormatStarted || resamplerConfigurationChanged || config != newChannelConfig || memcmp(&newFormat, &format, sizeof(format)) != 0) {
			[currentPtsLock lock];
			// Finish the already queued transition and emit any staged frames before
			// accepting another format. Otherwise a third format can overwrite the
			// pending format while the second stream is still buffered.
			if(rsold || rsDone || inputBufferLastTime > 0 || rsEndDrainPending || rsEndDrainComplete) {
				[currentPtsLock unlock];
				return -1;
			}
			if(formatClipped) {
				ALog(@"Sample rate clipped to no more than %f Hz!", maxSampleRate);
				void *newResampler = AVFFloat64ResamplerCreate((int)format.mChannelsPerFrame, srcRate, dstRate);
				if(!newResampler) {
					[currentPtsLock unlock];
					ALog(@"Unable to create the Float64 output resampler");
					stopping = YES;
					return -1;
				}
				if(rsstate) {
					rsold = rsstate;
					rsOldIsEndDrain = NO;
				}
				rsstate = newResampler;
			} else if(rsstate) {
				rsold = rsstate;
				rsOldIsEndDrain = NO;
				rsstate = NULL;
			}
			lastClippedSampleRate = formatClipped ? srcRate : 0.0;
			[currentPtsLock unlock];
			newFormat = format;
			newChannelConfig = config;
			streamFormatStarted = YES;

			visFormat = AudioFormatAsFloat64(format);
			visFormat.mChannelsPerFrame = 1;
			visFormat.mBytesPerFrame = sizeof(double);
			visFormat.mBytesPerPacket = visFormat.mBytesPerFrame * visFormat.mFramesPerPacket;

			downmixerForVis = [[DownmixProcessor alloc] initWithInputFormat:format inputConfig:config andOutputFormat:visFormat outputConfig:AudioConfigMono];
			if(!rsold) {
				realStreamFormat = format;
				realStreamChannelConfig = config;
				streamFormatChanged = YES;
			}
		}
	}

	if(streamFormatChanged) {
		return 0;
	}

	AudioChunk *chunk = [outputController readChunkAsFloat64:amountToRead];

	int frameCount = (int)[chunk frameCount];
	format = [chunk format];
	config = [chunk channelConfig];
	double chunkDuration = 0;

	if(frameCount) {
		chunkDuration = [chunk duration];

		NSData *samples = [chunk removeSamples:frameCount];
#ifdef _DEBUG
		[BadSampleCleaner cleanSamples64:(double *)[samples bytes]
		                          amount:frameCount * format.mChannelsPerFrame
		                        location:@"pre downmix"];
#endif
		// It should be fine to request up to double, we'll only get downsampled
		const double *outputPtr = (const double *)[samples bytes];
		if(rsstate) {
			size_t inDone = 0;
			[currentPtsLock lock];
			size_t framesDone = AVFFloat64ResamplerProcess(rsstate, outputPtr, frameCount, &inDone, &rsTempBuffer[0], amountToRead);
			[currentPtsLock unlock];
			if(!framesDone) return 0;
			frameCount = (int)framesDone;
			outputPtr = &rsTempBuffer[0];
			chunkDuration = frameCount / newFormat.mSampleRate;
		}

		[downmixerForVis process:outputPtr
		              frameCount:frameCount
		                  output:&visAudio[0]];

		[visController postSampleRate:44100.0];

		if(newFormat.mSampleRate != 44100.0) {
			if(newFormat.mSampleRate != lastVisRate) {
				if(rsvis) {
					BOOL drained = NO;
					while(!drained) {
						int samplesFlushed;
						[currentPtsLock lock];
						samplesFlushed = AVFFloat64ResamplerFlush(rsvis, &visTemp[0], 8192, &drained);
						[currentPtsLock unlock];
						if(samplesFlushed > 0) {
							vDSP_vdpsp(visTemp, 1, visOutput, 1, samplesFlushed);
							[visController postVisPCM:visOutput amount:samplesFlushed];
						} else if(!drained) {
							break;
						}
					}
					[currentPtsLock lock];
					AVFFloat64ResamplerDelete(rsvis);
					rsvis = NULL;
					[currentPtsLock unlock];
				}
				lastVisRate = newFormat.mSampleRate;
				[currentPtsLock lock];
				rsvis = AVFFloat64ResamplerCreate(1, lastVisRate, 44100.0);
				[currentPtsLock unlock];
			}
			if(rsvis) {
				int samplesProcessed;
				size_t totalDone = 0;
				size_t inDone = 0;
				size_t visFrameCount = frameCount;
				{
					[currentPtsLock lock];
					samplesProcessed = AVFFloat64ResamplerProcess(rsvis, &visAudio[totalDone], visFrameCount, &inDone, &visTemp[0], 8192);
					[currentPtsLock unlock];
					if(samplesProcessed) {
						vDSP_vdpsp(visTemp, 1, visOutput, 1, samplesProcessed);
						[visController postVisPCM:visOutput amount:samplesProcessed];
					}
					totalDone += inDone;
					visFrameCount -= inDone;
				} while(samplesProcessed && visFrameCount);
			}
		} else if(rsvis) {
			BOOL drained = NO;
			while(!drained) {
				int samplesFlushed;
				[currentPtsLock lock];
				samplesFlushed = AVFFloat64ResamplerFlush(rsvis, &visTemp[0], 8192, &drained);
				[currentPtsLock unlock];
				if(samplesFlushed > 0) {
					vDSP_vdpsp(visTemp, 1, visOutput, 1, samplesFlushed);
					[visController postVisPCM:visOutput amount:samplesFlushed];
				} else if(!drained) {
					break;
				}
			}
			[currentPtsLock lock];
			AVFFloat64ResamplerDelete(rsvis);
			rsvis = NULL;
			[currentPtsLock unlock];
			vDSP_vdpsp(visAudio, 1, visOutput, 1, frameCount);
			[visController postVisPCM:visOutput amount:frameCount];
		} else {
			vDSP_vdpsp(visAudio, 1, visOutput, 1, frameCount);
			[visController postVisPCM:visOutput amount:frameCount];
		}

		cblas_dcopy((int)(frameCount * newFormat.mChannelsPerFrame), outputPtr, 1, &buffer[0], 1);
		amountRead = frameCount;
	} else {
		return 0;
	}

	if(stopping) return 0;

	double volumeScale = 1.0;
	double sustained;
	sustained = secondsHdcdSustained;
	if(sustained > 0) {
		if(sustained < amountRead) {
			secondsHdcdSustained = 0;
		} else {
			secondsHdcdSustained -= chunkDuration;
			volumeScale = 0.5;
		}
	}

	if(eqEnabled) {
		volumeScale *= eqPreamp;
	}

	scale_by_volume_double(&buffer[0], amountRead * newFormat.mChannelsPerFrame, volumeScale);

	return amountRead;
}

- (id)initWithController:(OutputNode *)c {
	self = [super init];
	if(self) {
		outputController = c;
		volume = 1.0;
		outputDeviceID = -1;

		secondsHdcdSustained = 0;

		currentPtsLock = [NSLock new];

#ifdef OUTPUT_LOG
		NSString *logName = [NSTemporaryDirectory() stringByAppendingPathComponent:@"CogAudioLog.raw"];
		_logFile = fopen([logName UTF8String], "wb");
#endif
	}

	return self;
}

static OSStatus
default_device_changed(AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses, void *inUserData) {
	OutputAVFoundation *this = (__bridge OutputAVFoundation *)inUserData;
	return [this setOutputDeviceByID:-1];
}

static OSStatus
current_device_listener(AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses, void *inUserData) {
	OutputAVFoundation *this = (__bridge OutputAVFoundation *)inUserData;
	for(UInt32 i = 0; i < inNumberAddresses; ++i) {
		switch(inAddresses[i].mSelector) {
			case kAudioDevicePropertyDeviceIsAlive:
				return [this setOutputDeviceByID:-1];

			case kAudioDevicePropertyNominalSampleRate:
			case kAudioDevicePropertyStreamFormat:
				this->outputdevicechanged = YES;
				return noErr;
		}
	}
	return noErr;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if(context != kOutputAVFoundationContext) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}

	if([keyPath isEqualToString:@"values.outputDevice"]) {
		NSDictionary *device = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] objectForKey:@"outputDevice"];

		[self setOutputDeviceWithDeviceDict:device];
	} else if([keyPath isEqualToString:@"values.GraphicEQenable"]) {
		BOOL enabled = [[[[NSUserDefaultsController sharedUserDefaultsController] defaults] objectForKey:@"GraphicEQenable"] boolValue];

		[self setEqualizerEnabled:enabled];
	} else if([keyPath isEqualToString:@"values.eqPreamp"]) {
		double preamp = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] doubleForKey:@"eqPreamp"];
		eqPreamp = pow(10.0, preamp / 20.0);
	} else if([keyPath isEqualToString:@"values.enableHrtf"]) {
		enableHrtf = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] boolForKey:@"enableHrtf"];
		if(streamFormatStarted)
			resetStreamFormat = YES;
	} else if([keyPath isEqualToString:@"values.enableFSurround"]) {
		enableFSurround = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] boolForKey:@"enableFSurround"];
		if(streamFormatStarted)
			resetStreamFormat = YES;
	}
}

- (BOOL)signalEndOfStream:(double)latency {
	stopped = YES;
	BOOL ret = [outputController selectNextBuffer];
	stopped = ret;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC * latency)), dispatch_get_main_queue(), ^{
		[self->outputController endOfInputPlayed];
		[self->outputController resetAmountPlayed];
		self->lastCheckpointPts = self->trackPts;
		self->trackPts = kCMTimeZero;
	});
	return ret;
}

- (BOOL)processEndOfStream {
	if(stopping) {
		stopping = YES;
		return YES;
	}
	if([outputController endOfStream] != YES) {
		return NO;
	}

	// Preserve a gapless resampler across a queued track with the same format.
	// At the actual end of the playlist, however, all staged samples, SOXR
	// delay, and the FreeSurround tail must be enqueued before playback stops.
	if(!rsEndDrainComplete && ![outputController chainQueueHasTracks]) {
		[currentPtsLock lock];
		const BOOL hasResamplerWork = rsstate || rsold;
		[currentPtsLock unlock];
		if(hasResamplerWork || rsDone || inputBufferLastTime > 0 || fsurround) {
			rsEndDrainPending = YES;
			return NO;
		}
	}

	if([self signalEndOfStream:secondsLatency]) {
		stopping = YES;
		return YES;
	}
	return NO;
}

- (void)threadEntry:(id)arg {
	running = YES;
	started = NO;
	shouldPlayOutBuffer = NO;
	secondsLatency = 1.0;

	while(!stopping) {
		if([outputController shouldReset]) {
			[outputController setShouldReset:NO];
			[self removeSynchronizerBlock];
			[renderSynchronizer setRate:0];
			[audioRenderer stopRequestingMediaData];
			[audioRenderer flush];

			void *activeResampler = NULL;
			void *oldResampler = NULL;
			void *visualizationResampler = NULL;
			[currentPtsLock lock];
			activeResampler = rsstate;
			oldResampler = rsold;
			visualizationResampler = rsvis;
			rsstate = NULL;
			rsold = NULL;
			rsvis = NULL;
			fsurround = nil;
			currentPts = kCMTimeZero;
			lastPts = kCMTimeZero;
			outputPts = kCMTimeZero;
			[currentPtsLock unlock];
			AVFFloat64ResamplerDelete(activeResampler);
			AVFFloat64ResamplerDelete(oldResampler);
			AVFFloat64ResamplerDelete(visualizationResampler);

			inputBufferLastTime = 0;
			rsDone = NO;
			rsEndDrainPending = NO;
			rsEndDrainComplete = NO;
			rsOldIsEndDrain = NO;
			streamFormatStarted = NO;
			streamFormatChanged = NO;
			resetStreamFormat = NO;
			lastClippedSampleRate = 0.0;
			lastVisRate = 44100.0;
			downmixerForVis = nil;
			hrtf = nil;
			FSurroundDelayRemoved = NO;
			if(_eq) {
				AudioUnitReset(_eq, kAudioUnitScope_Input, 0);
				AudioUnitReset(_eq, kAudioUnitScope_Output, 0);
				AudioUnitReset(_eq, kAudioUnitScope_Global, 0);
			}
			trackPts = kCMTimeZero;
			lastCheckpointPts = kCMTimeZero;
			secondsLatency = 1.0;
			started = NO;
			restarted = NO;
			[self synchronizerBlock];
		}

		if(stopping)
			break;

		@autoreleasepool {
			while(!stopping && [audioRenderer isReadyForMoreMediaData]) {
				CMSampleBufferRef bufferRef = [self makeSampleBuffer];

				if(bufferRef) {
					CMTime chunkDuration = CMSampleBufferGetDuration(bufferRef);

					[currentPtsLock lock];
					outputPts = CMTimeAdd(outputPts, chunkDuration);
					[currentPtsLock unlock];
					trackPts = CMTimeAdd(trackPts, chunkDuration);

					[audioRenderer enqueueSampleBuffer:bufferRef];

					CFRelease(bufferRef);
				} else {
					break;
				}
			}
		}

		if(!paused && !started) {
			[self resume];
		}

		if([outputController shouldContinue] == NO) {
			break;
		}

		usleep(5000);
	}

	stopped = YES;
	if(!stopInvoked) {
		[self doStop];
	}
}

- (OSStatus)setOutputDeviceByID:(AudioDeviceID)deviceID {
	OSStatus err;
	BOOL defaultDevice = NO;
	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioHardwarePropertyDefaultOutputDevice,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};

	if(deviceID == -1) {
		defaultDevice = YES;
		UInt32 size = sizeof(AudioDeviceID);
		err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &theAddress, 0, NULL, &size, &deviceID);

		if(err != noErr) {
			DLog(@"THERE'S NO DEFAULT OUTPUT DEVICE");

			return err;
		}
	}

	if(audioRenderer) {
		if(defaultdevicelistenerapplied && !defaultDevice) {
			/* Already set above
			 * theAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice; */
			AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &theAddress, default_device_changed, (__bridge void *_Nullable)(self));
			defaultdevicelistenerapplied = NO;
		}

		outputdevicechanged = NO;

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

			CFStringRef deviceUID = NULL;
			theAddress.mSelector = kAudioDevicePropertyDeviceUID;
			UInt32 size = sizeof(deviceUID);

			err = AudioObjectGetPropertyData(outputDeviceID, &theAddress, 0, NULL, &size, &deviceUID);
			if(err != noErr) {
				DLog(@"Unable to get UID of device");
				return err;
			}

			[audioRenderer setAudioOutputDeviceUniqueID:(__bridge NSString *)deviceUID];
			CFRelease(deviceUID);

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
	} else {
		err = noErr;
	}

	if(err != noErr) {
		DLog(@"No output device with ID %d could be found.", deviceID);

		return err;
	}

	return err;
}

- (BOOL)setOutputDeviceWithDeviceDict:(NSDictionary *)deviceDict {
	NSNumber *deviceIDNum = [deviceDict objectForKey:@"deviceID"];
	AudioDeviceID outputDeviceID = [deviceIDNum unsignedIntValue] ?: -1;

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

	__Verify_noErr(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &theAddress, 0, NULL, &propsize));
	UInt32 nDevices = propsize / (UInt32)sizeof(AudioDeviceID);
	AudioDeviceID *devids = malloc(propsize);
	__Verify_noErr(AudioObjectGetPropertyData(kAudioObjectSystemObject, &theAddress, 0, NULL, &propsize, devids));

	theAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
	AudioDeviceID systemDefault;
	propsize = sizeof(systemDefault);
	__Verify_noErr(AudioObjectGetPropertyData(kAudioObjectSystemObject, &theAddress, 0, NULL, &propsize, &systemDefault));

	theAddress.mScope = kAudioDevicePropertyScopeOutput;

	for(UInt32 i = 0; i < nDevices; ++i) {
		UInt32 isAlive = 0;
		propsize = sizeof(isAlive);
		theAddress.mSelector = kAudioDevicePropertyDeviceIsAlive;
		__Verify_noErr(AudioObjectGetPropertyData(devids[i], &theAddress, 0, NULL, &propsize, &isAlive));
		if(!isAlive) continue;

		CFStringRef name = NULL;
		propsize = sizeof(name);
		theAddress.mSelector = kAudioDevicePropertyDeviceNameCFString;
		__Verify_noErr(AudioObjectGetPropertyData(devids[i], &theAddress, 0, NULL, &propsize, &name));

		propsize = 0;
		theAddress.mSelector = kAudioDevicePropertyStreamConfiguration;
		__Verify_noErr(AudioObjectGetPropertyDataSize(devids[i], &theAddress, 0, NULL, &propsize));

		if(propsize < sizeof(UInt32)) {
			if(name) CFRelease(name);
			continue;
		}

		AudioBufferList *bufferList = (AudioBufferList *)malloc(propsize);
		__Verify_noErr(AudioObjectGetPropertyData(devids[i], &theAddress, 0, NULL, &propsize, bufferList));
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

		CFRelease(name);

		if(stop) {
			break;
		}
	}

	free(devids);
}

- (void)updateStreamFormat {
	/* Set the channel layout for the audio queue */
	resetStreamFormat = NO;

	uint32_t channels = realStreamFormat.mChannelsPerFrame;
	uint32_t channelConfig = realStreamChannelConfig;

	if(enableFSurround && channels == 2 && channelConfig == AudioConfigStereo) {
		[currentPtsLock lock];
		fsurround = [[FSurroundFilter alloc] initWithSampleRate:realStreamFormat.mSampleRate];
		[currentPtsLock unlock];
		channels = [fsurround channelCount];
		channelConfig = [fsurround channelConfig];
		FSurroundDelayRemoved = NO;
	} else {
		[currentPtsLock lock];
		fsurround = nil;
		[currentPtsLock unlock];
	}

	/* Apple's audio processor really only supports common 1-8 channel formats */
	if(enableHrtf || channels > 8 || ((channelConfig & ~(AudioConfig6Point1|AudioConfig7Point1)) != 0)) {
		NSURL *presetUrl = [[NSBundle mainBundle] URLForResource:@"SADIE_D02-96000" withExtension:@"mhr"];

		hrtf = [[HeadphoneFilter alloc] initWithImpulseFile:presetUrl forSampleRate:realStreamFormat.mSampleRate withInputChannels:channels withConfig:channelConfig];

		channels = 2;
		channelConfig = AudioChannelSideLeft | AudioChannelSideRight;
	} else {
		hrtf = nil;
	}

	streamFormat = AudioFormatAsFloat32(realStreamFormat);
	streamFormat.mChannelsPerFrame = channels;
	streamFormat.mBytesPerFrame = sizeof(float) * channels;
	streamFormat.mFramesPerPacket = 1;
	streamFormat.mBytesPerPacket = sizeof(float) * channels;
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

	if(audioFormatDescription) {
		CFRelease(audioFormatDescription);
		audioFormatDescription = NULL;
	}

	if(CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &streamFormat, sizeof(layout), &layout, 0, NULL, NULL, &audioFormatDescription) != noErr) {
		return;
	}

	if(eqInitialized) {
		AudioUnitUninitialize(_eq);
		eqInitialized = NO;
	}

	AudioStreamBasicDescription asbd = streamFormat;

	// Of course, non-interleaved has only one sample per frame/packet, per buffer
	asbd.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
	asbd.mBytesPerFrame = sizeof(float);
	asbd.mBytesPerPacket = sizeof(float);
	asbd.mFramesPerPacket = 1;

	UInt32 maximumFrames = 4096;
	AudioUnitSetProperty(_eq, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, sizeof(maximumFrames));

	AudioUnitSetProperty(_eq, kAudioUnitProperty_StreamFormat,
	                     kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));

	AudioUnitSetProperty(_eq, kAudioUnitProperty_StreamFormat,
	                     kAudioUnitScope_Output, 0, &asbd, sizeof(asbd));
	AudioUnitReset(_eq, kAudioUnitScope_Input, 0);
	AudioUnitReset(_eq, kAudioUnitScope_Output, 0);

	AudioUnitReset(_eq, kAudioUnitScope_Global, 0);

	if(AudioUnitInitialize(_eq) != noErr) {
		eqEnabled = NO;
		return;
	}
	eqInitialized = YES;

	eqEnabled = [[[[NSUserDefaultsController sharedUserDefaultsController] defaults] objectForKey:@"GraphicEQenable"] boolValue];
}

- (CMSampleBufferRef)makeSampleBuffer {
	CMBlockBufferRef blockBuffer = nil;

	int samplesRendered = [self makeBlockBuffer:&blockBuffer];
	if(!samplesRendered) {
		if(blockBuffer) CFRelease(blockBuffer);
		return nil;
	}

	CMSampleBufferRef sampleBuffer = nil;

	OSStatus err = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, blockBuffer, audioFormatDescription, samplesRendered, outputPts, nil, &sampleBuffer);
	CFRelease(blockBuffer);
	if(err != noErr) {
		return nil;
	}

	return sampleBuffer;
}

- (int)makeBlockBuffer:(CMBlockBufferRef *)blockBufferOut {
	OSStatus status;
	CMBlockBufferRef blockListBuffer = nil;

	status = CMBlockBufferCreateEmpty(kCFAllocatorDefault, 0, 0, &blockListBuffer);
	if(status != noErr || !blockListBuffer) return 0;

	if(rsEndDrainComplete) {
		// The periodic observer may not have sampled the just-enqueued tail yet.
		// Refresh the queued latency synchronously so final-stop scheduling keeps
		// the complete tail alive.
		[currentPtsLock lock];
		double queuedLatency = CMTimeGetSeconds(CMTimeSubtract(outputPts, currentPts));
		if(!isfinite(queuedLatency) || queuedLatency < 0.0) queuedLatency = 0.0;
		secondsLatency = queuedLatency;
		[currentPtsLock unlock];
		if([self processEndOfStream]) {
			rsEndDrainComplete = NO;
			CFRelease(blockListBuffer);
			return 0;
		}
		rsEndDrainComplete = NO;
	}

	// A drained transition owns the staged frames that follow it. Promote its
	// format before reading again so a third format cannot relabel those frames.
	if(rsDone && !rsold) {
		rsDone = NO;
		realStreamFormat = newFormat;
		realStreamChannelConfig = newChannelConfig;
		[self updateStreamFormat];
	}

	if(resetStreamFormat || streamFormatChanged) {
		streamFormatChanged = NO;
		[self updateStreamFormat];
	}

	// At final playlist EOS the already staged output precedes SOXR's delayed
	// tail. Move the active resampler only after those staged frames were sent.
	if(rsEndDrainPending && inputBufferLastTime == 0 && !rsold && rsstate) {
		[currentPtsLock lock];
		if(rsEndDrainPending && !rsold && rsstate) {
			rsold = rsstate;
			rsstate = NULL;
			rsOldIsEndDrain = YES;
		}
		[currentPtsLock unlock];
	}

	int inputRendered = inputBufferLastTime;
	int bytesRendered = inputRendered * newFormat.mBytesPerPacket;

	while(inputRendered < 4096 && !rsEndDrainPending) {
		int maxToRender = MIN(4096 - inputRendered, 512);
		int rendered = [self renderInput:maxToRender toBuffer:&tempBuffer[0]];
		if(rendered > 0) {
			memcpy((((uint8_t *)inputBuffer) + bytesRendered), &tempBuffer[0], rendered * newFormat.mBytesPerPacket);
			inputRendered += rendered;
			bytesRendered += rendered * newFormat.mBytesPerPacket;
			inputBufferLastTime = inputRendered;
		}
		if(streamFormatChanged) {
			streamFormatChanged = NO;
			if(inputRendered) {
				resetStreamFormat = YES;
				break;
			} else {
				[self updateStreamFormat];
			}
		}
		if(rendered < 0) {
			break;
		}
		if(rendered == 0) {
			[self processEndOfStream];
			break;
		}
		if([self processEndOfStream] || rsEndDrainPending) break;
	}

	inputBufferLastTime = inputRendered;

	int samplesRenderedTotal = 0;

	for(size_t i = 0; i < 2;) {
		int samplesRendered;
		BOOL finishingOldStream = NO;

		if(i == 0) {
			if(!rsold) {
				++i;
				continue;
			}
			void *finishedResampler = NULL;
			BOOL drained = NO;
			BOOL finishedEndDrain = NO;
			[currentPtsLock lock];
			samplesRendered = AVFFloat64ResamplerFlush(rsold, &rsTempBuffer[0], 4096, &drained);
			if(drained) {
				finishedResampler = rsold;
				rsold = NULL;
				finishedEndDrain = rsOldIsEndDrain;
				rsOldIsEndDrain = NO;
				if(finishedEndDrain) {
					rsEndDrainPending = NO;
					rsEndDrainComplete = YES;
				} else {
					rsDone = YES;
				}
				finishingOldStream = YES;
			}
			[currentPtsLock unlock];
			if(finishedResampler) {
				AVFFloat64ResamplerDelete(finishedResampler);
			}
			samplePtr = &rsTempBuffer[0];
			if(!samplesRendered && !(finishingOldStream && fsurround)) {
				++i;
				continue;
			}
		} else {
			samplesRendered = inputRendered;
			samplePtr = &inputBuffer[0];
			if(rsDone) {
				rsDone = NO;
				realStreamFormat = newFormat;
				realStreamChannelConfig = newChannelConfig;
				[self updateStreamFormat];
			}
		}

		const BOOL finishingCurrentStream = (rsEndDrainPending && !rsstate) ||
		                                    (!rsEndDrainPending && samplesRendered > 0 && samplesRendered < 4096);
		const BOOL drainSurround = resetStreamFormat ||
		                           (i == 0 ? finishingOldStream : finishingCurrentStream);
		if(samplesRendered || (fsurround && drainSurround)) {
			if(fsurround) {
				int countToProcess = samplesRendered;
				if(countToProcess < 4096) {
					bzero(samplePtr + countToProcess * 2, (4096 - countToProcess) * 2 * sizeof(double));
					countToProcess = 4096;
				}
				[fsurround process:samplePtr output:&fsurroundBuffer[0] count:countToProcess];
				samplePtr = &fsurroundBuffer[0];
				if(drainSurround) {
					bzero(&fsurroundBuffer[4096 * 6], 4096 * 2 * sizeof(double));
					[fsurround process:&fsurroundBuffer[4096 * 6] output:&fsurroundBuffer[4096 * 6] count:4096];
					samplesRendered += 2048;
				}
				if(!FSurroundDelayRemoved) {
					FSurroundDelayRemoved = YES;
					if(samplesRendered > 2048) {
						samplePtr += 2048 * 6;
						samplesRendered -= 2048;
					}
				}
			}

			if(!samplesRendered) {
				break;
			}

			if(hrtf) {
				[hrtf process:samplePtr sampleCount:samplesRendered toBuffer:&hrtfBuffer[0]];
				samplePtr = &hrtfBuffer[0];
			}

			if(eqEnabled && eqInitialized) {
				const int channels = streamFormat.mChannelsPerFrame;
				if(channels > 0) {
					double *const eqSamples = samplePtr;
					int framesProcessed = 0;
					while(framesProcessed < samplesRendered) {
						const int framesToProcess = MIN(4096, samplesRendered - framesProcessed);
						const size_t channelsminusone = channels - 1;
						uint8_t audioBufferListStorage[sizeof(AudioBufferList) + sizeof(AudioBuffer) * channelsminusone];
						AudioBufferList *ioData = (AudioBufferList *)&audioBufferListStorage[0];

						samplePtr = eqSamples + (size_t)framesProcessed * channels;
						ioData->mNumberBuffers = channels;
						for(size_t channel = 0; channel < channels; ++channel) {
							ioData->mBuffers[channel].mData = &eqBuffer[4096 * channel];
							ioData->mBuffers[channel].mDataByteSize = framesToProcess * sizeof(float);
							ioData->mBuffers[channel].mNumberChannels = 1;
						}

						status = AudioUnitRender(_eq, NULL, &timeStamp, 0, framesToProcess, ioData);
						if(status != noErr) {
							samplePtr = eqSamples;
							CFRelease(blockListBuffer);
							return 0;
						}

						timeStamp.mSampleTime += framesToProcess;
						for(int channel = 0; channel < channels; ++channel) {
							vDSP_vspdp(&eqBuffer[4096 * channel], 1, samplePtr + channel, channels, framesToProcess);
						}
						framesProcessed += framesToProcess;
					}
					samplePtr = eqSamples;
				}
			}

			CMBlockBufferRef blockBuffer = nil;
			const size_t outputSampleCount = (size_t)samplesRendered * streamFormat.mChannelsPerFrame;
			const size_t dataByteSize = outputSampleCount * sizeof(float);
			vDSP_vdpsp(samplePtr, 1, deviceBuffer, 1, outputSampleCount);

#ifdef OUTPUT_LOG
			fwrite(deviceBuffer, 1, dataByteSize, _logFile);
#endif

			status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nil, dataByteSize, kCFAllocatorDefault, nil, 0, dataByteSize, kCMBlockBufferAssureMemoryNowFlag, &blockBuffer);

			if(status != noErr || !blockBuffer) {
				CFRelease(blockListBuffer);
				return 0;
			}

			status = CMBlockBufferReplaceDataBytes(deviceBuffer, blockBuffer, 0, dataByteSize);

			if(status != noErr) {
				CFRelease(blockBuffer);
				CFRelease(blockListBuffer);
				return 0;
			}

			status = CMBlockBufferAppendBufferReference(blockListBuffer, blockBuffer, 0, CMBlockBufferGetDataLength(blockBuffer), 0);

			if(status != noErr) {
				CFRelease(blockBuffer);
				CFRelease(blockListBuffer);
				return 0;
			}

			CFRelease(blockBuffer);
		}

		if(i == 0) {
			samplesRenderedTotal += samplesRendered;
			if(samplesRendered) {
				break;
			}
			++i;
		} else {
			inputBufferLastTime = 0;
			samplesRenderedTotal += samplesRendered;
			++i;
		}
	}

	if(rsEndDrainPending && inputBufferLastTime == 0 && !rsDone) {
		[currentPtsLock lock];
		const BOOL resamplerDrainFinished = !rsstate && !rsold;
		[currentPtsLock unlock];
		if(resamplerDrainFinished) {
			rsEndDrainPending = NO;
			rsEndDrainComplete = YES;
		}
	}

	*blockBufferOut = blockListBuffer;

	return samplesRenderedTotal;
}

- (BOOL)setup {
	if(audioRenderer || renderSynchronizer)
		[self stop];

	@synchronized(self) {
		stopInvoked = NO;
		stopCompleted = NO;
		commandStop = NO;
		shouldPlayOutBuffer = NO;

		audioFormatDescription = NULL;

		resetStreamFormat = NO;
		streamFormatChanged = NO;
		streamFormatStarted = NO;

		inputBufferLastTime = 0;

		running = NO;
		stopping = NO;
		stopped = NO;
		paused = NO;
		outputDeviceID = -1;
		restarted = NO;

		downmixerForVis = nil;

		rsDone = NO;
		rsEndDrainPending = NO;
		rsEndDrainComplete = NO;
		rsOldIsEndDrain = NO;
		rsstate = NULL;
		rsold = NULL;
		
		lastClippedSampleRate = 0.0;

		rsvis = NULL;
		lastVisRate = 44100.0;

		AudioComponentDescription desc;
		NSError *err;

		desc.componentType = kAudioUnitType_Output;
		desc.componentSubType = kAudioUnitSubType_HALOutput;
		desc.componentManufacturer = kAudioUnitManufacturer_Apple;
		desc.componentFlags = 0;
		desc.componentFlagsMask = 0;

		audioRenderer = [AVSampleBufferAudioRenderer new];
		renderSynchronizer = [AVSampleBufferRenderSynchronizer new];

		if(audioRenderer == nil || renderSynchronizer == nil)
			return NO;

		if(@available(macOS 12.0, *)) {
			[audioRenderer setAllowedAudioSpatializationFormats:AVAudioSpatializationFormatMonoStereoAndMultichannel];
		}

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

		AudioComponent comp = NULL;

		desc.componentType = kAudioUnitType_Effect;
		desc.componentSubType = kAudioUnitSubType_GraphicEQ;

		comp = AudioComponentFindNext(comp, &desc);
		if(!comp)
			return NO;

		OSStatus _err = AudioComponentInstanceNew(comp, &_eq);
		if(err)
			return NO;

		UInt32 value;
		UInt32 size = sizeof(value);

		value = CHUNK_SIZE;
		AudioUnitSetProperty(_eq, kAudioUnitProperty_MaximumFramesPerSlice,
		                     kAudioUnitScope_Global, 0, &value, size);

		value = 127;
		AudioUnitSetProperty(_eq, kAudioUnitProperty_RenderQuality,
		                     kAudioUnitScope_Global, 0, &value, size);

		AURenderCallbackStruct callbackStruct;
		callbackStruct.inputProcRefCon = (__bridge void *)self;
		callbackStruct.inputProc = eqRenderCallback;
		AudioUnitSetProperty(_eq, kAudioUnitProperty_SetRenderCallback,
		                     kAudioUnitScope_Input, 0, &callbackStruct, sizeof(callbackStruct));

		AudioUnitReset(_eq, kAudioUnitScope_Input, 0);
		AudioUnitReset(_eq, kAudioUnitScope_Output, 0);

		AudioUnitReset(_eq, kAudioUnitScope_Global, 0);

		_err = AudioUnitInitialize(_eq);
		if(_err)
			return NO;

		eqInitialized = YES;

		[self setEqualizerEnabled:[[[[NSUserDefaultsController sharedUserDefaultsController] defaults] objectForKey:@"GraphicEQenable"] boolValue]];

		[outputController beginEqualizer:_eq];

		visController = [VisualizationController sharedController];

		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.outputDevice" options:0 context:kOutputAVFoundationContext];
		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.GraphicEQenable" options:0 context:kOutputAVFoundationContext];
		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.eqPreamp" options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew) context:kOutputAVFoundationContext];
		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.enableHrtf" options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew) context:kOutputAVFoundationContext];
		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.enableFSurround" options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew) context:kOutputAVFoundationContext];
		observersapplied = YES;

		[renderSynchronizer addRenderer:audioRenderer];

		currentPts = kCMTimeZero;
		lastPts = kCMTimeZero;
		outputPts = kCMTimeZero;
		trackPts = kCMTimeZero;
		lastCheckpointPts = kCMTimeZero;
		bzero(&timeStamp, sizeof(timeStamp));
		timeStamp.mFlags = kAudioTimeStampSampleTimeValid;

		[self synchronizerBlock];

		[audioRenderer setVolume:volume];

		return (err == nil);
	}
}

- (void)synchronizerBlock {
	NSLock *lock = currentPtsLock;
	CMTime interval = CMTimeMakeWithSeconds(1.0 / 60.0, 1000000000);
	CMTime *lastPts = &self->lastPts;
	CMTime *outputPts = &self->outputPts;
	OutputNode *outputController = self->outputController;
	double *latencySecondsOut = &self->secondsLatency;
	VisualizationController *visController = self->visController;
	void **rsstate = &self->rsstate;
	void **rsold = &self->rsold;
	void **rsvis = &self->rsvis;
	FSurroundFilter *const *fsurroundtest = &self->fsurround;
	currentPtsObserver = [renderSynchronizer addPeriodicTimeObserverForInterval:interval
	                                                                      queue:NULL
	                                                                 usingBlock:^(CMTime time) {
		                                                                 [lock lock];
		                                                                 self->currentPts = time;
		                                                                 [lock unlock];
		                                                                 CMTime timeToAdd = CMTimeSubtract(time, *lastPts);
		                                                                 self->lastPts = time;
		                                                                 double timeAdded = CMTimeGetSeconds(timeToAdd);
		                                                                 if(timeAdded > 0) {
			                                                                 [outputController incrementAmountPlayed:timeAdded];
		                                                                 }
		                                                                 [lock lock];
		                                                                 CMTime latencyTime = CMTimeSubtract(*outputPts, time);
		                                                                 [lock unlock];
		                                                                 double latencySeconds = CMTimeGetSeconds(latencyTime);
		                                                                 double latencyVis = 0.0;
		                                                                 [lock lock];
			                                                                 if(*rsstate) {
				                                                                 latencySeconds += AVFFloat64ResamplerLatency(*rsstate);
			                                                                 }
			                                                                 if(*rsold) {
				                                                                 latencySeconds += AVFFloat64ResamplerLatency(*rsold);
			                                                                 }
			                                                                 if(*rsvis) {
				                                                                 latencyVis = AVFFloat64ResamplerLatency(*rsvis);
		                                                                 }
		                                                                 if(*fsurroundtest) {
			                                                                 latencyVis += 2048.0 / [(*fsurroundtest) srate];
		                                                                 }
		                                                                 [lock unlock];
		                                                                 if(latencySeconds < 0)
			                                                                 latencySeconds = 0;
		                                                                 latencyVis = latencySeconds - latencyVis;
		                                                                 if(latencyVis < 0 || latencyVis > 30.0) {
			                                                                 if(latencyVis > 30.0 && !self->restarted) {
																				 self->restarted = YES;
				                                                                 [outputController setShouldReset:YES];
			                                                                 }
			                                                                 latencyVis = 0.0;
		                                                                 }
		                                                                 *latencySecondsOut = latencySeconds;
		                                                                 [visController postLatency:latencyVis];
	                                                                 }];
}

- (void)removeSynchronizerBlock {
	if(renderSynchronizer && currentPtsObserver) {
		[renderSynchronizer removeTimeObserver:currentPtsObserver];
		currentPtsObserver = nil;
	}
}

- (void)setVolume:(double)v {
	volume = v * 0.01;
	if(audioRenderer) {
		[audioRenderer setVolume:volume];
	}
}

- (void)setEqualizerEnabled:(BOOL)enabled {
	if(enabled && !eqEnabled) {
		if(_eq) {
			AudioUnitReset(_eq, kAudioUnitScope_Input, 0);
			AudioUnitReset(_eq, kAudioUnitScope_Output, 0);
			AudioUnitReset(_eq, kAudioUnitScope_Global, 0);
		}
	}

	eqEnabled = enabled;
}

- (double)latency {
	if(secondsLatency > 0) return secondsLatency;
	else return 0;
}

- (void)start {
	[self threadEntry:nil];
}

- (void)stop {
	commandStop = YES;
	[self doStop];
}

- (void)doStop {
	if(stopInvoked) {
		return;
	}
	@synchronized(self) {
		stopInvoked = YES;
		if(observersapplied) {
			[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.outputDevice" context:kOutputAVFoundationContext];
			[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.GraphicEQenable" context:kOutputAVFoundationContext];
			[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.eqPreamp" context:kOutputAVFoundationContext];
			[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.enableHrtf" context:kOutputAVFoundationContext];
			[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.enableFSurround" context:kOutputAVFoundationContext];
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
		if(renderSynchronizer || audioRenderer) {
			if(renderSynchronizer) {
				if(shouldPlayOutBuffer && !commandStop) {
					int compareVal = 0;
					double secondsLatency = self->secondsLatency >= 0 ? self->secondsLatency : 0;
					int compareMax = (((1000000 / 5000) * secondsLatency) + (10000 / 5000)); // latency plus 10ms, divide by sleep intervals
					do {
						[currentPtsLock lock];
						compareVal = CMTimeCompare(outputPts, currentPts);
						[currentPtsLock unlock];
						usleep(5000);
					} while(!commandStop && compareVal > 0 && compareMax-- > 0);
				}
				[self removeSynchronizerBlock];
				[renderSynchronizer setRate:0];
				if(audioRenderer) {
					[renderSynchronizer removeRenderer:audioRenderer atTime:kCMTimeZero completionHandler:^(BOOL didRemoveRenderer) {
						if(!didRemoveRenderer) {
							DLog(@"Error removing renderer!");
						}
					}];
				}
			}
			if(audioRenderer) {
				[audioRenderer stopRequestingMediaData];
				[audioRenderer flush];
			}
			renderSynchronizer = nil;
			audioRenderer = nil;
		}
		if(running) {
			while(!stopped) {
				stopping = YES;
				usleep(5000);
			}
		}
		if(audioFormatDescription) {
			CFRelease(audioFormatDescription);
			audioFormatDescription = NULL;
		}
		if(_eq) {
			[outputController endEqualizer:_eq];
			if(eqInitialized) {
				AudioUnitUninitialize(_eq);
				eqInitialized = NO;
			}
			AudioComponentInstanceDispose(_eq);
			_eq = NULL;
		}
		if(downmixerForVis) {
			downmixerForVis = nil;
		}
#ifdef OUTPUT_LOG
		if(_logFile) {
			fclose(_logFile);
			_logFile = NULL;
		}
#endif
		void *activeResampler = NULL;
		void *oldResampler = NULL;
		void *visualizationResampler = NULL;
		[currentPtsLock lock];
		activeResampler = rsstate;
		oldResampler = rsold;
		visualizationResampler = rsvis;
		rsstate = NULL;
		rsold = NULL;
		rsvis = NULL;
		[currentPtsLock unlock];
		AVFFloat64ResamplerDelete(activeResampler);
		AVFFloat64ResamplerDelete(oldResampler);
		AVFFloat64ResamplerDelete(visualizationResampler);
		rsDone = NO;
		rsEndDrainPending = NO;
		rsEndDrainComplete = NO;
		rsOldIsEndDrain = NO;
		inputBufferLastTime = 0;
		outputController = nil;
		visController = nil;
		stopCompleted = YES;
	}
}

- (void)dealloc {
	[self stop];
}

- (void)pause {
	paused = YES;
	if(started)
		[renderSynchronizer setRate:0];
}

- (void)resume {
	[renderSynchronizer setRate:1.0 time:currentPts];
	paused = NO;
	started = YES;
}

- (void)sustainHDCD {
	secondsHdcdSustained = 10.0;
}

- (void)setShouldPlayOutBuffer:(BOOL)s {
	shouldPlayOutBuffer = s;
}

@end
