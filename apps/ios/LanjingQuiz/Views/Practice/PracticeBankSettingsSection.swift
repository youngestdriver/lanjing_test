import SwiftUI

/// 我的 > 题库 settings: server address, local-bank status, 更新题库 button.
/// Creates its own PracticeBankViewModel (a second instance is harmless — the
/// store commits atomically with meta written last).
struct PracticeBankSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var serverURL = ""
    @State private var vm: PracticeBankViewModel?
    @State private var status: String?

    var body: some View {
        Section {
            TextField("题库服务器地址", text: $serverURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("更新题库") {
                BankSettings.saveServerURL(serverURL)
                Task { await vm?.updateBank() }
            }
            .disabled(isDownloading)
            if isDownloading, let progress = downloadProgress {
                ProgressView(value: Double(progress.fileIndex), total: Double(progress.fileCount))
                    .progressViewStyle(.linear)
                Text("正在下载 \(progress.fileName)（\(progress.fileIndex + 1)/\(progress.fileCount)）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("题库")
        } footer: {
            Text("首次进入练习页会自动下载全部题目并缓存到本机，完成后可离线练习；题目图片不缓存，展示时从网络加载。模拟器默认 127.0.0.1:3000，真机请填电脑的局域网地址。")
        }
        .onAppear {
            serverURL = BankSettings.loadServerURL()
            if vm == nil {
                vm = PracticeBankViewModel(appState: appState)
            }
            refreshStatus()
        }
        .onChange(of: serverURL) { _, newValue in
            BankSettings.saveServerURL(newValue)
        }
        .onChange(of: vm?.phase) { _, _ in refreshStatus() }
    }

    private var isDownloading: Bool {
        if case .downloading = vm?.phase { return true }
        return false
    }

    private var downloadProgress: QuestionBankClient.Progress? {
        if case .downloading(let progress) = vm?.phase { return progress }
        return nil
    }

    private func refreshStatus() {
        guard let vm else { return }
        switch vm.phase {
        case .ready:
            if let meta = vm.meta {
                status = "已下载 · 版本 round \(meta.round ?? 0) · \(meta.totalCount) 题"
            } else {
                status = "已下载"
            }
        case .failed(let message):
            status = "下载失败：\(message)"
        case .downloading:
            status = nil
        case .idle:
            if let meta = vm.meta {
                status = "已下载 · 版本 round \(meta.round ?? 0) · \(meta.totalCount) 题"
            } else {
                status = "尚未下载（首次进入练习页自动下载）"
            }
        }
    }
}
