// face-follow — pocket-viewer plugin: boxes every face (Apple Vision) and
// turns the gimbal to keep the largest one framed.
//
//   face-follow [--no-follow] [--no-boxes] [--verbose] [--gain 0.8] [--deadzone 0.06] [--target-y 0.4] [--name face-follow]

import CoreVideo
import Foundation
import Vision

struct Options {
  var follow = true
  var boxes = true      // draw the face boxes and the target mark
  var gain = 0.8        // fraction of the error corrected per move
  var deadzone = 0.06   // normalized distance from the target point that counts as framed
  var targetY = 0.4     // keep the face a little above center (headroom)
  var verbose = false   // log every move
  var name = "face-follow"  // in the Plugins menu; settings are remembered per name

  init(_ args: [String]) {
    var it = args.dropFirst().makeIterator()
    while let a = it.next() {
      switch a {
      case "--no-follow": follow = false
      case "--no-boxes": boxes = false
      case "--verbose": verbose = true
      case "--gain": gain = Double(it.next() ?? "") ?? gain
      case "--deadzone": deadzone = Double(it.next() ?? "") ?? deadzone
      case "--target-y": targetY = Double(it.next() ?? "") ?? targetY
      case "--name": name = it.next() ?? name
      default:
        FileHandle.standardError.write("usage: face-follow [--no-follow] [--no-boxes] [--verbose] [--gain g] [--deadzone d] [--target-y y] [--name n]\n".data(using: .utf8)!)
        exit(2)
      }
    }
  }
}

/// Faces in normalized top-left coordinates, largest first.
func detectFaces(_ frame: VideoFrame) -> [(rect: CGRect, confidence: Float)] {
  withPixelBuffer(frame) { pb -> [(CGRect, Float)] in
    let request = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([request])
    return (request.results ?? [])
      .map { face in
        let b = face.boundingBox  // Vision: normalized, origin bottom-left
        return (CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), face.confidence)
      }
      .sorted { $0.0.width * $0.0.height > $1.0.width * $1.0.height }
  } ?? []
}

@main
struct FaceFollow {
  static func main() {
    var opt = Options(CommandLine.arguments)
    let pv: PocketViewer
    do {
      pv = try PocketViewer(name: opt.name)
    } catch {
      FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
      exit(1)
    }
    let follower = Follower()
    follower.gain = opt.gain
    follower.deadzone = opt.deadzone
    if opt.verbose { follower.log = { pv.log("face " + $0) } }
    var lastCount = -1

    pv.onVideo = { frame in
      guard frame.format == "bgra" else { return }
      let faces = detectFaces(frame)
      if faces.count != lastCount {
        let n = "\(faces.count) face\(faces.count == 1 ? "" : "s")"
        pv.log(n + " in view")
        pv.hud("🙂 " + n + (opt.follow && faces.count > 0 ? " · following" : ""),
               color: faces.count > 0 ? "#00ff88" : "#bbbbbb")
        lastCount = faces.count
      }
      var items: [[String: Any]] = [
        // target point
        ["shape": "line", "x1": 0.48, "y1": opt.targetY, "x2": 0.52, "y2": opt.targetY, "color": "#ffffff80", "width": 1],
        ["shape": "line", "x1": 0.5, "y1": opt.targetY - 0.03, "x2": 0.5, "y2": opt.targetY + 0.03, "color": "#ffffff80", "width": 1],
      ]
      for (i, face) in faces.enumerated() {
        let r = face.rect
        items.append([
          "shape": "rect", "x": r.minX, "y": r.minY, "w": r.width, "h": r.height,
          "color": i == 0 ? "#00ff88" : "#ffffffaa", "width": i == 0 ? 3 : 1.5,
          "label": i == 0 ? (opt.follow ? "following" : "face") : String(format: "%.0f%%", face.confidence * 100),
        ])
      }
      if opt.boxes { pv.draw("faces", items, ttl: 0.5) }

      guard opt.follow, let target = faces.first?.rect else { return }
      follower.update(point: CGPoint(x: target.midX, y: target.midY), target: CGPoint(x: 0.5, y: opt.targetY),
                      frame: frame, pv: pv)
    }

    // Settings in pocket-viewer's Plugins menu; they apply immediately.
    func declareOptions() {
      pv.setOptions([
        ["key": "follow", "title": "Move the gimbal to follow", "type": "bool", "value": opt.follow],
        ["key": "boxes", "title": "Show face boxes", "type": "bool", "value": opt.boxes],
        ["key": "gain", "title": "Correction per move", "type": "choice", "value": opt.gain,
         "choices": [[0.5, "Gentle (50%)"], [0.8, "Normal (80%)"], [1.0, "Full (100%)"]]],
        ["key": "targetY", "title": "Keep the face at", "type": "choice", "value": opt.targetY,
         "choices": [[0.33, "Upper third"], [0.4, "Slightly above center"], [0.5, "Center"]]],
      ])
    }
    pv.onSet = { key, value in
      switch (key, value) {
      case ("follow", let v as Bool): opt.follow = v
      case ("boxes", let v as Bool):
        opt.boxes = v
        if !v { pv.clear("faces") }
      case ("gain", let v as Double): opt.gain = v; follower.gain = v
      case ("targetY", let v as Double): opt.targetY = v
      default: return
      }
      follower.reset()
      lastCount = -1  // refresh the HUD
      pv.log("\(key) → \(value)")
      declareOptions()
    }
    declareOptions()

    pv.subscribe(video: ["maxWidth": 640, "fps": 15, "format": "bgra"], state: true)
    pv.log("face-follow started (follow: \(opt.follow), gain \(opt.gain))")
    pv.run()
  }
}
