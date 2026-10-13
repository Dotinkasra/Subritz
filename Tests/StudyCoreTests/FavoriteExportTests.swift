import Foundation
import Testing
@testable import StudyCore

struct FavoriteExportTests {
  func word(_ surface: String, at date: Date, video: Video? = nil) throws -> FavoriteWord {
    var token = try CoreTests().parse("word_level")[0].tokens[0]
    token.surface = surface
    token.startTime = 65
    return FavoriteWord(token: token,
      entry: DictionaryEntry(definition: "自作詳細", shortGloss: "自作の意味, \"語義\"\n第二行"),
      video: video, savedAt: date)
  }
  func calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }
  @Test func dateRangeIncludesBothWholeDaysEvenAcrossDaylightSaving() throws {
    let calendar = calendar()
    let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
    let next = calendar.date(byAdding: .day, value: 1, to: start)!
    #expect(next.timeIntervalSince(start) == 23 * 3600)
    let words = try [word("before", at: start.addingTimeInterval(-1)), word("start", at: start),
      word("end", at: next.addingTimeInterval(-1)), word("after", at: next)]
    let export = FavoriteExport(range: .dates(start: start, end: start), calendar: calendar)
    #expect(try export.selected(from: words).map(\.surface) == ["end", "start"])
    #expect(throws: AppFailure.self) {
      try FavoriteExport(range: .dates(start: next, end: start), calendar: calendar).selected(from: words)
    }
  }
  @Test func latestCountSortsRegistrationDatesAndKeepsTiesStable() throws {
    let words = try [word("old", at: Date(timeIntervalSince1970: 1)),
      word("new", at: Date(timeIntervalSince1970: 3)),
      word("tie", at: Date(timeIntervalSince1970: 3))]
    #expect(try FavoriteExport(range: .latest(2)).selected(from: words).map(\.surface) == ["new", "tie"])
    #expect(try FavoriteExport(range: .latest(100)).selected(from: words).count == 3)
    #expect(throws: AppFailure.self) { try FavoriteExport(range: .latest(0)).selected(from: words) }
  }
  @Test func csvQuotesCellsAndEnumeratesOccurrencesWithoutDuplicatesOrUnrelatedRecords() throws {
    let source = Video(id: "fixtureA000", title: "Authored, \"A\"", duration: 100)
    let other = Video(id: "fixtureB000", title: "Authored B", duration: 4000)
    let word = try word("sample", at: Date(timeIntervalSince1970: 100), video: source)
    let one = VideoTimestamp(video: source, time: 65, kind: .favorite, wordID: word.id)
    let two = VideoTimestamp(video: other, time: 3601, kind: .favorite, wordID: word.id)
    let unrelated = VideoTimestamp(video: other, time: 2, kind: .favorite, wordID: "unrelated")
    let csv = try FavoriteExport(format: .csv, includeMetadata: true)
      .contents(words: [word], timestamps: [one, two, one, unrelated])
    #expect(!csv.contains(word.shortGloss) && !csv.contains(word.definition) && !csv.contains("日本語の意味"))
    #expect(csv.contains("Authored, \"\"A\"\" · 1:05"))
    #expect(csv.contains("Authored B · 1:00:01"))
    #expect(!csv.contains(" · 0:02"))
    #expect(csv.components(separatedBy: " · 1:05").count == 2)
    #expect(csv.hasSuffix("\r\n"))
  }
  @Test func metadataIsOptionalAndSourceOccurrenceSurvivesTrimmedTimestamp() throws {
    let video = Video(id: "fixtureA000", title: "Authored video", duration: 100)
    let word = try word("sample", at: Date(timeIntervalSince1970: 100), video: video)
    for format in FavoriteExportFormat.allCases {
      let plain = try FavoriteExport(format: format).contents(words: [word], timestamps: [])
      #expect(plain == (format == .text ? "sample\n" : "\"sample\"\r\n"))
      #expect(!plain.contains(video.title) && !plain.contains(video.watchURL) && !plain.contains("登録日時"))
      let metadata = try FavoriteExport(format: format, includeMetadata: true)
        .contents(words: [word], timestamps: [])
      #expect(metadata.contains(video.watchURL) && metadata.contains(video.title) && metadata.contains("1:05"))
      #expect(!metadata.contains(word.shortGloss) && !metadata.contains(word.definition) && !metadata.contains("自作の意味"))
    }
    #expect(try FavoriteExport().contents(words: [], timestamps: []).isEmpty)
  }
  @Test func wordsOnlyHaveOneRecordPerLineAndNoHeaderOrBlankSeparators() throws {
    let words = try [word("silver robot", at: Date(timeIntervalSince1970: 1)),
      word("signal", at: Date(timeIntervalSince1970: 2))]
    #expect(try FavoriteExport().contents(words: words, timestamps: []) == "signal\nsilver robot\n")
    #expect(try FavoriteExport(format: .csv).contents(words: words, timestamps: []) == "\"signal\"\r\n\"silver robot\"\r\n")
    let quoted = try word("a, \"phrase\"", at: Date())
    #expect(try FavoriteExport(format: .csv).contents(words: [quoted], timestamps: []) == "\"a, \"\"phrase\"\"\"\r\n")
  }
}
