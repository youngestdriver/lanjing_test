import Foundation

enum APIError: Error, Equatable {
    /// Upstream session expired — the only error that forces the app back to login.
    case sessionExpired
    /// No sessionId cookie present (apps/web/server.js auth middleware equivalent).
    case notLoggedIn
    /// Upstream business error, carries `data.desc` (e.g. "密码错误").
    case upstream(String)
    /// Cannot extract exam_results_id from the exam page.
    case cannotFindResultsId
    /// Response body could not be decoded.
    case invalidResponse
    /// A question batch from /exam/get_question_info/ could not be decoded —
    /// carries a detailed diagnosis (which batch / which question ids / what
    /// the upstream returned) for the crawl log.
    case invalidBatch(String)
    /// Transport-level failure (URLError etc.).
    case transport(String)

    var message: String {
        switch self {
        case .sessionExpired: "登录已过期，请重新登录"
        case .notLoggedIn: "未登录"
        case .upstream(let desc): desc
        case .cannotFindResultsId: "无法获取考试记录 ID"
        case .invalidResponse: "服务器响应异常"
        case .invalidBatch(let detail): detail
        case .transport(let message): "网络错误：\(message)"
        }
    }
}
