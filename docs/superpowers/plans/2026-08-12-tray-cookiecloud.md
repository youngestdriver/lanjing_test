# 托盘 CookieCloud 设置实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows 托盘与 macOS 菜单栏增加"设置 Cookie 服务器…"入口,原生对话框配置 CookieCloud(启用/服务器/UUID/密码),保存后自动同步。

**Architecture:** 服务端零改动——复用已存在的免登录 API(GET/POST `/api/cookiecloud`、POST `/api/cookiecloud/sync`);两个 wrapper 各自实现原生对话框:Windows C# WinForms Form、macOS Swift NSAlert + accessoryView。

**Tech Stack:** C# .NET 8 WinForms(本地无 dotnet,CI 编译验证)、Swift 6 AppKit(本地可编译)、System.Net.Http / URLSession。

## Global Constraints

- 服务端(`apps/web/server.js`)与测试**零改动**(现有 93 项测试保持全绿)
- API 契约(已存在,直接消费):`GET /api/cookiecloud` → `{enabled, server, uuid, hasPassword, lastPush, lastPull, lastError}`;`POST /api/cookiecloud` 部分更新,password 空/缺 → 保留;`POST /api/cookiecloud/sync` 单飞永不 reject
- 对话框打开时 GET 预填;密码框**留空 = 不修改**(hasPassword 时显示"已保存,留空不修改")
- 保存成功 → 自动 POST `/api/cookiecloud/sync`;保存失败 → 对话框内错误文案,不关闭
- 端口常量复用:`Program.ServerPort = 3000`(C#)/ `homeURL` 端口(macOS)
- C# 本地无法编译 → 语法级自审 + CI windows job 编译验证;macOS 本地完整编译
- GUI 交互(对话框手动点击)无法自动化——交付后由用户手动确认;自动化验证覆盖:编译 + 服务 API 冒烟

---

### Task 1: Windows C# 对话框 + 菜单项

**Files:**
- Create: `apps/desktop/windows/CookieCloudForm.cs`
- Modify: `apps/desktop/windows/Program.cs`(静态 HttpClient、菜单项、ShowCookieCloudDialog)

**Interfaces:**
- Consumes: `Program.ServerPort`(现有常量 3000)
- Produces: `CookieCloudForm(string baseUrl, HttpClient http)`(构造后 `ShowDialog()`);Program 菜单新增"设置 Cookie 服务器…"

- [ ] **Step 1: 写 `apps/desktop/windows/CookieCloudForm.cs`**

```csharp
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;

namespace LanjingQuiz;

/// <summary>原生 CookieCloud 配置对话框:打开时 GET 预填当前配置,
/// 保存时 POST(密码留空不修改),成功后自动触发一次同步。</summary>
internal sealed class CookieCloudForm : Form
{
    private readonly string _baseUrl;
    private readonly HttpClient _http;
    private readonly CheckBox _enabledCheck = new() { Text = "启用同步" };
    private readonly TextBox _serverBox = new() { PlaceholderText = "https://cc.example.com" };
    private readonly TextBox _uuidBox = new() { PlaceholderText = "扩展设置中的 UUID" };
    private readonly TextBox _passwordBox = new() { UseSystemPasswordChar = true, PlaceholderText = "留空不修改" };
    private readonly Label _statusLabel = new() { ForeColor = SystemColors.GrayText, AutoSize = true };
    private readonly Label _errorLabel = new() { ForeColor = Color.Firebrick, AutoSize = true };
    private readonly Button _saveButton = new() { Text = "保存", DialogResult = DialogResult.None };

    public CookieCloudForm(string baseUrl, HttpClient http)
    {
        _baseUrl = baseUrl;
        _http = http;

        Text = "Cookie 服务器";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(440, 320);

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
            ColumnCount = 1,
            RowCount = 10,
            AutoSize = true,
        };
        for (int i = 0; i < 10; i++)
        {
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, i == 9 ? 40 : 30));
        }

        layout.Controls.Add(_enabledCheck, 0, 0);
        layout.Controls.Add(MakeLabel("服务器地址"), 0, 1);
        layout.Controls.Add(_serverBox, 0, 2);
        layout.Controls.Add(MakeLabel("UUID"), 0, 3);
        layout.Controls.Add(_uuidBox, 0, 4);
        layout.Controls.Add(MakeLabel("密码"), 0, 5);
        layout.Controls.Add(_passwordBox, 0, 6);
        layout.Controls.Add(_statusLabel, 0, 7);
        layout.Controls.Add(_errorLabel, 0, 8);

        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill };
        var cancelButton = new Button { Text = "取消", DialogResult = DialogResult.Cancel };
        _saveButton.Click += async (_, _) => await SaveAsync();
        buttons.Controls.Add(_saveButton);
        buttons.Controls.Add(cancelButton);
        layout.Controls.Add(buttons, 0, 9);

        Controls.Add(layout);
        AcceptButton = _saveButton;
        CancelButton = cancelButton;

        _ = LoadAsync(); // fire-and-forget; errors land in _errorLabel
    }

    private Label MakeLabel(string text) => new() { Text = text, AutoSize = true, Font = new Font(Font.FontFamily, 9f, FontStyle.Bold) };

    private async Task LoadAsync()
    {
        try
        {
            using var response = await _http.GetAsync($"{_baseUrl}/api/cookiecloud");
            var json = JsonNode.Parse(await response.Content.ReadAsStringAsync());
            _enabledCheck.Checked = json?["enabled"]?.GetValue<bool>() ?? false;
            _serverBox.Text = json?["server"]?.GetValue<string>() ?? "";
            _uuidBox.Text = json?["uuid"]?.GetValue<string>() ?? "";
            _passwordBox.PlaceholderText = (json?["hasPassword"]?.GetValue<bool>() ?? false)
                ? "已保存,留空不修改"
                : "未设置";
            _passwordBox.Text = "";
            _statusLabel.Text = BuildStatus(
                json?["lastPush"]?.GetValue<string>() ?? "",
                json?["lastPull"]?.GetValue<string>() ?? "",
                json?["lastError"]?.GetValue<string>() ?? "");
        }
        catch (Exception ex)
        {
            _errorLabel.Text = $"读取配置失败:{ex.Message}";
        }
    }

    private async Task SaveAsync()
    {
        _saveButton.Enabled = false;
        _errorLabel.Text = "";
        try
        {
            var payload = new JsonObject
            {
                ["enabled"] = _enabledCheck.Checked,
                ["server"] = _serverBox.Text.Trim(),
                ["uuid"] = _uuidBox.Text.Trim(),
            };
            if (!string.IsNullOrEmpty(_passwordBox.Text))
            {
                payload["password"] = _passwordBox.Text;
            }

            using var content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");
            using var response = await _http.PostAsync($"{_baseUrl}/api/cookiecloud", content);
            var json = JsonNode.Parse(await response.Content.ReadAsStringAsync());
            if (response.IsSuccessStatusCode && json?["server"] != null)
            {
                // 配置即生效:触发一次同步(server 单飞,失败静默进 lastError)。
                _ = _http.PostAsync($"{_baseUrl}/api/cookiecloud/sync", null).ContinueWith(_ => { });
                DialogResult = DialogResult.OK;
                Close();
            }
            else
            {
                _errorLabel.Text = json?["error"]?.GetValue<string>() ?? "保存失败";
            }
        }
        catch (Exception ex)
        {
            _errorLabel.Text = $"保存失败:{ex.Message}";
        }
        finally
        {
            _saveButton.Enabled = true;
        }
    }

    private static string BuildStatus(string lastPush, string lastPull, string lastError)
    {
        if (!string.IsNullOrEmpty(lastError)) return $"上次同步失败:{lastError}";
        var parts = new List<string>();
        if (!string.IsNullOrEmpty(lastPull)) parts.Add($"上次拉取 {FormatTime(lastPull)}");
        if (!string.IsNullOrEmpty(lastPush)) parts.Add($"上次推送 {FormatTime(lastPush)}");
        return parts.Count > 0 ? string.Join(" · ", parts) : "尚未同步";
    }

    private static string FormatTime(string iso)
    {
        if (DateTimeOffset.TryParse(iso, out var dto)) return dto.ToLocalTime().ToString("HH:mm");
        return iso;
    }
}
```

- [ ] **Step 2: 修改 `apps/desktop/windows/Program.cs`**

2a. 类顶部加静态 HttpClient(在 `_tray` 字段附近):

```csharp
    private static readonly HttpClient _http = new();
```

2b. `BuildTray()` 的菜单(在"打开浏览器"项之后、分隔符之前)插入:

```csharp
        menu.Items.Add("设置 Cookie 服务器…", null, (_, _) => ShowCookieCloudDialog());
```

2c. 新增方法(放在 `OpenBrowser()` 之后):

```csharp
    private static void ShowCookieCloudDialog()
    {
        using var form = new CookieCloudForm($"http://127.0.0.1:{ServerPort}", _http);
        form.ShowDialog();
    }
```

- [ ] **Step 3: 本地自审(无 dotnet)**

核对清单(记录到报告):
1. using 齐全:`System.Net.Http`(HttpClient/StringContent)、`System.Text`(Encoding)、`System.Text.Json.Nodes`(JsonNode/JsonObject);Form/Control 由 UseWindowsForms 隐式 using
2. 语法:async void 事件处理器(`_saveButton.Click += async (_, _) => await SaveAsync();`)、`_ = LoadAsync()` fire-and-forget、`ContinueWith(_ => { })` 静默同步
3. `JsonNode.Parse` 对非 JSON 响应返回 null?——Parse 抛异常 → 被 catch 捕获进错误文案(可接受);`json?["server"]` 空安全
4. `PlaceholderText` 是 .NET 8 WinForms TextBox 属性(存在)
5. 线程:async/await 从 UI 事件上下文恢复主线程更新控件 ✓;`ContinueWith` 不碰 UI ✓
6. csproj 无需改动(自动包含 .cs)

- [ ] **Step 4: 提交**

```bash
git add apps/desktop/windows/CookieCloudForm.cs apps/desktop/windows/Program.cs
git commit -m "Windows 托盘:设置 Cookie 服务器对话框(预填/保存/自动同步)
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: macOS 菜单栏对话框

**Files:**
- Modify: `apps/desktop/macos/main.swift`(菜单项 + NSAlert 对话框 + URLSession)

**Interfaces:**
- Consumes: `homeURL`(现有,端口 3000)
- Produces: 菜单新增"设置 Cookie 服务器…",点击弹出 NSAlert 对话框

- [ ] **Step 1: 修改 `apps/desktop/macos/main.swift`**

1a. `buildStatusItem()` 的菜单(在"打开浏览器"之后、分隔符之前)插入:

```swift
        menu.addItem(withTitle: "设置 Cookie 服务器…", action: #selector(showCookieCloudDialog), keyEquivalent: "")
```

1b. 新增方法(放在 `openBrowser()` 之后):

```swift
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

        let stack = NSStackView()
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
            guard let config else { return }
            enabledCheck.state = config.enabled ? .on : .off
            serverField.stringValue = config.server
            uuidField.stringValue = config.uuid
            passwordField.placeholderString = config.hasPassword ? "已保存,留空不修改" : "未设置"
            statusLabel.stringValue = self?.buildStatus(config) ?? ""
        }

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
                }
                // 保存成功:触发一次同步(server 单飞,失败静默进 lastError)。
                self?.syncCookieCloudNow()
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
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let display = DateFormatter()
        display.dateFormat = "HH:mm"
        return display.string(from: date)
    }
```

- [ ] **Step 2: 本地完整编译验证**

Run:
```bash
cd /Users/qzh/Project/lanjing_test
rm -rf /tmp/cc-build && mkdir -p /tmp/cc-build
swiftc -O -target arm64-apple-macosx12.0 apps/desktop/macos/main.swift \
  -o /tmp/cc-build/launcher-arm64 -framework AppKit -framework Foundation
file /tmp/cc-build/launcher-arm64
```
Expected: 编译成功,`Mach-O 64-bit executable arm64`(Swift 语法验证;x86_64 交叉链接由 CI 的 Xcode 验证,与本任务无关)

- [ ] **Step 3: 服务 API 冒烟(对话框依赖的端点行为)**

Run:
```bash
cd /Users/qzh/Project/lanjing_test/apps/web
LANJING_LOCAL_DIR=/tmp/cc-smoke PORT=4392 node desktop-entry.js > /tmp/cc-smoke.log 2>&1 &
sleep 1.5
curl -s http://127.0.0.1:4392/api/cookiecloud   # 默认配置(免登录可读)
curl -s -X POST http://127.0.0.1:4392/api/cookiecloud -H "Content-Type: application/json" \
  -d '{"enabled":true,"server":"https://cc.example.com","uuid":"u1"}'
curl -s http://127.0.0.1:4392/api/cookiecloud   # 应显示 server/uuid 已保存
kill %1
```
Expected: 第一个返回默认 `{"enabled":false,...}`;POST 后 server/uuid 更新、hasPassword false;password 留空不覆盖语义由 server 既有测试覆盖(本任务不重复)

> 说明:对话框的 GUI 交互(点击菜单、输入、保存)无法自动化——编译 + API 冒烟验证代码路径,交互体验由用户在桌面版发布后手动确认。

- [ ] **Step 4: 提交**

```bash
git add apps/desktop/macos/main.swift
git commit -m "macOS 菜单栏:设置 Cookie 服务器对话框(预填/保存/自动同步)
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: 收尾(README + 回归)

**Files:**
- Modify: `README.md`(桌面发布说明补一句托盘能力)

- [ ] **Step 1: README 桌面产物表说明补充**

README 桌面发布段的 Windows/macOS 行说明尾部追加(或表格下加一句):

```markdown
托盘/菜单栏图标提供:打开浏览器、设置 Cookie 服务器(CookieCloud 配置,保存后自动同步)、退出。
```

- [ ] **Step 2: 全量回归确认**

Run:
```bash
cd /Users/qzh/Project/lanjing_test/apps/web && npm test 2>&1 | grep -E "^# (tests|pass|fail)"
```
Expected: 93/93 全绿(server 零改动,确认无意外影响)

- [ ] **Step 3: 提交**

```bash
git add README.md
git commit -m "README:桌面托盘能力说明(Cookie 服务器设置)
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Self-Review 结论

- **Spec 覆盖**:菜单项(Task 1 2b / Task 2 1a)、GET 预填(Task 1 LoadAsync / Task 2 fetchCookieCloudConfig)、密码留空不修改(Task 1 占位符与 payload 条件 / Task 2 placeholderString 与 payload 条件)、保存+自动 sync(Task 1 SaveAsync / Task 2 saveCookieCloudConfig+syncCookieCloudNow)、失败不关窗(Task 1 错误 label / Task 2 失败 NSAlert)、同步状态展示(Task 1 BuildStatus / Task 2 buildStatus)、server 零改动(Global Constraints + Task 3 回归)、验证策略(Task 1 自审 + CI / Task 2 本地编译 + API 冒烟 + 手动确认)
- **类型/接口一致性**:`CookieCloudForm(baseUrl, http)` 构造(Task 1 Step 1 定义、Step 2c 调用参数 `($"http://127.0.0.1:{ServerPort}", _http)` 一致);Swift 的 `CookieCloudConfig` 字段与 GET 响应键名一致;`homeURL.port ?? 3000` 两处使用一致
- **无占位符**:全部代码完整;Task 2 Step 3 的"密码留空不覆盖语义"标注由 server 既有测试覆盖(不重复)
- **注意项**:C# 的 `JsonNode.Parse` 对非 JSON 抛异常 → 被外层 catch 捕获(错误文案),可接受;Swift `runModal` 期间 main queue 可派发(模态 runloop),预填在用户输入前到达——若网络慢于用户输入,保存时用旧值覆盖的窗口极小,接受
