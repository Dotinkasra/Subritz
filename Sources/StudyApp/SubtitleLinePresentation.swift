import Foundation
import StudyCore

// LazyVStack may retain previously visited rows. Those rows must not subscribe
// to the complete study model or rebuild their word views on unrelated changes.
// This value contains only the visible state belonging to one caption row.
struct SubtitleLinePresentation: Equatable {
  let session: UUID
  let current: Bool
  let emphasized: Set<UUID>
  let selected: Set<UUID>
  let searchRanges: [UUID: [NSRange]]
  let activeSearchRanges: [UUID: [NSRange]]
  let grammarEnabled: Bool
  let analyses: [UUID: Analysis]
  let currentSentence: Sentence?

  @MainActor init(model: StudyModel, line: CaptionLine) {
    session = model.session
    current = line.index == model.currentLineIndex
    let ids = Set(line.tokens.map(\.id))
    var highlighted = Set(model.resolvedExpression?.tokens.map(\.id) ?? [])
    if let id = model.currentToken?.id { highlighted.insert(id) }
    emphasized = highlighted.intersection(ids)
    selected = Set(line.tokens.filter { model.dictionarySelectionContains($0) }.map(\.id))
    searchRanges = Dictionary(uniqueKeysWithValues: line.tokens.compactMap { token in
      model.subtitleSearchResults.highlights[token.id].map { (token.id, $0) }
    })
    var active: [UUID: [NSRange]] = [:]
    for fragment in model.currentSubtitleSearchMatch?.fragments ?? [] where ids.contains(fragment.tokenID) {
      active[fragment.tokenID, default: []].append(fragment.range)
    }
    activeSearchRanges = active
    grammarEnabled = model.grammarEnabledForVideo && abs(line.index - model.currentLineIndex) <= 1
    if grammarEnabled {
      let owners = Set(line.tokens.map(\.sentenceID))
      analyses = Dictionary(uniqueKeysWithValues: (model.document?.sentences ?? []).compactMap {
        guard owners.contains($0.id), let analysis = $0.grammarAnalysis else { return nil }
        return ($0.id, analysis)
      })
    } else { analyses = [:] }
    currentSentence = grammarEnabled && current ? model.currentSentence : nil
  }
}
