import Foundation

/// The encrypted blob a CookieCloud server stores per uuid
/// (api/app.js: data/<uuid>.json).
struct CookieCloudBlob: Sendable {
    let encrypted: String
    let cryptoType: String
}

/// Talks to a self-hosted CookieCloud server. Uses its own ephemeral session
/// so CookieCloud traffic never mixes with the app's lanjingweike cookie jar
/// (ephemeral configurations have no HTTPCookieStorage).
struct CookieCloudClient: Sendable {
    enum Error: Swift.Error, LocalizedError {
        case invalidServerURL
        case uploadRejected
        case downloadFailed(Int)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .invalidServerURL: "cookiecloud: invalid server URL"
            case .uploadRejected: "cookiecloud: upload was not acknowledged"
            case .downloadFailed(let status): "cookiecloud: download failed with status \(status)"
            case .malformedResponse: "cookiecloud: malformed server response"
            }
        }
    }

    private struct UpdateResponse: Decodable {
        let action: String?
    }

    private struct BlobResponse: Decodable {
        let encrypted: String
        let cryptoType: String?
    }

    private let session: URLSession

    init(session: URLSession = CookieCloudClient.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }

    /// POST {server}/update — overwrite the uuid's encrypted blob.
    func push(server: String, uuid: String, encrypted: String, cryptoType: String) async throws {
        guard var url = URL(string: server) else { throw Error.invalidServerURL }
        url.append(path: "update")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["uuid": uuid, "encrypted": encrypted, "crypto_type": cryptoType]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 < 300 else { throw Error.uploadRejected }
        if let json = try? JSONDecoder().decode(UpdateResponse.self, from: data), json.action != "done" {
            throw Error.uploadRejected
        }
    }

    /// GET {server}/get/{uuid}. Returns nil when the blob does not exist yet
    /// (404): callers treat that as an empty cloud, e.g. first-time setup
    /// where the push creates the blob. Other failures throw.
    func pull(server: String, uuid: String) async throws -> CookieCloudBlob? {
        guard var url = URL(string: server) else { throw Error.invalidServerURL }
        url.append(path: "get")
        url.append(path: uuid)
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw Error.downloadFailed(status) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(BlobResponse.self, from: data) else {
            throw Error.malformedResponse
        }
        return CookieCloudBlob(encrypted: decoded.encrypted, cryptoType: decoded.cryptoType ?? "legacy")
    }
}
