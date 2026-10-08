import Foundation
import Testing

@testable import StudyCore

struct RealtimeTests {
  @Test func omittedFirstOffsetPreservesWordAnchors() throws {
    let raw = Data(
      #"{"events":[{"tStartMs":12000,"dDurationMs":4800,"segs":[{"utf8":"We're"},{"utf8":" uh","tOffsetMs":400},{"utf8":" Who","tOffsetMs":1100},{"utf8":" named","tOffsetMs":1500},{"utf8":" her","tOffsetMs":1900},{"utf8":" Nora","tOffsetMs":2200},{"utf8":" Quartz?","tOffsetMs":2600}]}]}"#
        .utf8)
    let sentences = try CaptionPipeline().parse(raw, videoID: "test")
    let timeline = Timeline(sentences)
    #expect(abs(timeline.tokens[1].startTime - 12.4) < 0.001)
    #expect(timeline.token(at: 14.61)?.surface == "Quartz")
    #expect(timeline.tokens[6].timingQuality == .exact)
    #expect(timeline.lines.count == 1)
  }
  @Test func previousCurrentAndNextLinesUseOriginalCaptionEvents() throws {
    let raw = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":900,"segs":[{"utf8":"I study"}]},{"tStartMs":1000,"dDurationMs":900,"segs":[{"utf8":"English every day"}]},{"tStartMs":2000,"dDurationMs":900,"segs":[{"utf8":"at home."}]}]}"#
        .utf8)
    let timeline = Timeline(try CaptionPipeline().parse(raw, videoID: "test"))
    #expect(timeline.sentences.count == 1)
    #expect(timeline.lines.count == 3)
    #expect(timeline.line(at: 1.2)?.index == 1)
    #expect(timeline.line(at: 0.4)?.index == 0)
    #expect(timeline.line(at: 2.1)?.index == 2)
    #expect(timeline.upcomingWords(at: 1.0, limit: 2).map(\.surface) == ["English", "every"])
  }
  @Test func overlappingDisplayDurationsCannotScrambleWordOrder() throws {
    let raw = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":7000,"segs":[{"utf8":"I"},{"utf8":" study.","tOffsetMs":500}]},{"tStartMs":2000,"aAppend":1,"segs":[{"utf8":"\n"}]},{"tStartMs":2010,"dDurationMs":3000,"segs":[{"utf8":"You"},{"utf8":" read.","tOffsetMs":300}]}]}"#
        .utf8)
    let timeline = Timeline(try CaptionPipeline().parse(raw, videoID: "test"))
    #expect(timeline.tokens.map(\.surface) == ["I", "study", ".", "You", "read", "."])
    #expect(timeline.sentences.map(\.text) == ["I study.", "You read."])
    #expect(timeline.lines.count == 2)
  }
  @Test func playbackClockPauseBufferingRateAndSeek() {
    var clock = PlaybackClock()
    clock.sample(time: 10, now: 100, state: 1, rate: 1)
    #expect(abs(clock.position(now: 100.1) - 10.1) < 0.001)
    clock.sample(time: 10, now: 100.05, state: 1, rate: 1)
    #expect(abs(clock.position(now: 100.1) - 10.1) < 0.001)
    #expect(clock.position(now: 105) == 10.25)
    clock.sample(time: 11, now: 101, state: 2, rate: 1)
    #expect(clock.position(now: 102) == 11)
    clock.sample(time: 11, now: 102, state: 3, rate: 1)
    #expect(clock.position(now: 103) == 11)
    clock.sample(time: 11, now: 103, state: 1, rate: 2)
    #expect(abs(clock.position(now: 103.1) - 11.2) < 0.001)
    clock.seek(to: 50, now: 104)
    #expect(clock.position(now: 104) == 50)
    clock.sample(time: 50, now: 104.1, state: 2, rate: 2)
    #expect(clock.position(now: 105) == 50)
  }
  @Test func unknownNeverExposesSpeculativeRoles() throws {
    let raw = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"We're uh."}]}]}"#.utf8)
    let sentences = try CaptionPipeline().parse(raw, videoID: "test")
    let data = try JSONEncoder().encode(
      GrammarResponse(
        schemaVersion: 1,
        results: [
          Analysis(
            sentenceId: sentences[0].id, pattern: .UNKNOWN,
            spans: [
              Span(role: .VERB, startToken: 1, endTokenExclusive: 2)
            ])
        ]))
    #expect(try GrammarContract.validate(data, sentences: sentences)[0].spans.isEmpty)
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["STUDY_REALTIME_CAPTION"] != nil))
  func importedCaptionWordOffsets() throws {
    let data = try Data(
      contentsOf: URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["STUDY_REALTIME_CAPTION"]!))
    let timeline = Timeline(try CaptionPipeline().parse(data, videoID: "abcdefghijk"))
    #expect(!timeline.lines.isEmpty)
    #expect(
      Set(timeline.lines.compactMap { $0.tokens.first?.captionLineIndex }).count
        == timeline.lines.count)
    #expect(timeline.tokens.allSatisfy { $0.startTime < $0.endTime })
    print(
      "Imported caption: \(timeline.lines.count) lines, \(timeline.tokens.count) tokens"
    )
  }
}
