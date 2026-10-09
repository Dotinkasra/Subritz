import StudyCore
import SwiftUI

enum LibrarySection: String, CaseIterable { case history, favorites }

extension StudyModel {
  func startLibrary() {
    libraryLoading = true
    libraryStartup = Task.detached { try LibraryStore() }
    libraryOperation = Task {
      defer { libraryLoading = false }
      do {
        guard let libraryStartup else { return }
        library = try await libraryStartup.value
        if let cache = try? await storageTask?.value.0 {
          try await library?.seedHistoryIfNeeded(cache.recentHistory())
        }
        try await refreshLibrary()
      } catch { libraryError = "履歴・お気に入りを開けませんでした：" + error.localizedDescription }
    }
  }
  func refreshLibrary() async throws {
    guard let library else { return }
    let history = try await library.history()
    let favorites = try await library.favorites()
    videoHistory = history
    favoriteWords = favorites
  }
  func mutateLibrary(
    favoriteID: String? = nil, _ operation: @escaping (LibraryStore) async throws -> Void
  ) {
    let previous = libraryOperation
    libraryOperation = Task {
      await previous?.value
      libraryError = nil
      defer { if let favoriteID { pendingFavoriteIDs.remove(favoriteID) } }
      do {
        guard let library else { throw AppFailure("履歴・お気に入りが準備できていません") }
        try await operation(library)
        try await refreshLibrary()
      } catch { libraryError = "履歴・お気に入りを保存できませんでした：" + error.localizedDescription }
    }
  }
  func recordCurrentVideo() {
    guard let video = document?.video, library != nil || libraryStartup != nil else { return }
    let date = Date()
    mutateLibrary { try await $0.record(video, at: date) }
  }
  var displayedFavoriteID: String? {
    displayedToken.flatMap { $0.lexical ? DictionaryText.normalize($0.surface) : nil }
  }
  var displayedWordIsFavorite: Bool {
    guard let id = displayedFavoriteID else { return false }
    return favoriteWords.contains { $0.id == id }
  }
  var canToggleDisplayedFavorite: Bool {
    guard let id = displayedFavoriteID else { return false }
    return library != nil && !pendingFavoriteIDs.contains(id)
  }
  func toggleDisplayedFavorite() {
    guard canToggleDisplayedFavorite, let token = displayedToken, let id = displayedFavoriteID
    else { return }
    if displayedWordIsFavorite {
      removeFavorite(id)
      return
    }
    pendingFavoriteIDs.insert(id)
    let entry = dictionaryEntry
    let video = document?.video
    let date = Date()
    let provider: any DictionaryProvider =
      settings.dictionary == "eijiro" && eijiro != nil ? eijiro! : MacDictionaryProvider()
    mutateLibrary(favoriteID: id) { library in
      let definition: DictionaryEntry?
      if let entry { definition = entry } else { definition = await provider.lookup(token) }
      try await library.saveFavorite(
        FavoriteWord(token: token, entry: definition, video: video, savedAt: date))
    }
  }
  func removeFavorite(_ id: String) {
    guard !pendingFavoriteIDs.contains(id), library != nil else { return }
    pendingFavoriteIDs.insert(id)
    mutateLibrary(favoriteID: id) { library in
      try await library.removeFavorite(id)
    }
  }
  func removeHistory(_ item: VideoHistoryItem) {
    mutateLibrary { try await $0.removeHistory(item.id) }
  }
  func selectHistory(_ item: VideoHistoryItem) {
    guard !isChangingCacheDirectory else { return }
    if hasOpenVideo { pendingHistory = item } else { openHistory(item) }
  }
  func confirmHistoryLoad(_ target: VideoHistoryItem? = nil) {
    guard let item = target ?? pendingHistory, !isChangingCacheDirectory else { return }
    closeVideo()
    openHistory(item)
  }
  func openHistory(_ item: VideoHistoryItem) {
    pendingHistory = nil
    url = item.video.watchURL
    load()
  }
  func seekToWord(_ token: Token) {
    guard ready, token.lexical, token.startTime.isFinite, token.startTime >= 0,
      timeline?.tokens.contains(where: { $0.id == token.id }) == true
    else { return }
    pinDictionary(token)
    seek(token.startTime)
  }
}
