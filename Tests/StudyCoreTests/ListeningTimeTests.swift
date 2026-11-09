import Foundation
import Testing

@testable import StudyCore

struct ListeningTimeTests {
  let base = Date(timeIntervalSince1970: 1_800_000_000)
  func sample(
    _ media: Double, _ uptime: Double, state: Int = 1, rate: Double = 1,
    audible: Bool = true
  ) -> ListeningPlaybackSample {
    .init(
      mediaTime: media, uptime: uptime, date: base.addingTimeInterval(uptime), state: state,
      rate: rate, audible: audible)
  }
  func seconds(_ ranges: [DateInterval]) -> Double { ranges.reduce(0) { $0 + $1.duration } }
  func calendar(_ zone: String = "Asia/Tokyo") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.firstWeekday = 2
    return calendar
  }
  func date(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
    in calendar: Calendar
  ) -> Date {
    calendar.date(
      from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  @Test func playbackCountsElapsedListeningTimeAtDifferentSpeedsAndCoarseSamples() {
    var tracker = PlaybackListeningTracker()
    let coverage = EnglishListeningCoverage(ranges: [0..<100])
    #expect(tracker.consume(sample(0, 0), coverage: coverage).isEmpty)
    #expect(abs(seconds(tracker.consume(sample(1, 1), coverage: coverage)) - 1) < 0.00001)
    #expect(tracker.consume(sample(1, 1.05), coverage: coverage).isEmpty)
    #expect(abs(seconds(tracker.consume(sample(1.2, 1.2), coverage: coverage)) - 0.2) < 0.00001)
    #expect(tracker.consume(sample(1.2, 1.2, rate: 2), coverage: coverage).isEmpty)
    #expect(
      abs(seconds(tracker.consume(sample(2.2, 1.7, rate: 2), coverage: coverage)) - 0.5) < 0.00001)
  }
  @Test func pausesMuteBufferingSeeksAndSleepCannotInflateListeningTime() {
    var tracker = PlaybackListeningTracker()
    let coverage = EnglishListeningCoverage(ranges: [0..<10000])
    let values: [(ListeningPlaybackSample, Double)] = [
      (sample(0, 0), 0), (sample(1, 1), 1), (sample(1, 2, state: 2), 0),
      (sample(2, 3), 0), (sample(3, 4), 1), (sample(4, 5, audible: false), 0),
      (sample(5, 6, audible: false), 0), (sample(6, 7), 0), (sample(7, 8), 1),
      (sample(60, 8.1), 0), (sample(61, 9.1), 1), (sample(61, 10), 0),
      (sample(61.2, 15), 0), (sample(61.3, 15.1), 0.1),
      (sample(1, 15.2), 0), (sample(1.1, 15.3), 0.1),
      (sample(1.1, 15.4, state: 3), 0), (sample(2, 16), 0),
      (sample(100, 1000), 0),
    ]
    for (value, expected) in values {
      #expect(abs(seconds(tracker.consume(value, coverage: coverage)) - expected) < 0.00001)
    }
  }
  @Test func onlyTheEnglishCaptionPortionOfAnIntervalIsCounted() throws {
    var tracker = PlaybackListeningTracker()
    let coverage = EnglishListeningCoverage(ranges: [1..<2, 4..<5])
    _ = tracker.consume(sample(0, 0), coverage: coverage)
    let intervals = tracker.consume(sample(4, 4), coverage: coverage)
    #expect(seconds(intervals) == 1 && intervals.first?.start == base.addingTimeInterval(1))
    #expect(seconds(tracker.consume(sample(5, 5), coverage: coverage)) == 1)
    let raw = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"[Music]"}]},{"tStartMs":3000,"dDurationMs":1000,"segs":[{"utf8":"A paper robot."}]},{"tStartMs":5000,"dDurationMs":1000,"segs":[{"utf8":"日本語のみ"}]}]}"#
        .utf8)
    let actual = EnglishListeningCoverage(
      lines: Timeline(try CaptionPipeline().parse(raw, videoID: "authored")).lines)
    #expect(actual.intersections(from: 0, to: 10) == [3..<4])
  }
  @Test func speechCorrectionsAreDeduplicatedAndLongSilentGapsAreExcluded() {
    var tracker = SpeechListeningTracker()
    let first = LiveSpeechUpdate(
      text: "A paper robot.", start: 0, end: 2, isFinal: false,
      words: [.init(text: "A paper", start: 0, end: 0.5), .init(text: "robot", start: 1.5, end: 2)])
    #expect(seconds(tracker.consume(first, receivedAt: base)) == 1)
    #expect(tracker.consume(first, receivedAt: base.addingTimeInterval(1)).isEmpty)
    let correction = LiveSpeechUpdate(
      text: "A blue robot glows.", start: 0, end: 2.5, isFinal: true,
      words: [
        .init(text: "A blue", start: 0, end: 0.5), .init(text: "robot glows", start: 1.5, end: 2.5),
      ])
    #expect(seconds(tracker.consume(correction, receivedAt: base.addingTimeInterval(1))) == 0.5)
    #expect(
      tracker.consume(.init(text: "[Music]", start: 5, end: 20, isFinal: true), receivedAt: base)
        .isEmpty)
    #expect(
      tracker.consume(.init(text: "", start: 5, end: 20, isFinal: true), receivedAt: base).isEmpty)
    tracker.reset()
    #expect(seconds(tracker.consume(first, receivedAt: base)) == 1)
  }
  @Test func allDaySpeechKeepsDeduplicationBoundedAndRejectsAncientCallbacks() {
    var tracker = SpeechListeningTracker()
    var total: Double = 0
    for index in 0..<10000 {
      let update = LiveSpeechUpdate(
        text: "A paper robot.", start: Double(index * 3), end: Double(index * 3 + 1), isFinal: true)
      total += seconds(tracker.consume(update, receivedAt: base.addingTimeInterval(update.end)))
      #expect(tracker.consume(update, receivedAt: base.addingTimeInterval(update.end + 1)).isEmpty)
    }
    #expect(total == 10000)
    #expect(
      tracker.consume(
        .init(text: "Old callback.", start: 0, end: 2, isFinal: true), receivedAt: base
      ).isEmpty)
  }
  @Test func checkpointsKeepStableIDsAndFailedOlderSavesCannotOverwriteNewerProgress() throws {
    var buffer = ListeningBuffer()
    buffer.append(DateInterval(start: base, duration: 1), source: .video)
    let checkpoint = buffer.drain()
    #expect(!buffer.hasChanges)
    buffer.append(DateInterval(start: base.addingTimeInterval(1), duration: 2), source: .video)
    buffer.restore(checkpoint)
    let latest = try #require(buffer.drain().first)
    #expect(latest.id == checkpoint.first?.id && latest.seconds == 3)
    buffer.append(DateInterval(start: base.addingTimeInterval(10), duration: 1), source: .video)
    buffer.append(DateInterval(start: base.addingTimeInterval(11), duration: 1), source: .speech)
    #expect(buffer.drain().count == 2)
  }
  @Test func calendarBinsRespectLeapMonthsWeekStartsAndDaylightSaving() {
    let jp = calendar()
    #expect(
      ListeningCalendarRange(period: .year, anchor: date(2024, 2, 20, in: jp), calendar: jp).bins
        .count == 12)
    #expect(
      ListeningCalendarRange(period: .month, anchor: date(2024, 2, 20, in: jp), calendar: jp).bins
        .count == 29)
    let week = ListeningCalendarRange(
      period: .week, anchor: date(2026, 11, 11, in: jp), calendar: jp)
    #expect(week.bins.count == 7 && jp.component(.weekday, from: week.interval.start) == 2)
    let la = calendar("America/Los_Angeles")
    #expect(
      ListeningCalendarRange(period: .day, anchor: date(2026, 3, 8, 12, in: la), calendar: la).bins
        .count == 23)
    #expect(
      ListeningCalendarRange(period: .day, anchor: date(2026, 11, 1, 12, in: la), calendar: la).bins
        .count == 25)
  }
  @Test func storageClipsAtMidnightAndIdempotentCheckpointsSurviveRestart() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let jp = calendar()
    let midnight = date(2026, 11, 10, in: calendar())
    let store = try LibraryStore(directory: root)
    var span = ListeningSpan(
      start: midnight.addingTimeInterval(-10), end: midnight.addingTimeInterval(10), source: .video)
    try await store.saveListeningSpans([span, span])
    let old = span
    span.end = midnight.addingTimeInterval(20)
    try await store.saveListeningSpans([span, old])
    try await store.saveListeningSpans([
      .init(start: midnight, end: midnight.addingTimeInterval(5), source: .speech)
    ])
    let reopened = try LibraryStore(directory: root)
    let yesterday = try await reopened.listeningTotals(
      in: .init(period: .day, anchor: midnight.addingTimeInterval(-1), calendar: jp))
    let today = try await reopened.listeningTotals(
      in: .init(period: .day, anchor: midnight, calendar: jp))
    #expect(yesterday.reduce(0) { $0 + $1.total } == 10)
    #expect(today.reduce(0) { $0 + $1.videoSeconds } == 20)
    #expect(today.reduce(0) { $0 + $1.speechSeconds } == 5)
    for period in [ListeningPeriod.year, .month, .week] {
      let totals = try await reopened.listeningTotals(
        in: .init(period: period, anchor: midnight, calendar: jp))
      #expect(totals.reduce(0) { $0 + $1.total } == 35)
    }
    let nepal = calendar("Asia/Kathmandu")
    let boundary = date(2026, 11, 10, in: nepal)
    try await store.saveListeningSpans([
      .init(
        start: boundary.addingTimeInterval(-60), end: boundary.addingTimeInterval(60),
        source: .speech)
    ])
    let totals = try await reopened.listeningTotals(
      in: .init(period: .day, anchor: boundary, calendar: nepal))
    #expect(totals.first?.speechSeconds == 60)
  }
  @Test func invalidStorageBatchRollsBackWithoutLosingExistingRecords() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let good = ListeningSpan(start: base, end: base.addingTimeInterval(10), source: .video)
    await #expect(throws: (any Error).self) {
      try await store.saveListeningSpans([good, .init(start: base, end: base, source: .video)])
    }
    let totals = try await store.listeningTotals(in: .init(period: .day, anchor: base))
    #expect(totals.reduce(0) { $0 + $1.total } == 0)
  }
}
