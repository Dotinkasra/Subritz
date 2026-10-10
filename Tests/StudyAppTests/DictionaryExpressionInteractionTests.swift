import Foundation
import Testing
@testable import StudyApp
@testable import StudyCore

@MainActor struct DictionaryExpressionInteractionTests {
  func fixture() async throws -> (StudyModel, [Token], URL, UserDefaults, String) {
    let (model, defaults, suite) = try SettingsLifecycleTests().isolatedModel()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = try EijiroProvider(directory: root)
    let file = root.appendingPathComponent("phrases.txt")
    try "■stack up  {句自動} : 自作句義A、自作句義B\n■stack  {名} : 自作名義A、自作名義B\n■stack  {自動} : 自作動詞義A\n".write(to: file, atomically: true, encoding: .utf8)
    _ = try await provider.importFile(file)
    model.eijiro = provider
    model.settings.dictionary = "eijiro"
    let raw = Data(#"{"events":[{"tStartMs":0,"dDurationMs":5000,"segs":[{"utf8":"robot stacks up near a lantern."}]}]}"#.utf8)
    let tokens = try CaptionPipeline().parse(raw, videoID: "test").flatMap(\.tokens)
    let sentence = Sentence(id: tokens[0].sentenceID, videoID: "test", index: 0,
      text: tokens.map(\.surface).joined(separator: " "), startTime: 0, endTime: 5, tokens: tokens, grammarAnalysis: nil)
    model.document = StudyDocument(video: Video(id: "test", title: "Test", duration: 5), rawCaption: Data(), sentences: [sentence])
    model.timeline = Timeline([sentence])
    model.grammarEnabledForVideo = false
    model.ready = true
    return (model, tokens, root, defaults, suite)
  }
  @Test func realtimeAndHoverRecognizeExpressionsWhileSingleClickKeepsIndividualWord() async throws {
    let (model, tokens, root, defaults, suite) = try await fixture()
    defer { model.closeVideo(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    model.update(time: tokens[1].startTime + 0.01, duration: 5, state: 2)
    await model.dictionaryTask?.value
    #expect(model.displayedToken?.surface == "stacks up" && model.dictionaryEntry?.headword == "stack up")
    model.update(time: tokens[2].startTime + 0.01, duration: 5, state: 2)
    await model.dictionaryTask?.value
    #expect(model.displayedToken?.surface == "stacks up")
    model.realtime = false
    model.dictionaryModeChanged()
    model.hover(tokens[1])
    await model.dictionaryTask?.value
    #expect(model.displayedToken?.surface == "stacks up" && DictionaryPane(model: model).detailed)
    model.pinDictionary(tokens[1])
    await model.dictionaryTask?.value
    #expect(model.displayedToken?.surface == "stacks" && model.resolvedExpression == nil)
    #expect(model.dictionaryEntry?.headword == "stack")
    #expect(["自作名義A、自作名義B", "自作動詞義A"].contains(model.dictionaryEntry?.shortGloss ?? ""))
    model.realtime = true
    model.update(time: tokens[1].startTime + 0.01, duration: 5, state: 2)
    model.releaseDictionaryPin()
    await model.dictionaryTask?.value
    #expect(model.displayedToken?.surface == "stacks up")
    model.pinDictionary(tokens[1])
    await model.dictionaryTask?.value
    model.update(time: tokens[1].startTime + 0.02, duration: 5, state: 1)
    await model.dictionaryTask?.value
    #expect(!model.dictionaryIsPinned && model.displayedToken?.surface == "stacks up")
  }
  @Test func rangeSelectionIsExactReversibleAndCanBeSavedAsFavorite() async throws {
    let (model, tokens, root, defaults, suite) = try await fixture()
    defer { model.closeVideo(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    model.realtime = false
    model.pinDictionaryRange(from: tokens[2].id, to: tokens[1].id)
    await model.dictionaryTask?.value
    #expect(model.displayedToken?.surface == "stacks up" && model.dictionaryEntry?.headword == "stack up")
    #expect(model.dictionarySelectionContains(tokens[1]) && model.dictionarySelectionContains(tokens[2]))
    model.library = try LibraryStore(directory: root.appendingPathComponent("library"))
    model.toggleDisplayedFavorite()
    model.pinDictionaryRange(from: tokens[2].id, to: tokens[3].id)
    await model.libraryOperation?.value
    await model.dictionaryTask?.value
    #expect(model.favoriteWords.first?.surface == "stacks up" && model.favoriteWords.first?.lemma == "stack up")
    #expect(model.favoriteWords.first?.partOfSpeech == "句動詞")
    #expect(model.displayedToken?.surface == "up near" && model.dictionaryEntry == nil)
    #expect(model.dictionaryIsPinned)
    model.pinDictionaryRange(from: tokens[1].id, to: tokens[1].id)
    await model.dictionaryTask?.value
    #expect(model.pinnedExpression == nil && model.displayedToken?.surface == "stacks")
    model.releaseDictionaryPin()
    #expect(model.displayedToken == nil)
  }
  @Test func realtimeRangeRemainsWhileDraggingThenResumesAndOldResultsCannotReplaceSelection() async throws {
    let (model, tokens, root, defaults, suite) = try await fixture()
    defer { model.closeVideo(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    model.pinDictionaryRange(from: tokens[1].id, to: tokens[2].id)
    model.draggingDictionarySelection = true
    model.update(time: tokens[3].startTime + 0.01, duration: 5, state: 1)
    #expect(model.pinnedExpression != nil)
    model.draggingDictionarySelection = false
    model.update(time: tokens[4].startTime + 0.01, duration: 5, state: 1)
    #expect(!model.dictionaryIsPinned && model.currentToken?.id == tokens[4].id)
    model.pinDictionaryRange(from: tokens[1].id, to: tokens[2].id)
    let oldTask = model.dictionaryTask
    model.pinDictionaryRange(from: tokens[2].id, to: tokens[3].id)
    await oldTask?.value
    await model.dictionaryTask?.value
    #expect(model.displayedToken?.surface == "up near" && model.dictionaryEntry == nil)
    model.closeVideo()
    #expect(model.pinnedExpression == nil && model.resolvedExpression == nil)
  }
  @Test(arguments: [false, true]) func contractionMeaningAndExpansionsReachBothDictionaryModes(realtime: Bool) async throws {
    let (model, defaults, suite) = try SettingsLifecycleTests().isolatedModel()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { model.closeVideo(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let provider = try EijiroProvider(directory: root)
    let file = root.appendingPathComponent("authored.txt")
    try "■there's {省略形-1} : ＝<→there is>、<→there has>\n■there is {動} : 自作表示義A".write(to: file, atomically: true, encoding: .utf8)
    _ = try await provider.importFile(file)
    let raw = Data(#"{"events":[{"tStartMs":0,"dDurationMs":5000,"segs":[{"utf8":"There's a copper tower."}]}]}"#.utf8)
    let sentences = try CaptionPipeline().parse(raw, videoID: "test")
    model.document = StudyDocument(video: Video(id: "test", title: "Test", duration: 5), rawCaption: raw, sentences: sentences)
    model.timeline = Timeline(sentences)
    model.eijiro = provider
    model.settings.dictionary = "eijiro"
    model.grammarEnabledForVideo = false
    model.ready = true
    model.realtime = realtime
    let token = try #require(model.timeline?.tokens.first)
    model.update(time: 0.01, duration: 5, state: 2)
    if !realtime { model.hover(token) }
    await model.dictionaryTask?.value
    #expect(model.displayedToken?.surface == "There's")
    #expect(model.dictionaryEntry?.shortGloss == "自作表示義A")
    #expect(model.dictionaryEntry?.expandedForms == ["there is", "there has"])
    model.toggleDictionarySelection(token)
    await model.dictionaryTask?.value
    #expect(model.dictionaryIsPinned && model.dictionaryEntry?.partOfSpeech == "省略形")
    #expect(model.dictionaryEntry?.shortGloss == "自作表示義A")
  }
  @Test(arguments: [false, true]) func incorrectOrDifferentPosCannotHideDefinitionsInEitherMode(realtime: Bool) async throws {
    let (model, defaults, suite) = try SettingsLifecycleTests().isolatedModel()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { model.closeVideo(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let provider = try EijiroProvider(directory: root)
    let file = root.appendingPathComponent("authored.txt")
    try "■my {代名} : 自作所有義A\n■wardrobeunit {名} : 自作名義B".write(to: file, atomically: true, encoding: .utf8)
    _ = try await provider.importFile(file)
    let raw = Data(#"{"events":[{"tStartMs":0,"dDurationMs":5000,"segs":[{"utf8":"My wardrobeunit glows."}]}]}"#.utf8)
    var sentences = try CaptionPipeline().parse(raw, videoID: "test")
    sentences[0].tokens[0].partOfSpeech = "Determiner"
    sentences[0].tokens[1].partOfSpeech = "Adjective"
    model.document = StudyDocument(video: Video(id: "test", title: "Test", duration: 5), rawCaption: raw, sentences: sentences)
    model.timeline = Timeline(sentences)
    model.eijiro = provider
    model.settings.dictionary = "eijiro"
    model.grammarEnabledForVideo = false
    model.ready = true
    model.realtime = realtime
    for (index, meaning, pos) in [(0, "自作所有義A", "Pronoun"), (1, "自作名義B", "Noun")] {
      let token = sentences[0].tokens[index]
      model.update(time: token.startTime + 0.01, duration: 5, state: 2)
      if !realtime { model.hover(token) }
      await model.dictionaryTask?.value
      #expect(model.dictionaryEntry?.shortGloss == meaning && model.dictionaryEntry?.partOfSpeech == pos)
      model.toggleDictionarySelection(token)
      await model.dictionaryTask?.value
      #expect(model.dictionaryIsPinned && model.dictionaryEntry?.shortGloss == meaning)
      #expect(DictionaryPane(model: model).pos(model.dictionaryEntry?.partOfSpeech) == (index == 0 ? "代名詞" : "N · 名詞"))
      model.releaseDictionaryPin()
    }
  }
  @Test(arguments: [false, true]) func negativeSpeechCannotDisplayAnAffirmativeIdiom(realtime: Bool) async throws {
    let (model, defaults, suite) = try SettingsLifecycleTests().isolatedModel()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { model.closeVideo(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let provider = try EijiroProvider(directory: root)
    let file = root.appendingPathComponent("authored.txt")
    try "■I do : 自作肯定熟語義A\n■don't {省略形} : ＝<→do not>\n■do not {助動} : 自作否定義B".write(to: file, atomically: true, encoding: .utf8)
    _ = try await provider.importFile(file)
    let raw = Data(#"{"events":[{"tStartMs":0,"dDurationMs":5000,"segs":[{"utf8":"I don't think the copper robot moves."}]}]}"#.utf8)
    var sentences = try CaptionPipeline().parse(raw, videoID: "test")
    sentences[0].tokens[1].lemma = "do"
    let tokens = sentences[0].tokens
    model.document = StudyDocument(video: Video(id: "test", title: "Test", duration: 5), rawCaption: raw, sentences: sentences)
    model.timeline = Timeline(sentences)
    model.eijiro = provider
    model.settings.dictionary = "eijiro"
    model.grammarEnabledForVideo = false
    model.ready = true
    model.realtime = realtime
    model.update(time: tokens[1].startTime + 0.01, duration: 5, state: 2)
    if !realtime { model.hover(tokens[1]) }
    await model.dictionaryTask?.value
    #expect(model.displayedToken?.surface == "don't" && model.resolvedExpression == nil)
    #expect(model.dictionaryEntry?.shortGloss == "自作否定義B")
    model.pinDictionaryRange(from: tokens[0].id, to: tokens[1].id)
    await model.dictionaryTask?.value
    #expect(model.displayedToken?.surface == "I don't" && model.dictionaryEntry == nil)
    model.library = try LibraryStore(directory: root.appendingPathComponent("library"))
    model.toggleDisplayedFavorite()
    await model.libraryOperation?.value
    #expect(model.favoriteWords.first?.surface == "I don't" && model.favoriteWords.first?.lemma == nil)
  }
}
