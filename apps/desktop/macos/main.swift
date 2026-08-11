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
        menu.addItem(withTitle: "设置 Cookie 服务器…", action: #selector(showCookieCloudDialog), keyEquivalent: "")
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

    @objc private func showCookieCloudDialog() {
        let alert = NSAlert()
        alert.messageText = "Cookie 服务器"
        alert.informativeText = "配置 CookieCloud 以在设备间共享登录会话"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let enabledCheck = NSButton(checkboxWithTitle: "启用同步", target: nil, action: nil)
        let serverField = NSTextField(string: "")
        serverField.placeholderString = "https://cc.example.com"
        let uuidField = NSTextField(string: "")
        uuidField.placeholderString = "扩展设置中的 UUID"
        let passwordField = NSSecureTextField(string: "")
        passwordField.placeholderString = "留空不修改"
        let statusLabel = NSTextField(labelWithString: "读取中…")
        statusLabel.textColor = .secondaryLabelColor
        let errorLabel = NSTextField(labelWithString: "")
        errorLabel.textColor = .systemRed

        // NSAlert does not size its accessoryView: an Auto-Layout-only stack
        // keeps its zero frame and the fields never render. Give the stack an
        // explicit frame and let it lay its arranged subviews out.
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 340, height: 210))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for (label, field) in [("服务器地址", serverField), ("UUID", uuidField), ("密码", passwordField)] {
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: 11, weight: .medium)
            stack.addArrangedSubview(caption)
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
            stack.addArrangedSubview(field)
        }
        stack.addArrangedSubview(enabledCheck)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(errorLabel)
        alert.accessoryView = stack

        // 预填(异步 GET;runModal 的模态 runloop 会派发 main queue,字段在
        // 用户输入前填充好)。
        fetchCookieCloudConfig { [weak self] config in
            // 闭包已在 main 队列(见 fetchCookieCloudConfig);GET 失败时与 C# 侧
            // 行为对齐:红字报错、清掉“读取中…”状态,避免静默卡在“读取中…”。
            guard let config else {
                errorLabel.stringValue = "读取配置失败:无法连接本地服务"
                statusLabel.stringValue = ""
                return
            }
            enabledCheck.state = config.enabled ? .on : .off
            serverField.stringValue = config.server
            uuidField.stringValue = config.uuid
            passwordField.placeholderString = config.hasPassword ? "已保存,留空不修改" : "未设置"
            statusLabel.stringValue = self?.buildStatus(config) ?? ""
        }

        // A menu-bar app (LSUIElement) is not active by default: without
        // activation the alert's text fields never receive keyboard input
        // (fields look editable but typing does nothing). Activate first and
        // put the first field in focus so the user can type immediately.
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeFirstResponder(serverField)

        if alert.runModal() != .alertFirstButtonReturn { return }

        var payload: [String: Any] = [
            "enabled": enabledCheck.state == .on,
            "server": serverField.stringValue.trimmingCharacters(in: .whitespaces),
            "uuid": uuidField.stringValue.trimmingCharacters(in: .whitespaces),
        ]
        if !passwordField.stringValue.isEmpty {
            payload["password"] = passwordField.stringValue
        }
        saveCookieCloudConfig(payload) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.showFailure("保存 Cookie 服务器配置失败:\(error)")
                } else {
                    // 保存成功:触发一次同步(server 单飞,失败静默进 lastError)。
                    self?.syncCookieCloudNow()
                }
            }
        }
    }

    private struct CookieCloudConfig {
        let enabled: Bool
        let server: String
        let uuid: String
        let hasPassword: Bool
        let lastPush: String?
        let lastPull: String?
        let lastError: String?
    }

    private func fetchCookieCloudConfig(completion: @escaping (CookieCloudConfig?) -> Void) {
        let url = URL(string: "http://127.0.0.1:\(homeURL.port ?? 3000)/api/cookiecloud")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let config = CookieCloudConfig(
                enabled: json["enabled"] as? Bool ?? false,
                server: json["server"] as? String ?? "",
                uuid: json["uuid"] as? String ?? "",
                hasPassword: json["hasPassword"] as? Bool ?? false,
                lastPush: json["lastPush"] as? String,
                lastPull: json["lastPull"] as? String,
                lastError: json["lastError"] as? String)
            DispatchQueue.main.async { completion(config) }
        }.resume()
    }

    private func saveCookieCloudConfig(_ payload: [String: Any], completion: @escaping (String?) -> Void) {
        let url = URL(string: "http://127.0.0.1:\(homeURL.port ?? 3000)/api/cookiecloud")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["server"] != nil else {
                let message: String
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? String {
                    message = error
                } else {
                    message = "无法连接本地服务"
                }
                DispatchQueue.main.async { completion(message) }
                return
            }
            DispatchQueue.main.async { completion(nil) }
        }.resume()
    }

    private func syncCookieCloudNow() {
        let url = URL(string: "http://127.0.0.1:\(homeURL.port ?? 3000)/api/cookiecloud/sync")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 服务端对所有写请求要求 application/json(否则 415 直接拒收),同
        // saveCookieCloudConfig;不带 body 的 POST 也必须带此头。
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    private func buildStatus(_ config: CookieCloudConfig) -> String {
        if let lastError = config.lastError, !lastError.isEmpty {
            return "上次同步失败:\(lastError)"
        }
        var parts: [String] = []
        if let lastPull = config.lastPull, !lastPull.isEmpty { parts.append("上次拉取 \(Self.formatTime(lastPull))") }
        if let lastPush = config.lastPush, !lastPush.isEmpty { parts.append("上次推送 \(Self.formatTime(lastPush))") }
        return parts.isEmpty ? "尚未同步" : parts.joined(separator: " · ")
    }

    private static func formatTime(_ iso: String) -> String {
        // server 的 lastPush/lastPull 带毫秒("2026-08-12T01:23:45.678Z"),
        // 默认选项不含 .withFractionalSeconds 会解析失败、退回原始 ISO 串。
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // 兜底:非毫秒时间戳(.withFractionalSeconds 会解析失败)回退默认选项,
        // 避免退回原始 ISO 串。
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return iso }
        let display = DateFormatter()
        display.dateFormat = "HH:mm"
        return display.string(from: date)
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
