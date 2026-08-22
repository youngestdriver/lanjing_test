import SwiftUI

/// 未登录占位态:练习页与考试列表页共用(登录页「跳过」以未登录状态进入
/// 主界面后,两个 tab 都以同一提示引导登录;「去登录」直接路由回登录页)。
struct NeedsLoginPlaceholder: View {
    @Environment(AppState.self) private var appState
    let description: String

    var body: some View {
        ContentUnavailableView {
            Label("需要登录", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text(description)
        } actions: {
            Button("去登录") {
                appState.route = .login
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
