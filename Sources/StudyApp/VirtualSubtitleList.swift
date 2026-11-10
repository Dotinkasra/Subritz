import AppKit
import StudyCore
import SwiftUI

/// Reflow changes almost every row's first token. A lazy SwiftUI stack retains
/// visited word controls and resolves distant scroll targets by laying them out.
/// A table keeps only viewport cells alive and knows every row's offset directly.
/// Grammar and live speech retain their variable-height scroll implementation.
struct VirtualSubtitleList: NSViewRepresentable {
  let model: StudyModel
  let layout: SubtitleReflow
  let revision: Int
  let rowHeight: CGFloat
  let viewportHeight: CGFloat
  let onVisibleRow: (UUID?) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.drawsBackground = false
    let table = NSTableView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subtitle"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .none
    table.intercellSpacing = NSSize(width: 0, height: 8)
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.focusRingType = .none
    table.autoresizingMask = [.width]
    table.dataSource = context.coordinator
    table.delegate = context.coordinator
    scroll.documentView = table
    context.coordinator.connect(scroll: scroll, table: table)
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.update(self)
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.disconnect()
  }

  @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var input: VirtualSubtitleList?
    private weak var scroll: NSScrollView?
    private weak var table: NSTableView?
    private var observer: NSObjectProtocol?
    private var target: UUID?
    private var session: UUID?
    private var revision = -1
    private var rowHeight: CGFloat = 0
    private var padding: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    private var searching = false
    private var pinned = false
    private var dragging = false
    private var playing = false
    private var visibleID: UUID?
    private var publication: Task<Void, Never>?

    func connect(scroll: NSScrollView, table: NSTableView) {
      self.scroll = scroll
      self.table = table
      scroll.contentView.postsBoundsChangedNotifications = true
      observer = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.publishVisibleRow() }
      }
    }
    func disconnect() {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      publication?.cancel()
      table?.delegate = nil
      table?.dataSource = nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
      guard let input, !input.layout.rows.isEmpty else { return 0 }
      return input.layout.rows.count + 2 // Empty top/bottom rows permit centering the ends.
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard let input else { return 1 }
      return row == 0 || row == input.layout.rows.count + 1 ? max(1, padding) : rowHeight
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      guard let input, input.layout.rows.indices.contains(row - 1) else { return NSView() }
      let identifier = NSUserInterfaceItemIdentifier("subtitle-row")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SubtitleCell
        ?? SubtitleCell(rootView: AnyView(EmptyView()))
      cell.identifier = identifier
      configure(cell, row: row - 1, input: input)
      return cell
    }
    private func configure(_ cell: SubtitleCell, row: Int, input: VirtualSubtitleList) {
      let line = input.layout.rows[row]
      let currentID = input.layout.rowID(containing: input.model.currentToken?.id
        ?? input.model.subtitlePlaybackAnchorID)
      let presentation = SubtitleLinePresentation(model: input.model, line: line,
        current: currentID == line.id, grammarNearby: false, wrapCharacters: Int.max)
      let pin = input.model.subtitleScrollPinned && input.layout.rowID(
        containing: input.model.subtitlePinnedTokenID ?? input.model.subtitlePinnedLineID) == line.id
      guard cell.line != line || cell.presentation != presentation || cell.pinned != pin
        || cell.height != rowHeight else { return }
      cell.line = line
      cell.presentation = presentation
      cell.pinned = pin
      cell.height = rowHeight
      cell.rootView = AnyView(
        SubtitleLineView(model: input.model, line: line, presentation: presentation)
          .equatable()
          .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .center)
          .contentShape(Rectangle())
          .onTapGesture(count: 2) { input.model.toggleSubtitleScrollPin(at: line.id) }
          .overlay {
            if pin {
              RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 2)
                .allowsHitTesting(false)
            }
          })
    }
    func update(_ next: VirtualSubtitleList) {
      guard let table, let scroll else { return }
      let model = next.model
      let changed = revision != next.revision || session != model.session
      let newPadding = max(0, (next.viewportHeight - 60) / 3)
      let font = NSFont.systemFont(ofSize: SubtitleAppearance.fontSize(current: true,
        scale: model.subtitleFontScale), weight: .medium)
      let height = max(next.rowHeight, ceil(font.ascender - font.descender + font.leading) + 18)
      let dimensionsChanged = rowHeight != height || viewportHeight != next.viewportHeight
      let wasSearching = searching
      let wasPinned = pinned
      let wasDragging = dragging
      let wasPlaying = playing
      input = next
      revision = next.revision
      session = model.session
      rowHeight = height
      viewportHeight = next.viewportHeight
      padding = newPadding
      searching = model.browsingSubtitleSearch
      pinned = model.subtitleScrollPinned
      dragging = model.draggingDictionarySelection
      playing = model.playing
      let requested: UUID?
      if searching {
        requested = model.currentSubtitleSearchMatch?.fragments.first?.tokenID
      } else if pinned {
        requested = model.subtitlePinnedTokenID ?? model.subtitlePinnedLineID
      } else {
        requested = model.currentToken?.id ?? model.subtitlePlaybackAnchorID
          ?? model.subtitleLines.first?.id
      }
      let newTarget = next.layout.rowID(containing: requested)
      let shouldFollow = !dragging && (
        changed || dimensionsChanged || (!pinned && (target != newTarget || wasSearching || wasPinned
          || wasDragging || (!wasPlaying && playing))) || (searching && target != newTarget))
      target = newTarget
      table.tableColumns.first?.width = max(1, scroll.contentSize.width)
      if changed {
        // Recycle only currently visible cells, rather than retaining every row
        // visited by playback or measuring all preceding rows after each change.
        table.reloadData()
      } else {
        if dimensionsChanged {
          table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        }
        let visible = table.rows(in: scroll.contentView.bounds)
        if visible.location != NSNotFound {
          for row in visible.location..<NSMaxRange(visible)
          where next.layout.rows.indices.contains(row - 1) {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SubtitleCell {
              configure(cell, row: row - 1, input: next)
            }
          }
        }
      }
      if shouldFollow, let requested, let index = next.layout.tokenRows[requested] {
        let rect = table.rect(ofRow: index + 1)
        let y = min(max(0, rect.midY - scroll.contentView.bounds.height / 2),
          max(0, table.bounds.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
      }
      publishVisibleRow()
    }
    private func publishVisibleRow() {
      guard let input, let scroll, let table, !input.layout.rows.isEmpty else { return }
      let row = table.row(at: NSPoint(x: 1, y: scroll.contentView.bounds.midY)) - 1
      let index = min(max(0, row), input.layout.rows.count - 1)
      let id = input.layout.rows[index].id
      guard visibleID != id else { return }
      visibleID = id
      publication?.cancel()
      publication = Task { @MainActor in
        await Task.yield()
        guard !Task.isCancelled else { return }
        input.onVisibleRow(id)
        input.model.prefetchDictionary(nearLine: input.layout.tokenSourceLines[id])
      }
    }
  }
  @MainActor final class SubtitleCell: NSHostingView<AnyView> {
    var line: CaptionLine?
    var presentation: SubtitleLinePresentation?
    var pinned = false
    var height: CGFloat = 0
  }
}
