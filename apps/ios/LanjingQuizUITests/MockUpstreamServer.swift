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
    /// Explicit QoS so the test thread's blocking waits on this server are
    /// not priority inversions (callbacks fire on this queue).
    private let queue = DispatchQueue(label: "MockUpstreamServer", qos: .userInitiated)

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
        receivers.forEach { $0.cancel() }
    }

    // MARK: - Connection handling

    /// Active per-connection receive loops. All callbacks fire on the serial
    /// `queue`, so this is only touched from that queue (plus stop() at teardown).
    private var receivers: [ConnectionReceiver] = []

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        let receiver = ConnectionReceiver(connection: connection, server: self)
        receivers.append(receiver)
        receiver.start()
    }

    private func receiverFinished(_ receiver: ConnectionReceiver) {
        receivers.removeAll { $0 === receiver }
    }

    /// Per-connection receive loop. All NWConnection callbacks fire on the
    /// server's serial `queue`, so buffer state is confined to it; the
    /// @unchecked Sendable box keeps the @Sendable completion closures legal.
    /// The server retains the receiver for the connection's lifetime, and the
    /// receiver drops itself (via receiverFinished) when the connection ends.
    private final class ConnectionReceiver: @unchecked Sendable {
        private let connection: NWConnection
        private weak var server: MockUpstreamServer?
        private var buffer = Data()

        init(connection: NWConnection, server: MockUpstreamServer) {
            self.connection = connection
            self.server = server
        }

        func start() {
            receiveMore()
        }

        func cancel() {
            connection.cancel()
        }

        private func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let request = MockUpstreamServer.parseRequest(buffer) {
                    server?.respond(connection, to: request)
                } else if isComplete || error != nil {
                    connection.cancel()
                    server?.receiverFinished(self)
                } else {
                    receiveMore()
                }
            }
        }
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

    /// Answer-card HTML: one section + 5 questions in the section (q1–q3
    /// 成语辨析, q4 short / q5 long 虚词辨析 — the latter pair feeds the
    /// 题干高度 regression UI test).
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
            <a href="#4"><div class="question_cbox"><span>4</span><span questionsId="q4" uuId="u4"></span></div></a>
            <a href="#5"><div class="question_cbox"><span>5</span><span questionsId="q5" uuId="u5"></span></div></a>
          </div>
        </div>
        </body>
        </html>
        """
    }

    /// 5 questions. q1–q3 classify 成语辨析 (analysis contains 成语) and form
    /// the existing 3-question quiz loop; q4 (short) and q5 (a deliberately
    /// LONG 题干) classify 虚词辨析 via "关联词" — the 虚词辨析 rule runs
    /// before 成语辨析 in the 言语理解|逻辑填空 table, and neither contains
    /// the word 成语. q4 first / q5 second keeps every quiz-page control
    /// on-screen for the height-regression UI test (问题 1): the short 题干
    /// renders ~30pt, the long 题干 (20 paragraphs) ~1000pt. Classifier
    /// coverage of other types lives in the unit tests.
    private static let questionBatchJSON = """
    [
      {"_id":"q1","question":"<p>依次填入最恰当的一项是</p>","answer1":"<p>A. 栩栩如生</p>","answer2":"<p>B. 绘声绘色</p>","answer3":"<p>C. 惟妙惟肖</p>","answer4":"<p>D. 活灵活现</p>","key1":"1","key2":"0","key3":"0","key4":"0","test_ans":"","test_ans_right":"A","analysis":"<p>填入成语“栩栩如生”，形容非常逼真</p>"},
      {"_id":"q2","question":"<p>依次填入最恰当的一项是</p>","answer1":"<p>A. 虽然…但是</p>","answer2":"<p>B. 因为…所以</p>","answer3":"<p>C. 不但…而且</p>","answer4":"<p>D. 要么…要么</p>","key1":"1","key2":"0","key3":"0","key4":"0","test_ans":"","test_ans_right":"A","analysis":"<p>成语“一蹴而就”，意思是轻而易举</p>"},
      {"_id":"q3","question":"<p>第一空与“情怀”搭配的词语是</p>","answer1":"<p>A. 树立</p>","answer2":"<p>B. 建立</p>","answer3":"<p>C. 培养</p>","answer4":"<p>D. 塑造</p>","key1":"1","key2":"0","key3":"0","key4":"0","test_ans":"","test_ans_right":"A","analysis":"<p>成语“积重难返”，指长期形成的问题</p>"},
      {"_id":"q4","question":"<p>下列各句中，关联词使用最恰当的一项是</p>","answer1":"<p>A. 既然他已经尽力，就应当给予肯定</p>","answer2":"<p>B. 不但他认真学习，而且成绩很好</p>","answer3":"<p>C. 因为下雨，但是比赛照常进行</p>","answer4":"<p>D. 只要努力，所以一定能成功</p>","key1":"1","key2":"0","key3":"0","key4":"0","test_ans":"","test_ans_right":"A","analysis":"<p>本题考查关联词的搭配使用，正确句子应保持关联词成对使用</p>"},
      {"_id":"q5","question":"<p>阅读下面的文段，完成下列各题。</p><p>转折关系，是复句中一种非常重要的逻辑关系，它表示分句之间意思相反或者相对。</p><p>后一个分句不是顺着前一个分句的意思说下去，而是转到相反或相对的方向上去。</p><p>表示转折关系的常用关联词有：虽然……但是、尽管……可是、然而、却、不过、只是等。</p><p>例如“虽然天气很冷，但是他依然坚持晨跑”，前一分句说出一个事实，后一分句则转向相反的一面。</p><p>递进关系则不同，它表示后一分句的意思比前一分句更进一步，程度更深、范围更广。</p><p>表示递进关系的常用关联词有：不但……而且、不仅……还、尚且……何况、甚至等。</p><p>例如“他不但学习成绩优异，而且积极参加各种社会活动”，后一分句对前一分句作了进一步的补充。</p><p>因果关系表示前一分句是原因，后一分句是结果，或者反过来由果溯因。</p><p>表示因果关系的常用关联词有：因为……所以、由于……因此、之所以……是因为、既然……就等。</p><p>例如“因为他平时训练刻苦，所以这次比赛取得了优异的成绩”，前因后果，逻辑清楚。</p><p>并列关系表示几个分句分别说明相关的几件事，或者描述同一事物的几个方面。</p><p>表示并列关系的常用关联词有：既……又、一边……一边、一方面……另一方面、不是……而是等。</p><p>条件关系表示前一分句提出一个条件，后一分句说明满足这个条件后产生的结果。</p><p>表示条件关系的常用关联词有：只要……就、只有……才、无论……都、除非……否则等。</p><p>选择关系表示从几个分句所述的事项中选择一项，表示选择的常用关联词有：或者……或者、是……还是、宁可……也不等。</p><p>假设关系表示前一分句提出假设，后一分句说明这一假设实现后将会产生的结果。</p><p>表示假设关系的常用关联词有：如果……就、假如……那么、即使……也、要是……便等。</p><p>在一段文字中，正确使用关联词能够让语句之间的逻辑关系更加清晰，表达更加准确。</p><p>使用关联词时要注意搭配成对，不能混淆不同关系类型的关联词，否则会造成语病。</p><p>例如把“虽然”和“而且”搭配在一起使用，就属于典型的关联词搭配错误，需要特别注意。</p>","answer1":"<p>A. 转折</p>","answer2":"<p>B. 递进</p>","answer3":"<p>C. 因果</p>","answer4":"<p>D. 并列</p>","key1":"1","key2":"0","key3":"0","key4":"0","test_ans":"","test_ans_right":"A","analysis":"<p>本题考查关联词关系的辨析，转折关系与并列关系需要区分清楚</p>"}
    ]
    """
}
