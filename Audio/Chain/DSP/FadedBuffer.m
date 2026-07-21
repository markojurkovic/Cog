//
//  FadedBuffer.m
//  CogAudio
//
//  Created by Christopher Snowhill on 8/17/25.
//

#import "FadedBuffer.h"

#import <Accelerate/Accelerate.h>

#import "OutputCoreAudio.h"

double fadeTimeMS = 200.0;

static BOOL doPMarkerForSample(const void *samples,
	                           AudioStreamBasicDescription format,
	                           size_t sampleIndex,
	                           uint8_t *marker) {
	if(!samples || !marker) return NO;
	int32_t packed;
	if(AudioFormatIsDoPInteger(format)) {
		memcpy(&packed, (const uint8_t *)samples + sampleIndex * sizeof(packed), sizeof(packed));
	} else if(AudioFormatIsFloat64(format)) {
		const double sample = ((const double *)samples)[sampleIndex];
		if(!isfinite(sample) || sample >= 1.0 || sample < -1.0) return NO;
		packed = (int32_t)llrint(sample * 2147483648.0);
	} else if(AudioFormatIsFloat32(format)) {
		const float sample = ((const float *)samples)[sampleIndex];
		if(!isfinite(sample) || sample >= 1.0f || sample < -1.0f) return NO;
		packed = (int32_t)llrint((double)sample * 2147483648.0);
	} else {
		return NO;
	}
	*marker = (uint8_t)(((uint32_t)packed) >> 24);
	return YES;
}

BOOL audioBufferIsDoP(const void *samples, AudioStreamBasicDescription format, size_t count, uint8_t *nextMarker) {
	const size_t channels = format.mChannelsPerFrame;
	if(!samples || !channels || !count ||
	   (!AudioFormatIsDoPInteger(format) &&
	    !AudioFormatIsFloat64(format) &&
	    !AudioFormatIsFloat32(format))) return NO;

	// A DoP frame has the same 0x05/0xFA marker in every channel, and the
	// marker alternates on every frame. Validate the complete buffer: callers use
	// the returned phase to join buffers, so accepting a damaged tail can make a
	// DAC lose DoP lock.
	uint8_t previousMarker = 0;
	for(size_t frame = 0; frame < count; ++frame) {
		uint8_t marker = 0;
		if(!doPMarkerForSample(samples, format, frame * channels, &marker)) return NO;
		if(marker != 0x05 && marker != 0xFA) return NO;
		if(frame && marker == previousMarker) return NO;
		for(size_t channel = 1; channel < channels; ++channel) {
			uint8_t channelMarker = 0;
			if(!doPMarkerForSample(samples, format, frame * channels + channel, &channelMarker) ||
			   channelMarker != marker) return NO;
		}
		previousMarker = marker;
	}

	if(nextMarker) {
		*nextMarker = (previousMarker == 0x05) ? 0xFA : 0x05;
	}
	return YES;
}

BOOL fillDoPSilence(void *samples, AudioStreamBasicDescription format, size_t count, uint8_t *nextMarker) {
	const size_t channels = format.mChannelsPerFrame;
	if(!samples || !channels || !nextMarker ||
	   (!AudioFormatIsDoPInteger(format) &&
	    !AudioFormatIsFloat64(format) &&
	    !AudioFormatIsFloat32(format))) return NO;
	uint8_t marker = (*nextMarker == 0xFA) ? 0xFA : 0x05;
	for(size_t frame = 0; frame < count; ++frame) {
		const uint32_t packed = ((uint32_t)marker << 24) | (0x69U << 16) | (0x69U << 8);
		if(AudioFormatIsDoPInteger(format)) {
			for(size_t channel = 0; channel < channels; ++channel) {
				memcpy((uint8_t *)samples + (frame * channels + channel) * sizeof(packed), &packed, sizeof(packed));
			}
		} else if(AudioFormatIsFloat64(format)) {
			int32_t signedPacked;
			memcpy(&signedPacked, &packed, sizeof(signedPacked));
			const double silence = (double)signedPacked / 2147483648.0;
			for(size_t channel = 0; channel < channels; ++channel) {
				((double *)samples)[frame * channels + channel] = silence;
			}
		} else {
			int32_t signedPacked;
			memcpy(&signedPacked, &packed, sizeof(signedPacked));
			const float silence = (float)((double)signedPacked / 2147483648.0);
			for(size_t channel = 0; channel < channels; ++channel) {
				((float *)samples)[frame * channels + channel] = silence;
			}
		}
		marker = (marker == 0x05) ? 0xFA : 0x05;
	}
	*nextMarker = marker;
	return YES;
}

BOOL fadeAudio(const float *inSamples, float *outSamples, size_t channels, size_t count, float *fadeLevel, float fadeStep, float fadeTarget) {
	float _fadeLevel = *fadeLevel;
	BOOL towardZero = fadeStep < 0.0;
	BOOL stopping = NO;
	size_t maxCount = (size_t)floor(fabs(fadeTarget - _fadeLevel) / fabs(fadeStep));
	if(maxCount) {
		size_t countToDo = MIN(count, maxCount);
		for(size_t i = 0; i < channels; ++i) {
			_fadeLevel = *fadeLevel;
			vDSP_vrampmuladd(&inSamples[i], channels, &_fadeLevel, &fadeStep, &outSamples[i], channels, countToDo);
		}
	}
	if(maxCount <= count) {
		if(!towardZero && maxCount < count) {
			vDSP_vadd(&inSamples[maxCount * channels], 1, &outSamples[maxCount * channels], 1, &outSamples[maxCount * channels], 1, (count - maxCount) * channels);
		}
		stopping = YES;
	}
	*fadeLevel = _fadeLevel;
	return stopping;
}

BOOL fadeAudio64(const double *inSamples, double *outSamples, size_t channels, size_t count, double *fadeLevel, double fadeStep, double fadeTarget) {
	double _fadeLevel = *fadeLevel;
	BOOL towardZero = fadeStep < 0.0;
	BOOL stopping = NO;
	size_t maxCount = (size_t)floor(fabs(fadeTarget - _fadeLevel) / fabs(fadeStep));
	if(maxCount) {
		size_t countToDo = MIN(count, maxCount);
		for(size_t i = 0; i < channels; ++i) {
			_fadeLevel = *fadeLevel;
			vDSP_vrampmuladdD(&inSamples[i], channels, &_fadeLevel, &fadeStep, &outSamples[i], channels, countToDo);
		}
	}
	if(maxCount <= count) {
		if(!towardZero && maxCount < count) {
			vDSP_vaddD(&inSamples[maxCount * channels], 1, &outSamples[maxCount * channels], 1, &outSamples[maxCount * channels], 1, (count - maxCount) * channels);
		}
		stopping = YES;
	}
	*fadeLevel = _fadeLevel;
	return stopping;
}

@implementation FadedBuffer {
	double fadeLevel;
	double fadeStep;
	double fadeTarget;

	ChunkList *lastBuffer;

	NSArray *DSPs;
}

- (id)initWithBuffer:(ChunkList *)buffer withDSPs:(NSArray *)DSPs fadeStart:(double)fadeStart fadeTarget:(double)fadeTarget sampleRate:(double)sampleRate {
	self = [super init];
	if(self) {
		self->buffer = buffer;
		self->DSPs = DSPs;

		writeSemaphore = [Semaphore new];
		readSemaphore = [Semaphore new];

		accessLock = [NSLock new];

		initialBufferFilled = NO;

		controller = self;
		endOfStream = NO;
		shouldContinue = YES;

		nodeChannelConfig = 0;
		nodeLossless = NO;

		durationPrebuffer = 0;

		inWrite = NO;
		inPeek = NO;
		inRead = NO;
		inMerge = NO;

		[self setPreviousNode:nil];

#ifdef LOG_CHAINS
		[self initLogFiles];
#endif

		fadeLevel = fadeStart;
		self->fadeTarget = fadeTarget;
		lastBuffer = buffer;
		const double maxFadeDurationMS = 1000.0 * [buffer listDuration];
		const double fadeDuration = MIN(fadeTimeMS, maxFadeDurationMS);
		fadeStep = ((fadeTarget - fadeLevel) / sampleRate) * (1000.0 / fadeDuration);

		Node *node = DSPs[0];
		[node setPreviousNode:self];
	}
	return self;
}

- (void)dealloc {
	for(Node *node in DSPs) {
		[node setShouldContinue:NO];
	}
}

- (BOOL)mix:(double *)outputBuffer sampleCount:(size_t)samples channelCount:(size_t)channels {
	if(lastBuffer) {
		size_t dspCount = [DSPs count];
		Node *node = DSPs[dspCount - 1];
		AudioChunk * chunk = [[node buffer] removeAndMergeSamplesAsFloat64:samples callBlock:^BOOL{
			if(![buffer isEmpty] && fadeStep) return false;
			else return true;
		}];
		if(chunk && [chunk frameCount]) {
			// Will always be input request size or less
			size_t samplesToMix = [chunk frameCount];
			NSData *sampleData = [chunk removeSamples:samplesToMix];
			if([chunk isDoP] && audioBufferIsDoP([sampleData bytes], [chunk format], samplesToMix, NULL)) {
				// DoP is a bitstream disguised as PCM. Mixing or fading it corrupts
				// both its marker bytes and its DSD payload, so use a hard cut.
				return true;
			}
			BOOL stopping = fadeAudio64((const double *)[sampleData bytes], outputBuffer, channels, samplesToMix, &fadeLevel, fadeStep, fadeTarget);
			if(stopping) {
				fadeStep = 0;
				fadeLevel = fadeTarget;
			}
			return stopping;
		}
	}
	// No buffer or no chunk, stream ended
	return true;
}

@end
