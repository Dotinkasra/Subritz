import AppKit
import StudyCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @ObservedObject var model: StudyModel
  @State private var apiKey = APISecret.read()
  @State private var choosingDictionary = false
  @State private var window = WindowReference()
  @State private var dictionaryBrowsers: [DictionaryBrowser.Application] = []
  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("一般") {
          TextField("yt-dlp 実行ファイル", text: $model.settings.ytDlpPath)
          Text("空欄の場合は自動検出します。").font(.caption).foregroundStyle(.secondary)
        }
        Section("動画キャッシュ") {
          Picker("容量の上限", selection: $model.settings.cacheMB) {
            ForEach([256, 512, 1024, 2048, 5120], id: \.self) { Text("\($0) MB").tag($0) }
          }
          LabeledContent("保存先") {
            Text(model.settings.cacheURL.path).font(.caption).textSelection(.enabled)
              .lineLimit(2).truncationMode(.middle).frame(maxWidth: 390, alignment: .trailing)
          }
          HStack {
            Button("保存先を選択…") { chooseCacheDirectory() }
            Button("標準の保存先に戻す") { model.changeCacheDirectory(to: nil) }
              .disabled(model.settings.cacheDirectory.isEmpty)
            Spacer()
            if model.isChangingCacheDirectory { ProgressView().controlSize(.small) }
          }.disabled(model.isChangingCacheDirectory)
          HStack {
            Text("使用量：\(model.cacheUsage/1024/1024) MB").foregroundStyle(.secondary)
            Spacer()
            Button("キャッシュを削除") { model.clearCache() }
              .disabled(model.isChangingCacheDirectory)
          }
          if !model.cacheMessage.isEmpty {
            Text(model.cacheMessage).font(.caption).foregroundStyle(.secondary)
          }
          Text("保存先の変更後も、以前のキャッシュは元のフォルダに残ります。英辞郎データの保存先は変わりません。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("辞書") {
          LabeledContent("辞書を開く際のブラウザ") {
            DictionaryBrowserPicker(selection: $model.settings.dictionaryBrowser,
              applications: dictionaryBrowsers)
              .frame(width: 280)
          }
          Text("Cambridge Dictionaryの英英辞書を開く方法を選びます。")
            .font(.caption).foregroundStyle(.secondary)
          Picker("使用する辞書", selection: $model.settings.dictionary) {
            Text("macOS 標準辞書").tag("macOS")
            Text("英辞郎").tag("eijiro")
          }
          HStack {
            Text("英辞郎：\(model.eijiroCount)項目").foregroundStyle(.secondary)
            Spacer()
            Button("インポート…") { choosingDictionary = true }
              .disabled(choosingDictionary || model.dictionaryBusy)
            Button("削除") { model.removeDictionary() }
              .disabled(model.dictionaryBusy || model.eijiroCount == 0)
          }
          if model.dictionaryBusy {
            HStack {
              ProgressView().controlSize(.small)
              Text(model.isImportingDictionary ? "英辞郎をインポート中…" : "英辞郎を削除中…")
            }.accessibilityElement(children: .combine)
          }
          if !model.dictionaryMessage.isEmpty {
            Text(model.dictionaryMessage).font(.caption).foregroundStyle(.secondary)
          }
          Text("ご自身が所有する英辞郎テキストを指定してください。macOS辞書の日本語語義はOSの辞書設定に依存します。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("文法解析") {
          Picker("解析サービス", selection: $model.settings.provider) {
            Text("OpenAI 互換ローカル LLM").tag("local")
            Text("Codex CLI").tag("codex")
          }
          if model.settings.provider == "local" {
            TextField("Base URL", text: $model.settings.baseURL)
            TextField("ローカル LLM のモデル名", text: $model.settings.localModel)
            Picker("同時解析数", selection: $model.settings.localConcurrency) {
              Text("1（ローカルPC向け）").tag(1)
              Text("2（並列処理できるサーバー向け）").tag(2)
            }
            SecureField("API key（任意）", text: $apiKey)
            Text("API keyはKeychainに保存します。字幕の英文を上記URLへ送信します。")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            TextField("Codex 実行ファイル", text: $model.settings.codexPath)
            TextField("Codex のモデル名", text: $model.settings.codexModel)
            Picker("同時解析数", selection: $model.settings.codexConcurrency) {
              Text("1").tag(1)
              Text("2（複数の文を並列解析）").tag(2)
            }
            Text("実行ファイルとモデル名は空欄でCLIの設定を使用します。モデルIDはgpt-6-lunaなどを指定してください。事前にターミナルで認証が必要です。")
              .font(.caption).foregroundStyle(.secondary)
          }
          TextField("タイムアウト（秒）", value: $model.settings.timeout, format: .number)
          Text("5〜3600秒。解析サービスの変更は次の動画読み込みから反映します。モデル名はサービスごとに保存します。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }.formStyle(.grouped).textFieldStyle(.roundedBorder)
      Divider()
      HStack {
        Text(model.settingsMessage.isEmpty ? "変更は自動で保存されます" : model.settingsMessage)
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("閉じる") {
          model.flushAPIKey()
          window.value?.close()
        }.keyboardShortcut(.cancelAction)
      }.padding(16)
    }.frame(width: 720, height: 780)
      .onAppear { dictionaryBrowsers = DictionaryBrowser.installed() }
      .background(SettingsWindowTitle(window: window).frame(width: 0, height: 0))
      .onChange(of: model.settings) { old, _ in model.saveSettings(previous: old) }
      .onChange(of: apiKey) { _, key in model.scheduleAPIKeySave(key) }
      .onDisappear { model.flushAPIKey() }
      .fileImporter(isPresented: $choosingDictionary, allowedContentTypes: [.plainText, .data]) {
        result in
        switch result {
        case .success(let url): model.importDictionary(url)
        case .failure(let error): model.dictionaryMessage = error.localizedDescription
        }
      }.task { await model.refreshStorage() }
  }
  func chooseCacheDirectory() {
    let panel = NSOpenPanel()
    panel.title = "動画キャッシュの保存先"
    panel.prompt = "選択"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = model.settings.cacheURL
    if let window = window.value {
      panel.beginSheetModal(for: window) { response in
        if response == .OK, let url = panel.url { model.changeCacheDirectory(to: url) }
      }
    }
  }
}
