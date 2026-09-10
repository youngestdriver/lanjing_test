import SwiftUI
import UIKit

/// Renders upstream HTML (question stem, options, analysis) as SwiftUI text.
/// Dark mode: strips inline backgrounds and forces text color — mirrors the web's
/// `color: inherit !important` / background-stripping rules in index.html:911-918.
///
/// Rendering path: the overwhelming majority of blocks (p/span/br with plain
/// color, font-size and line-height styles — 99.9% of question text) go through
/// a hand-rolled scanner that produces the AttributedString directly. WebKit's
/// HTML importer is a 5–20× slower parse for exactly this input and dominates
/// practice-screen startup; anything outside the whitelist (`<img>` is routed
/// to WKWebView by RichHTMLContent anyway; lists, headings, superscripts, …)
/// falls back to the importer.
struct HTMLText: View {
    let html: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(Self.render(html, dark: colorScheme == .dark) ?? AttributedString(Self.plainText(html)))
    }

    @MainActor private static var cache: [String: AttributedString] = [:]
    /// 插入顺序,用于简单 FIFO 淘汰:整场练习(最多 150 题)的所有块都会
    /// 经过这里,无上限缓存会随会话一直涨。
    @MainActor private static var cacheOrder: [String] = []
    @MainActor private static let cacheLimit = 300

    @MainActor
    static func render(_ html: String, dark: Bool) -> AttributedString? {
        let key = html + (dark ? "|d" : "|l")
        if let cached = cache[key] { return cached }
        let result = canFastRender(html)
            ? fastRender(html, dark: dark)
            : importedRender(html, dark: dark)
        if let result {
            cache[key] = result
            cacheOrder.append(key)
            while cacheOrder.count > cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        return result
    }

    /// True when the block only uses tags the fast scanner understands:
    /// `p/span/br/b/strong/i/em/u`. Anything else (li, table, h3, sup, …) or
    /// an image falls back to the importer.
    nonisolated static func canFastRender(_ html: String) -> Bool {
        guard !html.lowercased().contains("<img") else { return false }
        let allowed: Set<String> = ["p", "span", "br", "b", "strong", "i", "em", "u"]
        guard let regex = try? NSRegularExpression(pattern: #"</?([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>"#) else { return false }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if !allowed.contains(ns.substring(with: match.range(at: 1)).lowercased()) { return false }
        }
        return true
    }

    // MARK: - Fast path

    @MainActor
    private static func fastRender(_ html: String, dark: Bool) -> AttributedString? {
        struct Style {
            var fontSize: CGFloat = 17
            var bold = false
            var italic = false
            var underline = false
            var lineHeight: CGFloat?
        }
        let fg: UIColor = dark ? .white : UIColor(hex: 0x3c3c3c)
        let ns = html as NSString
        let result = NSMutableAttributedString()
        var style = Style()
        var styleStack: [Style] = []

        func font(_ s: Style) -> UIFont {
            let base = UIFont.systemFont(ofSize: s.fontSize, weight: s.bold ? .bold : .regular)
            guard s.italic,
                  let descriptor = base.fontDescriptor.withSymbolicTraits(
                      base.fontDescriptor.symbolicTraits.union(.traitItalic)
                  ) else { return base }
            return UIFont(descriptor: descriptor, size: s.fontSize)
        }

        func attributes(_ s: Style) -> [NSAttributedString.Key: Any] {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font(s),
                .foregroundColor: fg,
            ]
            if let lineHeight = s.lineHeight {
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = lineHeight
                paragraph.maximumLineHeight = lineHeight
                attrs[.paragraphStyle] = paragraph
            }
            if s.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            return attrs
        }

        func append(_ text: String, _ s: Style = style) {
            result.append(NSAttributedString(string: text, attributes: attributes(s)))
        }

        /// Reads `style="…"` from an opening tag.
        func styleText(in tag: String) -> String {
            let ns = tag as NSString
            guard let regex = try? NSRegularExpression(pattern: #"style\s*=\s*["']([^"']*)["']"#),
                  let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length))
            else { return "" }
            return ns.substring(with: match.range(at: 1))
        }

        /// 与 Web importer 的语义对齐:颜色交由 dark/light 统一强制,
        /// 样式只保留字号/加粗/斜体/下划线/行高。
        func parseStyle(from styleText: String, into s: inout Style) {
            let ns = styleText as NSString
            func first(_ pattern: String) -> String? {
                guard let re = try? NSRegularExpression(pattern: pattern),
                      let m = re.firstMatch(in: styleText, range: NSRange(location: 0, length: ns.length))
                else { return nil }
                return ns.substring(with: m.range(at: 1))
            }
            if let px = first(#"font-size:\s*(\d+(?:\.\d+)?)px"#), let v = Double(px), v > 0 {
                s.fontSize = CGFloat(v)
            }
            if let weight = first(#"font-weight:\s*(\d+|bold)"#) {
                s.bold = weight == "bold" || (Double(weight) ?? 0) >= 600
            }
            if first(#"text-decoration:\s*([a-z-]+)"#)?.contains("underline") == true {
                s.underline = true
            }
            if let re = try? NSRegularExpression(pattern: #"line-height:\s*(\d+(?:\.\d+)?)\s*(px|rem|em|%)"#),
               let m = re.firstMatch(in: styleText, range: NSRange(location: 0, length: ns.length)),
               let value = Double(ns.substring(with: m.range(at: 1))) {
                switch ns.substring(with: m.range(at: 2)) {
                case "px": s.lineHeight = CGFloat(value)
                case "rem", "em": s.lineHeight = CGFloat(value) * s.fontSize
                case "%": s.lineHeight = CGFloat(value / 100) * s.fontSize
                default: break
                }
            }
        }

        guard let tokenRegex = try? NSRegularExpression(pattern: #"(?s)<[^>]*>|([^<]+)"#) else { return nil }
        let tokens = tokenRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for match in tokens {
            let raw = ns.substring(with: match.range)
            if raw.hasPrefix("<") {
                // 闭合标签用 </ 前缀:按名称分发,开/关由 name + closed 决定。
                let lower = raw.lowercased()
                let closed = lower.hasPrefix("</")
                let name: String
                if closed {
                    name = String(lower.dropFirst(2).prefix { $0 != ">" && $0 != "/" && !$0.isWhitespace })
                } else {
                    name = String(lower.dropFirst(1).prefix { $0 != ">" && $0 != "/" && !$0.isWhitespace })
                }
                switch name {
                case "br":
                    if !closed { append("\n") }
                case "p":
                    if !closed, result.length > 0 {
                        append("\n\n")
                        parseStyle(from: styleText(in: raw), into: &style)
                    }
                case "span":
                    if closed {
                        style = styleStack.popLast() ?? style
                    } else {
                        styleStack.append(style)
                        parseStyle(from: styleText(in: raw), into: &style)
                    }
                case "strong", "b":
                    style.bold = !closed
                case "i", "em":
                    style.italic = !closed
                case "u":
                    style.underline = !closed
                default:
                    break
                }
            } else {
                append(decodeEntities(raw))
            }
        }
        return AttributedString(result)
    }

    // MARK: - Fallback (WebKit HTML importer)

    @MainActor
    private static func importedRender(_ html: String, dark: Bool) -> AttributedString? {
        guard let data = html.data(using: .utf8),
              let ns = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                  ],
                  documentAttributes: nil
              )
        else { return nil }
        let mutable = NSMutableAttributedString(attributedString: ns)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.removeAttribute(.backgroundColor, range: full)
        let fg: UIColor = dark ? .white : UIColor(hex: 0x3c3c3c)
        mutable.addAttribute(.foregroundColor, value: fg, range: full)
        return AttributedString(mutable)
    }

    // MARK: - Helpers

    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    /// Decodes the entities the question bank actually uses + numeric refs.
    private nonisolated static func decodeEntities(_ text: String) -> String {
        var result = text
        let named: [(String, String)] = [
            ("&nbsp;", "\u{00A0}"), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&hellip;", "…"),
            ("&times;", "×"), ("&divide;", "÷"), ("&deg;", "°"), ("&middot;", "·"),
            ("&ndash;", "–"), ("&mdash;", "—"), ("&ldquo;", "“"), ("&rdquo;", "”"),
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let offset = Int(ns.substring(with: match.range(at: 1))) ?? 0
                if let scalar = UnicodeScalar(offset) {
                    result = (result as NSString).replacingCharacters(in: match.range, with: String(scalar))
                }
            }
        }
        return result
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
