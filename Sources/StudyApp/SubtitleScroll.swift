import Foundation
import StudyCore

extension StudyModel {
  var subtitleRowSpacing: Double {
    isLiveSpeech ? settings.liveSubtitleRowSpacing : settings.subtitleRowSpacing
  }
  func setSubtitleRowSpacing(_ value: Double) {
    guard value.isFinite else { return }
    let value = min(1, max(0, value))
    guard value != subtitleRowSpacing else { return }
    if isLiveSpeech { settings.liveSubtitleRowSpacing = value }
    else { settings.subtitleRowSpacing = value }
    var saved = AppSettings.load(defaults: defaults)
    if isLiveSpeech { saved.liveSubtitleRowSpacing = value }
    else { saved.subtitleRowSpacing = value }
    saved.save(defaults: defaults)
  }

  func toggleSubtitleScrollPin(at lineID: UUID? = nil) {
    guard ready else { return }
    subtitleScrollPinned.toggle()
    if subtitleScrollPinned {
      let selected = lineID.flatMap { id in subtitleLines.contains(where: { $0.id == id }) ? id : nil }
      subtitlePinnedLineID = selected ?? (
        subtitleLines.indices.contains(currentLineIndex) ? subtitleLines[currentLineIndex].id : nil)
    } else {
      subtitlePinnedLineID = nil
      if isLiveSpeech { liveSubtitleAutoFollow = true }
    }
  }

  /// Geometry changes from recognition/layout must not look like manual scrolling.
  /// Upward user movement releases following; reaching the bottom restores it.
  func updateLiveSubtitleScroll(previousOffset: Double, offset: Double,
    bottomDistance: Double, userInitiated: Bool) {
    guard isLiveSpeech, userInitiated, !subtitleScrollPinned,
      !browsingSubtitleSearch, !draggingDictionarySelection,
      previousOffset.isFinite, offset.isFinite, bottomDistance.isFinite else { return }
    if bottomDistance <= 2 {
      if !liveSubtitleAutoFollow { liveSubtitleAutoFollow = true }
    } else if offset < previousOffset - 0.5 {
      if liveSubtitleAutoFollow { liveSubtitleAutoFollow = false }
    }
  }

  /// Only controls the viewport. Playback, highlighting and dictionary updates keep running.
  var followsLiveSubtitles: Bool {
    isLiveSpeech && subtitleFollowLineID() != nil
  }
  var liveSubtitleFollowRevision: Int? { followsLiveSubtitles ? liveSubtitleRevision : nil }

  func subtitleFollowLineID(ignoringSearch: Bool = false) -> UUID? {
    guard !subtitleScrollPinned, !draggingDictionarySelection,
      ignoringSearch || !browsingSubtitleSearch else { return nil }
    if isLiveSpeech { return liveSubtitleAutoFollow ? subtitleLines.last?.id : nil }
    guard subtitleLines.indices.contains(currentLineIndex) else { return nil }
    return subtitleLines[currentLineIndex].id
  }
}
