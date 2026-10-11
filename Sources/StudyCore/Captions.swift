import Foundation
import NaturalLanguage

public struct CaptionPipeline {
  public static let parserVersion = 3, reconstructionVersion = 4
  public static let maxTokens = 40, maxSeconds: Double = 15
  public init() {}
  struct Segment: Decodable {
    var utf8: String?
    var tOffsetMs: Double?
  }
  struct Event: Decodable {
    var tStartMs: Double?
    var dDurationMs: Double?
    var segs: [Segment]?
  }
  struct Root: Decodable { var events: [Event] }
  public func parse(_ data: Data, videoID: String) throws -> [Sentence] {
    guard let root = try? JSONDecoder().decode(Root.self, from: data) else {
      throw AppFailure(.captionParseFailed, "字幕の JSON3 を解析できませんでした")
    }
    let events = root.events.filter {
      ($0.segs ?? []).contains {
        !clean($0.utf8 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    }.sorted {
      ($0.tStartMs ?? 0) < ($1.tStartMs ?? 0)
    }
    var stream: [Token] = []
    for (ei, event) in events.enumerated() {
      try Task.checkCancellation()
      let start = max(0, (event.tStartMs ?? 0) / 1000)
      let next =
        ei + 1 < events.count ? max(start, (events[ei + 1].tStartMs ?? 0) / 1000) : start + 2
      let estimated = (event.dDurationMs ?? 0) <= 0
      let displayEnd =
        start + (estimated ? max(0.1, next - start) : max(0.1, event.dDurationMs! / 1000))
      // Display duration can overlap the next utterance. Never distribute words/punctuation past it.
      let end = ei + 1 < events.count && next > start ? min(displayEnd, next) : displayEnd
      let segs = event.segs!.filter { !(clean($0.utf8 ?? "")).isEmpty }
      let allAnchored =
        segs.contains { $0.tOffsetMs != nil }
        && segs.enumerated().allSatisfy { $0.offset == 0 || $0.element.tOffsetMs != nil }
      var generated: [Token] = []
      if !allAnchored {
        generated = distribute(
          segs.map { clean($0.utf8 ?? "") }.joined(), start: start, end: end,
          quality: estimated ? .estimated : .interpolated)
      } else {
        for (si, seg) in segs.enumerated() {
          let a = min(end, max(start, start + (seg.tOffsetMs ?? 0) / 1000))
          let b =
            si + 1 < segs.count
            ? min(end, max(a + 0.01, start + (segs[si + 1].tOffsetMs ?? 0) / 1000)) : end
          var ts = distribute(
            clean(seg.utf8 ?? ""), start: a, end: max(a + 0.01, b), quality: .anchored)
          if ts.filter({ $0.lexical }).count == 1 {
            for k in ts.indices { ts[k].timingQuality = estimated ? .estimated : .exact }
          }
          generated += ts
        }
      }
      for i in generated.indices { generated[i].captionLineIndex = ei }
      let limit = min(stream.count, generated.count)
      var overlap = 0
      if limit > 0, start <= (stream.last?.endTime ?? 0) + 0.5 {
        for n in stride(from: limit, through: 1, by: -1) {
          if stream.suffix(n).map(\.normalized) == generated.prefix(n).map(\.normalized) {
            overlap = n
            break
          }
        }
      }
      stream += generated.dropFirst(overlap)
    }
    // Preserve transcript order. Sorting individual words by estimated times can
    // interleave neighboring caption events and corrupt both text and grammar.
    // Some real JSON3 segments share an anchor. Keep all words searchable and
    // preserve source ordering, lowering quality for adjusted anchors.
    for i in stream.indices where i > 0 {
      if stream[i].startTime < stream[i - 1].startTime + 0.001 {
        stream[i].startTime = stream[i - 1].startTime + 0.001
        stream[i].timingQuality = .estimated
      }
      stream[i].endTime = max(stream[i].endTime, stream[i].startTime + 0.001)
    }
    for i in stream.indices where i + 1 < stream.count {
      stream[i].endTime = max(
        stream[i].startTime + 0.001, min(stream[i].endTime, stream[i + 1].startTime))
    }
    guard !stream.isEmpty else {
      throw AppFailure(.unsupportedCaptionStructure, "利用可能な字幕テキストがありません")
    }
    var groups: [[Token]] = []
    var pending: [Token] = []
    func flush() {
      if !pending.isEmpty {
        groups.append(pending)
        pending = []
      }
    }
    for token in stream {
      if let last = pending.last, token.startTime - last.endTime > 1.2 { flush() }
      if let first = pending.first,
        pending.filter({ $0.lexical }).count >= Self.maxTokens
          || token.endTime - first.startTime > Self.maxSeconds
      {
        // Prefer the largest caption gap inside the safety window.
        if pending.count > 2,
          let cut = (1..<pending.count).max(by: {
            pending[$0].startTime - pending[$0 - 1].endTime < pending[$1].startTime
              - pending[$1 - 1].endTime
          }), pending[cut].startTime - pending[cut - 1].endTime > 0.15
        {
          groups.append(Array(pending.prefix(cut)))
          pending = Array(pending.dropFirst(cut))
        } else {
          // Keep a dangling determiner/preposition with the phrase in the next safety chunk.
          let dependent: Set<String> = [
            "my", "your", "our", "their", "the", "a", "an", "of", "to", "with", "about",
          ]
          var cut = pending.count
          while cut > max(1, pending.count - 4), dependent.contains(pending[cut - 1].normalized) {
            cut -= 1
          }
          if cut < pending.count {
            groups.append(Array(pending.prefix(cut)))
            pending = Array(pending.dropFirst(cut))
          } else {
            flush()
          }
        }
      }
      pending.append(token)
      if [".", "?", "!"].contains(token.surface) { flush() }
    }
    flush()
    return groups.enumerated().map { index, group in
      let id = UUID()
      var tokens = group
      for i in tokens.indices {
        tokens[i].sentenceID = id
        tokens[i].index = i
      }
      let text = tokens.reduce("") { result, t in
        result + (result.isEmpty || !t.lexical ? "" : " ") + t.surface
      }
      // POS and lemma need sentence context, not isolated caption words.
      let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
      tagger.string = text
      tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
      var search = text.startIndex
      for i in tokens.indices {
        if let range = text.range(of: tokens[i].surface, range: search..<text.endIndex) {
          search = range.upperBound
          if tokens[i].lexical {
            tokens[i].lemma =
              tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            tokens[i].partOfSpeech =
              tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0?.rawValue
          }
        }
      }
      return Sentence(
        id: id, videoID: videoID, index: index, text: text, startTime: tokens.first!.startTime,
        endTime: tokens.last!.endTime, tokens: tokens)
    }
  }
  func clean(_ value: String) -> String {
    var s = value.precomposedStringWithCanonicalMapping
    for (a, b) in [
      ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"),
      ("&nbsp;", " "),
    ] { s = s.replacingOccurrences(of: a, with: b) }
    s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    return s.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0)
        || CharacterSet.whitespacesAndNewlines.contains($0)
    }.map(String.init).joined().replacingOccurrences(
      of: "\\s+", with: " ", options: .regularExpression)
  }
  func distribute(_ text: String, start: Double, end: Double, quality: TimingQuality) -> [Token] {
    let regex = try! NSRegularExpression(
      pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}]+)*|[^\\s\\p{L}\\p{N}]")
    let words = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      Range($0.range, in: text).map { String(text[$0]) }
    }
    let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
    tagger.string = text
    tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
    let total = max(1, words.reduce(0) { $0 + max(1, $1.count) })
    let duration = max(0.001 * Double(words.count), end - start)
    var cursor = start
    var search = text.startIndex
    return words.enumerated().map { i, w in
      let lexical = w.rangeOfCharacter(from: .alphanumerics) != nil
      let range = text.range(of: w, range: search..<text.endIndex)
      var lemma: String?
      var pos: String?
      if let range {
        search = range.upperBound
        lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
        pos = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0?.rawValue
      }
      let a = cursor
      cursor += duration * Double(max(1, w.count)) / Double(total)
      return Token(
        index: i, surface: w, normalized: w.lowercased().precomposedStringWithCanonicalMapping,
        lemma: lemma, partOfSpeech: pos, startTime: a, endTime: cursor, timingQuality: quality,
        lexical: lexical)
    }
  }
}
public struct CaptionLine: Identifiable, Equatable {
  public var id: UUID
  public var index: Int
  public var tokens: [Token]
  public var startTime: Double { tokens.first?.startTime ?? 0 }
  public var endTime: Double { tokens.last?.endTime ?? startTime }
}
public struct Timeline {
  public let sentences: [Sentence]
  public let tokens: [Token]
  public let lines: [CaptionLine]
  public init(_ sentences: [Sentence]) {
    self.sentences = sentences
    tokens = sentences.flatMap(\.tokens).sorted { $0.startTime < $1.startTime }
    var groups: [[Token]] = []
    for token in tokens {
      if let last = groups.last?.last,
        (token.captionLineIndex != nil && token.captionLineIndex == last.captionLineIndex)
          || (token.captionLineIndex == nil && token.sentenceID == last.sentenceID)
      {
        groups[groups.count - 1].append(token)
      } else {
        groups.append([token])
      }
    }
    lines = groups.enumerated().map {
      CaptionLine(id: $0.element[0].id, index: $0.offset, tokens: $0.element)
    }
  }
  public func token(at time: Double) -> Token? {
    find(tokens, time: time, start: { $0.startTime }, end: { $0.endTime }).flatMap {
      $0.lexical ? $0 : nil
    }
  }
  public func sentence(at time: Double) -> Sentence? {
    find(sentences, time: time, start: { $0.startTime }, end: { $0.endTime })
  }
  public func line(at time: Double) -> CaptionLine? {
    find(lines, time: time, start: { $0.startTime }, end: { $0.endTime })
  }
  public func upcomingWords(at time: Double, limit: Int = 8) -> [Token] {
    var low = 0
    var high = tokens.count
    while low < high {
      let mid = (low + high) / 2
      if tokens[mid].startTime < time { low = mid + 1 } else { high = mid }
    }
    return Array(tokens[low...].lazy.filter(\.lexical).prefix(max(0, limit)))
  }
  private func find<T>(_ values: [T], time: Double, start: (T) -> Double, end: (T) -> Double) -> T?
  {
    var low = 0
    var high = values.count
    while low < high {
      let mid = (low + high) / 2
      if start(values[mid]) <= time { low = mid + 1 } else { high = mid }
    }
    guard low > 0, time < end(values[low - 1]) else { return nil }
    return values[low - 1]
  }
}

/// Parsing runs on a service actor, with cancellation inherited from its caller.
public actor CaptionService {
  public init() {}
  public func parse(_ data: Data, videoID: String) throws -> [Sentence] {
    try CaptionPipeline().parse(data, videoID: videoID)
  }
}
