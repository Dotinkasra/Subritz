import Foundation

public enum ListeningSource: String, CaseIterable, Codable, Sendable {
  case video, speech
  public var title: String { self == .video ? "動画" : "音声認識" }
}

public struct ListeningSpan: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let start: Date
  public var end: Date
  public let source: ListeningSource
  public var seconds: Double { end.timeIntervalSince(start) }
  public init(id: UUID = UUID(), start: Date, end: Date, source: ListeningSource) {
    self.id = id
    self.start = start
    self.end = end
    self.source = source
  }
}

/// Only timestamps and the input kind are retained, never captions or audio.
/// Checkpoints update stable IDs, so saving/retrying a checkpoint is idempotent.
public struct ListeningBuffer {
  private var current: ListeningSpan?
  private var dirty: [UUID: ListeningSpan] = [:]
  public init() {}
  public var hasChanges: Bool { !dirty.isEmpty }
  public mutating func append(_ interval: DateInterval, source: ListeningSource) {
    guard interval.duration.isFinite, interval.duration > 0 else { return }
    if var span = current, span.source == source,
      abs(span.end.timeIntervalSince(interval.start)) < 0.001
    {
      span.end = max(span.end, interval.end)
      current = span
    } else {
      current = ListeningSpan(start: interval.start, end: interval.end, source: source)
    }
    if let current { dirty[current.id] = current }
  }
  public mutating func drain() -> [ListeningSpan] {
    let result = Array(dirty.values)
    dirty.removeAll(keepingCapacity: true)
    return result
  }
  public mutating func restore(_ spans: [ListeningSpan]) {
    for span in spans where dirty[span.id].map({ $0.end < span.end }) ?? true {
      dirty[span.id] = span
    }
  }
}

public enum ListeningEvidence {
  public static func containsEnglish(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return false }
    // Caption annotations are not spoken English (e.g. [Music], [Applause]).
    if text.hasPrefix("["), text.hasSuffix("]") { return false }
    let annotation = text.trimmingCharacters(in: CharacterSet(charactersIn: "()♪♫ ")).lowercased()
    if annotation != text.lowercased(),
      ["music", "applause", "laughter", "laughing", "silence", "noise", "inaudible"].contains(
        annotation)
    {
      return false
    }
    return text.unicodeScalars.contains {
      (65...90).contains($0.value) || (97...122).contains($0.value)
    }
  }
  static func merged(_ ranges: [Range<Double>], gap: Double = 0) -> [Range<Double>] {
    var result: [Range<Double>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = result.last, range.lowerBound <= last.upperBound + gap {
        result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        result.append(range)
      }
    }
    return result
  }
}

public struct EnglishListeningCoverage {
  private let ranges: [Range<Double>]
  public init(lines: [CaptionLine]) {
    ranges = ListeningEvidence.merged(
      lines.compactMap { line in
        guard line.startTime.isFinite, line.endTime.isFinite, line.endTime > line.startTime,
          ListeningEvidence.containsEnglish(line.tokens.map(\.surface).joined(separator: " "))
        else { return nil }
        return line.startTime..<line.endTime
      })
  }
  public init(ranges: [Range<Double>]) {
    self.ranges = ListeningEvidence.merged(
      ranges.filter { $0.lowerBound.isFinite && $0.upperBound.isFinite })
  }
  public func intersections(from start: Double, to end: Double) -> [Range<Double>] {
    guard end > start else { return [] }
    var low = 0
    var high = ranges.count
    while low < high {
      let mid = (low + high) / 2
      if ranges[mid].upperBound <= start { low = mid + 1 } else { high = mid }
    }
    var result: [Range<Double>] = []
    while low < ranges.count, ranges[low].lowerBound < end {
      result.append(max(start, ranges[low].lowerBound)..<min(end, ranges[low].upperBound))
      low += 1
    }
    return result
  }
}

public struct ListeningPlaybackSample: Sendable {
  public let mediaTime: Double
  public let uptime: Double
  public let date: Date
  public let state: Int
  public let rate: Double
  public let audible: Bool
  public init(
    mediaTime: Double, uptime: Double, date: Date, state: Int, rate: Double, audible: Bool
  ) {
    self.mediaTime = mediaTime
    self.uptime = uptime
    self.date = date
    self.state = state
    self.rate = rate
    self.audible = audible
  }
}

/// Uses authoritative iframe samples, not the interpolated display clock.
public struct PlaybackListeningTracker {
  private var previous: ListeningPlaybackSample?
  public private(set) var isCounting = false
  public init() {}
  public mutating func reset() {
    previous = nil
    isCounting = false
  }
  public mutating func consume(
    _ sample: ListeningPlaybackSample, coverage: EnglishListeningCoverage
  ) -> [DateInterval] {
    guard sample.mediaTime.isFinite, sample.uptime.isFinite, sample.rate.isFinite,
      sample.rate > 0, sample.date.timeIntervalSince1970.isFinite
    else {
      reset()
      return []
    }
    guard let last = previous else {
      previous = sample
      isCounting = false
      return []
    }
    let elapsed = sample.uptime - last.uptime
    // Keep the last progress sample through coarse/duplicate player timestamps.
    if sample.mediaTime == last.mediaTime, sample.state == last.state,
      sample.audible == last.audible, sample.rate == last.rate, elapsed < 5
    {
      return []
    }
    previous = sample
    isCounting = false
    let progress = sample.mediaTime - last.mediaTime
    guard last.state == 1, sample.state == 1, last.audible, sample.audible,
      last.rate == sample.rate, elapsed > 0, elapsed <= 5, progress > 0,
      abs(progress - elapsed * sample.rate) <= max(0.35, elapsed * sample.rate * 0.2)
    else { return [] }
    let wallStart = sample.date.addingTimeInterval(-elapsed)
    let intervals = coverage.intersections(from: last.mediaTime, to: sample.mediaTime).map { range in
      let start = wallStart.addingTimeInterval(
        (range.lowerBound - last.mediaTime) / progress * elapsed)
      let end = wallStart.addingTimeInterval(
        (range.upperBound - last.mediaTime) / progress * elapsed)
      return DateInterval(start: start, end: end)
    }
    isCounting = !intervals.isEmpty
    return intervals
  }
}

/// A progressive recognition result may repeat or revise the same audio range.
/// Count each range once per capture run, independently of transcript caching.
public struct SpeechListeningTracker {
  private var covered: [Range<Double>] = []
  private var discardedThrough: Double = 0
  public init() {}
  public mutating func reset() {
    covered.removeAll(keepingCapacity: true)
    discardedThrough = 0
  }
  public mutating func consume(_ update: LiveSpeechUpdate, receivedAt date: Date) -> [DateInterval]
  {
    guard update.start.isFinite, update.end.isFinite, update.start >= 0, update.end > update.start,
      ListeningEvidence.containsEnglish(update.text)
    else { return [] }
    let validWords = update.words.filter {
      $0.start.isFinite && $0.end.isFinite && $0.start >= update.start
        && $0.end <= update.end + 0.01 && $0.end > $0.start
    }
    let ranges: [Range<Double>]
    if validWords.isEmpty {
      ranges = [update.start..<update.end]
    } else {
      ranges = ListeningEvidence.merged(
        validWords.filter { ListeningEvidence.containsEnglish($0.text) }
          .map { $0.start..<$0.end }, gap: 0.75)
    }
    var added: [Range<Double>] = []
    for proposed in ranges where proposed.upperBound > discardedThrough {
      let range = max(proposed.lowerBound, discardedThrough)..<proposed.upperBound
      var cursor = range.lowerBound
      for old in covered where old.upperBound > cursor && old.lowerBound < range.upperBound {
        if old.lowerBound > cursor { added.append(cursor..<min(old.lowerBound, range.upperBound)) }
        cursor = max(cursor, old.upperBound)
        if cursor >= range.upperBound { break }
      }
      if cursor < range.upperBound { added.append(cursor..<range.upperBound) }
    }
    covered = ListeningEvidence.merged(covered + ranges)
    // Keep correction/deduplication work bounded during all-day recognition.
    // Older late callbacks are ignored rather than counted a second time.
    discardedThrough = max(discardedThrough, update.end - 120)
    covered = covered.compactMap {
      $0.upperBound > discardedThrough ? max($0.lowerBound, discardedThrough)..<$0.upperBound : nil
    }
    // Recognition latency affects placement by a small amount, not duration.
    // Anchoring to receipt avoids attributing sleep/permission wait to listening.
    return added.map {
      DateInterval(
        start: date.addingTimeInterval($0.lowerBound - update.end),
        end: date.addingTimeInterval($0.upperBound - update.end))
    }
  }
}

public enum ListeningPeriod: String, CaseIterable, Identifiable, Sendable {
  case year, month, week, day
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .year: return "年"
    case .month: return "月"
    case .week: return "週"
    case .day: return "日"
    }
  }
  public var component: Calendar.Component {
    switch self {
    case .year: return .year
    case .month: return .month
    case .week: return .weekOfYear
    case .day: return .day
    }
  }
}

public struct ListeningTimeBin: Identifiable, Sendable, Equatable {
  public var id: Date { start }
  public let start: Date
  public let end: Date
  public var videoSeconds: Double = 0
  public var speechSeconds: Double = 0
  public var total: Double { videoSeconds + speechSeconds }
  public init(start: Date, end: Date) {
    self.start = start
    self.end = end
  }
}

public struct ListeningCalendarRange: Sendable {
  public let interval: DateInterval
  public let bins: [ListeningTimeBin]
  public init(period: ListeningPeriod, anchor: Date, calendar: Calendar = .current) {
    interval = calendar.dateInterval(of: period.component, for: anchor)!
    let step: Calendar.Component = period == .year ? .month : period == .day ? .hour : .day
    var bins: [ListeningTimeBin] = []
    var date = interval.start
    while date < interval.end {
      guard let next = calendar.date(byAdding: step, value: 1, to: date), next > date else { break }
      let end = min(next, interval.end)
      bins.append(ListeningTimeBin(start: date, end: end))
      date = end
    }
    self.bins = bins
  }
}

extension LibraryStore {
  public func saveListeningSpans(_ spans: [ListeningSpan]) throws {
    guard !spans.isEmpty else { return }
    try db.execute("BEGIN IMMEDIATE")
    do {
      for span in spans {
        guard span.start.timeIntervalSince1970.isFinite, span.end.timeIntervalSince1970.isFinite,
          span.seconds.isFinite, span.seconds > 0
        else { throw AppFailure("視聴時間の記録が正しくありません") }
        try db.execute(
          "INSERT INTO listening_spans(id,started,ended,source) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET ended=MAX(ended,excluded.ended)",
          values: [
            span.id.uuidString, String(span.start.timeIntervalSince1970),
            String(span.end.timeIntervalSince1970), span.source.rawValue,
          ])
      }
      try db.execute("COMMIT")
    } catch {
      try? db.execute("ROLLBACK")
      throw error
    }
  }
  public func listeningTotals(in range: ListeningCalendarRange) throws -> [ListeningTimeBin] {
    try range.bins.map { bin in
      var result = bin
      let rows = try db.rows(
        "SELECT source,SUM(MIN(ended,CAST(? AS REAL))-MAX(started,CAST(? AS REAL))) FROM listening_spans WHERE started < ? AND ended > ? GROUP BY source",
        values: [
          String(bin.end.timeIntervalSince1970), String(bin.start.timeIntervalSince1970),
          String(bin.end.timeIntervalSince1970), String(bin.start.timeIntervalSince1970),
        ])
      for row in rows {
        if row[0] == ListeningSource.video.rawValue { result.videoSeconds = Double(row[1]) ?? 0 }
        if row[0] == ListeningSource.speech.rawValue { result.speechSeconds = Double(row[1]) ?? 0 }
      }
      return result
    }
  }
}
