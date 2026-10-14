import AppKit
import StudyCore
import SwiftUI

/// A continuous, selectable dictionary body. SwiftUI's Text measures a long
/// record at speculative widths during stack layout, blocking the main thread.
/// TextKit lays it out at the available width and reuses that layout for drawing.
struct DictionaryBodyText: NSViewRepresentable {
  let text: String
  var blocks: [DictionaryBlock] = []
  var fontSize: CGFloat = 19
  var lineSpacing: CGFloat = 7

  func makeNSView(context: Context) -> DictionaryBodyTextView {
    DictionaryBodyTextView()
  }
  func updateNSView(_ view: DictionaryBodyTextView, context: Context) {
    view.update(text: text, fontSize: fontSize, lineSpacing: lineSpacing, blocks: blocks)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: DictionaryBodyTextView,
    context: Context) -> CGSize? {
    nsView.fittingSize(width: proposal.width)
  }
}

final class DictionaryBodyTextView: NSTextView {
  private var contentFontSize: CGFloat = 0
  private var contentLineSpacing: CGFloat = 0
  private var measuredSize: CGSize?
  private var contentText = ""
  private var contentBlocks: [DictionaryBlock] = []

  init() {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    super.init(frame: .zero, textContainer: container)
    container.lineFragmentPadding = 0
    container.widthTracksTextView = false
    container.heightTracksTextView = false
    layout.backgroundLayoutEnabled = false
    isEditable = false
    isSelectable = true
    isRichText = false
    drawsBackground = false
    // SwiftUI owns the frame. NSTextView's automatic resizing would compete
    // with the height returned from sizeThatFits for long records.
    isVerticallyResizable = false
    isHorizontallyResizable = false
    textContainerInset = .zero
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    synchronizeViewportWidth()
  }

  override func layout() {
    super.layout()
    synchronizeViewportWidth()
  }

  private func synchronizeViewportWidth() {
    guard bounds.width > 0, bounds.width.isFinite,
      textContainer?.containerSize.width != bounds.width else { return }
    _ = fittingSize(width: bounds.width)
    invalidateIntrinsicContentSize()
  }

  func update(text: String, fontSize: CGFloat, lineSpacing: CGFloat, blocks: [DictionaryBlock] = []) {
    guard contentText != text || contentBlocks != blocks
      || contentFontSize != fontSize || contentLineSpacing != lineSpacing else { return }
    contentText = text
    contentBlocks = blocks
    contentFontSize = fontSize
    contentLineSpacing = lineSpacing
    let body = NSMutableAttributedString(string: "")
    let paragraphs = blocks.isEmpty ? [DictionaryBlock(text, role: .body)] : blocks
    for (index, block) in paragraphs.enumerated() {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = lineSpacing
      paragraph.lineBreakMode = .byWordWrapping
      paragraph.paragraphSpacing = 9
      var size = fontSize
      var weight = NSFont.Weight.regular
      var color = NSColor.labelColor
      switch block.role {
      case .partOfSpeech:
        size = fontSize; weight = .bold; color = .controlAccentColor
        paragraph.paragraphSpacingBefore = 18
      case .phrase:
        weight = .semibold; color = .controlAccentColor
        paragraph.paragraphSpacingBefore = 16
      case .meaning: weight = .medium
      case .example, .translation:
        size = max(13, fontSize - 2); color = .secondaryLabelColor
        paragraph.headIndent = 20; paragraph.firstLineHeadIndent = 20
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = block.role == .translation ? 12 : 4
      case .note, .metadata:
        size = max(12, fontSize - 4); color = .secondaryLabelColor
        paragraph.lineSpacing = 4
        paragraph.headIndent = 12; paragraph.firstLineHeadIndent = 12
      case .body: break
      }
      body.append(NSAttributedString(string: block.text + (index == paragraphs.count - 1 ? "" : "\n"), attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        .paragraphStyle: paragraph,
      ]))
    }
    textStorage?.setAttributedString(body)
    measuredSize = nil
  }
  func fittingSize(width proposedWidth: CGFloat?) -> CGSize {
    // Zero/infinite proposals are stack sizing probes, not a readable viewport.
    // Never shape the whole record as one unbounded line or one-character lines.
    guard proposedWidth != 0 else { return .zero }
    let width = proposedWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
      ?? measuredSize?.width ?? 600
    if let measuredSize, measuredSize.width == width { return measuredSize }
    guard let textContainer, let layoutManager else { return .zero }
    textContainer.containerSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    layoutManager.ensureLayout(for: textContainer)
    let rect = layoutManager.usedRect(for: textContainer)
    let height = ceil(max(rect.maxY, layoutManager.extraLineFragmentRect.maxY))
    let size = CGSize(width: width, height: height)
    measuredSize = size
    // SwiftUI may probe another width after assigning the frame without
    // assigning that same frame again. Restore the viewport before drawing.
    needsLayout = true
    return size
  }
}
