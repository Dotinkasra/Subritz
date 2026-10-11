import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

@MainActor struct SubtitleLinePresentationTests {
  @Test func hundredsOfVisitedRowsOnlyChangeAtTheAffectedRows() throws {
    let events = (0..<500).map { index in
      ["tStartMs": index * 4000, "dDurationMs": 1900,
        "segs": [["utf8": "Silver robots wait."]]] as [String: Any]
    }
    let raw = try JSONSerialization.data(withJSONObject: ["events": events])
    let sentences = try CaptionPipeline().parse(raw, videoID: "test")
    let model = StudyModel(prepareStorage: false)
    model.timeline = Timeline(sentences)
    model.document = StudyDocument(video: Video(id: "test", title: "Test", duration: 2000),
      rawCaption: raw, sentences: sentences)
    model.grammarEnabledForVideo = false
    let lines = model.subtitleLines
    try #require(lines.count == 500)
    for destination in [1, 250, 499] {
      model.currentLineIndex = destination - 1
      model.currentToken = lines[destination - 1].tokens[0]
      let before = lines.map { SubtitleLinePresentation(model: model, line: $0) }
      model.currentLineIndex = destination
      model.currentToken = lines[destination].tokens[0]
      let after = lines.map { SubtitleLinePresentation(model: model, line: $0) }
      #expect(zip(before, after).filter { $0 != $1 }.count == 2)
      model.playbackPosition.time = Double(destination * 4000) / 1000 + 0.2
      model.dictionaryLoading = true
      model.dictionaryEntry = DictionaryEntry(definition: "Self-authored entry", shortGloss: "意味")
      let unrelated = lines.map { SubtitleLinePresentation(model: model, line: $0) }
      #expect(unrelated == after)
    }
  }

  @Test func wordHighlightsSelectionAndSearchUpdateTheirOwnRows() throws {
    let (model, words) = try DictionaryPinTests().fixture(realtime: false)
    model.grammarEnabledForVideo = false
    let lines = model.subtitleLines
    let first = SubtitleLinePresentation(model: model, line: lines[0])
    let second = SubtitleLinePresentation(model: model, line: lines[1])
    model.currentToken = words[1]
    #expect(SubtitleLinePresentation(model: model, line: lines[0]) != first)
    #expect(SubtitleLinePresentation(model: model, line: lines[1]) == second)
    model.pinDictionaryRange(from: words[2].id, to: words[3].id)
    let pinned = SubtitleLinePresentation(model: model, line: lines[1])
    #expect(pinned.selected == Set([words[2].id, words[3].id]))
    model.releaseDictionaryPin()
    #expect(SubtitleLinePresentation(model: model, line: lines[1]).selected.isEmpty)
    model.openSubtitleSearch()
    model.setSubtitleSearchQuery("read")
    let searched = SubtitleLinePresentation(model: model, line: lines[1])
    #expect(searched.searchRanges[words[3].id] == [NSRange(location: 0, length: 4)])
    #expect(searched.activeSearchRanges == searched.searchRanges)
    model.closeSubtitleSearch()
    #expect(SubtitleLinePresentation(model: model, line: lines[1]).searchRanges.isEmpty)
  }

  @Test func grammarCompletionAndSessionReplacementInvalidateTheRow() throws {
    let (model, _) = try DictionaryPinTests().fixture(realtime: false)
    let line = model.subtitleLines[0]
    let before = SubtitleLinePresentation(model: model, line: line)
    let owner = try #require(model.currentSentence)
    model.apply([Analysis(sentenceId: owner.id, pattern: .SV,
      spans: [Span(role: .SUBJECT, startToken: 0, endTokenExclusive: 1),
        Span(role: .VERB, startToken: 1, endTokenExclusive: 2)])])
    let completed = SubtitleLinePresentation(model: model, line: line)
    #expect(completed != before)
    #expect(completed.analyses[owner.id]?.pattern == .SV)
    #expect(completed.currentSentence?.grammarStatus == .completed)
    model.session = UUID()
    #expect(SubtitleLinePresentation(model: model, line: line) != completed)
    model.grammarEnabledForVideo = false
    let disabled = SubtitleLinePresentation(model: model, line: line)
    #expect(!disabled.grammarEnabled && disabled.analyses.isEmpty && disabled.currentSentence == nil)
  }
}
