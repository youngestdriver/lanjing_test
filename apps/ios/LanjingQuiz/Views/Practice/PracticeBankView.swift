import SwiftUI

/// Navigation values for the practice flow (NativeStack links).
enum PracticeRoute: Hashable {
    case subcategories(category: String)
    case quiz(category: String, subCategory: String)
}

/// The 练习 tab: gates practice on the local bank being downloaded (first
/// use downloads it from the configured server; while downloading, only
/// progress is shown), then offers 大类 → 子类 → 刷题.
struct PracticeBankView: View {
    @Environment(AppState.self) private var appState
    @State private var vm: PracticeBankViewModel?

    var body: some View {
        NavigationStack {
            Group {
                switch vm?.phase ?? .idle {
                case .idle:
                    downloadingView(nil)
                case .downloading(let progress):
                    downloadingView(progress)
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
    }

    /// First-use gate: downloading shows progress only, no other interaction.
    private func downloadingView(_ progress: QuestionBankClient.Progress?) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(progress?.fileIndex ?? 0), total: Double(progress?.fileCount ?? 6))
                .progressViewStyle(.linear)
                .frame(maxWidth: 260)
            Text("正在下载题库（\(min(progress?.fileIndex ?? 0, progress?.fileCount ?? 6))/\(progress?.fileCount ?? 6)）")
                .font(.system(size: 14, weight: .semibold))
            if let progress {
                Text(progress.fileName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("首次使用需下载全部题目到本机，完成后即可离线练习")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("题库下载失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text("\(message)\n\n请检查服务器是否已启动，并在 我的 > 题库服务器地址 确认地址正确后重试。")
        } actions: {
            Button("重试") {
                Task { await vm?.updateBank() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
