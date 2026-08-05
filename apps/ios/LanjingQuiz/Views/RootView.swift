import SwiftUI

private enum HomeTab: Hashable {
    case exams
    case practice
    case profile
}

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: HomeTab = .exams
    @State private var isSplashVisible = true
    @State private var initialRouteIsReady = false
    @State private var splashAnimationIsFinished = false

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

            if isSplashVisible {
                SplashView {
                    splashAnimationIsFinished = true
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.notice)
        .onChange(of: initialRouteIsReady && splashAnimationIsFinished) { _, isReadyToDismiss in
            guard isReadyToDismiss else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                isSplashVisible = false
            }
        }
        .task {
            await appState.start()
            initialRouteIsReady = true
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

                Section("答题设置") {
                    Toggle(isOn: autoAdvanceBinding) {
                        Label("答对后自动下一题", systemImage: "arrow.right.square")
                    }
                }

                CookieCloudSection()

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

// MARK: - Launch animation

/// A lightweight, resolution-independent launch scene. The system launch screen
/// remains static by design; this view supplies the first animated app frame.
private struct SplashView: View {
    let onAnimationFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var whaleProgress: CGFloat = 0
    @State private var sprayProgress: CGFloat = 0
    @State private var dropletProgress: CGFloat = 0
    @State private var rippleProgress: CGFloat = 0
    @State private var tailIsWagging = false
    @State private var hasReportedAnimationFinish = false

    var body: some View {
        GeometryReader { proxy in
            let sceneScale = min(max(proxy.size.width / 390, 0.75), 1.25)
            let whaleSize = min(proxy.size.width * 0.72, 330 * sceneScale)
            let sceneCenter = CGPoint(
                x: proxy.size.width / 2,
                y: proxy.size.height * 0.43
            )

            ZStack {
                LinearGradient(
                    colors: [
                        Color(hex: 0x063E74),
                        Color(hex: 0x087AB8),
                        Color(hex: 0x1CB0F6),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [.white.opacity(0.2), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.7
                )

                SplashBubble(size: 11 * sceneScale, progress: whaleProgress)
                    .position(x: sceneCenter.x - whaleSize * 0.5, y: sceneCenter.y - whaleSize * 0.44)
                SplashBubble(size: 18 * sceneScale, progress: dropletProgress)
                    .position(x: sceneCenter.x + whaleSize * 0.46, y: sceneCenter.y - whaleSize * 0.2)
                SplashBubble(size: 8 * sceneScale, progress: rippleProgress)
                    .position(x: sceneCenter.x - whaleSize * 0.56, y: sceneCenter.y + whaleSize * 0.14)

                SplashOcean(progress: rippleProgress)
                    .frame(width: whaleSize * 1.4, height: whaleSize * 0.46)
                    .position(x: sceneCenter.x, y: sceneCenter.y + whaleSize * 0.31)

                SplashWaterSpout(progress: sprayProgress)
                    .frame(width: whaleSize * 0.62, height: whaleSize * 0.74, alignment: .bottom)
                    .position(x: sceneCenter.x - whaleSize * 0.11, y: sceneCenter.y - whaleSize * 0.37)

                SplashDroplets(progress: dropletProgress, scale: sceneScale)
                    .position(x: sceneCenter.x - whaleSize * 0.1, y: sceneCenter.y - whaleSize * 0.39)

                SplashWhale(
                    size: whaleSize,
                    progress: whaleProgress,
                    tailIsWagging: tailIsWagging
                )
                .position(sceneCenter)

                VStack(spacing: 8) {
                    Text("蓝鲸助手")
                        .font(.system(size: 29 * sceneScale, weight: .heavy, design: .rounded))
                    Text("让每一次练习，都更清晰")
                        .font(.system(size: 14 * sceneScale, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .foregroundStyle(.white)
                .opacity(Double(whaleProgress))
                .offset(y: (1 - whaleProgress) * 12)
                .position(x: sceneCenter.x, y: sceneCenter.y + whaleSize * 0.62)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("蓝鲸助手，正在启动")
        .accessibilityAddTraits(.isImage)
        .task { @MainActor in
            await playAnimation()
        }
    }

    @MainActor
    private func playAnimation() async {
        // `Task.sleep` throws as soon as SwiftUI cancels this view task.  The
        // guards below deliberately stop any later animation phases in that
        // case, but the splash must still report completion so RootView can
        // remove an already-visible overlay.  `reportAnimationFinished()` is
        // idempotent, making this safe for both the normal and cancelled paths.
        defer {
            reportAnimationFinished()
        }
        guard whaleProgress == 0 else { return }

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.22)) {
                whaleProgress = 1
                sprayProgress = 0.55
            }
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            return
        }

        withAnimation(.spring(response: 0.72, dampingFraction: 0.72)) {
            whaleProgress = 1
        }
        withAnimation(.easeInOut(duration: 0.38).repeatForever(autoreverses: true).delay(0.2)) {
            tailIsWagging = true
        }

        try? await Task.sleep(for: .milliseconds(360))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.48)) {
            sprayProgress = 1
        }

        try? await Task.sleep(for: .milliseconds(240))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.8)) {
            dropletProgress = 1
            rippleProgress = 1
        }

        try? await Task.sleep(for: .milliseconds(1060))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.24)) {
            sprayProgress = 0.42
        }
    }

    @MainActor
    private func reportAnimationFinished() {
        guard !hasReportedAnimationFinish else { return }
        hasReportedAnimationFinish = true
        onAnimationFinished()
    }
}

private struct SplashWhale: View {
    let size: CGFloat
    let progress: CGFloat
    let tailIsWagging: Bool

    private var whaleBlue: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x1CB0F6), Color(hex: 0x0A65A4)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            SplashWhaleTailShape()
                .fill(whaleBlue)
                .frame(width: size * 0.31, height: size * 0.31)
                .rotationEffect(.degrees(tailIsWagging ? 11 : -4), anchor: .leading)
                .offset(x: size * 0.39, y: -size * 0.02)

            SplashWhaleBodyShape()
                .fill(whaleBlue)
                .frame(width: size, height: size * 0.55)

            Ellipse()
                .fill(.white.opacity(0.2))
                .frame(width: size * 0.46, height: size * 0.14)
                .rotationEffect(.degrees(-8))
                .offset(x: -size * 0.08, y: size * 0.13)

            SplashWhaleFlipperShape()
                .fill(Color(hex: 0x07598F))
                .frame(width: size * 0.22, height: size * 0.2)
                .rotationEffect(.degrees(18))
                .offset(x: -size * 0.03, y: size * 0.24)

            Circle()
                .fill(.white)
                .frame(width: size * 0.075, height: size * 0.075)
                .offset(x: -size * 0.29, y: -size * 0.075)
            Circle()
                .fill(Color(hex: 0x063E74))
                .frame(width: size * 0.03, height: size * 0.03)
                .offset(x: -size * 0.285, y: -size * 0.07)

            SplashWhaleSmileShape()
                .stroke(.white.opacity(0.72), style: StrokeStyle(lineWidth: max(1.5, size * 0.009), lineCap: .round))
                .frame(width: size * 0.2, height: size * 0.075)
                .offset(x: -size * 0.25, y: size * 0.07)

            Capsule()
                .fill(Color(hex: 0x063E74))
                .frame(width: size * 0.06, height: size * 0.014)
                .rotationEffect(.degrees(-7))
                .offset(x: -size * 0.08, y: -size * 0.255)
        }
        .frame(width: size, height: size * 0.64)
        .scaleEffect(0.78 + 0.22 * progress)
        .opacity(Double(progress))
        .offset(y: (1 - progress) * 34)
        .shadow(color: Color(hex: 0x063E74).opacity(0.22), radius: 12, x: 0, y: 9)
    }
}

private struct SplashWaterSpout: View {
    let progress: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            SplashWaterJetShape()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.82), Color(hex: 0x77DAFF)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 58, height: 152)

            Capsule()
                .fill(Color(hex: 0x8DE5FF).opacity(0.88))
                .frame(width: 16, height: 94)
                .rotationEffect(.degrees(-19), anchor: .bottom)
                .offset(x: -37, y: 18)

            Capsule()
                .fill(Color(hex: 0x8DE5FF).opacity(0.82))
                .frame(width: 14, height: 82)
                .rotationEffect(.degrees(20), anchor: .bottom)
                .offset(x: 37, y: 27)
        }
        .scaleEffect(x: 0.72 + progress * 0.28, y: max(0.01, progress), anchor: .bottom)
        .opacity(Double(progress))
    }
}

private struct SplashDroplets: View {
    let progress: CGFloat
    let scale: CGFloat

    var body: some View {
        ZStack {
            SplashDroplet(progress: progress, delay: 0, direction: -1, rise: 82 * scale)
            SplashDroplet(progress: progress, delay: 0.13, direction: 0.35, rise: 105 * scale)
            SplashDroplet(progress: progress, delay: 0.24, direction: 1, rise: 72 * scale)
        }
    }
}

private struct SplashDroplet: View {
    let progress: CGFloat
    let delay: CGFloat
    let direction: CGFloat
    let rise: CGFloat

    private var localProgress: CGFloat {
        min(max((progress - delay) / max(0.01, 1 - delay), 0), 1)
    }

    private var visibility: CGFloat {
        if localProgress < 0.1 { return localProgress / 0.1 }
        if localProgress > 0.9 { return (1 - localProgress) / 0.1 }
        return 1
    }

    var body: some View {
        let p = localProgress
        let x = direction * (18 + 44 * p)
        let y = -rise * sin(p * .pi) + 56 * p * p

        SplashWaterDropShape()
            .fill(Color(hex: 0xC2F1FF))
            .frame(width: 13, height: 19)
            .rotationEffect(.degrees(Double(direction * 9)))
            .offset(x: x, y: y)
            .opacity(Double(max(0, visibility)))
    }
}

private struct SplashOcean: View {
    let progress: CGFloat

    var body: some View {
        ZStack {
            SplashRippleRing(progress: progress, delay: 0)
            SplashRippleRing(progress: progress, delay: 0.16)
            SplashRippleRing(progress: progress, delay: 0.32)

            Capsule()
                .fill(.white.opacity(0.16))
                .frame(width: 210, height: 20)
                .offset(y: 20)
            Capsule()
                .fill(Color(hex: 0xA7EFFF).opacity(0.36))
                .frame(width: 122, height: 12)
                .offset(y: 5)
        }
    }
}

private struct SplashRippleRing: View {
    let progress: CGFloat
    let delay: CGFloat

    private var localProgress: CGFloat {
        min(max((progress - delay) / max(0.01, 1 - delay), 0), 1)
    }

    var body: some View {
        let p = localProgress
        Ellipse()
            .stroke(.white.opacity(Double((1 - p) * 0.45)), lineWidth: 2)
            .frame(width: 56 + p * 158, height: 12 + p * 30)
            .offset(y: 10 + p * 8)
    }
}

private struct SplashBubble: View {
    let size: CGFloat
    let progress: CGFloat

    var body: some View {
        Circle()
            .stroke(.white.opacity(0.42), lineWidth: 1.5)
            .frame(width: size, height: size)
            .scaleEffect(0.65 + progress * 0.35)
            .opacity(Double(progress))
            .offset(y: (1 - progress) * 16)
    }
}

private struct SplashWhaleBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()

        path.move(to: CGPoint(x: width * 0.05, y: height * 0.53))
        path.addCurve(
            to: CGPoint(x: width * 0.31, y: height * 0.11),
            control1: CGPoint(x: width * 0.05, y: height * 0.24),
            control2: CGPoint(x: width * 0.16, y: height * 0.07)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.77, y: height * 0.15),
            control1: CGPoint(x: width * 0.46, y: height * 0.02),
            control2: CGPoint(x: width * 0.68, y: height * 0.05)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.94, y: height * 0.46),
            control1: CGPoint(x: width * 0.9, y: height * 0.18),
            control2: CGPoint(x: width * 0.96, y: height * 0.34)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.75, y: height * 0.76),
            control1: CGPoint(x: width * 0.94, y: height * 0.63),
            control2: CGPoint(x: width * 0.84, y: height * 0.75)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.36, y: height * 0.92),
            control1: CGPoint(x: width * 0.61, y: height * 0.93),
            control2: CGPoint(x: width * 0.48, y: height * 0.96)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.05, y: height * 0.64),
            control1: CGPoint(x: width * 0.17, y: height * 0.9),
            control2: CGPoint(x: width * 0.06, y: height * 0.77)
        )
        path.closeSubpath()
        return path
    }
}

private struct SplashWhaleTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()

        path.move(to: CGPoint(x: width * 0.02, y: height * 0.5))
        path.addCurve(
            to: CGPoint(x: width * 0.6, y: height * 0.06),
            control1: CGPoint(x: width * 0.23, y: height * 0.24),
            control2: CGPoint(x: width * 0.38, y: height * 0.02)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.98, y: height * 0.1),
            control1: CGPoint(x: width * 0.76, y: height * 0.04),
            control2: CGPoint(x: width * 0.91, y: height * 0.02)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.57, y: height * 0.5),
            control1: CGPoint(x: width * 0.9, y: height * 0.34),
            control2: CGPoint(x: width * 0.73, y: height * 0.48)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.98, y: height * 0.9),
            control1: CGPoint(x: width * 0.74, y: height * 0.52),
            control2: CGPoint(x: width * 0.9, y: height * 0.67)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.6, y: height * 0.94),
            control1: CGPoint(x: width * 0.91, y: height * 0.98),
            control2: CGPoint(x: width * 0.76, y: height * 0.96)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.02, y: height * 0.5),
            control1: CGPoint(x: width * 0.37, y: height * 0.98),
            control2: CGPoint(x: width * 0.22, y: height * 0.76)
        )
        path.closeSubpath()
        return path
    }
}

private struct SplashWhaleFlipperShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.05, y: rect.height * 0.05))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.94, y: rect.height * 0.9),
            control1: CGPoint(x: rect.width * 0.62, y: rect.height * 0.1),
            control2: CGPoint(x: rect.width * 1.02, y: rect.height * 0.48)
        )
        path.addCurve(
            to: CGPoint(x: rect.width * 0.15, y: rect.height * 0.42),
            control1: CGPoint(x: rect.width * 0.5, y: rect.height * 0.88),
            control2: CGPoint(x: rect.width * 0.17, y: rect.height * 0.71)
        )
        path.closeSubpath()
        return path
    }
}

private struct SplashWhaleSmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.22))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * 0.22),
            control: CGPoint(x: rect.midX, y: rect.height * 0.95)
        )
        return path
    }
}

private struct SplashWaterJetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()

        path.move(to: CGPoint(x: width * 0.27, y: height))
        path.addCurve(
            to: CGPoint(x: width * 0.38, y: height * 0.14),
            control1: CGPoint(x: width * 0.22, y: height * 0.66),
            control2: CGPoint(x: width * 0.2, y: height * 0.31)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.64, y: height * 0.1),
            control1: CGPoint(x: width * 0.46, y: height * 0.02),
            control2: CGPoint(x: width * 0.57, y: height * 0.02)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.78, y: height),
            control1: CGPoint(x: width * 0.82, y: height * 0.28),
            control2: CGPoint(x: width * 0.83, y: height * 0.67)
        )
        path.closeSubpath()
        return path
    }
}

private struct SplashWaterDropShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * 0.64),
            control1: CGPoint(x: rect.maxX, y: rect.height * 0.35),
            control2: CGPoint(x: rect.maxX, y: rect.height * 0.5)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.height * 0.88),
            control2: CGPoint(x: rect.width * 0.72, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.height * 0.64),
            control1: CGPoint(x: rect.width * 0.28, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.height * 0.88)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.height * 0.5),
            control2: CGPoint(x: rect.minX, y: rect.height * 0.35)
        )
        path.closeSubpath()
        return path
    }
}
