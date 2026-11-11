import SwiftUI

/// Anchor the heading to the viewport, rather than centering a block whose
/// height changes when pronunciation or a definition arrives asynchronously.
struct RealtimeDictionaryLayout: Layout {
  let viewportHeight: CGFloat
  var spacing: CGFloat = 22

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    guard let heading = sizes.first else { return CGSize(width: width, height: viewportHeight) }
    let top = max(0, (viewportHeight - heading.height) / 2)
    let details = sizes.dropFirst().filter { $0.height > 0 }
      .reduce(CGFloat.zero) { $0 + spacing + $1.height }
    return CGSize(width: width,
      height: max(viewportHeight, top + heading.height + details))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let heading = subviews.first else { return }
    let width = ProposedViewSize(width: bounds.width, height: nil)
    let headingSize = heading.sizeThatFits(width)
    var y = bounds.minY + max(0, (viewportHeight - headingSize.height) / 2)
    for (index, view) in subviews.enumerated() {
      let size = view.sizeThatFits(width)
      if index > 0, size.height > 0 { y += spacing }
      view.place(at: CGPoint(x: bounds.midX, y: y), anchor: .top,
        proposal: ProposedViewSize(width: bounds.width, height: size.height))
      y += size.height
    }
  }
}
