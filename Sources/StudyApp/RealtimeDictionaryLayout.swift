import AppKit
import SwiftUI

/// Reserve one line even when pronunciation is absent or switched off, so
/// neither the heading nor the translation moves as pronunciation changes.
struct RealtimePronunciationSlot: View {
  let value: String?
  private let size: CGFloat = 22

  var body: some View {
    let font = NSFont.systemFont(ofSize: size, weight: .medium)
    Color.clear
      .frame(height: ceil(font.ascender - font.descender + font.leading))
      .overlay {
        DictionaryPronunciation(value: value, size: size)
          .lineLimit(1).minimumScaleFactor(0.5)
          .multilineTextAlignment(.center)
      }
  }
}

/// Anchor the heading to the viewport, rather than centering a block whose
/// height changes when pronunciation or a definition arrives asynchronously.
struct RealtimeDictionaryLayout: Layout {
  let viewportHeight: CGFloat
  var headingIndex: Int = 0
  var spacing: CGFloat = 22

  private func topOffset(for sizes: [CGSize]) -> CGFloat {
    guard sizes.indices.contains(headingIndex) else { return 0 }
    let preceding = sizes.prefix(headingIndex).enumerated().reduce(CGFloat.zero) {
      $0 + $1.element.height + ($1.offset > 0 && $1.element.height > 0 ? spacing : 0)
    } + (headingIndex > 0 && sizes[headingIndex].height > 0 ? spacing : 0)
    return max(0, (viewportHeight - sizes[headingIndex].height) / 2 - preceding)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    guard let first = sizes.first else { return CGSize(width: width, height: viewportHeight) }
    let top = topOffset(for: sizes)
    let details = sizes.dropFirst().filter { $0.height > 0 }
      .reduce(CGFloat.zero) { $0 + spacing + $1.height }
    return CGSize(width: width,
      height: max(viewportHeight, top + first.height + details))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let width = ProposedViewSize(width: bounds.width, height: nil)
    let sizes = subviews.map { $0.sizeThatFits(width) }
    var y = bounds.minY + topOffset(for: sizes)
    for (index, view) in subviews.enumerated() {
      let size = view.sizeThatFits(width)
      if index > 0, size.height > 0 { y += spacing }
      view.place(at: CGPoint(x: bounds.midX, y: y), anchor: .top,
        proposal: ProposedViewSize(width: bounds.width, height: size.height))
      y += size.height
    }
  }
}
