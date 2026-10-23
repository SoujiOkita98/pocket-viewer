// echocancel — experimental echo cancellation via macOS voice processing.
//
// Captures one input device through AVAudioEngine with voice processing on
// (echo cancellation, noise suppression), optionally monitors it to an output
// device, and hands out the processed audio as CMSampleBuffers stamped on the
// host clock so they can be muxed with camera frames.
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EchoCanceller : NSObject

// inputUID/outputUID are CoreAudio device UIDs; a nil outputUID means the
// system default output. Echo of anything played on that output is removed.
- (BOOL)startWithInputUID:(NSString *)inputUID
                outputUID:(nullable NSString *)outputUID
               monitoring:(BOOL)monitoring
                    error:(NSError **)error;
- (void)stop;

@property(nonatomic) BOOL monitoring;     // play the processed input on the output device
@property(readonly) float levelDB;        // recent peak of the processed input
// Called on an audio thread with each processed buffer.
@property(nonatomic, copy, nullable) void (^onAudio)(CMSampleBufferRef buffer);

@end

NS_ASSUME_NONNULL_END
