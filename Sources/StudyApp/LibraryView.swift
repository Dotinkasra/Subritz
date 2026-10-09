import StudyCore
import SwiftUI

struct LibraryView: View {
  @ObservedObject var model: StudyModel
  @State private var query = ""
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("ライブラリ", selection: $model.librarySection) {
          Text("動画履歴").tag(LibrarySection.history)
          Text("単語のお気に入り").tag(LibrarySection.favorites)
        }.pickerStyle(.segmented).frame(maxWidth: 360)
        Spacer()
        TextField(model.librarySection == .history ? "タイトルを検索" : "単語・意味を検索", text: $query)
          .textFieldStyle(.roundedBorder).frame(width: 220)
      }.padding(16)
      Divider()
      if model.libraryLoading {
        ProgressView("ライブラリを読み込んでいます…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.librarySection == .history {
        history
      } else {
        FavoritesView(model: model, query: query)
      }
      if let error = model.libraryError {
        Text(error).font(.callout).foregroundStyle(.red).padding(12)
      }
    }
    .onChange(of: model.librarySection) { query = "" }
    .alert(
      "現在の動画を閉じて、選んだ動画を開きますか？",
      isPresented: Binding(
        get: { model.pendingHistory != nil }, set: { if !$0 { model.pendingHistory = nil } }
      ), presenting: model.pendingHistory
    ) { item in
      Button("キャンセル", role: .cancel) { model.pendingHistory = nil }
      Button("動画を開く") { model.confirmHistoryLoad(item) }
    } message: { _ in
      Text("現在の再生と字幕解析を終了します。保存済みのキャッシュは残ります。")
    }
  }
  var matches: [VideoHistoryItem] {
    model.videoHistory.filter {
      query.isEmpty || $0.video.title.localizedCaseInsensitiveContains(query)
    }
  }
  var history: some View {
    VStack(spacing: 0) {
      if model.videoHistory.isEmpty {
        ContentUnavailableView(
          "動画履歴はありません", systemImage: "clock", description: Text("読み込んだ動画を、最近開いた順で100件まで保存します。"))
      } else if matches.isEmpty {
        ContentUnavailableView.search(text: query)
      } else {
        List(matches) { item in
          Button {
            model.selectHistory(item)
          } label: {
            HStack(spacing: 14) {
              HistoryThumbnail(video: item.video)
              VStack(alignment: .leading, spacing: 6) {
                Text(item.video.title).font(.headline).lineLimit(2)
                Text(item.lastOpened.formatted(.dateTime.year().month().day().hour().minute()))
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "play.circle").font(.title2).foregroundStyle(.secondary)
            }.padding(.vertical, 5).contentShape(Rectangle())
          }.buttonStyle(.plain).disabled(model.isChangingCacheDirectory)
            .help("この動画を読み込む")
            .contextMenu {
              Button("履歴から削除", role: .destructive) { model.removeHistory(item) }
            }
        }.listStyle(.inset)
      }
      Divider()
      HStack {
        Text("\(model.videoHistory.count) / 100件 · 最近開いた順")
        Spacer()
      }.font(.caption).foregroundStyle(.secondary).padding(12)
    }
  }
}
struct HistoryThumbnail: View {
  let video: Video
  var body: some View {
    AsyncImage(url: video.thumbnailImageURL) { phase in
      if let image = phase.image {
        image.resizable().scaledToFill()
      } else {
        ZStack {
          Color.secondary.opacity(0.1)
          Image(systemName: "play.rectangle").font(.title).foregroundStyle(.secondary)
        }
      }
    }.frame(width: 128, height: 72).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
      .accessibilityHidden(true)
  }
}
struct FavoritesView: View {
  @ObservedObject var model: StudyModel
  let query: String
  @State private var selectedID: String?
  var matches: [FavoriteWord] {
    model.favoriteWords.filter {
      query.isEmpty || $0.surface.localizedCaseInsensitiveContains(query)
        || $0.shortGloss.localizedCaseInsensitiveContains(query)
    }
  }
  var body: some View {
    if model.favoriteWords.isEmpty {
      ContentUnavailableView(
        "お気に入りの単語はありません", systemImage: "star", description: Text("字幕をクリックして単語を固定し、辞書の星を押すと登録できます。"))
    } else if matches.isEmpty {
      ContentUnavailableView.search(text: query)
    } else {
      NavigationSplitView {
        List(matches, selection: $selectedID) { word in
          VStack(alignment: .leading, spacing: 5) {
            Text(word.surface).font(.headline)
            Text(word.shortGloss.isEmpty ? "語義は未登録です" : word.shortGloss)
              .font(.callout).foregroundStyle(.secondary).lineLimit(2)
          }.padding(.vertical, 5).tag(word.id)
            .contextMenu {
              Button("お気に入りを解除", role: .destructive) { model.removeFavorite(word.id) }
            }
        }.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
      } detail: {
        if let word = matches.first(where: { $0.id == selectedID }) {
          FavoriteDefinitionView(model: model, word: word)
        } else {
          ContentUnavailableView("単語を選んでください", systemImage: "book.closed")
        }
      }
    }
  }
}
struct FavoriteDefinitionView: View {
  @ObservedObject var model: StudyModel
  let word: FavoriteWord
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .top) {
          Text(word.surface).font(.system(size: 38, weight: .semibold)).textSelection(.enabled)
          Spacer()
          Button {
            model.removeFavorite(word.id)
          } label: {
            Image(systemName: "star.fill")
          }
          .foregroundStyle(.orange).disabled(model.pendingFavoriteIDs.contains(word.id))
          .help("お気に入りを解除")
        }
        if let partOfSpeech = word.partOfSpeech {
          Text(DictionaryPane(model: model).pos(partOfSpeech)).foregroundStyle(.secondary)
        }
        Text(word.shortGloss.isEmpty ? "語義は未登録です" : word.shortGloss).font(.title2).textSelection(
          .enabled)
        if !word.definition.isEmpty {
          Divider()
          ForEach(Array(DictionaryText.paragraphs(word.definition).enumerated()), id: \.offset) {
            _, paragraph in
            Text(paragraph).font(.body).lineSpacing(5).textSelection(.enabled)
          }
        }
        if let video = word.sourceVideo {
          Divider()
          Text("登録した動画：" + video.title).font(.caption).foregroundStyle(.secondary)
        }
        Text("登録時の辞書表示を保存しています").font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }
  }
}
