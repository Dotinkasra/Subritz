import Foundation
import StudyCore

extension StudyModel {
  var subtitleFontScale: Double {
    isLiveSpeech ? settings.liveSubtitleFontScale : settings.subtitleFontScale
  }
  var subtitleWrapCharacters: Int {
    isLiveSpeech ? settings.liveSubtitleWrapCharacters : settings.subtitleWrapCharacters
  }
  func setSubtitleFontScale(_ value: Double) {
    guard value.isFinite else { return }
    let value = SubtitleAppearance.clampedFontScale(value)
    guard value != subtitleFontScale else { return }
    if isLiveSpeech {
      settings.liveSubtitleFontScale = value
    } else {
      settings.subtitleFontScale = value
    }
    persistLayoutSettings()
  }
  func setSubtitleWrapCharacters(_ value: Double) {
    guard value.isFinite else { return }
    let value = SubtitleAppearance.clampedCharacters(Int(min(140, max(20, value)).rounded()))
    guard value != subtitleWrapCharacters else { return }
    if isLiveSpeech {
      settings.liveSubtitleWrapCharacters = value
    } else {
      settings.subtitleWrapCharacters = value
    }
    persistLayoutSettings()
  }
  func setWorkspaceLayout(upper: Double? = nil, leading: Double? = nil) {
    if let upper, upper.isFinite { settings.workspaceUpperFraction = min(0.95, max(0.05, upper)) }
    if let leading, leading.isFinite {
      settings.workspaceLeadingFraction = min(0.95, max(0.05, leading))
    }
    persistLayoutSettings()
  }
  func resetWorkspaceLayout() {
    let initial = AppSettings()
    settings.workspaceUpperFraction = initial.workspaceUpperFraction
    settings.workspaceLeadingFraction = initial.workspaceLeadingFraction
    settings.subtitleRowSpacing = initial.subtitleRowSpacing
    settings.liveSubtitleRowSpacing = initial.liveSubtitleRowSpacing
    settings.subtitleWrapCharacters = initial.subtitleWrapCharacters
    settings.liveSubtitleWrapCharacters = initial.liveSubtitleWrapCharacters
    settings.subtitleFontScale = initial.subtitleFontScale
    settings.liveSubtitleFontScale = initial.liveSubtitleFontScale
    persistLayoutSettings()
  }
  private func persistLayoutSettings() {
    // Don't save unrelated, unfinished edits in the Settings window.
    var saved = AppSettings.load(defaults: defaults)
    saved.workspaceUpperFraction = settings.workspaceUpperFraction
    saved.workspaceLeadingFraction = settings.workspaceLeadingFraction
    saved.subtitleRowSpacing = settings.subtitleRowSpacing
    saved.liveSubtitleRowSpacing = settings.liveSubtitleRowSpacing
    saved.subtitleWrapCharacters = settings.subtitleWrapCharacters
    saved.liveSubtitleWrapCharacters = settings.liveSubtitleWrapCharacters
    saved.subtitleFontScale = settings.subtitleFontScale
    saved.liveSubtitleFontScale = settings.liveSubtitleFontScale
    saved.save(defaults: defaults)
  }
}
