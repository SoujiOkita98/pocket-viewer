// plugins — out-of-process plugin host.
//
// Plugins (any language) connect to a Unix socket, subscribe to video frames,
// audio and gimbal state, and send back drawing and gimbal commands. See
// plugins/PROTOCOL.md for the wire format.
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PluginClient : NSObject
@property(readonly) int clientID;
@property(readonly, copy) NSString *name;   // from the plugin's hello, else "client N"
@property(readonly, nullable) NSTask *task;  // set when pocket-viewer launched it
@end

@protocol PluginServerDelegate <NSObject>
// All called on the main thread.
- (void)pluginClient:(PluginClient *)client sent:(NSDictionary *)message;
- (void)pluginClientsChanged;
- (NSDictionary *)pluginHelloInfo;  // merged into the hello sent to each new client
@end

@interface PluginServer : NSObject

- (instancetype)initWithSocketPath:(NSString *)path delegate:(id<PluginServerDelegate>)delegate;
- (BOOL)start:(NSError **)error;

// Runs `/bin/sh -c command` with POCKET_VIEWER_SOCKET (and a token tying its
// connection to the task) in the environment. Main thread.
- (void)launch:(NSString *)command;
- (void)stopClient:(PluginClient *)client;  // terminates its task, if any, and disconnects
- (void)stopTask:(NSTask *)task;
- (NSString *)nameOfTask:(NSTask *)task;
- (void)shutdown;  // terminates launched plugins and removes the socket

@property(readonly, copy) NSString *socketPath;
@property(readonly) NSArray<PluginClient *> *clients;  // main thread
@property(readonly) NSArray<NSTask *> *pendingTasks;   // launched, not yet connected (main thread)

// Thread-safe fan-out. Timestamps are host-clock buffers; conversion to each
// client's requested format happens off the caller's thread, and frames are
// dropped for clients that are still busy with the previous one.
- (void)pushVideo:(CMSampleBufferRef)buffer;
- (void)pushAudio:(CMSampleBufferRef)buffer;
- (void)broadcastState:(NSDictionary *)state;  // to clients subscribed to "state"

@end

NS_ASSUME_NONNULL_END
