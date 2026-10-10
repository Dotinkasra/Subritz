import StudyCore
import SwiftUI

enum LibrarySection: String, CaseIterable { case history, timestamps, favorites }
struct LibraryPlaybackRequest: Identifiable {
  let id = UUID()
  let video: Video
  let time: Double
}

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
      } catch { libraryError = "ライブラリを開けませんでした：" + error.localizedDescription }
    }
  }
  func refreshLibrary() async throws {
    guard let library else { return }
    let history = try await library.history()
    let favorites = try await library.favorites()
    let timestamps = try await library.timestamps()
    videoHistory = history
    favoriteWords = favorites
    videoTimestamps = timestamps
  }
  func mutateLibrary(
    favoriteID: String? = nil, completion: (() -> Void)? = nil,
    _ operation: @escaping (LibraryStore) async throws -> Void
  ) {
    let previous = libraryOperation
    libraryOperation = Task {
      await previous?.value
      libraryError = nil
      defer {
        if let favoriteID { pendingFavoriteIDs.remove(favoriteID) }
        completion?()
      }
      do {
        guard let library else { throw AppFailure("ライブラリが準備できていません") }
        try await operation(library)
        try await refreshLibrary()
      } catch { libraryError = "ライブラリを保存できませんでした：" + error.localizedDescription }
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
    let expression = pinnedExpression ?? resolvedExpression
    let video = document?.video
    let date = Date()
    let provider: any DictionaryProvider =
      settings.dictionary == "eijiro" && eijiro != nil ? eijiro! : MacDictionaryProvider()
    mutateLibrary(favoriteID: id) { library in
      let definition: DictionaryEntry?
      if let entry { definition = entry }
      else if let expression { definition = await provider.lookupExpressions([expression.tokens]).first ?? nil }
      else { definition = await provider.lookup(token) }
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
  @discardableResult func selectHistory(_ item: VideoHistoryItem) -> Bool {
    requestLibraryPlayback(video: item.video, at: 0)
  }
  @discardableResult func selectTimestamp(_ item: VideoTimestamp) -> Bool {
    requestLibraryPlayback(video: item.video, at: item.time)
  }
  @discardableResult func requestLibraryPlayback(video: Video, at time: Double) -> Bool {
    guard !isChangingCacheDirectory, time.isFinite, time >= 0 else { return false }
    do { _ = try YouTubeURL.id(video.watchURL) } catch {
      libraryError = error.localizedDescription
      return false
    }
    let request = LibraryPlaybackRequest(video: video, time: time)
    if hasOpenVideo {
      pendingLibraryPlayback = request
      return false
    }
    return openLibraryPlayback(request)
  }
  @discardableResult func confirmLibraryPlayback(_ target: LibraryPlaybackRequest? = nil) -> Bool {
    guard let request = target ?? pendingLibraryPlayback, !isChangingCacheDirectory else { return false }
    pendingLibraryPlayback = nil
    if ready, document?.video.id == request.video.id {
      releaseDictionaryPin()
      seek(duration > 0 ? min(request.time, duration) : request.time)
      return true
    }
    closeVideo()
    return openLibraryPlayback(request)
  }
  @discardableResult func openLibraryPlayback(_ request: LibraryPlaybackRequest) -> Bool {
    pendingLibraryPlayback = nil
    url = request.video.watchURL
    return load(startTime: request.time)
  }
  var canSaveBookmark: Bool {
    ready && document != nil && time.isFinite && time >= 0 && !savingBookmark
      && (library != nil || libraryStartup != nil)
  }
  func saveBookmark() {
    guard canSaveBookmark, let video = document?.video else { return }
    let timestamp = VideoTimestamp(video: video, time: time)
    savingBookmark = true
    timestampMessage = "しおりを保存しています…"
    let sid = session
    mutateLibrary(completion: {
      self.savingBookmark = false
      if sid == self.session {
        self.timestampMessage = self.libraryError == nil
          ? "しおりを保存しました（" + PlaybackTime.format(timestamp.time) + "）" : ""
      }
    }) { try await $0.saveTimestamp(timestamp) }
  }
  func saveExitTimestamp() {
    guard ready, let video = document?.video, time.isFinite, time >= 0,
      library != nil || libraryStartup != nil else { return }
    let timestamp = VideoTimestamp(video: video, time: time, kind: .resume)
    mutateLibrary { try await $0.saveTimestamp(timestamp) }
  }
  func removeTimestamp(_ item: VideoTimestamp) {
    mutateLibrary { try await $0.removeTimestamp(item.id) }
  }
  func occurrence(of word: FavoriteWord) -> VideoTimestamp? {
    guard let video = word.sourceVideo, word.sourceTime.isFinite, word.sourceTime >= 0 else { return nil }
    return VideoTimestamp(video: video, time: word.sourceTime, kind: .favorite,
      wordID: word.id, savedAt: word.savedAt)
  }
  func seekToWord(_ token: Token) {
    guard ready, token.lexical, token.startTime.isFinite, token.startTime >= 0,
      timeline?.tokens.contains(where: { $0.id == token.id }) == true
    else { return }
    pinDictionary(token)
    seek(token.startTime)
  }
}
