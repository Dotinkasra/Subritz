import Foundation
import Testing
@testable import StudyApp

@MainActor struct SubtitleScrollTests {
  @Test func pinStopsFollowingWithoutStoppingPlaybackWordOrLineUpdates() throws {
    let model = try SubtitleSearchInteractionTests().fixture()
    defer { model.closeVideo() }
    model.update(time: 0.01, duration: 10, state: 1)
    let first = model.currentToken?.id
    #expect(model.subtitleFollowLineID() == model.subtitleLines[0].id)
    model.toggleSubtitleScrollPin()
    let pinned = model.subtitlePinnedLineID
    model.update(time: 9.1, duration: 10, state: 1)
    #expect(model.subtitleScrollPinned && model.subtitleFollowLineID() == nil)
    #expect(model.playing && model.time == 9.1 && model.currentLineIndex == 2)
    #expect(model.currentToken?.id != first)
    #expect(model.subtitlePinnedLineID == pinned && pinned == model.subtitleLines[0].id)
    #expect(model.bridge.pendingSeekTime == nil)
    model.toggleSubtitleScrollPin()
    #expect(model.subtitlePinnedLineID == nil)
    #expect(model.subtitleFollowLineID() == model.subtitleLines[2].id)
  }
  @Test func searchAndDraggingDoNotOverridePinAndClosingVideoResetsIt() throws {
    let model = try SubtitleSearchInteractionTests().fixture()
    model.toggleSubtitleScrollPin()
    model.openSubtitleSearch()
    model.setSubtitleSearchQuery("robot")
    model.navigateSubtitleSearch()
    #expect(model.subtitleScrollPinned && model.subtitleFollowLineID(ignoringSearch: true) == nil)
    model.toggleSubtitleScrollPin()
    #expect(model.subtitleFollowLineID() == nil)
    #expect(model.subtitleFollowLineID(ignoringSearch: true) == model.subtitleLines[0].id)
    model.draggingDictionarySelection = true
    #expect(model.subtitleFollowLineID(ignoringSearch: true) == nil)
    model.draggingDictionarySelection = false
    model.closeSubtitleSearch()
    #expect(model.subtitleFollowLineID() != nil)
    model.toggleSubtitleScrollPin()
    model.closeVideo()
    #expect(!model.subtitleScrollPinned && model.subtitlePinnedLineID == nil)
    model.toggleSubtitleScrollPin()
    #expect(!model.subtitleScrollPinned)
  }
  @Test func pinOutlineTargetsTheBrowsedOrDoubleClickedRowRatherThanThePlaybackRow() throws {
    let model = try SubtitleSearchInteractionTests().fixture()
    defer { model.closeVideo() }
    let target = model.subtitleLines[2].id
    model.toggleSubtitleScrollPin(at: target)
    #expect(model.subtitlePinnedLineID == target && model.currentLineIndex == 0)
    model.update(time: 5.1, duration: 10, state: 1)
    #expect(model.subtitlePinnedLineID == target)
    model.toggleSubtitleScrollPin(at: model.subtitleLines[1].id)
    #expect(model.subtitlePinnedLineID == nil && !model.subtitleScrollPinned)
  }
}
