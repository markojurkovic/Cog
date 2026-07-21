//
//  ChunkList.m
//  CogAudio Framework
//
//  Created by Christopher Snowhill on 2/5/22.
//

#import <Accelerate/Accelerate.h>

#import "ChunkList.h"

#import "hdcd_decode2.h"

#if !DSD_DECIMATE
#import "dsd2float.h"
#endif

#ifdef _DEBUG
#import "BadSampleCleaner.h"
#endif

static void *kChunkListContext = &kChunkListContext;

#if DSD_DECIMATE
/**
 * DSD 2 PCM: Stage 1:
 * Decimate by factor 8
 * (one byte (8 samples) -> one float sample)
 * The bits are processed from least signicifant to most signicicant.
 * @author Sebastian Gesemann
 */

/**
 * This is the 2nd half of an even order symmetric FIR
 * lowpass filter (to be used on a signal sampled at 44100*64 Hz)
 * Passband is 0-24 kHz (ripples +/- 0.025 dB)
 * Stopband starts at 176.4 kHz (rejection: 170 dB)
 * The overall gain is 2.0
 */

#define dsd2pcm_FILTER_COEFFS_COUNT 64
static const double dsd2pcm_FILTER_COEFFS[64] = {
	0.09712411121659, 0.09613438994044, 0.09417884216316, 0.09130441727307,
	0.08757947648990, 0.08309142055179, 0.07794369263673, 0.07225228745463,
	0.06614191680338, 0.05974199351302, 0.05318259916599, 0.04659059631228,
	0.04008603356890, 0.03377897290478, 0.02776684382775, 0.02213240062966,
	0.01694232798846, 0.01224650881275, 0.00807793792573, 0.00445323755944,
	0.00137370697215, -0.00117318019994, -0.00321193033831, -0.00477694265140,
	-0.00591028841335, -0.00665946056286, -0.00707518873201, -0.00720940203988,
	-0.00711340642819, -0.00683632603227, -0.00642384017266, -0.00591723006715,
	-0.00535273320457, -0.00476118922548, -0.00416794965654, -0.00359301524813,
	-0.00305135909510, -0.00255339111833, -0.00210551956895, -0.00171076760278,
	-0.00136940723130, -0.00107957856005, -0.00083786862365, -0.00063983084245,
	-0.00048043272086, -0.00035442550015, -0.00025663481039, -0.00018217573430,
	-0.00012659899635, -0.00008597726991, -0.00005694188820, -0.00003668060332,
	-0.00002290670286, -0.00001380895679, -0.00000799057558, -0.00000440385083,
	-0.00000228567089, -0.00000109760778, -0.00000047286430, -0.00000017129652,
	-0.00000004282776, 0.00000000119422, 0.00000000949179, 0.00000000747450
};

struct dsd2pcm_state {
	/*
	 * This is the 2nd half of an even order symmetric FIR
	 * lowpass filter (to be used on a signal sampled at 44100*64 Hz)
	 * Passband is 0-24 kHz (ripples +/- 0.025 dB)
	 * Stopband starts at 176.4 kHz (rejection: 170 dB)
	 * The overall gain is 2.0
	 */

	/* These remain constant for the duration */
	int FILT_LOOKUP_PARTS;
	double *FILT_LOOKUP_TABLE;
	uint8_t *REVERSE_BITS;
	int FIFO_LENGTH;
	int FIFO_OFS_MASK;

	/* These are altered */
	int *fifo;
	int fpos;
};

static void dsd2pcm_free(void *);
static void dsd2pcm_reset(void *);

static void *dsd2pcm_alloc(void) {
	struct dsd2pcm_state *state = (struct dsd2pcm_state *)calloc(1, sizeof(struct dsd2pcm_state));

	double *FILT_LOOKUP_TABLE;
	double *temp;
	uint8_t *REVERSE_BITS;

	if(!state)
		return NULL;

	state->FILT_LOOKUP_PARTS = (dsd2pcm_FILTER_COEFFS_COUNT + 7) / 8;
	const int FILT_LOOKUP_PARTS = state->FILT_LOOKUP_PARTS;
	// The current 128 tap FIR leads to a 16 KB double-precision lookup table.
	state->FILT_LOOKUP_TABLE = (double *)calloc(sizeof(double), FILT_LOOKUP_PARTS << 8);
	if(!state->FILT_LOOKUP_TABLE)
		goto fail;
	FILT_LOOKUP_TABLE = state->FILT_LOOKUP_TABLE;
	temp = (double *)calloc(sizeof(double), 0x100);
	if(!temp)
		goto fail;
	for(int part = 0, sofs = 0, dofs = 0; part < FILT_LOOKUP_PARTS;) {
		memset(temp, 0, 0x100 * sizeof(double));
		for(int bit = 0, bitmask = 0x80; bit < 8 && sofs + bit < dsd2pcm_FILTER_COEFFS_COUNT;) {
			double coeff = dsd2pcm_FILTER_COEFFS[sofs + bit];
			for(int bite = 0; bite < 0x100; bite++) {
				if((bite & bitmask) == 0) {
					temp[bite] -= coeff;
				} else {
					temp[bite] += coeff;
				}
			}
			bit++;
			bitmask >>= 1;
		}
		for(int s = 0; s < 0x100;) {
			FILT_LOOKUP_TABLE[dofs++] = temp[s++];
		}
		part++;
		sofs += 8;
	}
	free(temp);
	{ // calculate FIFO stuff
		int k = 1;
		while(k < FILT_LOOKUP_PARTS * 2) k <<= 1;
		state->FIFO_LENGTH = k;
		state->FIFO_OFS_MASK = k - 1;
	}
	state->REVERSE_BITS = (uint8_t *)calloc(1, 0x100);
	if(!state->REVERSE_BITS)
		goto fail;
	REVERSE_BITS = state->REVERSE_BITS;
	for(int i = 0, j = 0; i < 0x100; i++) {
		REVERSE_BITS[i] = (uint8_t)j;
		// "reverse-increment" of j
		for(int bitmask = 0x80;;) {
			if(((j ^= bitmask) & bitmask) != 0) break;
			if(bitmask == 1) break;
			bitmask >>= 1;
		}
	}

	state->fifo = (int *)calloc(sizeof(int), state->FIFO_LENGTH);
	if(!state->fifo)
		goto fail;

	dsd2pcm_reset(state);

	return (void *)state;

fail:
	dsd2pcm_free(state);
	return NULL;
}

static void *dsd2pcm_dup(void *_state) {
	struct dsd2pcm_state *state = (struct dsd2pcm_state *)_state;
	if(state) {
		struct dsd2pcm_state *newstate = (struct dsd2pcm_state *)calloc(1, sizeof(struct dsd2pcm_state));
		if(newstate) {
			newstate->FILT_LOOKUP_PARTS = state->FILT_LOOKUP_PARTS;
			newstate->FIFO_LENGTH = state->FIFO_LENGTH;
			newstate->FIFO_OFS_MASK = state->FIFO_OFS_MASK;
			newstate->fpos = state->fpos;

			newstate->FILT_LOOKUP_TABLE = (double *)calloc(sizeof(double), state->FILT_LOOKUP_PARTS << 8);
			if(!newstate->FILT_LOOKUP_TABLE)
				goto fail;

			memcpy(newstate->FILT_LOOKUP_TABLE, state->FILT_LOOKUP_TABLE, sizeof(double) * (state->FILT_LOOKUP_PARTS << 8));

			newstate->REVERSE_BITS = (uint8_t *)calloc(1, 0x100);
			if(!newstate->REVERSE_BITS)
				goto fail;

			memcpy(newstate->REVERSE_BITS, state->REVERSE_BITS, 0x100);

			newstate->fifo = (int *)calloc(sizeof(int), state->FIFO_LENGTH);
			if(!newstate->fifo)
				goto fail;

			memcpy(newstate->fifo, state->fifo, sizeof(int) * state->FIFO_LENGTH);

			return (void *)newstate;
		}

	fail:
		dsd2pcm_free(newstate);
		return NULL;
	}

	return NULL;
}

static void dsd2pcm_free(void *_state) {
	struct dsd2pcm_state *state = (struct dsd2pcm_state *)_state;
	if(state) {
		free(state->fifo);
		free(state->REVERSE_BITS);
		free(state->FILT_LOOKUP_TABLE);
		free(state);
	}
}

static void dsd2pcm_reset(void *_state) {
	struct dsd2pcm_state *state = (struct dsd2pcm_state *)_state;
	const int FILT_LOOKUP_PARTS = state->FILT_LOOKUP_PARTS;
	int *fifo = state->fifo;
	for(int i = 0; i < FILT_LOOKUP_PARTS; i++) {
		fifo[i] = 0x55;
		fifo[i + FILT_LOOKUP_PARTS] = 0xAA;
	}
	state->fpos = FILT_LOOKUP_PARTS;
}

static int dsd2pcm_latency(void *_state) {
	struct dsd2pcm_state *state = (struct dsd2pcm_state *)_state;
	if(state)
		return state->FILT_LOOKUP_PARTS * 8;
	else
		return 0;
}

static void dsd2pcm_process(void *_state, const uint8_t *src, size_t sofs, size_t sinc, float *dest, size_t dofs, size_t dinc, size_t len) {
	struct dsd2pcm_state *state = (struct dsd2pcm_state *)_state;
	int bite1, bite2, temp;
	double sample;
	int *fifo = state->fifo;
	const uint8_t *REVERSE_BITS = state->REVERSE_BITS;
	const double *FILT_LOOKUP_TABLE = state->FILT_LOOKUP_TABLE;
	const int FILT_LOOKUP_PARTS = state->FILT_LOOKUP_PARTS;
	const int FIFO_OFS_MASK = state->FIFO_OFS_MASK;
	int fpos = state->fpos;
	while(len > 0) {
		fifo[fpos] = REVERSE_BITS[fifo[fpos]] & 0xFF;
		fifo[(fpos + FILT_LOOKUP_PARTS) & FIFO_OFS_MASK] = src[sofs] & 0xFF;
		sofs += sinc;
		temp = (fpos + 1) & FIFO_OFS_MASK;
		sample = 0;
		for(int k = 0, lofs = 0; k < FILT_LOOKUP_PARTS;) {
			bite1 = fifo[(fpos - k) & FIFO_OFS_MASK];
			bite2 = fifo[(temp + k) & FIFO_OFS_MASK];
			sample += FILT_LOOKUP_TABLE[lofs + bite1] + FILT_LOOKUP_TABLE[lofs + bite2];
			k++;
			lofs += 0x100;
		}
		fpos = temp;
		dest[dofs] = (float)sample;
		dofs += dinc;
		len--;
	}
	state->fpos = fpos;
}

static void convert_dsd_to_f32(float *output, const uint8_t *input, size_t count, size_t channels, void **dsd2pcm) {
	for(size_t channel = 0; channel < channels; ++channel) {
		dsd2pcm_process(dsd2pcm[channel], input, channel, channels, output, channel, channels, count);
	}
}

static void dsd2pcm_process64(void *_state, const uint8_t *src, size_t sofs, size_t sinc, double *dest, size_t dofs, size_t dinc, size_t len) {
	struct dsd2pcm_state *state = (struct dsd2pcm_state *)_state;
	int *fifo = state->fifo;
	const uint8_t *REVERSE_BITS = state->REVERSE_BITS;
	const double *FILT_LOOKUP_TABLE = state->FILT_LOOKUP_TABLE;
	const int FILT_LOOKUP_PARTS = state->FILT_LOOKUP_PARTS;
	const int FIFO_OFS_MASK = state->FIFO_OFS_MASK;
	int fpos = state->fpos;
	while(len > 0) {
		fifo[fpos] = REVERSE_BITS[fifo[fpos]] & 0xFF;
		fifo[(fpos + FILT_LOOKUP_PARTS) & FIFO_OFS_MASK] = src[sofs] & 0xFF;
		sofs += sinc;
		int temp = (fpos + 1) & FIFO_OFS_MASK;
		double sample = 0;
		for(int k = 0, lofs = 0; k < FILT_LOOKUP_PARTS;) {
			int bite1 = fifo[(fpos - k) & FIFO_OFS_MASK];
			int bite2 = fifo[(temp + k) & FIFO_OFS_MASK];
			sample += FILT_LOOKUP_TABLE[lofs + bite1] + FILT_LOOKUP_TABLE[lofs + bite2];
			k++;
			lofs += 0x100;
		}
		fpos = temp;
		dest[dofs] = sample;
		dofs += dinc;
		len--;
	}
	state->fpos = fpos;
}

static void convert_dsd_to_f64(double *output, const uint8_t *input, size_t count, size_t channels, void **dsd2pcm) {
	for(size_t channel = 0; channel < channels; ++channel) {
		dsd2pcm_process64(dsd2pcm[channel], input, channel, channels, output, channel, channels, count);
	}
}
#else
static void convert_dsd_to_f32(float *output, const uint8_t *input, size_t count, size_t channels) {
	const uint8_t *iptr = input;
	float *optr = output;
	for(size_t index = 0; index < count; ++index) {
		for(size_t channel = 0; channel < channels; ++channel) {
			uint8_t sample = *iptr++;
			cblas_scopy(8, &dsd2float[sample][0], 1, optr++, (int)channels);
		}
		optr += channels * 7;
	}
}

static void convert_dsd_to_f64(double *output, const uint8_t *input, size_t count, size_t channels) {
	const uint8_t *iptr = input;
	double *optr = output;
	for(size_t index = 0; index < count; ++index) {
		for(size_t channel = 0; channel < channels; ++channel) {
			uint8_t sample = *iptr++;
			for(size_t bit = 0; bit < 8; ++bit) {
				optr[bit * channels] = dsd2float[sample][bit];
			}
			++optr;
		}
		optr += channels * 7;
	}
}
#endif

static uint8_t reverse_bits8(uint8_t value) {
	value = (uint8_t)(((value & 0xF0) >> 4) | ((value & 0x0F) << 4));
	value = (uint8_t)(((value & 0xCC) >> 2) | ((value & 0x33) << 2));
	value = (uint8_t)(((value & 0xAA) >> 1) | ((value & 0x55) << 1));
	return value;
}

static int32_t pack_dop_word_s32(uint8_t first, uint8_t second, uint8_t marker) {
	const uint32_t packed = ((uint32_t)marker << 24) | ((uint32_t)first << 16) | ((uint32_t)second << 8);
	int32_t signedPacked;
	memcpy(&signedPacked, &packed, sizeof(signedPacked));
	return signedPacked;
}

static size_t convert_dsd_to_dop_s32(int32_t *output, const uint8_t *input, size_t inputFrames, size_t channels, BOOL reverseBits, uint8_t *pendingFrame, BOOL *hasPendingFrame, uint8_t *nextMarker) {
	if(!output || !input || !channels || channels > 32) return 0;

	size_t inputFrame = 0;
	size_t outputFrame = 0;
	uint8_t marker = (*nextMarker == 0xFA) ? 0xFA : 0x05;

	// Some decoders normalize DSD bytes for PCM conversion; DoP needs the
	// serialized payload bit order back on the wire.
	if(*hasPendingFrame && inputFrames) {
		for(size_t channel = 0; channel < channels; ++channel) {
			const uint8_t first = reverseBits ? reverse_bits8(pendingFrame[channel]) : pendingFrame[channel];
			const uint8_t second = reverseBits ? reverse_bits8(input[channel]) : input[channel];
			output[channel] = pack_dop_word_s32(first, second, marker);
		}
		marker = (marker == 0x05) ? 0xFA : 0x05;
		inputFrame = 1;
		outputFrame = 1;
		*hasPendingFrame = NO;
	}

	while(inputFrame + 1 < inputFrames) {
		for(size_t channel = 0; channel < channels; ++channel) {
			uint8_t first = input[inputFrame * channels + channel];
			uint8_t second = input[(inputFrame + 1) * channels + channel];
			if(reverseBits) {
				first = reverse_bits8(first);
				second = reverse_bits8(second);
			}
			output[outputFrame * channels + channel] = pack_dop_word_s32(first, second, marker);
		}
		marker = (marker == 0x05) ? 0xFA : 0x05;
		inputFrame += 2;
		++outputFrame;
	}

	if(inputFrame < inputFrames) {
		memcpy(pendingFrame, input + inputFrame * channels, channels);
		*hasPendingFrame = YES;
	}

	*nextMarker = marker;
	return outputFrame;
}

static void convert_s16_to_hdcd_input(int32_t *output, const int16_t *input, size_t count) {
	for(size_t i = 0; i < count; ++i) {
		output[i] = input[i];
	}
}

static uint32_t load_pcm_word(const uint8_t *input, size_t storageBytes, BOOL bigEndian) {
	uint32_t word = 0;
	if(bigEndian) {
		for(size_t byte = 0; byte < storageBytes; ++byte) {
			word = (word << 8) | input[byte];
		}
	} else {
		for(size_t byte = 0; byte < storageBytes; ++byte) {
			word |= (uint32_t)input[byte] << (byte * 8);
		}
	}
	return word;
}

static int32_t pcm_word_to_full_s32(const uint8_t *input, size_t storageBytes, size_t validBits, BOOL bigEndian, BOOL alignedHigh, BOOL isUnsigned) {
	uint64_t word = load_pcm_word(input, storageBytes, bigEndian);
	const size_t storageBits = storageBytes * 8;
	if(alignedHigh && validBits < storageBits) {
		word >>= storageBits - validBits;
	}

	const uint64_t mask = (UINT64_C(1) << validBits) - 1;
	word &= mask;
	const uint64_t signBit = UINT64_C(1) << (validBits - 1);
	const int64_t centered = isUnsigned ? (int64_t)word - (int64_t)signBit :
	                                       (int64_t)(word ^ signBit) - (int64_t)signBit;
	return (int32_t)(centered * (int64_t)(UINT64_C(1) << (32 - validBits)));
}

static void convert_integer_pcm_to_s32(int32_t *output, const uint8_t *input, size_t count, size_t storageBytes, size_t validBits, BOOL bigEndian, BOOL alignedHigh, BOOL isUnsigned) {
	for(size_t sample = 0; sample < count; ++sample) {
		output[sample] = pcm_word_to_full_s32(input + sample * storageBytes, storageBytes, validBits, bigEndian, alignedHigh, isUnsigned);
	}
}

static void convert_integer_pcm_to_s16(int16_t *output, const uint8_t *input, size_t count, size_t storageBytes, size_t validBits, BOOL bigEndian, BOOL alignedHigh, BOOL isUnsigned) {
	for(size_t sample = 0; sample < count; ++sample) {
		output[sample] = (int16_t)(pcm_word_to_full_s32(input + sample * storageBytes, storageBytes, validBits, bigEndian, alignedHigh, isUnsigned) / INT64_C(65536));
	}
}

static void convert_f64_to_f32(float *output, const double *input, size_t count) {
	vDSP_vdpsp(input, 1, output, 1, count);
}

static void convert_f32_to_f64(double *output, const float *input, size_t count) {
	vDSP_vspdp(input, 1, output, 1, count);
}

static void swap_sample_endianness(uint8_t *buffer, size_t storageBytes, size_t sampleCount) {
	for(size_t sample = 0; sample < sampleCount; ++sample) {
		uint8_t *word = buffer + sample * storageBytes;
		for(size_t left = 0, right = storageBytes - 1; left < right; ++left, --right) {
			const uint8_t temporary = word[left];
			word[left] = word[right];
			word[right] = temporary;
		}
	}
}

@implementation ChunkList

@synthesize listDuration;
@synthesize listDurationRatioed;
@synthesize maxDuration;

- (void)destroyHDCDState {
	if(hdcd_decoder) {
		free(hdcd_decoder);
		hdcd_decoder = NULL;
	}
}

- (void)destroyDSDState {
#if DSD_DECIMATE
	if(dsd2pcm) {
		for(size_t channel = 0; channel < dsd2pcmCount; ++channel) {
			dsd2pcm_free(dsd2pcm[channel]);
			dsd2pcm[channel] = NULL;
		}
		free(dsd2pcm);
		dsd2pcm = NULL;
	}
	dsd2pcmCount = 0;
	dsd2pcmLatency = 0;
#endif
}

- (void)invalidateConversionState {
	formatRead = NO;
	[self destroyHDCDState];
	[self destroyDSDState];
	dsdDoPHasPendingFrame = NO;
	dsdDoPMarker = 0x05;
}

- (id)initWithMaximumDuration:(double)duration {
	self = [super init];

	if(self) {
		chunkList = [NSMutableArray new];
		listDuration = 0.0;
		listDurationRatioed = 0.0;
		maxDuration = duration;

		inAdder = NO;
		inRemover = NO;
		inPeeker = NO;
		inMerger = NO;
		inConverter = NO;
		stopping = NO;
		
		formatRead = NO;
		converterOutputFloat64 = NO;

		inputBuffer = NULL;
		inputBufferSize = 0;

#if DSD_DECIMATE
		dsd2pcm = NULL;
		dsd2pcmCount = 0;
		dsd2pcmLatency = 0;
#endif

		observersRegistered = NO;
		outputDSDAsDoP = NO;
		dsdDoPHasPendingFrame = NO;
		dsdDoPMarker = 0x05;
	}

	return self;
}

- (void)addObservers {
	if(!observersRegistered) {
		halveDSDVolume = NO;
		enableHDCD = NO;

		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.halveDSDVolume" options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew) context:kChunkListContext];
		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.enableHDCD" options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew) context:kChunkListContext];

		observersRegistered = YES;
	}
}

- (void)removeObservers {
	if(observersRegistered) {
		[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.halveDSDVolume" context:kChunkListContext];
		[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.enableHDCD" context:kChunkListContext];

		observersRegistered = NO;
	}
}

- (void)dealloc {
	stopping = YES;
	while(inAdder || inRemover || inPeeker || inMerger || inConverter) {
		usleep(500);
	}
	[self removeObservers];
	[self destroyHDCDState];
	[self destroyDSDState];
	if(tempData) {
		free(tempData);
	}
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if(context != kChunkListContext) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}
	
	if([keyPath isEqualToString:@"values.halveDSDVolume"]) {
		halveDSDVolume = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] boolForKey:@"halveDSDVolume"];
	} else if([keyPath isEqualToString:@"values.enableHDCD"]) {
		enableHDCD = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] boolForKey:@"enableHDCD"];
	}
}

- (void)reset {
	@synchronized(chunkList) {
		@synchronized(self) {
			[chunkList removeAllObjects];
			listDuration = 0.0;
			listDurationRatioed = 0.0;
			[self invalidateConversionState];
		}
	}
}

- (void)setOutputDSDAsDoP:(BOOL)enabled {
	@synchronized(chunkList) {
		@synchronized(self) {
			if(outputDSDAsDoP == enabled) {
				return;
			}
			outputDSDAsDoP = enabled;
			[self invalidateConversionState];
		}
	}
}

- (BOOL)isEmpty {
	@synchronized(chunkList) {
		return [chunkList count] == 0;
	}
}

- (BOOL)isFull {
	@synchronized (chunkList) {
		return (maxDuration - listDuration) < 0.001;
	}
}

- (void)addChunk:(AudioChunk *)chunk {
	if(stopping) return;

	inAdder = YES;

	const double chunkDuration = [chunk duration];
	const double chunkDurationRatioed = [chunk durationRatioed];

	@synchronized(chunkList) {
		[chunkList addObject:chunk];
		listDuration += chunkDuration;
		listDurationRatioed += chunkDurationRatioed;
	}

	inAdder = NO;
}

- (AudioChunk *)removeSamples:(size_t)maxFrameCount {
	if(stopping) {
		return [AudioChunk new];
	}

	@synchronized(chunkList) {
		inRemover = YES;
		if(![chunkList count]) {
			inRemover = NO;
			return [AudioChunk new];
		}
		AudioChunk *chunk = [chunkList objectAtIndex:0];
		if([chunk frameCount] <= maxFrameCount) {
			[chunkList removeObjectAtIndex:0];
			listDuration -= [chunk duration];
			listDurationRatioed -= [chunk durationRatioed];
			inRemover = NO;
			return chunk;
		}
		double streamTimestamp = [chunk streamTimestamp];
		NSData *removedData = [chunk removeSamples:maxFrameCount];
		AudioChunk *ret = [AudioChunk new];
		[ret setFormat:[chunk format]];
		[ret setChannelConfig:[chunk channelConfig]];
		[ret setLossless:[chunk lossless]];
		[ret setDsdDoPReverseBits:[chunk dsdDoPReverseBits]];
		[ret setDoP:[chunk isDoP]];
		[ret setStreamTimestamp:streamTimestamp];
		[ret setStreamTimeRatio:[chunk streamTimeRatio]];
		[ret assignData:removedData];
		if(chunk.resetForward) {
			ret.resetForward = YES;
			chunk.resetForward = NO;
		}
		listDuration -= [ret duration];
		listDurationRatioed -= [ret durationRatioed];
		inRemover = NO;
		return ret;
	}
}

- (AudioChunk *)removeSamplesAsFloat32:(size_t)maxFrameCount {
	return [self removeSamplesConvertedToFloat64:NO maxFrameCount:maxFrameCount];
}

- (AudioChunk *)removeSamplesAsFloat64:(size_t)maxFrameCount {
	return [self removeSamplesConvertedToFloat64:YES maxFrameCount:maxFrameCount];
}

- (AudioChunk *)removeSamplesConvertedToFloat64:(BOOL)toFloat64 maxFrameCount:(size_t)maxFrameCount {
	if(stopping) {
		return [AudioChunk new];
	}

	@synchronized (chunkList) {
		inRemover = YES;
		if(![chunkList count]) {
			inRemover = NO;
			return [AudioChunk new];
		}
		AudioChunk *chunk = [chunkList objectAtIndex:0];
#if !DSD_DECIMATE
		AudioStreamBasicDescription asbd = [chunk format];
		if(asbd.mBitsPerChannel == 1) {
			maxFrameCount /= 8;
		}
#endif
		if([chunk frameCount] <= maxFrameCount) {
			[chunkList removeObjectAtIndex:0];
			listDuration -= [chunk duration];
			listDurationRatioed -= [chunk durationRatioed];
			inRemover = NO;
			return [self convertChunk:chunk toFloat64:toFloat64];
		}
		double streamTimestamp = [chunk streamTimestamp];
		NSData *removedData = [chunk removeSamples:maxFrameCount];
		AudioChunk *ret = [AudioChunk new];
		[ret setFormat:[chunk format]];
		[ret setChannelConfig:[chunk channelConfig]];
		[ret setLossless:[chunk lossless]];
		[ret setDsdDoPReverseBits:[chunk dsdDoPReverseBits]];
		[ret setDoP:[chunk isDoP]];
		[ret setStreamTimestamp:streamTimestamp];
		[ret setStreamTimeRatio:[chunk streamTimeRatio]];
		[ret assignData:removedData];
		if(chunk.resetForward) {
			ret.resetForward = YES;
			chunk.resetForward = NO;
		}
		listDuration -= [ret duration];
		listDurationRatioed -= [ret durationRatioed];
		inRemover = NO;
		return [self convertChunk:ret toFloat64:toFloat64];
	}
}

- (AudioChunk *)removeAndMergeSamples:(size_t)maxFrameCount callBlock:(BOOL(NS_NOESCAPE ^ _Nonnull)(void))block {
	if(stopping) {
		return [AudioChunk new];
	}

	inMerger = YES;

	BOOL formatSet = NO;
	AudioStreamBasicDescription currentFormat;
	uint32_t currentChannelConfig = 0;

	double streamTimestamp = 0.0;
	double streamTimeRatio = 1.0;
	BOOL blocked = NO;
	while(![self peekTimestamp:&streamTimestamp timeRatio:&streamTimeRatio]) {
		if((blocked = block())) {
			break;
		}
	}

	if(blocked) {
		inMerger = NO;
		return [AudioChunk new];
	}

	AudioChunk *chunk;
	size_t totalFrameCount = 0;
	AudioChunk *outputChunk = [AudioChunk new];

	[outputChunk setStreamTimestamp:streamTimestamp];
	[outputChunk setStreamTimeRatio:streamTimeRatio];

	while(!stopping && totalFrameCount < maxFrameCount) {
		AudioStreamBasicDescription newFormat;
		uint32_t newChannelConfig;
		if(![self peekFormat:&newFormat channelConfig:&newChannelConfig]) {
			if(block()) {
				break;
			}
			continue;
		}
		if(formatSet &&
		   (memcmp(&newFormat, &currentFormat, sizeof(newFormat)) != 0 ||
			newChannelConfig != currentChannelConfig)) {
			break;
		} else if(!formatSet) {
			[outputChunk setFormat:newFormat];
			[outputChunk setChannelConfig:newChannelConfig];
			currentFormat = newFormat;
			currentChannelConfig = newChannelConfig;
			formatSet = YES;
		}

		chunk = [self removeSamples:maxFrameCount - totalFrameCount];
		if(!chunk || ![chunk frameCount]) {
			if(block()) {
				break;
			}
			continue;
		}

		if([chunk isHDCD]) {
			[outputChunk setHDCD];
		}

		if(!totalFrameCount) {
			[outputChunk setDsdDoPReverseBits:[chunk dsdDoPReverseBits]];
			[outputChunk setDoP:[chunk isDoP]];
		}

		if(chunk.resetForward) {
			outputChunk.resetForward = YES;
		}

		size_t frameCount = [chunk frameCount];
		NSData *sampleData = [chunk removeSamples:frameCount];

		[outputChunk assignData:sampleData];

		totalFrameCount += frameCount;
	}

	if(!totalFrameCount) {
		inMerger = NO;
		return [AudioChunk new];
	}

	inMerger = NO;
	return outputChunk;
}

- (AudioChunk *)removeAndMergeSamplesAsFloat32:(size_t)maxFrameCount callBlock:(BOOL(NS_NOESCAPE ^ _Nonnull)(void))block {
	AudioChunk *ret = [self removeAndMergeSamples:maxFrameCount callBlock:block];
	return [self convertChunk:ret toFloat64:NO];
}

- (AudioChunk *)removeAndMergeSamplesAsFloat64:(size_t)maxFrameCount callBlock:(BOOL(NS_NOESCAPE ^ _Nonnull)(void))block {
	AudioChunk *ret = [self removeAndMergeSamples:maxFrameCount callBlock:block];
	return [self convertChunk:ret toFloat64:YES];
}

- (AudioChunk *)convertChunkLocked:(AudioChunk *)inChunk toFloat64:(BOOL)toFloat64 {
	if(stopping) return [AudioChunk new];

	inConverter = YES;

	AudioStreamBasicDescription chunkFormat = [inChunk format];
	// Despite these methods' historical floating-point names, DoP is an opaque integer
	// bitstream. Preserve only explicitly tagged DoP chunks; ordinary 24-bit PCM
	// using the same ASBD still follows the normal PCM conversion below.
	if(![inChunk frameCount] ||
	   ([inChunk isDoP] && AudioFormatIsDoPInteger(chunkFormat))) {
		inConverter = NO;
		return inChunk;
	}

	const BOOL nativeTargetFormat = toFloat64 ? AudioFormatIsFloat64(chunkFormat) : AudioFormatIsFloat32(chunkFormat);
	uint32_t chunkConfig = [inChunk channelConfig];
	BOOL chunkLossless = [inChunk lossless];
	if(inChunk.resetForward || !formatRead || converterOutputFloat64 != toFloat64 || memcmp(&chunkFormat, &inputFormat, sizeof(chunkFormat)) != 0 ||
	   chunkConfig != inputChannelConfig || chunkLossless != inputLossless) {
		[self destroyHDCDState];
		[self destroyDSDState];
		dsdDoPHasPendingFrame = NO;
		dsdDoPMarker = 0x05;
		formatRead = NO;

		const BOOL isFloat = !!(chunkFormat.mFormatFlags & kAudioFormatFlagIsFloat);
		const BOOL validCommonLayout = chunkFormat.mFormatID == kAudioFormatLinearPCM &&
		                               !(chunkFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) &&
		                               chunkFormat.mChannelsPerFrame > 0 &&
		                               chunkFormat.mFramesPerPacket == 1 &&
		                               chunkFormat.mBytesPerFrame > 0 &&
		                               chunkFormat.mBytesPerFrame % chunkFormat.mChannelsPerFrame == 0 &&
		                               chunkFormat.mBytesPerPacket == chunkFormat.mBytesPerFrame;
		const size_t storageBytes = validCommonLayout ? chunkFormat.mBytesPerFrame / chunkFormat.mChannelsPerFrame : 0;
		const BOOL validFloatLayout = isFloat &&
		                              (chunkFormat.mBitsPerChannel == 32 || chunkFormat.mBitsPerChannel == 64) &&
		                              storageBytes == chunkFormat.mBitsPerChannel / 8;
			const BOOL validIntegerLayout = !isFloat &&
			                                chunkFormat.mBitsPerChannel >= 1 &&
			                                chunkFormat.mBitsPerChannel <= 32 &&
			                                storageBytes >= 1 && storageBytes <= sizeof(uint32_t) &&
			                                chunkFormat.mBitsPerChannel <= storageBytes * 8 &&
			                                (chunkFormat.mBitsPerChannel != 1 || storageBytes == 1);
		if(!validCommonLayout || (!validFloatLayout && !validIntegerLayout)) {
			inConverter = NO;
			return [AudioChunk new];
		}

		formatRead = YES;
		converterOutputFloat64 = toFloat64;
		inputFormat = chunkFormat;
		inputChannelConfig = chunkConfig;
		inputLossless = chunkLossless;

		if(!isFloat &&
		   inputLossless &&
		   inputFormat.mBitsPerChannel == 16 &&
		   storageBytes == sizeof(int16_t) &&
		   !!(inputFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
		   inputFormat.mChannelsPerFrame == 2 &&
		   inputFormat.mSampleRate == 44100) {
			[self addObservers];
			hdcd_decoder = calloc(1, sizeof(hdcd_state_stereo_t));
			if(!hdcd_decoder) {
				formatRead = NO;
				inConverter = NO;
				return [AudioChunk new];
			}
			hdcd_reset_stereo((hdcd_state_stereo_t *)hdcd_decoder, 44100);
		}

		floatFormat = toFloat64 ? AudioFormatAsFloat64(inputFormat) : AudioFormatAsFloat32(inputFormat);

		if(inputFormat.mBitsPerChannel == 1) {
			if(outputDSDAsDoP && inputFormat.mChannelsPerFrame <= sizeof(dsdDoPPendingFrame)) {
				floatFormat = AudioFormatAsDoPInteger(inputFormat);
				floatFormat.mSampleRate *= 1.0 / 16.0;
			} else {
#if DSD_DECIMATE
				// Decimate this for speed
				floatFormat.mSampleRate *= 1.0 / 8.0;
				dsd2pcmCount = floatFormat.mChannelsPerFrame;
				dsd2pcm = (void **)calloc(dsd2pcmCount, sizeof(void *));
				if(!dsd2pcm) {
					[self invalidateConversionState];
					inConverter = NO;
					return [AudioChunk new];
				}
				dsd2pcm[0] = dsd2pcm_alloc();
				if(!dsd2pcm[0]) {
					[self invalidateConversionState];
					inConverter = NO;
					return [AudioChunk new];
				}
				dsd2pcmLatency = dsd2pcm_latency(dsd2pcm[0]);
				for(size_t i = 1; i < dsd2pcmCount; ++i) {
					dsd2pcm[i] = dsd2pcm_dup(dsd2pcm[0]);
					if(!dsd2pcm[i]) {
						[self invalidateConversionState];
						inConverter = NO;
						return [AudioChunk new];
					}
				}
#endif
			}
		}
	}

	if(nativeTargetFormat) {
		inConverter = NO;
		return inChunk;
	}
	
	NSUInteger samplesRead = [inChunk frameCount];
	
	if(!samplesRead) {
		inConverter = NO;
		return [AudioChunk new];
	}
	
	BOOL isFloat = !!(inputFormat.mFormatFlags & kAudioFormatFlagIsFloat);
	BOOL isUnsigned = !isFloat && !(inputFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger);
	size_t bitsPerSample = inputFormat.mBitsPerChannel;
	BOOL isBigEndian = !!(inputFormat.mFormatFlags & kAudioFormatFlagIsBigEndian);
	BOOL isAlignedHigh = !!(inputFormat.mFormatFlags & kAudioFormatFlagIsAlignedHigh);
	const size_t storageBytesPerSample = inputFormat.mBytesPerFrame / inputFormat.mChannelsPerFrame;
	const BOOL outputIsDoP = inputFormat.mBitsPerChannel == 1 &&
	                         outputDSDAsDoP &&
	                         inputFormat.mChannelsPerFrame <= sizeof(dsdDoPPendingFrame);

	double streamTimestamp = [inChunk streamTimestamp];

#if DSD_DECIMATE
	const size_t sizeFactor = 3;
#else
	const size_t sizeFactor = (bitsPerSample == 1) ? 9 : 3;
#endif
	if(floatFormat.mBytesPerPacket > (SIZE_MAX - 64) / sizeFactor ||
	   samplesRead > (SIZE_MAX - 64) / (floatFormat.mBytesPerPacket * sizeFactor)) {
		inConverter = NO;
		return [AudioChunk new];
	}
	size_t newSize = samplesRead * floatFormat.mBytesPerPacket * sizeFactor + 64;
	if(!tempData || tempDataSize < newSize) {
		uint8_t *resizedData = realloc(tempData, newSize);
		if(!resizedData) {
			inConverter = NO;
			return [AudioChunk new];
		}
		tempData = resizedData;
		tempDataSize = newSize;
	}

	// double buffer system, with alignment
	const size_t buffer_adder_base = (samplesRead * floatFormat.mBytesPerPacket + 31) & ~31;

	NSUInteger bytesReadFromInput = samplesRead * inputFormat.mBytesPerPacket;
	NSData *inputData = [inChunk removeSamples:samplesRead];

	uint8_t *inputBuffer = (uint8_t *)[inputData bytes];
	BOOL inputChanged = NO;

	BOOL hdcdSustained = NO;

	if(bytesReadFromInput && isFloat && isBigEndian) {
		// Integer conversion reads either endian directly. Floating-point values
		// need native byte order before Accelerate can consume them.
		memcpy(&tempData[0], [inputData bytes], bytesReadFromInput);
		swap_sample_endianness((uint8_t *)(&tempData[0]), storageBytesPerSample, bytesReadFromInput / storageBytesPerSample);
		inputBuffer = &tempData[0];
		inputChanged = YES;
	}

	if(bytesReadFromInput && isFloat && bitsPerSample == 64 && !toFloat64) {
		const size_t buffer_adder = (inputBuffer == &tempData[0]) ? buffer_adder_base * 2 : 0;
		samplesRead = bytesReadFromInput / sizeof(double);
		convert_f64_to_f32((float *)(&tempData[buffer_adder]), (const double *)inputBuffer, samplesRead);
		bytesReadFromInput = samplesRead * sizeof(float);
		inputBuffer = &tempData[buffer_adder];
		inputChanged = YES;
		bitsPerSample = 32;
	} else if(bytesReadFromInput && isFloat && bitsPerSample == 32 && toFloat64) {
		const size_t buffer_adder = (inputBuffer == &tempData[0]) ? buffer_adder_base : 0;
		samplesRead = bytesReadFromInput / sizeof(float);
		convert_f32_to_f64((double *)(&tempData[buffer_adder]), (const float *)inputBuffer, samplesRead);
		bytesReadFromInput = samplesRead * sizeof(double);
		inputBuffer = &tempData[buffer_adder];
		inputChanged = YES;
		bitsPerSample = 64;
	}

	if(bytesReadFromInput && !isFloat) {
		double gain = 1.0;
		if(bitsPerSample == 1) {
			const size_t buffer_adder = (inputBuffer == &tempData[0]) ? buffer_adder_base : 0;
			samplesRead = bytesReadFromInput / inputFormat.mBytesPerPacket;
			if(outputDSDAsDoP && inputFormat.mChannelsPerFrame <= sizeof(dsdDoPPendingFrame)) {
				samplesRead = convert_dsd_to_dop_s32((int32_t *)(&tempData[buffer_adder]), (const uint8_t *)inputBuffer, samplesRead, inputFormat.mChannelsPerFrame, [inChunk dsdDoPReverseBits], dsdDoPPendingFrame, &dsdDoPHasPendingFrame, &dsdDoPMarker);
				bitsPerSample = 24;
				bytesReadFromInput = samplesRead * floatFormat.mBytesPerPacket;
				isUnsigned = NO;
				inputBuffer = &tempData[buffer_adder];
				inputChanged = YES;
			} else {
				if(toFloat64) {
					convert_dsd_to_f64((double *)(&tempData[buffer_adder]), (const uint8_t *)inputBuffer, samplesRead, inputFormat.mChannelsPerFrame
#if DSD_DECIMATE
							   , dsd2pcm
#endif
					);
				} else {
					convert_dsd_to_f32((float *)(&tempData[buffer_adder]), (const uint8_t *)inputBuffer, samplesRead, inputFormat.mChannelsPerFrame
#if DSD_DECIMATE
							   , dsd2pcm
#endif
					);
				}
#if !DSD_DECIMATE
				samplesRead *= 8;
#endif
				bitsPerSample = toFloat64 ? 64 : 32;
				bytesReadFromInput = samplesRead * floatFormat.mBytesPerPacket;
				isFloat = YES;
				inputBuffer = &tempData[buffer_adder];
				inputChanged = YES;
				[self addObservers];
#if DSD_DECIMATE
			if(halveDSDVolume) {
				if(toFloat64) {
					double scaleFactor = 2.0;
					vDSP_vsdivD((double *)inputBuffer, 1, &scaleFactor, (double *)inputBuffer, 1, bytesReadFromInput / sizeof(double));
				} else {
					float scaleFactor = 2.0f;
					vDSP_vsdiv((float *)inputBuffer, 1, &scaleFactor, (float *)inputBuffer, 1, bytesReadFromInput / sizeof(float));
				}
			}
#else
			if(!halveDSDVolume) {
				if(toFloat64) {
					double scaleFactor = 2.0;
					vDSP_vsmulD((double *)inputBuffer, 1, &scaleFactor, (double *)inputBuffer, 1, bytesReadFromInput / sizeof(double));
				} else {
					float scaleFactor = 2.0f;
					vDSP_vsmul((float *)inputBuffer, 1, &scaleFactor, (float *)inputBuffer, 1, bytesReadFromInput / sizeof(float));
				}
			}
#endif
			}
		} else {
			const uint8_t *integerInput = (const uint8_t *)[inputData bytes];
			samplesRead = bytesReadFromInput / storageBytesPerSample;
			int32_t *integerBuffer = (int32_t *)&tempData[0];

			if(hdcd_decoder) {
				int16_t *hdcdInput = (int16_t *)&tempData[0];
				convert_integer_pcm_to_s16(hdcdInput, integerInput, samplesRead, storageBytesPerSample, bitsPerSample, isBigEndian, isAlignedHigh, isUnsigned);
				int32_t *hdcdOutput = (int32_t *)&tempData[buffer_adder_base];
				convert_s16_to_hdcd_input(hdcdOutput, hdcdInput, samplesRead);
				hdcd_process_stereo((hdcd_state_stereo_t *)hdcd_decoder, hdcdOutput, (int)(samplesRead / 2));
				if(((hdcd_state_stereo_t *)hdcd_decoder)->channel[0].sustain &&
				   ((hdcd_state_stereo_t *)hdcd_decoder)->channel[1].sustain) {
					hdcdSustained = YES;
				}
				if(enableHDCD) {
					gain = 2.0;
					integerBuffer = hdcdOutput;
				} else {
					convert_integer_pcm_to_s32(integerBuffer, integerInput, samplesRead, storageBytesPerSample, bitsPerSample, isBigEndian, isAlignedHigh, isUnsigned);
				}
			} else {
				convert_integer_pcm_to_s32(integerBuffer, integerInput, samplesRead, storageBytesPerSample, bitsPerSample, isBigEndian, isAlignedHigh, isUnsigned);
			}

			bytesReadFromInput = samplesRead * sizeof(int32_t);
			inputBuffer = (uint8_t *)integerBuffer;
			const size_t buffer_adder = (inputBuffer == &tempData[0]) ? buffer_adder_base : 0;
			if(toFloat64) {
				vDSP_vflt32D((const int32_t *)inputBuffer, 1, (double *)(&tempData[buffer_adder]), 1, samplesRead);
				double scale = 2147483648.0 / gain;
				vDSP_vsdivD((const double *)(&tempData[buffer_adder]), 1, &scale, (double *)(&tempData[buffer_adder]), 1, samplesRead);
			} else {
				vDSP_vflt32((const int32_t *)inputBuffer, 1, (float *)(&tempData[buffer_adder]), 1, samplesRead);
				float scale = (float)(2147483648.0 / gain);
				vDSP_vsdiv((const float *)(&tempData[buffer_adder]), 1, &scale, (float *)(&tempData[buffer_adder]), 1, samplesRead);
			}
			bytesReadFromInput = samplesRead * (toFloat64 ? sizeof(double) : sizeof(float));
			inputBuffer = &tempData[buffer_adder];
		}

#ifdef _DEBUG
		if(!outputIsDoP) {
			if(toFloat64) {
				[BadSampleCleaner cleanSamples64:(double *)inputBuffer
									 amount:bytesReadFromInput / sizeof(double)
								   location:@"post int to Float64 conversion"];
			} else {
				[BadSampleCleaner cleanSamples:(float *)inputBuffer
								amount:bytesReadFromInput / sizeof(float)
							  location:@"post int to Float32 conversion"];
			}
		}
#endif
	}

	AudioChunk *outChunk = [AudioChunk new];
	[outChunk setFormat:floatFormat];
	[outChunk setDoP:outputIsDoP];
	[outChunk setChannelConfig:inputChannelConfig];
	[outChunk setLossless:inputLossless];
	[outChunk setStreamTimestamp:streamTimestamp];
	[outChunk setStreamTimeRatio:[inChunk streamTimeRatio]];
	if(hdcdSustained) [outChunk setHDCD];
	if(inChunk.resetForward) {
		outChunk.resetForward = YES;
	}
	
	[outChunk assignSamples:inputBuffer frameCount:bytesReadFromInput / floatFormat.mBytesPerPacket];

	inConverter = NO;
	return outChunk;
}

- (AudioChunk *)convertChunk:(AudioChunk *)inChunk toFloat64:(BOOL)toFloat64 {
	@synchronized(self) {
		return [self convertChunkLocked:inChunk toFloat64:toFloat64];
	}
}

- (BOOL)peekFormat:(AudioStreamBasicDescription *)format channelConfig:(uint32_t *)config {
	if(stopping) return NO;
	inPeeker = YES;
	@synchronized(chunkList) {
		if([chunkList count]) {
			AudioChunk *chunk = [chunkList objectAtIndex:0];
			*format = [chunk format];
			*config = [chunk channelConfig];
			inPeeker = NO;
			return YES;
		}
	}
	inPeeker = NO;
	return NO;
}

- (BOOL)peekTimestamp:(double *)timestamp timeRatio:(double *)timeRatio {
	if(stopping) return NO;
	inPeeker = YES;
	@synchronized (chunkList) {
		if([chunkList count]) {
			AudioChunk *chunk = [chunkList objectAtIndex:0];
			*timestamp = [chunk streamTimestamp];
			*timeRatio = [chunk streamTimeRatio];
			inPeeker = NO;
			return YES;
		}
	}
	*timestamp = 0.0;
	*timeRatio = 1.0;
	inPeeker = NO;
	return NO;
}

@end
