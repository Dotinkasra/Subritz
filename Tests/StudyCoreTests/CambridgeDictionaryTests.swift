import Foundation
import Testing
@testable import StudyCore

struct CambridgeDictionaryTests {
  @Test func captionGapsOpenSearchWithoutReusingThePreviousWord() throws {
    let robot = CambridgeDictionary.destinationURL(for: "robot")
    #expect(robot == CambridgeDictionary.lookupURL(for: "robot"))
    for gap in ["", " \n "] {
      let destination = CambridgeDictionary.destinationURL(for: gap)
      #expect(destination == CambridgeDictionary.searchPageURL)
      #expect(URLComponents(url: destination, resolvingAgainstBaseURL: false)?.queryItems == nil)
    }
    #expect(CambridgeDictionary.destinationURL(for: "signal") == CambridgeDictionary.lookupURL(for: "signal"))
  }
  @Test func searchURLPreservesExpressionsContractionsAndQueryCharacters() throws {
    for (input, expected) in [(" pile   up ", "pile up"), ("I don’t", "I don't"),
      ("a+b & q=other?#", "a+b & q=other?#"), ("café", "café")] {
      let url = try #require(CambridgeDictionary.lookupURL(for: input))
      let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
      #expect(components.scheme == "https" && components.host == "dictionary.cambridge.org")
      #expect(components.path == "/search/english/direct/")
      #expect(components.queryItems == [URLQueryItem(name: "q", value: expected)])
      #expect(!url.absoluteString.contains("+"))
    }
    #expect(CambridgeDictionary.lookupURL(for: " \n ") == nil)
  }
}
