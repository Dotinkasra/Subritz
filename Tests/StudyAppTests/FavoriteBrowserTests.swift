import Foundation
import Testing
@testable import StudyApp
@testable import StudyCore

@MainActor struct FavoriteBrowserTests {
  func words(_ count: Int, archived: Bool = false) throws -> [FavoriteWord] {
    let raw = Data(#"{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"A paper robot waits."}]}]}"#.utf8)
    let base = try #require(Timeline(CaptionPipeline().parse(raw, videoID: "authored")).tokens.first)
    return (0..<count).map { index in
      var token = base
      token.surface = "Lantern" + String(format: "%03d", index)
      var word = FavoriteWord(token: token, entry: DictionaryEntry(definition: "自作詳細", shortGloss: "OnlyMeaning"),
        video: nil, savedAt: Date(timeIntervalSince1970: 1_800_000_000 - Double(index)))
      word.archivedAt = archived ? Date(timeIntervalSince1970: 1_800_001_000) : nil
      return word
    }
  }
  @Test func pagesContainAtMost50AndForwardBackwardAndEmptyBoundariesAreCorrect() throws {
    let browser = FavoriteBrowser()
    browser.update(try words(103))
    #expect(browser.pageCount == 3 && browser.pageWords.count == 50)
    #expect(!browser.hasPrevious && browser.hasNext && browser.selectedWord?.surface == "Lantern000")
    var ids = browser.pageWords.map(\.id)
    browser.movePage(by: 1)
    #expect(browser.pageIndex == 1 && browser.pageWords.count == 50)
    #expect(browser.hasPrevious && browser.hasNext && browser.selectedWord?.surface == "Lantern050")
    ids += browser.pageWords.map(\.id)
    browser.movePage(by: 1)
    #expect(browser.pageIndex == 2 && browser.pageWords.count == 3 && !browser.hasNext)
    ids += browser.pageWords.map(\.id)
    #expect(ids.count == 103 && Set(ids).count == 103)
    browser.movePage(by: 1)
    #expect(browser.pageIndex == 2)
    browser.movePage(by: -1)
    #expect(browser.pageIndex == 1 && browser.selectedWord?.surface == "Lantern050")
    browser.update([])
    #expect(browser.pageIndex == 0 && browser.pageWords.isEmpty && browser.selectedWord == nil)
    #expect(!browser.hasPrevious && !browser.hasNext)
  }
  @Test func searchMatchesTheWholeCollectionAndOnlyEnglishWordsIgnoringCase() throws {
    let browser = FavoriteBrowser()
    browser.update(try words(151))
    browser.movePage(by: 2)
    browser.query = " lAnTeRn150 "
    #expect(browser.pageIndex == 0 && browser.matchCount == 1)
    #expect(browser.pageWords.first?.surface == "Lantern150")
    browser.query = "OnlyMeaning"
    #expect(browser.matchCount == 0 && browser.selectedWord == nil)
    browser.query = "Lantern1"
    #expect(browser.matchCount == 51 && browser.pageCount == 2 && browser.pageWords.count == 50)
    browser.movePage(by: 1)
    #expect(browser.pageWords.map(\.surface) == ["Lantern150"])
    browser.query = ""
    #expect(browser.pageIndex == 0 && browser.matchCount == 151 && browser.pageWords.count == 50)
  }
  @Test func archiveUsesTheSameSearchAndPaginationAndMutationsClampTheCurrentPage() throws {
    let browser = FavoriteBrowser()
    var items = try words(101)
    for index in 0..<51 { items[index].archivedAt = Date() }
    browser.update(items)
    #expect(browser.activeCount == 50 && browser.archivedCount == 51)
    #expect(browser.pageWords.first?.surface == "Lantern051" && browser.pageCount == 1)
    browser.toggleArchive()
    #expect(browser.pageWords.count == 50 && browser.pageCount == 2)
    browser.movePage(by: 1)
    #expect(browser.selectedWord?.surface == "Lantern050")
    items[50].archivedAt = nil
    browser.update(items) // Restore the only item on the last page.
    #expect(browser.pageIndex == 0 && browser.pageCount == 1 && browser.pageWords.count == 50)
    #expect(browser.selectedWord?.surface == "Lantern000")
    browser.query = "051"
    #expect(browser.matchCount == 0)
    browser.toggleArchive()
    #expect(browser.matchCount == 1 && browser.selectedWord?.surface == "Lantern051")
  }
  @Test func modelArchiveMovesAndRestoresWithoutReplacingRegistrationOrOccurrences() async throws {
    let (model, root) = try LibraryInteractionTests().libraryModel()
    defer {
      model.ready = false
      model.closeVideo()
      try? FileManager.default.removeItem(at: root)
    }
    let token = try #require(model.timeline?.tokens.first { $0.surface == "study" })
    model.pinDictionary(token)
    model.toggleDisplayedFavorite()
    await model.libraryOperation?.value
    let original = try #require(model.favoriteWords.first)
    let originalTime = try #require(model.videoTimestamps.first?.time)
    model.setFavoriteArchived(original.id, archived: true)
    #expect(model.pendingFavoriteIDs.contains(original.id))
    model.setFavoriteArchived(original.id, archived: false) // Ignore a duplicate while saving.
    await model.libraryOperation?.value
    #expect(model.favoriteWords.first?.isArchived == true && !model.displayedWordIsFavorite)
    #expect(model.favoriteWords.first?.savedAt == original.savedAt)
    #expect(model.videoTimestamps.first?.time == originalTime)
    #expect(model.favoriteExportWords.isEmpty)
    model.favoriteExportArchived = true
    #expect(model.favoriteExportWords.map(\.id) == [original.id])
    model.toggleDisplayedFavorite() // Star restores the archived word rather than replacing it.
    await model.libraryOperation?.value
    #expect(model.displayedWordIsFavorite && model.favoriteWords.first?.isArchived == false)
    #expect(model.favoriteWords.first?.savedAt == original.savedAt)
    #expect(model.favoriteWords.first?.definition == original.definition)
    #expect(model.favoriteWords.first?.sourceTime == original.sourceTime)
    #expect(model.videoTimestamps.first?.time == originalTime)
    #expect(model.libraryError == nil && model.pendingFavoriteIDs.isEmpty)
    model.favoriteExportArchived = false
    #expect(model.favoriteExportWords.map(\.id) == [original.id])
  }
}
