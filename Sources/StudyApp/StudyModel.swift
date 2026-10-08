import StudyCore
import SwiftUI

@MainActor final class StudyModel: ObservableObject {
  @Published var url = ""
  @Published var settings = AppSettings.load()
  @Published var phase: VideoLoadPhase = .idle
  @Published var stage = "YouTube の英語動画 URL を入力してください"
  @Published var error: String?
  @Published var grammarError: String?
  @Published var errorDetails: String?
  @Published var grammarErrorDetails: String?
  @Published var dictionaryLoading = false
  @Published var ready = false
  @Published var loading = false
  @Published var showSettings = false
  @Published var document: StudyDocument?
  @Published var currentSentence: Sentence?
  @Published var currentLineIndex = 0
  @Published var currentToken: Token?
  @Published var pinnedToken: Token?
  @Published var hoverToken: Token?
  @Published var dictionaryEntry: DictionaryEntry?
  @Published var realtime = true
  @Published var time: Double = 0
  @Published var duration: Double = 0
  @Published var playing = false
  @Published var cacheUsage = 0
  @Published var eijiroCount = 0
  @Published var settingsMessage = ""
  let bridge = PlayerBridge()
  var storageTask: Task<(StudyStore, EijiroProvider), Error>?
  var store: StudyStore?
  var eijiro: EijiroProvider?
  var timeline: Timeline?
  var session = UUID()
  var fingerprint = ""
  var scheduler: GrammarScheduler?
  var loadTask: Task<Void, Never>?
  var backgroundTask: Task<Void, Never>?
  var backgroundRunning = false
  var dictionaryTask: Task<Void, Never>?
  var dictionaryPrefetchTask: Task<Void, Never>?
  var dictionaryMisses = Set<String>()
  var dictionaryCache: [String: DictionaryEntry] = [:]
  var selectedDictionaryID: UUID?
  var lastPriorityTime: Double = -300
  var activeSentenceIndex: Int?
  init(prepareStorage: Bool = true) {
    bridge.onTime = { [weak self] t, d, s in self?.update(time: t, duration: d, state: s) }
    bridge.onError = { [weak self] message in self?.error = message }
    guard prepareStorage else { return }
    storageTask = Task.detached { (try StudyStore(), try EijiroProvider()) }
    Task {
      do {
        let stores = try await storageTask!.value
        store = stores.0
        eijiro = stores.1
        await refreshStorage()
      } catch { self.error = "永続データを開けませんでした：" + error.localizedDescription }
    }
  }
  func load() {
    phase = .validatingURL
    let id: String
    do { id = try YouTubeURL.id(url) } catch {
      self.error = error.localizedDescription
      return
    }
    loadTask?.cancel()
    backgroundTask?.cancel()
    backgroundRunning = false
    dictionaryTask?.cancel()
    dictionaryPrefetchTask?.cancel()
    bridge.pause()
    session = UUID()
    let sid = session
    ready = false
    loading = true
    error = nil
    errorDetails = nil
    grammarError = nil
    grammarErrorDetails = nil
    document = nil
    timeline = nil
    currentSentence = nil
    currentToken = nil
    currentLineIndex = 0
    hoverToken = nil
    pinnedToken = nil
    dictionaryEntry = nil
    selectedDictionaryID = nil
    activeSentenceIndex = nil
    lastPriorityTime = -300
    time = 0
    let config = settings
    loadTask = Task {
      do {
        if store == nil, let storageTask {
          let stores = try await storageTask.value
          store = stores.0
          eijiro = stores.1
        }
        phase = .probingVideo
        StudyLog.youtube.info("Probing video metadata")
        stage = "動画情報を取得しています…"
        let yt = YtDlpProvider(path: config.ytDlpPath)
        let probe = try await yt.probe(id: id)
        guard sid == session else { return }
        phase = .fetchingCaptions
        stage = "自動生成英語字幕を取得しています…"
        let raw = try await yt.caption(probe)
        guard sid == session else { return }
        phase = .parsingCaptions
        stage = "字幕を解析し、単語タイムラインを構築しています…"
        let provider: any GrammarProvider =
          config.provider == "codex"
          ? CodexGrammarProvider(settings: config) : LocalGrammarProvider(settings: config)
        let key = Fingerprint.make(
          videoID: id, caption: raw, provider: await provider.cacheIdentity(),
          model: config.grammarModel)
        let cached = try await store?.load(key)
        let sentences: [Sentence]
        if let cached {
          sentences = cached.sentences
        } else {
          sentences = try await CaptionService().parse(raw, videoID: id)
        }
        guard sid == session, !Task.isCancelled else { return }
        phase = .buildingTimeline
        StudyLog.timing.info("Built caption timeline")
        document = StudyDocument(video: probe.video, rawCaption: raw, sentences: sentences)
        timeline = Timeline(sentences)
        duration = probe.video.duration
        fingerprint = key
        scheduler = GrammarScheduler(provider: provider, context: sentences)
        await initialGrammar(sid: sid)
      } catch is CancellationError {} catch {
        guard sid == session else { return }
        loading = false
        phase = .failed((error as? AppFailure) ?? AppFailure(error.localizedDescription))
        self.error = error.localizedDescription
        errorDetails = (error as? AppFailure)?.details
        stage = "読み込みに失敗しました"
      }
    }
  }
  func initialGrammar(sid: UUID) async {
    guard let scheduler, let document else { return }
    let initial = document.sentences.filter { $0.startTime < 300 && $0.grammarAnalysis == nil }
    let batches = GrammarContract.batches(initial)
    do {
      for (index, batch) in batches.enumerated() {
        try Task.checkCancellation()
        guard sid == session else { return }
        phase = .initialGrammarAnalysis(progress: Double(index) / Double(max(1, batches.count)))
        stage = "先頭5分の文法を解析しています… \(Int(Double(index)/Double(max(1,batches.count))*100))%"
        mark(batch, status: .analyzing)
        do {
          let results = try await scheduler.analyze(batch)
          guard sid == session, !Task.isCancelled else { return }
          apply(results)
          mark(
            batch.filter { sentence in !results.contains { $0.sentenceId == sentence.id } },
            status: .failed)
        } catch let failure as AppFailure where failure.code == .grammarInvalidResponse {
          guard sid == session, !Task.isCancelled else { return }
          mark(batch, status: .failed)
          StudyLog.grammar.error("Invalid grammar response; continuing with subtitles")
        }
        await persistCurrentDocument()
      }
      guard sid == session else { return }
      continuePlayback()
    } catch is CancellationError {} catch {
      guard sid == session else { return }
      loading = false
      mark(
        self.document?.sentences.filter { $0.startTime < 300 && $0.grammarAnalysis == nil } ?? [],
        status: .failed)
      grammarError = error.localizedDescription
      grammarErrorDetails = (error as? AppFailure)?.details
      stage = "文法解析を中断しました。再試行するか、文法表示なしで動画を開けます。"
    }
  }
  func retryCurrentGrammar() {
    guard var sentence = currentSentence, let scheduler else { return }
    sentence.grammarAnalysis = nil
    let sid = session
    mark([sentence], status: .queued)
    Task {
      await scheduler.enqueue([sentence], priority: true, retryFailed: true)
      guard sid == session else { return }
      startBackground()
    }
  }
  func retryGrammar() {
    load()
  }
  func continuePlayback() {
    loading = false
    ready = true
    phase = .ready
    grammarError = nil
    stage = "再生できます"
    if let d = document { timeline = Timeline(d.sentences) }
    Task {
      await persistCurrentDocument()
      await refreshStorage()
    }
    prefetchDictionary(at: time)
    startBackground()
  }
  func startBackground() {
    guard !backgroundRunning else { return }
    backgroundRunning = true
    let sid = session
    backgroundTask = Task {
      defer { if sid == session { backgroundRunning = false } }
      guard let scheduler, let d = document else { return }
      phase = .backgroundAnalysis
      StudyLog.grammar.info("Starting background grammar queue")
      await scheduler.enqueue(d.sentences.filter { $0.startTime >= 300 })
      while !Task.isCancelled {
        let batch = await scheduler.next()
        if batch.isEmpty { break }
        mark(batch, status: .analyzing)
        do {
          let results = try await scheduler.analyze(batch)
          guard sid == session, !Task.isCancelled else { return }
          apply(results)
          mark(
            batch.filter { sentence in !results.contains { $0.sentenceId == sentence.id } },
            status: .failed)
          await persistCurrentDocument()
        } catch is CancellationError { return } catch {
          guard sid == session else { return }
          mark(batch, status: .failed)
          stage = "バックグラウンド文法解析に失敗しました：" + error.localizedDescription
        }
      }
    }
  }
  func mark(_ batch: [Sentence], status: GrammarStatus) {
    let ids = Set(batch.map(\.id))
    guard var d = document else { return }
    for i in d.sentences.indices where ids.contains(d.sentences[i].id) {
      d.sentences[i].grammarStatus = status
    }
    document = d
    refreshCurrentSentence()
  }
  func apply(_ analyses: [Analysis]) {
    guard var d = document else { return }
    let results = Dictionary(uniqueKeysWithValues: analyses.map { ($0.sentenceId, $0) })
    for i in d.sentences.indices {
      if let a = results[d.sentences[i].id] {
        d.sentences[i].grammarAnalysis = a
        d.sentences[i].grammarStatus = .completed
        for j in d.sentences[i].tokens.indices {
          d.sentences[i].tokens[j].grammarRole =
            a.displaySpans(at: j).first?.role
        }
      }
    }
    document = d
    refreshCurrentSentence()
  }
  func refreshCurrentSentence() {
    if let i = activeSentenceIndex, let d = document, i < d.sentences.count {
      currentSentence = d.sentences[i]
    }
  }
  func persistCurrentDocument() async {
    guard let d = document else { return }
    let sid = session
    let key = fingerprint
    let limit = settings.cacheMB * 1024 * 1024
    do { try await store?.save(d, fingerprint: key, limit: limit) } catch {
      if sid == session { self.error = "キャッシュを保存できませんでした：" + error.localizedDescription }
    }
  }
  func update(time t: Double, duration d: Double, state: Int) {
    guard ready else { return }
    let resumedPlayback = !playing && state == 1
    let discontinuity = abs(t - time) > 1.0
    if abs(t - time) >= 0.1 || discontinuity || playing != (state == 1) { time = t }
    if d > 0, d != duration { duration = d }
    if playing != (state == 1) { playing = state == 1 }
    guard let timeline else { return }
    if let line = timeline.line(at: t), currentLineIndex != line.index {
      currentLineIndex = line.index
    }
    let sentence = timeline.sentence(at: t)
    if currentSentence?.id != sentence?.id {
      activeSentenceIndex = sentence?.index
      currentSentence = sentence.flatMap { document?.sentences[$0.index] }
    }
    let token = timeline.token(at: t)
    let tokenChanged = currentToken?.id != token?.id
    let resumeRealtime =
      realtime && state == 1 && pinnedToken != nil
      && (resumedPlayback || tokenChanged)
    if resumeRealtime {
      pinnedToken = nil
      hoverToken = nil
    }
    if tokenChanged {
      currentToken = token
      prefetchDictionary(at: t)
    }
    if (tokenChanged || resumeRealtime) && hoverToken == nil { lookup() }
    if discontinuity || (t - lastPriorityTime > 30 && currentSentence?.grammarAnalysis == nil) {
      prioritize(t)
    }
  }
  func seek(_ t: Double) {
    bridge.seek(t)
    update(time: t, duration: duration, state: playing ? 1 : 2)
    prioritize(t)
  }
  func prioritize(_ t: Double) {
    lastPriorityTime = t
    guard let scheduler, let d = document else { return }
    let pending = d.sentences.filter {
      $0.endTime >= t && $0.startTime < t + 300 && $0.grammarAnalysis == nil
    }
    let sid = session
    Task {
      await scheduler.enqueue(pending, priority: true)
      if sid == session { startBackground() }
    }
  }
  func hover(_ token: Token?, exiting: UUID? = nil) {
    guard pinnedToken == nil else { return }
    if let exiting, hoverToken?.id != exiting { return }
    hoverToken = token
    lookup()
  }
  func pinDictionary(_ token: Token) {
    guard token.lexical else { return }
    pinnedToken = token
    hoverToken = nil
    lookup()
  }
  func releaseDictionaryPin() {
    pinnedToken = nil
    hoverToken = nil
    lookup()
  }
  func dictionaryModeChanged() {
    if realtime && playing { releaseDictionaryPin() } else { lookup() }
  }
  var displayedToken: Token? { pinnedToken ?? hoverToken ?? (realtime ? currentToken : nil) }
  var subtitleLines: [CaptionLine] { timeline?.lines ?? [] }
  func dictionaryKey(_ token: Token) -> String {
    settings.dictionary + ":" + token.normalized + ":" + (token.partOfSpeech ?? "") + ":"
      + (token.lemma ?? "")
  }
  func prefetchDictionary(at time: Double) {
    dictionaryPrefetchTask?.cancel()
    let tokens = timeline?.upcomingWords(at: time, limit: 10) ?? []
    let sid = session
    let provider: any DictionaryProvider =
      settings.dictionary == "eijiro" && eijiro != nil ? eijiro! : MacDictionaryProvider()
    dictionaryPrefetchTask = Task {
      for token in tokens {
        guard !Task.isCancelled, sid == session else { return }
        let key = dictionaryKey(token)
        if dictionaryCache[key] != nil || dictionaryMisses.contains(key) { continue }
        let entry = await provider.lookup(token)
        guard !Task.isCancelled, sid == session else { return }
        if let entry { dictionaryCache[key] = entry } else { dictionaryMisses.insert(key) }
      }
    }
  }
  func lookup() {
    let token = displayedToken
    guard selectedDictionaryID != token?.id else { return }
    dictionaryTask?.cancel()
    selectedDictionaryID = token?.id
    dictionaryEntry = nil
    dictionaryLoading = false
    guard let token, token.lexical else { return }
    let key = dictionaryKey(token)
    if dictionaryMisses.contains(key) { return }
    if let entry = dictionaryCache[key] {
      dictionaryLoading = false
      dictionaryEntry = entry
      return
    }
    let sid = session
    let provider: any DictionaryProvider =
      settings.dictionary == "eijiro" && eijiro != nil ? eijiro! : MacDictionaryProvider()
    dictionaryLoading = true
    dictionaryTask = Task {
      let entry = await provider.lookup(token)
      guard !Task.isCancelled, sid == session, displayedToken?.id == token.id else { return }
      StudyLog.dictionary.debug("Updated dictionary token")
      dictionaryLoading = false
      dictionaryEntry = entry
      if let entry {
        if dictionaryCache.count > 2000 { dictionaryCache.removeAll() }
        dictionaryCache[key] = entry
      } else {
        dictionaryMisses.insert(key)
      }
    }
  }
  func saveSettings(apiKey: String) {
    guard settings.timeout >= 5, settings.timeout <= 3600 else {
      settingsMessage = "タイムアウトは 5〜3600 秒を指定してください"
      return
    }
    do {
      try APISecret.save(apiKey)
      settings.model = settings.grammarModel
      settings.save()
      dictionaryCache.removeAll()
      dictionaryMisses.removeAll()
      dictionaryPrefetchTask?.cancel()
      selectedDictionaryID = nil
      lookup()
      settingsMessage = "設定を保存しました"
      Task {
        do {
          try await store?.evict(
            limit: settings.cacheMB * 1024 * 1024, protecting: document?.video.id)
          await refreshStorage()
        } catch { settingsMessage = error.localizedDescription }
      }
    } catch { settingsMessage = error.localizedDescription }
  }
  func refreshStorage() async {
    cacheUsage = (try? await store?.usage()) ?? 0
    eijiroCount = (try? await eijiro?.count()) ?? 0
  }
  func importDictionary(_ url: URL) {
    settingsMessage = "英辞郎データをインポートしています…"
    Task {
      let granted = url.startAccessingSecurityScopedResource()
      defer { if granted { url.stopAccessingSecurityScopedResource() } }
      do {
        let n = try await eijiro?.importFile(url)
        settingsMessage = "\(n ?? 0) 項目をインポートしました"
        dictionaryCache.removeAll()
        dictionaryMisses.removeAll()
        dictionaryPrefetchTask?.cancel()
        await refreshStorage()
      } catch { settingsMessage = error.localizedDescription }
    }
  }
  func removeDictionary() {
    Task {
      do {
        try await eijiro?.remove()
        dictionaryCache.removeAll()
        dictionaryMisses.removeAll()
        dictionaryPrefetchTask?.cancel()
        await refreshStorage()
        settingsMessage = "英辞郎データを削除しました"
      } catch { settingsMessage = error.localizedDescription }
    }
  }
  func clearCache() {
    Task {
      do {
        try await store?.clear()
        await refreshStorage()
        settingsMessage = "動画キャッシュを削除しました"
      } catch { settingsMessage = error.localizedDescription }
    }
  }
}
