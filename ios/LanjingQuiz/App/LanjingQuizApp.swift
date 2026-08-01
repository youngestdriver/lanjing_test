import SwiftUI

@main
struct LanjingQuizApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(appState.theme.colorScheme)
        }
    }
}
