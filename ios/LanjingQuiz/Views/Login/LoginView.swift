import SwiftUI

struct LoginView: View {
    @Environment(AppState.self) private var appState
    @State private var vm: LoginViewModel?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    Spacer()
                    Button(appState.theme.toggleLabel) {
                        appState.toggleTheme()
                    }
                    .font(.system(size: 20))
                }
                Text("🦉")
                    .font(.system(size: 72))
                Text("更智能的蓝鲸微课考试助手")
                    .displayFont(22)
                if let vm {
                    fields(vm)
                } else {
                    ProgressView()
                }
            }
            .padding(24)
        }
        .task { if vm == nil { vm = LoginViewModel(appState: appState) } }
    }

    private func fields(_ vm: LoginViewModel) -> some View {
        VStack(spacing: 16) {
            TextField(
                "手机号",
                text: Binding(get: { vm.phone }, set: { vm.phone = $0 })
            )
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))

            SecureField(
                "密码",
                text: Binding(get: { vm.password }, set: { vm.password = $0 })
            )
            .textContentType(.password)
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))

            if let errorMessage = vm.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(DS.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))
            }

            if vm.isLoading {
                ProgressView()
            } else {
                Button("登录") {
                    Task { await vm.login() }
                }
                .buttonStyle(KeycapButtonStyle(color: DS.accent))
            }
        }
    }
}
