import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

@MainActor struct AdvancedModeTests {
  @Test func switchingOnlyChangesPresentationAndPersistsWithoutInvalidDraftSettings() async throws {
    let (model, tokens, root, defaults, suite) = try await DictionaryExpressionInteractionTests().fixture()
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    model.update(time: tokens[1].startTime + 0.01, duration: 5, state: 1)
    await model.dictionaryTask?.value
    let entry = try #require(model.dictionaryEntry)
    let expression = try #require(model.resolvedExpression)
    let session = model.session
    let queryID = model.selectedDictionaryID
    let time = model.time
    let line = model.currentLineIndex
    let cacheKeys = Set(model.dictionaryCache.keys)
    model.settings.timeout = 0 // Unfinished settings must not prevent saving this preference.
    for enabled in [true, false, true] {
      model.setAdvancedMode(enabled)
      #expect(model.realtimeEnglishOnly == enabled)
      #expect(model.dictionaryEntry?.definition == entry.definition)
      #expect(model.dictionaryEntry?.shortGloss == entry.shortGloss)
      #expect(model.resolvedExpression?.id == expression.id)
      #expect(model.displayedToken?.surface == "stacks up")
      #expect(model.currentToken?.id == tokens[1].id && model.currentLineIndex == line)
      #expect(model.time == time && model.playing && model.session == session)
      #expect(model.selectedDictionaryID == queryID && Set(model.dictionaryCache.keys) == cacheKeys)
      #expect(model.dictionaryTask?.isCancelled == false)
      #expect(model.loadTask == nil && model.backgroundTask == nil)
    }
    let reloaded = StudyModel(prepareStorage: false, defaults: defaults)
    #expect(reloaded.settings.advancedMode)
    #expect(reloaded.settings.timeout == 120)
  }

  @Test func manualSelectionAndNormalModeKeepMeaningsAndPlaybackReturnsToEnglishOnly() async throws {
    let (model, tokens, root, defaults, suite) = try await DictionaryExpressionInteractionTests().fixture()
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    model.update(time: tokens[1].startTime + 0.01, duration: 5, state: 2)
    await model.dictionaryTask?.value
    model.setAdvancedMode(true)
    #expect(model.realtimeEnglishOnly)
    model.hover(tokens[1])
    await model.dictionaryTask?.value
    #expect(!model.realtimeEnglishOnly && DictionaryPane(model: model).detailed)
    #expect(model.dictionaryEntry?.shortGloss == "自作句義A、自作句義B")
    model.pinDictionary(tokens[1])
    await model.dictionaryTask?.value
    #expect(!model.realtimeEnglishOnly && model.displayedToken?.surface == "stacks")
    #expect(model.dictionaryEntry != nil)
    model.pinDictionaryRange(from: tokens[1].id, to: tokens[2].id)
    await model.dictionaryTask?.value
    #expect(!model.realtimeEnglishOnly && DictionaryPane(model: model).detailed)
    #expect(model.dictionaryEntry?.shortGloss == "自作句義A、自作句義B")
    model.setAdvancedMode(false)
    model.setAdvancedMode(true)
    #expect(model.pinnedExpression != nil && !model.realtimeEnglishOnly)
    model.update(time: tokens[1].startTime + 0.02, duration: 5, state: 1)
    await model.dictionaryTask?.value
    #expect(!model.dictionaryIsPinned && model.realtimeEnglishOnly)
    model.realtime = false
    model.dictionaryModeChanged()
    model.hover(tokens[1])
    await model.dictionaryTask?.value
    #expect(!model.realtimeEnglishOnly && DictionaryPane(model: model).detailed)
    #expect(model.dictionaryEntry?.shortGloss == "自作句義A、自作句義B")
  }
}
