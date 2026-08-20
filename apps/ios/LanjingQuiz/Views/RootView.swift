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
        }
        .animation(.easeInOut(duration: 0.25), value: appState.notice)
        .task {
            await appState.start()
        }
        .onChange(of: appState.route) { _, newRoute in
            // 登录页「跳过」以未登录状态进入主界面:直接落在「我的」tab,
            // 便于先配置 Cookie 云端同步再登录(正常登录 hasSession 为真,
            // 不会触发)。其他路由变化不受影响。
            if case .examList = newRoute, !appState.api.hasSession {
                selectedTab = .profile
            }
        }
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

            PracticeBankView()
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

private struct ProfileView: View {
    @Environment(AppState.self) private var appState

    /// 跟随系统颜色设置 toggle: on → .system, off → last manual light/dark.
    private var followSystemBinding: Binding<Bool> {
        Binding(
            get: { appState.theme == .system },
            set: { appState.setFollowsSystem($0) }
        )
    }

    private var autoAdvanceBinding: Binding<Bool> {
        Binding(
            get: { appState.autoAdvanceOnCorrect },
            set: { appState.autoAdvanceOnCorrect = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if appState.api.hasSession {
                        Label("已登录", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(DS.accent)
                    } else {
                        Label("未登录", systemImage: "person.crop.circle.badge.questionmark")
                            .foregroundStyle(.secondary)
                        Button("去登录") {
                            appState.route = .login
                        }
                        .accessibilityIdentifier("goto-login")
                    }
                } header: {
                    Text("账户")
                }

                Section("外观") {
                    Toggle("跟随系统颜色设置", isOn: followSystemBinding)
                    if appState.theme != .system {
                        Button {
                            appState.theme = appState.theme == .dark ? .light : .dark
                            appState.theme.save()
                        } label: {
                            HStack {
                                Text("深色模式")
                                Spacer()
                                if appState.theme == .dark {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(DS.accent)
                                }
                            }
                        }
                    }
                }

                Section("答题设置") {
                    Toggle(isOn: autoAdvanceBinding) {
                        Label("答对后自动下一题", systemImage: "arrow.right.square")
                    }
                }

                PracticeBankSettingsSection()

                CookieCloudSection()

                Section {
                    Button("退出登录", role: .destructive) {
                        appState.logout()
                    }
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("我的")
        }
    }

    /// "1.0 (1)" from the bundle (MARKETING_VERSION + CURRENT_PROJECT_VERSION).
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }
}

/// 云端同步 settings rows: CookieCloud config (server / UUID / password),
/// mirroring the web app's "Cookie 云端同步" section. Password goes to the
/// Keychain; everything else to UserDefaults.
private struct CookieCloudSection: View {
    @Environment(AppState.self) private var appState
    @State private var enabled = false
    @State private var server = ""
    @State private var uuid = ""
    @State private var password = ""
    @State private var statusText: String?
    @State private var isSyncing = false

    private var isConfigured: Bool {
        enabled && !server.isEmpty && !uuid.isEmpty && !password.isEmpty
    }

    private func load() {
        let config = CookieCloudSettings.loadConfig()
        enabled = config.enabled
        server = config.server
        uuid = config.uuid
        password = CookieCloudSettings.loadPassword() ?? ""
    }

    private func save() {
        CookieCloudSettings.saveConfig(.init(enabled: enabled, server: server, uuid: uuid))
        CookieCloudSettings.savePassword(password)
    }

    private func runSync() async {
        isSyncing = true
        defer { isSyncing = false }
        let result = await appState.cookieCloudSync.syncNow()
        if let error = result.error {
            statusText = "同步失败：\(error)"
        } else {
            var parts = ["同步完成"]
            if result.applied { parts.append("已导入云端会话") }
            if result.pushed { parts.append("已上传本地会话") }
            statusText = parts.joined(separator: "，")
        }
    }

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label("Cookie 云端同步", systemImage: "cloud.fill")
            }
            if enabled {
                TextField("服务器地址", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("UUID", text: $uuid)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
                Button {
                    Task { await runSync() }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Text("立即同步")
                    }
                }
                .disabled(!isConfigured || isSyncing)
                if let statusText {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("云端同步")
        } footer: {
            Text("登录凭证会加密后上传到你配置的服务器；UUID 与密码需与浏览器扩展一致，服务地址是你自建的 CookieCloud。")
        }
        .onAppear(perform: load)
        .onChange(of: enabled) { _, _ in save() }
        .onChange(of: server) { _, _ in save() }
        .onChange(of: uuid) { _, _ in save() }
        .onChange(of: password) { _, _ in save() }
    }
}

