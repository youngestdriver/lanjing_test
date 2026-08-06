import XCTest
@testable import LanjingQuiz

/// Records requested URLs across @Sendable closures (progress callbacks are
/// synchronous, so those use ProgressCollector instead).
private actor URLRecorder {
    private(set) var requested: [String] = []

    func record(_ url: String) { requested.append(url) }
}

/// Synchronous, lock-guarded progress collection for the sync progress
/// callback (NSLock is fine outside async contexts).
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [QuestionBankClient.Progress] = []

    func append(_ step: QuestionBankClient.Progress) {
        lock.lock(); defer { lock.unlock() }
        storage.append(step)
    }

    var steps: [QuestionBankClient.Progress] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

final class QuestionBankClientTests: XCTestCase {

    private static let metaJSON = #"{"version":1,"round":26,"counts":{"言语理解":2}}"#
    private static let categoryText = "{\"_id\":\"q1\"}\n"

    private func makeClient(
        _ handler: @escaping @Sendable (String) -> (Int, Data)
    ) -> (client: QuestionBankClient, recorder: URLRecorder) {
        let recorder = URLRecorder()
        let client = QuestionBankClient { url in
            await recorder.record(url.absoluteString)
            let (status, data) = handler(url.path)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        return (client, recorder)
    }

    func testDownloadBankSuccessFiresSixProgressStepsInOrder() async throws {
        let (client, recorder) = makeClient { path in
            if path.hasSuffix("meta.json") { return (200, Data(Self.metaJSON.utf8)) }
            return (200, Data(Self.categoryText.utf8))
        }
        let collector = ProgressCollector()
        let result = try await client.downloadBank(
            from: URL(string: "http://127.0.0.1:3000")!,
            progress: { collector.append($0) }
        )
        let steps = collector.steps
        XCTAssertEqual(steps.count, 6)
        XCTAssertEqual(steps.map(\.fileIndex), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(steps.map(\.fileName), ["meta.json", "言语理解.jsonl", "数字运算.jsonl", "逻辑推理.jsonl", "资料分析.jsonl", "特有题型.jsonl"])
        XCTAssertEqual(result.files.count, 5)
        XCTAssertEqual(result.files.first?.category, "言语理解")
        XCTAssertEqual(result.meta.round, 26)

        // Chinese file names percent-encoded in the request URL.
        let requested = await recorder.requested
        XCTAssertTrue(requested.contains { $0.contains("%E8%A8%80%E8%AF%AD%E7%90%86%E8%A7%A3.jsonl") })
    }

    func testDownloadBankTrailingSlashBaseURLYieldsSameURLs() async throws {
        func run(_ base: String) async throws -> [String] {
            let recorder = URLRecorder()
            let client = QuestionBankClient { url in
                await recorder.record(url.absoluteString)
                let data = url.path.hasSuffix("meta.json") ? Data(Self.metaJSON.utf8) : Data(Self.categoryText.utf8)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
            _ = try await client.downloadBank(from: URL(string: base)!, progress: { _ in })
            return await recorder.requested
        }
        let noSlash = try await run("http://127.0.0.1:3000")
        let withSlash = try await run("http://127.0.0.1:3000/")
        XCTAssertEqual(noSlash, withSlash)
    }

    func testHTTP404Throws() async {
        let (client, _) = makeClient { path in
            if path.hasSuffix("meta.json") { return (200, Data(Self.metaJSON.utf8)) }
            return (404, Data())
        }
        do {
            _ = try await client.downloadBank(from: URL(string: "http://127.0.0.1:3000")!, progress: { _ in })
            XCTFail("expected httpStatus error")
        } catch let error as QuestionBankClient.BankError {
            guard case .httpStatus(404) = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testLoaderThrowPropagates() async {
        let client = QuestionBankClient { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await client.downloadBank(from: URL(string: "http://127.0.0.1:3000")!, progress: { _ in })
            XCTFail("expected throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testMalformedMetaThrows() async {
        let (client, _) = makeClient { _ in (200, Data("not json".utf8)) }
        do {
            _ = try await client.downloadBank(from: URL(string: "http://127.0.0.1:3000")!, progress: { _ in })
            XCTFail("expected malformedMeta error")
        } catch let error as QuestionBankClient.BankError {
            guard case .malformedMeta = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testNotUTF8Throws() async {
        let (client, _) = makeClient { path in
            if path.hasSuffix("meta.json") { return (200, Data(Self.metaJSON.utf8)) }
            return (200, Data([0xFF, 0xFE, 0x00])) // invalid UTF-8
        }
        do {
            _ = try await client.downloadBank(from: URL(string: "http://127.0.0.1:3000")!, progress: { _ in })
            XCTFail("expected notUTF8 error")
        } catch let error as QuestionBankClient.BankError {
            guard case .notUTF8 = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testFetchMetaAlone() async throws {
        let (client, _) = makeClient { path in
            if path.hasSuffix("meta.json") { return (200, Data(Self.metaJSON.utf8)) }
            return (404, Data())
        }
        let meta = try await client.fetchMeta(from: URL(string: "http://127.0.0.1:3000")!)
        XCTAssertEqual(meta.round, 26)
        XCTAssertEqual(meta.totalCount, 2)
    }
}
