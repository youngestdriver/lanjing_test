import SwiftUI

/// Persisted with the same single "theme" key as the web app (localStorage).
/// `.system` follows the system appearance (colorScheme == nil).
enum Theme: String, CaseIterable {
    case light, dark, system

    static let storageKey = "theme"
    /// Last manual light/dark choice, restored when the 跟随系统 toggle is
    /// turned off.
    static let manualStorageKey = "theme.manual"

    static func load() -> Theme {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return .light }
        return Theme(rawValue: raw) ?? .light
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Theme.storageKey)
    }

    static func loadManual() -> Theme {
        guard let raw = UserDefaults.standard.string(forKey: manualStorageKey) else { return .light }
        return Theme(rawValue: raw) ?? .light
    }

    static func saveManual(_ theme: Theme) {
        UserDefaults.standard.set(theme.rawValue, forKey: manualStorageKey)
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil // follow the system appearance
        }
    }

    /// Label of the quiz-header quick toggle: it flips to the fixed theme
    /// shown here (system → dark).
    var toggleLabel: String { self == .light ? "🌙" : "☀️" }
}

enum QuizSettings {
    static let autoAdvanceOnCorrectKey = "quiz.autoAdvanceOnCorrect"

    static func loadAutoAdvanceOnCorrect(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoAdvanceOnCorrectKey) as? Bool ?? false
    }

    static func saveAutoAdvanceOnCorrect(
        _ isEnabled: Bool,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(isEnabled, forKey: autoAdvanceOnCorrectKey)
    }
}
