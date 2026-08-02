import SwiftUI

private enum HomeTab: Hashable {
    case exams
    case practice
    case profile
}

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: HomeTab = .exams

    var body: some View {
        ZStack {
            switch appState.route {
            case .login:
                LoginView()
            case .examList:
                HomeTabView(selectedTab: $selectedTab)
            case .quiz(let exam):
                QuizView(exam: exam)
            case .result(let result):
                ResultView(result: result)
            }
        }
        .overlay(alignment: .top) {
            if let notice = appState.notice {
                HStack(spacing: 12) {
                    Text(notice)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        appState.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(DS.orange)
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))
                .padding(.horizontal)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.notice)
        .task { await appState.start() }
    }
}

private struct HomeTabView: View {
    @Binding var selectedTab: HomeTab

    var body: some View {
        TabView(selection: $selectedTab) {
            ExamListView()
                .tabItem {
                    Label("考试列表", systemImage: "list.bullet.rectangle")
                }
                .tag(HomeTab.exams)

            PracticeView(showExamList: { selectedTab = .exams })
                .tabItem {
                    Label("练习", systemImage: "target")
                }
                .tag(HomeTab.practice)

            ProfileView()
                .tabItem {
                    Label("我的", systemImage: "person.crop.circle")
                }
                .tag(HomeTab.profile)
        }
    }
}

private struct PracticeView: View {
    let showExamList: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("开始练习", systemImage: "target")
            } description: {
                Text("从考试列表选择一份试卷开始答题")
            } actions: {
                Button("前往考试列表", action: showExamList)
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle("练习")
        }
    }
}

private struct ProfileView: View {
    @Environment(AppState.self) private var appState

    private var themeBinding: Binding<Theme> {
        Binding(
            get: { appState.theme },
            set: { newTheme in
                appState.theme = newTheme
                newTheme.save()
            }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("已登录", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(DS.accent)
                } header: {
                    Text("账户")
                }

                Section("外观") {
                    Picker("主题", selection: themeBinding) {
                        Text("浅色").tag(Theme.light)
                        Text("深色").tag(Theme.dark)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button("退出登录", role: .destructive) {
                        appState.logout()
                    }
                }
            }
            .navigationTitle("我的")
        }
    }
}
