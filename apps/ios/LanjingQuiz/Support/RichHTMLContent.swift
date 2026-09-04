import SwiftUI
import WebKit

/// Renders upstream HTML with remote images. NSAttributedString's HTML importer
/// silently drops <img> tags (no image loading), so the HTML is split into
/// text runs (rendered by HTMLText) and image blocks (AsyncImage).
///
/// 首帧高度策略(练习"空白页突然长出":WebView 量高异步 + 远程图晚到):
/// 初始高度 = 缓存实测 ?? 按文字密度的估算(不再是 1pt);量高到位和图片
/// 加载完成的高度更新走 0.25s ease-out 动画;实测高度按 html+字号缓存
/// (HTMLHeightCache),同会话内翻页回看零闪跳。预取命中的图片由
/// localizedImageTags 以 data URI 嵌入文档(见 PracticeBankViewModel),
/// 渲染零网络,图片出现在首测高度里,不产生二次生长。
struct RichHTMLContent: View {
    let html: String
    var fontSize: CGFloat = 17
    var allowsTextSelection = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat

    init(html: String, fontSize: CGFloat = 17, allowsTextSelection: Bool = true) {
        self.html = html
        self.fontSize = fontSize
        self.allowsTextSelection = allowsTextSelection
        _contentHeight = State(initialValue: HTMLHeightCache.height(for: html, fontSize: fontSize)
            ?? RichHTMLContent.estimatedHeight(html: html, fontSize: fontSize))
    }

    var body: some View {
        InlineHTMLWebView(
            html: html,
            fontSize: fontSize,
            dark: colorScheme == .dark,
            allowsTextSelection: allowsTextSelection,
            contentHeight: $contentHeight
        )
        .frame(height: contentHeight)
        .animation(.easeOut(duration: 0.25), value: contentHeight)
    }

    enum Segment {
        case text(String)
        case image(URL)
    }

    /// Upstream rich-text editors append filler blocks after the visible
    /// text (`<p><br/></p>`, `<p>&nbsp;</p>`, stray `<br>`, `&nbsp;`/whitespace
    /// runs). The browser renders them as full blank lines, pushing the options
    /// and analysis down by a per-question amount — the varying gap between the
    /// stem and the options. Only the tail is stripped: interior blank
    /// paragraphs, a trailing `<br>` inside a paragraph that carries words, and
    /// the answer blanks inside the question text are preserved.
    static func stripTrailingFiller(_ html: String) -> String {
        var result = html
        while true {
            let before = result
            result = result.replacingOccurrences(
                of: #"(?is)(?:&nbsp;|\s)+$"#,
                with: "",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: #"(?is)<br\s*/?>(?:&nbsp;|\s)*$"#,
                with: "",
                options: .regularExpression
            )
            if let stripped = strippingTrailingEmptyBlock(from: result) {
                result = stripped
            }
            if result == before { break }
        }
        return result
    }

    /// Drops the trailing `<p>…</p>` / `<div>…</div>` block whose rendered text
    /// is empty (whitespace / `&nbsp;` / filler tags only); nil when the tail
    /// carries content or the structure is malformed.
    private static func strippingTrailingEmptyBlock(from html: String) -> String? {
        let ns = html as NSString
        let pClose = ns.range(of: "</p>", options: [.backwards, .caseInsensitive])
        let divClose = ns.range(of: "</div>", options: [.backwards, .caseInsensitive])
        let useDiv = divClose.location != NSNotFound
            && (pClose.location == NSNotFound || divClose.location > pClose.location)
        if pClose.location == NSNotFound && divClose.location == NSNotFound { return nil }
        let close = useDiv ? divClose : pClose
        let tag = useDiv ? "div" : "p"
        // Latest open tag of this kind before the close. The lookahead keeps
        // </p>, <pre>, <picture> etc. from matching.
        guard let openRegex = try? NSRegularExpression(
            pattern: "<\(tag)(?=[\\s>])",
            options: [.caseInsensitive]
        ), let open = openRegex.matches(in: html, range: NSRange(location: 0, length: close.location)).last
        else { return nil }
        // Open tag must actually terminate before the close tag.
        let afterOpen = open.range.location + open.range.length
        let openEnd = ns.range(
            of: ">",
            options: [],
            range: NSRange(location: afterOpen, length: close.location - afterOpen)
        )
        guard openEnd.location != NSNotFound else { return nil }
        let content = ns.substring(with: NSRange(
            location: openEnd.location + 1,
            length: close.location - openEnd.location - 1
        ))
        // Filler spans/breaks are invisible alone, but images, tables, media
        // etc. render real content — such blocks are never filler.
        let hasVisualContent = content.range(
            of: #"(?i)<(?:img|picture|svg|canvas|iframe|embed|object|video|audio|table|math|input|textarea|select|hr|form)\b"#,
            options: .regularExpression
        ) != nil
        let text = content
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty, !hasVisualContent else { return nil }
        let block = NSRange(
            location: open.range.location,
            length: close.location + close.length - open.range.location
        )
        return ns.replacingCharacters(in: block, with: "")
    }

    /// 首帧高度估算:量高回调到达前给出接近最终的初始高度,页面不再以 1pt
    /// 起步。中文按 1em 宽、ASCII 按 0.55em 宽折算字符密度,行高与正文 CSS
    /// 一致(fontSize × 1.55);估算只能逼近,实测到位后由动画平滑修正。
    nonisolated static func estimatedHeight(html: String, fontSize: CGFloat) -> CGFloat {
        let stripped = html
            .replacingOccurrences(
                of: #"(?i)<(?:img|picture|svg)\b[^>]*>"#,
                with: "▮",
                options: .regularExpression
            )
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lineHeight = fontSize * 1.55
        guard !stripped.isEmpty else { return lineHeight + fontSize * 0.55 }
        let scalars = stripped.unicodeScalars
        let ascii = scalars.reduce(0) { $0 + ($1.isASCII ? 1 : 0) }
        let width = Double(scalars.count - ascii) * 1.0 + Double(ascii) * 0.55
        let charsPerLine = max(8.0, 375.0 / Double(fontSize))
        let lines = max(1, Int(ceil(width / charsPerLine)))
        return CGFloat(lines) * lineHeight + fontSize * 0.55
    }

    /// 预取命中的图片以 data URI 就地替换 `<img>` 的 src:WKWebView 渲染
    /// 零网络、图片出现在首测高度里,不产生"文字先出、图片后到"的二次生长。
    /// `imageData` 收到与 imageURL 同解析规则的绝对 URL;未命中返回 nil 保留
    /// 原 src(走网络,由量高动画兜底)。
    nonisolated static func localizedImageTags(
        _ html: String,
        imageData: (URL) -> Data?
    ) -> String {
        let ns = html as NSString
        let pattern = #"(?i)<img\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        var result = html
        for match in matches.reversed() {
            let tag = ns.substring(with: match.range)
            guard let url = imageURL(from: tag), let data = imageData(url) else { continue }
            let attrPattern = #"(?is)(src|data-src)\s*=\s*(["'])[^"']*\2"#
            guard let attrRegex = try? NSRegularExpression(pattern: attrPattern) else { continue }
            let modified = attrRegex.stringByReplacingMatches(
                in: tag,
                range: NSRange(location: 0, length: (tag as NSString).length),
                withTemplate: "$1=$2data:\(mimeType(for: url));base64,\(data.base64EncodedString())$2"
            )
            result = (result as NSString).replacingCharacters(in: match.range, with: modified)
        }
        return result
    }

    nonisolated private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// Split HTML into alternating text / image segments.
    nonisolated static func segments(from html: String) -> [Segment] {
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
    nonisolated static func imageURL(from imgTag: String) -> URL? {
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

    nonisolated private static func resolvedURL(_ src: String) -> URL? {
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
        Coordinator(contentHeight: $contentHeight, html: html, fontSize: fontSize)
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
        context.coordinator.html = html
        context.coordinator.fontSize = fontSize
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
        // Upstream content carries inline `color: #3C464F`-style spans designed
        // for light backgrounds; in dark mode those stay dark-on-dark unless
        // every element is forced to inherit the body's white text. The
        // universal rule must NOT override html/body themselves (inheriting
        // from the viewport's initial black), so their color carries
        // !important and wins by type specificity.
        let colorRule = dark ? "* { background-color: transparent !important; color: inherit !important; }"
                             : "* { background-color: transparent !important; }"
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
        html, body {
            margin: 0; padding: 0; width: 100%; overflow: hidden;
            background: transparent; color: \(foreground) !important;
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
        \(colorRule)
        </style></head>
        <body>\(RichHTMLContent.stripTrailingFiller(
            RichHTMLContent.localizedImageTags(html) { PracticeImageStore.data(for: $0) }
        ))</body>
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
        var html: String
        var fontSize: CGFloat

        init(contentHeight: Binding<CGFloat>, html: String, fontSize: CGFloat) {
            _contentHeight = contentHeight
            self.html = html
            self.fontSize = fontSize
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
                HTMLHeightCache.setHeight(measuredHeight, for: html, fontSize: fontSize)
            }
        }
    }
}

/// 进程内量高缓存(html+字号 → 实测高度):同一次会话翻页回看零闪跳。
/// 写入:WKScriptMessageHandler(主线程);读取:RichHTMLContent init。
/// Swift 6 严格并发下 View init 不可触碰 @MainActor 全局,故以 NSLock +
/// nonisolated(unsafe) 保护,调用方保证量级小(每题几个字段)。
enum HTMLHeightCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [String: CGFloat] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    private static let limit = 500

    static func height(for html: String, fontSize: CGFloat) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        return storage[key(html, fontSize)]
    }

    static func setHeight(_ height: CGFloat, for html: String, fontSize: CGFloat) {
        let k = key(html, fontSize)
        lock.lock(); defer { lock.unlock() }
        if storage[k] == nil {
            order.append(k)
            if order.count > limit {
                storage[order.removeFirst()] = nil
            }
        }
        storage[k] = height
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        storage = [:]
        order = []
    }

    static func key(_ html: String, _ fontSize: CGFloat) -> String {
        "\(fontSize)|\(html)"
    }
}
