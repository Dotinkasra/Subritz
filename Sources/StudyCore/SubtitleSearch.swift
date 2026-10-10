import Foundation

public struct SubtitleSearchFragment {
  public let tokenID: UUID
  public let range: NSRange
}
public struct SubtitleSearchMatch: Identifiable {
  public var id: Int { range.location }
  public let range: NSRange
  public let lineID: UUID
  public let fragments: [SubtitleSearchFragment]
}
public struct SubtitleSearchResults {
  public var matches: [SubtitleSearchMatch] = []
  public var highlights: [UUID: [NSRange]] = [:]
  public init() {}
}
// The index uses UTF-16 offsets, matching NSString search and AppKit's attributed
// titles. Each offset is mapped back to the original token, including partial
// words and phrases crossing mechanical caption-line boundaries.
public struct SubtitleSearchIndex {
  private struct Location {
    let tokenID: UUID
    let lineID: UUID
    let range: NSRange
  }
  private let text: NSString
  private let locations: [Location]
  public init(lines: [CaptionLine]) {
    var content = ""
    var locations: [Location] = []
    var offset = 0
    for line in lines {
      for token in line.tokens {
        if !content.isEmpty, token.lexical { content += " "; offset += 1 }
        let word = Self.apostrophes(token.surface)
        let length = word.utf16.count
        locations.append(Location(tokenID: token.id, lineID: line.id,
          range: NSRange(location: offset, length: length)))
        content += word
        offset += length
      }
    }
    text = content as NSString
    self.locations = locations
  }
  private static func apostrophes(_ text: String) -> String {
    text.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
  }
  public func search(_ query: String) -> SubtitleSearchResults {
    let query = Self.apostrophes(query).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    var result = SubtitleSearchResults()
    guard !query.isEmpty else { return result }
    var start = 0
    while start < text.length {
      let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
        range: NSRange(location: start, length: text.length - start))
      guard range.location != NSNotFound, range.length > 0 else { break }
      var low = 0, high = locations.count
      while low < high {
        let mid = (low + high) / 2
        if NSMaxRange(locations[mid].range) <= range.location { low = mid + 1 }
        else { high = mid }
      }
      var fragments: [SubtitleSearchFragment] = []
      var index = low
      while index < locations.count, locations[index].range.location < NSMaxRange(range) {
        let location = locations[index]
        let intersection = NSIntersectionRange(range, location.range)
        if intersection.length > 0 {
          let local = NSRange(location: intersection.location - location.range.location, length: intersection.length)
          fragments.append(SubtitleSearchFragment(tokenID: location.tokenID, range: local))
          result.highlights[location.tokenID, default: []].append(local)
        }
        index += 1
      }
      if !fragments.isEmpty {
        result.matches.append(SubtitleSearchMatch(range: range, lineID: locations[low].lineID, fragments: fragments))
      }
      start = NSMaxRange(range)
    }
    return result
  }
}
