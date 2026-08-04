import Foundation
import Observation

@MainActor
@Observable
final class LoginViewModel {
    var phone = ""
    var password = ""
    var errorMessage: String?
    var isLoading = false

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func login() async {
        let normalizedPhone = APIClient.normalizePhone(phone)
        guard !normalizedPhone.isEmpty, !password.isEmpty else {
            errorMessage = "请输入手机号和密码"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await appState.api.login(phone: normalizedPhone, password: password)
            errorMessage = nil
            await appState.start()
        } catch {
            appState.handle(error)
            if let apiError = error as? APIError,
               apiError != .sessionExpired, apiError != .notLoggedIn {
                errorMessage = apiError.message
            }
        }
    }
}
