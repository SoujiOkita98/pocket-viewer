// face-follow — pocket-viewer plugin: boxes every face (Apple Vision) and
// turns the gimbal to keep the largest one framed.
//
//   face-follow [--no-follow] [--verbose] [--gain 0.8] [--deadzone 0.06] [--target-y 0.4]

import CoreVideo
import Foundation
import Vision

// Field of view at zoom 100, measured on a Pocket 3 in landscape: a 10° pan
// moved the picture 37/320 of its width at zoom 110 → ~95° wide. Assumes the
// 16:9 formats; not verified in portrait.
let wideFOV = 95.0
let narrowFOV = wideFOV * 9 / 16

struct Options {
  var follow = true
  var gain = 0.8        // fraction of the error corrected per move
  var deadzone = 0.06   // normalized distance from the target point that counts as framed
  var targetY = 0.4     // keep the face a little above center (headroom)
  var verbose = false   // log every move
  var settle = 0.4      // seconds the gimbal must hold still before the next move (> state period)

  init(_ args: [String]) {
    var it = args.dropFirst().makeIterator()
    while let a = it.next() {
      switch a {
      case "--no-follow": follow = false
      case "--verbose": verbose = true
      case "--gain": gain = Double(it.next() ?? "") ?? gain
      case "--deadzone": deadzone = Double(it.next() ?? "") ?? deadzone
      case "--target-y": targetY = Double(it.next() ?? "") ?? targetY
      default:
        FileHandle.standardError.write("usage: face-follow [--no-follow] [--verbose] [--gain g] [--deadzone d] [--target-y y]\n".data(using: .utf8)!)
        exit(2)
      }
    }
  }
}

/// Faces in normalized top-left coordinates, largest first.
func detectFaces(_ frame: VideoFrame) -> [(rect: CGRect, confidence: Float)] {
  var data = frame.data
  return data.withUnsafeMutableBytes { raw -> [(CGRect, Float)] in
    var pb: CVPixelBuffer?
    guard CVPixelBufferCreateWithBytes(nil, frame.width, frame.height, kCVPixelFormatType_32BGRA, raw.baseAddress!,
                                       frame.width * 4, nil, nil, nil, &pb) == kCVReturnSuccess, let pb else { return [] }
    let request = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([request])
    return (request.results ?? [])
      .map { face in
        let b = face.boundingBox  // Vision: normalized, origin bottom-left
        return (CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), face.confidence)
      }
      .sorted { $0.0.width * $0.0.height > $1.0.width * $1.0.height }
  }
}

@main
struct FaceFollow {
  static func main() {
    let opt = Options(CommandLine.arguments)
    let pv: PocketViewer
    do {
      pv = try PocketViewer(name: "face-follow")
    } catch {
      FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
      exit(1)
    }
    var settledSince: Double? = nil
    var lastCount = -1

    pv.onVideo = { frame in
      guard frame.format == "bgra" else { return }
      let faces = detectFaces(frame)
      if faces.count != lastCount {
        pv.log("\(faces.count) face\(faces.count == 1 ? "" : "s") in view")
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
      pv.draw("faces", items, ttl: 0.5)

      guard opt.follow, let target = faces.first?.rect else { return }
      // Move only once the gimbal has reached its last target and held still:
      // a frame taken mid-move shows an error that is already being corrected,
      // and acting on it again overshoots and oscillates.
      let st = pv.state
      guard let pan = st["pan"] as? Double, let tilt = st["tilt"] as? Double,
            let actualPan = st["actualPan"] as? Double, let actualTilt = st["actualTilt"] as? Double else { return }
      let now = ProcessInfo.processInfo.systemUptime
      guard abs(pan - actualPan) < 1, abs(tilt - actualTilt) < 1 else {
        settledSince = nil
        return
      }
      if settledSince == nil { settledSince = now }
      guard now - settledSince! >= opt.settle else { return }

      let ex = target.midX - 0.5, ey = target.midY - opt.targetY
      guard abs(ex) > opt.deadzone || abs(ey) > opt.deadzone else { return }
      // Normalized error → degrees, for the current zoom and orientation.
      let zoom = max(1, (st["zoom"] as? Double ?? 100) / 100)
      let landscape = frame.width >= frame.height
      let hfov = (landscape ? wideFOV : narrowFOV) / zoom
      let vfov = (landscape ? narrowFOV : wideFOV) / zoom
      // +pan turns right, +tilt turns up (both measured). Absolute targets from
      // the real position, so nothing accumulates if a move falls short.
      let dpan = abs(ex) > opt.deadzone ? max(-20, min(20, ex * hfov * opt.gain)) : 0
      let dtilt = abs(ey) > opt.deadzone ? max(-20, min(20, -ey * vfov * opt.gain)) : 0
      pv.gimbal(pan: actualPan + dpan, tilt: actualTilt + dtilt)
      if opt.verbose {
        pv.log(String(format: "face at (%.2f, %.2f) err (%+.2f, %+.2f) → pan %.1f%+.1f tilt %.1f%+.1f (zoom %.0f%%)",
                      target.midX, target.midY, ex, ey, actualPan, dpan, actualTilt, dtilt, zoom * 100))
      }
      settledSince = nil
    }

    pv.subscribe(video: ["maxWidth": 640, "fps": 15, "format": "bgra"], state: true)
    pv.log("face-follow started (follow: \(opt.follow), gain \(opt.gain))")
    pv.run()
  }
}
