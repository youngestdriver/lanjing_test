import SwiftUI

/// Renders upstream HTML with remote images. NSAttributedString's HTML importer
/// silently drops <img> tags (no image loading), so the HTML is split into
/// text runs (rendered by HTMLText) and image blocks (AsyncImage).
struct RichHTMLContent: View {
    let html: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(from: html).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let html):
                    HTMLText(html: html)
                case .image(let url):
                    RemoteImageView(url: url)
                }
            }
        }
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

struct RemoteImageView: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
            case .failure:
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                    Text("图片加载失败")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))
            case .empty:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 280)
        .clipped()
    }
}
