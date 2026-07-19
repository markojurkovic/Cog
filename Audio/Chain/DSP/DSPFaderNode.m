//
//  DSPFaderNode.m
//  CogAudio Framework
//
//  Created by Christopher Snowhill on 8/15/25.
//

#import <Foundation/Foundation.h>

#import <CogAudio/OutputCoreAudio.h>

#import "Logging.h"

#import "DSPFaderNode.h"

@implementation DSPFaderNode {
	NSLock *fadersLock;
	NSMutableArray<FadedBuffer *> *faders;

	BOOL stopping, paused;
	BOOL formatSet;
	BOOL waitForResetEvent;
	NSRecursiveLock *mutex;

	double timestamp;

	AudioStreamBasicDescription outputFormat;
	uint32_t outputChannelConfig;

	double fadeLevel, fadeStep;
	atomic_bool doPMode;

	double inBuffer[512 * 32];
	double outBuffer[512 * 32];
}

@synthesize timestamp;

- (id _Nullable)initWithController:(id _Nonnull)c previous:(id _Nullable)p latency:(double)latency {
	self = [super initWithController:c previous:p latency:latency];
	if(self) {
		mutex = [NSRecursiveLock new];
		fadersLock = [NSLock new];
		faders = [NSMutableArray new];
		fadeLevel = 1.0;
		atomic_init(&doPMode, false);
	}
	return self;
}

- (void)dealloc {
	DLog(@"Downmix dealloc");
	[self setShouldContinue:NO];
	[self cleanUp];
	[super cleanUp];
}

- (void)cleanUp {
	stopping = YES;
	[fadersLock lock];
	[faders removeAllObjects];
	[fadersLock unlock];
	formatSet = NO;
}

- (BOOL)setup {
	return YES;
}

- (void)resetBuffer {
	paused = YES;
	[mutex lock];
	[buffer reset];
	[fadersLock lock];
	[faders removeAllObjects];
	[fadersLock unlock];
	paused = NO;
	waitForResetEvent = NO;
	[mutex unlock];
}

- (void)setOutputFormat:(AudioStreamBasicDescription)format withChannelConfig:(uint32_t)config {
	if(memcmp(&outputFormat, &format, sizeof(outputFormat)) != 0 ||
	   outputChannelConfig != config) {
		if(fadeStep) {
			if(formatSet) {
				fadeStep *= outputFormat.mSampleRate;
			}
			fadeStep /= format.mSampleRate;
		}
        outputFormat = format;
        outputChannelConfig = config;
        formatSet = YES;
	}
}

- (BOOL)paused {
	return paused;
}

- (void)setPreviousNode:(id)p {
	if(previousNode != p) {
		paused = YES;
		[mutex lock];
		previousNode = p;
		paused = NO;
		[mutex unlock];
	}
}

- (void)process {
	while([self shouldContinue] == YES) {
		if(paused || endOfStream) {
			usleep(500);
			continue;
		}
		@autoreleasepool {
			AudioChunk *chunk = nil;
			chunk = [self convert];
			if(!chunk || ![chunk frameCount]) {
				if(previousNode && [previousNode endOfStream] == YES) {
					usleep(500);
					endOfStream = YES;
					continue;
				}
				if(paused) {
					continue;
				}
				usleep(500);
			} else {
				[self writeChunk:chunk];
				chunk = nil;
			}
		}
	}
}

- (AudioChunk *)convert {
	if(stopping)
		return nil;

	[mutex lock];

	if(stopping || !previousNode || ([[previousNode buffer] isEmpty] && [previousNode endOfStream] == YES) || [self shouldContinue] == NO) {
		[mutex unlock];
		return nil;
	}

	AudioStreamBasicDescription format;
	uint32_t channelConfig;
	if([self peekFormat:&format channelConfig:&channelConfig]) {
		if(!formatSet ||
		   memcmp(&format, &outputFormat, sizeof(format)) != 0 ||
		   channelConfig != outputChannelConfig) {
			[self setOutputFormat:format withChannelConfig:channelConfig];
		}
	}
		
	[fadersLock lock];
	size_t count = [faders count];
	[fadersLock unlock];
	const BOOL processingRequired = fadeStep || count;

	BOOL inputRead = YES;
	AudioChunk *chunk = processingRequired ? [self readChunkAsFloat64:512] : [self readChunk:512];
	size_t frameCount = chunk ? [chunk frameCount] : 0;
	if(frameCount && processingRequired) {
		AudioStreamBasicDescription processingFormat = [chunk format];
		[self setOutputFormat:processingFormat withChannelConfig:[chunk channelConfig]];
	}
	if(waitForResetEvent && frameCount && !chunk.resetForward) {
		frameCount = 0;
	}
	if(!frameCount && count && formatSet) {
		AudioStreamBasicDescription processingFormat = AudioFormatAsFloat64(outputFormat);
		[self setOutputFormat:processingFormat withChannelConfig:outputChannelConfig];
		chunk = [AudioChunk new];
		[chunk setFormat:processingFormat];
		[chunk setChannelConfig:outputChannelConfig];
		bzero(inBuffer, 512 * processingFormat.mBytesPerPacket);
		frameCount = 512;
		inputRead = NO;
	}

	if(!frameCount) {
		[mutex unlock];
		return nil;
	}

	if(chunk.resetForward) {
		waitForResetEvent = NO;
		chunk.resetForward = NO;
	}

	if(inputRead) {
		timestamp = chunk.streamTimestamp;
	}

	BOOL fadingOut = NO;
	if(frameCount && (fadeStep || count)) {
		BOOL inputIsDoP = NO;
		if(inputRead) {
			NSData *sampleData = [chunk removeSamples:frameCount];
			memcpy(inBuffer, [sampleData bytes], frameCount * outputFormat.mBytesPerPacket);
			inputIsDoP = audioBufferIsDoP64(inBuffer, outputFormat.mChannelsPerFrame, frameCount, NULL);
			if(!inputIsDoP) {
				// DoP mode follows the current carrier instead of remaining latched
				// after playback has moved back to PCM.
				atomic_store_explicit(&doPMode, false, memory_order_relaxed);
			}
		} else {
			// [chunk removeSamples:frameCount];
			// Only happens above, and since the samples aren't assigned, they don't need to be removed
		}
		double *nextBuffer = inBuffer;
		if(atomic_load_explicit(&doPMode, memory_order_relaxed) || inputIsDoP) {
			// Never apply a gain ramp or an old-track mix to a DoP carrier.
			atomic_store_explicit(&doPMode, true, memory_order_relaxed);
			fadeStep = 0;
			fadeLevel = 1.0;
			[fadersLock lock];
			[faders removeAllObjects];
			[fadersLock unlock];
		} else if(inputRead && fadeStep) {
			bzero(outBuffer, frameCount * outputFormat.mBytesPerPacket);
			BOOL stopping = fadeAudio64(inBuffer, outBuffer, outputFormat.mChannelsPerFrame, frameCount, &fadeLevel, fadeStep, 1.0);
			if(stopping) {
				fadeStep = 0;
				fadeLevel = 1.0;
			}
			nextBuffer = outBuffer;
		}
		[fadersLock lock];
		NSArray<FadedBuffer *> *fadersCopy = [faders copy];
		[fadersLock unlock];
		for(FadedBuffer *buffer in fadersCopy) {
			BOOL stopping = [buffer mix:nextBuffer sampleCount:frameCount channelCount:outputFormat.mChannelsPerFrame];
			fadingOut = YES;
			if(stopping) {
				[fadersLock lock];
				[faders removeObject:buffer];
				[fadersLock unlock];
			}
		}
		[chunk assignSamples:nextBuffer frameCount:frameCount];
	}

	if(!inputRead) {
		chunk.streamTimestamp = timestamp;
		chunk.streamTimeRatio = 1.0;
	}
	timestamp += chunk.duration;

	[mutex unlock];
	return (fadingOut || inputRead) ? chunk : nil;
}

- (void)fadeIn {
	fadeLevel = 0.0;
	if(formatSet) {
		fadeStep = (1.0 / outputFormat.mSampleRate) * (1000.0 / fadeTimeMS);
	} else {
		fadeStep = 1000.0 / fadeTimeMS;
	}
	waitForResetEvent = YES;
}

- (void)waitForReset {
	waitForResetEvent = YES;
}

- (void)setDoPMode:(BOOL)enabled {
	// Output preparation can run before the fader has input. The worker holds
	// mutex while waiting for that input, so taking it here deadlocks startup:
	// playback cannot supply input until preparation returns. This flag is
	// independent of the fader's buffered state and only needs atomic access.
	atomic_store_explicit(&doPMode, enabled, memory_order_relaxed);
}

- (double)fadeLevel {
	return fadeLevel;
}

- (void)appendFadeOut:(FadedBuffer *)buffer {
	[fadersLock lock];
	[faders addObject:buffer];
	[fadersLock unlock];
}

- (BOOL)fading {
	[fadersLock lock];
	BOOL fading = [faders count] > 0;
	[fadersLock unlock];
	return fading;
}

@end
