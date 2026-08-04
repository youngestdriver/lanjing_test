import Foundation

/// Faithful port of server.js proxy logic: browser header spoofing, cookie jar,
/// session-expiry detection and every upstream flow (login → exam list → enter →
/// questions → answer → mark → submit).
@MainActor
final class APIClient: NSObject, URLSessionDelegate {
    nonisolated static let baseURL = URL(string: "https://test.lanjingweike.com")!
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0"

    let cookieStore: CookieStore
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = cookieStore.storage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()
    private var redirectTargets: [URL] = []

    init(cookieStore: CookieStore = CookieStore()) {
        self.cookieStore = cookieStore
        super.init()
    }

    var hasSession: Bool { cookieStore.hasSession }

    // MARK: - Core request (port of proxyRequest)

    struct RawResponse {
        let status: Int
        let text: String
    }

    func request(
        _ path: String,
        method: String = "GET",
        form: [String: String]? = nil,
        referer: String? = nil,
        detectExpiry: Bool = true
    ) async throws -> RawResponse {
        guard let url = URL(string: path, relativeTo: Self.baseURL) else {
            throw APIError.invalidResponse
        }
        var headers = [
            "User-Agent": Self.userAgent,
            "X-Requested-With": "XMLHttpRequest",
            "Origin": Self.baseURL.absoluteString,
            "Referer": referer ?? Self.baseURL.absoluteString + "/exam",
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "sec-ch-ua": "\"Microsoft Edge\";v=\"149\", \"Chromium\";v=\"149\", \"Not)A;Brand\";v=\"24\"",
            "sec-ch-ua-mobile": "?0",
            "sec-ch-ua-platform": "\"Windows\"",
        ]
        if form != nil {
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.allHTTPHeaderFields = headers
        if let form {
            urlRequest.httpBody = Data(Self.formEncode(form).utf8)
        }

        redirectTargets = []
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""

        if detectExpiry, Self.detectSessionExpiry(status: status, text: text, redirectTargets: redirectTargets) {
            cookieStore.clear()
            throw APIError.sessionExpired
        }
        return RawResponse(status: status, text: text)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirectTargets.append(request.url ?? response.url ?? Self.baseURL)
        completionHandler(request)
    }

    /// Port of the proxyRequest session-expiry block (server.js:53-64).
    nonisolated static func detectSessionExpiry(status: Int, text: String, redirectTargets: [URL]) -> Bool {
        // Rule 1: redirect to the login page
        if redirectTargets.contains(where: { $0.path.contains("/login/account/login") }) {
            return true
        }
        // Rule 2: login-page HTML served as the body
        if text.contains("/login/account/login"),
           text.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil {
            return true
        }
        // Rule 3: "onlineStatus": 0 (quoted or not)
        let pattern = "\"onlineStatus\"\\s*:\\s*\"?0\"?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let data = text.data(using: .utf8) else { throw APIError.invalidResponse }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Port of URLSearchParams.toString() for the ASCII form values actually sent.
    nonisolated static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encode: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        return form.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&")
    }

    /// Port of the login form in server.js:139-144.
    nonisolated static func loginForm(phone: String, password: String) -> [String: String] {
        let normalizedPhone = normalizePhone(phone)
        return [
            "userName": normalizedPhone + "@1",
            "userNameInput": normalizedPhone,
            "password": Hashing.sha256Hex(password),
            "passwordMD5": Hashing.md5Hex(password),
            "companyId": "1",
            "newCompanyId": "1",
            "remember": "false",
            "phoneAccount": "",
            "authCode": "",
            "captchaText": "",
            "nextUrl": "",
        ]
    }

    /// Phone numbers copied from Contacts or formatted by the keyboard can
    /// contain grouping spaces (including non-breaking spaces). The upstream
    /// login endpoint expects only the actual phone-number characters.
    nonisolated static func normalizePhone(_ phone: String) -> String {
        String(phone.filter { !$0.isWhitespace })
    }

    // MARK: - Endpoints

    func login(phone: String, password: String) async throws {
        // Warm up JSESSIONID (server.js:127-136) — login page must not trigger expiry detection
        if !cookieStore.hasJSESSIONID {
            _ = try await request("/login/account/login/1", method: "GET", detectExpiry: false)
        }
        let response = try await request("/login/account/login", method: "POST", form: Self.loginForm(phone: phone, password: password))
        let login = try decode(LoginResponse.self, from: response.text)
        guard login.success else {
            throw APIError.upstream(login.desc ?? "登录失败")
        }
        cookieStore.persist()
    }

    func examList() async throws -> ExamListData {
        let form = [
            "examStyle": "0", "timeSort": "", "status": "", "setProcess": "-1",
            "page": "1", "firstVisit": "true", "name": "", "rowCount": "100", "participation": "",
        ]
        let response = try await request("/exam/current_exam_list", method: "POST", form: form)
        let list = try decode(ExamListResponse.self, from: response.text)
        guard list.success else { throw APIError.upstream(list.desc ?? "获取考试列表失败") }
        guard let bizContent = list.bizContent else { throw APIError.invalidResponse }
        let styleMap = Dictionary(uniqueKeysWithValues: bizContent.styles.map { ($0.id.value, $0.name) })
        let exams = bizContent.examInfoModelList.map { dto in
            Exam(dto: dto, styleName: styleMap[dto.examStyle?.value ?? ""] ?? (dto.examStyleName ?? "unknown"))
        }
        return ExamListData(total: bizContent.total ?? 0, styles: styleMap, exams: exams)
    }

    func enterExam(_ exam: Exam) async throws -> ExamSession {
        let examInfoId = String(exam.id)
        let html: String
        if exam.isNew {
            // Step 0: enter_exam, follow redirects (server.js:402-410)
            _ = try await request("/exam/enter_exam/1/\(examInfoId)", method: "GET")
            let referer = Self.baseURL.absoluteString + "/exam/before_answer_notice/\(examInfoId)"
            // Step 1: faceCheckCondition
            _ = try await request("/exam/faceCheckCondition", method: "POST", form: ["examInfoId": examInfoId], referer: referer)
            // Step 2: start_exam_queue
            let queueResponse = try await request("/exam/start_exam_queue", method: "POST", form: ["examId": examInfoId], referer: referer)
            let queue = try? decode(QueueResponse.self, from: queueResponse.text)
            let queueOk = queue?.bizContent?.isOk == true || queue?.code?.value == "60011"
            // Step 3: poll check_queue_status if needed (≤30 × 2s)
            if !queueOk {
                for _ in 0..<30 {
                    let poll = try await request("/exam/check_queue_status", method: "POST", form: ["examId": examInfoId], referer: referer)
                    let status = try? decode(QueueResponse.self, from: poll.text)
                    if status?.bizContent?.isOk == true { break }
                    try await Task.sleep(for: .seconds(2))
                }
            }
            // Step 4: poll test_complete until ready (body is bare JSON true)
            for _ in 0..<30 {
                let complete = try await request("/exam/test_complete", method: "POST", form: ["examId": examInfoId], referer: referer)
                if complete.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" { break }
                try await Task.sleep(for: .seconds(2))
            }
            // Step 5: GET exam_start
            let start = try await request("/exam/exam_start/\(examInfoId)", method: "GET", referer: referer)
            html = start.text
        } else {
            let start = try await request("/exam/exam_start/\(examInfoId)", method: "GET")
            html = start.text
        }

        let parsed = ExamHTMLParser.parse(html, fallbackExamInfoId: examInfoId)
        guard let examResultsId = parsed.examResultsId, !parsed.questionStates.isEmpty else {
            throw APIError.upstream("进入考试失败")
        }
        return ExamSession(
            examInfoId: parsed.examInfoId,
            examResultsId: examResultsId,
            uuid: parsed.uuid,
            questionStates: parsed.questionStates,
            sectionMap: parsed.sectionMap,
            sectionOrder: parsed.sectionOrder
        )
    }

    /// Port of fetchAllQuestions: batches of 50, uuids repeated per batch.
    func fetchQuestions(_ session: ExamSession) async throws -> [Question] {
        var all: [Question] = []
        let testIds = session.testIds
        let uuid = session.uuid
        for batchStart in stride(from: 0, to: testIds.count, by: 50) {
            let batch = Array(testIds[batchStart..<min(batchStart + 50, testIds.count)])
            let uuids = Array(repeating: uuid ?? "null", count: batch.count).joined(separator: ",")
            let form = [
                "examResultsId": session.examResultsId,
                "examInfoId": session.examInfoId,
                "testIds": batch.joined(separator: ","),
                "uuids": uuids,
            ]
            let response = try await request("/exam/get_question_info/", method: "POST", form: form)
            guard let dtos = try? decode([QuestionDTO].self, from: response.text) else {
                throw APIError.invalidResponse
            }
            all.append(contentsOf: dtos.map(Question.init(dto:)))
        }
        return all
    }

    /// Port of POST /api/exams/:id/answer → /exam/exam_start_ing_multi.
    func submitAnswer(session: ExamSession, testId: String, testAns: String, correct: Bool) async throws {
        let item: [String: Any] = [
            "exam_results_id": session.examResultsId,
            "test_id": testId,
            "test_ans": testAns,
            "exam_info_id": session.examInfoId,
            "correct": correct,
        ]
        let json = try JSONSerialization.data(withJSONObject: [item])
        let form = [
            "examTestList": String(data: json, encoding: .utf8) ?? "[]",
            "timeStamp": String(Int(Date().timeIntervalSince1970 * 1000)),
        ]
        _ = try await request("/exam/exam_start_ing_multi", method: "POST", form: form, referer: examReferer(session.examInfoId))
    }

    func toggleMark(session: ExamSession, testId: String, isMark: Bool) async throws {
        let form = [
            "test_id": testId,
            "exam_results_id": session.examResultsId,
            "exam_info_id": session.examInfoId,
            "isMark": isMark ? "1" : "0",
            "timeStamp": String(Int(Date().timeIntervalSince1970 * 1000)),
        ]
        _ = try await request("/exam/exam_question_mark", method: "POST", form: form, referer: examReferer(session.examInfoId))
    }

    /// Port of POST /api/exams/:id/submit: lightweight enter if no cached session,
    /// get_remian_time, then exam_ending (followed) + result-page parsing.
    func submitExam(examInfoId: String, session: ExamSession?) async throws -> ExamResult {
        var resultsId: String
        var infoId = examInfoId
        if let session {
            resultsId = session.examResultsId
            infoId = session.examInfoId
        } else {
            let start = try await request("/exam/exam_start/\(examInfoId)", method: "GET")
            let parsed = ExamHTMLParser.parse(start.text, fallbackExamInfoId: examInfoId)
            guard let rid = parsed.examResultsId else { throw APIError.cannotFindResultsId }
            resultsId = rid
            infoId = parsed.examInfoId
        }
        // Step 1: remaining time (upstream typo kept for parity)
        _ = try await request("/exam/get_remian_time", method: "POST", form: ["examResultId": resultsId])
        // Step 2: end exam — redirects to the result page
        let path = "/exam/exam_ending?examInfoId=\(infoId)&examResultsId=\(resultsId)&isForce=0&switchScreen=0&noOpsAutoCommit=0"
        let end = try await request(path, method: "GET", referer: examReferer(examInfoId))
        // A non-result response (such as the still-active exam page) must not be
        // interpreted as a completed submission with the parser's fallback values.
        guard end.text.range(of: "class=\"score\"", options: .caseInsensitive) != nil else {
            throw APIError.upstream("考试未能结束，请刷新后重试")
        }
        return ResultPageParser.parse(end.text)
    }

    func clearSession() {
        cookieStore.clear()
    }

    private func examReferer(_ examInfoId: String) -> String {
        Self.baseURL.absoluteString + "/exam/exam_start/" + examInfoId
    }
}
