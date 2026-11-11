import StudyCore
import SwiftUI

enum LibrarySection: String, CaseIterable { case history, timestamps, favorites }
struct HistoryDayGroup: Identifiable {
  var id: Date { day }
  let day: Date
  let videos: [VideoHistoryItem]
  static func grouped(_ history: [VideoHistoryItem], calendar: Calendar = .current) -> [Self] {
    Dictionary(grouping: history, by: { calendar.startOfDay(for: $0.lastOpened) })
      .map { day, items in
        Self(day: day, videos: items.sorted {
          if $0.lastOpened != $1.lastOpened { return $0.lastOpened > $1.lastOpened }
          return $0.id < $1.id
        })
      }.sorted { $0.day > $1.day }
  }
}
struct PendingHistoryPosition {
  let id = UUID()
  let position: PlaybackResumePosition
}
struct TimestampVideoGroup: Identifiable {
  var id: String { video.id }
  let video: Video
  let timestamps: [VideoTimestamp]
  let lastSavedAt: Date

  static func grouped(_ timestamps: [VideoTimestamp]) -> [Self] {
    Dictionary(grouping: timestamps, by: { $0.video.id }).values.compactMap { items in
      guard let latest = items.max(by: { $0.savedAt < $1.savedAt }) else { return nil }
      return Self(video: latest.video, timestamps: items.sorted {
        if $0.time != $1.time { return $0.time < $1.time }
        if $0.savedAt != $1.savedAt { return $0.savedAt > $1.savedAt }
        return $0.id < $1.id
      }, lastSavedAt: latest.savedAt)
    }.sorted {
      if $0.lastSavedAt != $1.lastSavedAt { return $0.lastSavedAt > $1.lastSavedAt }
      return $0.id < $1.id
    }
  }

  func matches(_ query: String) -> Bool {
    query.isEmpty || video.title.localizedCaseInsensitiveContains(query)
      || timestamps.contains {
        PlaybackTime.format($0.time).contains(query)
          || ($0.wordID?.localizedCaseInsensitiveContains(query) ?? false)
      }
  }
}
struct LibraryPlaybackRequest: Identifiable {
  let id = UUID()
  let video: Video
  let time: Double
  var resumeFromHistory = false
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
        markBackupChanged()
      } catch { libraryError = "ライブラリを保存できませんでした：" + error.localizedDescription }
    }
  }
  func recordCurrentVideo() {
    guard !isLiveSpeech, let video = document?.video, library != nil || libraryStartup != nil else { return }
    let date = Date()
    mutateLibrary { try await $0.record(video, at: date) }
  }
  func recordHistoryPosition(_ position: PlaybackResumePosition, state: Int, uptime: Double) {
    guard !isLiveSpeech, ready, let video = document?.video,
      library != nil || libraryStartup != nil else { return }
    if let checkpoint = resumeTracker.receive(time: position.time, duration: position.duration,
      state: state, uptime: uptime, date: position.date) {
      pendingHistoryPositions[video.id] = PendingHistoryPosition(position: checkpoint)
      queueHistoryPosition(video.id)
    }
  }
  func flushHistoryPosition() {
    if !isLiveSpeech, ready, let video = document?.video, let latest = resumeTracker.latest {
      pendingHistoryPositions[video.id] = PendingHistoryPosition(position: latest)
    }
    // Retain failed snapshots after closing, so the next close/quit can retry.
    for id in pendingHistoryPositions.keys.sorted() { queueHistoryPosition(id) }
  }
  private func queueHistoryPosition(_ videoID: String) {
    guard let pending = pendingHistoryPositions[videoID] else { return }
    let previous = libraryOperation
    libraryOperation = Task {
      await previous?.value
      guard pendingHistoryPositions[videoID]?.id == pending.id else { return }
      do {
        guard let library else { throw AppFailure("ライブラリが準備できていません") }
        try await library.saveHistoryPosition(videoID: videoID, position: pending.position)
        // Avoid reloading all dictionary definitions and timestamps every 5s.
        videoHistory = try await library.history()
        if pendingHistoryPositions[videoID]?.id == pending.id {
          pendingHistoryPositions.removeValue(forKey: videoID)
        }
        if pendingHistoryPositions.isEmpty { historyPositionSaveError = nil }
        markBackupChanged()
      } catch {
        historyPositionSaveError = "最後に開いた位置を保存できませんでした：" + error.localizedDescription
      }
    }
  }
  var displayedFavoriteID: String? {
    displayedToken.flatMap { $0.lexical ? DictionaryText.normalize($0.surface) : nil }
  }
  var displayedWordIsFavorite: Bool {
    guard let id = displayedFavoriteID else { return false }
    return favoriteWords.contains { $0.id == id && !$0.isArchived }
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
    if favoriteWords.contains(where: { $0.id == id && $0.isArchived }) {
      setFavoriteArchived(id, archived: false)
      return
    }
    pendingFavoriteIDs.insert(id)
    let entry = dictionaryEntry
    let expression = pinnedExpression ?? resolvedExpression
    let video = isLiveSpeech ? nil : document?.video
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
  func setFavoriteArchived(_ id: String, archived: Bool) {
    guard !pendingFavoriteIDs.contains(id), library != nil, !isRestoringBackup else { return }
    pendingFavoriteIDs.insert(id)
    mutateLibrary(favoriteID: id) { try await $0.setFavoriteArchived(id, archived: archived) }
  }
  var favoriteExportWords: [FavoriteWord] {
    favoriteWords.filter { $0.isArchived == favoriteExportArchived }
  }
  func removeHistory(_ item: VideoHistoryItem) {
    mutateLibrary { try await $0.removeHistory(item.id) }
  }
  @discardableResult func selectHistory(_ item: VideoHistoryItem) -> Bool {
    let current = videoHistory.first { $0.id == item.id } ?? item
    return requestLibraryPlayback(video: current.video, at: current.lastPosition ?? 0,
      resumeFromHistory: true)
  }
  @discardableResult func selectTimestamp(_ item: VideoTimestamp) -> Bool {
    requestLibraryPlayback(video: item.video, at: item.time)
  }
  @discardableResult func requestLibraryPlayback(video: Video, at time: Double,
    resumeFromHistory: Bool = false) -> Bool {
    guard !isRestoringBackup, !isChangingCacheDirectory, time.isFinite, time >= 0 else { return false }
    do { _ = try YouTubeURL.id(video.watchURL) } catch {
      libraryError = error.localizedDescription
      return false
    }
    let request = LibraryPlaybackRequest(video: video, time: time, resumeFromHistory: resumeFromHistory)
    if hasOpenVideo {
      pendingLibraryPlayback = request
      return false
    }
    return openLibraryPlayback(request)
  }
  @discardableResult func confirmLibraryPlayback(_ target: LibraryPlaybackRequest? = nil) -> Bool {
    guard let request = target ?? pendingLibraryPlayback, !isRestoringBackup, !isChangingCacheDirectory else { return false }
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
    return load(startTime: request.resumeFromHistory ? nil : request.time)
  }
  var canSaveBookmark: Bool {
    !isLiveSpeech && ready && document != nil && time.isFinite && time >= 0 && !savingBookmark
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
    guard !isLiveSpeech, ready, let video = document?.video, let latest = resumeTracker.latest,
      library != nil || libraryStartup != nil else { return }
    var confirmedVideo = video
    confirmedVideo.duration = latest.duration
    let timestamp = VideoTimestamp(video: confirmedVideo, time: latest.time, kind: .resume, savedAt: latest.date)
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
    if !isLiveSpeech { seek(token.startTime) }
  }
}
