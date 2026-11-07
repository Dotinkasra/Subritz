import AppKit
import SwiftUI

/// Keep the hosted panes alive while changing only their proposed sizes.
/// Fractions belong to MainView so Reset never recreates the video or capture.
struct WorkspaceSplitView<Leading: View, Dictionary: View, Subtitles: View>: View {
  @Binding var upperFraction: CGFloat
  @Binding var leadingFraction: CGFloat
  @ViewBuilder let leading: () -> Leading
  @ViewBuilder let dictionary: () -> Dictionary
  @ViewBuilder let subtitles: () -> Subtitles
  private let divider: CGFloat = 8

  var body: some View {
    GeometryReader { geometry in
      let width = max(0, geometry.size.width - divider)
      let height = max(0, geometry.size.height - divider)
      let leadingWidth = position(leadingFraction, total: width, firstMinimum: 360, secondMinimum: 420)
      let upperHeight = position(upperFraction, total: height, firstMinimum: 280, secondMinimum: 180)
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          leading().frame(width: leadingWidth, height: upperHeight)
          WorkspaceDivider(vertical: true, fraction: $leadingFraction,
            label: "辞書との境界", extent: width) { fraction in
            leadingFraction = position(fraction, total: width,
              firstMinimum: 360, secondMinimum: 420) / max(1, width)
          }.frame(width: divider)
          dictionary().frame(width: max(0, width - leadingWidth), height: upperHeight)
        }.frame(height: upperHeight)
        WorkspaceDivider(vertical: false, fraction: $upperFraction,
          label: "字幕との境界", extent: height) { fraction in
          upperFraction = position(fraction, total: height,
            firstMinimum: 280, secondMinimum: 180) / max(1, height)
        }.frame(height: divider)
        subtitles().frame(height: max(0, height - upperHeight))
      }.frame(width: geometry.size.width, height: geometry.size.height)
        .coordinateSpace(name: "study-workspace")
    }
  }
  private func position(_ fraction: CGFloat, total: CGFloat, firstMinimum: CGFloat, secondMinimum: CGFloat) -> CGFloat {
    let maximum = max(0, total - secondMinimum)
    return min(maximum, max(min(firstMinimum, maximum), total * fraction))
  }
}

private struct WorkspaceDivider: NSViewRepresentable {
  let vertical: Bool
  @Binding var fraction: CGFloat
  let label: String
  let extent: CGFloat
  let onChange: (CGFloat) -> Void
  func makeNSView(context: Context) -> DividerHandle { DividerHandle() }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: DividerHandle, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 8, height: proposal.height ?? 8)
  }
  func updateNSView(_ view: DividerHandle, context: Context) {
    view.vertical = vertical
    view.fraction = fraction
    view.extent = extent
    view.onChange = onChange
    view.toolTip = "ドラッグして" + (vertical ? "左右の幅" : "上下の高さ") + "を変更"
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.splitter)
    view.setAccessibilityLabel(label)
    view.setAccessibilityValueDescription("\(Int(fraction * 100))%")
    view.needsDisplay = true
    view.window?.invalidateCursorRects(for: view)
  }

  final class DividerHandle: NSView {
    var vertical = false
    var fraction: CGFloat = 0.5
    var extent: CGFloat = 1
    var onChange: ((CGFloat) -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
      addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown)
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(rect: .zero,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
      addTrackingArea(area)
      tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.windowBackgroundColor.setFill()
      bounds.fill()
      NSColor.separatorColor.setFill()
      let line = vertical ? NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
        : NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
      line.fill()
      (hovered ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
      let grip = vertical ? NSRect(x: bounds.midX - 1.5, y: bounds.midY - 18, width: 3, height: 36)
        : NSRect(x: bounds.midX - 18, y: bounds.midY - 1.5, width: 36, height: 3)
      NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func mouseDown(with event: NSEvent) {
      guard let window else { return }
      let origin = event.locationInWindow
      let initial = fraction
      let size = max(1, extent)
      while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
        let distance = vertical ? next.locationInWindow.x - origin.x : origin.y - next.locationInWindow.y
        onChange?(initial + distance / size)
        if next.type == .leftMouseUp { break }
      }
    }
    override func accessibilityPerformIncrement() -> Bool { onChange?(fraction + 0.05); return true }
    override func accessibilityPerformDecrement() -> Bool { onChange?(fraction - 0.05); return true }
  }
}
