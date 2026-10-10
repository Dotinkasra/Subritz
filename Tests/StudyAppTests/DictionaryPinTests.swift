import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

@MainActor struct DictionaryPinTests {
  func fixture(realtime: Bool) throws -> (StudyModel, [Token]) {
    let raw = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":900,"segs":[{"utf8":"I"},{"utf8":" study.","tOffsetMs":450}]},{"tStartMs":1000,"dDurationMs":900,"segs":[{"utf8":"You"},{"utf8":" read.","tOffsetMs":450}]}]}"#
        .utf8)
    let sentences = try CaptionPipeline().parse(raw, videoID: "test")
    let model = StudyModel(prepareStorage: false)
    model.settings.dictionary = "macOS"
    model.document = StudyDocument(
      video: Video(id: "test", title: "Test", duration: 2), rawCaption: raw, sentences: sentences)
    model.timeline = Timeline(sentences)
    model.ready = true
    model.realtime = realtime
    for token in model.timeline!.tokens {
      model.dictionaryCache[model.dictionaryKey(token)] = DictionaryEntry(
        definition: "Definition " + token.surface, shortGloss: token.surface)
    }
    model.update(time: 0.1, duration: 2, state: 2)
    return (model, model.timeline!.tokens.filter(\.lexical))
  }
  @Test func normalPinSurvivesHoverAndPlaybackWhileSubtitlesStaySynchronized() throws {
    let (model, words) = try fixture(realtime: false)
    model.hover(words[0])
    model.pinDictionary(words[0])
    model.hover(nil, exiting: words[0].id)
    model.hover(words[1])
    model.update(time: 1.1, duration: 2, state: 1)
    #expect(model.playing)
    #expect(model.currentLineIndex == 1)
    #expect(model.currentToken?.id == words[2].id)
    #expect(model.displayedToken?.id == words[0].id)
    #expect(model.dictionaryEntry?.shortGloss == words[0].surface)
    #expect(DictionaryPane(model: model).detailed)
  }
  @Test func pausedRealtimePinSurvivesTimeChangesAndPointerExit() throws {
    let (model, words) = try fixture(realtime: true)
    model.pinDictionary(words[2])
    model.hover(nil, exiting: words[2].id)
    model.update(time: 0.6, duration: 2, state: 2)
    #expect(model.displayedToken?.id == words[2].id)
    #expect(model.dictionaryEntry?.shortGloss == words[2].surface)
    #expect(model.currentToken?.id == words[1].id)
  }
  @Test func resumedRealtimeClearsPinEvenWhenTheSpokenWordHasNotChanged() throws {
    let (model, words) = try fixture(realtime: true)
    model.pinDictionary(words[2])
    model.update(time: 0.1, duration: 2, state: 1)
    #expect(model.pinnedToken == nil)
    #expect(model.hoverToken == nil)
    #expect(model.displayedToken?.id == words[0].id)
    #expect(model.dictionaryEntry?.shortGloss == words[0].surface)
    #expect(!DictionaryPane(model: model).detailed)
  }
  @Test func playingRealtimeReturnsToSynchronizationAtNextWord() throws {
    let (model, words) = try fixture(realtime: true)
    model.update(time: 0.1, duration: 2, state: 1)
    model.pinDictionary(words[2])
    model.update(time: 0.2, duration: 2, state: 1)
    #expect(model.displayedToken?.id == words[2].id)
    model.update(time: 0.6, duration: 2, state: 1)
    model.hover(nil, exiting: words[2].id)
    #expect(model.pinnedToken == nil)
    #expect(model.displayedToken?.id == words[1].id)
    #expect(model.dictionaryEntry?.shortGloss == words[1].surface)
    #expect(!DictionaryPane(model: model).detailed)
  }
  @Test func switchingToPlayingRealtimeResumesDictionarySynchronization() throws {
    let (model, words) = try fixture(realtime: false)
    model.pinDictionary(words[0])
    model.update(time: 1.1, duration: 2, state: 1)
    model.realtime = true
    model.dictionaryModeChanged()
    #expect(model.displayedToken?.id == words[2].id)
    #expect(model.pinnedToken == nil)
    #expect(model.dictionaryEntry?.shortGloss == words[2].surface)
  }
  @Test func anotherClickReplacesPinAndReleaseRestoresMode() throws {
    let (model, words) = try fixture(realtime: false)
    model.pinDictionary(words[0])
    model.pinDictionary(words[2])
    #expect(model.pinnedToken?.id == words[2].id)
    #expect(model.dictionaryEntry?.shortGloss == words[2].surface)
    model.releaseDictionaryPin()
    #expect(model.displayedToken == nil)
    #expect(model.dictionaryEntry == nil)
    model.realtime = true
    model.pinDictionary(words[2])
    model.releaseDictionaryPin()
    #expect(model.displayedToken?.id == words[0].id)
    #expect(model.dictionaryEntry?.shortGloss == words[0].surface)
  }
  @Test func punctuationCannotBePinned() throws {
    let (model, words) = try fixture(realtime: true)
    let punctuation = try #require(model.timeline?.tokens.first { !$0.lexical })
    model.pinDictionary(words[0])
    model.pinDictionary(punctuation)
    #expect(model.pinnedToken?.id == words[0].id)
  }
  @Test(arguments: [false, true]) func secondClickClearsSelectionAndRestoresDictionaryMode(realtime: Bool) throws {
    let (model, words) = try fixture(realtime: realtime)
    model.toggleDictionarySelection(words[2])
    #expect(model.pinnedToken?.id == words[2].id)
    model.toggleDictionarySelection(words[3])
    #expect(model.pinnedToken?.id == words[3].id)
    model.toggleDictionarySelection(words[3])
    #expect(!model.dictionaryIsPinned && model.hoverToken == nil)
    #expect(model.displayedToken?.id == (realtime ? words[0].id : nil))
    #expect(model.dictionaryEntry?.shortGloss == (realtime ? words[0].surface : nil))
    #expect(model.time == 0.1 && !model.playing)
  }
  @Test func clickingSelectedRangeClearsItAndDraggingCanSelectAgain() throws {
    let (model, words) = try fixture(realtime: false)
    model.pinDictionaryRange(from: words[0].id, to: words[1].id)
    model.toggleDictionarySelection(words[1])
    #expect(!model.dictionaryIsPinned && model.displayedToken == nil)
    model.pinDictionaryRange(from: words[1].id, to: words[1].id)
    model.pinDictionaryRange(from: words[1].id, to: words[1].id)
    #expect(model.pinnedToken?.id == words[1].id)
    model.pinDictionaryRange(from: words[1].id, to: words[0].id)
    #expect(model.pinnedExpression?.tokens.map(\.id) == [words[0].id, words[1].id])
  }
}
