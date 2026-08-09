import SwiftUI

/// Navigation values for the practice flow (NativeStack links).
enum PracticeRoute: Hashable {
    case subcategories(category: String)
    case quiz(category: String, subCategory: String)
}

/// The 练习 tab: gates practice on the local bank being crawled (first use
/// crawls every 机考题库 paper directly from the upstream platform; while
/// crawling, only progress is shown), then offers 大类 → 题型 → 刷题.
struct PracticeBankView: View {
    @Environment(AppState.self) private var appState
    @State private var vm: PracticeBankViewModel?

    var body: some View {
        NavigationStack {
            Group {
                switch vm?.phase ?? .idle {
                case .idle:
                    loadingView
                case .downloading(let progress):
                    downloadingView(progress)
                case .needsLogin:
                    needsLoginView
                case .failed(let message):
                    failedView(message)
                case .ready:
                    PracticeCategoryListView(vm: vm!)
                }
            }
            .navigationTitle("练习")
            // Native push/pop via NavigationLink values — the system back
            // button and swipe-back work at every level.
            .navigationDestination(for: PracticeRoute.self) { route in
                switch route {
                case .subcategories(let category):
                    PracticeSubcategoryListView(vm: vm!, category: category)
                case .quiz(let category, let subCategory):
                    PracticeQuizView(vm: vm!, category: category, subCategory: subCategory)
                }
            }
        }
        .task {
            if vm == nil {
                vm = PracticeBankViewModel(appState: appState)
            }
            await vm?.ensureBankReady()
        }
        // 我的 > 删除题库 wiped the local bank — reset this VM and re-crawl.
        .onChange(of: appState.bankResetVersion) { _, _ in
            vm?.bankWasDeleted()
            Task { await vm?.ensureBankReady() }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在检查题库…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// First-use gate: crawling shows progress only, no other interaction.
    private func downloadingView(_ progress: PracticeUpstreamClient.CrawlProgress) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(progress.index), total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
                .frame(maxWidth: 260)
            if progress.total > 0 {
                Text("正在爬取题库（\(progress.index)/\(progress.total)）")
                    .font(.system(size: 14, weight: .semibold))
                Text(progress.paperName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("正在爬取题库…")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var needsLoginView: some View {
        ContentUnavailableView {
            Label("需要登录", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text("练习题目直接从蓝鲸平台获取，登录后才能使用。")
        } actions: {
            Button("去登录") {
                appState.route = .login
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func failedView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("题库爬取失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text("\(message)\n\n请检查网络后重试；已爬取的题目会保留，重试会从中断处继续。")
        } actions: {
            Button("重试") {
                Task { await vm?.updateBank() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
