import StudyCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @ObservedObject var model: StudyModel
  @Environment(\.dismiss) var dismiss
  @State private var apiKey = APISecret.read()
  @State private var importing = false
  var body: some View {
    VStack {
      HStack {
        Text("設定").font(.title2.bold())
        Spacer()
        Button("閉じる") { dismiss() }
      }.padding()
      Form {
        Section("一般") {
          TextField("yt-dlp 実行ファイル（空欄で自動検出）", text: $model.settings.ytDlpPath)
          Picker("動画キャッシュ上限", selection: $model.settings.cacheMB) {
            ForEach([256, 512, 1024, 2048, 5120], id: \.self) { Text("\($0) MB").tag($0) }
          }
          HStack {
            Text("現在 \(model.cacheUsage/1024/1024) MB")
            Spacer()
            Button("動画キャッシュを削除") { model.clearCache() }
          }
        }
        Section("辞書") {
          Picker("辞書 Provider", selection: $model.settings.dictionary) {
            Text("macOS 標準辞書").tag("macOS")
            Text("英辞郎").tag("eijiro")
          }
          Text("英辞郎：\(model.eijiroCount) 項目").foregroundStyle(.secondary)
          HStack {
            Button("英辞郎をインポート / 再インポート") { importing = true }
            Button("英辞郎を削除") { model.removeDictionary() }
          }
          Text("ご自身が所有する英辞郎テキストデータを指定してください。macOS 辞書の日本語語義は OS の辞書設定に依存します。").font(.caption)
            .foregroundStyle(.secondary)
        }
        Section("文法 / LLM") {
          Picker("Provider", selection: $model.settings.provider) {
            Text("OpenAI 互換ローカル LLM").tag("local")
            Text("Codex CLI").tag("codex")
          }
          if model.settings.provider == "local" {
            TextField("Base URL", text: $model.settings.baseURL)
            SecureField("API key（任意・Keychain に保存）", text: $apiKey)
            Text("字幕の英文を上記 endpoint へ送信します。").font(.caption).foregroundStyle(.secondary)
          } else {
            TextField("Codex 実行ファイル（空欄で自動検出）", text: $model.settings.codexPath)
            Text("字幕の英文を認証済み Codex CLI へ送信します。事前にターミナルで認証してください。").font(.caption).foregroundStyle(
              .secondary)
          }
          TextField("モデル名（Codex は空欄で CLI の設定を使用）", text: $model.settings.model)
          if model.settings.provider == "codex" {
            Text("モデル ID は gpt-6-luna のような小文字の識別子を指定します。空欄なら認証済み CLI の設定を使用します。").font(.caption)
              .foregroundStyle(.secondary)
          }
          HStack {
            Text("タイムアウト（秒）")
            TextField("秒", value: $model.settings.timeout, format: .number).frame(width: 100)
          }
          Text("Provider の変更は次回の動画読み込みから反映します。").font(.caption).foregroundStyle(.secondary)
        }
      }.formStyle(.grouped)
      HStack {
        Text(model.settingsMessage).font(.caption)
        Spacer()
        Button("保存") { model.saveSettings(apiKey: apiKey) }.buttonStyle(.borderedProminent)
      }.padding()
    }.frame(width: 690, height: 720).fileImporter(
      isPresented: $importing, allowedContentTypes: [.plainText, .data]
    ) { result in
      switch result {
      case .success(let url): model.importDictionary(url)
      case .failure(let error): model.settingsMessage = error.localizedDescription
      }
    }.task { await model.refreshStorage() }
  }
}
