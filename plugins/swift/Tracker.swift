// tracker — pocket-viewer plugin: click something in the picture (or ⌥-drag a
// box around it) and the gimbal keeps it centered. Esc stops.
//
//   tracker [--no-follow] [--verbose] [--gain 0.8] [--size 0.15]
//
// Tracking is Apple Vision's visual object tracker, so it follows whatever
// was selected (a cup, a pet, a hand), not a class of objects.

import CoreVideo
import Foundation
import Vision

struct Options {
  var follow = true
  var gain = 0.8
  var size = 0.15      // box height a click selects, as a fraction of the frame height
  var verbose = false

  init(_ args: [String]) {
    var it = args.dropFirst().makeIterator()
    while let a = it.next() {
      switch a {
      case "--no-follow": follow = false
      case "--verbose": verbose = true
      case "--gain": gain = Double(it.next() ?? "") ?? gain
      case "--size": size = Double(it.next() ?? "") ?? size
      default:
        FileHandle.standardError.write("usage: tracker [--no-follow] [--verbose] [--gain g] [--size s]\n".data(using: .utf8)!)
        exit(2)
      }
    }
  }
}

/// One tracked target. Vision works in normalized coordinates with the
/// origin bottom-left; everything outside this class uses top-left.
///
/// Vision's tracker lets the box creep larger frame after frame, and on a live
/// camera it never stops. Only its center is trusted: the size stays what was
/// selected, scaled by any zoom since, and once the box drifts more than 15%
/// from that, tracking restarts from the current center at that size.
final class Track {
  private let handler = VNSequenceRequestHandler()
  private var observation: VNDetectedObjectObservation
  private var lowConfidence = 0  // consecutive frames
  private let size: CGSize       // as selected, at `zoom`
  private let zoom: Double
  private(set) var reseeds = 0

  init(rect: CGRect, zoom: Double) {
    observation = VNDetectedObjectObservation(boundingBox: Track.flip(rect))
    size = rect.size
    self.zoom = zoom
  }

  static func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

  var rect: CGRect { Track.flip(observation.boundingBox) }

  /// Follows the target into `frame`, taken at `zoom`. Returns false once it
  /// is lost: low confidence for about a second, or tracking failed outright.
  func update(_ frame: VideoFrame, zoom now: Double) -> Bool {
    let ok = withPixelBuffer(frame) { pb -> Bool in
      let request = VNTrackObjectRequest(detectedObjectObservation: observation)
      request.trackingLevel = .accurate
      do { try handler.perform([request], on: pb) } catch { return false }
      guard let result = request.results?.first as? VNDetectedObjectObservation else { return false }
      observation = result
      let scale = now / zoom
      let w = min(1, size.width * scale), h = min(1, size.height * scale)
      let b = result.boundingBox
      if abs(b.width / w - 1) > 0.15 || abs(b.height / h - 1) > 0.15 {
        let x = min(max(b.midX - w / 2, 0), 1 - w), y = min(max(b.midY - h / 2, 0), 1 - h)
        observation = VNDetectedObjectObservation(boundingBox: CGRect(x: x, y: y, width: w, height: h))
        reseeds += 1
      }
      lowConfidence = result.confidence < 0.3 ? lowConfidence + 1 : 0
      return true
    } ?? false
    return ok && lowConfidence < 15
  }
}

@main
struct Tracker {
  static func main() {
    var opt = Options(CommandLine.arguments)
    let pv: PocketViewer
    do {
      pv = try PocketViewer(name: "tracker")
    } catch {
      FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
      exit(1)
    }
    let follower = Follower()
    follower.gain = opt.gain
    if opt.verbose { follower.log = { pv.log("target " + $0) } }

    // Video and input both arrive on the socket thread, one at a time.
    var track: Track?
    var pendingRect: CGRect?   // selected, starts tracking on the next frame
    var frameAspect = 16.0 / 9

    func idle() { pv.hud("🎯 click to track", color: "#bbbbbb") }

    func hint() {
      pv.draw("hint", [["shape": "text", "x": 0.02, "y": 0.02, "size": 13,
                        "text": "tracker: click a target or ⌥-drag a box · Esc stops"]], ttl: 4)
    }

    pv.onInput = { e in
      switch e["event"] as? String {
      case "click":
        guard let x = e["x"] as? Double, let y = e["y"] as? Double else { return }
        // A square box around the click, clamped to the frame.
        let h = opt.size, w = opt.size / frameAspect
        pendingRect = CGRect(x: min(max(x - w / 2, 0), 1 - w), y: min(max(y - h / 2, 0), 1 - h), width: w, height: h)
      case "select":
        guard let x = e["x"] as? Double, let y = e["y"] as? Double,
              let w = e["w"] as? Double, let h = e["h"] as? Double else { return }
        pendingRect = CGRect(x: x, y: y, width: w, height: h)
      case "cancel":
        if track != nil { pv.log("stopped") }
        idle()
        track = nil
        pendingRect = nil
        pv.clear("target")
      default: break
      }
    }

    pv.onVideo = { frame in
      guard frame.format == "bgra" else { return }
      frameAspect = Double(frame.width) / Double(max(1, frame.height))
      if let r = pendingRect {
        pendingRect = nil
        track = Track(rect: r, zoom: pv.state["zoom"] as? Double ?? 100)
        follower.reset()
        pv.log(String(format: "tracking (%.2f, %.2f) %.2f×%.2f", r.midX, r.midY, r.width, r.height))
        pv.hud(opt.follow ? "🎯 tracking" : "🎯 tracking (not following)", color: "#ffcc00")
      }
      guard let t = track else { return }
      guard t.update(frame, zoom: pv.state["zoom"] as? Double ?? 100) else {
        track = nil
        pv.log("target lost")
        idle()
        pv.draw("target", [["shape": "text", "x": 0.02, "y": 0.02, "text": "tracker: target lost", "color": "#ff6666"]],
                ttl: 2)
        return
      }
      let r = t.rect
      pv.draw("target", [
        ["shape": "rect", "x": r.minX, "y": r.minY, "w": r.width, "h": r.height, "color": "#ffcc00", "width": 3,
         "label": opt.follow ? "tracking" : "target"],
      ], ttl: 0.5)
      if opt.follow {
        follower.update(point: CGPoint(x: r.midX, y: r.midY), target: CGPoint(x: 0.5, y: 0.5), frame: frame, pv: pv)
      }
    }

    func declareOptions() {
      pv.setOptions([
        ["key": "follow", "title": "Move the gimbal to follow", "type": "bool", "value": opt.follow],
        ["key": "gain", "title": "Correction per move", "type": "choice", "value": opt.gain,
         "choices": [[0.5, "Gentle (50%)"], [0.8, "Normal (80%)"], [1.0, "Full (100%)"]]],
        ["key": "size", "title": "Click selects a box of", "type": "choice", "value": opt.size,
         "choices": [[0.08, "Small (8%)"], [0.15, "Medium (15%)"], [0.3, "Large (30%)"]]],
      ])
    }
    pv.onSet = { key, value in
      switch (key, value) {
      case ("follow", let v as Bool): opt.follow = v
      case ("gain", let v as Double): opt.gain = v; follower.gain = v
      case ("size", let v as Double): opt.size = v
      default: return
      }
      follower.reset()
      pv.log("\(key) → \(value)")
      declareOptions()
    }
    declareOptions()

    pv.subscribe(video: ["maxWidth": 640, "fps": 15, "format": "bgra"], state: true, input: true)
    hint()
    idle()
    pv.log("tracker started: click a target or ⌥-drag a box in the video; Esc stops")
    pv.run()
  }
}
