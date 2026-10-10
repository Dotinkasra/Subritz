import Foundation
import Testing
@testable import StudyApp
@testable import StudyCore

@MainActor struct SubtitleSearchInteractionTests {
  func fixture() throws -> StudyModel {
    let raw = Data(#"{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"A robot builds."}]},{"tStartMs":5000,"dDurationMs":1000,"segs":[{"utf8":"A silver robot waits."}]},{"tStartMs":9000,"dDurationMs":1000,"segs":[{"utf8":"The robot glows."}]}]}"#.utf8)
    let sentences = try CaptionPipeline().parse(raw, videoID: "test")
    let model = StudyModel(prepareStorage: false)
    model.document = StudyDocument(video: Video(id: "test", title: "Authored search fixture", duration: 10), rawCaption: raw, sentences: sentences)
    model.timeline = Timeline(sentences)
    model.grammarEnabledForVideo = false
    model.ready = true
    return model
  }
  @Test func searchAndNavigationDoNotSeekOrAlterPlaybackAndWrapBothWays() throws {
    let model = try fixture()
    defer { model.closeVideo() }
    model.update(time: 0.01, duration: 10, state: 1)
    let token = model.currentToken?.id
    model.openSubtitleSearch()
    model.setSubtitleSearchQuery("robot")
    #expect(model.subtitleSearchResults.matches.count == 3 && model.browsingSubtitleSearch)
    #expect(model.currentSubtitleSearchMatch?.lineID == model.subtitleLines[0].id)
    model.navigateSubtitleSearch(backwards: true)
    #expect(model.subtitleSearchSelection == 2)
    model.navigateSubtitleSearch()
    #expect(model.subtitleSearchSelection == 0)
    model.navigateSubtitleSearch()
    #expect(model.currentSubtitleSearchMatch?.lineID == model.subtitleLines[1].id)
    #expect(model.playing && model.time == 0.01 && model.currentToken?.id == token)
    #expect(model.bridge.pendingSeekTime == nil)
    model.update(time: 9.1, duration: 10, state: 1)
    #expect(model.currentLineIndex == 2 && model.subtitleSearchSelection == 1)
    model.closeSubtitleSearch()
    #expect(!model.browsingSubtitleSearch && model.subtitleSearchResults.highlights.isEmpty)
    #expect(model.playing && model.time == 9.1)
  }
  @Test func typingUpdatesMatchesAndEmptyResultsAreSafeToNavigate() throws {
    let model = try fixture()
    defer { model.closeVideo() }
    model.openSubtitleSearch()
    model.setSubtitleSearchQuery("ro")
    #expect(model.subtitleSearchResults.matches.count == 3)
    model.navigateSubtitleSearch()
    model.setSubtitleSearchQuery("silver robot")
    #expect(model.subtitleSearchResults.matches.count == 1 && model.subtitleSearchSelection == 0)
    #expect(model.currentSubtitleSearchMatch?.fragments.count == 2)
    model.setSubtitleSearchQuery("nonexistent")
    model.navigateSubtitleSearch(backwards: true)
    model.navigateSubtitleSearch()
    #expect(model.currentSubtitleSearchMatch == nil && !model.browsingSubtitleSearch)
    model.setSubtitleSearchQuery(" \n ")
    #expect(model.subtitleSearchResults.highlights.isEmpty)
  }
  @Test func closingAndReopeningRestoresQueryWithoutHiddenHighlights() throws {
    let model = try fixture()
    defer { model.closeVideo() }
    model.openSubtitleSearch()
    model.setSubtitleSearchQuery("robot")
    model.navigateSubtitleSearch()
    model.closeSubtitleSearch()
    #expect(!model.subtitleSearchVisible && !model.browsingSubtitleSearch)
    #expect(model.subtitleSearchQuery == "robot" && model.subtitleSearchResults.highlights.isEmpty)
    model.openSubtitleSearch()
    #expect(model.subtitleSearchQuery == "robot" && model.subtitleSearchResults.matches.count == 3)
    #expect(model.subtitleSearchSelection == 0 && model.browsingSubtitleSearch)
  }
  @Test func querySurvivesVideoChangesButIndicesAndHighlightsDoNot() throws {
    let model = try fixture()
    model.openSubtitleSearch()
    let request = model.subtitleSearchFocusRequest
    model.setSubtitleSearchQuery("robot")
    model.openSubtitleSearch()
    #expect(model.subtitleSearchFocusRequest == request + 1 && model.subtitleSearchQuery == "robot")
    model.closeVideo()
    #expect(!model.subtitleSearchVisible && model.subtitleSearchQuery == "robot" && model.subtitleSearchIndex == nil)
    #expect(model.currentSubtitleSearchMatch == nil)
    model.openSubtitleSearch()
    #expect(!model.subtitleSearchVisible)
    let other = try fixture()
    model.document = other.document
    model.timeline = other.timeline
    model.ready = true
    model.openSubtitleSearch()
    #expect(model.subtitleSearchResults.matches.count == 3)
    #expect(model.subtitleSearchResults.matches.first?.lineID == other.subtitleLines[0].id)
    #expect(other.subtitleSearchQuery.isEmpty) // A fresh app model has no stored query.
    model.closeVideo()
  }
}
