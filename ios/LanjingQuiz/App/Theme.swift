import SwiftUI

/// Persisted with the same single "theme" key as the web app (localStorage).
enum Theme: String, CaseIterable {
    case light, dark

    static let storageKey = "theme"

    static func load() -> Theme {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return .light }
        return Theme(rawValue: raw) ?? .light
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Theme.storageKey)
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    var toggleLabel: String { self == .light ? "🌙" : "☀️" }
}
