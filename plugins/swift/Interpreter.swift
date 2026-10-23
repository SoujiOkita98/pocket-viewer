// interpreter — pocket-viewer plugin: live subtitles of what's said, with a
// running translation.
//
// Speech is recognized locally with Apple's Speech framework (on-device when
// the language supports it); each phrase is translated with the OpenAI API
// once the speaker pauses. Without an API key it only shows the transcript.
//
//   interpreter [--from zh-CN] [--to English] [--model gpt-5.4-mini] [--key-file path]
//
// The key comes from --key-file, $OPENAI_API_KEY, ./.openai-key or
// ~/.config/pocket-viewer/openai-key, in that order.

import AVFoundation
import Foundation
import Speech

struct Options {
  var from = Locale.current.identifier
  var to = "English"
  var model = "gpt-5.4-mini"
  var pause = 0.9  // seconds of no new words that end a phrase
  var keyFile: String?

  init(_ args: [String]) {
    var it = args.dropFirst().makeIterator()
    while let a = it.next() {
      switch a {
      case "--from": from = it.next() ?? from
      case "--to": to = it.next() ?? to
      case "--model": model = it.next() ?? model
      case "--key-file": keyFile = it.next()
      default:
        FileHandle.standardError.write("usage: interpreter [--from zh-CN] [--to English] [--model m] [--key-file path]\n".data(using: .utf8)!)
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

/// Feeds 16 kHz mono audio to Apple speech recognition and reports phrases.
final class Recognizer {
  private let recognizer: SFSpeechRecognizer
  private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var started = Date()
  private var text = ""        // current task's transcript so far
  private var committed = ""   // the part of `text` already handed out as phrases
  private var lastChange = Date()
  private var recent: [(time: Date, buffer: AVAudioPCMBuffer)] = []  // last few seconds of audio
  private let pause: Double
  var onPartial: ((String) -> Void)?
  var onLog: ((String) -> Void)?

  /// Errors that just mean "nothing was said" or "task was cancelled".
  static func isQuiet(_ e: NSError) -> Bool {
    (e.domain == "kAFAssistantErrorDomain" && [203, 216, 1110].contains(e.code)) || e.code == NSUserCancelledError
  }
  var onPhrase: ((String) -> Void)?

  init?(locale: String, pause: Double) {
    guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale)), r.isAvailable else { return nil }
    recognizer = r
    recognizer.queue = OperationQueue()  // don't depend on a main run loop
    self.pause = pause
  }

  var onDevice: Bool { recognizer.supportsOnDeviceRecognition }

  func start() {
    startTask()
    // Cut phrases at pauses; restart tasks before Apple's ~1 minute limit.
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
  }

  private func startTask() {
    lock.lock()
    defer { lock.unlock() }
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    req.addsPunctuation = true
    request = req
    text = ""
    committed = ""
    started = Date()
    task = recognizer.recognitionTask(with: req) { [weak self] result, error in
      guard let self else { return }
      if let result {
        self.lock.lock()
        let isCurrent = self.request === req
        if isCurrent && result.bestTranscription.formattedString != self.text {
          self.text = result.bestTranscription.formattedString
          self.lastChange = Date()
        }
        self.lock.unlock()
        if isCurrent { self.onPartial?(self.pendingText()) }
      }
      // Only the current task may restart: cancelling the old one in restart()
      // calls back here with an error, and restarting again then would kill
      // the new task (which is how recognition used to stop after ~50 s).
      guard error != nil || result?.isFinal == true else { return }
      self.lock.lock()
      let isCurrent = self.request === req
      self.lock.unlock()
      guard isCurrent else { return }
      if let error = error as NSError?, !Recognizer.isQuiet(error) { self.onLog?("recognition: \(error.localizedDescription)") }
      self.restart(flush: true)
    }
  }

  /// Text not yet handed out. The recognizer may revise words it already
  /// reported (punctuation, a better guess) or, after a long pause, start its
  /// transcript over with just the new words. A mostly-shared prefix is a
  /// revision: keep that much committed so it isn't translated twice. Little
  /// in common means a new transcript: everything in it is new.
  private func pendingLocked() -> String {
    if !text.hasPrefix(committed) {
      let common = text.commonPrefix(with: committed).count
      if common * 2 < committed.count {
        committed = ""
      } else if let end = Recognizer.boundary(of: committed, in: text) {
        committed = String(text[..<end])
      } else {
        committed = String(text.prefix(min(committed.count, text.count)))
      }
    }
    return String(text.dropFirst(committed.count))
  }

  /// Where the revised `text` reaches the end of what was `committed`: the
  /// last occurrence of committed's final few characters near the old length.
  /// Counting characters instead misplaces the boundary whenever the revision
  /// added or removed punctuation, dropping or repeating words.
  static func boundary(of committed: String, in text: String) -> String.Index? {
    let anchor = String(committed.filter { !$0.isPunctuation && !$0.isWhitespace }.suffix(3))
    guard !anchor.isEmpty else { return nil }
    let limit = text.index(text.startIndex, offsetBy: min(text.count, committed.count + 6))
    guard let r = text.range(of: anchor, options: .backwards, range: text.startIndex..<limit) else { return nil }
    // Include punctuation that directly follows the anchor in the committed part.
    var end = r.upperBound
    while end < text.endIndex, text[end].isPunctuation { end = text.index(after: end) }
    return end
  }

  private func pendingText() -> String {
    lock.lock()
    defer { lock.unlock() }
    return pendingLocked()
  }

  private func flushPhrase() {
    lock.lock()
    let phrase = pendingLocked().trimmingCharacters(in: .whitespacesAndNewlines)
    committed = text
    lock.unlock()
    if !phrase.isEmpty { onPhrase?(phrase) }
  }

  private func restart(flush: Bool) {
    if flush { flushPhrase() }
    lock.lock()
    let old = task
    let heardUntil = lastChange
    request?.endAudio()
    request = nil
    lock.unlock()
    old?.cancel()
    startTask()
    // The old task stops listening a moment after its last word, often once
    // the next phrase has begun. Replay what came in after its last result so
    // the new task hears that start too (it would otherwise lose a word or two).
    lock.lock()
    for (time, buffer) in recent where time > heardUntil { request?.append(buffer) }
    lock.unlock()
  }

  private func tick() {
    lock.lock()
    let idle = Date().timeIntervalSince(lastChange)
    let pending = !pendingLocked().isEmpty
    let age = Date().timeIntervalSince(started)
    lock.unlock()
    if pending && idle >= pause { flushPhrase() }
    if age > 50 && idle >= pause { restart(flush: true) }
  }

  func append(_ chunk: AudioChunk) {
    guard chunk.rate == 16000, chunk.channels == 1,
          let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.frames)) else { return }
    buf.frameLength = AVAudioFrameCount(chunk.frames)
    chunk.data.withUnsafeBytes { raw in
      let s = raw.bindMemory(to: Int16.self)
      let out = buf.floatChannelData![0]
      for i in 0..<chunk.frames { out[i] = Float(Int16(littleEndian: s[i])) / 32768 }
    }
    lock.lock()
    request?.append(buf)
    let now = Date()
    recent.append((now, buf))
    recent.removeAll { now.timeIntervalSince($0.time) > 5 }
    lock.unlock()
  }
}

/// The subtitle overlay: the phrase being spoken under the last two
/// translations. All state lives on one serial queue.
final class Subtitles: @unchecked Sendable {
  private let pv: PocketViewer
  private let queue = DispatchQueue(label: "subtitles")
  private var translations: [String] = []
  private var partial = ""

  init(_ pv: PocketViewer) { self.pv = pv }

  func setPartial(_ text: String) { queue.async { self.partial = text; self.redraw() } }
  func add(_ translation: String) { queue.async { self.translations.append(translation); self.redraw() } }

  private func redraw() {
    var items: [[String: Any]] = translations.suffix(2).map { ["shape": "subtitle", "text": $0, "size": 26] }
    if !partial.isEmpty {
      items.append(["shape": "subtitle", "text": partial, "size": 18, "color": "#ffffffb0", "background": "#00000060"])
    }
    pv.draw("subtitles", items, ttl: 12)
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
}
