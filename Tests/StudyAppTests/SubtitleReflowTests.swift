import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

@MainActor struct SubtitleReflowTests {
  func fixture() throws -> (StudyModel, UserDefaults, String) {
    let (model, defaults, suite) = try SettingsLifecycleTests().isolatedModel()
    let chunks = [
      (0, 1000, "A paper robot carries"), (1000, 1000, "a blue lantern across"),
      (2000, 1000, "the quiet garden."), (3000, 2000, "[Music]"),
      (8000, 1000, "Copper towers glow."),
    ]
    let events = chunks.map {
      ["tStartMs": $0.0, "dDurationMs": $0.1, "segs": [["utf8": $0.2]]] as [String: Any]
    }
    let raw = try JSONSerialization.data(withJSONObject: ["events": events])
    let sentences = try CaptionPipeline().parse(raw, videoID: "authored")
    model.document = StudyDocument(
      video: Video(id: "authored", title: "Authored reflow fixture", duration: 10), rawCaption: raw,
      sentences: sentences)
    model.timeline = Timeline(sentences)
    model.ready = true
    model.realtime = false
    model.grammarEnabledForVideo = false
    for token in model.timeline!.tokens {
      model.dictionaryCache[model.dictionaryKey(token)] = DictionaryEntry(
        definition: "Self-authored definition", shortGloss: "自作語義")
      model.expressionMisses.insert(token.id)
    }
    return (model, defaults, suite)
  }
  func reflow(_ model: StudyModel, width: Double = 1000, characters: Int = 140) throws
    -> SubtitleReflow
  {
    try .build(
      lines: model.subtitleLines, width: width, maximumCharacters: characters, measure: { _ in 10 })
  }
  @Test func shortSourceCaptionsJoinWithoutChangingAnyTokenOrTiming() throws {
    let (model, defaults, suite) = try fixture()
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    let original = model.subtitleLines
    #expect(original.count == 5)
    let display = try reflow(model)
    #expect(display.rows.count == 3)  // Continuous English, annotation, English after a long pause.
    #expect(display.rows.flatMap(\.tokens) == original.flatMap(\.tokens))
    #expect(model.subtitleLines == original)
    #expect(display.rows[0].tokens.map(\.surface).contains("garden"))
    #expect(display.rowID(containing: original[1].id) == display.rows[0].id)
    #expect(display.tokenSourceLines[original[1].id] == original[1].id)
    #expect(Set(display.tokenRows.keys).count == original.flatMap(\.tokens).count)
  }
  @Test func widthAndCharacterChangesRepackTheSameWordsAndMaxUsesViewportWidth() async throws {
    let (model, defaults, suite) = try fixture()
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    let wide = try reflow(model, characters: 140)
    let short = try reflow(model, characters: 20)
    let narrow = try reflow(model, width: 35, characters: 140)
    #expect(short.rows.count > wide.rows.count && narrow.rows.count > short.rows.count)
    for layout in [wide, short, narrow] {
      #expect(layout.rows.flatMap(\.tokens) == model.timeline?.tokens)
    }
    let engine = SubtitleReflowEngine()
    let actualWide = try await engine.build(
      lines: model.subtitleLines, width: 4000, characters: 140, fontScale: 1, grammar: false)
    let actualNarrow = try await engine.build(
      lines: model.subtitleLines, width: 220, characters: 140, fontScale: 1, grammar: false)
    #expect(actualWide.rows.count < actualNarrow.rows.count)
    #expect(actualWide.rows[0].tokens.count == wide.rows[0].tokens.count)
  }
  @Test func searchPinRangeAndSeekKeepOriginalReferencesAcrossReflow() throws {
    let (model, defaults, suite) = try fixture()
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    model.openSubtitleSearch()
    model.setSubtitleSearchQuery("carries a blue")
    let match = try #require(model.currentSubtitleSearchMatch)
    #expect(match.fragments.count == 3)
    let carryID = try #require(match.fragments.first?.tokenID)
    let carry = try #require(model.timeline?.tokens.first { $0.id == carryID })
    let end = try #require(model.timeline?.tokens.first { $0.surface == "blue" })
    let wide = try reflow(model)
    let narrow = try reflow(model, width: 35)
    for layout in [wide, narrow] {
      let rowID = try #require(layout.rowID(containing: carryID))
      #expect(
        layout.rows.first { $0.id == rowID }?.tokens.contains(where: { $0.id == carryID }) == true)
    }
    model.toggleSubtitleScrollPin(at: carryID)
    #expect(model.subtitlePinnedTokenID == carryID)
    model.pinDictionaryRange(from: carryID, to: end.id)
    #expect(
      model.pinnedExpression?.tokens.filter(\.lexical).map(\.surface) == ["carries", "a", "blue"])
    model.setSubtitleWrapCharacters(20)
    #expect(
      model.subtitlePinnedTokenID == carryID && model.currentSubtitleSearchMatch?.id == match.id)
    model.seekToWord(carry)
    #expect(model.time == carry.startTime && model.bridge.pendingSeekTime == carry.startTime)
    #expect(model.pinnedToken?.id == carryID)
    #expect(model.subtitleSearchResults.highlights[carryID] == [NSRange(location: 0, length: 7)])
    model.toggleSubtitleScrollPin()
    #expect(model.subtitlePinnedTokenID == nil)
  }
  @Test func grammarIndexesAndCurrentWordRemainAccurateWhenSourceLinesShareADisplayRow() throws {
    let (model, defaults, suite) = try fixture()
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    let word = try #require(model.timeline?.tokens.first { $0.surface == "carries" })
    model.grammarEnabledForVideo = true
    model.apply([
      Analysis(
        sentenceId: word.sentenceID, pattern: .SVO,
        spans: [Span(role: .VERB, startToken: word.index, endTokenExclusive: word.index + 1)])
    ])
    model.update(time: word.startTime + 0.001, duration: 10, state: 2)
    let display = try reflow(model)
    let row = try #require(display.rows.first)
    let presentation = SubtitleLinePresentation(
      model: model, line: row, current: true, grammarNearby: true)
    #expect(presentation.emphasized.contains(word.id))
    #expect(
      presentation.analyses[word.sentenceID]?.displaySpans(at: word.index).first?.role == .VERB)
    #expect(presentation.currentSentence?.id == word.sentenceID)
    #expect(row.tokens.first { $0.id == word.id } == word)
  }
  @Test func obsoleteAsyncLayoutsCannotReplaceANewerSession() async throws {
    let (model, defaults, suite) = try fixture()
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    let state = SubtitleDisplayState()
    let old = Task {
      await state.rebuild(
        lines: model.subtitleLines, width: 220, characters: 20, fontScale: 1, grammar: false,
        session: UUID())
    }
    await Task.yield()
    old.cancel()
    await state.rebuild(
      lines: [], width: 1000, characters: 140, fontScale: 1, grammar: false, session: UUID())
    await old.value
    #expect(state.layout.rows.isEmpty)
  }
  @Test func playbackTrackingUsesOriginalWordTimesWithoutRebuildingTheTimeline() throws {
    let (model, defaults, suite) = try fixture()
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    let display = try reflow(model, width: 70)
    let revision = model.subtitleTimelineRevision
    let timeline = try #require(model.timeline)
    let words = timeline.tokens.filter(\.lexical)
    for word in words {
      let time = (word.startTime + word.endTime) / 2
      model.update(time: time, duration: 10, state: 1)
      #expect(model.currentToken?.id == word.id)
      #expect(model.subtitlePlaybackAnchorID == word.id)
      let rowID = try #require(display.rowID(containing: model.subtitlePlaybackAnchorID))
      #expect(display.rows.first { $0.id == rowID }?.tokens.contains(word) == true)
    }
    model.update(time: 9.5, duration: 10, state: 1)
    #expect(model.currentToken == nil && model.subtitlePlaybackAnchorID == words.last?.id)
    #expect(model.subtitleTimelineRevision == revision)
  }

}
