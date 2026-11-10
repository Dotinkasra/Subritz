import Foundation
import SwiftUI
import Testing

@testable import StudyApp
@testable import StudyCore

@MainActor struct SubtitleLayoutTests {
  @Test func wrapUsesBothCharacterBudgetAndWindowWidth() {
    let sizes = Array(repeating: CGSize(width: 40, height: 20), count: 5)
    let wide = FlowLayout.pack(
      sizes: sizes, characters: [4, 4, 4, 4, 4], width: 300, maximumCharacters: 10, spacing: 5)
    #expect(
      wide.points == [
        CGPoint(x: 0, y: 0), CGPoint(x: 45, y: 0), CGPoint(x: 0, y: 25), CGPoint(x: 45, y: 25),
        CGPoint(x: 0, y: 50),
      ])
    let narrow = FlowLayout.pack(
      sizes: sizes, characters: [4, 4, 4, 4, 4], width: 80, maximumCharacters: 140, spacing: 5)
    #expect(narrow.points.map(\.x) == [0, 0, 0, 0, 0])
    #expect(narrow.size.height == 120 && narrow.size.width == 80)
    let expanded = FlowLayout.pack(
      sizes: sizes, characters: [4, 4, 4, 4, 4], width: 300, maximumCharacters: 140, spacing: 5)
    #expect(expanded.size.height == 20)
  }
  @Test func appearanceChangesInvalidateRowsButPreservePlaybackPinSearchAndOtherPreferences() throws
  {
    let fixture = try SubtitleSearchInteractionTests().fixture()
    let (model, defaults, suite) = try SettingsLifecycleTests().isolatedModel()
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    model.document = fixture.document
    model.timeline = fixture.timeline
    model.ready = true
    model.grammarEnabledForVideo = false
    model.toggleSubtitleScrollPin(at: model.subtitleLines[1].id)
    model.openSubtitleSearch()
    model.setSubtitleSearchQuery("robot")
    let before = model.subtitleLines.map { SubtitleLinePresentation(model: model, line: $0) }
    let time = model.time
    let pinned = model.subtitlePinnedLineID
    model.settings.timeout = 0  // An unfinished unrelated edit must stay unsaved.
    model.setSubtitleFontScale(1.2)
    model.setSubtitleWrapCharacters(60)
    let after = model.subtitleLines.map { SubtitleLinePresentation(model: model, line: $0) }
    #expect(zip(before, after).allSatisfy { $0 != $1 })
    #expect(after.allSatisfy { $0.fontScale == 1.2 && $0.wrapCharacters == 60 })
    #expect(
      model.time == time && model.subtitlePinnedLineID == pinned && model.subtitleSearchVisible)
    model.liveSpeechSessionID = UUID()
    #expect(model.subtitleFontScale == 1 && model.subtitleWrapCharacters == 80)
    model.setSubtitleFontScale(0.8)
    model.setSubtitleWrapCharacters(110)
    let saved = AppSettings.load(defaults: defaults)
    #expect(saved.subtitleFontScale == 1.2 && saved.liveSubtitleFontScale == 0.8)
    #expect(
      saved.subtitleWrapCharacters == 60 && saved.liveSubtitleWrapCharacters == 110
        && saved.timeout == 120)
    model.setSubtitleFontScale(.nan)
    model.setSubtitleWrapCharacters(.infinity)
    #expect(model.subtitleFontScale == 0.8 && model.subtitleWrapCharacters == 110)
  }
  @Test func resetRestoresEveryLayoutDefaultForBothModesWithoutTouchingOtherSettings() throws {
    let (model, defaults, suite) = try SettingsLifecycleTests().isolatedModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    model.setWorkspaceLayout(upper: 0.8, leading: 0.3)
    model.setSubtitleFontScale(1.3)
    model.setSubtitleWrapCharacters(25)
    model.setSubtitleRowSpacing(0.2)
    model.liveSpeechSessionID = UUID()
    model.setSubtitleFontScale(0.7)
    model.setSubtitleWrapCharacters(130)
    model.setSubtitleRowSpacing(0.3)
    model.setAdvancedMode(true)
    model.settings.timeout = 0
    model.resetWorkspaceLayout()
    let saved = AppSettings.load(defaults: defaults)
    #expect(saved.workspaceUpperFraction == 0.55 && saved.workspaceLeadingFraction == 0.5)
    #expect(saved.subtitleRowSpacing == 1 && saved.liveSubtitleRowSpacing == 1)
    #expect(saved.subtitleWrapCharacters == 80 && saved.liveSubtitleWrapCharacters == 80)
    #expect(saved.subtitleFontScale == 1 && saved.liveSubtitleFontScale == 1)
    #expect(saved.advancedMode && saved.timeout == 120 && model.settings.timeout == 0)
  }
}
