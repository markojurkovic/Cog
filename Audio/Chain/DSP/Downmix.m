//
//  Downmix.m
//  Cog
//
//  Created by Christopher Snowhill on 2/05/22.
//  Copyright 2022 __LoSnoCo__. All rights reserved.
//

#import "Downmix.h"

#import "Logging.h"

#import "AudioChunk.h"

#import <Accelerate/Accelerate.h>

static void downmix_to_stereo(const double *inBuffer, int channels, uint32_t config, double *outBuffer, size_t count) {
	double FrontRatios[2] = { 0.0, 0.0 };
	double FrontCenterRatio = 0.0;
	double LFERatio = 0.0;
	double BackRatios[2] = { 0.0, 0.0 };
	double BackCenterRatio = 0.0;
	double SideRatios[2] = { 0.0, 0.0 };
	if(config & (AudioChannelFrontLeft | AudioChannelFrontRight)) {
		FrontRatios[0] = 1.0;
	}
	if(config & AudioChannelFrontCenter) {
		FrontRatios[0] = 0.5858;
		FrontCenterRatio = 0.4142;
	}
	if(config & (AudioChannelBackLeft | AudioChannelBackRight)) {
		if(config & AudioChannelFrontCenter) {
			FrontRatios[0] = 0.651;
			FrontCenterRatio = 0.46;
			BackRatios[0] = 0.5636;
			BackRatios[1] = 0.3254;
		} else {
			FrontRatios[0] = 0.4226;
			BackRatios[0] = 0.366;
			BackRatios[1] = 0.2114;
		}
	}
	if(config & AudioChannelLFE) {
		FrontRatios[0] *= 0.8;
		FrontCenterRatio *= 0.8;
		LFERatio = FrontCenterRatio;
		BackRatios[0] *= 0.8;
		BackRatios[1] *= 0.8;
	}
	if(config & AudioChannelBackCenter) {
		FrontRatios[0] *= 0.86;
		FrontCenterRatio *= 0.86;
		LFERatio *= 0.86;
		BackRatios[0] *= 0.86;
		BackRatios[1] *= 0.86;
		BackCenterRatio = FrontCenterRatio * 0.86;
	}
	if(config & (AudioChannelSideLeft | AudioChannelSideRight)) {
		double ratio = 0.73;
		if(config & AudioChannelBackCenter) ratio = 0.85;
		FrontRatios[0] *= ratio;
		FrontCenterRatio *= ratio;
		LFERatio *= ratio;
		BackRatios[0] *= ratio;
		BackRatios[1] *= ratio;
		BackCenterRatio *= ratio;
		SideRatios[0] = 0.463882352941176 * ratio;
		SideRatios[1] = 0.267882352941176 * ratio;
	}

	int32_t channelIndexes[channels];
	for(int i = 0; i < channels; ++i) {
		channelIndexes[i] = [AudioChunk findChannelIndex:[AudioChunk extractChannelFlag:i fromConfig:config]];
	}

	vDSP_vclrD(outBuffer, 1, count * 2);

	double tempBuffer[count * 2];

	for(uint32_t i = 0; i < channels; ++i) {
		double leftRatio = 0.0;
		double rightRatio = 0.0;
		switch(channelIndexes[i]) {
			case 0:
				leftRatio = FrontRatios[0];
				rightRatio = FrontRatios[1];
				break;

			case 1:
				leftRatio = FrontRatios[1];
				rightRatio = FrontRatios[0];
				break;

			case 2:
				leftRatio = FrontCenterRatio;
				rightRatio = FrontCenterRatio;
				break;

			case 3:
				leftRatio = LFERatio;
				rightRatio = LFERatio;
				break;

			case 4:
				leftRatio = BackRatios[0];
				rightRatio = BackRatios[1];
				break;

			case 5:
				leftRatio = BackRatios[1];
				rightRatio = BackRatios[0];
				break;

			case 6:
			case 7:
				break;

			case 8:
				leftRatio = BackCenterRatio;
				rightRatio = BackCenterRatio;
				break;

			case 9:
				leftRatio = SideRatios[0];
				rightRatio = SideRatios[1];
				break;

			case 10:
				leftRatio = SideRatios[1];
				rightRatio = SideRatios[0];
				break;

			case 11:
			case 12:
			case 13:
			case 14:
			case 15:
			case 16:
			case 17:
			default:
				break;
		}
		vDSP_vsmulD(inBuffer + i, channels, &leftRatio, tempBuffer, 1, count);
		vDSP_vsmulD(inBuffer + i, channels, &rightRatio, tempBuffer + count, 1, count);
		vDSP_vaddD(outBuffer, 2, tempBuffer, 1, outBuffer, 2, count);
		vDSP_vaddD(outBuffer + 1, 2, tempBuffer + count, 1, outBuffer + 1, 2, count);
	}
}

static void downmix_to_mono(const double *inBuffer, int channels, uint32_t config, double *outBuffer, size_t count) {
	double tempBuffer[count * 2];
	if(channels > 2 || config != AudioConfigStereo) {
		downmix_to_stereo(inBuffer, channels, config, tempBuffer, count);
		inBuffer = tempBuffer;
		// channels = 2;
		// config = AudioConfigStereo;
	}
	cblas_dcopy((int)count, inBuffer, 2, outBuffer, 1);
	vDSP_vaddD(outBuffer, 1, inBuffer + 1, 2, outBuffer, 1, count);
	const double scale = 0.5;
	vDSP_vsmulD(outBuffer, 1, &scale, outBuffer, 1, count);
}

static void upmix(const double *inBuffer, int inchannels, uint32_t inconfig, double *outBuffer, int outchannels, uint32_t outconfig, size_t count) {
	if(inconfig == AudioConfigMono && outconfig == AudioConfigStereo) {
		cblas_dcopy((int)count, inBuffer, 1, outBuffer, 2);
		cblas_dcopy((int)count, inBuffer, 1, outBuffer + 1, 2);
	} else if(inconfig == AudioConfigMono && outconfig == AudioConfig4Point0) {
		cblas_dcopy((int)count, inBuffer, 1, outBuffer, 4);
		cblas_dcopy((int)count, inBuffer, 1, outBuffer + 1, 4);
		vDSP_vclrD(outBuffer + 2, 4, count);
		vDSP_vclrD(outBuffer + 3, 4, count);
	} else if(inconfig == AudioConfigMono && (outconfig & AudioChannelFrontCenter)) {
		uint32_t cIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelFrontCenter];
		cblas_dcopy((int)count, inBuffer, 1, outBuffer + cIndex, outchannels);
		for(size_t i = 0; i < cIndex; ++i) {
			vDSP_vclrD(outBuffer + i, outchannels, (int)count);
		}
		for(size_t i = cIndex + 1; i < outchannels; ++i) {
			vDSP_vclrD(outBuffer + i, outchannels, (int)count);
		}
	} else if(inconfig == AudioConfig4Point0 && outchannels >= 5) {
		uint32_t flIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelFrontLeft];
		uint32_t frIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelFrontRight];
		uint32_t blIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelBackLeft];
		uint32_t brIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelBackRight];
		vDSP_vclrD(outBuffer, 1, count * outchannels);
		if(flIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 0, 4, outBuffer + flIndex, outchannels);
		if(frIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 1, 4, outBuffer + frIndex, outchannels);
		if(blIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 2, 4, outBuffer + blIndex, outchannels);
		if(brIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 3, 4, outBuffer + brIndex, outchannels);
	} else if(inconfig == AudioConfig5Point0 && outchannels >= 6) {
		uint32_t flIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelFrontLeft];
		uint32_t frIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelFrontRight];
		uint32_t cIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelFrontCenter];
		uint32_t blIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelBackLeft];
		uint32_t brIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelBackRight];
		vDSP_vclrD(outBuffer, 1, count * outchannels);
		if(flIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 0, 5, outBuffer + flIndex, outchannels);
		if(frIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 1, 5, outBuffer + frIndex, outchannels);
		if(cIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 2, 5, outBuffer + cIndex, outchannels);
		if(blIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 3, 5, outBuffer + blIndex, outchannels);
		if(brIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 4, 5, outBuffer + brIndex, outchannels);
	} else if(inconfig == AudioConfig6Point1 && outchannels >= 8) {
		uint32_t flIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelFrontLeft];
		uint32_t frIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelFrontRight];
		uint32_t cIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelFrontCenter];
		uint32_t lfeIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelLFE];
		uint32_t blIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelBackLeft];
		uint32_t brIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelBackRight];
		uint32_t bcIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelBackCenter];
		uint32_t slIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelSideLeft];
		uint32_t srIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:AudioChannelSideRight];
		vDSP_vclrD(outBuffer, 1, count * outchannels);
		if(flIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 0, 7, outBuffer + flIndex, outchannels);
		if(frIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 1, 7, outBuffer + frIndex, outchannels);
		if(cIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 2, 7, outBuffer + cIndex, outchannels);
		if(lfeIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 3, 7, outBuffer + lfeIndex, outchannels);
		if(slIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 4, 7, outBuffer + slIndex, outchannels);
		if(srIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 5, 7, outBuffer + srIndex, outchannels);
		if(bcIndex != ~0)
			cblas_dcopy((int)count, inBuffer + 6, 7, outBuffer + bcIndex, outchannels);
		else {
			if(blIndex != ~0)
				cblas_dcopy((int)count, inBuffer + 6, 7, outBuffer + blIndex, outchannels);
			if(brIndex != ~0)
				cblas_dcopy((int)count, inBuffer + 6, 7, outBuffer + brIndex, outchannels);
		}
	} else {
		vDSP_vclrD(outBuffer, 1, count * outchannels);
		for(int i = 0; i < inchannels; ++i) {
			uint32_t channelFlag = [AudioChunk extractChannelFlag:i fromConfig:inconfig];
			uint32_t outIndex = [AudioChunk channelIndexFromConfig:outconfig forFlag:channelFlag];
			if(outIndex != ~0)
				cblas_dcopy((int)count, inBuffer + i, inchannels, outBuffer + outIndex, outchannels);
		}
	}
}

@implementation DownmixProcessor

static void *kDownmixProcessorContext = &kDownmixProcessorContext;

static BOOL isSupportedFloatFormat(AudioStreamBasicDescription format) {
	return AudioFormatIsFloat32(format) || AudioFormatIsFloat64(format);
}

static BOOL resizeDoubleScratch(double **scratch, size_t *capacity, size_t sampleCount) {
	if(*capacity >= sampleCount) return YES;
	if(sampleCount > SIZE_MAX / sizeof(double)) return NO;
	double *newScratch = (double *)realloc(*scratch, sampleCount * sizeof(double));
	if(!newScratch) return NO;
	*scratch = newScratch;
	*capacity = sampleCount;
	return YES;
}

- (id)initWithInputFormat:(AudioStreamBasicDescription)inf inputConfig:(uint32_t)iConfig andOutputFormat:(AudioStreamBasicDescription)outf outputConfig:(uint32_t)oConfig {
	self = [super init];

	if(self) {
		if(!isSupportedFloatFormat(inf))
			return nil;

		if(!isSupportedFloatFormat(outf))
			return nil;

		inputFormat = inf;
		outputFormat = outf;

		inConfig = iConfig;
		outConfig = oConfig;
	}

	return self;
}

- (void)dealloc {
	free(inputScratch);
	free(outputScratch);
}

- (void)process:(const void *)inBuffer frameCount:(size_t)frames output:(void *)outBuffer {
	const size_t inputSampleCount = frames * inputFormat.mChannelsPerFrame;
	const size_t outputSampleCount = frames * outputFormat.mChannelsPerFrame;
	const BOOL inputIsFloat32 = inputFormat.mBitsPerChannel == 32;
	const BOOL outputIsFloat32 = outputFormat.mBitsPerChannel == 32;

	const double *doubleInput = (const double *)inBuffer;
	double *doubleOutput = (double *)outBuffer;
	if(inputIsFloat32) {
		if(!resizeDoubleScratch(&inputScratch, &inputScratchCapacity, inputSampleCount)) {
			bzero(outBuffer, frames * outputFormat.mBytesPerFrame);
			return;
		}
		vDSP_vspdp((const float *)inBuffer, 1, inputScratch, 1, inputSampleCount);
		doubleInput = inputScratch;
	}
	if(outputIsFloat32) {
		if(!resizeDoubleScratch(&outputScratch, &outputScratchCapacity, outputSampleCount)) {
			bzero(outBuffer, frames * outputFormat.mBytesPerFrame);
			return;
		}
		doubleOutput = outputScratch;
	}

	if(inputFormat.mChannelsPerFrame == 2 && outConfig == AudioConfigStereo &&
	   inConfig == (AudioChannelSideLeft | AudioChannelSideRight)) {
		// Workaround for HRTF output
		memcpy(doubleOutput, doubleInput, outputSampleCount * sizeof(double));
	} else if(inputFormat.mChannelsPerFrame > 2 && outConfig == AudioConfigStereo) {
		downmix_to_stereo(doubleInput, inputFormat.mChannelsPerFrame, inConfig, doubleOutput, frames);
	} else if(inputFormat.mChannelsPerFrame > 1 && outConfig == AudioConfigMono) {
		downmix_to_mono(doubleInput, inputFormat.mChannelsPerFrame, inConfig, doubleOutput, frames);
	} else if(inputFormat.mChannelsPerFrame < outputFormat.mChannelsPerFrame) {
		upmix(doubleInput, inputFormat.mChannelsPerFrame, inConfig, doubleOutput, outputFormat.mChannelsPerFrame, outConfig, frames);
	} else if(inConfig == outConfig) {
		memcpy(doubleOutput, doubleInput, outputSampleCount * sizeof(double));
	}

	if(outputIsFloat32) {
		vDSP_vdpsp(doubleOutput, 1, (float *)outBuffer, 1, outputSampleCount);
	}
}

@end
