import SwiftUI

/// Punctuation is text, not a disabled control: AppKit's disabled-button tint
/// must never override the active caption row's foreground color on redraw.
struct SubtitlePunctuation: View {
  let title: String
  let size: CGFloat
  let current: Bool
  var searchRanges: [NSRange] = []
  var activeSearchRanges: [NSRange] = []

  var attributedTitle: AttributedString {
    var text = AttributedString(title)
    text.font = .system(size: size, weight: current ? .medium : .regular)
    text.foregroundColor = current ? Color.primary : Color.secondary
    for (ranges, color) in [(searchRanges, Color.yellow), (activeSearchRanges, Color.orange)] {
      for range in ranges {
        guard let source = Range(range, in: title),
          let start = AttributedString.Index(source.lowerBound, within: text),
          let end = AttributedString.Index(source.upperBound, within: text)
        else { continue }
        text[start..<end].backgroundColor = color
        text[start..<end].foregroundColor = .black
      }
    }
    return text
  }
  var body: some View {
    Text(attributedTitle).fixedSize().padding(.horizontal, 2).padding(.vertical, 3)
      .allowsHitTesting(false)
  }
}
