// transcribe — speech to text for plugins in any language: reads 16 kHz mono
// s16le audio on stdin and writes one JSON object per line on stdout:
//
//   {"partial": "words so far"}      while someone speaks
//   {"phrase": "the whole phrase"}   after a pause (--pause seconds)
//   {"log": "message"}               status and errors
//
//   transcribe [--lang zh-CN] [--pause 1.0]
//
// Recognition is Apple Speech, on-device when the language supports it. Used
// by plugins/node/ai-agent; exits when stdin closes.

import AVFoundation
import Foundation
import Speech

func emit(_ obj: [String: String]) {
  guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
  FileHandle.standardOutput.write(data + Data("\n".utf8))
}

@main
struct Transcribe {
  static func main() {
    var lang = Locale.current.identifier.hasPrefix("zh") ? "zh-CN" : "en-US"
    var pause = 1.0
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
      switch a {
      case "--lang": lang = it.next() ?? lang
      case "--pause": pause = Double(it.next() ?? "") ?? pause
      default:
        FileHandle.standardError.write("usage: transcribe [--lang zh-CN] [--pause secs] < s16le-16k-mono\n".data(using: .utf8)!)
        exit(2)
      }
    }
    setvbuf(stdout, nil, _IONBF, 0)

    let auth = DispatchSemaphore(value: 0)
    var status = SFSpeechRecognizerAuthorizationStatus.notDetermined
    SFSpeechRecognizer.requestAuthorization {
      status = $0
      auth.signal()
    }
    auth.wait()
    guard status == .authorized else {
      emit(["log": "speech recognition not authorized (System Settings → Privacy & Security → Speech Recognition)"])
      exit(1)
    }
    guard let rec = Recognizer(locale: lang, pause: pause) else {
      emit(["log": "speech recognition unavailable for \(lang)"])
      exit(1)
    }
    rec.onLog = { emit(["log": $0]) }
    rec.onPartial = { emit(["partial": $0]) }
    rec.onPhrase = { emit(["phrase": $0]) }
    emit(["log": "listening (\(lang), \(rec.onDevice ? "on-device" : "server-based"))"])

    // 100 ms chunks from stdin; EOF ends the program.
    Thread.detachNewThread {
      let stdin = FileHandle.standardInput
      var pending = Data()
      while true {
        let data = stdin.availableData
        if data.isEmpty { exit(0) }
        pending.append(data)
        let chunkBytes = 3200
        while pending.count >= chunkBytes {
          let chunk = pending.prefix(chunkBytes)
          pending.removeFirst(chunkBytes)
          rec.append(AudioChunk(pts: 0, rate: 16000, channels: 1, frames: chunkBytes / 2, data: Data(chunk)))
        }
      }
    }
    rec.start()
    RunLoop.main.run()
  }
}
