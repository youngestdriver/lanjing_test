import Foundation
import SwiftData
import WebKit

/// Serves `lanjing-image://<id>` resources to WKWebView from SwiftData.
final class QuestionImageSchemeHandler: NSObject, WKURLSchemeHandler {
    private let database: BankDatabase

    init(database: BankDatabase) {
        self.database = database
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let id = urlSchemeTask.request.url?.host,
              !id.isEmpty else {
            fail(urlSchemeTask, status: 400)
            return
        }
        Task { @MainActor in
            do {
                let context = ModelContext(database.container)
                let images = try context.fetch(FetchDescriptor<BankImage>())
                guard let image = images.first(where: { $0.id == id }) else {
                    fail(urlSchemeTask, status: 404)
                    return
                }
                let response = URLResponse(
                    url: urlSchemeTask.request.url!,
                    mimeType: image.mimeType,
                    expectedContentLength: image.data.count,
                    textEncodingName: nil
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(image.data)
                urlSchemeTask.didFinish()
            } catch {
                fail(urlSchemeTask, status: 500)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, status: Int) {
        let response = HTTPURLResponse(
            url: task.request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil
        )!
        task.didReceive(response)
        task.didFinish()
    }
}
