import SwiftUI

/// Navigation values for the practice flow (NativeStack links).
enum PracticeRoute: Hashable {
    case papers(category: String)
    case subcategories(paper: Exam)
    case quiz(paper: Exam, subCategory: String)
}

/// The 练习 tab: gates practice on an upstream session (questions are fetched
/// directly from the 蓝鲸平台), then offers 分类 → 试卷 → 题型 → 刷题.
struct PracticeBankView: View {
    @Environment(AppState.self) private var appState
    @State private var vm: PracticeBankViewModel?

    var body: some View {
        NavigationStack {
            Group {
                switch vm?.phase ?? .idle {
                case .idle, .loading:
                    loadingView
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
                case .papers(let category):
                    PracticePaperListView(vm: vm!, category: category)
                case .subcategories(let paper):
                    PracticeSubcategoryListView(vm: vm!, paper: paper)
                case .quiz(let paper, let subCategory):
                    PracticeQuizView(vm: vm!, paper: paper, subCategory: subCategory)
                }
            }
        }
        .task {
            if vm == nil {
                vm = PracticeBankViewModel(appState: appState)
            }
            await vm?.load()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在加载试卷…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
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
            Label("加载失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("重试") {
                Task { await vm?.load() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
