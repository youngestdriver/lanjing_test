import Foundation

/// Persisted CookieCloud configuration. Non-secret fields live in
/// UserDefaults (mirroring apps/web/.local/settings.json); the password is
/// stored in the Keychain (mirroring how the web server keeps it in a 0600
/// file next to the session).
enum CookieCloudSettings {
    static let configKey = "quiz.cookieCloud"
    static let lastPushedHashKey = "quiz.cookieCloud.lastPushedHash"
    static let passwordKeychainAccount = "cookiecloud.password"

    struct Config: Codable, Equatable {
        var enabled: Bool
        var server: String
        var uuid: String

        static let empty = Config(enabled: false, server: "", uuid: "")
    }

    static func loadConfig(from defaults: UserDefaults = .standard) -> Config {
        guard let data = defaults.data(forKey: configKey),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return .empty }
        return config
    }

    static func saveConfig(_ config: Config, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: configKey)
    }

    static func loadPassword() -> String? {
        guard let data = KeychainHelper.load(account: passwordKeychainAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func savePassword(_ password: String) {
        try? KeychainHelper.save(Data(password.utf8), account: passwordKeychainAccount)
    }

    static func loadLastPushedHash(from defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: lastPushedHashKey)
    }

    static func saveLastPushedHash(_ hash: String, to defaults: UserDefaults = .standard) {
        defaults.set(hash, forKey: lastPushedHashKey)
    }
}

/// CookieCloud cookie_data <-> [HTTPCookie] conversions and domain merging,
/// mirroring apps/web/lib/cookiecloud.js. Pure static helpers so tests can
/// exercise them without network or Keychain.
enum CookieCloudConversion {
    static let lanjingDomainMarker = "lanjingweike.com"

    /// Cookies excluded from sync entirely. KSX_CID is set to "1" by the
    /// upstream on every response, and restoring it into a browser breaks
    /// the original web client; the upstream re-issues it anyway, so
    /// dropping it from synced data is safe.
    static let excludedCookieNames = Set(["KSX_CID"])

    /// [HTTPCookie] -> { domain: [cookie dictionaries] } for upload. Cookies
    /// are grouped by their real domain so the extension's per-domain format
    /// is preserved.
    static func cookieData(from cookies: [HTTPCookie]) -> [String: [[String: Any]]] {
        var grouped: [String: [[String: Any]]] = [:]
        for cookie in cookies where !excludedCookieNames.contains(cookie.name) {
            var properties: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path,
                "secure": cookie.isSecure,
                "httpOnly": cookie.isHTTPOnly,
            ]
            if let expires = cookie.expiresDate {
                properties["expirationDate"] = expires.timeIntervalSince1970
            }
            if cookie.isSessionOnly {
                properties["session"] = true
            }
            if let policy = cookie.sameSitePolicy {
                switch policy {
                case .sameSiteLax: properties["sameSite"] = "lax"
                case .sameSiteStrict: properties["sameSite"] = "strict"
                default: break // no "none" constant on this SDK
                }
            }
            grouped[cookie.domain, default: []].append(properties)
        }
        return grouped
    }

    /// CookieCloud cookie_data -> [HTTPCookie]. Only lanjingweike cookies are
    /// imported; everything else (from an extension upload) is ignored.
    /// `sameSite` has no HTTPCookiePropertyKey and is silently dropped.
    static func cookies(from cookieData: [String: Any]) -> [HTTPCookie] {
        var result: [HTTPCookie] = []
        for (domain, cookies) in cookieData {
            guard domain.contains(lanjingDomainMarker), let cookies = cookies as? [[String: Any]] else { continue }
            for cookie in cookies {
                guard let name = cookie["name"] as? String, !name.isEmpty,
                      !excludedCookieNames.contains(name),
                      let value = cookie["value"] as? String
                else { continue }
                // httpOnly and session have no HTTPCookiePropertyKey on this
                // SDK; they are dropped on import (session cookies stay
                // session cookies by default without an expiration date).
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: cookie["domain"] as? String ?? domain,
                    .path: cookie["path"] as? String ?? "/",
                    .secure: cookie["secure"] as? Bool ?? true,
                ]
                if let expiration = cookie["expirationDate"] as? NSNumber {
                    properties[.expires] = Date(timeIntervalSince1970: expiration.doubleValue)
                }
                if let cookie = HTTPCookie(properties: properties) {
                    result.append(cookie)
                }
            }
        }
        return result
    }

    /// Merge our push payload into the remote blob: every non-lanjingweike
    /// domain from the remote is kept, our lanjingweike entries replace the
    /// remote's.
    static func mergeCookieData(remote: [String: Any], ours: [String: Any]) -> [String: Any] {
        var merged: [String: Any] = [:]
        for (domain, cookies) in remote where !domain.contains(lanjingDomainMarker) {
            merged[domain] = cookies
        }
        for (domain, cookies) in ours {
            merged[domain] = cookies
        }
        return merged
    }
}

/// Result of a manual sync, rendered by the settings UI.
struct CookieCloudSyncResult: Equatable {
    var applied = false
    var pushed = false
    var error: String?
}

/// Coordinates pull/push with the CookieCloud server: import a session at
/// launch, publish the local session after login, and support a manual sync
/// button. Storage writes stay on the main actor (CookieStore is @MainActor);
/// network calls suspend.
@MainActor
final class CookieCloudSync {
    private let client: CookieCloudClient
    private let cookieStore: CookieStore
    private let defaults: UserDefaults
    private var lastPushedHash: String?

    init(client: CookieCloudClient = CookieCloudClient(), cookieStore: CookieStore, defaults: UserDefaults = .standard) {
        self.client = client
        self.cookieStore = cookieStore
        self.defaults = defaults
        self.lastPushedHash = CookieCloudSettings.loadLastPushedHash(from: defaults)
    }

    private var config: CookieCloudSettings.Config {
        CookieCloudSettings.loadConfig(from: defaults)
    }

    private var password: String {
        CookieCloudSettings.loadPassword() ?? ""
    }

    var isConfigured: Bool {
        let config = self.config
        return config.enabled && !config.server.isEmpty && !config.uuid.isEmpty && !password.isEmpty
    }

    private var lanjingCookies: [HTTPCookie] {
        cookieStore.storage.cookies?.filter { $0.domain.contains(CookieCloudConversion.lanjingDomainMarker) } ?? []
    }

    /// Deterministic hash of the current lanjingweike jar, used to skip
    /// uploads when nothing changed (mirrors the extension's 24h dedup).
    private var currentJarHash: String {
        let data = CookieCloudConversion.cookieData(from: lanjingCookies)
        let json = (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])) ?? Data()
        return Hashing.sha256Hex(String(data: json, encoding: .utf8) ?? "")
    }

    /// Fetch and decrypt the remote blob; nil when the server has no blob yet.
    private func fetchAndDecrypt() async throws -> [String: Any]? {
        let config = self.config
        guard let blob = try await client.pull(server: config.server, uuid: config.uuid) else { return nil }
        let plaintext = try CookieCloudCrypto.decryptAny(
            blob.encrypted, uuid: config.uuid, password: password, cryptoType: blob.cryptoType
        )
        guard let data = plaintext.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CookieCloudCrypto.Error.invalidPlaintext }
        return payload["cookie_data"] as? [String: Any] ?? [:]
    }

    private func apply(_ cookies: [HTTPCookie]) {
        // setCookies merges; purge stale lanjingweike cookies first so an old
        // sessionId cannot survive an import.
        for cookie in lanjingCookies {
            cookieStore.storage.deleteCookie(cookie)
        }
        // Pass a non-nil URL for both parameters to avoid CFNetwork
        // dereferencing nil on iOS 27 Beta (same as CookieStore.restore()).
        cookieStore.storage.setCookies(cookies, for: APIClient.baseURL, mainDocumentURL: APIClient.baseURL)
        cookieStore.persist()
        updateLastPushedHash()
    }

    private func updateLastPushedHash() {
        let hash = currentJarHash
        lastPushedHash = hash
        CookieCloudSettings.saveLastPushedHash(hash, to: defaults)
    }

    /// Push the local jar, keeping non-lanjingweike domains from the remote
    /// blob so an extension's other-domain cookies survive our writes.
    private func pushUnconditionally() async throws {
        let config = self.config
        let ours = CookieCloudConversion.cookieData(from: lanjingCookies)
        let remote = (try? await fetchAndDecrypt()) ?? [:]
        let merged = CookieCloudConversion.mergeCookieData(remote: remote, ours: ours)
        let payload: [String: Any] = ["cookie_data": merged, "local_storage_data": [:]]
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let plaintext = String(data: json, encoding: .utf8) ?? "{}"
        let encrypted = try CookieCloudCrypto.encrypt(
            plaintext, uuid: config.uuid, password: password, cryptoType: "aes-128-cbc-fixed"
        )
        try await client.push(server: config.server, uuid: config.uuid, encrypted: encrypted, cryptoType: "aes-128-cbc-fixed")
        updateLastPushedHash()
    }

    /// App-launch import: pull and apply a cloud session, bounded by a hard
    /// timeout so an unreachable server never delays the route decision.
    /// Returns whether a session is available after the attempt.
    func pullAndApplyIfNeeded() async -> Bool {
        guard isConfigured else { return cookieStore.hasSession }
        let work = Task { () -> Bool in
            do {
                if let remote = try await fetchAndDecrypt() {
                    let cookies = CookieCloudConversion.cookies(from: remote)
                    if cookies.contains(where: { $0.name == "sessionId" }) {
                        apply(cookies)
                        return true
                    }
                }
                return cookieStore.hasSession
            } catch {
                return cookieStore.hasSession
            }
        }
        return await race(work, timeoutSeconds: 4) ?? cookieStore.hasSession
    }

    /// Publish the local session after login; no-op when the jar hash is
    /// unchanged or sync is not configured. Fire-and-forget.
    func pushIfNeeded() async {
        guard isConfigured, cookieStore.hasSession else { return }
        let hash = currentJarHash
        guard hash != lastPushedHash else { return }
        try? await pushUnconditionally()
    }

    /// Manual sync from the settings screen: import the cloud session, then
    /// push if the local jar diverged from what we last wrote.
    func syncNow() async -> CookieCloudSyncResult {
        var result = CookieCloudSyncResult()
        guard isConfigured else {
            result.error = "CookieCloud 同步未配置"
            return result
        }
        do {
            if let remote = try await fetchAndDecrypt() {
                let cookies = CookieCloudConversion.cookies(from: remote)
                if cookies.contains(where: { $0.name == "sessionId" }) {
                    apply(cookies)
                    result.applied = true
                }
            }
            if cookieStore.hasSession, currentJarHash != lastPushedHash {
                try await pushUnconditionally()
                result.pushed = true
            }
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    /// Races the work against a timeout; returns nil when the timeout wins.
    private func race<T: Sendable>(_ work: Task<T, Never>, timeoutSeconds: Double) async -> T? {
        await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                await work.value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw CancellationError()
            }
            do {
                let first = try await group.next()
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                return nil
            }
        }
    }
}
