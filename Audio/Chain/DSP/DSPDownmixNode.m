//
//  DSPDownmixNode.m
//  CogAudio Framework
//
//  Created by Christopher Snowhill on 2/13/25.
//

#import <Foundation/Foundation.h>
#import <math.h>

#import "Downmix.h"

#import "Logging.h"
#import "FadedBuffer.h"

#import "DSPDownmixNode.h"

@implementation DSPDownmixNode {
	DownmixProcessor *downmix;

	BOOL stopping, paused;
	BOOL formatSet;
	NSRecursiveLock *mutex;

	AudioStreamBasicDescription lastInputFormat;
	AudioStreamBasicDescription inputFormat;
	AudioStreamBasicDescription outputFormat;

	uint32_t lastInputChannelConfig, inputChannelConfig;
	uint32_t outputChannelConfig;

	double outBuffer[4096 * 32];
}

- (id _Nullable)initWithController:(id _Nonnull)c previous:(id _Nullable)p latency:(double)latency {
	self = [super initWithController:c previous:p latency:latency];
	if(self) {
		mutex = [NSRecursiveLock new];
	}
	return self;
}

- (void)dealloc {
	DLog(@"Downmix dealloc");
	[self setShouldContinue:NO];
	[self cleanUp];
	[super cleanUp];
}

- (BOOL)fullInit {
	[mutex lock];
	if(formatSet) {
		AudioStreamBasicDescription processingInputFormat = AudioFormatAsFloat64(inputFormat);
		AudioStreamBasicDescription processingOutputFormat = AudioFormatAsFloat64(outputFormat);
		downmix = [[DownmixProcessor alloc] initWithInputFormat:processingInputFormat inputConfig:inputChannelConfig andOutputFormat:processingOutputFormat outputConfig:outputChannelConfig];
		if(!downmix) {
			[mutex unlock];
			return NO;
		}
	}
	[mutex unlock];
	return YES;
}

- (void)fullShutdown {
	[mutex lock];
	downmix = nil;
	[mutex unlock];
}

- (BOOL)setup {
	if(stopping)
		return NO;
	[self fullShutdown];
	return [self fullInit];
}

- (void)cleanUp {
	stopping = YES;
	[self fullShutdown];
	formatSet = NO;
}

- (void)resetBuffer {
	paused = YES;
	[mutex lock];
	[buffer reset];
	paused = NO;
	[mutex unlock];
}

- (void)setOutputFormat:(AudioStreamBasicDescription)format withChannelConfig:(uint32_t)config {
	if(memcmp(&outputFormat, &format, sizeof(outputFormat)) != 0 ||
	   outputChannelConfig != config) {
		paused = YES;
		[mutex lock];
		[buffer reset];
		[self fullShutdown];
        outputFormat = format;
        outputChannelConfig = config;
        formatSet = YES;
        paused = NO;
		[mutex unlock];
	}
}

- (BOOL)paused {
	return paused;
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
				if([previousNode endOfStream] == YES) {
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

	if(stopping || ([[previousNode buffer] isEmpty] && [previousNode endOfStream] == YES) || [self shouldContinue] == NO) {
		[mutex unlock];
		return nil;
	}

	if(![self peekFormat:&inputFormat channelConfig:&inputChannelConfig]) {
		[mutex unlock];
		return nil;
	}

	if(!inputFormat.mSampleRate ||
	   !inputFormat.mBitsPerChannel ||
	   !inputFormat.mChannelsPerFrame ||
	   !inputFormat.mBytesPerFrame ||
	   !inputFormat.mFramesPerPacket ||
	   !inputFormat.mBytesPerPacket) {
		[mutex unlock];
		return nil;
	}

	const BOOL channelMappingMatches = inputChannelConfig == outputChannelConfig ||
	                                   (inputFormat.mChannelsPerFrame == 2 &&
	                                    inputChannelConfig == (AudioChannelSideLeft | AudioChannelSideRight) &&
	                                    outputChannelConfig == AudioConfigStereo);
	const BOOL channelProcessingRequired = formatSet &&
	                                       (inputFormat.mChannelsPerFrame != outputFormat.mChannelsPerFrame ||
	                                        !channelMappingMatches);
	if(!channelProcessingRequired) {
		lastInputFormat = inputFormat;
		lastInputChannelConfig = inputChannelConfig;
		[self fullShutdown];
		[mutex unlock];
		return [self readChunk:4096];
	}

	if(!downmix ||
	   memcmp(&inputFormat, &lastInputFormat, sizeof(inputFormat)) != 0 ||
	   inputChannelConfig != lastInputChannelConfig) {
		lastInputFormat = inputFormat;
		lastInputChannelConfig = inputChannelConfig;
		[self fullShutdown];
		if(formatSet && ![self setup]) {
			[mutex unlock];
			return nil;
		}
	}

	if(!downmix) {
		[mutex unlock];
		return [self readChunk:4096];
	}

	AudioChunk *chunk = [self readChunkAsFloat64:4096];
	if(!chunk || ![chunk frameCount]) {
		[mutex unlock];
		return nil;
	}

	double streamTimestamp = [chunk streamTimestamp];

	size_t frameCount = [chunk frameCount];
	NSData *sampleData = [chunk removeSamples:frameCount];
	const double *inSamples = (const double *)[sampleData bytes];
	const AudioStreamBasicDescription processingInputFormat = AudioFormatAsFloat64(inputFormat);
	const AudioStreamBasicDescription processingOutputFormat = AudioFormatAsFloat64(outputFormat);
	uint8_t nextDoPMarker = 0x05;
	if(fabs(inputFormat.mSampleRate - outputFormat.mSampleRate) < 1.0 &&
	   audioBufferIsDoP64(inSamples, inputFormat.mChannelsPerFrame, frameCount, &nextDoPMarker)) {
		AudioChunk *outputChunk = [AudioChunk new];
		[outputChunk setFormat:processingOutputFormat];
		if(outputChannelConfig) {
			[outputChunk setChannelConfig:outputChannelConfig];
		}
		if([chunk isHDCD]) [outputChunk setHDCD];
		if(chunk.resetForward) outputChunk.resetForward = YES;
		[outputChunk setStreamTimestamp:streamTimestamp];
		[outputChunk setStreamTimeRatio:[chunk streamTimeRatio]];
		if(processingInputFormat.mChannelsPerFrame == processingOutputFormat.mChannelsPerFrame &&
		   processingInputFormat.mBytesPerPacket == processingOutputFormat.mBytesPerPacket) {
			[outputChunk assignData:sampleData];
		} else {
			const size_t inputChannels = inputFormat.mChannelsPerFrame;
			const size_t outputChannels = outputFormat.mChannelsPerFrame;
			const size_t channelsToCopy = MIN(inputChannels, outputChannels);
			const uint8_t firstMarker = (frameCount % 2) ? ((nextDoPMarker == 0x05) ? 0xFA : 0x05) : nextDoPMarker;
			uint8_t marker = firstMarker;
			fillDoPSilence64(&outBuffer[0], outputChannels, frameCount, &marker);
			for(size_t frame = 0; frame < frameCount; ++frame) {
				memcpy(&outBuffer[frame * outputChannels], &inSamples[frame * inputChannels], channelsToCopy * sizeof(double));
			}
			[outputChunk assignSamples:&outBuffer[0] frameCount:frameCount];
		}
		[mutex unlock];
		return outputChunk;
	}

	[downmix process:inSamples frameCount:frameCount output:&outBuffer[0]];

	AudioChunk *outputChunk = [AudioChunk new];
	[outputChunk setFormat:processingOutputFormat];
	if(outputChannelConfig) {
		[outputChunk setChannelConfig:outputChannelConfig];
	}
	if([chunk isHDCD]) [outputChunk setHDCD];
	if(chunk.resetForward) outputChunk.resetForward = YES;
	[outputChunk setStreamTimestamp:streamTimestamp];
	[outputChunk setStreamTimeRatio:[chunk streamTimeRatio]];
	[outputChunk assignSamples:&outBuffer[0] frameCount:frameCount];

	[mutex unlock];
	return outputChunk;
}

@end
