import AppKit
import Testing
import StudyCore

@testable import StudyApp

@MainActor struct DictionaryBodyTextTests {
  @Test func structuralTypographyKeepsEveryParagraphSelectable() throws {
    let blocks: [DictionaryBlock] = [
      .init("名詞", role: .partOfSpeech), .init("1 自作義", role: .meaning),
      .init("A paper robot turns.", role: .example), .init("自作例文訳", role: .translation),
      .init("自作用法", role: .note), .init("sampleunit around", role: .phrase),
    ]
    let body = blocks.map(\.text).joined(separator: "\n")
    let view = DictionaryBodyTextView()
    view.update(text: body, fontSize: 19, lineSpacing: 7, blocks: blocks)
    #expect(view.string == body)
    let storage = try #require(view.textStorage)
    let heading = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    let exampleRange = (body as NSString).range(of: "A paper robot turns.")
    let exampleFont = try #require(storage.attribute(.font, at: exampleRange.location, effectiveRange: nil) as? NSFont)
    let paragraph = try #require(storage.attribute(.paragraphStyle, at: exampleRange.location, effectiveRange: nil) as? NSParagraphStyle)
    #expect(heading.pointSize > exampleFont.pointSize && paragraph.headIndent == 20)
    #expect(view.fittingSize(width: 400).height > 0)
    view.setSelectedRange(NSRange(location: 0, length: storage.length))
    #expect((view.string as NSString).substring(with: view.selectedRange()) == body)
  }
  @Test func longRecordRemainsCompleteSelectableAndReflowsWithoutLosingSelection() throws {
    let body = (1...1000).map { "自作の語義\($0)。A paper robot collects blue tiles." }.joined(separator: "\n")
      + "\n自作本文の末尾"
    let view = DictionaryBodyTextView()
    view.update(text: body, fontSize: 19, lineSpacing: 7)
    #expect(view.string == body && view.isSelectable && !view.isEditable)
    let wide = view.fittingSize(width: 700)
    #expect(wide.height.isFinite && wide.height > 1000 && wide.width == 700)
    let selection = NSRange(location: 0, length: (body as NSString).length)
    view.setSelectedRange(selection)
    let narrow = view.fittingSize(width: 250)
    #expect(narrow.height > wide.height && view.selectedRange() == selection)
    #expect((view.string as NSString).substring(with: view.selectedRange()) == body)
    #expect(view.fittingSize(width: nil) == narrow)
    #expect(view.fittingSize(width: .infinity) == narrow)
    #expect(view.fittingSize(width: 0) == .zero)
    #expect(view.fittingSize(width: 250) == narrow)
    // Repeated SwiftUI updates must retain selection and the measured layout.
    view.update(text: body, fontSize: 19, lineSpacing: 7)
    #expect(view.selectedRange() == selection && view.fittingSize(width: 250) == narrow)
    view.update(text: "次の自作本文", fontSize: 19, lineSpacing: 7)
    #expect(view.string == "次の自作本文" && view.fittingSize(width: 250).height < wide.height)
  }

  @Test func sizingProbesCannotLeaveLongBodyClippedAtADifferentViewportWidth() throws {
    let blocks = (1...600).flatMap { index in
      [DictionaryBlock("\(index) 自作の長い語義。A paper robot carries a violet lantern across the room.", role: .meaning),
       DictionaryBlock("Authored example \(index): the copper clock stays beside a blue tower.", role: .example)]
    } + [DictionaryBlock("自作本文の最終段落", role: .meaning)]
    let view = DictionaryBodyTextView()
    view.update(text: blocks.map(\.text).joined(separator: "\n"), fontSize: 19, lineSpacing: 7, blocks: blocks)
    let layout = try #require(view.layoutManager)
    let container = try #require(view.textContainer)
    let selection = NSRange(location: 0, length: (view.string as NSString).length)
    view.setSelectedRange(selection)
    for width: CGFloat in [1400, 350, 900] {
      let size = view.fittingSize(width: width)
      view.setFrameSize(size)
      // A later SwiftUI sizing probe must not change actual drawing geometry.
      _ = view.fittingSize(width: width / 2)
      view.layout()
      layout.ensureLayout(for: container)
      let lastGlyph = layout.boundingRect(forGlyphRange: NSRange(location: layout.numberOfGlyphs - 1, length: 1), in: container)
      #expect(container.containerSize.width == width)
      #expect(lastGlyph.maxY <= view.bounds.height)
      #expect(lastGlyph.maxX <= view.bounds.width)
      #expect(view.selectedRange() == selection)
      #expect(!view.isVerticallyResizable)
    }
  }
}
