#import "moviewriter.h"

@implementation MovieWriter {
  dispatch_queue_t _queue;  // owns every field below
  AVAssetWriter *_writer;
  AVAssetWriterInput *_video, *_audio;
  BOOL _started, _finishing;
}

- (instancetype)initWithURL:(NSURL *)url
              videoSettings:(NSDictionary *)videoSettings
              audioSettings:(NSDictionary *)audioSettings
                      error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _url = url;
  _queue = dispatch_queue_create("moviewriter", DISPATCH_QUEUE_SERIAL);
  _writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:error];
  if (!_writer) return nil;
  _video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
  _audio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
  _video.expectsMediaDataInRealTime = YES;
  _audio.expectsMediaDataInRealTime = YES;
  for (AVAssetWriterInput *in in @[ _video, _audio ]) {
    if (![_writer canAddInput:in]) {
      if (error)
        *error = [NSError errorWithDomain:AVFoundationErrorDomain
                                     code:AVErrorUnknown
                                 userInfo:@{NSLocalizedDescriptionKey : @"unsupported recording settings"}];
      return nil;
    }
    [_writer addInput:in];
  }
  if (![_writer startWriting]) {
    if (error) *error = _writer.error;
    return nil;
  }
  return self;
}

- (void)appendVideo:(CMSampleBufferRef)buffer {
  CFRetain(buffer);
  dispatch_async(_queue, ^{
    // The movie starts at the first video frame; audio before it is dropped.
    if (!self->_started && !self->_finishing) {
      [self->_writer startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(buffer)];
      self->_started = YES;
    }
    if (self->_started && !self->_finishing && self->_video.readyForMoreMediaData)
      [self->_video appendSampleBuffer:buffer];
    CFRelease(buffer);
  });
}

- (void)appendAudio:(CMSampleBufferRef)buffer {
  CFRetain(buffer);
  dispatch_async(_queue, ^{
    if (self->_started && !self->_finishing && self->_audio.readyForMoreMediaData)
      [self->_audio appendSampleBuffer:buffer];
    CFRelease(buffer);
  });
}

- (void)finishWithCompletion:(void (^)(NSError *))done {
  dispatch_async(_queue, ^{
    self->_finishing = YES;
    if (!self->_started) {  // nothing was written; don't leave an empty file behind
      [self->_writer cancelWriting];
      NSError *err = [NSError errorWithDomain:AVFoundationErrorDomain
                                         code:AVErrorNoDataCaptured
                                     userInfo:@{NSLocalizedDescriptionKey : @"no video frames arrived"}];
      dispatch_async(dispatch_get_main_queue(), ^{ done(err); });
      return;
    }
    [self->_video markAsFinished];
    [self->_audio markAsFinished];
    [self->_writer finishWritingWithCompletionHandler:^{
      NSError *err = self->_writer.status == AVAssetWriterStatusCompleted ? nil : self->_writer.error;
      dispatch_async(dispatch_get_main_queue(), ^{ done(err); });
    }];
  });
}

@end
