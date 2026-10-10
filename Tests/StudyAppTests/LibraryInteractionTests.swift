import AppKit
import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

private actor LibraryVideoProvider: YouTubeProvider {
  var requested: [String] = []
  func probe(id: String) async throws -> VideoProbe {
    requested.append(id)
    return VideoProbe(
      id: id, title: "Loaded from history", duration: 2, language: "en", automatic_captions: nil,
      thumbnail: "https://i.ytimg.com/thumbnail.jpg")
  }
  func caption(_ probe: VideoProbe) async throws -> Data {
    Data(#"{"events":[{"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"Hello world."}]}]}"#.utf8)
  }
  func calls() -> [String] { requested }
}
@MainActor struct LibraryInteractionTests {
  func libraryModel() throws -> (StudyModel, URL) {
    let (model, _) = try DictionaryPinTests().fixture(realtime: false)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    model.library = try LibraryStore(directory: root)
    return (model, root)
  }
  @Test func starStoresTheSelectedWordEvenIfPlaybackOrPinChanges() async throws {
    let (model, root) = try libraryModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let words = model.timeline!.tokens.filter(\.lexical)
    model.pinDictionary(words[1])
    model.toggleDisplayedFavorite()
    #expect(!model.canToggleDisplayedFavorite)
    model.toggleDisplayedFavorite()  // duplicate event must not toggle it back off
    model.pinDictionary(words[2])
    await model.libraryOperation?.value
    #expect(model.favoriteWords.map(\.id) == [words[1].surface.lowercased()])
    #expect(model.favoriteWords[0].shortGloss == words[1].surface)
    #expect(model.favoriteWords[0].sourceTime == words[1].startTime)
    model.pinDictionary(words[1])
    #expect(model.displayedWordIsFavorite)
    model.toggleDisplayedFavorite()
    await model.libraryOperation?.value
    #expect(model.favoriteWords.isEmpty && !model.displayedWordIsFavorite)
  }
  @Test func savedFavoriteWithoutDictionaryResultUsesCapturedTokenAndProvider() async throws {
    let (model, root) = try libraryModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let dictionary = try EijiroProvider(directory: root.appendingPathComponent("dictionary"))
    let file = root.appendingPathComponent("words.txt")
    try "■study {名・動} : 自作登録義\n".write(to: file, atomically: true, encoding: .utf8)
    _ = try await dictionary.importFile(file)
    model.settings.dictionary = "eijiro"
    model.eijiro = dictionary
    let token = try #require(model.timeline?.tokens.first { $0.surface == "study" })
    model.pinDictionary(token)
    model.dictionaryEntry = nil
    model.toggleDisplayedFavorite()
    model.releaseDictionaryPin()
    await model.libraryOperation?.value
    #expect(model.favoriteWords.first?.id == "study")
    #expect(model.favoriteWords.first?.shortGloss == "自作登録義")
  }
  @Test func failedFavoriteWriteUnlocksTheStarAndReportsError() async throws {
    let (model, root) = try libraryModel()
    defer { try? FileManager.default.removeItem(at: root) }
    try await model.library?.db.execute("DROP TABLE favorite_words")
    model.pinDictionary(model.timeline!.tokens[0])
    model.toggleDisplayedFavorite()
    await model.libraryOperation?.value
    #expect(model.libraryError != nil && model.favoriteWords.isEmpty)
    #expect(model.pendingFavoriteIDs.isEmpty && model.canToggleDisplayedFavorite)
  }
  @Test func closingVideoAndClearingCacheKeepHistoryAndFavorites() async throws {
    let (model, root) = try libraryModel()
    defer { try? FileManager.default.removeItem(at: root) }
    model.recordCurrentVideo()
    model.pinDictionary(model.timeline!.tokens[0])
    model.toggleDisplayedFavorite()
    await model.libraryOperation?.value
    model.store = try StudyStore(directory: root)
    model.closeVideo()
    try await model.store?.clear()
    try await model.refreshLibrary()
    #expect(model.videoHistory.count == 1 && model.favoriteWords.count == 1)
  }
  @Test func historySelectionConfirmsReplacementAndLoadsThroughSamePipeline() async throws {
    let (model, root) = try libraryModel()
    defer {
      model.closeVideo()
      try? FileManager.default.removeItem(at: root)
    }
    model.settings.aiGrammarEnabled = false  // Prevent external LLM requests in this test.
    let provider = LibraryVideoProvider()
    model.youtubeProviderOverride = provider
    let item = VideoHistoryItem(
      video: Video(id: "abcdefghijk", title: "History title", duration: 2))
    let originalSession = model.session
    #expect(!model.selectHistory(item))
    #expect(model.pendingLibraryPlayback?.video.id == item.id && model.session == originalSession)
    #expect(await provider.calls().isEmpty)
    model.pendingLibraryPlayback = nil  // cancel leaves the current video untouched
    #expect(model.document?.video.id == "test" && model.ready)
    #expect(!model.selectHistory(item))
    #expect(model.confirmLibraryPlayback())
    await model.loadTask?.value
    await model.libraryOperation?.value
    #expect(await provider.calls() == [item.id])
    #expect(model.url == item.video.watchURL && model.document?.video.id == item.id && model.ready)
    #expect(model.videoHistory.first?.video.title == "Loaded from history")
  }
  @Test func historyWithoutOpenVideoStartsImmediatelyAndBlockedLoadsDoNotDismiss() async throws {
    let (model, root) = try libraryModel()
    defer {
      model.closeVideo()
      try? FileManager.default.removeItem(at: root)
    }
    model.closeVideo()
    model.settings.aiGrammarEnabled = false
    let provider = LibraryVideoProvider()
    model.youtubeProviderOverride = provider
    let item = VideoHistoryItem(video: Video(id: "abcdefghijk", title: "History", duration: 2))
    model.isChangingCacheDirectory = true
    #expect(!model.selectHistory(item) && !model.hasOpenVideo)
    #expect(!model.confirmLibraryPlayback(LibraryPlaybackRequest(video: item.video, time: 0)))
    #expect(await provider.calls().isEmpty)
    model.isChangingCacheDirectory = false
    let invalid = VideoHistoryItem(video: Video(id: "invalid", title: "Invalid", duration: 2))
    #expect(!model.selectHistory(invalid) && !model.hasOpenVideo)
    #expect(await provider.calls().isEmpty)
    #expect(model.selectHistory(item))
    #expect(model.loading && model.pendingLibraryPlayback == nil)
    await model.loadTask?.value
    await model.libraryOperation?.value
    #expect(model.ready && model.document?.video.id == item.id)
    #expect(await provider.calls() == [item.id])
  }
  @Test func nativeSingleClickPinsAndDoubleClickSeeksWithoutStartingPausedVideo() throws {
    let (model, _) = try DictionaryPinTests().fixture(realtime: false)
    let token = model.timeline!.tokens[3]  // read, at 1.45 seconds
    let button = SubtitleWordButton.WordButton(frame: .zero)
    button.onClick = { model.toggleDictionarySelection(token) }
    button.onDoubleClick = { model.seekToWord(token) }
    button.clicked()
    #expect(model.pinnedToken?.id == token.id && model.time == 0.1)
    button.clicked()
    #expect(!model.dictionaryIsPinned && model.time == 0.1)
    button.clicked()
    let event = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
        context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
    button.mouseDown(with: event)
    #expect(model.time == token.startTime && model.currentToken?.id == token.id)
    #expect(model.pinnedToken?.id == token.id && !model.playing)
    button.isEnabled = false
    model.update(time: 0.1, duration: 2, state: 2)
    button.mouseDown(with: event)
    #expect(model.time == 0.1)
  }
  @Test func seekingUsesTimedTokenAndPreservesPlayingRealtimeSynchronization() throws {
    let (model, _) = try DictionaryPinTests().fixture(realtime: true)
    let token = model.timeline!.tokens[3]
    model.update(time: 0.1, duration: 2, state: 1)
    model.seekToWord(token)
    #expect(model.playing && model.time == token.startTime)
    #expect(model.displayedToken?.id == token.id && model.pinnedToken == nil)
    var oldToken = token
    oldToken.id = UUID()
    model.seekToWord(oldToken)
    #expect(model.time == token.startTime)
    var invalid = token
    invalid.startTime = .nan
    model.seekToWord(invalid)
    #expect(model.time == token.startTime)
    let punctuation = try #require(model.timeline?.tokens.first { !$0.lexical })
    model.seekToWord(punctuation)
    #expect(model.time == token.startTime)
  }
}
