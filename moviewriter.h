// moviewriter — records camera frames plus an external audio stream (e.g. the
// echo-cancelled one) into a QuickTime movie. Both streams must be stamped on
// the host clock. Thread-safe: append from any thread.
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MovieWriter : NSObject

- (nullable instancetype)initWithURL:(NSURL *)url
                       videoSettings:(NSDictionary *)videoSettings
                       audioSettings:(NSDictionary *)audioSettings
                               error:(NSError **)error;
- (void)appendVideo:(CMSampleBufferRef)buffer;
- (void)appendAudio:(CMSampleBufferRef)buffer;
// Calls done on the main queue; error is nil on success.
- (void)finishWithCompletion:(void (^)(NSError *_Nullable error))done;

@property(readonly) NSURL *url;

@end

NS_ASSUME_NONNULL_END
