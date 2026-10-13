import StudyCore
import SwiftUI

struct LibraryView: View {
  @ObservedObject var model: StudyModel
  @Environment(\.dismissWindow) private var dismissWindow
  @Environment(\.openWindow) private var openWindow
  @State private var query = ""
  @State private var selections: [LibrarySection: String] = [:]
  var history: [VideoHistoryItem] {
    model.videoHistory.filter { query.isEmpty || $0.video.title.localizedCaseInsensitiveContains(query) }
  }
  var timestamps: [VideoTimestamp] {
    model.videoTimestamps.filter {
      query.isEmpty || $0.video.title.localizedCaseInsensitiveContains(query)
        || PlaybackTime.format($0.time).contains(query)
        || ($0.wordID?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }
  var favorites: [FavoriteWord] {
    model.favoriteWords.filter {
      query.isEmpty || $0.surface.localizedCaseInsensitiveContains(query)
        || $0.shortGloss.localizedCaseInsensitiveContains(query)
    }
  }
  var selectedHistory: VideoHistoryItem? { history.first { $0.id == selections[.history] } }
  var selectedTimestamp: VideoTimestamp? { timestamps.first { $0.id == selections[.timestamps] } }
  var selectedFavorite: FavoriteWord? { favorites.first { $0.id == selections[.favorites] } ?? favorites.first }
  var selection: Binding<String?> {
    Binding(get: {
      switch model.librarySection {
      case .history: return selectedHistory?.id
      case .timestamps: return selectedTimestamp?.id
      case .favorites: return selectedFavorite?.id
      }
    }, set: { selections[model.librarySection] = $0 })
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("ライブラリ", selection: $model.librarySection) {
          Text("動画履歴").tag(LibrarySection.history)
          Text("タイムスタンプ").tag(LibrarySection.timestamps)
          Text("単語のお気に入り").tag(LibrarySection.favorites)
        }.pickerStyle(.segmented).frame(maxWidth: 440)
        Spacer()
        TextField("ライブラリを検索", text: $query)
          .textFieldStyle(.roundedBorder).frame(width: 220)
      }.padding(16)
      Divider()
      // Keep the same columns, search field and footer for every library section,
      // including loading/empty/search states. No nested navigation window chrome.
      HSplitView {
        list.frame(minWidth: 300, idealWidth: 350, maxWidth: 430, maxHeight: .infinity)
        detail.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      HStack {
        Text(countDescription)
        Spacer()
        if model.librarySection == .favorites {
          Button("エクスポート", systemImage: "square.and.arrow.up") {
            openWindow(id: "favorite-export")
          }.help("お気に入りの単語をテキストまたはCSVで書き出す")
            .disabled(model.libraryLoading || model.favoriteWords.isEmpty)
        }
      }.font(.caption).foregroundStyle(.secondary).padding(12)
      if let error = model.libraryError {
        Text(error).font(.callout).foregroundStyle(.red).padding(12)
      }
    }
    .onChange(of: model.librarySection) { query = "" }
    .alert(sameVideo ? "この動画の指定位置へ移動しますか？" : "現在の動画を閉じて、選んだ動画を開きますか？",
      isPresented: Binding(get: { model.pendingLibraryPlayback != nil },
        set: { if !$0 { model.pendingLibraryPlayback = nil } }),
      presenting: model.pendingLibraryPlayback
    ) { request in
      Button("キャンセル", role: .cancel) { model.pendingLibraryPlayback = nil }
      Button(sameVideo ? "指定位置へ移動" : "動画を開く") {
        finishNavigation(model.confirmLibraryPlayback(request))
      }
    } message: { request in
      Text(request.video.title + " · " + PlaybackTime.format(request.time) + "\n"
        + (sameVideo ? "再生状態を保ったまま、この位置へ移動します。"
          : "現在の再生と字幕解析を終了します。現在位置は自動保存します。"))
    }
  }
  var sameVideo: Bool {
    model.ready && model.document?.video.id == model.pendingLibraryPlayback?.video.id
  }
  var countDescription: String {
    switch model.librarySection {
    case .history: return "\(model.videoHistory.count) / 100件 · 最近開いた順"
    case .timestamps: return "\(model.videoTimestamps.count) / 1000件 · 新しい記録順"
    case .favorites: return "\(model.favoriteWords.count)語 · 最近登録した順"
    }
  }
  @ViewBuilder var list: some View {
    if model.libraryLoading {
      ProgressView("ライブラリを読み込んでいます…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      switch model.librarySection {
      case .history:
        if history.isEmpty { emptyList }
        else {
          List(history) { item in
            Button {
              if selectRow(item.id, in: .history) {
                finishNavigation(model.selectHistory(item))
              }
            } label: {
              VideoLibraryRow(video: item.video,
                subtitle: item.lastOpened.formatted(.dateTime.year().month().day().hour().minute()))
            }.buttonStyle(.plain).disabled(model.isChangingCacheDirectory)
              .listRowBackground(rowBackground(item.id, in: .history))
              .accessibilityAddTraits(selections[.history] == item.id ? .isSelected : [])
              .help("クリックで選択、選択中の項目をもう一度クリックで動画を開く")
              .contextMenu {
                Button("履歴から削除", role: .destructive) { model.removeHistory(item) }
              }
          }.listStyle(.inset)
        }
      case .timestamps:
        if timestamps.isEmpty { emptyList }
        else {
          List(timestamps) { item in
            Button {
              if selectRow(item.id, in: .timestamps) { open(item) }
            } label: {
              VideoLibraryRow(video: item.video,
                subtitle: PlaybackTime.format(item.time) + " · " + timestampLabel(item))
            }.buttonStyle(.plain).disabled(model.isChangingCacheDirectory)
              .listRowBackground(rowBackground(item.id, in: .timestamps))
              .accessibilityAddTraits(selections[.timestamps] == item.id ? .isSelected : [])
              .help("クリックで選択、選択中の項目をもう一度クリックで保存した位置へ移動")
              .contextMenu {
                Button("タイムスタンプを削除", role: .destructive) { model.removeTimestamp(item) }
              }
          }.listStyle(.inset)
        }
      case .favorites:
        if favorites.isEmpty { emptyList }
        else {
          List(favorites, selection: selection) { word in
            VStack(alignment: .leading, spacing: 5) {
              Text(word.surface).font(.headline)
              RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.45))
                .frame(width: 120, height: 12).accessibilityLabel("日本語の意味は非表示")
            }.padding(.vertical, 5).tag(word.id)
              .contextMenu {
                Button("お気に入りを解除", role: .destructive) { model.removeFavorite(word.id) }
              }
          }.listStyle(.inset)
        }
      }
    }
  }
  @ViewBuilder var emptyList: some View {
    if !query.isEmpty { ContentUnavailableView.search(text: query) }
    else {
      switch model.librarySection {
      case .history:
        ContentUnavailableView("動画履歴はありません", systemImage: "clock",
          description: Text("読み込んだ動画を100件まで保存します。"))
      case .timestamps:
        ContentUnavailableView("タイムスタンプはありません", systemImage: "bookmark",
          description: Text("しおり・閉じた位置・お気に入りの出現位置を保存します。"))
      case .favorites:
        ContentUnavailableView("お気に入りはありません", systemImage: "star",
          description: Text("辞書の星から単語・表現を登録できます。"))
      }
    }
  }
  @ViewBuilder var detail: some View {
    switch model.librarySection {
    case .favorites:
      if let word = selectedFavorite { FavoriteDefinitionView(model: model, word: word, open: open).id(word.id) }
      else { ContentUnavailableView("単語を選んでください", systemImage: "book.closed") }
    case .history:
      if let item = selectedHistory {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            HistoryThumbnail(video: item.video)
            Text(item.video.title).font(.title2).textSelection(.enabled)
            Button("動画を開く", systemImage: "play.fill") {
              finishNavigation(model.selectHistory(item))
            }.disabled(model.isChangingCacheDirectory)
            Divider()
            Text("保存したタイムスタンプ").font(.headline)
            let saved = model.videoTimestamps.filter { $0.video.id == item.video.id }
            if saved.isEmpty { Text("この動画の記録はありません").foregroundStyle(.secondary) }
            ForEach(saved) { timestamp in
              Button { open(timestamp) } label: {
                Label(PlaybackTime.format(timestamp.time) + " · " + timestampLabel(timestamp),
                  systemImage: "play.circle")
              }.disabled(model.isChangingCacheDirectory)
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
      } else { ContentUnavailableView("動画を選んでください", systemImage: "play.rectangle") }
    case .timestamps:
      if let item = selectedTimestamp {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            HistoryThumbnail(video: item.video)
            Text(item.video.title).font(.title2).textSelection(.enabled)
            Text(PlaybackTime.format(item.time)).font(.system(size: 38, weight: .semibold)).monospacedDigit()
            Text(timestampLabel(item)).foregroundStyle(.secondary)
            Text(item.savedAt.formatted(.dateTime.year().month().day().hour().minute()))
              .font(.caption).foregroundStyle(.secondary)
            Button("この位置から開く", systemImage: "play.fill") { open(item) }
              .disabled(model.isChangingCacheDirectory)
            Divider()
            Text(item.videoURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button("タイムスタンプを削除", role: .destructive) { model.removeTimestamp(item) }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
      } else { ContentUnavailableView("タイムスタンプを選んでください", systemImage: "bookmark") }
    }
  }
  func open(_ item: VideoTimestamp) {
    finishNavigation(model.selectTimestamp(item))
  }
  // The row button owns selection. A List selection binding would select a new
  // row before its button action, mistaking the first click for a repeat click.
  func selectRow(_ id: String, in section: LibrarySection) -> Bool {
    let repeated = selections[section] == id
    selections[section] = id
    return repeated
  }
  func rowBackground(_ id: String, in section: LibrarySection) -> Color {
    selections[section] == id ? Color.accentColor.opacity(0.2) : .clear
  }
  func finishNavigation(_ started: Bool) {
    guard started else { return }
    openWindow(id: "main")
    dismissWindow(id: "library")
  }
}
func timestampLabel(_ timestamp: VideoTimestamp) -> String {
  switch timestamp.kind {
  case .bookmark: return "しおり"
  case .resume: return "最後に開いた位置"
  case .favorite: return "お気に入り" + (timestamp.wordID.map { ": " + $0 } ?? "")
  }
}
struct VideoLibraryRow: View {
  let video: Video
  let subtitle: String
  var body: some View {
    HStack(spacing: 12) {
      HistoryThumbnail(video: video)
      VStack(alignment: .leading, spacing: 6) {
        Text(video.title).font(.headline).lineLimit(2)
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
    }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
  }
}
struct HistoryThumbnail: View {
  let video: Video
  var body: some View {
    AsyncImage(url: video.thumbnailImageURL) { phase in
      if let image = phase.image { image.resizable().scaledToFill() }
      else {
        ZStack {
          Color.secondary.opacity(0.1)
          Image(systemName: "play.rectangle").font(.title).foregroundStyle(.secondary)
        }
      }
    }.frame(width: 128, height: 72).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
      .accessibilityHidden(true)
  }
}
struct FavoriteDefinitionView: View {
  @ObservedObject var model: StudyModel
  let word: FavoriteWord
  let open: (VideoTimestamp) -> Void
  @State private var meaningVisible = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .top) {
          Text(word.surface).font(.system(size: 38, weight: .semibold)).textSelection(.enabled)
          Spacer()
          Button { model.removeFavorite(word.id) } label: { Image(systemName: "star.fill") }
            .foregroundStyle(.orange).disabled(model.pendingFavoriteIDs.contains(word.id))
            .help("お気に入りを解除")
        }
        if let partOfSpeech = word.partOfSpeech {
          Text(DictionaryPane(model: model).pos(partOfSpeech)).foregroundStyle(.secondary)
        }
        HStack {
          CambridgeLookupButton(word: word.surface, browser: model.settings.dictionaryBrowser)
          Spacer()
          Button(meaningVisible ? "日本語を隠す" : "日本語を表示",
            systemImage: meaningVisible ? "eye.slash" : "eye") { meaningVisible.toggle() }
            .help("日本語の意味・詳細定義の表示を切り替える")
        }
        MaskedDictionaryContent(revealed: meaningVisible, onReveal: { meaningVisible = true }) {
          Text(word.shortGloss.isEmpty ? "語義は未登録です" : word.shortGloss)
            .font(.title2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        if let timestamp = model.occurrence(of: word) {
          Divider()
          Text("出現箇所").font(.headline)
          Button { open(timestamp) } label: {
            VideoLibraryRow(video: timestamp.video, subtitle: PlaybackTime.format(timestamp.time))
          }.buttonStyle(.plain).disabled(model.isChangingCacheDirectory)
            .help("この単語の出現位置へ移動")
        }
        if !word.definition.isEmpty {
          Divider()
          MaskedDictionaryContent(revealed: meaningVisible, onReveal: { meaningVisible = true }) {
            VStack(alignment: .leading, spacing: 20) {
              ForEach(Array(DictionaryText.paragraphs(word.definition).enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph).font(.body).lineSpacing(5).textSelection(.enabled)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        Text("登録時の辞書表示を保存しています").font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }
  }
}

struct MaskedDictionaryContent<Content: View>: View {
  let revealed: Bool
  let onReveal: () -> Void
  @ViewBuilder let content: () -> Content
  var body: some View {
    Group {
      if revealed { content() }
      else { content().hidden().allowsHitTesting(false).accessibilityHidden(true) }
    }.overlay {
      if !revealed {
        ZStack {
          // Hidden text also prevents copying/accessibility and pressed-state effects from exposing it.
          RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.30, green: 0.31, blue: 0.33))
            .allowsHitTesting(false)
          Button(action: onReveal) {
            Label("クリックして日本語を表示", systemImage: "eye.slash")
              .font(.caption).foregroundStyle(.white.opacity(0.9))
              .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("日本語の意味を表示")
        }
      }
    }
  }
}
