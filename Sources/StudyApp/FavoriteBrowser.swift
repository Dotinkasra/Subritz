import StudyCore
import SwiftUI

/// Rebuild matches only when the words, query or archive scope change, rather
/// than on every playback/dictionary notification observed by the library view.
@MainActor final class FavoriteBrowser: ObservableObject {
  static let pageSize = 50
  @Published var query = "" {
    didSet { if query != oldValue { rebuild(resetPage: true) } }
  }
  @Published private(set) var showingArchive = false
  @Published private(set) var pageIndex = 0
  @Published private(set) var pageWords: [FavoriteWord] = []
  @Published private(set) var matchCount = 0
  @Published private(set) var activeCount = 0
  @Published private(set) var archivedCount = 0
  @Published var selectedID: String?
  private var words: [FavoriteWord] = []
  private var matches: [FavoriteWord] = []

  var pageCount: Int { max(1, (matchCount + Self.pageSize - 1) / Self.pageSize) }
  var hasPrevious: Bool { pageIndex > 0 }
  var hasNext: Bool { pageIndex + 1 < pageCount }
  var selectedWord: FavoriteWord? { pageWords.first { $0.id == selectedID } ?? pageWords.first }
  var scopeCount: Int { showingArchive ? archivedCount : activeCount }

  func update(_ words: [FavoriteWord]) {
    self.words = words
    archivedCount = words.filter(\.isArchived).count
    activeCount = words.count - archivedCount
    rebuild(resetPage: false)
  }
  func toggleArchive() {
    showingArchive.toggle()
    rebuild(resetPage: true)
  }
  func movePage(by offset: Int) {
    let target = min(max(0, pageIndex + offset), pageCount - 1)
    guard target != pageIndex else { return }
    pageIndex = target
    updatePage()
  }
  private func rebuild(resetPage: Bool) {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    matches = words.filter {
      $0.isArchived == showingArchive && (term.isEmpty || $0.surface.localizedCaseInsensitiveContains(term))
    }
    matchCount = matches.count
    pageIndex = resetPage ? 0 : min(pageIndex, pageCount - 1)
    if resetPage { selectedID = nil }
    updatePage()
  }
  private func updatePage() {
    pageWords = Array(matches.dropFirst(pageIndex * Self.pageSize).prefix(Self.pageSize))
    if !pageWords.contains(where: { $0.id == selectedID }) { selectedID = pageWords.first?.id }
  }
}
