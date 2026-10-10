import AppKit
import StudyCore
import SwiftUI

extension StudyModel {
  var currentSubtitleSearchMatch: SubtitleSearchMatch? {
    let matches = subtitleSearchResults.matches
    return matches.indices.contains(subtitleSearchSelection) ? matches[subtitleSearchSelection] : nil
  }
  var browsingSubtitleSearch: Bool { subtitleSearchVisible && !subtitleSearchResults.matches.isEmpty }
  func openSubtitleSearch() {
    guard ready else { return }
    if !subtitleSearchVisible { refreshSubtitleSearch() }
    subtitleSearchVisible = true
    subtitleSearchFocusRequest += 1
  }
  func setSubtitleSearchQuery(_ query: String) {
    guard query != subtitleSearchQuery else { return }
    subtitleSearchQuery = query
    if subtitleSearchVisible { refreshSubtitleSearch() }
  }
  private func refreshSubtitleSearch() {
    if subtitleSearchIndex == nil { subtitleSearchIndex = SubtitleSearchIndex(lines: subtitleLines) }
    subtitleSearchResults = subtitleSearchIndex!.search(subtitleSearchQuery)
    subtitleSearchSelection = 0
  }
  func navigateSubtitleSearch(backwards: Bool = false) {
    let count = subtitleSearchResults.matches.count
    guard count > 0 else { return }
    subtitleSearchSelection = (subtitleSearchSelection + (backwards ? count - 1 : 1)) % count
  }
  func closeSubtitleSearch() {
    subtitleSearchVisible = false
    subtitleSearchResults = SubtitleSearchResults()
    subtitleSearchSelection = 0
  }
  func resetSubtitleSearchForVideo() {
    closeSubtitleSearch()
    // The query belongs to this running app, while offsets and highlights
    // belong to one video's caption text. Never reuse offsets for another video.
    subtitleSearchIndex = nil
  }
}

// Use the native search-field editor so Return and Shift-Return work while
// typing, without global shortcuts intercepting dictionary or player controls.
struct SubtitleSearchField: NSViewRepresentable {
  let query: String
  let focusRequest: Int
  let onChange: (String) -> Void
  let onNavigate: (Bool) -> Void
  let onClose: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> SearchField {
    let field = SearchField()
    field.placeholderString = "字幕内を検索"
    field.maximumRecents = 0
    field.setAccessibilityLabel("字幕内を検索")
    field.delegate = context.coordinator
    return field
  }
  func updateNSView(_ field: SearchField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != query { field.stringValue = query }
    if context.coordinator.focusRequest != focusRequest {
      context.coordinator.focusRequest = focusRequest
      field.requestFocus()
    }
  }
  final class SearchField: NSSearchField {
    private var needsFocus = false
    func requestFocus() {
      needsFocus = true
      focusIfReady()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusIfReady() }
    private func focusIfReady() {
      guard needsFocus, window != nil else { return }
      needsFocus = false
      DispatchQueue.main.async { [weak self] in
        guard let self, let window = self.window else { return }
        window.makeFirstResponder(self)
        self.currentEditor()?.selectAll(nil)
      }
    }
  }
  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: SubtitleSearchField
    var focusRequest: Int? = nil
    init(_ parent: SubtitleSearchField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      if let field = notification.object as? NSSearchField { parent.onChange(field.stringValue) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      if ["insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:"].contains(NSStringFromSelector(selector)) {
        parent.onNavigate(NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        return true
      }
      if NSStringFromSelector(selector) == "cancelOperation:" { parent.onClose(); return true }
      return false
    }
  }
}
