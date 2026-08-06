import Foundation

/// Practice-bank server settings, persisted like QuizSettings.
enum BankSettings {
    static let serverURLKey = "quiz.bankServerURL"
    /// Simulator shares the Mac's loopback, where the web server runs by
    /// default. Device users edit the address in 我的.
    static let defaultServerURL = "http://127.0.0.1:3000"

    static func loadServerURL(from defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: serverURLKey) ?? defaultServerURL
    }

    static func saveServerURL(_ url: String, to defaults: UserDefaults = .standard) {
        defaults.set(url, forKey: serverURLKey)
    }

    /// Trim trailing "/", require an http(s) scheme → base URL, else nil.
    static func baseURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Strip only the trailing slash — a path without a leading "/" makes
        // URLComponents produce nil.
        if let path = components?.path, path.hasSuffix("/") {
            components?.path = String(path.dropLast())
        }
        return components?.url
    }
}
