import Foundation
import Testing
@testable import StudyCore

struct LiveTranscriptTests {
  @Test func volatileEditsReplaceTextWithoutDuplicatesAndKeepUnchangedWordIDs() throws {
    var cache = LiveTranscriptCache(limitBytes: 10000)
    let id = cache.begin(source: .system)
    try cache.apply(.init(text: "A blue robot", start: 0, end: 1, isFinal: false), to: id)
    let before = try #require(cache.session(id)).document.sentences.flatMap(\.tokens)
    try cache.apply(.init(text: "A blue robot walks.", start: 0, end: 2, isFinal: true), to: id)
    let after = try #require(cache.session(id)).document.sentences.flatMap(\.tokens)
    #expect(after.prefix(before.count).map(\.id) == before.map(\.id))
    #expect(cache.session(id)?.segments.count == 1)
    #expect(after.filter(\.lexical).map(\.surface) == ["A", "blue", "robot", "walks"])
    let late = try cache.apply(.init(text: "A wrong correction", start: 0, end: 1, isFinal: false), to: id)
    #expect(!late && cache.session(id)?.segments.first?.update.text == "A blue robot walks.")
    try cache.apply(.init(text: "It finds a lantern.", start: 2, end: 4, isFinal: true), to: id)
    let timeline = Timeline(try #require(cache.session(id)).document.sentences)
    #expect(timeline.lines.count == 2 && timeline.lines[0].id == before[0].id)
  }
  @Test func exactSpeechWordTimesAndPauseOffsetsArePreserved() throws {
    var cache = LiveTranscriptCache(limitBytes: 10000)
    let id = cache.begin(source: .microphone)
    let update = LiveSpeechUpdate(text: "Blue robot.", start: 0, end: 2, isFinal: true, words: [
      .init(text: "Blue ", start: 0, end: 0.4), .init(text: "robot.", start: 1, end: 2),
    ]).offset(by: 10)
    try cache.apply(update, to: id)
    let words = try #require(cache.session(id)).document.sentences.flatMap(\.tokens).filter(\.lexical)
    #expect(words.map(\.startTime) == [10, 11])
    #expect(words.allSatisfy { $0.timingQuality == .exact || $0.timingQuality == .anchored })
  }
  @Test func limitEvictsOldestEnglishAcrossSessionsAndCanShrinkImmediately() throws {
    var cache = LiveTranscriptCache(limitBytes: 100)
    let old = cache.begin(source: .system)
    try cache.apply(.init(text: "A blue robot.", start: 0, end: 1, isFinal: true), to: old)
    let current = cache.begin(source: .microphone)
    try cache.apply(.init(text: "A red clock.", start: 0, end: 1, isFinal: true), to: current)
    cache.setLimit("A red clock.".utf8.count)
    #expect(cache.byteCount == "A red clock.".utf8.count)
    #expect(cache.session(old) == nil && cache.session(current)?.segments.count == 1)
    cache.setLimit(1)
    #expect(cache.byteCount == 0 && cache.session(current) != nil)
    cache.removeAll()
    #expect(cache.sessions.isEmpty && cache.byteCount == 0)
  }
  @Test func invalidResultsAndRepeatedEmptySessionsAreBounded() throws {
    var cache = LiveTranscriptCache(limitBytes: 10)
    var id = cache.begin(source: .system)
    for _ in 0..<100 { id = cache.begin(source: .microphone) }
    #expect(cache.sessions.count == 1)
    #expect(try !cache.apply(.init(text: "hello", start: .nan, end: 1, isFinal: true), to: id))
    #expect(try !cache.apply(.init(text: "hello", start: 2, end: 1, isFinal: true), to: id))
    #expect(try !cache.apply(.init(text: " ", start: 0, end: 1, isFinal: true), to: id))
    try cache.apply(.init(text: "A long authored sentence.", start: 0, end: 1, isFinal: true), to: id)
    #expect(cache.byteCount <= 10)
  }
  @Test func settingsRoundTripAndLegacyDefaults() throws {
    let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(legacy.liveSpeechCacheMB == 4 && legacy.speechAudioSource == .system && legacy.speechMicrophoneID.isEmpty)
    var settings = legacy
    settings.liveSpeechCacheMB = 8; settings.speechMicrophoneID = "authored-device"; settings.speechAudioSource = .microphone
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
    let invalid = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"liveSpeechCacheMB":999}"#.utf8))
    #expect(invalid.liveSpeechCacheMB == 64)
  }
  @Test func incompleteWordTimingCannotDropRecognizedText() throws {
    var cache = LiveTranscriptCache(limitBytes: 10000)
    let id = cache.begin(source: .system)
    try cache.apply(.init(text: "A violet robot.", start: 0, end: 2, isFinal: true, words: [
      .init(text: "A ", start: 0, end: 0.3), .init(text: "violet ", start: 0.3, end: 1),
      .init(text: "robot.", start: 1, end: .nan),
    ]), to: id)
    let text = try #require(cache.session(id)).document.sentences.map(\.text).joined()
    #expect(text == "A violet robot.")
  }
}
