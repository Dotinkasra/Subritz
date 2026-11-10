import AppKit
import SwiftUI
import Testing

@testable import StudyApp
@testable import StudyCore

@MainActor struct VirtualSubtitleListTests {
  @Test func distantPlaybackAndSearchTargetsStayExactAfterCharacterChanges() throws {
    let (model, defaults, suite) = try SubtitleReflowTests().fixture()
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    let timeline = try #require(model.timeline)
    let word = try #require(timeline.tokens.first { $0.surface == "towers" })
    model.update(time: (word.startTime + word.endTime) / 2, duration: 10, state: 2)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 100))
    let table = NSTableView()
    table.addTableColumn(NSTableColumn(identifier: .init("subtitle")))
    let coordinator = VirtualSubtitleList.Coordinator()
    table.dataSource = coordinator
    table.delegate = coordinator
    scroll.documentView = table
    coordinator.connect(scroll: scroll, table: table)
    defer { coordinator.disconnect() }
    func update(_ layout: SubtitleReflow, revision: Int) {
      coordinator.update(VirtualSubtitleList(model: model, layout: layout, revision: revision,
        rowHeight: 60, viewportHeight: 100, onVisibleRow: { _ in }))
    }
    let wide = try SubtitleReflowTests().reflow(model)
    update(wide, revision: 1)
    let target = try #require(wide.tokenRows[word.id]) + 1
    #expect(table.numberOfRows == wide.rows.count + 2)
    #expect(scroll.contentView.bounds.intersects(table.rect(ofRow: target)))
    let narrow = try SubtitleReflowTests().reflow(model, width: 35)
    update(narrow, revision: 2)
    let newTarget = try #require(narrow.tokenRows[word.id]) + 1
    #expect(table.numberOfRows == narrow.rows.count + 2)
    #expect(scroll.contentView.bounds.intersects(table.rect(ofRow: newTarget)))
    #expect(model.currentToken?.id == word.id && model.time == (word.startTime + word.endTime) / 2)
    model.openSubtitleSearch()
    model.setSubtitleSearchQuery("paper robot")
    update(narrow, revision: 2)
    let match = try #require(model.currentSubtitleSearchMatch?.fragments.first?.tokenID)
    let searchRow = try #require(narrow.tokenRows[match]) + 1
    #expect(scroll.contentView.bounds.intersects(table.rect(ofRow: searchRow)))
    model.closeSubtitleSearch()
    update(narrow, revision: 2)
    #expect(scroll.contentView.bounds.intersects(table.rect(ofRow: newTarget)))
    model.suspendVideoSubtitleFollowing()
    scroll.contentView.scroll(to: .zero)
    let nextWord = try #require(timeline.tokens.first { $0.surface == "garden" })
    model.update(time: (nextWord.startTime + nextWord.endTime) / 2, duration: 10, state: 1)
    update(narrow, revision: 2)
    #expect(scroll.contentView.bounds.origin.y == 0)
    #expect(!model.videoSubtitleAutoFollow && model.currentToken?.id == nextWord.id)
    model.resumeVideoSubtitleFollowing()
    update(narrow, revision: 2)
    let resumedRow = try #require(narrow.tokenRows[nextWord.id]) + 1
    #expect(scroll.contentView.bounds.intersects(table.rect(ofRow: resumedRow)))
  }

  @Test func pendingCharacterInputDoesNotRecreateAlreadyReflowedWordControls() throws {
    let (model, defaults, suite) = try SubtitleReflowTests().fixture()
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    let layout = try SubtitleReflowTests().reflow(model)
    let row = try #require(layout.rows.first)
    let before = SubtitleLinePresentation(model: model, line: row, current: true,
      grammarNearby: false, wrapCharacters: Int.max)
    model.setSubtitleWrapCharacters(20)
    let pending = SubtitleLinePresentation(model: model, line: row, current: true,
      grammarNearby: false, wrapCharacters: Int.max)
    #expect(before == pending)
    #expect(model.subtitleWrapCharacters == 20)
  }
}
