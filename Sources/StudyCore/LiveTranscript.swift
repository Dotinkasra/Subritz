import Foundation

public enum SpeechAudioSource: String, Codable, CaseIterable, Sendable {
  case system, microphone
  public var title: String { self == .system ? "Macの再生音" : "マイク" }
}

public struct LiveSpeechWord: Sendable, Equatable {
  public var text: String
  public var start: Double
  public var end: Double
  public init(text: String, start: Double, end: Double) {
    self.text = text; self.start = start; self.end = end
  }
}

public struct LiveSpeechUpdate: Sendable, Equatable {
  public var text: String
  public var start: Double
  public var end: Double
  public var isFinal: Bool
  public var words: [LiveSpeechWord]
  public init(text: String, start: Double, end: Double, isFinal: Bool,
    words: [LiveSpeechWord] = []) {
    self.text = text; self.start = start; self.end = end
    self.isFinal = isFinal; self.words = words
  }
  public func offset(by seconds: Double) -> Self {
    Self(text: text, start: start + seconds, end: end + seconds, isFinal: isFinal,
      words: words.map { LiveSpeechWord(text: $0.text, start: $0.start + seconds, end: $0.end + seconds) })
  }
}

public struct LiveTranscriptSegment: Identifiable {
  public let id: UUID
  public let ordinal: Int
  public let update: LiveSpeechUpdate
  public let sentences: [Sentence]
  public var byteCount: Int { update.text.utf8.count }
}

public struct LiveTranscriptSession: Identifiable {
  public let id: UUID
  public let startedAt: Date
  public let source: SpeechAudioSource
  public fileprivate(set) var segments: [LiveTranscriptSegment] = []
  fileprivate var nextOrdinal = 0
  public var byteCount: Int { segments.reduce(0) { $0 + $1.byteCount } }
  public var endTime: Double { segments.last?.update.end ?? 0 }
  public var document: StudyDocument {
    var sentences = segments.flatMap(\.sentences)
    for index in sentences.indices { sentences[index].index = index }
    return StudyDocument(video: Video(id: "live-" + id.uuidString,
      title: "リアルタイム音声認識", duration: endTime), rawCaption: Data(), sentences: sentences)
  }
}

/// App-session-only English text. No file, UserDefaults, or audio recording is
/// created. The limit counts UTF-8 transcript bytes, not the process's RAM.
public struct LiveTranscriptCache {
  public private(set) var sessions: [LiveTranscriptSession] = []
  public private(set) var limitBytes: Int
  public var byteCount: Int { sessions.reduce(0) { $0 + $1.byteCount } }
  public init(limitBytes: Int) { self.limitBytes = max(1, limitBytes) }
  @discardableResult public mutating func begin(source: SpeechAudioSource, at date: Date = Date()) -> UUID {
    let session = LiveTranscriptSession(id: UUID(), startedAt: date, source: source)
    // Empty sessions have no useful cached content; bound their metadata too.
    sessions.removeAll { $0.segments.isEmpty }
    sessions.append(session)
    return session.id
  }
  public func session(_ id: UUID) -> LiveTranscriptSession? { sessions.first { $0.id == id } }
  public mutating func activate(_ id: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
    let session = sessions.remove(at: index)
    sessions.append(session)
  }
  public mutating func setLimit(_ bytes: Int) { limitBytes = max(1, bytes); trim() }
  public mutating func removeAll() { sessions.removeAll() }

  @discardableResult public mutating func apply(_ update: LiveSpeechUpdate, to id: UUID) throws -> Bool {
    guard let index = sessions.firstIndex(where: { $0.id == id }),
      update.start.isFinite, update.end.isFinite, update.start >= 0, update.end > update.start,
      !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    let old = sessions[index].segments
    let overlaps: (LiveTranscriptSegment) -> Bool = {
      abs($0.update.start - update.start) < 0.001
        || ($0.update.start < update.end && update.start < $0.update.end)
    }
    // A late volatile result must never undo an already finalized range.
    if old.contains(where: { overlaps($0) && $0.update.isFinal }) { return false }
    let previous = old.first(where: overlaps)
    if previous?.update == update { return false }
    let ordinal = previous?.ordinal ?? sessions[index].nextOrdinal
    let sentences = try Self.parse(update, videoID: "live-" + id.uuidString,
      ordinal: ordinal, previous: previous?.sentences ?? [])
    sessions[index].segments.removeAll(where: overlaps)
    sessions[index].segments.append(LiveTranscriptSegment(id: previous?.id ?? UUID(),
      ordinal: ordinal, update: update, sentences: sentences))
    sessions[index].segments.sort { $0.update.start < $1.update.start }
    sessions[index].nextOrdinal = max(sessions[index].nextOrdinal, ordinal + 1)
    trim()
    return true
  }

  private mutating func trim() {
    var excess = byteCount - limitBytes
    for index in sessions.indices where excess > 0 {
      while excess > 0, let first = sessions[index].segments.first {
        excess -= first.byteCount
        sessions[index].segments.removeFirst()
      }
    }
    // Retain the newest empty session so recognition can continue after eviction.
    if let lastID = sessions.last?.id {
      sessions.removeAll { $0.id != lastID && $0.segments.isEmpty }
    }
  }

  private static func parse(_ update: LiveSpeechUpdate, videoID: String, ordinal: Int,
    previous: [Sentence]) throws -> [Sentence] {
    let words = update.words.filter {
      !$0.text.isEmpty && $0.start.isFinite && $0.end.isFinite
        && $0.start >= update.start && $0.end <= update.end + 0.01 && $0.end > $0.start
    }
    let segments: [[String: Any]] = words.isEmpty || words.map(\.text).joined() != update.text
      ? [["utf8": update.text]]
      : words.map { ["utf8": $0.text, "tOffsetMs": ($0.start - update.start) * 1000] }
    let data = try JSONSerialization.data(withJSONObject: ["events": [[
      "tStartMs": update.start * 1000, "dDurationMs": (update.end - update.start) * 1000, "segs": segments,
    ]]])
    var sentences = try CaptionPipeline().parse(data, videoID: videoID)
    let oldTokens = previous.flatMap(\.tokens)
    var tokenIndex = 0
    for index in sentences.indices {
      if previous.indices.contains(index) { sentences[index].id = previous[index].id }
      for j in sentences[index].tokens.indices {
        if oldTokens.indices.contains(tokenIndex),
          oldTokens[tokenIndex].surface == sentences[index].tokens[j].surface {
          sentences[index].tokens[j].id = oldTokens[tokenIndex].id
        }
        sentences[index].tokens[j].sentenceID = sentences[index].id
        sentences[index].tokens[j].captionLineIndex = ordinal
        tokenIndex += 1
      }
    }
    return sentences
  }
}
