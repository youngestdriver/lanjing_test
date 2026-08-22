import SwiftUI

struct LoginView: View {
    @Environment(AppState.self) private var appState
    @State private var vm: LoginViewModel?
    @State private var screen: LoginScreen = .landing
    @State private var isPasswordVisible = false
    @State private var agreedToTerms = true
    @State private var isInfoPresented = false
    @State private var infoTitle = ""
    @State private var infoMessage = ""
    @FocusState private var focusedField: LoginField?

    private let loginBlue = Color(hex: 0x4169F5)

    private enum LoginScreen: Hashable {
        case landing
        case password
    }

    private enum LoginField: Hashable {
        case phone
        case password
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            switch screen {
            case .landing:
                landingPage
                    .transition(.opacity)
            case .password:
                passwordPage
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.24), value: screen)
        .task {
            if vm == nil {
                vm = LoginViewModel(appState: appState)
            }
            await vm?.retryCloudSyncIfNeeded()
        }
        .task(id: screen) {
            guard screen == .password else { return }
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, screen == .password else { return }
            focusedField = .phone
        }
        .onChange(of: screen) { _, newScreen in
            if newScreen == .landing {
                focusedField = nil
                isPasswordVisible = false
            }
        }
        .alert(infoTitle, isPresented: $isInfoPresented) {
            Button(appState.theme == .light ? "切换深色模式" : "切换浅色模式") {
                appState.toggleTheme()
            }
            Button("知道了", role: .cancel) {}
        } message: {
            Text(infoMessage)
        }
    }

    private var landingPage: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                topBar(showBackButton: false)

                Spacer(minLength: 62)

                VStack(spacing: 18) {
                    // 登录页展示应用图标(与主屏幕图标同款)。AppIcon 编译产物
                    // 不能按名加载(UIImage(named: "AppIcon") 为 nil),故引用
                    // AppIconLogo.imageset 的同副本——替换 AppIcon 时需同步。
                    // 底图无透明圆角,按 iOS 图标圆角比例(~22.4%)裁出圆角。
                    Image("AppIconLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 132, height: 132)
                        .clipShape(RoundedRectangle(cornerRadius: 30))
                        .accessibilityHidden(true)

                    Text("蓝鲸助手")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(loginBlue)
                }

                Spacer(minLength: 118)

                Button {
                    guard agreedToTerms else {
                        presentInfo(
                            title: "请先同意协议",
                            message: "登录前请阅读并同意用户协议与隐私政策。"
                        )
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.24)) {
                        screen = .password
                    }
                } label: {
                    Label("密码登录", systemImage: "lock.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                }
                .buttonStyle(LoginPillButtonStyle(color: loginBlue))
                .accessibilityIdentifier("password-login-entry")

                agreementRow
                    .padding(.top, 30)
                    .padding(.bottom, 14)
            }
            .padding(.horizontal, 32)
            .frame(minHeight: proxy.size.height)
            .frame(width: proxy.size.width)
        }
    }

    private var passwordPage: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    topBar(showBackButton: true)

                    Text("密码登录")
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 58)

                    if let vm {
                        passwordFields(vm)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 72)
                    }

                    Spacer(minLength: 150)
                }
                .frame(minHeight: max(0, proxy.size.height - 74))
                .padding(.horizontal, 32)
                .padding(.bottom, 22)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let vm {
                    loginButton(vm)
                        .padding(.horizontal, 32)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                        .background(Color(.systemBackground))
                }
            }
        }
    }

    @ViewBuilder
    private func topBar(showBackButton: Bool) -> some View {
        HStack {
            if showBackButton {
                Button {
                    withAnimation(.easeInOut(duration: 0.24)) {
                        screen = .landing
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 50, height: 50)
                        .background(Color(.systemBackground), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(Color(.separator).opacity(0.7), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
            } else {
                Color.clear
                    .frame(width: 50, height: 50)
            }

            Spacer()

            if showBackButton {
                Button("帮助") {
                    presentInfo(
                        title: "登录帮助",
                        message: "请输入注册手机号和密码。如果忘记密码，请联系管理员重置。"
                    )
                }
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            } else {
                Button("跳过") {
                    appState.skipLogin()
                }
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .accessibilityIdentifier("skip-login")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func passwordFields(_ vm: LoginViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("+86")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)

                Rectangle()
                    .fill(Color(.separator).opacity(0.7))
                    .frame(width: 1, height: 24)

                TextField(
                    "手机号",
                    text: Binding(get: { vm.phone }, set: { vm.phone = $0 })
                )
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused($focusedField, equals: .phone)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .background(Color(.secondarySystemBackground), in: Capsule())

            HStack(spacing: 12) {
                Group {
                    if isPasswordVisible {
                        TextField(
                            "密码",
                            text: Binding(get: { vm.password }, set: { vm.password = $0 })
                        )
                    } else {
                        SecureField(
                            "密码",
                            text: Binding(get: { vm.password }, set: { vm.password = $0 })
                        )
                    }
                }
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .submitLabel(.done)
                .onSubmit { submit(vm) }

                Button {
                    isPasswordVisible.toggle()
                } label: {
                    Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPasswordVisible ? "隐藏密码" : "显示密码")
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .background(Color(.secondarySystemBackground), in: Capsule())

            Button("忘记密码") {
                presentInfo(
                    title: "忘记密码",
                    message: "请联系管理员重置密码。"
                )
            }
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(loginBlue)
            .buttonStyle(.plain)
            .padding(.top, 3)

            if let errorMessage = vm.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 70)
    }

    private func loginButton(_ vm: LoginViewModel) -> some View {
        Button {
            submit(vm)
        } label: {
            Group {
                if vm.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("登录")
                }
            }
            .font(.system(size: 20, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 58)
        }
        .buttonStyle(LoginPillButtonStyle(color: loginBlue))
        .disabled(vm.isLoading)
        .accessibilityIdentifier("password-login-submit")
    }

    private var agreementRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                agreedToTerms.toggle()
            } label: {
                Image(systemName: agreedToTerms ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(agreedToTerms ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(agreedToTerms ? "已同意用户协议和隐私政策" : "未同意用户协议和隐私政策")

            Text("我已阅读并同意")
                .foregroundStyle(.secondary)

            Button("用户协议") {
                presentInfo(title: "用户协议", message: "蓝鲸助手用户协议将在后续版本中提供。")
            }
            .foregroundStyle(.primary)
            .buttonStyle(.plain)

            Text("与")
                .foregroundStyle(.secondary)

            Button("隐私政策") {
                presentInfo(title: "隐私政策", message: "蓝鲸助手隐私政策将在后续版本中提供。")
            }
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
        }
        .font(.system(size: 15, weight: .regular))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func submit(_ vm: LoginViewModel) {
        guard agreedToTerms else {
            presentInfo(
                title: "请先同意协议",
                message: "登录前请阅读并同意用户协议与隐私政策。"
            )
            return
        }

        focusedField = nil
        Task {
            await vm.login()
        }
    }

    private func presentInfo(title: String, message: String) {
        infoTitle = title
        infoMessage = message
        isInfoPresented = true
    }
}

private struct LoginPillButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(color.opacity(configuration.isPressed ? 0.82 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
