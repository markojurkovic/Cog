//
//  OutputCoreAudio.h
//  Cog
//
//  Created by Christopher Snowhill on 7/25/23.
//  Copyright 2023-2024 Christopher Snowhill. All rights reserved.
//

#import <AssertMacros.h>
#import <Cocoa/Cocoa.h>

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/CoreAudioTypes.h>

#ifdef __cplusplus
#import <atomic>
using std::atomic_long;
#else
#import <stdatomic.h>
#endif

#import <simd/simd.h>

#import <CogAudio/ChunkList.h>

#import <CogAudio/Node.h>

#import <CogAudio/DSPFaderNode.h>
#import <CogAudio/DSPDownmixNode.h>
#import <CogAudio/DSPHRTFNode.h>

#import <CogAudio/SimpleBuffer.h>

//#define OUTPUT_LOG

@class OutputNode;

@class AudioChunk;

@interface OutputCoreAudio : Node {
	OutputNode *outputController;

	NSLock *outputLock;

	double streamTimestamp;

	BOOL stopInvoked;
	BOOL stopCompleted;
	BOOL running;
	BOOL stopping;
	BOOL stopped;
	BOOL started;
	BOOL paused;
	BOOL restarted;
	BOOL commandStop;
	BOOL resetting;

	BOOL cutOffInput;
	BOOL fading, faded, fadingstop;
	BOOL doPActive;
	BOOL doPSeekPending;
	uint8_t doPMarker;
	double fadeLevel;
	double fadeStep;
	double fadeTarget;

	BOOL prebufferReached;
	BOOL prebufferSignaled;

	BOOL eqEnabled;
	BOOL eqInitialized;

	BOOL streamFormatStarted;
	BOOL streamFormatChanged;

	double secondsHdcdSustained;

	BOOL defaultdevicelistenerapplied;
	BOOL currentdevicelistenerapplied;
	BOOL devicealivelistenerapplied;
	BOOL observersapplied;
	BOOL outputdevicechanged;

	BOOL suspendOutputOnPause;
	BOOL exclusiveOutputEnabled;

	double volume;

	AVAudioFormat *_deviceFormat;

	AudioDeviceID outputDeviceID;
	NSMutableDictionary<NSNumber *, NSNumber *> *sampleRateSupportCache;
	AudioStreamBasicDescription deviceFormat;
	AudioStreamBasicDescription renderFormat;
	AudioStreamBasicDescription sourceFormat;
	AudioStreamBasicDescription realStreamFormat; // stream format pre-hrtf
	AudioStreamBasicDescription streamFormat; // stream format last seen in render callback

	uint32_t deviceChannelConfig;
	uint32_t sourceChannelConfig;
	uint32_t realStreamChannelConfig;
	uint32_t streamChannelConfig;
	BOOL sourceFormatValid;

	BOOL preferDoPIntegerOutput;
	BOOL renderFormatDoPInteger;
	double preferredDoPCarrierSampleRate;
	BOOL preferNativeHighPrecisionOutput;
	BOOL renderFormatNativeHighPrecision;
	AudioStreamBasicDescription preferredNativeHighPrecisionFormat;
	BOOL preferIntegerPhysicalOutput;
	BOOL renderFormatIntegerPhysical;
	NSDictionary<NSNumber *, NSValue *> *preferredIntegerPhysicalFormats;
	BOOL preferExclusiveIntegerTransport;
	BOOL renderFormatEndToEndInteger;
	BOOL preferredIntegerTransportRequiresHog;
	NSDictionary<NSNumber *, NSValue *> *preferredIntegerVirtualFormats;
	AudioStreamBasicDescription preferredIntegerClientFormat;
	BOOL preferExclusiveFloatTransport;
	NSDictionary<NSNumber *, NSValue *> *preferredFloatVirtualFormats;
	AudioStreamBasicDescription preferredFloatClientFormat;
	BOOL savedPhysicalFormatValid;
	AudioDeviceID savedPhysicalFormatDeviceID;
	NSDictionary<NSNumber *, NSValue *> *savedPhysicalFormats;
	BOOL savedVirtualFormatValid;
	AudioDeviceID savedVirtualFormatDeviceID;
	NSDictionary<NSNumber *, NSValue *> *savedVirtualFormats;
	BOOL hogModeOwned;
	AudioDeviceID hogModeDeviceID;
	AudioDeviceIOProcID exclusiveIOProcID;
	AudioDeviceID exclusiveIOProcDeviceID;
	BOOL exclusiveIOProcRunning;
	UInt32 exclusiveMaximumFramesToRender;

	double *outputDoubleScratch;
	double *inputDoubleScratch;
	size_t outputDoubleScratchCapacity;

	AUAudioUnit *_au;
	AURenderPullInputBlock _outputRenderBlock;

	size_t _bufferSize;

	BOOL resetStreamFormat;
	
	BOOL shouldPlayOutBuffer;

	BOOL DSPsLaunched;
	DSPHRTFNode *hrtfNode;
	DSPDownmixNode *downmixNode;
	DSPFaderNode *faderNode;

	SimpleBuffer *bufferNode;

	NSTimer *idleTimer;

#ifdef OUTPUT_LOG
	NSFileHandle *_logFile;
#endif
}

- (id)initWithController:(OutputNode *)c;

- (BOOL)setup;
- (OSStatus)setOutputDeviceByID:(int)deviceID;
- (BOOL)setOutputDeviceWithDeviceDict:(NSDictionary *)deviceDict;
- (void)start;
- (void)pause;
- (void)resume;
- (void)stop;
- (BOOL)beginStreamReplacement;
- (void)finishStreamReplacement;

- (void)fadeOut;
- (void)fadeOutBackground;
- (void)beginSeek;
- (void)fadeIn;
- (void)faderFadeIn;

- (void)timeOut;

- (double)latency;

- (double)volume;
- (void)setVolume:(double)v;

- (void)setShouldPlayOutBuffer:(BOOL)enabled;

- (void)sustainHDCD;

- (AudioStreamBasicDescription)deviceFormat;
- (uint32_t)deviceChannelConfig;
- (AudioStreamBasicDescription)outputFormatForInputFormat:(AudioStreamBasicDescription)inputFormat;
- (BOOL)prepareForInputFormat:(AudioStreamBasicDescription)inputFormat;
- (void)refreshOutputStatus;

- (DSPDownmixNode *)downmix;
- (DSPFaderNode *)fader;

@end
