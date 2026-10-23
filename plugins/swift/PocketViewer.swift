// Client for pocket-viewer plugins. Compile it together with your plugin:
//   swiftc -O -parse-as-library PocketViewer.swift MyPlugin.swift -o my-plugin
// See ../PROTOCOL.md for the wire format.

import Foundation

public struct VideoFrame {
  public let pts: Double     // host-clock seconds
  public let width: Int
  public let height: Int
  public let format: String  // "bgra" (rows top to bottom) or "jpeg"
  public let data: Data
}

public struct AudioChunk {
  public let pts: Double
  public let rate: Double
  public let channels: Int
  public let frames: Int
  public let data: Data      // signed 16-bit little-endian, interleaved
}

public final class PocketViewer {
  public var onHello: (([String: Any]) -> Void)?
  public var onVideo: ((VideoFrame) -> Void)?
  public var onAudio: ((AudioChunk) -> Void)?
  public var onState: (([String: Any]) -> Void)?
  /// The user changed one of the settings declared with `setOptions` (key, value).
  public var onSet: ((String, Any) -> Void)?
  /// A click ("click": x, y), an ⌥-drag box ("select": x, y, w, h) or Esc
  /// ("cancel") on the video, normalized, origin top-left. Needs subscribe(input: true).
  public var onInput: (([String: Any]) -> Void)?
  public private(set) var state: [String: Any] = [:]

  private let fd: Int32
  private let sendLock = NSLock()

  public static var defaultSocketPath: String {
    ProcessInfo.processInfo.environment["POCKET_VIEWER_SOCKET"]
      ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("pocket-viewer.sock")
  }

  public init(name: String, socketPath: String = PocketViewer.defaultSocketPath) throws {
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      _ = socketPath.withCString { strlcpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count) }
    }
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard fd >= 0, ok == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "cannot connect to \(socketPath) — is pocket-viewer running?"])
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)  // a plugin that re-execs itself must not keep this connection open
    send(["type": "hello", "name": name, "token": ProcessInfo.processInfo.environment["POCKET_VIEWER_TOKEN"] ?? ""])
  }

  // MARK: Sending (thread-safe)

  public func send(_ header: [String: Any], payload: Data = Data()) {
    var h = header
    if !payload.isEmpty { h["size"] = payload.count }
    guard let json = try? JSONSerialization.data(withJSONObject: h) else { return }
    var len = UInt32(json.count).bigEndian
    var msg = Data(bytes: &len, count: 4)
    msg.append(json)
    msg.append(payload)
    sendLock.lock()
    defer { sendLock.unlock() }
    msg.withUnsafeBytes { buf in
      var off = 0
      while off < buf.count {
        let n = Darwin.send(fd, buf.baseAddress! + off, buf.count - off, 0)
        if n <= 0 { if errno == EINTR { continue }; return }
        off += n
      }
    }
  }

  /// video: ["maxWidth": 640, "fps": 15, "format": "bgra"|"jpeg"]; audio: ["rate": 16000, "channels": 1]
  public func subscribe(video: [String: Any]? = nil, audio: [String: Any]? = nil, state: Bool = false,
                        input: Bool = false) {
    send(["type": "subscribe", "video": video ?? NSNull(), "audio": audio ?? NSNull(), "state": state,
          "input": input])
  }

  /// Replaces this plugin's `layer`; it disappears after `ttl` seconds (0 = keep).
  public func draw(_ layer: String, _ items: [[String: Any]], ttl: Double = 0) {
    send(["type": "draw", "layer": layer, "items": items, "ttl": ttl])
  }

  /// Shows `text` on the HUD's plugin line, under `key` (one segment per key).
  /// Empty text removes it; `ttl` > 0 removes it after that many seconds.
  public func hud(_ text: String, key: String = "default", color: String? = nil, ttl: Double = 0) {
    var m: [String: Any] = ["type": "hud", "key": key, "text": text, "ttl": ttl]
    if let color { m["color"] = color }
    send(m)
  }

  public func clear(_ layer: String? = nil) {
    send(layer.map { ["type": "clear", "layer": $0] } ?? ["type": "clear"])
  }

  public func gimbal(pan: Double? = nil, tilt: Double? = nil, dpan: Double? = nil, dtilt: Double? = nil) {
    var m: [String: Any] = ["type": "gimbal"]
    if let pan { m["pan"] = pan }
    if let tilt { m["tilt"] = tilt }
    if let dpan { m["dpan"] = dpan }
    if let dtilt { m["dtilt"] = dtilt }
    send(m)
  }

  /// Declares user-adjustable settings, shown in pocket-viewer's Plugins menu:
  /// ["key": "follow", "title": "Follow", "type": "bool", "value": true] or
  /// ["key": "to", "title": "Translate to", "type": "choice", "choices": [["en", "English"], ...], "value": "en"].
  /// Changes arrive through `onSet`; send this again whenever values change.
  public func setOptions(_ items: [[String: Any]]) { send(["type": "options", "items": items]) }

  /// Re-runs this program with `--key value` in its arguments, to apply a
  /// setting that is only read at startup. pocket-viewer still knows the new
  /// process (same POCKET_VIEWER_TOKEN). Returns only if exec fails.
  public func restart(setting key: String, to value: String) {
    var args = CommandLine.arguments
    if let i = args.firstIndex(of: "--" + key), i + 1 < args.count { args[i + 1] = value } else { args += ["--" + key, value] }
    log("\(key) → \(value), restarting")
    let argv = args.map { strdup($0) } + [nil]
    execvp(args[0], argv)
    log("restart failed: \(String(cString: strerror(errno)))")
  }

  public func zoom(_ zoom: Double) { send(["type": "zoom", "zoom": zoom]) }
  public func zoom(by dzoom: Double) { send(["type": "zoom", "dzoom": dzoom]) }
  public func center() { send(["type": "center"]) }
  /// "start", "stop" or "toggle".
  public func record(_ action: String) { send(["type": "record", "action": action]) }
  /// Saves the next frame, full resolution, as a JPEG next to the recordings.
  public func snapshot() { send(["type": "snapshot"]) }
  public func log(_ text: String) { send(["type": "log", "text": text]) }

  // MARK: Receiving

  private func readExact(_ n: Int) -> Data? {
    var data = Data(count: n)
    var off = 0
    while off < n {
      let r = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + off, n - off) }
      if r > 0 { off += r } else if r < 0 && errno == EINTR { continue } else { return nil }
    }
    return data
  }

  /// Dispatches messages to the callbacks until pocket-viewer goes away.
  /// Callbacks run on the calling thread, one at a time.
  public func run() {
    while let lenData = readExact(4) {
      let hlen = Int(lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
      guard let hdata = readExact(hlen),
            let h = try? JSONSerialization.jsonObject(with: hdata) as? [String: Any] else { return }
      let size = h["size"] as? Int ?? 0
      guard let payload = size > 0 ? readExact(size) : Data() else { return }
      switch h["type"] as? String {
      case "hello": onHello?(h)
      case "input": onInput?(h)
      case "set":
        if let key = h["key"] as? String, let value = h["value"] { onSet?(key, value) }
      case "state":
        state = h
        onState?(h)
      case "video":
        onVideo?(VideoFrame(pts: h["pts"] as? Double ?? 0, width: h["width"] as? Int ?? 0,
                            height: h["height"] as? Int ?? 0, format: h["format"] as? String ?? "", data: payload))
      case "audio":
        onAudio?(AudioChunk(pts: h["pts"] as? Double ?? 0, rate: h["rate"] as? Double ?? 0,
                            channels: h["channels"] as? Int ?? 1, frames: h["frames"] as? Int ?? 0, data: payload))
      default: break
      }
    }
  }
}
