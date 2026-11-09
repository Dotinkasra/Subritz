import Foundation
import Testing
import StudyCore
@testable import StudyApp

@MainActor private final class RecordingWordSpeech: WordSpeechSynthesizing {
  var onEnd: ((UUID) -> Void)?
  var spoken: [(text: String, quality: WordSpeechQuality, request: UUID)] = []
  var stops = 0
  var available = true
  func speak(_ text: String, quality: WordSpeechQuality, request: UUID) -> Bool {
    guard available else { return false }
    spoken.append((text, quality, request))
    return true
  }
  func stop() { stops += 1 }
}

@MainActor struct WordSpeechTests {
  @Test func rapidSelectionsReplaceSpeechAndObsoleteCompletionCannotClearTheNewWord() throws {
    let engine = RecordingWordSpeech()
    let player = WordSpeechPlayer { engine }
    player.toggle("  robot\n")
    let first = try #require(engine.spoken.first)
    #expect(first.text == "robot" && player.speakingText == "robot")
    player.toggle("paper lantern")
    let second = try #require(engine.spoken.last)
    #expect(second.text == "paper lantern" && engine.stops == 1)
    engine.onEnd?(first.request)
    #expect(player.speakingText == "paper lantern")
    engine.onEnd?(second.request)
    #expect(player.speakingText == nil)
  }
  @Test func sameWordStopsAndExplicitStopInvalidatesLateCallbacks() throws {
    let engine = RecordingWordSpeech()
    let player = WordSpeechPlayer { engine }
    player.toggle("clock")
    player.toggle("clock")
    #expect(engine.spoken.count == 1 && engine.stops == 1 && player.speakingText == nil)
    player.toggle("garden")
    let request = try #require(engine.spoken.last?.request)
    player.stop()
    engine.onEnd?(request)
    #expect(player.speakingText == nil)
  }
  @Test func emptySelectionDoesNotInitializeSpeechAndMissingVoiceCanBeRetried() {
    let engine = RecordingWordSpeech()
    var initialized = false
    let player = WordSpeechPlayer { initialized = true; return engine }
    player.toggle(" \n")
    #expect(!initialized && player.speakingText == nil && player.error == nil)
    engine.available = false
    player.toggle("robot")
    #expect(player.error != nil && player.speakingText == nil)
    engine.available = true
    player.toggle("robot")
    #expect(player.error == nil && player.speakingText == "robot" && engine.spoken.count == 1)
  }
  @Test func requestedQualityIsPassedThroughAndChangingItReplaysTheSameWord() {
    let engine = RecordingWordSpeech()
    let player = WordSpeechPlayer { engine }
    player.toggle("robot", quality: .enhanced)
    player.toggle("robot", quality: .premium)
    #expect(engine.spoken.map(\.quality) == [.enhanced, .premium])
    #expect(player.speakingText == "robot" && engine.stops == 1)
    player.toggle("robot", quality: .premium)
    #expect(player.speakingText == nil && engine.spoken.count == 2)
  }
  @Test func voiceSelectionRequiresAnInstalledEnglishVoiceOfExactlyTheChosenQuality() {
    let voices = [
      WordSpeechVoice(id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: .standard),
      WordSpeechVoice(id: "com.apple.voice.enhanced.en-GB.Daniel", name: "Daniel", language: "en-GB", quality: .enhanced),
      WordSpeechVoice(id: "com.apple.voice.enhanced.en-US.Ava", name: "Ava", language: "en-US", quality: .enhanced),
      WordSpeechVoice(id: "authored.japanese", name: "自作", language: "ja-JP", quality: .premium),
    ]
    #expect(WordSpeechVoices.select(.standard, from: voices)?.name == "Samantha")
    #expect(WordSpeechVoices.select(.enhanced, from: voices.reversed())?.name == "Ava")
    #expect(WordSpeechVoices.select(.premium, from: voices) == nil)
    #expect(WordSpeechVoices.select(.enhanced, from: Array(voices.prefix(2)))?.name == "Daniel")
    #expect(WordSpeechVoices.select(.standard, from: []) == nil)
  }
}
