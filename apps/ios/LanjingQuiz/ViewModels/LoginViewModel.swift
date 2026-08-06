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

    /// Called when the login screen appears: the launch-time pull is bounded
    /// by a timeout, so a cloud session that syncs in shortly after launch
    /// would otherwise leave the user stuck on the login screen. Retry once;
    /// don't interrupt the user if they already started typing.
    func retryCloudSyncIfNeeded() async {
        guard phone.isEmpty, password.isEmpty else { return }
        let hasSession = await appState.cookieCloudSync.pullAndApplyIfNeeded()
        if hasSession { appState.route = .examList }
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
            await appState.finishLogin()
        } catch {
            appState.handle(error)
            if let apiError = error as? APIError,
               apiError != .sessionExpired, apiError != .notLoggedIn {
                errorMessage = apiError.message
            }
        }
    }
}
