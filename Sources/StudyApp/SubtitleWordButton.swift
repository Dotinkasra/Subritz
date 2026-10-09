import AppKit
import SwiftUI

// Native clickCount preserves immediate single-click pinning without competing
// SwiftUI tap recognizers or a delay for the macOS double-click interval.
struct SubtitleWordButton: NSViewRepresentable {
  let title: String
  let size: CGFloat
  let current: Bool
  let enabled: Bool
  let onClick: () -> Void
  let onDoubleClick: () -> Void
  func makeNSView(context: Context) -> WordButton {
    WordButton(frame: .zero)
  }
  func updateNSView(_ view: WordButton, context: Context) {
    let font = NSFont.systemFont(ofSize: size, weight: current ? .medium : .regular)
    let attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: font,
        .foregroundColor: current ? NSColor.labelColor : NSColor.secondaryLabelColor,
      ])
    if !view.attributedTitle.isEqual(to: attributedTitle) {
      view.title = title
      view.font = font
      view.attributedTitle = attributedTitle
      view.invalidateIntrinsicContentSize()
    }
    view.isEnabled = enabled
    view.onClick = onClick
    view.onDoubleClick = onDoubleClick
    view.toolTip = enabled ? "クリックで辞書を固定 · ダブルクリックで発話位置へ移動" : nil
    view.setAccessibilityLabel(title)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: WordButton, context: Context) -> CGSize? {
    nsView.intrinsicContentSize
  }
  @MainActor final class WordButton: NSButton {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    override init(frame: NSRect) {
      super.init(frame: frame)
      isBordered = false
      setButtonType(.momentaryPushIn)
      target = self
      action = #selector(clicked)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc func clicked() { if isEnabled { onClick?() } }
    override func mouseDown(with event: NSEvent) {
      guard isEnabled else { return }
      if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
    override var intrinsicContentSize: NSSize {
      let textSize = attributedTitle.size()
      return NSSize(width: ceil(textSize.width) + 4, height: ceil(textSize.height) + 6)
    }
  }
}
