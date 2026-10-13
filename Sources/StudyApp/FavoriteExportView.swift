import StudyCore
import SwiftUI
import UniformTypeIdentifiers

struct FavoriteExportView: View {
  @ObservedObject var model: StudyModel
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var format: FavoriteExportFormat = .text
  @State private var range = RangeChoice.all
  @State private var start = Date()
  @State private var end = Date()
  @State private var count = "100"
  @State private var metadata = false
  @State private var exporting = false
  @State private var message: String?
  @State private var initialized = false
  @State private var window = WindowReference()
  enum RangeChoice: String, CaseIterable { case all, dates, latest }

  private var exporter: FavoriteExport {
    let selection: FavoriteExportRange
    switch range {
    case .all: selection = .all
    case .dates: selection = .dates(start: start, end: end)
    case .latest: selection = .latest(Int(count.trimmingCharacters(in: .whitespaces)) ?? 0)
    }
    return FavoriteExport(format: format, range: selection, includeMetadata: metadata)
  }
  private var selection: Result<[FavoriteWord], Error> {
    Result { try exporter.selected(from: model.favoriteWords) }
  }
  private var selectedCount: Int { (try? selection.get().count) ?? 0 }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("お気に入りをエクスポート").font(.title2.bold())
      Form {
        Picker("ファイル形式", selection: $format) {
          Text("テキスト（.txt）").tag(FavoriteExportFormat.text)
          Text("CSV（.csv）").tag(FavoriteExportFormat.csv)
        }
        Picker("対象範囲", selection: $range) {
          Text("すべて").tag(RangeChoice.all)
          Text("登録日の範囲").tag(RangeChoice.dates)
          Text("最新の指定件数").tag(RangeChoice.latest)
        }
        if range == .dates {
          DatePicker("開始日", selection: $start, displayedComponents: .date)
          DatePicker("終了日", selection: $end, displayedComponents: .date)
          Text("開始日・終了日の登録分も含みます。")
            .font(.caption).foregroundStyle(.secondary)
        } else if range == .latest {
          TextField("最新からの件数", text: $count)
            .textFieldStyle(.roundedBorder)
        }
        Toggle("メタデータを含める", isOn: $metadata)
        Text("登録日時、登録動画のタイトル・URL、出現箇所の動画・時刻・URLを含めます。複数の出現箇所は列挙します。")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }.disabled(exporting)
      Text("\(selectedCount)語を書き出します（英単語のみ／UTF-8）")
        .foregroundStyle(.secondary)
      Text("日本語の語義・辞書の詳細定義は書き出しません。")
        .font(.caption).foregroundStyle(.secondary)
      if case .failure(let error) = selection {
        Text(error.localizedDescription).font(.callout).foregroundStyle(.red)
      }
      if let message { Text(message).font(.callout).foregroundStyle(.red) }
      HStack {
        if exporting { ProgressView().controlSize(.small); Text("書き出しています…") }
        Spacer()
        Button("キャンセル") { dismissWindow(id: "favorite-export") }
          .keyboardShortcut(.cancelAction).disabled(exporting)
        Button("OK") { export() }.keyboardShortcut(.defaultAction)
          .disabled(exporting || model.libraryLoading || selectedCount == 0)
      }
    }.padding(24).frame(width: 480)
      .background(ExportWindowReference(window: window).frame(width: 0, height: 0))
      .onAppear {
        guard !initialized else { return }
        initialized = true
        start = model.favoriteWords.map(\.savedAt).min() ?? Date()
        end = Date()
      }
  }

  private func export() {
    message = nil
    guard let window = window.value else {
      message = "保存ダイアログを開けませんでした。ウィンドウを開き直してください。"
      return
    }
    // Capture the selection and library together so later changes cannot alter the file mid-export.
    let contents: String
    do { contents = try exporter.contents(words: model.favoriteWords, timestamps: model.videoTimestamps) }
    catch { message = error.localizedDescription; return }
    let panel = NSSavePanel()
    panel.title = "お気に入りを書き出す"
    panel.nameFieldStringValue = "Subritz-favorites." + format.fileExtension
    panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .plainText]
    panel.canCreateDirectories = true
    exporting = true
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let destination = panel.url else { exporting = false; return }
      Task { @MainActor in
        do {
          try await Task.detached(priority: .userInitiated) {
            try contents.write(to: destination, atomically: true, encoding: .utf8)
          }.value
          exporting = false
          dismissWindow(id: "favorite-export")
        } catch {
          exporting = false
          message = "書き出せませんでした：" + error.localizedDescription
        }
      }
    }
  }
}

private struct ExportWindowReference: NSViewRepresentable {
  let window: WindowReference
  func makeNSView(context: Context) -> MainWindowLifecycle.WindowProbe {
    let view = MainWindowLifecycle.WindowProbe()
    view.onWindow = { window.value = $0 }
    return view
  }
  func updateNSView(_ view: MainWindowLifecycle.WindowProbe, context: Context) {}
}
