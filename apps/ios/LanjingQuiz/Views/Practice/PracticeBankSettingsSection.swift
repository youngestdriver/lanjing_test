import SwiftUI

/// 我的 > 题库 settings: local-bank status and 更新题库 (re-crawl from the
/// upstream platform). Creates its own PracticeBankViewModel (a second
/// instance is harmless — the store commits atomically per paper with
/// meta.papers progress).
struct PracticeBankSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var vm: PracticeBankViewModel?
    @State private var status: String?

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
            if let status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("题库")
        } footer: {
            Text("首次进入练习页会自动从蓝鲸平台爬取全部题目并保存在本机，完成后可离线练习；题目图片不缓存，展示时从网络加载。爬取每张新卷会占用一次作答机会并自动结束。")
        }
        .onAppear {
            if vm == nil {
                vm = PracticeBankViewModel(appState: appState)
            }
            refreshStatus()
        }
        .onChange(of: vm?.phase) { _, _ in refreshStatus() }
    }

    private var isCrawling: Bool {
        if case .downloading = vm?.phase { return true }
        return false
    }

    private var crawlProgress: PracticeUpstreamClient.CrawlProgress? {
        if case .downloading(let progress) = vm?.phase { return progress }
        return nil
    }

    private func refreshStatus() {
        guard let vm else { return }
        switch vm.phase {
        case .ready:
            if let meta = vm.meta {
                status = "已爬取 · 版本 round \(meta.round ?? 0) · \(meta.totalCount) 题"
            } else {
                status = "已爬取"
            }
        case .failed(let message):
            status = "爬取失败：\(message)"
        case .downloading:
            status = nil
        case .idle:
            if let meta = vm.meta {
                status = "已爬取 · 版本 round \(meta.round ?? 0) · \(meta.totalCount) 题"
            } else {
                status = "尚未爬取（首次进入练习页自动爬取）"
            }
        case .needsLogin:
            status = "需要登录后爬取"
        }
    }
}
