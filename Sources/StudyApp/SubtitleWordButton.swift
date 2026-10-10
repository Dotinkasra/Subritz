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
  var selectionID: UUID? = nil
  var selectionScope: UUID? = nil
  var onDrag: ((UUID) -> Void)? = nil
  var onDragState: ((Bool) -> Void)? = nil
  var searchRanges: [NSRange] = []
  var activeSearchRanges: [NSRange] = []
  func makeNSView(context: Context) -> WordButton {
    WordButton(frame: .zero)
  }
  func updateNSView(_ view: WordButton, context: Context) {
    let font = NSFont.systemFont(ofSize: size, weight: current ? .medium : .regular)
    let attributedTitle = NSMutableAttributedString(
      string: title,
      attributes: [
        .font: font,
        .foregroundColor: current ? NSColor.labelColor : NSColor.secondaryLabelColor,
      ])
    for (ranges, color) in [(searchRanges, NSColor.systemYellow), (activeSearchRanges, NSColor.systemOrange)] {
      for range in ranges where range.location >= 0 && NSMaxRange(range) <= attributedTitle.length {
        attributedTitle.addAttributes([.backgroundColor: color, .foregroundColor: NSColor.black], range: range)
      }
    }
    if !view.attributedTitle.isEqual(to: attributedTitle) {
      view.title = title
      view.font = font
      view.attributedTitle = attributedTitle
      view.invalidateIntrinsicContentSize()
    }
    view.isEnabled = enabled
    view.onClick = onClick
    view.onDoubleClick = onDoubleClick
    view.selectionID = selectionID
    view.selectionScope = selectionScope
    view.onDrag = onDrag
    view.onDragState = onDragState
    view.toolTip = enabled ? "クリックで辞書を固定 · 再クリックまたはEscで選択解除 · ドラッグで複数語を選択 · ダブルクリックで発話位置へ移動" : nil
    view.setAccessibilityLabel(title)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: WordButton, context: Context) -> CGSize? {
    nsView.intrinsicContentSize
  }
  @MainActor final class WordButton: NSButton {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var selectionID: UUID?
    var selectionScope: UUID?
    var onDrag: ((UUID) -> Void)?
    var onDragState: ((Bool) -> Void)?
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
      if event.clickCount == 2 { onDoubleClick?(); return }
      guard let onDrag, let window, let scope = selectionScope else {
        super.mouseDown(with: event); return
      }
      clicked()
      let origin = event.locationInWindow
      var dragging = false
      defer { if dragging { onDragState?(false) } }
      while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
        inMode: .eventTracking, dequeue: true) {
        if hypot(next.locationInWindow.x - origin.x, next.locationInWindow.y - origin.y) >= 4 {
          if !dragging { dragging = true; onDragState?(true) }
          if let endpoint = Self.endpoint(at: next.locationInWindow, window: window, scope: scope) {
            onDrag(endpoint)
          }
        }
        if next.type == .leftMouseUp { break }
      }
    }
    static func endpoint(at point: NSPoint, window: NSWindow, scope: UUID) -> UUID? {
      guard let root = window.contentView else { return nil }
      var closest: (UUID, CGFloat)?
      func visit(_ view: NSView) {
        guard !view.isHidden else { return }
        if let button = view as? WordButton, button.isEnabled,
          button.selectionScope == scope, let id = button.selectionID {
          let frame = button.convert(button.bounds, to: nil)
          if point.y >= frame.minY - 3 && point.y <= frame.maxY + 3 {
            let distance = max(0, max(frame.minX - point.x, point.x - frame.maxX))
            if distance < 40, closest == nil || distance < closest!.1 { closest = (id, distance) }
          }
        }
        for child in view.subviews { visit(child) }
      }
      visit(root)
      return closest?.0
    }
    override var intrinsicContentSize: NSSize {
      let textSize = attributedTitle.size()
      return NSSize(width: ceil(textSize.width) + 4, height: ceil(textSize.height) + 6)
    }
  }
}
