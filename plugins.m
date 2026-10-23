#import "plugins.h"

#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include <poll.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

static const uint32_t kMaxHeader = 1 << 20;     // 1 MB of JSON is plenty
static const uint32_t kMaxPayload = 64 << 20;   // plugins rarely send payloads
static const int kWriteTimeoutMs = 3000;        // a client stuck this long is dropped
static const int kMaxAudioInFlight = 64;

// Plugin input is untrusted: JSON null arrives as NSNull, numbers as strings,
// and so on. Anything of the wrong type reads as absent.
static NSDictionary *specFrom(id v) {
  if ([v isKindOfClass:NSDictionary.class]) return v;
  if ([v isKindOfClass:NSNumber.class] && [v boolValue]) return @{};
  return nil;
}

static double numberIn(NSDictionary *d, NSString *key, double fallback) {
  id v = d[key];
  return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : fallback;
}

#pragma mark - Client

@interface PluginClient ()
@property(readwrite) int clientID;
@property(readwrite, copy) NSString *name;
@property(readwrite, nullable) NSTask *task;
// Subscriptions: written on the main thread, read from the push threads.
@property(atomic, copy, nullable) NSDictionary *videoSpec, *audioSpec;
@property(atomic) BOOL wantsState, wantsInput;
// Audio conversion state, used only on the server's audio queue.
@property(nonatomic, nullable) AVAudioConverter *converter;
@end

@implementation PluginClient {
 @public
  int _fd;
  dispatch_queue_t _writeQueue;
  dispatch_source_t _readSource;
  NSMutableData *_inbox;
  _Atomic bool _videoBusy;
  _Atomic int _audioInFlight;
  _Atomic bool _dead;
  double _lastVideo;  // CACurrentMediaTime of the last frame sent; video queue only
}

static BOOL writeAll(int fd, const uint8_t *p, size_t n) {
  while (n) {
    ssize_t w = send(fd, p, n, 0);
    if (w > 0) {
      p += w;
      n -= w;
    } else if (w < 0 && errno == EINTR) {
      continue;
    } else if (w < 0 && errno == EAGAIN) {
      struct pollfd pfd = {.fd = fd, .events = POLLOUT};
      if (poll(&pfd, 1, kWriteTimeoutMs) <= 0) return NO;
    } else {
      return NO;
    }
  }
  return YES;
}

// Frames each message as: u32 big-endian header length, JSON header, payload.
- (void)send:(NSDictionary *)header payload:(nullable NSData *)payload done:(nullable void (^)(void))done {
  if (_dead) {
    if (done) done();
    return;
  }
  NSMutableDictionary *h = [header mutableCopy];
  if (payload) h[@"size"] = @(payload.length);
  NSData *json = [NSJSONSerialization dataWithJSONObject:h options:0 error:nil];
  dispatch_async(_writeQueue, ^{
    uint32_t len = htonl((uint32_t)json.length);
    BOOL ok = !self->_dead && writeAll(self->_fd, (const uint8_t *)&len, 4) &&
              writeAll(self->_fd, json.bytes, json.length) &&
              (!payload || writeAll(self->_fd, payload.bytes, payload.length));
    if (!ok && !atomic_exchange(&self->_dead, true)) {
      // Unblock and end the read side; its cancel handler cleans up.
      shutdown(self->_fd, SHUT_RDWR);
    }
    if (done) done();
  });
}

@end

#pragma mark - Server

@implementation PluginServer {
  __weak id<PluginServerDelegate> _delegate;
  int _listenFD;
  dispatch_source_t _listenSource;
  dispatch_queue_t _ioQueue, _videoQueue, _audioQueue;
  NSMutableArray<PluginClient *> *_clients;          // main thread
  NSMutableDictionary<NSString *, NSTask *> *_pending;  // token -> task, main thread
  NSMutableDictionary<NSString *, NSTask *> *_launched; // token -> task once connected
  NSMapTable<NSTask *, NSString *> *_taskNames;
  NSArray<PluginClient *> *_snapshot;                 // atomic copy for push threads
  int _nextID;
  CIContext *_ci;
  CGColorSpaceRef _srgb;
  _Atomic bool _converting;
}

- (instancetype)initWithSocketPath:(NSString *)path delegate:(id<PluginServerDelegate>)delegate {
  if ((self = [super init])) {
    _socketPath = [path copy];
    _delegate = delegate;
    _listenFD = -1;
    _ioQueue = dispatch_queue_create("plugins.io", DISPATCH_QUEUE_SERIAL);
    _videoQueue = dispatch_queue_create("plugins.video", DISPATCH_QUEUE_SERIAL);
    _audioQueue = dispatch_queue_create("plugins.audio", DISPATCH_QUEUE_SERIAL);
    _clients = [NSMutableArray array];
    _pending = [NSMutableDictionary dictionary];
    _launched = [NSMutableDictionary dictionary];
    _taskNames = [NSMapTable strongToStrongObjectsMapTable];
    _snapshot = @[];
    _ci = [CIContext contextWithOptions:nil];
    _srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  }
  return self;
}

- (void)dealloc {
  CGColorSpaceRelease(_srgb);
}

- (BOOL)start:(NSError **)error {
  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  if (_socketPath.length >= sizeof addr.sun_path) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENAMETOOLONG userInfo:nil];
    return NO;
  }
  strlcpy(addr.sun_path, _socketPath.fileSystemRepresentation, sizeof addr.sun_path);
  unlink(addr.sun_path);  // stale socket from a previous run

  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  // Owner-only: any process of this user can connect, nobody else.
  mode_t old = umask(077);
  BOOL ok = fd >= 0 && bind(fd, (struct sockaddr *)&addr, sizeof addr) == 0 && listen(fd, 16) == 0;
  umask(old);
  if (!ok) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    if (fd >= 0) close(fd);
    return NO;
  }
  _listenFD = fd;
  _listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _ioQueue);
  __weak PluginServer *weakSelf = self;
  dispatch_source_set_event_handler(_listenSource, ^{
    int cfd = accept(fd, NULL, NULL);
    if (cfd >= 0) dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf addClientFD:cfd]; });
  });
  dispatch_resume(_listenSource);
  return YES;
}

- (NSArray<PluginClient *> *)clients {
  return [_clients copy];
}

- (NSArray<NSTask *> *)pendingTasks {
  return _pending.allValues;
}

- (void)publishClients {
  @synchronized(self) {
    _snapshot = [_clients copy];
  }
  [_delegate pluginClientsChanged];
}

- (NSArray<PluginClient *> *)snapshot {
  @synchronized(self) {
    return _snapshot;
  }
}

#pragma mark Connections

- (void)addClientFD:(int)fd {
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  int sndbuf = 4 << 20;  // room for a few raw frames
  setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof sndbuf);
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);

  PluginClient *c = [PluginClient new];
  c.clientID = ++_nextID;
  c.name = [NSString stringWithFormat:@"client %d", c.clientID];
  c->_fd = fd;
  c->_writeQueue = dispatch_queue_create("plugins.write", DISPATCH_QUEUE_SERIAL);
  c->_inbox = [NSMutableData data];
  c->_readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _ioQueue);
  __weak PluginServer *weakSelf = self;
  __weak PluginClient *weakClient = c;
  dispatch_source_set_event_handler(c->_readSource, ^{
    PluginClient *client = weakClient;
    if (client) [weakSelf readFrom:client];
  });
  dispatch_source_set_cancel_handler(c->_readSource, ^{
    // Close only after pending writes have drained or failed.
    dispatch_async(c->_writeQueue, ^{ close(fd); });
  });
  dispatch_resume(c->_readSource);
  [_clients addObject:c];
  [self publishClients];

  NSMutableDictionary *hello = [@{@"type" : @"hello", @"protocol" : @1, @"clientID" : @(c.clientID)} mutableCopy];
  [hello addEntriesFromDictionary:[_delegate pluginHelloInfo]];
  [c send:hello payload:nil done:nil];
}

// io queue
- (void)readFrom:(PluginClient *)c {
  uint8_t buf[65536];
  for (;;) {
    ssize_t n = read(c->_fd, buf, sizeof buf);
    if (n > 0) {
      [c->_inbox appendBytes:buf length:n];
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && errno == EAGAIN) break;
    [self disconnect:c];  // EOF or error
    return;
  }
  // Parse every complete message in the inbox.
  for (;;) {
    NSData *in = c->_inbox;
    if (in.length < 4) break;
    uint32_t hlen = ntohl(*(const uint32_t *)in.bytes);
    if (hlen == 0 || hlen > kMaxHeader) return [self disconnect:c];
    if (in.length < 4 + hlen) break;
    NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:[in subdataWithRange:NSMakeRange(4, hlen)]
                                                        options:0
                                                          error:nil];
    if (![msg isKindOfClass:NSDictionary.class]) return [self disconnect:c];
    NSUInteger size = [msg[@"size"] isKindOfClass:NSNumber.class] ? [msg[@"size"] unsignedIntegerValue] : 0;
    if (size > kMaxPayload) return [self disconnect:c];
    if (in.length < 4 + hlen + size) break;
    NSData *payload = size ? [in subdataWithRange:NSMakeRange(4 + hlen, size)] : nil;
    [c->_inbox replaceBytesInRange:NSMakeRange(0, 4 + hlen + size) withBytes:NULL length:0];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self handle:msg payload:payload from:c];
    });
  }
}

// io queue
- (void)disconnect:(PluginClient *)c {
  if (!c->_readSource) return;
  atomic_store(&c->_dead, true);
  dispatch_source_cancel(c->_readSource);
  c->_readSource = nil;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self->_clients removeObject:c];
    NSLog(@"plugin disconnected: %@", c.name);
    [self publishClients];
  });
}

// main thread
- (void)handle:(NSDictionary *)msg payload:(NSData *)payload from:(PluginClient *)c {
  if (![_clients containsObject:c]) return;
  NSString *type = msg[@"type"];
  if ([type isEqual:@"hello"]) {
    if ([msg[@"name"] isKindOfClass:NSString.class]) c.name = msg[@"name"];
    NSString *token = [msg[@"token"] isKindOfClass:NSString.class] ? msg[@"token"] : @"";
    NSTask *task = _pending[token] ?: _launched[token];
    if (task) {
      c.task = task;
      // Remember it: a plugin that re-execs itself (to apply settings)
      // reconnects with the same token and is still ours.
      _launched[token] = task;
      [_pending removeObjectForKey:token];
    }
    NSLog(@"plugin connected: %@", c.name);
    [self publishClients];
  } else if ([type isEqual:@"subscribe"]) {
    c.videoSpec = specFrom(msg[@"video"]);
    c.audioSpec = specFrom(msg[@"audio"]);
    c.wantsState = specFrom(msg[@"state"]) != nil;
    c.wantsInput = specFrom(msg[@"input"]) != nil;
    dispatch_async(_audioQueue, ^{ c.converter = nil; });  // spec may have changed
  } else {
    [_delegate pluginClient:c sent:msg];
  }
}

#pragma mark Launching

- (void)launch:(NSString *)command {
  NSString *token = NSUUID.UUID.UUIDString;
  NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
  env[@"POCKET_VIEWER_SOCKET"] = _socketPath;
  env[@"POCKET_VIEWER_TOKEN"] = token;
  NSTask *task = [NSTask new];
  task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
  task.arguments = @[ @"-c", command ];
  task.environment = env;
  __weak PluginServer *weakSelf = self;
  task.terminationHandler = ^(NSTask *t) {
    dispatch_async(dispatch_get_main_queue(), ^{
      PluginServer *s = weakSelf;
      if (!s) return;
      NSLog(@"plugin exited (%d): %@", t.terminationStatus, [s->_taskNames objectForKey:t]);
      [s->_pending removeObjectForKey:token];
      [s->_launched removeObjectForKey:token];
      [s->_taskNames removeObjectForKey:t];
      [s publishClients];
    });
  };
  NSError *err;
  if (![task launchAndReturnError:&err]) {
    NSLog(@"cannot launch plugin %@: %@", command, err.localizedDescription);
    return;
  }
  NSLog(@"launched plugin: %@", command);
  _pending[token] = task;
  [_taskNames setObject:command forKey:task];
  [self publishClients];
}

- (NSString *)nameOfTask:(NSTask *)task {
  return [_taskNames objectForKey:task] ?: @"plugin";
}

- (void)stopTask:(NSTask *)task {
  if (task.isRunning) [task terminate];
}

- (void)shutdown {
  for (PluginClient *c in _clients) [self stopTask:c.task];
  for (NSTask *t in _pending.allValues) [self stopTask:t];
  if (_listenSource) dispatch_source_cancel(_listenSource);
  if (_listenFD >= 0) close(_listenFD);
  unlink(_socketPath.fileSystemRepresentation);
}

- (void)stopClient:(PluginClient *)client {
  [self stopTask:client.task];
  dispatch_async(_ioQueue, ^{ [self disconnect:client]; });
}

#pragma mark Fan-out

- (void)pushVideo:(CMSampleBufferRef)buffer {
  double now = CACurrentMediaTime();
  NSMutableArray<PluginClient *> *due = [NSMutableArray array];
  for (PluginClient *c in self.snapshot) {
    NSDictionary *spec = c.videoSpec;
    if (!spec || c->_videoBusy) continue;
    double fps = numberIn(spec, @"fps", 15);
    if (fps <= 0) fps = 15;
    if (now - c->_lastVideo >= 0.9 / fps) [due addObject:c];
  }
  if (!due.count || atomic_exchange(&_converting, true)) return;  // one conversion at a time
  CFRetain(buffer);
  dispatch_async(_videoQueue, ^{
    [self convertVideo:buffer for:due];
    CFRelease(buffer);
    atomic_store(&self->_converting, false);
  });
}

// video queue
- (void)convertVideo:(CMSampleBufferRef)buffer for:(NSArray<PluginClient *> *)clients {
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(buffer);
  if (!pb) return;
  CIImage *image = [CIImage imageWithCVPixelBuffer:pb];
  double srcW = CVPixelBufferGetWidth(pb), srcH = CVPixelBufferGetHeight(pb);
  double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer));
  NSMutableDictionary<NSString *, NSData *> *cache = [NSMutableDictionary dictionary];

  for (PluginClient *c in clients) {
    NSDictionary *spec = c.videoSpec;
    NSString *format = [spec[@"format"] isEqual:@"jpeg"] ? @"jpeg" : @"bgra";
    int w = (int)MIN(srcW, MAX(16, numberIn(spec, @"maxWidth", 640)));
    int h = (int)lround(srcH * w / srcW);
    double quality = MIN(1, MAX(0.1, numberIn(spec, @"quality", 0.7)));
    NSString *key = [NSString stringWithFormat:@"%@ %d %.2f", format, w, quality];
    NSData *data = cache[key];
    if (!data) {
      CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(w / srcW, h / srcH)];
      if ([format isEqual:@"jpeg"]) {
        data = [_ci JPEGRepresentationOfImage:scaled
                                   colorSpace:_srgb
                                      options:@{(id)kCGImageDestinationLossyCompressionQuality : @(quality)}];
      } else {
        NSMutableData *bgra = [NSMutableData dataWithLength:(NSUInteger)w * h * 4];
        // render:toBitmap: writes the top row first (verified against the JPEG path).
        [_ci render:scaled
              toBitmap:bgra.mutableBytes
              rowBytes:w * 4
                bounds:CGRectMake(0, 0, w, h)
                format:kCIFormatBGRA8
            colorSpace:_srgb];
        data = bgra;
      }
      if (!data) continue;
      cache[key] = data;
    }
    atomic_store(&c->_videoBusy, true);
    c->_lastVideo = CACurrentMediaTime();
    [c send:@{@"type" : @"video", @"pts" : @(pts), @"width" : @(w), @"height" : @(h), @"format" : format}
        payload:data
           done:^{ atomic_store(&c->_videoBusy, false); }];
  }
}

static AVAudioPCMBuffer *pcmFromSampleBuffer(CMSampleBufferRef sb) {
  CMAudioFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
  const AudioStreamBasicDescription *asbd = fd ? CMAudioFormatDescriptionGetStreamBasicDescription(fd) : NULL;
  if (!asbd) return nil;
  AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithStreamDescription:asbd];
  if (!fmt && asbd->mChannelsPerFrame > 2) {  // >2 channels need a layout to be described at all
    AVAudioChannelLayout *layout = [AVAudioChannelLayout
        layoutWithLayoutTag:kAudioChannelLayoutTag_DiscreteInOrder | asbd->mChannelsPerFrame];
    fmt = [[AVAudioFormat alloc] initWithStreamDescription:asbd channelLayout:layout];
  }
  AVAudioFrameCount n = (AVAudioFrameCount)CMSampleBufferGetNumSamples(sb);
  AVAudioPCMBuffer *pcm = fmt && n ? [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:n] : nil;
  if (!pcm) return nil;
  pcm.frameLength = n;  // sizes the AudioBufferList; with 0 the copy fails (-12731)
  if (CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, 0, (int32_t)n, pcm.mutableAudioBufferList)) return nil;
  return pcm;
}

- (void)pushAudio:(CMSampleBufferRef)buffer {
  NSMutableArray<PluginClient *> *wanted = [NSMutableArray array];
  for (PluginClient *c in self.snapshot)
    if (c.audioSpec && c->_audioInFlight < kMaxAudioInFlight) [wanted addObject:c];
  if (!wanted.count) return;
  CFRetain(buffer);
  dispatch_async(_audioQueue, ^{
    AVAudioPCMBuffer *src = pcmFromSampleBuffer(buffer);
    double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer));
    CFRelease(buffer);
    if (src) [self convertAudio:src pts:pts for:wanted];
  });
}

// audio queue
- (void)convertAudio:(AVAudioPCMBuffer *)src pts:(double)pts for:(NSArray<PluginClient *> *)clients {
  for (PluginClient *c in clients) {
    NSDictionary *spec = c.audioSpec;
    double rate = MIN(192000, MAX(8000, numberIn(spec, @"rate", 16000)));
    AVAudioChannelCount channels = (AVAudioChannelCount)MIN(8, MAX(1, numberIn(spec, @"channels", 1)));
    AVAudioConverter *conv = c.converter;
    if (!conv || ![conv.inputFormat isEqual:src.format]) {
      AVAudioFormat *out = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                            sampleRate:rate
                                                              channels:channels
                                                           interleaved:YES];
      conv = [[AVAudioConverter alloc] initFromFormat:src.format toFormat:out];
      c.converter = conv;
    }
    if (!conv) continue;
    AVAudioFrameCount cap = (AVAudioFrameCount)ceil(src.frameLength * rate / src.format.sampleRate) + 64;
    AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:conv.outputFormat frameCapacity:cap];
    __block BOOL given = NO;
    NSError *err;
    // Feeding one buffer per call keeps the resampler's state continuous.
    [conv convertToBuffer:out
                    error:&err
       withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *status) {
         if (given) {
           *status = AVAudioConverterInputStatus_NoDataNow;
           return nil;
         }
         given = YES;
         *status = AVAudioConverterInputStatus_HaveData;
         return src;
       }];
    if (!out.frameLength) continue;
    NSData *data = [NSData dataWithBytes:out.int16ChannelData[0] length:out.frameLength * channels * 2];
    atomic_fetch_add(&c->_audioInFlight, 1);
    [c send:@{
      @"type" : @"audio",
      @"pts" : @(pts),
      @"rate" : @(rate),
      @"channels" : @(channels),
      @"format" : @"s16le",
      @"frames" : @(out.frameLength)
    }
        payload:data
           done:^{ atomic_fetch_sub(&c->_audioInFlight, 1); }];
  }
}

- (void)send:(NSDictionary *)message to:(PluginClient *)client {
  [client send:message payload:nil done:nil];
}

- (void)broadcastState:(NSDictionary *)state {
  NSMutableDictionary *msg = [state mutableCopy];
  msg[@"type"] = @"state";
  for (PluginClient *c in self.snapshot)
    if (c.wantsState) [c send:msg payload:nil done:nil];
}

- (void)broadcastInput:(NSDictionary *)event {
  NSMutableDictionary *msg = [event mutableCopy];
  msg[@"type"] = @"input";
  for (PluginClient *c in self.snapshot)
    if (c.wantsInput) [c send:msg payload:nil done:nil];
}

@end
