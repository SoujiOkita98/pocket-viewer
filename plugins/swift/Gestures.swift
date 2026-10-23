// gestures — pocket-viewer plugin: control the camera with hand gestures.
//
// A teaching example: it shows how to read hand poses with Vision and turn
// them into commands (hold times, one-shot vs repeating actions, overlay
// feedback). The thresholds are rough; it isn't meant for everyday use.
//
//   ✋ open palm, held 1 s       start / stop recording
//   ✌️ victory, held 1 s         save a snapshot
//   ☝️ point left/right/up/down  turn the gimbal that way while held
//   👍 / 👎 thumb up / down      zoom in / out while held
//
//   gestures [--verbose]
//
// Hands are found with Apple Vision's hand-pose detector. Each gesture must be
// held briefly before it acts, and one-shot gestures (record, snapshot) need
// the hand to change before they fire again.

import CoreVideo
import Foundation
import Vision

enum Gesture: Equatable {
  case none, palm, victory, thumbUp, thumbDown
  case point(dx: Double, dy: Double)  // unit direction in the picture, y down

  var name: String {
    switch self {
    case .none: return ""
    case .palm: return "✋"
    case .victory: return "✌️"
    case .thumbUp: return "👍"
    case .thumbDown: return "👎"
    case .point: return "☝️"
    }
  }

  /// Same kind of gesture, ignoring the pointing direction.
  func sameKind(_ other: Gesture) -> Bool {
    switch (self, other) {
    case (.point, .point): return true
    default: return self == other
    }
  }
}

/// One hand: its gesture and where to draw the label (normalized, top-left).
struct Hand {
  var gesture: Gesture
  var box: CGRect
}

typealias Joint = VNHumanHandPoseObservation.JointName

/// Classifies a hand from its joints, in pixels so distances aren't skewed by
/// the frame's aspect ratio. A finger counts as extended when its tip is well
/// beyond its middle joint as seen from the wrist.
func classify(_ obs: VNHumanHandPoseObservation, width: Double, height: Double) -> Hand? {
  guard let points = try? obs.recognizedPoints(.all) else { return nil }
  func p(_ j: Joint) -> CGPoint? {
    guard let rp = points[j], rp.confidence > 0.3 else { return nil }
    return CGPoint(x: rp.location.x * width, y: (1 - rp.location.y) * height)  // top-left, pixels
  }
  func d(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
  guard let wrist = p(.wrist), let middleMCP = p(.middleMCP) else { return nil }
  let palm = d(wrist, middleMCP)
  guard palm > 8 else { return nil }  // too small or degenerate

  func extended(_ tip: Joint, _ pip: Joint) -> Bool? {
    guard let t = p(tip), let m = p(pip) else { return nil }
    return d(wrist, t) > d(wrist, m) * 1.15 && d(wrist, t) > palm * 1.4
  }
  guard let index = extended(.indexTip, .indexPIP), let middle = extended(.middleTip, .middlePIP),
        let ring = extended(.ringTip, .ringPIP), let little = extended(.littleTip, .littlePIP) else { return nil }
  var thumb = false
  var thumbVertical = 0.0  // tip above (−) or below (+) its base, in palms
  if let tip = p(.thumbTip), let ip = p(.thumbIP), let mp = p(.thumbMP), let littleMCP = p(.littleMCP) {
    thumb = d(tip, littleMCP) > d(ip, littleMCP) * 1.1 && d(tip, mp) > palm * 0.5
    thumbVertical = (tip.y - mp.y) / palm
  }

  let all = [wrist, middleMCP] + [Joint.indexTip, .middleTip, .ringTip, .littleTip, .thumbTip].compactMap(p)
  let xs = all.map(\.x), ys = all.map(\.y)
  let box = CGRect(x: xs.min()! / width, y: ys.min()! / height,
                   width: (xs.max()! - xs.min()!) / width, height: (ys.max()! - ys.min()!) / height)

  var g = Gesture.none
  switch (index, middle, ring, little) {
  case (true, true, true, true) where thumb: g = .palm
  case (true, true, false, false): g = .victory
  case (true, false, false, false):
    if let tip = p(.indexTip), let mcp = p(.indexMCP), d(tip, mcp) > palm * 0.8 {
      let len = d(tip, mcp)
      g = .point(dx: (tip.x - mcp.x) / len, dy: (tip.y - mcp.y) / len)
    }
  case (false, false, false, false) where thumb:
    if thumbVertical < -0.6 { g = .thumbUp } else if thumbVertical > 0.6 { g = .thumbDown }
  default: break
  }
  return Hand(gesture: g, box: box)
}

func detectHands(_ frame: VideoFrame) -> [Hand] {
  withPixelBuffer(frame) { pb -> [Hand] in
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 2
    try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([request])
    return (request.results ?? []).compactMap { classify($0, width: Double(frame.width), height: Double(frame.height)) }
  } ?? []
}

struct Options {
  var record = true, snapshot = true, move = true, zoom = true
  var verbose = false

  init(_ args: [String]) {
    for a in args.dropFirst() {
      switch a {
      case "--verbose": verbose = true
      default:
        FileHandle.standardError.write("usage: gestures [--verbose]\n".data(using: .utf8)!)
        exit(2)
      }
    }
  }
}

@main
struct Gestures {
  static func main() {
    var opt = Options(CommandLine.arguments)
    let pv: PocketViewer
    do {
      pv = try PocketViewer(name: "gestures")
    } catch {
      FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
      exit(1)
    }

    let holdOneShot = 1.0   // seconds a record / snapshot gesture must be held
    let holdRepeat = 0.4    // before pointing or thumbs start acting
    var current = Gesture.none
    var since = 0.0         // when `current` started
    var fired = false       // one-shot already done for this hold
    var lastRepeat = 0.0
    var noHandFrames = 0

    pv.onVideo = { frame in
      guard frame.format == "bgra" else { return }
      let now = ProcessInfo.processInfo.systemUptime
      let hands = detectHands(frame)
      // The first hand showing a gesture wins.
      let active = hands.first { $0.gesture != .none }
      let g = active?.gesture ?? .none
      // Tolerate a frame or two of dropout without restarting the hold.
      if g == .none && current != .none && noHandFrames < 3 {
        noHandFrames += 1
      } else {
        noHandFrames = 0
        if !g.sameKind(current) {
          current = g
          since = now
          fired = false
          if opt.verbose && g != .none { pv.log("gesture \(g.name)") }
        } else {
          current = g  // keep the latest pointing direction
        }
      }
      let held = now - since

      var label = ""
      var progress: Double? = nil
      switch current {
      case .palm where opt.record:
        let recording = pv.state["recording"] as? Bool ?? false
        label = recording ? "✋ stop recording" : "✋ start recording"
        progress = fired ? nil : min(1, held / holdOneShot)
        if !fired && held >= holdOneShot {
          fired = true
          pv.record(recording ? "stop" : "start")
          pv.log(recording ? "stop recording" : "start recording")
          pv.hud(recording ? "⏹ recording stopped" : "🔴 recording", key: "last", color: "#66ccff", ttl: 2)
        }
      case .victory where opt.snapshot:
        label = "✌️ snapshot"
        progress = fired ? nil : min(1, held / holdOneShot)
        if !fired && held >= holdOneShot {
          fired = true
          pv.snapshot()
          pv.log("snapshot")
          pv.hud("📸 snapshot", key: "last", color: "#66ccff", ttl: 2)
        }
      case .point(let dx, let dy) where opt.move:
        // Mostly horizontal turns pan, mostly vertical tilts. Facing the
        // camera, a hand pointing to its owner's right points left in the
        // picture, and the camera turns that way: toward where they point.
        let horizontal = abs(dx) >= abs(dy)
        let arrow = horizontal ? (dx > 0 ? "→" : "←") : (dy > 0 ? "↓" : "↑")
        label = "☝️ turn \(arrow)"
        if held >= holdRepeat && now - lastRepeat >= 0.5 {
          lastRepeat = now
          if horizontal { pv.gimbal(dpan: dx > 0 ? 4 : -4) } else { pv.gimbal(dtilt: dy > 0 ? -3 : 3) }
        }
      case .thumbUp where opt.zoom, .thumbDown where opt.zoom:
        let zoomIn = current == .thumbUp
        label = zoomIn ? "👍 zoom in" : "👎 zoom out"
        if held >= holdRepeat && now - lastRepeat >= 0.2 {
          lastRepeat = now
          pv.zoom(by: zoomIn ? 10 : -10)
        }
      default: break
      }

      var items: [[String: Any]] = []
      if let hand = active, !label.isEmpty {
        let b = hand.box
        items.append(["shape": "rect", "x": b.minX, "y": b.minY, "w": b.width, "h": b.height,
                      "color": "#66ccff", "width": 2, "label": label, "size": 15])
        if let progress {
          items.append(["shape": "rect", "x": b.minX, "y": b.maxY + 0.01, "w": b.width, "h": 0.012,
                        "color": "#66ccff", "width": 1])
          items.append(["shape": "rect", "x": b.minX, "y": b.maxY + 0.01, "w": b.width * progress, "h": 0.012,
                        "color": "#66ccff", "fill": "#66ccff", "width": 1])
        }
      }
      pv.draw("hands", items, ttl: 0.5)
    }

    func declareOptions() {
      pv.setOptions([
        ["key": "record", "title": "✋ Open palm: start / stop recording", "type": "bool", "value": opt.record],
        ["key": "snapshot", "title": "✌️ Victory: snapshot", "type": "bool", "value": opt.snapshot],
        ["key": "move", "title": "☝️ Point: turn the gimbal", "type": "bool", "value": opt.move],
        ["key": "zoom", "title": "👍 / 👎 Thumb: zoom", "type": "bool", "value": opt.zoom],
      ])
    }
    pv.onSet = { key, value in
      guard let v = value as? Bool else { return }
      switch key {
      case "record": opt.record = v
      case "snapshot": opt.snapshot = v
      case "move": opt.move = v
      case "zoom": opt.zoom = v
      default: return
      }
      pv.log("\(key) → \(v)")
      declareOptions()
    }
    declareOptions()

    pv.subscribe(video: ["maxWidth": 640, "fps": 15, "format": "bgra"], state: true)
    pv.hud("🖐 gestures")
    pv.log("gestures started: ✋ record · ✌️ snapshot · ☝️ turn · 👍👎 zoom")
    pv.run()
  }
}
