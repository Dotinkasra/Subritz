import Foundation
import Testing
@testable import StudyCore

struct SubtitleSearchTests {
  func lines(_ words: [[String]]) -> [CaptionLine] {
    words.enumerated().map { index, words in
      let tokens = words.enumerated().map { offset, surface in
        Token(index: offset, surface: surface, normalized: surface.lowercased(),
          startTime: Double(index * 10 + offset), endTime: Double(index * 10 + offset + 1),
          timingQuality: .estimated, lexical: surface.rangeOfCharacter(from: .alphanumerics) != nil)
      }
      return CaptionLine(id: UUID(), index: index, tokens: tokens)
    }
  }
  @Test func caseInsensitivePartialMatchesHavePreciseTokenHighlights() {
    let lines = lines([["Banana", "robot", "."], ["ROBOT", "copper", "."]])
    let index = SubtitleSearchIndex(lines: lines)
    let partial = index.search("an")
    #expect(partial.matches.count == 2)
    #expect(partial.highlights[lines[0].tokens[0].id] == [NSRange(location: 1, length: 2), NSRange(location: 3, length: 2)])
    let repeated = index.search("rObOt")
    #expect(repeated.matches.map(\.lineID) == lines.map(\.id))
    #expect(repeated.highlights.count == 2)
    #expect(repeated.highlights[lines[1].tokens[0].id] == [NSRange(location: 0, length: 5)])
  }
  @Test func phrasesCrossCaptionBoundariesAndNormalizeQueryWhitespace() {
    let lines = lines([["a", "silver"], ["robot", "builds", "a", "tower", "."]])
    let result = SubtitleSearchIndex(lines: lines).search("SILVER  \n robot")
    #expect(result.matches.count == 1)
    #expect(result.matches.first?.lineID == lines[0].id)
    #expect(result.matches.first?.fragments.map(\.tokenID) == [lines[0].tokens[1].id, lines[1].tokens[0].id])
    #expect(result.highlights[lines[0].tokens[1].id] == [NSRange(location: 0, length: 6)])
    #expect(result.highlights[lines[1].tokens[0].id] == [NSRange(location: 0, length: 5)])
  }
  @Test func apostrophesUnicodeAndPunctuationPreserveOriginalOffsets() {
    let lines = lines([["🛰café", "don’t", "wait", "."]])
    let index = SubtitleSearchIndex(lines: lines)
    let unicode = index.search("CAFE")
    #expect(unicode.highlights[lines[0].tokens[0].id] == [NSRange(location: 2, length: 4)])
    let apostrophe = index.search("don't")
    #expect(apostrophe.highlights[lines[0].tokens[1].id] == [NSRange(location: 0, length: 5)])
    let punctuation = index.search("wait.")
    #expect(punctuation.matches.count == 1 && punctuation.highlights.count == 2)
    #expect(index.search(".").matches.count == 1)
    #expect(index.search(".*").matches.isEmpty) // Literal text, not a regular expression.
  }
  @Test func emptyAndMissingQueriesHaveNoHighlights() {
    let index = SubtitleSearchIndex(lines: lines([["silver", "robot"]]))
    for query in ["", " \n\t ", "unlisted"] {
      #expect(index.search(query).matches.isEmpty && index.search(query).highlights.isEmpty)
    }
    #expect(SubtitleSearchIndex(lines: []).search("robot").matches.isEmpty)
  }
}
