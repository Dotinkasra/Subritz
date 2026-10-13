import Foundation

public enum CambridgeDictionary {
  public static let searchPageURL = URL(string: "https://dictionary.cambridge.org/dictionary/english/")!
  public static func destinationURL(for word: String) -> URL {
    lookupURL(for: word) ?? searchPageURL
  }
  /// Uses the English search endpoint published in Cambridge's search-box widget.
  /// https://dictionary.cambridge.org/freesearch.html
  public static func lookupURL(for word: String) -> URL? {
    let query = word.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      .replacingOccurrences(of: "’", with: "'")
    guard !query.isEmpty else { return nil }
    var components = URLComponents(string: "https://dictionary.cambridge.org/search/english/direct/")!
    components.queryItems = [URLQueryItem(name: "q", value: query)]
    // Literal '+' must not be interpreted as a form-encoded space by the search endpoint.
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return components.url
  }
}
