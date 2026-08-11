import AppKit
import Foundation

// 蓝鲸助手 status-bar launcher: spawns the bundled Bun server binary,
// opens the browser, and exposes 打开浏览器 / 退出 in the menu bar.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var server: Process?
    private let homeURL = URL(string: "http://127.0.0.1:3000")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
        buildStatusItem()
        startServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = NSImage(named: NSImage.Name("status-icon")) {
                button.image = image
            } else {
                button.title = "蓝"
            }
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "打开浏览器", action: #selector(openBrowser), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func startServer() {
        let serverURL = Bundle.main.resourceURL!
            .appendingPathComponent("LanjingQuiz-server")
        guard FileManager.default.isExecutableFile(atPath: serverURL.path) else {
            showFailure("服务组件缺失:\(serverURL.path)")
            return
        }
        let process = Process()
        process.executableURL = serverURL
        process.environment = [
            "LANJING_LOCAL_DIR": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/LanjingQuiz").path,
            "LANJING_OPEN_BROWSER": "1",
            "PORT": "3000",
        ]
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.statusItem?.button?.title = "蓝"
            }
        }
        do {
            try process.run()
            server = process
            // 浏览器由服务端在 listen 成功后经 LANJING_OPEN_BROWSER=1 打开,
            // 这里不再重复打开(否则会开两个标签页)。
        } catch {
            showFailure("服务启动失败:\(error.localizedDescription)")
        }
    }

    private func stopServer() {
        if let server, server.isRunning {
            server.terminate()
            server.waitUntilExit()
        }
        server = nil
    }

    @objc private func openBrowser() {
        NSWorkspace.shared.open(homeURL)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "蓝鲸助手"
        alert.informativeText = message
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
