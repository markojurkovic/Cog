//
//  FadedBuffer.h
//  CogAudio
//
//  Created by Christopher Snowhill on 8/17/25.
//

#import <Cocoa/Cocoa.h>

#import "ChunkList.h"

#import "Node.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

extern double fadeTimeMS;

extern BOOL fadeAudio(const float *inSamples, float *outSamples, size_t channels, size_t count, float *fadeLevel, float fadeStep, float fadeTarget);
extern BOOL fadeAudio64(const double *inSamples, double *outSamples, size_t channels, size_t count, double *fadeLevel, double fadeStep, double fadeTarget);
extern BOOL audioBufferIsDoP(const void *samples, AudioStreamBasicDescription format, size_t count, uint8_t * _Nullable nextMarker);
extern BOOL fillDoPSilence(void *samples, AudioStreamBasicDescription format, size_t count, uint8_t *nextMarker);

#ifdef __cplusplus
}
#endif

@interface FadedBuffer : Node

- (id)initWithBuffer:(ChunkList *)buffer withDSPs:(NSArray *)DSPs fadeStart:(double)fadeStart fadeTarget:(double)fadeTarget sampleRate:(double)sampleRate;
- (BOOL)mix:(double *)outputBuffer sampleCount:(size_t)samples channelCount:(size_t)channels;

@end

NS_ASSUME_NONNULL_END
