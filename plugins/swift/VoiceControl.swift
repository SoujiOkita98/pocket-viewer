// voice-control — pocket-viewer plugin: spoken commands, recognized on-device
// with Apple Speech.
//
//   左转 / 右转 [30度]      turn left / right [30 degrees]     (default 15°)
//   抬头 / 低头 [20度]      look up / look down [20 degrees]   (default 10°)
//   放大 / 缩小 [到2倍]     zoom in / zoom out [to 2x]
//   回中                    center
//   开始录像 / 停止录像     start recording / stop recording
//   拍照                    take a photo
//
//   voice-control [--lang zh-CN|en-US] [--wake 相机] [--pause 0.7]
//
// With --wake, only words after the wake word count ("相机，左转"), so
// conversation that happens to contain a command word doesn't move anything.

import AVFoundation
import Foundation
import Speech

struct Options {
  var lang = Locale.current.identifier.hasPrefix("zh") ? "zh-CN" : "en-US"
  var wake = ""
  var pause = 0.7

  init(_ args: [String]) {
    var it = args.dropFirst().makeIterator()
    while let a = it.next() {
      switch a {
      case "--lang": lang = it.next() ?? lang
      case "--wake": wake = it.next() ?? wake
      case "--pause": pause = Double(it.next() ?? "") ?? pause
      default:
        FileHandle.standardError.write("usage: voice-control [--lang zh-CN|en-US] [--wake word] [--pause secs]\n".data(using: .utf8)!)
        exit(2)
      }
    }
  }
}

enum Command {
  case pan(Double), tilt(Double), zoomBy(Double), zoomTo(Double), center, record(String), snapshot

  var description: String {
    switch self {
    case .pan(let d): return String(format: "turn %@ %.0f°", d < 0 ? "left" : "right", abs(d))
    case .tilt(let d): return String(format: "look %@ %.0f°", d < 0 ? "down" : "up", abs(d))
    case .zoomBy(let d): return d > 0 ? "zoom in" : "zoom out"
    case .zoomTo(let z): return String(format: "zoom to %.1fx", z / 100)
    case .center: return "center"
    case .record(let a): return a == "start" ? "start recording" : "stop recording"
    case .snapshot: return "snapshot"
    }
  }
}

/// "30", "三十", "四十五", "两", "一百二十" → number.
func parseNumber(_ s: String) -> Double? {
  if let d = Double(s) { return d }
  let digits: [Character: Double] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
  var total = 0.0, current = 0.0
  for c in s {
    if let d = digits[c] {
      current = d
    } else if c == "十" {
      total += (current == 0 ? 1 : current) * 10
      current = 0
    } else if c == "百" {
      total += (current == 0 ? 1 : current) * 100
      current = 0
    } else {
      return nil
    }
  }
  return total + current
}

/// Finds every command in `text`, in the order spoken.
func parseCommands(_ text: String) -> [Command] {
  let num = #"([0-9]+(?:\.[0-9]+)?|[零一二两三四五六七八九十百]+)"#
  // A unit is required, so "左转一点" ("a bit") isn't read as 1°.
  let degrees = #"(?:\s*"# + num + #"\s*(?:度|°|degrees?))?"#
  let times = #"(?:\s*(?:到|to)?\s*"# + num + #"\s*(?:倍|x|times))?"#
  // (pattern, build from the optional number)
  let rules: [(String, (Double?) -> Command)] = [
    (#"(?:左转|(?:向|往)左(?:转|看|边)?|(?:turn|pan|look) left)"# + degrees, { .pan(-($0 ?? 15)) }),
    (#"(?:右转|(?:向|往)右(?:转|看|边)?|(?:turn|pan|look) right)"# + degrees, { .pan($0 ?? 15) }),
    (#"(?:抬头|(?:向|往)上(?:看|转|抬)?|(?:look|tilt) up)"# + degrees, { .tilt($0 ?? 10) }),
    (#"(?:低头|(?:向|往)下(?:看|转)?|(?:look|tilt) down)"# + degrees, { .tilt(-($0 ?? 10)) }),
    (#"(?:放大|拉近|推近|zoom in)"# + times, { $0.map { .zoomTo($0 * 100) } ?? .zoomBy(50) }),
    (#"(?:缩小|拉远|zoom out)"# + times, { $0.map { .zoomTo($0 * 100) } ?? .zoomBy(-50) }),
    (#"(?:回中|归中|居中|回正|复位|回到中间|\bcenter\b|\bre-?center\b)"#, { _ in .center }),
    (#"(?:开始录(?:像|制|影|视频)|start recording)"#, { _ in .record("start") }),
    (#"(?:(?:停止|结束|停)录(?:像|制|影|视频)?|stop recording)"#, { _ in .record("stop") }),
    (#"(?:拍照|拍张照|拍一张|截图|take a (?:photo|picture|snapshot)|\bsnapshot\b)"#, { _ in .snapshot }),
  ]
  let lower = text.lowercased()
  let ns = lower as NSString
  var found: [(Int, Command)] = []
  for (pattern, build) in rules {
    guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
    for m in re.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
      let n = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? parseNumber(ns.substring(with: m.range(at: 1))) : nil
      found.append((m.range.location, build(n)))
    }
  }
  return found.sorted { $0.0 < $1.0 }.map(\.1)
}

/// The part of `text` that may hold commands: all of it, or what follows the
/// wake word (nil if it wasn't said).
func commandText(_ text: String, wake: String) -> String? {
  guard !wake.isEmpty else { return text }
  guard let r = text.range(of: wake, options: .caseInsensitive) else { return nil }
  return String(text[r.upperBound...])
}

func run(_ c: Command, _ pv: PocketViewer) {
  switch c {
  case .pan(let d): pv.gimbal(dpan: d)
  case .tilt(let d): pv.gimbal(dtilt: d)
  case .zoomBy(let d): pv.zoom(by: d)
  case .zoomTo(let z): pv.zoom(z)
  case .center: pv.center()
  case .record(let a): pv.record(a)
  case .snapshot: pv.snapshot()
  }
}

@main
struct VoiceControl {
  static func main() {
    var opt = Options(CommandLine.arguments)
    let pv: PocketViewer
    do {
      pv = try PocketViewer(name: "voice-control")
    } catch {
      FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
      exit(1)
    }

    let queue = DispatchQueue(label: "voice-control")  // recognizer callbacks come from two threads
    func declareOptions() {
      pv.setOptions([
        ["key": "lang", "title": "Language", "type": "choice", "value": opt.lang,
         "choices": [["zh-CN", "中文（普通话）"], ["en-US", "English"]]],
        ["key": "wake", "title": "Wake word", "type": "choice", "value": opt.wake,
         "choices": [["", "None (any speech)"], ["相机", "“相机”"], ["camera", "“camera”"]]],
      ])
    }
    pv.onSet = { key, value in
      guard let v = value as? String else { return }
      switch key {
      case "lang": if v != opt.lang { pv.restart(setting: "lang", to: v) }
      case "wake":
        queue.sync { opt.wake = v }
        pv.log("wake word → \(v.isEmpty ? "none" : v)")
        pv.hud(v.isEmpty ? "🎙 listening" : "🎙 say “\(v)” + command")
        declareOptions()
      default: break
      }
    }
    declareOptions()

    let auth = DispatchSemaphore(value: 0)
    var status = SFSpeechRecognizerAuthorizationStatus.notDetermined
    SFSpeechRecognizer.requestAuthorization {
      status = $0
      auth.signal()
    }
    auth.wait()
    guard status == .authorized else {
      pv.log("speech recognition not authorized (System Settings → Privacy & Security → Speech Recognition)")
      exit(1)
    }
    guard let rec = Recognizer(locale: opt.lang, pause: opt.pause) else {
      pv.log("speech recognition unavailable for \(opt.lang)")
      exit(1)
    }
    rec.onLog = { pv.log($0) }

    rec.onPartial = { text in
      queue.async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        pv.draw("heard", [["shape": "text", "x": 0.02, "y": 0.9, "text": "🎙 " + t, "size": 14]], ttl: 2)
      }
    }
    rec.onPhrase = { phrase in
      queue.async {
        guard let text = commandText(phrase, wake: opt.wake) else { return }
        let commands = parseCommands(text)
        guard !commands.isEmpty else { return }
        pv.log("「\(phrase)」 → " + commands.map(\.description).joined(separator: ", "))
        pv.hud("✓ " + commands.map(\.description).joined(separator: " · "), key: "last", color: "#66ccff", ttl: 3)
        for c in commands { run(c, pv) }
        pv.draw("heard", [["shape": "text", "x": 0.02, "y": 0.9, "size": 16,
                           "text": "🎙 " + commands.map(\.description).joined(separator: " · ")]], ttl: 2.5)
      }
    }
    pv.onAudio = { rec.append($0) }
    pv.subscribe(audio: ["rate": 16000, "channels": 1])
    func showStatus() { pv.hud(opt.wake.isEmpty ? "🎙 listening" : "🎙 say “\(opt.wake)” + command") }
    showStatus()
    pv.log("listening for commands (\(opt.lang), \(rec.onDevice ? "on-device" : "server-based")"
      + (opt.wake.isEmpty ? ")" : ", wake word “\(opt.wake)”)"))

    // Speech callbacks and timers need a run loop; the socket gets its own thread.
    Thread.detachNewThread {
      pv.run()
      exit(0)
    }
    rec.start()
    RunLoop.main.run()
  }
}
