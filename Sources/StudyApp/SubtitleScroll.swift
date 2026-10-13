import Foundation

extension StudyModel {
  func toggleSubtitleScrollPin(at lineID: UUID? = nil) {
    guard ready else { return }
    subtitleScrollPinned.toggle()
    if subtitleScrollPinned {
      let selected = lineID.flatMap { id in subtitleLines.contains(where: { $0.id == id }) ? id : nil }
      subtitlePinnedLineID = selected ?? (
        subtitleLines.indices.contains(currentLineIndex) ? subtitleLines[currentLineIndex].id : nil)
    } else { subtitlePinnedLineID = nil }
  }

  /// Only controls the viewport. Playback, highlighting and dictionary updates keep running.
  func subtitleFollowLineID(ignoringSearch: Bool = false) -> UUID? {
    guard !subtitleScrollPinned, !draggingDictionarySelection,
      ignoringSearch || !browsingSubtitleSearch,
      subtitleLines.indices.contains(currentLineIndex) else { return nil }
    return subtitleLines[currentLineIndex].id
  }
}
