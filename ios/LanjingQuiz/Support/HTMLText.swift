import SwiftUI
import UIKit

/// Renders upstream HTML (question stem, options, analysis) as SwiftUI text.
/// Dark mode: strips inline backgrounds and forces text color — mirrors the web's
/// `color: inherit !important` / background-stripping rules in index.html:911-918.
struct HTMLText: View {
    let html: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(Self.render(html, dark: colorScheme == .dark) ?? AttributedString(Self.plainText(html)))
    }

    @MainActor private static var cache: [String: AttributedString] = [:]

    @MainActor
    static func render(_ html: String, dark: Bool) -> AttributedString? {
        let key = html + (dark ? "|d" : "|l")
        if let cached = cache[key] { return cached }
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
        let attributed = AttributedString(mutable)
        cache[key] = attributed
        return attributed
    }

    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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
