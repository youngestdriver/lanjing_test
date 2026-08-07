import Foundation
import Network

/// Minimal in-process HTTP server serving upstream-protocol fixtures so the
/// practice UI test runs hermetically (no LAN bank server, no real upstream).
/// The app is pointed at it via the LANJING_BASE_URL launch environment; every
/// request is recorded for assertions.
///
/// Routes mirror the shapes verified against apps/bank/test fixtures and the
/// iOS DTOs — note the numeric exam ids (ExamDTO.id is Int):
///   GET  /login/account/login/1   → login page + Set-Cookie JSESSIONID
///   POST /login/account/login     → {"code":10000,"success":true} + sessionId
///   POST /exam/current_exam_list  → 2 机考题库 papers + 1 non-target paper
///   POST /exam/enter_exam/1/{id}  → {"success":true}
///   POST /exam/faceCheckCondition / get_remian_time → {"success":true}
///   POST /exam/start_exam_queue   → {"code":"10000","success":true,"bizContent":{"isOk":true}}
///   POST /exam/test_complete      → bare `true`
///   GET  /exam/exam_start/{id}    → exam HTML (var exam_results_id + cards)
///   POST /exam/get_question_info/ → 3 QuestionDTOs (成语/虚词/实词)
///   GET  /exam/exam_ending?…      → {"code":10000,"success":true}
final class MockUpstreamServer: @unchecked Sendable {

    struct Call: Equatable {
        let method: String
        let path: String
    }

    private struct Request {
        let method: String
        let path: String
    }

    private let lock = NSLock()
    private var callsStorage: [Call] = []
    /// Requests seen so far, in order (server queue → test thread safe).
    var calls: [Call] {
        lock.withLock { callsStorage }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "MockUpstreamServer")

    /// Bound loopback port; valid after start() returns.
    private(set) var port: UInt16 = 0

    func start() throws {
        let listener = try NWListener(using: .tcp, on: 0)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        ready.wait()
        guard let port = listener.port else {
            throw NSError(domain: "MockUpstreamServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        self.port = port.rawValue
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let request = Self.parseRequest(buffer) {
                    self.respond(connection, to: request)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receiveMore()
                }
            }
        }
        receiveMore()
    }

    /// Parse "METHOD PATH HTTP/1.1\r\n…headers…\r\n\r\n[body]" once the
    /// Content-Length body is fully buffered; nil while incomplete.
    private static func parseRequest(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8))?.lowerBound else { return nil }
        guard let head = String(data: data[..<headerEnd], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])
        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd + 4
        guard data.count >= bodyStart + contentLength else { return nil }
        return Request(method: method, path: path)
    }

    // MARK: - Responding

    private func respond(_ connection: NWConnection, to request: Request) {
        lock.withLock {
            callsStorage.append(Call(method: request.method, path: request.path))
        }
        let (statusLine, extraHeaders, body) = Self.response(for: request)
        var head = "HTTP/1.1 \(statusLine)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += extraHeaders
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func response(for request: Request) -> (String, String, Data) {
        let route = request.path.components(separatedBy: "?")[0]

        switch (request.method, route) {
        case ("GET", "/login/account/login/1"):
            return ("200 OK", "Set-Cookie: JSESSIONID=js1; Path=/\r\n",
                    Data("<html><head><title>login</title></head><body>login page</body></html>".utf8))
        case ("POST", "/login/account/login"):
            return ("200 OK", "Set-Cookie: sessionId=SECRET; Path=/\r\n",
                    Data("{\"code\":10000,\"success\":true}".utf8))
        case ("POST", "/exam/current_exam_list"):
            return ("200 OK", "", Data(examListJSON.utf8))
        case ("POST", "/exam/enter_exam/1/111"), ("POST", "/exam/enter_exam/1/222"):
            return ("200 OK", "", Data("{\"code\":10000,\"success\":true}".utf8))
        case ("POST", "/exam/faceCheckCondition"), ("POST", "/exam/get_remian_time"):
            return ("200 OK", "", Data("{\"code\":10000,\"success\":true}".utf8))
        case ("POST", "/exam/start_exam_queue"):
            return ("200 OK", "", Data("{\"code\":\"10000\",\"success\":true,\"bizContent\":{\"isOk\":true}}".utf8))
        case ("POST", "/exam/test_complete"):
            return ("200 OK", "", Data("true".utf8))
        case ("GET", "/exam/exam_start/111"):
            return ("200 OK", "", Data(examStartHTML(examInfoId: "111").utf8))
        case ("GET", "/exam/exam_start/222"):
            return ("200 OK", "", Data(examStartHTML(examInfoId: "222").utf8))
        case ("POST", "/exam/get_question_info/"):
            return ("200 OK", "", Data(questionBatchJSON.utf8))
        case ("GET", "/exam/exam_ending"):
            return ("200 OK", "", Data("{\"code\":10000,\"success\":true}".utf8))
        default:
            return ("404 Not Found", "", Data("not found".utf8))
        }
    }

    // MARK: - Fixtures

    /// 2 机考题库 papers (111 new-attempt, 222 in-progress read-only) + 1
    /// non-target paper that must be filtered out of the practice list.
    private static let examListJSON = """
    {
      "success": true,
      "bizContent": {
        "total": 3,
        "styles": [
          {"id": "1052372", "name": "机考题库"},
          {"id": "1052373", "name": "中石化模考套餐"}
        ],
        "examInfoModelList": [
          {"id": 111, "examName": "【言语理解（二）】机考题库", "examStyle": "1052372", "wfs": 1, "practiceMode": 2},
          {"id": 222, "examName": "【言语理解（一）】机考题库", "examStyle": "1052372", "wfs": 0, "practiceMode": 2},
          {"id": 333, "examName": "【中国石化模拟卷（四）】", "examStyle": "1052373", "wfs": 1, "practiceMode": 0}
        ]
      }
    }
    """

    /// Answer-card HTML: one section + 3 questions in the section.
    private static func examStartHTML(examInfoId: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head><script>
        var exam_results_id = '87380582';
        var exam_info_id = '\(examInfoId)';
        </script></head>
        <body>
        <div class="exam-content">
          <div class="card-content-title">逻辑填空(共200题,每题1分,合计200.0分)</div>
          <div class="card-content-list">
            <a href="#1"><div class="question_cbox"><span>1</span><span questionsId="q1" uuId="u1"></span></div></a>
            <a href="#2"><div class="question_cbox"><span>2</span><span questionsId="q2" uuId="u2"></span></div></a>
            <a href="#3"><div class="question_cbox"><span>3</span><span questionsId="q3" uuId="u3"></span></div></a>
          </div>
        </div>
        </body>
        </html>
        """
    }

    /// 3 questions — all classified 成语辨析 by the rule engine, so the
    /// subcategory 成语辨析 holds the whole batch (the quiz loop then runs
    /// through all three). Classifier coverage of other types lives in the
    /// unit tests.
    private static let questionBatchJSON = """
    [
      {"_id":"q1","question":"<p>依次填入最恰当的一项是</p>","answer1":"<p>A. 栩栩如生</p>","answer2":"<p>B. 绘声绘色</p>","answer3":"<p>C. 惟妙惟肖</p>","answer4":"<p>D. 活灵活现</p>","key1":"1","key2":"0","key3":"0","key4":"0","test_ans":"","test_ans_right":"A","analysis":"<p>填入成语“栩栩如生”，形容非常逼真</p>"},
      {"_id":"q2","question":"<p>依次填入最恰当的一项是</p>","answer1":"<p>A. 虽然…但是</p>","answer2":"<p>B. 因为…所以</p>","answer3":"<p>C. 不但…而且</p>","answer4":"<p>D. 要么…要么</p>","key1":"1","key2":"0","key3":"0","key4":"0","test_ans":"","test_ans_right":"A","analysis":"<p>成语“一蹴而就”，意思是轻而易举</p>"},
      {"_id":"q3","question":"<p>第一空与“情怀”搭配的词语是</p>","answer1":"<p>A. 树立</p>","answer2":"<p>B. 建立</p>","answer3":"<p>C. 培养</p>","answer4":"<p>D. 塑造</p>","key1":"1","key2":"0","key3":"0","key4":"0","test_ans":"","test_ans_right":"A","analysis":"<p>成语“积重难返”，指长期形成的问题</p>"}
    ]
    """
}
