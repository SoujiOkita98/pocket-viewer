// interpreter — pocket-viewer plugin: live subtitles of what's said, with a
// running translation.
//
// Two engines:
//   --asr apple (default)  Apple Speech recognizes locally (on-device when the
//                          language supports it); each phrase is translated with
//                          the OpenAI chat API once the speaker pauses. Without
//                          an API key it only shows the transcript.
//   --asr openai           OpenAI's gpt-realtime-translate streams recognition
//                          and translation together, while the speaker talks.
//                          Billed per minute, so the session only runs while
//                          someone is talking: it opens on local voice and
//                          closes after --idle seconds without a transcript.
//
//   interpreter [--asr apple|openai] [--from zh-CN] [--to English] [--model gpt-5.4-mini]
//               [--pause 1.5] [--idle 10] [--vad-db 10] [--key-file path]
//
// The key comes from --key-file, $OPENAI_API_KEY, ./.openai-key or
// ~/.config/pocket-viewer/openai-key, in that order.

import AVFoundation
import CryptoKit
import Foundation
import Speech

struct Options {
  var from = Locale.current.identifier
  var to = "English"
  var model = "gpt-5.4-mini"
  var pause = 1.5  // seconds of no new words that end a phrase; shorter splits sentences mid-thought
  var keyFile: String?
  var asr = "apple"
  var idle = 10.0   // --asr openai: close the session after this many seconds without a transcript
  var vadDB = 10.0  // --asr openai: dB above the noise floor that counts as voice

  init(_ args: [String]) {
    var it = args.dropFirst().makeIterator()
    while let a = it.next() {
      switch a {
      case "--from": from = it.next() ?? from
      case "--to": to = it.next() ?? to
      case "--model": model = it.next() ?? model
      case "--key-file": keyFile = it.next()
      case "--pause": pause = Double(it.next() ?? "") ?? pause
      case "--asr": asr = it.next() ?? asr
      case "--idle": idle = Double(it.next() ?? "") ?? idle
      case "--vad-db": vadDB = Double(it.next() ?? "") ?? vadDB
      default:
        FileHandle.standardError.write("usage: interpreter [--asr apple|openai] [--from zh-CN] [--to English] [--model m] [--pause secs] [--idle secs] [--vad-db db] [--key-file path]\n".data(using: .utf8)!)
        exit(2)
      }
    }
  }
}

func openAIKey(file: String?) -> String? {
  func read(_ path: String) -> String? {
    let k = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    return k?.isEmpty == false ? k : nil
  }
  if let file { return read(file) }
  if let k = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !k.isEmpty { return k }
  return read(".openai-key")
    ?? read((NSHomeDirectory() as NSString).appendingPathComponent(".config/pocket-viewer/openai-key"))
}

/// Translates phrases one at a time, in order, keeping a little context.
final class Translator {
  private let key: String
  private let opt: Options
  private let queue = DispatchQueue(label: "translator")
  private var history: [(String, String)] = []  // recent (source, translation); queue only

  /// The fastest reasoning setting each model family accepts (checked against
  /// the API: gpt-5.x rejects "minimal", plain gpt-5 has no "none", and
  /// non-reasoning chat models reject the field entirely).
  static func lowestEffort(_ model: String) -> String? {
    if model.hasPrefix("gpt-5.") { return "none" }
    if model.hasPrefix("gpt-5") { return "minimal" }
    if model.hasPrefix("o") { return "low" }
    return nil
  }

  init(key: String, options: Options) {
    self.key = key
    self.opt = options
  }

  func translate(_ text: String, done: @escaping (String?, String?) -> Void) {
    queue.async {
      let context = self.history.suffix(3).map { "\($0.0) → \($0.1)" }.joined(separator: "\n")
      var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
      req.httpMethod = "POST"
      req.timeoutInterval = 20
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.setValue("Bearer \(self.key)", forHTTPHeaderField: "Authorization")
      var body: [String: Any] = [
        "model": self.opt.model,
        "messages": [
          ["role": "system",
           "content": "You are a simultaneous interpreter. Translate the user's speech transcript into \(self.opt.to). "
             + "It comes from live speech recognition, so fix obvious recognition errors from context. "
             + "Reply with the translation only."
             + (context.isEmpty ? "" : "\n\nPrevious phrases, for context:\n\(context)")],
          ["role": "user", "content": text],
        ],
      ]
      if let effort = Translator.lowestEffort(self.opt.model) { body["reasoning_effort"] = effort }
      req.httpBody = try? JSONSerialization.data(withJSONObject: body)

      var result: String?, error: String?
      let sem = DispatchSemaphore(value: 0)
      URLSession.shared.dataTask(with: req) { data, resp, err in
        defer { sem.signal() }
        if let err { error = err.localizedDescription; return }
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let msg = (json?["error"] as? [String: Any])?["message"] as? String {
          error = "OpenAI \((resp as? HTTPURLResponse)?.statusCode ?? 0): \(msg)"
          return
        }
        let choice = (json?["choices"] as? [[String: Any]])?.first
        result = ((choice?["message"] as? [String: Any])?["content"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if result == nil { error = "unexpected response" }
      }.resume()
      sem.wait()
      if let result { self.history.append((text, result)) }
      done(result, error)
    }
  }
}

/// --asr openai. gpt-realtime-translate takes a continuous 24 kHz PCM16 stream
/// (silence included) and returns source-transcript and translation deltas
/// while the speaker talks. It has no turn or "done" events, so callers cut
/// sentences at sentence-ending punctuation. Translated audio is ignored.
///
/// It is billed per minute of session, so it only runs while someone talks:
/// - opens when a local level detector hears voice (once closed, OpenAI hears
///   nothing, so only a local signal can reopen it). The last second of audio
///   is kept and sent first, so the opening words aren't lost;
/// - closes after `idleTimeout` seconds without a transcript from OpenAI.
///   That is a better "nobody is talking" signal than loudness: fans, music
///   or typing keep a level detector busy but produce no words;
/// - a session that closes without any transcript was opened by noise: its
///   level becomes the noise floor and the margin rises 6 dB (up to +18), so
///   steady noise stops reopening it. Both ease back after a minute of quiet.
final class RealtimeTranslator: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
  static let rate = 24000
  private let key: String
  private let language: String
  private let idleTimeout: Double
  private let voiceMargin: Double               // dB above the noise floor that counts as voice
  private var noisePenalty = 0.0                // extra margin after sessions opened by noise
  private let queue = DispatchQueue(label: "realtime")
  // All below: queue only.
  private var socket: URLSessionWebSocketTask?  // non-nil while a session is open
  private var pending = Data()                  // audio waiting to go out in 100 ms chunks
  private var preroll: [Data] = []              // last second of audio while closed
  private var noiseFloor: Double?               // dBFS, tracked while nobody talks
  private var levelAvg = -100.0                 // recent average level, dBFS
  private var loudMs = 0
  private var lastVoice = Date.distantPast
  private var lastWords = Date.distantPast      // last source-transcript delta (or session start)
  private var heardWords = false                // this session produced any transcript
  var onSource: ((String) -> Void)?
  var onTarget: ((String) -> Void)?
  var onLog: ((String) -> Void)?
  var onActive: ((Bool) -> Void)?

  init(key: String, language: String, idleTimeout: Double, voiceMargin: Double) {
    self.key = key
    self.language = language
    self.idleTimeout = idleTimeout
    self.voiceMargin = voiceMargin
  }

  // MARK: Voice gating

  private static func level(_ data: Data) -> Double {
    data.withUnsafeBytes { raw in
      let s = raw.bindMemory(to: Int16.self)
      guard !s.isEmpty else { return -100 }
      var sum = 0.0
      for v in s { let x = Double(Int16(littleEndian: v)); sum += x * x }
      let rms = (sum / Double(s.count)).squareRoot() / 32768
      return rms > 0 ? 20 * log10(rms) : -100
    }
  }

  /// Voice = clearly above the tracked noise floor for at least 60 ms, so a
  /// click or a cough doesn't open a session.
  private func isVoice(_ db: Double, ms: Int) -> Bool {
    let floor = noiseFloor ?? db
    if db > floor + voiceMargin + noisePenalty && db > -60 {
      loudMs += ms
      return loudMs >= 60
    }
    loudMs = 0
    // Follow the floor down quickly and up slowly (so speech doesn't raise it).
    noiseFloor = db < floor ? floor * 0.8 + db * 0.2 : floor * 0.995 + db * 0.005
    return false
  }

  func append(_ chunk: AudioChunk) {
    guard Int(chunk.rate) == RealtimeTranslator.rate, chunk.channels == 1 else { return }
    queue.async {
      let db = RealtimeTranslator.level(chunk.data)
      self.levelAvg = self.levelAvg * 0.95 + db * 0.05
      let voice = self.isVoice(db, ms: chunk.frames * 1000 / RealtimeTranslator.rate)
      if voice { self.lastVoice = Date() }
      // Penalty for noise-triggered sessions fades after a minute of quiet.
      if !voice && self.noisePenalty > 0 && Date().timeIntervalSince(self.lastVoice) > 60 { self.noisePenalty = 0 }
      if self.socket == nil {
        self.preroll.append(chunk.data)
        while self.preroll.reduce(0, { $0 + $1.count }) > RealtimeTranslator.rate * 2 { self.preroll.removeFirst() }
        guard voice else { return }
        self.onLog?("voice detected, opening translation session")
        self.connect()
        self.preroll.forEach { self.enqueue($0) }
        self.preroll.removeAll()
        return
      }
      self.enqueue(chunk.data)
      if Date().timeIntervalSince(self.lastWords) > self.idleTimeout { self.close() }
    }
  }

  // queue
  private func enqueue(_ data: Data) {
    pending.append(data)
    while pending.count >= RealtimeTranslator.rate / 10 * 2 {  // 100 ms
      let chunk = pending.prefix(RealtimeTranslator.rate / 10 * 2)
      pending.removeFirst(chunk.count)
      send(["type": "session.input_audio_buffer.append", "audio": chunk.base64EncodedString()])
    }
  }

  // MARK: Session

  // queue
  private func connect() {
    var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")!)
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    // Abuse monitoring wants a stable, non-identifying per-user id.
    let user = SHA256.hash(data: Data(NSUserName().utf8)).map { String(format: "%02x", $0) }.joined()
    req.setValue(user, forHTTPHeaderField: "OpenAI-Safety-Identifier")
    let ws = URLSession(configuration: .default, delegate: self, delegateQueue: nil).webSocketTask(with: req)
    socket = ws
    ws.resume()
    // Source transcripts are off by default (session.audio.input.transcription
    // is null in session.created, contrary to the guide); enable them.
    send(["type": "session.update", "session": ["audio": [
      "input": ["transcription": ["model": "gpt-live-transcribe"]],
      "output": ["language": language],
    ]]])
    receive(on: ws)
    lastWords = Date()
    heardWords = false
    onActive?(true)
  }

  // queue. Ends the session; deltas still in flight arrive before session.closed.
  private func close() {
    guard let ws = socket else { return }
    send(["type": "session.close"])
    socket = nil
    pending.removeAll()
    if heardWords {
      onLog?("no speech for \(Int(idleTimeout)) s, translation session closed (not billed while idle)")
    } else {
      noisePenalty = min(18, noisePenalty + 6)
      noiseFloor = max(noiseFloor ?? levelAvg, levelAvg)  // learn the noise that opened it
      onLog?("session heard no speech (noise?), closed; voice threshold +\(Int(noisePenalty)) dB for now")
    }
    onActive?(false)
    queue.asyncAfter(deadline: .now() + 5) { ws.cancel(with: .normalClosure, reason: nil) }
  }

  // queue
  private func send(_ message: [String: Any]) {
    guard let ws = socket, let data = try? JSONSerialization.data(withJSONObject: message),
          let text = String(data: data, encoding: .utf8) else { return }
    ws.send(.string(text)) { _ in }  // failures surface in receive()
  }

  private func receive(on ws: URLSessionWebSocketTask) {
    ws.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(.string(let text)):
        if self.handle(text) { ws.cancel(with: .normalClosure, reason: nil) } else { self.receive(on: ws) }
      case .success:
        self.receive(on: ws)
      case .failure(let error):
        self.queue.async {
          guard self.socket === ws else { return }  // closed on purpose
          // Dropped while in use: start over; the next voice reopens it.
          self.onLog?("translation session lost (\(error.localizedDescription))")
          self.socket = nil
          self.pending.removeAll()
          self.onActive?(false)
        }
      }
    }
  }

  /// Returns true once the session has closed.
  private func handle(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    switch msg["type"] as? String {
    case "session.input_transcript.delta":
      let delta = msg["delta"] as? String ?? ""
      if !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        queue.async {
          self.lastWords = Date()
          self.heardWords = true
        }
      }
      onSource?(delta)
    case "session.output_transcript.delta": onTarget?(msg["delta"] as? String ?? "")
    case "session.closed": return true
    case "error":
      let err = msg["error"] as? [String: Any]
      onLog?("realtime error: \(err?["message"] as? String ?? text)")
    default: break  // session.created, translated audio, ...
    }
    return false
  }
}

/// Splits a growing stream of text into finished sentences and the rest.
struct SentenceBuffer {
  private(set) var current = ""
  mutating func append(_ delta: String) -> [String] {
    current += delta
    var done: [String] = []
    while let end = current.firstIndex(where: { "。！？.!?".contains($0) }) {
      let sentence = current[...end].trimmingCharacters(in: .whitespaces)
      current = String(current[current.index(after: end)...])
      if !sentence.isEmpty { done.append(sentence) }
    }
    return done
  }
}

/// gpt-realtime-translate wants a language code; accept common names too.
func languageCode(_ name: String) -> String {
  let codes = ["english": "en", "chinese": "zh", "japanese": "ja", "korean": "ko", "spanish": "es", "french": "fr",
               "german": "de", "italian": "it", "portuguese": "pt", "russian": "ru", "arabic": "ar", "hindi": "hi"]
  return codes[name.lowercased()] ?? name
}

/// The subtitle overlay: the phrase being spoken under the last two
/// translations. All state lives on one serial queue.
final class Subtitles: @unchecked Sendable {
  private let pv: PocketViewer
  private let queue = DispatchQueue(label: "subtitles")
  private var translations: [String] = []
  private var current = ""  // translation still being streamed (--asr openai)
  private var partial = ""

  init(_ pv: PocketViewer) { self.pv = pv }

  func setPartial(_ text: String) { queue.async { self.partial = text; self.redraw() } }
  func add(_ translation: String) { queue.async { self.translations.append(translation); self.redraw() } }
  func setCurrent(_ text: String) { queue.async { self.current = text; self.redraw() } }

  private func redraw() {
    var lines = Array(translations.suffix(2))
    if !current.isEmpty { lines.append(current) }
    var items: [[String: Any]] = lines.suffix(3).map { ["shape": "subtitle", "text": $0, "size": 26] }
    if !partial.isEmpty {
      items.append(["shape": "subtitle", "text": partial, "size": 18, "color": "#ffffffb0", "background": "#00000060"])
    }
    pv.draw("subtitles", items, ttl: 12)
  }
}

/// Settings for pocket-viewer's Plugins menu. Changing one re-execs this
/// process with the new flag: both engines are built once at startup, and a
/// restart is the simplest way to rebuild either. pocket-viewer still knows
/// the restarted process (same token), and re-sends saved settings only when
/// they differ, so this can't loop.
func declareOptions(_ pv: PocketViewer, _ opt: Options) {
  func choices(_ list: [(Any, String)], including current: Any) -> [[Any]] {
    var out = list.map { [$0.0, $0.1] }
    if !list.contains(where: { "\($0.0)" == "\(current)" }) { out.append([current, "\(current)"]) }
    return out
  }
  pv.setOptions([
    ["key": "asr", "title": "Engine", "type": "choice", "value": opt.asr,
     "choices": [["apple", "Apple on-device + OpenAI translation"], ["openai", "OpenAI realtime (billed per minute)"]]],
    ["key": "to", "title": "Translate to", "type": "choice", "value": opt.to,
     "choices": choices([("English", "English"), ("Chinese", "中文"), ("Japanese", "日本語"), ("Korean", "한국어"),
                         ("Spanish", "Español"), ("French", "Français"), ("German", "Deutsch")], including: opt.to)],
    ["key": "from", "title": "Spoken language (Apple)", "type": "choice", "value": opt.from,
     "choices": choices([("zh-CN", "中文（普通话）"), ("en-US", "English"), ("ja-JP", "日本語"), ("ko-KR", "한국어")],
                        including: opt.from)],
    ["key": "pause", "title": "Phrase ends after (Apple)", "type": "choice", "value": opt.pause,
     "choices": choices([(1.0, "1.0 s"), (1.5, "1.5 s"), (2.0, "2.0 s"), (3.0, "3.0 s")], including: opt.pause)],
    ["key": "model", "title": "Translation model (Apple)", "type": "choice", "value": opt.model,
     "choices": choices([("gpt-5.4-mini", "gpt-5.4-mini"), ("gpt-5.4-nano", "gpt-5.4-nano (faster)"),
                         ("gpt-4.1-mini", "gpt-4.1-mini (fastest)")], including: opt.model)],
    ["key": "idle", "title": "Close session after no speech (OpenAI)", "type": "choice", "value": opt.idle,
     "choices": choices([(5.0, "5 s"), (10.0, "10 s"), (30.0, "30 s"), (60.0, "60 s")], including: opt.idle)],
  ])
  pv.onSet = { key, value in
    let new: String
    switch value {
    case let d as Double: new = d == d.rounded() ? String(Int(d)) : String(d)
    default: new = "\(value)"
    }
    let current: String
    switch key {
    case "asr": current = opt.asr
    case "to": current = opt.to
    case "from": current = opt.from
    case "model": current = opt.model
    case "pause": current = opt.pause == opt.pause.rounded() ? String(Int(opt.pause)) : String(opt.pause)
    case "idle": current = opt.idle == opt.idle.rounded() ? String(Int(opt.idle)) : String(opt.idle)
    default: return
    }
    guard new != current else { return }
    pv.restart(setting: key, to: new)
  }
}

@main
struct Interpreter {
  static func main() {
    let opt = Options(CommandLine.arguments)
    let pv: PocketViewer
    do {
      pv = try PocketViewer(name: "interpreter")
    } catch {
      FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
      exit(1)
    }

    declareOptions(pv, opt)
    if opt.asr == "openai" { runRealtime(pv, opt) }

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
    guard let rec = Recognizer(locale: opt.from, pause: opt.pause) else {
      pv.log("speech recognition unavailable for \(opt.from)")
      exit(1)
    }
    rec.onLog = { pv.log($0) }
    pv.hud("💬 \(opt.from) → \(opt.to)")
    let translator = openAIKey(file: opt.keyFile).map { Translator(key: $0, options: opt) }
    pv.log("listening (\(opt.from), \(rec.onDevice ? "on-device" : "server-based") recognition) → "
      + (translator.map { _ in "\(opt.to) via \(opt.model)" } ?? "no OpenAI key found, transcript only"))

    let subtitles = Subtitles(pv)
    rec.onPartial = { subtitles.setPartial($0) }
    rec.onPhrase = { phrase in
      subtitles.setPartial("")
      guard let translator else {
        pv.log("「\(phrase)」")
        return subtitles.add(phrase)
      }
      translator.translate(phrase) { result, error in
        if let error { pv.log("translation failed: \(error)") }
        pv.log("「\(phrase)」 → 「\(result ?? "")」")
        subtitles.add(result ?? phrase)
      }
    }
    pv.onAudio = { rec.append($0) }
    pv.subscribe(audio: ["rate": 16000, "channels": 1])

    // Speech callbacks and timers need a run loop; the socket gets its own thread.
    Thread.detachNewThread {
      pv.run()
      exit(0)
    }
    rec.start()
    RunLoop.main.run()
  }

  static func runRealtime(_ pv: PocketViewer, _ opt: Options) -> Never {
    guard let key = openAIKey(file: opt.keyFile) else {
      pv.log("--asr openai needs an OpenAI key ($OPENAI_API_KEY, ./.openai-key or --key-file)")
      exit(1)
    }
    let lang = languageCode(opt.to)
    let rt = RealtimeTranslator(key: key, language: lang, idleTimeout: opt.idle, voiceMargin: opt.vadDB)
    let subtitles = Subtitles(pv)
    let lock = NSLock()
    var source = SentenceBuffer(), target = SentenceBuffer()
    rt.onLog = { pv.log($0) }
    func showStatus(_ active: Bool) {
      pv.hud(active ? "● translating → \(opt.to)" : "○ interpreter idle", color: active ? "#ff6666" : "#bbbbbb")
    }
    rt.onActive = showStatus
    showStatus(false)
    rt.onSource = { delta in
      lock.lock()
      let done = source.append(delta)
      let tail = String(source.current.suffix(40))
      lock.unlock()
      for s in done { pv.log("「\(s)」") }
      subtitles.setPartial(tail)
    }
    rt.onTarget = { delta in
      lock.lock()
      let done = target.append(delta)
      let current = target.current
      lock.unlock()
      for s in done {
        pv.log("→ 「\(s)」")
        subtitles.add(s)
      }
      subtitles.setCurrent(current)
    }
    pv.log("listening → \(lang) via gpt-realtime-translate; opens on voice, closes after \(Int(opt.idle)) s without speech")
    pv.onAudio = { rt.append($0) }
    pv.subscribe(audio: ["rate": RealtimeTranslator.rate, "channels": 1])
    pv.run()
    exit(0)
  }
}
