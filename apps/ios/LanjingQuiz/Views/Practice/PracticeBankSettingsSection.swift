import SwiftUI
import UIKit

/// 我的 > 题库 settings: local-bank status, 更新题库 / 删除题库 (re-crawl /
/// wipe the local bank) and a separate 日志 section with 日志导出 (plain-text
/// export of the crawl log — per-paper step outcomes, saved as crawl_log.jsonl
/// during crawls). Creates its own PracticeBankViewModel (a second instance is
/// harmless — the store commits atomically per paper with meta.papers progress).
struct PracticeBankSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var vm: PracticeBankViewModel?
    @State private var exportURL: URL?
    @State private var logStatus: String?
    @State private var confirmDelete = false

    var body: some View {
        Section {
            Button("更新题库") {
                Task { await vm?.updateBank() }
            }
            .disabled(isCrawling)
            if isCrawling, let progress = crawlProgress {
                ProgressView(value: Double(progress.index), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.linear)
                if progress.total > 0 {
                    Text("正在爬取 \(progress.paperName)（\(progress.index)/\(progress.total)）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button("删除题库", role: .destructive) {
                confirmDelete = true
            }
            .disabled(isCrawling)
        } header: {
            Text("题库")
        }
        .confirmationDialog(
            "删除本地题库？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除题库", role: .destructive) {
                deleteBank()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本地题库将被清空（含爬取日志），再次进入练习页会重新从蓝鲸平台爬取全部试卷，每张新卷占用一次作答机会并自动结束。")
        }

        Section {
            Button("日志导出") {
                exportBankLog()
            }
            if let logStatus {
                Text(logStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("日志")
        }
        .onAppear {
            if vm == nil {
                vm = PracticeBankViewModel(appState: appState)
            }
        }
        .sheet(isPresented: Binding(
            get: { exportURL != nil },
            set: { if !$0 { exportURL = nil } }
        )) {
            if let exportURL {
                ShareSheet(activityItems: [exportURL])
            }
        }
    }

    /// Wipe the local bank (storage + crawl log) and notify every bank VM
    /// (练习 tab's instance included) via AppState.bankResetVersion.
    private func deleteBank() {
        vm?.bankWasDeleted()
        appState.deleteBank()
    }

    /// Write the crawl log (every paper's step outcomes) to a date-time named
    /// txt and hand it to the system share sheet (save to Files / AirDrop / …).
    private func exportBankLog() {
        guard let vm else { return }
        let entries = vm.bankStore.loadCrawlLog()
        guard !entries.isEmpty else {
            logStatus = "暂无爬取日志（完成一次爬取后生成）"
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BankExport", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: BankLogic.exportFileName())
        do {
            try BankLogic.exportLogText(entries).write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
            logStatus = nil
        } catch {
            logStatus = "导出失败：\(error.localizedDescription)"
        }
    }

    private var isCrawling: Bool {
        if case .downloading = vm?.phase { return true }
        return false
    }

    private var crawlProgress: PracticeUpstreamClient.CrawlProgress? {
        if case .downloading(let progress) = vm?.phase { return progress }
        return nil
    }
}

/// System share sheet (保存到"文件" / AirDrop / 微信 …) for the exported txt.
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
