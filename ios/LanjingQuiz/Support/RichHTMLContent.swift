import SwiftUI
import WebKit

/// Renders upstream HTML with remote images. NSAttributedString's HTML importer
/// silently drops <img> tags (no image loading), so the HTML is split into
/// text runs (rendered by HTMLText) and image blocks (AsyncImage).
struct RichHTMLContent: View {
    let html: String
    var fontSize: CGFloat = 17
    var allowsTextSelection = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        InlineHTMLWebView(
            html: html,
            fontSize: fontSize,
            dark: colorScheme == .dark,
            allowsTextSelection: allowsTextSelection,
            contentHeight: $contentHeight
        )
        .frame(height: contentHeight)
    }

    enum Segment {
        case text(String)
        case image(URL)
    }

    /// Split HTML into alternating text / image segments.
    static func segments(from html: String) -> [Segment] {
        let ns = html as NSString
        guard let imgRegex = try? NSRegularExpression(
            pattern: "<img\\b[^>]*>",
            options: [.caseInsensitive]
        ) else { return [.text(html)] }
        let matches = imgRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [.text(html)] }

        var segments: [Segment] = []
        var cursor = 0
        for match in matches {
            let tagRange = match.range
            if tagRange.location > cursor {
                let text = ns.substring(with: NSRange(location: cursor, length: tagRange.location - cursor))
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.text(text))
                }
            }
            if let url = imageURL(from: ns.substring(with: tagRange)) {
                segments.append(.image(url))
            }
            cursor = tagRange.location + tagRange.length
        }
        if cursor < ns.length {
            let text = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(text))
            }
        }
        if segments.isEmpty { segments.append(.text(html)) }
        return segments
    }

    /// Extract the src (falling back to data-src for lazy-loaded images),
    /// resolve relative URLs against the upstream base, decode common entities.
    static func imageURL(from imgTag: String) -> URL? {
        let tag = imgTag as NSString
        let patterns = ["src", "data-src"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: "\(pattern)\\s*=\\s*[\"']([^\"']+)[\"']",
                options: [.caseInsensitive]
            ), let match = regex.firstMatch(in: imgTag, range: NSRange(location: 0, length: tag.length)) else {
                continue
            }
            return resolvedURL(tag.substring(with: match.range(at: 1)))
        }
        return nil
    }

    private static func resolvedURL(_ src: String) -> URL? {
        let decoded = src
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        guard !decoded.hasPrefix("data:") else { return nil }  // data URIs: unsupported
        return URL(string: decoded, relativeTo: APIClient.baseURL)
    }
}

private struct InlineHTMLWebView: UIViewRepresentable {
    let html: String
    let fontSize: CGFloat
    let dark: Bool
    let allowsTextSelection: Bool
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "contentHeight")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = allowsTextSelection
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.isUserInteractionEnabled = allowsTextSelection
        let document = Self.document(
            html: html,
            fontSize: fontSize,
            dark: dark,
            allowsTextSelection: allowsTextSelection
        )
        guard context.coordinator.lastDocument != document else { return }
        context.coordinator.lastDocument = document
        webView.loadHTMLString(document, baseURL: APIClient.baseURL)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "contentHeight")
    }

    private static func document(
        html: String,
        fontSize: CGFloat,
        dark: Bool,
        allowsTextSelection: Bool
    ) -> String {
        let foreground = dark ? "#ffffff" : "#3c3c3c"
        let userSelect = allowsTextSelection ? "text" : "none"
        let touchCallout = allowsTextSelection ? "default" : "none"
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
        html, body {
            margin: 0; padding: 0; width: 100%; overflow: hidden;
            background: transparent; color: \(foreground);
            font: \(fontSize)px/1.55 -apple-system, BlinkMacSystemFont, sans-serif;
            overflow-wrap: break-word;
            -webkit-user-select: \(userSelect);
            user-select: \(userSelect);
            -webkit-touch-callout: \(touchCallout);
        }
        p { margin: 0 0 0.55em; }
        img {
            display: inline;
            max-width: 100% !important;
            height: auto !important;
            vertical-align: middle;
        }
        * { background-color: transparent !important; }
        </style></head>
        <body>\(html)</body>
        <script>
        (() => {
            const report = () => {
                const height = Math.ceil(document.documentElement.scrollHeight);
                window.webkit.messageHandlers.contentHeight.postMessage(height);
            };
            new ResizeObserver(report).observe(document.body);
            document.querySelectorAll('img').forEach(image => {
                image.addEventListener('load', report);
                image.addEventListener('error', report);
            });
            window.addEventListener('load', report);
            report();
        })();
        </script></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        @Binding var contentHeight: CGFloat
        var lastDocument: String?

        init(contentHeight: Binding<CGFloat>) {
            _contentHeight = contentHeight
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "contentHeight",
                  let height = message.body as? NSNumber else { return }
            let measuredHeight = max(1, CGFloat(truncating: height))
            if abs(contentHeight - measuredHeight) > 0.5 {
                contentHeight = measuredHeight
            }
        }
    }
}
