#import "echocancel.h"

#import <CoreAudio/CoreAudio.h>

static AudioDeviceID deviceForUID(NSString *uid) {
  AudioObjectPropertyAddress addr = {kAudioHardwarePropertyTranslateUIDToDevice,
                                     kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  CFStringRef cfuid = (__bridge CFStringRef)uid;
  AudioDeviceID dev = kAudioObjectUnknown;
  UInt32 size = sizeof dev;
  AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, sizeof cfuid, &cfuid, &size, &dev);
  return dev;
}

static NSError *osError(OSStatus status, NSString *what) {
  return [NSError errorWithDomain:NSOSStatusErrorDomain
                             code:status
                         userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"%@ (%d)", what, (int)status]}];
}

// Tap buffers are reused by the engine once the tap block returns.
static AVAudioPCMBuffer *copyBuffer(AVAudioPCMBuffer *buf) {
  AVAudioPCMBuffer *copy = [[AVAudioPCMBuffer alloc] initWithPCMFormat:buf.format frameCapacity:buf.frameLength];
  copy.frameLength = buf.frameLength;
  for (AVAudioChannelCount c = 0; c < buf.format.channelCount; c++)
    memcpy(copy.floatChannelData[c], buf.floatChannelData[c], buf.frameLength * sizeof(float));
  return copy;
}

@implementation EchoCanceller {
  AVAudioEngine *_engine;
  AVAudioPlayerNode *_player;  // plays the processed mic for monitoring
  id _configObserver;
  NSTimer *_watchdog;
  dispatch_queue_t _monitorQueue;
  _Atomic float _level;
}

- (float)levelDB {
  return _level;
}

- (BOOL)startWithInputUID:(NSString *)inputUID
                outputUID:(NSString *)outputUID
               monitoring:(BOOL)monitoring
                    error:(NSError **)error {
  [self stop];
  AVAudioEngine *engine = [AVAudioEngine new];
  if (![engine.inputNode setVoiceProcessingEnabled:YES error:error]) return NO;
  // Leave other apps' playback at full volume and the mic gain alone; the
  // defaults duck the one and boost the other.
  engine.inputNode.voiceProcessingAGCEnabled = NO;
  engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
      (AVAudioVoiceProcessingOtherAudioDuckingConfiguration){
          .enableAdvancedDucking = NO, .duckingLevel = AVAudioVoiceProcessingOtherAudioDuckingLevelMin};

  // Input and output share one voice-processing unit: element 1 is the mic
  // side, element 0 the speaker side.
  AudioUnit unit = engine.inputNode.audioUnit;
  AudioDeviceID in = deviceForUID(inputUID);
  if (in == kAudioObjectUnknown) {
    if (error) *error = osError(kAudioHardwareBadDeviceError, [@"unknown input " stringByAppendingString:inputUID]);
    return NO;
  }
  OSStatus st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1,
                                     &in, sizeof in);
  if (st) {
    if (error) *error = osError(st, @"select input device");
    return NO;
  }
  if (outputUID) {
    AudioDeviceID out = deviceForUID(outputUID);
    st = out == kAudioObjectUnknown
             ? kAudioHardwareBadDeviceError
             : AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &out, sizeof out);
    if (st) {
      if (error) *error = osError(st, @"select output device");
      return NO;
    }
  }

  // Voice processing resamples the speaker side and can pull a few frames more
  // than the engine's default 1024-frame slice, overrunning its buffers (heap
  // corruption, found with ASan). Give every node generous headroom.
  for (AVAudioNode *node in @[ engine.inputNode, engine.outputNode, engine.mainMixerNode ])
    node.AUAudioUnit.maximumFramesToRender = 4096;

  _engine = engine;
  _player = [AVAudioPlayerNode new];
  _monitorQueue = dispatch_queue_create("echocancel.monitor", DISPATCH_QUEUE_SERIAL);
  [engine attachNode:_player];
  self.monitoring = monitoring;
  [self connect];

  __weak EchoCanceller *weakSelf = self;
  [engine.inputNode installTapOnBus:0
                         bufferSize:1024
                             format:nil
                              block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
    [weakSelf deliver:buf at:when];
  }];

  // Voice processing builds its aggregate device after the first start, which
  // changes the I/O configuration and stops the engine. The change notification
  // doesn't always arrive (seen with an explicitly selected output device), so
  // a watchdog restarts the engine too.
  _configObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:AVAudioEngineConfigurationChangeNotification
                  object:engine
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *n) {
    [weakSelf restartIfStopped];
  }];
  _watchdog = [NSTimer scheduledTimerWithTimeInterval:1
                                              repeats:YES
                                                block:^(NSTimer *t) {
    [weakSelf restartIfStopped];
  }];
  if (![engine startAndReturnError:error]) return NO;
  [_player play];
  return YES;
}

- (void)restartIfStopped {
  if (!_engine || _engine.isRunning) return;
  [self connect];
  NSError *err;
  if ([_engine startAndReturnError:&err])
    [_player play];
  else
    NSLog(@"echo cancel restart failed: %@", err.localizedDescription);
}

// The mic must NOT be connected to the mixer: with inputNode wired into the
// graph, voice processing hands the tap pure silence. Monitoring instead goes
// tap → player → mixer → output. Voice processing also requires the client
// input and output formats to match, so everything uses the mic's format.
- (void)connect {
  AVAudioFormat *fmt = [_engine.inputNode outputFormatForBus:0];
  [_engine connect:_player to:_engine.mainMixerNode format:fmt];
  [_engine connect:_engine.mainMixerNode to:_engine.outputNode format:fmt];
}

- (void)setMonitoring:(BOOL)monitoring {
  _monitoring = monitoring;
  _engine.mainMixerNode.outputVolume = monitoring ? 1 : 0;
}

- (void)stop {
  if (_configObserver) [NSNotificationCenter.defaultCenter removeObserver:_configObserver];
  _configObserver = nil;
  [_watchdog invalidate];
  _watchdog = nil;
  [_engine.inputNode removeTapOnBus:0];
  [_engine stop];
  _engine = nil;
  _player = nil;
  _level = -160;
}

- (void)deliver:(AVAudioPCMBuffer *)buf at:(AVAudioTime *)when {
  if (!buf.frameLength || !buf.floatChannelData) return;
  float peak = 0;
  for (AVAudioChannelCount c = 0; c < buf.format.channelCount; c++)
    for (AVAudioFrameCount i = 0; i < buf.frameLength; i++) peak = MAX(peak, fabsf(buf.floatChannelData[c][i]));
  _level = peak > 0 ? 20 * log10f(peak) : -160;

  // Never call into the engine or its nodes from the tap: stopping the engine
  // holds its lock while waiting for the tap to return (deadlock, seen live).
  AVAudioPlayerNode *player = _player;
  if (self.monitoring && player) {
    AVAudioPCMBuffer *copy = copyBuffer(buf);
    dispatch_async(_monitorQueue, ^{
      if (player.engine) [player scheduleBuffer:copy completionHandler:nil];  // not after stop
    });
  }

  void (^onAudio)(CMSampleBufferRef) = self.onAudio;
  if (!onAudio || !when.hostTimeValid) return;

  CMAudioFormatDescriptionRef fmt = NULL;
  if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, buf.format.streamDescription, 0, NULL, 0, NULL, NULL,
                                     &fmt))
    return;
  CMSampleTimingInfo timing = {
      .duration = CMTimeMake(1, (int32_t)buf.format.sampleRate),
      .presentationTimeStamp = CMClockMakeHostTimeFromSystemUnits(when.hostTime),
      .decodeTimeStamp = kCMTimeInvalid,
  };
  CMSampleBufferRef sb = NULL;
  OSStatus st = CMSampleBufferCreate(kCFAllocatorDefault, NULL, false, NULL, NULL, fmt, buf.frameLength, 1, &timing,
                                     0, NULL, &sb);
  CFRelease(fmt);
  if (st) return;
  // Copies the samples, so the buffer outlives this callback.
  if (CMSampleBufferSetDataBufferFromAudioBufferList(sb, kCFAllocatorDefault, kCFAllocatorDefault, 0,
                                                     buf.audioBufferList) == noErr)
    onAudio(sb);
  CFRelease(sb);
}

- (void)dealloc {
  [self stop];
}

@end
