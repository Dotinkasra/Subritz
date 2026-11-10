import SwiftUI

struct SubtitleCharacterCount: LayoutValueKey { static let defaultValue = 0 }

struct FlowLayout: Layout {
  var spacing: CGFloat = 5
  var maximumCharacters: Int = .max
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? 1000, subviews: subviews).size
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let layout = arrange(width: bounds.width, subviews: subviews)
    for i in subviews.indices {
      subviews[i].place(
        at: CGPoint(x: bounds.minX + layout.points[i].x, y: bounds.minY + layout.points[i].y),
        proposal: .unspecified)
    }
  }
  func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
    Self.pack(
      sizes: subviews.map { $0.sizeThatFits(.unspecified) },
      characters: subviews.map { $0[SubtitleCharacterCount.self] },
      width: width, maximumCharacters: maximumCharacters, spacing: spacing)
  }
  static func pack(
    sizes: [CGSize], characters: [Int], width: CGFloat, maximumCharacters: Int,
    spacing: CGFloat
  ) -> (size: CGSize, points: [CGPoint]) {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var row: CGFloat = 0
    var count = 0
    var points: [CGPoint] = []
    for (index, size) in sizes.enumerated() {
      let length = characters.indices.contains(index) ? characters[index] : 0
      if x > 0 && (x + size.width > width || count + 1 + length > maximumCharacters) {
        x = 0
        y += row + spacing
        row = 0
        count = 0
      }
      points.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      row = max(row, size.height)
      count += (count == 0 ? 0 : 1) + length
    }
    return (CGSize(width: width, height: y + row), points)
  }
}
