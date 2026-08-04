import Foundation

/// Injectable persistence (tests use an in-memory fake; app uses Keychain).
protocol CookiePersistence {
    func save(_ data: Data) throws
    func load() -> Data?
    func clear()
}

struct KeychainCookiePersistence: CookiePersistence {
    private let account = "cookies"

    func save(_ data: Data) throws {
        try KeychainHelper.save(data, account: account)
    }

    func load() -> Data? {
        KeychainHelper.load(account: account)
    }

    func clear() {
        KeychainHelper.delete(account: account)
    }
}

/// Wraps HTTPCookieStorage.shared with Keychain persistence. This is the Swift equivalent
/// of the in-process cookie jar and apps/web/.local/session_cookies.txt used by apps/web/server.js.
/// URLSession auto-sends and auto-stores cookies, mirroring the Node jar behavior.
@MainActor
final class CookieStore {
    let storage: HTTPCookieStorage
    private let persistence: CookiePersistence

    init(persistence: CookiePersistence = KeychainCookiePersistence()) {
        self.persistence = persistence
        self.storage = .shared
        restore()
    }

    /// Server auth middleware equivalent: cookieJar.includes("sessionId=").
    var hasSession: Bool {
        storage.cookies?.contains { $0.name == "sessionId" } ?? false
    }

    var hasJSESSIONID: Bool {
        storage.cookies?.contains { $0.name == "JSESSIONID" } ?? false
    }

    /// Write cookies to Keychain (called on login success / logout / expiry,
    /// mirroring when apps/web/server.js persists its local session file).
    func persist() {
        guard let cookies = storage.cookies, !cookies.isEmpty else { return }
        let properties = cookies.compactMap { $0.properties }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
        else { return }
        try? persistence.save(data)
    }

    func restore() {
        guard let data = persistence.load(),
              let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]]
        else { return }
        let cookies = list.compactMap { dict in
            let properties = Dictionary(
                uniqueKeysWithValues: dict.map { (HTTPCookiePropertyKey($0.key), $0.value) }
            )
            return HTTPCookie(properties: properties)
        }
        guard !cookies.isEmpty else { return }
        // Pass a non-nil URL for both parameters to avoid CFNetwork dereferencing nil on iOS 27 Beta
        storage.setCookies(cookies, for: APIClient.baseURL, mainDocumentURL: APIClient.baseURL)
    }

    func clear() {
        for cookie in storage.cookies ?? [] {
            storage.deleteCookie(cookie)
        }
        persistence.clear()
    }
}
