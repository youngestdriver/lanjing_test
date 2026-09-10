import SwiftUI
import WebKit

/// Renders upstream question HTML. NSAttributedString's HTML importer silently
/// drops <img> tags, so blocks that carry images (formulas/charts) go through
/// WKWebView with the image bytes inlined as data: URIs (zero network, zero
/// custom scheme handler — see InlineHTMLWebView); text-only blocks render
/// natively via HTMLText.
struct RichHTMLContent: View {
    let html: String
    var fontSize: CGFloat = 17
    var allowsTextSelection = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        // 分段必须先于本地化:独立图段要拿**原始 remote URL** 去 SwiftData
        // 取位图(本地化后 src 变成 data: URI,按 remote 键查必然落空 →
        // 整块图永久灰条);只有混排段(整段交给 WebView)才需要 data: URI。
        let parts = Self.contentParts(of: html) { block in
            appState.bankDatabase?.localizeHTML(block) ?? block
        }
        Group {
            // 单一段且为纯文本:直接原生渲染(与历史视觉一致)。
            if parts.count == 1, case .text(let inner) = parts[0] {
                HTMLText(html: Self.stripTrailingFiller(inner))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // 段落级分段:文本段 HTMLText(原生)、独立图段 LocalBankImage
                // (SwiftData 直出,零 WebView)、行内混排段才用 WebView——
                // 数据库方案下图片块不再经 WebView/编码转手。
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(parts.indices, id: \.self) { index in
                        switch parts[index] {
                        case .text(let inner):
                            HTMLText(html: Self.stripTrailingFiller(inner))
                        case .image(let remoteURL):
                            LocalBankImage(remoteURL: remoteURL)
                        case .mixed(let inner):
                            webViewBlock(html: inner)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // 整体作为一个 accessibility 容器:调用点的 .accessibilityIdentifier
        // (题干高度测试等)落在容器上(组合 frame),而不是第一个文本段。
        .accessibilityElement(children: .contain)
    }

    // MARK: - Paragraph segmentation

    enum ParagraphPart {
        case text(String)
        case image(String)   // 原始 remoteURL,由 resolver 从 SwiftData 解码
        case mixed(String)   // 文字与图同行:整段交给 WebView
    }

    /// 分段 + 按段决定是否本地化。`.image` 段保留原始 remote URL(native
    /// 图块按它查 SwiftData),`.mixed` 段整体本地化后交给 WebView;`.text`
    /// 段不含 <img>,零成本跳过。布局上必须「先分段、后本地化」。
    @MainActor
    static func contentParts(
        of html: String,
        localize: (String) -> String
    ) -> [ParagraphPart] {
        paragraphParts(of: html).map { part in
            switch part {
            case .text(let inner): return .text(inner)
            case .image(let remoteURL): return .image(remoteURL)
            case .mixed(let inner): return .mixed(localize(inner))
            }
        }
    }

    /// 按块级标签(p/div/li)把 HTML 拆成段落,再按内容分类:
    /// - 无图 → 文本段;
    /// - 整段仅图(图表、整行公式)→ 独立图段;
    /// - 图与文字同行(行内公式)→ 混排段(WebView 保真)。
    /// 段与段之间的裸文本/残留归入文本段。
    nonisolated static func paragraphParts(of html: String) -> [ParagraphPart] {
        let ns = html as NSString
        guard let blockRegex = try? NSRegularExpression(
            pattern: #"(?is)<(?:p|div|li)\b[^>]*>.*?</(?:p|div|li)>"#
        ) else { return [.text(html)] }

        var parts: [ParagraphPart] = []
        func appendText(_ raw: String, _ whitespaceOnly: Bool) {
            guard !whitespaceOnly, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            parts.append(.text(raw))
        }
        func appendBlock(_ block: String) {
            let imgs = BankDatabase.imageURLs(from: block)
            guard !imgs.isEmpty else {
                parts.append(.text(block))
                return
            }
            // 块内是否还有 img 之外的文字(判定"同行混排"的关键)。
            let withoutImgs = block.replacingOccurrences(
                of: #"(?is)<img\b[^>]*>"#,
                with: "",
                options: .regularExpression
            )
            let strippedText = withoutImgs
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"&[a-zA-Z#0-9]+;"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if strippedText.isEmpty {
                parts.append(contentsOf: imgs.map(ParagraphPart.image))
            } else {
                parts.append(.mixed(block))
            }
        }

        var cursor = 0
        let full = NSRange(location: 0, length: ns.length)
        while let match = blockRegex.firstMatch(in: html, options: [], range: NSRange(location: cursor, length: full.length - cursor)) {
            if match.range.location > cursor {
                appendText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), false)
            }
            appendBlock(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        if cursor < full.length {
            appendText(ns.substring(with: NSRange(location: cursor, length: full.length - cursor)), false)
        }
        return parts.isEmpty ? [.text(html)] : parts
    }

    /// 行内混排段:webView(骨架 + 估高),图片已在段落切分前的
    /// localize 中内联为 data URI。状态按块私有(一个实例可能含多个
    /// 混排段,骨架/高度互不干扰)。
    private func webViewBlock(html innerHtml: String) -> some View {
        MixedWebView(
            html: innerHtml,
            fontSize: fontSize,
            dark: colorScheme == .dark,
            allowsTextSelection: allowsTextSelection
        )
    }

    /// 单段行内混排内容:骨架占位 + WebView,确定布局后揭示。
    private struct MixedWebView: View {
        let html: String
        let fontSize: CGFloat
        let dark: Bool
        let allowsTextSelection: Bool
        @State private var contentHeight: CGFloat = 1
        @State private var didFinishInitialLayout = false

        var body: some View {
            ZStack(alignment: .topLeading) {
                InlineHTMLWebView(
                    html: html,
                    fontSize: fontSize,
                    dark: dark,
                    allowsTextSelection: allowsTextSelection,
                    contentHeight: $contentHeight,
                    onInitialLayout: { didFinishInitialLayout = true }
                )
                .frame(height: contentHeight)
                .opacity(didFinishInitialLayout ? 1 : 0)

                if !didFinishInitialLayout {
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(height: max(18, fontSize * 1.2))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.10))
                            .frame(height: max(18, fontSize * 1.2))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .redacted(reason: .placeholder)
                }
            }
            .frame(minHeight: didFinishInitialLayout ? contentHeight : max(48, fontSize * 2.8))
            .transaction { $0.animation = nil }
        }
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
    let onInitialLayout: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight, onInitialLayout: onInitialLayout)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // No custom URL scheme handler on purpose: images are inlined as
        // data: URIs (BankDatabase.localizeHTML) before the document loads,
        // so every WebView keeps the default configuration and they all share
        // one WebContent process. A custom scheme handler would pin its own
        // process per configuration — the source of the WebContent storms.
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
        <body>\(RichHTMLContent.stripTrailingFiller(html))</body>
        <script>
        (() => {
            const report = () => {
                const height = Math.ceil(document.documentElement.scrollHeight);
                window.webkit.messageHandlers.contentHeight.postMessage(height);
            };
            const images = Array.from(document.images);
            const settle = image => image.complete ? Promise.resolve() : new Promise(resolve => {
                const done = () => resolve();
                image.addEventListener('load', done, { once: true });
                image.addEventListener('error', done, { once: true });
            });
            // Do not reveal the native view until image dimensions are known.
            Promise.all(images.map(settle)).then(() => {
                requestAnimationFrame(() => {
                    window.webkit.messageHandlers.contentHeight.postMessage({
                        height: Math.ceil(document.documentElement.scrollHeight),
                        initial: true
                    });
                    new ResizeObserver(report).observe(document.body);
                });
            });
            report();
        })();
        </script></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        @Binding var contentHeight: CGFloat
        var lastDocument: String?

        let onInitialLayout: () -> Void

        init(contentHeight: Binding<CGFloat>, onInitialLayout: @escaping () -> Void) {
            _contentHeight = contentHeight
            self.onInitialLayout = onInitialLayout
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "contentHeight" else { return }
            if let payload = message.body as? [String: Any],
               let rawHeight = payload["height"] as? NSNumber {
                if payload["initial"] as? Bool == true { onInitialLayout() }
                update(CGFloat(truncating: rawHeight))
                return
            }
            guard let height = message.body as? NSNumber else { return }
            update(CGFloat(truncating: height))
        }

        private func update(_ rawHeight: CGFloat) {
            let measuredHeight = max(1, rawHeight)
            if abs(contentHeight - measuredHeight) > 0.5 {
                contentHeight = measuredHeight
            }
        }
    }
}

/// 独立图片块(图表/整行公式):本地库解码直出——零 WebView、零网络、
/// 零 base64。解码结果由 resolver 缓存,通常一次性。大图按屏幕宽度
/// 缩放,小图(公式/图例)保持原始尺寸不放大。
private struct LocalBankImage: View {
    let remoteURL: String
    @Environment(AppState.self) private var appState
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: image.size.width)
                    .padding(.vertical, 4)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .task(id: remoteURL) {
            image = appState.bankDatabase?.resolverImage(for: remoteURL)
        }
    }
}
