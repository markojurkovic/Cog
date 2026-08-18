//
//  AudioChunk.m
//  CogAudio Framework
//
//  Created by Christopher Snowhill on 2/5/22.
//

#import "AudioChunk.h"

#import "CoreAudioUtils.h"

#include <math.h>

BOOL AudioFormatIsFloat32(AudioStreamBasicDescription format) {
	const AudioFormatFlags layoutFlags = kAudioFormatFlagIsFloat |
	                                     kAudioFormatFlagIsBigEndian |
	                                     kAudioFormatFlagIsSignedInteger |
	                                     kAudioFormatFlagIsPacked |
	                                     kAudioFormatFlagIsAlignedHigh |
	                                     kAudioFormatFlagIsNonInterleaved;
	return format.mFormatID == kAudioFormatLinearPCM &&
	       (format.mFormatFlags & layoutFlags) == kAudioFormatFlagsNativeFloatPacked &&
	       format.mBitsPerChannel == 32 &&
	       format.mFramesPerPacket == 1 &&
	       format.mBytesPerFrame == sizeof(float) * format.mChannelsPerFrame &&
	       format.mBytesPerPacket == format.mBytesPerFrame;
}

BOOL AudioFormatIsFloat64(AudioStreamBasicDescription format) {
	const AudioFormatFlags layoutFlags = kAudioFormatFlagIsFloat |
	                                     kAudioFormatFlagIsBigEndian |
	                                     kAudioFormatFlagIsSignedInteger |
	                                     kAudioFormatFlagIsPacked |
	                                     kAudioFormatFlagIsAlignedHigh |
	                                     kAudioFormatFlagIsNonInterleaved;
	return format.mFormatID == kAudioFormatLinearPCM &&
	       (format.mFormatFlags & layoutFlags) == kAudioFormatFlagsNativeFloatPacked &&
	       format.mBitsPerChannel == 64 &&
	       format.mFramesPerPacket == 1 &&
	       format.mBytesPerFrame == sizeof(double) * format.mChannelsPerFrame &&
	       format.mBytesPerPacket == format.mBytesPerFrame;
}

static BOOL AudioFormatHasSupportedIntegerPCMLayout(AudioStreamBasicDescription format,
                                                    size_t *bytesPerSample) {
	if(format.mFormatID != kAudioFormatLinearPCM ||
	   (format.mFormatFlags & (kAudioFormatFlagIsFloat |
	                           kAudioFormatFlagIsNonInterleaved |
	                           kLinearPCMFormatFlagsSampleFractionMask)) ||
	   format.mBitsPerChannel < 2 || format.mBitsPerChannel > 32 ||
	   !format.mChannelsPerFrame || format.mFramesPerPacket != 1 ||
	   !format.mBytesPerFrame ||
	   format.mBytesPerFrame % format.mChannelsPerFrame ||
	   format.mBytesPerPacket != format.mBytesPerFrame) {
		return NO;
	}

	const size_t storageBytes = format.mBytesPerFrame / format.mChannelsPerFrame;
	if(storageBytes < 1 || storageBytes > sizeof(uint32_t) ||
	   format.mBitsPerChannel > storageBytes * 8) {
		return NO;
	}
	if(bytesPerSample) *bytesPerSample = storageBytes;
	return YES;
}

BOOL AudioFormatIsHighPrecisionPCM(AudioStreamBasicDescription format) {
	if(format.mFormatFlags & kAudioFormatFlagIsFloat) {
		return format.mFormatID == kAudioFormatLinearPCM &&
		       !(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) &&
		       format.mBitsPerChannel == 64 &&
		       format.mChannelsPerFrame > 0 &&
		       format.mFramesPerPacket == 1 &&
		       format.mBytesPerFrame == sizeof(double) * format.mChannelsPerFrame &&
		       format.mBytesPerPacket == format.mBytesPerFrame;
	}
	return AudioFormatHasSupportedIntegerPCMLayout(format, NULL);
}

static uint64_t AudioLoadPCMWord(const uint8_t *input, size_t storageBytes, BOOL bigEndian) {
	uint64_t word = 0;
	if(bigEndian) {
		for(size_t byte = 0; byte < storageBytes; ++byte) {
			word = (word << 8) | input[byte];
		}
	} else {
		for(size_t byte = 0; byte < storageBytes; ++byte) {
			word |= (uint64_t)input[byte] << (byte * 8);
		}
	}
	return word;
}

static int64_t AudioLoadCenteredIntegerSample(const uint8_t *input,
                                              size_t storageBytes,
                                              UInt32 validBits,
                                              AudioFormatFlags flags) {
	const BOOL bigEndian = !!(flags & kAudioFormatFlagIsBigEndian);
	const BOOL alignedHigh = !(flags & kAudioFormatFlagIsPacked) &&
	                         !!(flags & kAudioFormatFlagIsAlignedHigh);
	uint64_t word = AudioLoadPCMWord(input, storageBytes, bigEndian);
	const size_t storageBits = storageBytes * 8;
	if(alignedHigh && validBits < storageBits) {
		word >>= storageBits - validBits;
	}

	const uint64_t validMask = (UINT64_C(1) << validBits) - 1;
	const uint64_t signBit = UINT64_C(1) << (validBits - 1);
	word &= validMask;
	if(flags & kAudioFormatFlagIsSignedInteger) {
		return (int64_t)(word ^ signBit) - (int64_t)signBit;
	}
	return (int64_t)word - (int64_t)signBit;
}

static void AudioStoreCenteredIntegerSample(uint8_t *output,
                                            size_t storageBytes,
                                            UInt32 validBits,
                                            AudioFormatFlags flags,
                                            int64_t centered) {
	const BOOL bigEndian = !!(flags & kAudioFormatFlagIsBigEndian);
	const BOOL alignedHigh = !(flags & kAudioFormatFlagIsPacked) &&
	                         !!(flags & kAudioFormatFlagIsAlignedHigh);
	const size_t storageBits = storageBytes * 8;
	const uint64_t validMask = (UINT64_C(1) << validBits) - 1;
	const uint64_t signBit = UINT64_C(1) << (validBits - 1);
	uint64_t word = (flags & kAudioFormatFlagIsSignedInteger) ?
	                    ((uint64_t)centered & validMask) :
	                    ((uint64_t)(centered + (int64_t)signBit) & validMask);
	if(alignedHigh && validBits < storageBits) {
		word <<= storageBits - validBits;
	}

	for(size_t byte = 0; byte < storageBytes; ++byte) {
		const size_t destinationByte = bigEndian ? storageBytes - byte - 1 : byte;
		output[destinationByte] = (uint8_t)(word >> (byte * 8));
	}
}

BOOL AudioConvertIntegerPCM(void *output,
                            AudioStreamBasicDescription outputFormat,
                            const void *input,
                            AudioStreamBasicDescription inputFormat,
                            size_t sampleCount) {
	size_t inputBytes = 0, outputBytes = 0;
	if(!output || !input ||
	   !AudioFormatHasSupportedIntegerPCMLayout(inputFormat, &inputBytes) ||
	   !AudioFormatHasSupportedIntegerPCMLayout(outputFormat, &outputBytes) ||
	   outputFormat.mBitsPerChannel < inputFormat.mBitsPerChannel) {
		return NO;
	}

	const uint8_t *inputSamples = (const uint8_t *)input;
	uint8_t *outputSamples = (uint8_t *)output;
	const UInt32 precisionShift = outputFormat.mBitsPerChannel - inputFormat.mBitsPerChannel;
	const int64_t precisionScale = INT64_C(1) << precisionShift;
	for(size_t sample = 0; sample < sampleCount; ++sample) {
		const int64_t centered = AudioLoadCenteredIntegerSample(inputSamples + sample * inputBytes,
		                                                            inputBytes,
		                                                            inputFormat.mBitsPerChannel,
		                                                            inputFormat.mFormatFlags);
		AudioStoreCenteredIntegerSample(outputSamples + sample * outputBytes,
		                                outputBytes,
		                                outputFormat.mBitsPerChannel,
		                                outputFormat.mFormatFlags,
		                                centered * precisionScale);
	}
	return YES;
}

BOOL AudioConvertIntegerPCMToFloat64(double *output,
                                     const void *input,
                                     AudioStreamBasicDescription inputFormat,
                                     size_t sampleCount) {
	size_t inputBytes = 0;
	if(!output || !input ||
	   !AudioFormatHasSupportedIntegerPCMLayout(inputFormat, &inputBytes)) {
		return NO;
	}

	const uint8_t *inputSamples = (const uint8_t *)input;
	const double scale = ldexp(1.0, (int)inputFormat.mBitsPerChannel - 1);
	for(size_t sample = 0; sample < sampleCount; ++sample) {
		const int64_t centered = AudioLoadCenteredIntegerSample(inputSamples + sample * inputBytes,
		                                                            inputBytes,
		                                                            inputFormat.mBitsPerChannel,
		                                                            inputFormat.mFormatFlags);
		output[sample] = (double)centered / scale;
	}
	return YES;
}

BOOL AudioFormatIsDoPInteger(AudioStreamBasicDescription format) {
	const AudioFormatFlags nativeEndian = kAudioFormatFlagsNativeEndian & kAudioFormatFlagIsBigEndian;
	return format.mFormatID == kAudioFormatLinearPCM &&
	       !(format.mFormatFlags & kAudioFormatFlagIsFloat) &&
	       !!(format.mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
	       !!(format.mFormatFlags & kAudioFormatFlagIsAlignedHigh) &&
	       !(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) &&
	       (format.mFormatFlags & kAudioFormatFlagIsBigEndian) == nativeEndian &&
	       format.mBitsPerChannel == 24 &&
	       format.mChannelsPerFrame > 0 &&
	       format.mFramesPerPacket == 1 &&
	       format.mBytesPerFrame == sizeof(int32_t) * format.mChannelsPerFrame &&
	       format.mBytesPerPacket == format.mBytesPerFrame;
}

AudioStreamBasicDescription AudioFormatAsFloat32(AudioStreamBasicDescription format) {
	format.mFormatID = kAudioFormatLinearPCM;
	format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
	format.mBitsPerChannel = 32;
	format.mFramesPerPacket = 1;
	format.mBytesPerFrame = (UInt32)(sizeof(float) * format.mChannelsPerFrame);
	format.mBytesPerPacket = format.mBytesPerFrame;
	format.mReserved = 0;
	return format;
}

AudioStreamBasicDescription AudioFormatAsFloat64(AudioStreamBasicDescription format) {
	format.mFormatID = kAudioFormatLinearPCM;
	format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
	format.mBitsPerChannel = 64;
	format.mFramesPerPacket = 1;
	format.mBytesPerFrame = (UInt32)(sizeof(double) * format.mChannelsPerFrame);
	format.mBytesPerPacket = format.mBytesPerFrame;
	format.mReserved = 0;
	return format;
}

AudioStreamBasicDescription AudioFormatAsCanonicalHighPrecisionPCM(AudioStreamBasicDescription format) {
	const BOOL isFloat = !!(format.mFormatFlags & kAudioFormatFlagIsFloat);
	const UInt32 validBits = format.mBitsPerChannel;
	UInt32 storageBytes = sizeof(double);
	if(!isFloat) {
		storageBytes = validBits <= 16 ? sizeof(int16_t) : sizeof(int32_t);
	}
	format.mFormatID = kAudioFormatLinearPCM;
	format.mFormatFlags = isFloat ? kAudioFormatFlagsNativeFloatPacked :
	                                (kAudioFormatFlagIsSignedInteger |
	                                 ((validBits == storageBytes * 8) ? kAudioFormatFlagIsPacked :
	                                                                     kAudioFormatFlagIsAlignedHigh) |
	                                 kAudioFormatFlagsNativeEndian);
	format.mBitsPerChannel = isFloat ? 64 : validBits;
	format.mFramesPerPacket = 1;
	format.mBytesPerFrame = (UInt32)(storageBytes * format.mChannelsPerFrame);
	format.mBytesPerPacket = format.mBytesPerFrame;
	format.mReserved = 0;
	return format;
}

AudioStreamBasicDescription AudioFormatAsDoPInteger(AudioStreamBasicDescription format) {
	format.mFormatID = kAudioFormatLinearPCM;
	format.mFormatFlags = kAudioFormatFlagIsSignedInteger |
	                      kAudioFormatFlagIsAlignedHigh |
	                      kAudioFormatFlagsNativeEndian;
	format.mBitsPerChannel = 24;
	format.mFramesPerPacket = 1;
	format.mBytesPerFrame = (UInt32)(sizeof(int32_t) * format.mChannelsPerFrame);
	format.mBytesPerPacket = format.mBytesPerFrame;
	format.mReserved = 0;
	return format;
}

@implementation AudioChunk

- (id)init {
	self = [super init];

	if(self) {
		chunkData = [NSMutableData new];
		formatAssigned = NO;
		lossless = NO;
		hdcd = NO;
		resetForward = NO;
		dsdDoPReverseBits = NO;
		doP = NO;
		streamTimestamp = 0.0;
		streamTimeRatio = 1.0;
	}

	return self;
}

- (id)initWithProperties:(NSDictionary *)properties {
	self = [super init];

	if(self) {
		chunkData = [NSMutableData new];
		[self setFormat:propertiesToASBD(properties)];
		lossless = [[properties objectForKey:@"encoding"] isEqualToString:@"lossless"];
		hdcd = NO;
		resetForward = NO;
		dsdDoPReverseBits = [[properties objectForKey:@"dsdDoPReverseBits"] boolValue];
		doP = NO;
		streamTimestamp = 0.0;
		streamTimeRatio = 1.0;
	}

	return self;
}

- (AudioChunk *)copy {
	AudioChunk *outputChunk = [AudioChunk new];
	[outputChunk setFormat:format];
	[outputChunk setChannelConfig:channelConfig];
	[outputChunk setLossless:lossless];
	if(hdcd) [outputChunk setHDCD];
	if(resetForward) outputChunk.resetForward = YES;
	outputChunk.dsdDoPReverseBits = dsdDoPReverseBits;
	outputChunk.doP = doP;
	[outputChunk setStreamTimestamp:streamTimestamp];
	[outputChunk setStreamTimeRatio:streamTimeRatio];
	[outputChunk assignData:chunkData];
	return outputChunk;
}

static const uint32_t AudioChannelConfigTable[] = {
	0,
	AudioConfigMono,
	AudioConfigStereo,
	AudioConfig3Point0,
	AudioConfig4Point0,
	AudioConfig5Point0,
	AudioConfig5Point1,
	AudioConfig6Point1,
	AudioConfig7Point1,
	0,
	AudioConfig7Point1 | AudioChannelFrontCenterLeft | AudioChannelFrontCenterRight
};

+ (uint32_t)guessChannelConfig:(uint32_t)channelCount {
	if(channelCount == 0) return 0;
	if(channelCount > 32) return 0;
	int ret = 0;
	if(channelCount < (sizeof(AudioChannelConfigTable) / sizeof(AudioChannelConfigTable[0])))
		ret = AudioChannelConfigTable[channelCount];
	if(!ret) {
		ret = (1 << channelCount) - 1;
	}
	assert([AudioChunk countChannels:ret] == channelCount);
	return ret;
}

+ (uint32_t)channelIndexFromConfig:(uint32_t)channelConfig forFlag:(uint32_t)flag {
	uint32_t index = 0;
	for(uint32_t walk = 0; walk < 32; ++walk) {
		uint32_t query = 1 << walk;
		if(flag & query) return index;
		if(channelConfig & query) ++index;
	}
	return ~0;
}

+ (uint32_t)extractChannelFlag:(uint32_t)index fromConfig:(uint32_t)channelConfig {
	uint32_t toskip = index;
	uint32_t flag = 1;
	while(flag) {
		if(channelConfig & flag) {
			if(toskip == 0) break;
			toskip--;
		}
		flag <<= 1;
	}
	return flag;
}

+ (uint32_t)countChannels:(uint32_t)channelConfig {
	return __builtin_popcount(channelConfig);
}

+ (uint32_t)findChannelIndex:(uint32_t)flag {
	uint32_t rv = 0;
	if((flag & 0xFFFF) == 0) {
		rv += 16;
		flag >>= 16;
	}
	if((flag & 0xFF) == 0) {
		rv += 8;
		flag >>= 8;
	}
	if((flag & 0xF) == 0) {
		rv += 4;
		flag >>= 4;
	}
	if((flag & 0x3) == 0) {
		rv += 2;
		flag >>= 2;
	}
	if((flag & 0x1) == 0) {
		rv += 1;
		flag >>= 1;
	}
	assert(flag & 1);
	return rv;
}

@synthesize lossless;
@synthesize resetForward;
@synthesize streamTimestamp;
@synthesize streamTimeRatio;
@synthesize dsdDoPReverseBits;
@synthesize doP;

- (AudioStreamBasicDescription)format {
	return format;
}

- (void)setFormat:(AudioStreamBasicDescription)informat {
	formatAssigned = YES;
	format = informat;
	channelConfig = [AudioChunk guessChannelConfig:format.mChannelsPerFrame];
}

- (uint32_t)channelConfig {
	return channelConfig;
}

- (void)setChannelConfig:(uint32_t)config {
	if(formatAssigned) {
		if(config == 0) {
			config = [AudioChunk guessChannelConfig:format.mChannelsPerFrame];
		}
	}
	channelConfig = config;
}

- (void)assignSamples:(const void *_Nonnull)data frameCount:(size_t)count {
	if(formatAssigned) {
		const size_t bytesPerPacket = format.mBytesPerPacket;
		[chunkData appendBytes:data length:bytesPerPacket * count];
	}
}

- (void)assignData:(NSData *)data {
	[chunkData appendData:data];
}

- (NSData *)removeSamples:(size_t)frameCount {
	if(formatAssigned) {
		@autoreleasepool {
			const double secondsDuration = (double)(frameCount) / format.mSampleRate;
			const double DSDrate = (format.mBitsPerChannel == 1) ? 8.0 : 1.0;
			const size_t bytesPerPacket = format.mBytesPerPacket;
			const size_t byteCount = bytesPerPacket * frameCount;
			NSData *ret = [chunkData subdataWithRange:NSMakeRange(0, byteCount)];
			[chunkData replaceBytesInRange:NSMakeRange(0, byteCount) withBytes:NULL length:0];
			streamTimestamp += secondsDuration * streamTimeRatio * DSDrate;
			return ret;
		}
	}
	return [NSData data];
}

- (BOOL)isEmpty {
	return [chunkData length] == 0;
}

- (size_t)frameCount {
	if(formatAssigned) {
		const size_t bytesPerPacket = format.mBytesPerPacket;
		return [chunkData length] / bytesPerPacket;
	}
	return 0;
}

- (void)setFrameCount:(size_t)count {
	if(formatAssigned) {
		count *= format.mBytesPerPacket;
		size_t currentLength = [chunkData length];
		if(count < currentLength) {
			[chunkData replaceBytesInRange:NSMakeRange(count, currentLength - count) withBytes:NULL length:0];
		}
	}
}

- (double)duration {
	if(formatAssigned && [chunkData length]) {
		const size_t bytesPerPacket = format.mBytesPerPacket;
		const double sampleRate = format.mSampleRate;
		const double DSDrate = (format.mBitsPerChannel == 1) ? 8.0 : 1.0;
		return ((double)([chunkData length] / bytesPerPacket) / sampleRate) * DSDrate;
	}
	return 0.0;
}

- (double)durationRatioed {
	return [self duration] * streamTimeRatio;
}

- (BOOL)isHDCD {
	return hdcd;
}

- (void)setHDCD {
	hdcd = YES;
}

@end
