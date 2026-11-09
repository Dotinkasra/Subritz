import AppKit
import StudyCore
import SwiftUI
import UniformTypeIdentifiers

struct BackupSettings: View {
  @ObservedObject var model: StudyModel
  let window: WindowReference
  var body: some View {
    Section("バックアップ（iCloud Drive対応）") {
      Toggle(
        "自動バックアップを有効にする",
        isOn: Binding(
          get: { model.backupPreferences.enabled },
          set: { enabled in
            if enabled && model.backupPreferences.bookmark == nil {
              chooseDestination(enable: true)
            } else {
              model.setAutomaticBackup(enabled)
            }
          })
      ).toggleStyle(.checkbox).disabled(model.backupBusy)
      LabeledContent("保存先") {
        Text(
          model.backupPreferences.directoryPath.isEmpty
            ? "未選択" : model.backupPreferences.directoryPath + "/Subritz Backups"
        )
        .font(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        .frame(maxWidth: 390, alignment: .trailing)
      }
      HStack {
        Button("保存先を選択…") { chooseDestination() }
        Button("今すぐバックアップ") {
          if model.backupPreferences.bookmark == nil {
            chooseDestination(saveAfter: true)
          } else {
            model.backupNow()
          }
        }
        Spacer()
        if model.backupBusy { ProgressView().controlSize(.small) }
      }.disabled(model.backupBusy)
      LabeledContent("最終保存") {
        Text(
          model.backupPreferences.lastSavedAt.map {
            $0.formatted(.dateTime.year().month().day().hour().minute())
          } ?? "まだ保存していません"
        )
        .foregroundStyle(.secondary)
      }
      HStack {
        Button("バックアップから復元…") { chooseRestore() }
        Button("保存先を開く") {
          do {
            let root = try model.backupPreferences.resolve()
            let granted = root.startAccessingSecurityScopedResource()
            defer { if granted { root.stopAccessingSecurityScopedResource() } }
            let folder = BackupFiles.folder(in: root)
            NSWorkspace.shared.open(
              FileManager.default.fileExists(atPath: folder.path) ? folder : root)
          } catch { model.backupError = error.localizedDescription }
        }.disabled(model.backupPreferences.bookmark == nil)
        Spacer()
      }.disabled(model.backupBusy)
      if let recovery = model.lastRecoveryURL {
        Button("復元前のバックアップを表示") { NSWorkspace.shared.activateFileViewerSelecting([recovery]) }
          .disabled(model.backupBusy)
      }
      Text(
        "初回は保存先にiCloud Drive内のフォルダを選んでください。変更をまとめて自動保存し、変更が続く間は約5分ごとに更新します。自動保存は最新5件を保持し、手動保存分は残します。"
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(
        "学習データ・設定・カラムのレイアウトが対象です。キャッシュ・辞書データ本体・音声データ・APIキーは含みません。iCloudへの転送はmacOSが行うため、最終保存日時は転送完了日時とは異なります。"
      )
      .font(.caption).foregroundStyle(.secondary)
      if !model.backupStatus.isEmpty {
        Text(model.backupStatus).font(.caption).foregroundStyle(.secondary)
      }
      if let error = model.backupError {
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
    }
  }
  func chooseDestination(enable: Bool = false, saveAfter: Bool = false) {
    guard let window = window.value else { return }
    let panel = NSOpenPanel()
    panel.title = "バックアップの保存先"
    panel.message = "サイドバーのiCloud Driveから保存先を選んでください。ほかのフォルダも利用できます。"
    panel.prompt = "保存先に設定"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    if !model.backupPreferences.directoryPath.isEmpty {
      panel.directoryURL = URL(fileURLWithPath: model.backupPreferences.directoryPath)
    }
    panel.beginSheetModal(for: window) { result in
      guard result == .OK, let url = panel.url else { return }
      model.chooseBackupDestination(url, enable: enable)
      if saveAfter { model.backupNow() }
    }
  }
  func chooseRestore() {
    guard let window = window.value else { return }
    let panel = NSOpenPanel()
    panel.title = "Subritzのバックアップから復元"
    panel.prompt = "内容を確認"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [UTType(exportedAs: "jp.local.subritz.backup", conformingTo: .data)]
    if let destination = try? model.backupPreferences.resolve() {
      panel.directoryURL = BackupFiles.folder(in: destination)
    }
    panel.beginSheetModal(for: window) { result in
      if result == .OK, let url = panel.url { model.prepareBackupRestore(url) }
    }
  }
}

struct BackupRestoreConfirmation: ViewModifier {
  @ObservedObject var model: StudyModel
  func body(content: Content) -> some View {
    content.alert(
      "バックアップから復元しますか？",
      isPresented: Binding(
        get: { model.backupRestorePrompt != nil },
        set: { if !$0 { model.cancelBackupRestore() } }), presenting: model.pendingBackupRestore
    ) { archive in
      Button("キャンセル", role: .cancel) { model.cancelBackupRestore() }
      Button("復元する", role: .destructive) { model.confirmBackupRestore(archive) }
    } message: { _ in
      Text(model.backupRestorePrompt ?? "")
    }
  }
}
