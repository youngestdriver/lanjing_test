import CryptoKit
import Foundation

/// 练习预取图片的磁盘缓存(URL 绝对串 SHA-256 → Caches/practice-images/<hash>.<ext>)。
/// PracticeBankViewModel 在进入练习时按当前题 → 后续题顺序预取写入;
/// RichHTMLContent.document 读取命中的字节以 data URI 嵌入 → WKWebView
/// 渲染零网络,图片出现在首测高度里,不产生"文字先出、图片后到"的二次生长。
/// 失败/未命中:保留原 src 走网络,由量高动画兜底。
enum PracticeImageStore {
    // 仅主线程访问(VM fetchImage 在 @MainActor、document 构建在 updateUIView)——
    // Swift 6 下懒加载全局需显式标记。
    nonisolated(unsafe) private static var directoryURL: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent("practice-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func data(for url: URL) -> Data? {
        guard let path = fileURL(for: url) else { return nil }
        return try? Data(contentsOf: path)
    }

    static func store(_ data: Data, for url: URL) {
        guard let path = fileURL(for: url) else { return }
        try? data.write(to: path, options: .atomic)
    }

    static func clear() {
        guard let dir = directoryURL else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func fileURL(for url: URL) -> URL? {
        guard let dir = directoryURL else { return nil }
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        return dir.appendingPathComponent("\(hash).\(ext)")
    }
}
