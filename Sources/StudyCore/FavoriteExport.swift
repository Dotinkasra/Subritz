import Foundation

public enum FavoriteExportFormat: String, CaseIterable, Sendable {
  case text, csv
  public var fileExtension: String { self == .text ? "txt" : "csv" }
}

public enum FavoriteExportRange: Sendable {
  case all
  case dates(start: Date, end: Date)
  case latest(Int)
}

/// Exports a snapshot of the user's library, without modifying its saved records.
public struct FavoriteExport: Sendable {
  public var format: FavoriteExportFormat
  public var range: FavoriteExportRange
  public var includeMetadata: Bool
  public var calendar: Calendar

  public init(format: FavoriteExportFormat = .text, range: FavoriteExportRange = .all,
    includeMetadata: Bool = false, calendar: Calendar = .current) {
    self.format = format
    self.range = range
    self.includeMetadata = includeMetadata
    self.calendar = calendar
  }

  public func selected(from words: [FavoriteWord]) throws -> [FavoriteWord] {
    // Retain the library's order for equal registration dates.
    let sorted = words.enumerated().sorted {
      $0.element.savedAt == $1.element.savedAt ? $0.offset < $1.offset
        : $0.element.savedAt > $1.element.savedAt
    }.map(\.element)
    switch range {
    case .all: return sorted
    case .latest(let count):
      guard count > 0 else { throw AppFailure("件数は1以上を指定してください。") }
      return Array(sorted.prefix(count))
    case .dates(let start, let end):
      let lower = calendar.startOfDay(for: start)
      let endDay = calendar.startOfDay(for: end)
      guard lower <= endDay else { throw AppFailure("終了日は開始日以降を指定してください。") }
      guard let upper = calendar.date(byAdding: .day, value: 1, to: endDay) else {
        throw AppFailure("指定された日付を読み取れませんでした。")
      }
      return sorted.filter { $0.savedAt >= lower && $0.savedAt < upper }
    }
  }

  public func contents(words: [FavoriteWord], timestamps: [VideoTimestamp]) throws -> String {
    let selected = try selected(from: words)
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss XXX"
    let occurrences = Dictionary(grouping: timestamps.filter { $0.kind == .favorite && $0.wordID != nil },
      by: { $0.wordID! })
    let rows = selected.map { word -> [String] in
      var row = [word.surface.split(whereSeparator: \.isWhitespace).joined(separator: " ")]
      if includeMetadata {
        var places = (occurrences[word.id] ?? []).filter { $0.time.isFinite && $0.time >= 0 }
          .sorted { $0.savedAt > $1.savedAt }
        // The source survives even if its timestamp was removed by the 1000-record limit.
        if let video = word.sourceVideo, word.sourceTime.isFinite, word.sourceTime >= 0,
          !places.contains(where: { $0.video.id == video.id && $0.time == word.sourceTime }) {
          places.append(VideoTimestamp(video: video, time: word.sourceTime,
            kind: .favorite, wordID: word.id, savedAt: word.savedAt))
        }
        var seen = Set<String>()
        let descriptions = places.filter {
          seen.insert($0.video.id + "\u{0}" + String($0.time)).inserted
        }.map { $0.video.title + " · " + PlaybackTime.format($0.time) + " · " + $0.videoURL }
        row += [formatter.string(from: word.savedAt), word.sourceVideo?.title ?? "",
          word.sourceVideo?.watchURL ?? "", descriptions.joined(separator: "\n")]
      }
      return row
    }
    let headers = ["単語"] + (includeMetadata
      ? ["登録日時", "登録動画タイトル", "登録動画URL", "出現箇所（タイトル・時刻・URL）"] : [])
    switch format {
    case .csv:
      // RFC 4180 quoting preserves commas, quotes and multiple occurrence lines in one cell.
      let records = includeMetadata ? [headers] + rows : rows
      return records.map { $0.map(Self.csvCell).joined(separator: ",") }
        .joined(separator: "\r\n") + (records.isEmpty ? "" : "\r\n")
    case .text:
      return rows.map { row in
        var lines = [row[0]]
        if includeMetadata {
          lines += ["登録日時: " + row[1], "登録動画: " + row[2], "登録動画URL: " + row[3]]
          if !row[4].isEmpty { lines.append("出現箇所:\n" + row[4]) }
        }
        return lines.joined(separator: "\n")
      }.joined(separator: includeMetadata ? "\n\n" : "\n") + (rows.isEmpty ? "" : "\n")
    }
  }

  private static func csvCell(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
