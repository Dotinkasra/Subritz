import AppKit
import StudyCore
import SwiftUI

/// Display rows reuse the original Token values, including IDs, timing and
/// sentence-local grammar indexes. Timeline and search keep their source lines.
struct SubtitleReflow {
  var rows: [CaptionLine] = []
  var tokenRows: [UUID: Int] = [:]
  var tokenSourceLines: [UUID: UUID] = [:]
  func rowID(containing token: UUID?) -> UUID? {
    guard let token, let index = tokenRows[token], rows.indices.contains(index) else { return nil }
    return rows[index].id
  }
  static func build(
    lines: [CaptionLine], width: Double, maximumCharacters: Int,
    measure: (Token) -> Double
  ) throws -> Self {
    var result = Self()
    var pending: [Token] = []
    var usedWidth = 0.0
    var usedCharacters = 0
    let width = max(1, width)
    func finish() {
      guard let first = pending.first else { return }
      let index = result.rows.count
      result.rows.append(CaptionLine(id: first.id, index: index, tokens: pending))
      for token in pending { result.tokenRows[token.id] = index }
      pending.removeAll(keepingCapacity: true)
      usedWidth = 0
      usedCharacters = 0
    }
    var previousWasAnnotation = false
    var lastEnd: Double?
    var scanned = 0
    for source in lines {
      let annotation = !ListeningEvidence.containsEnglish(
        source.tokens.map(\.surface).joined(separator: " "))
      if annotation || previousWasAnnotation { finish() }
      for token in source.tokens {
        scanned += 1
        if scanned % 128 == 0 { try Task.checkCancellation() }
        result.tokenSourceLines[token.id] = source.id
        if let lastEnd, token.startTime - lastEnd > 2 { finish() }
        let tokenWidth = max(1, measure(token))
        let separator = pending.isEmpty ? 0 : 1
        let budgetExceeded =
          maximumCharacters != Int.max
          && usedCharacters + separator + token.surface.count > maximumCharacters
        if !pending.isEmpty && (usedWidth + 5 + tokenWidth > width || budgetExceeded) { finish() }
        usedWidth += (pending.isEmpty ? 0 : 5) + tokenWidth
        usedCharacters += (pending.isEmpty ? 0 : 1) + token.surface.count
        pending.append(token)
        lastEnd = token.endTime
      }
      if annotation { finish() }
      previousWasAnnotation = annotation
    }
    finish()
    return result
  }
}

/// Font measurement and regrouping never run on the UI actor. Repeated slider
/// updates cancel obsolete passes, and width/character changes reuse glyph widths.
actor SubtitleReflowEngine {
  private var scale: Double?
  private var widths: [String: Double] = [:]
  func build(
    lines: [CaptionLine], width: Double, characters: Int, fontScale: Double,
    grammar: Bool
  ) throws -> SubtitleReflow {
    if scale != fontScale {
      scale = fontScale
      widths.removeAll(keepingCapacity: true)
    }
    let font = NSFont.systemFont(
      ofSize: SubtitleAppearance.fontSize(current: true, scale: fontScale), weight: .medium)
    let limit = characters == SubtitleAppearance.characterRange.upperBound ? Int.max : characters
    return try SubtitleReflow.build(lines: lines, width: width, maximumCharacters: limit) { token in
      let wordWidth: Double
      if let cached = widths[token.surface] {
        wordWidth = cached
      } else {
        wordWidth = ceil((token.surface as NSString).size(withAttributes: [.font: font]).width) + 4
        if widths.count >= 8192 { widths.removeAll(keepingCapacity: true) }
        widths[token.surface] = wordWidth
      }
      return grammar ? max(40, wordWidth) : wordWidth
    }
  }
}

@MainActor final class SubtitleDisplayState: ObservableObject {
  @Published private(set) var layout = SubtitleReflow()
  @Published private(set) var revision = 0
  private let engine = SubtitleReflowEngine()
  private var session: UUID?
  func rebuild(
    lines: [CaptionLine], width: Double, characters: Int, fontScale: Double, grammar: Bool,
    session: UUID
  ) async {
    guard !Task.isCancelled else { return }
    if self.session != session {
      self.session = session
      layout = SubtitleReflow()
    }
    do {
      let result = try await engine.build(
        lines: lines, width: width, characters: characters, fontScale: fontScale, grammar: grammar)
      guard !Task.isCancelled, self.session == session else { return }
      layout = result
      revision &+= 1
    } catch is CancellationError {} catch {
      assertionFailure("Subtitle display layout failed: \(error)")
    }
  }
}
