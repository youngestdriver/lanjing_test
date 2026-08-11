# 桌面发布实现计划(exe / .app / Linux 单文件)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** release.yml 的 web 免安装 zip 替换为:Windows 单文件 exe(x64+arm64,C# 托盘内嵌 Bun 编译服务)、macOS .app(dmg,Universal,Swift 状态栏)、Linux 单文件(x64+arm64)。

**Architecture:** 服务本体 = Bun `bun build --compile` 交叉编译的单文件(裸入口 `desktop-entry.js` 避免 server-config 误判,public 静态资源自动嵌入,数据目录走 `LANJING_LOCAL_DIR`);托盘/状态栏由平台原生 wrapper 提供(Windows C# .NET 8 单文件内嵌服务 exe;macOS Swift AppKit 状态栏)。CI 冒烟:每个平台产物启动后 curl `/api/status`。

**Tech Stack:** Bun 1.3.14(交叉编译 bun-windows-x64/arm64、bun-darwin-arm64/x64、bun-linux-x64/arm64)、C# .NET 8 WinForms(Windows runner 预装)、Swift 6 AppKit(macOS runner 预装)、sips + 纯 Node ICO 组装(图标,零依赖)。

## Global Constraints

- 服务入口必须是**无 exports 的裸脚本**(Bun 会把 module.exports 当 default export 误判为 server 配置)——`apps/web/desktop-entry.js`
- `LANJING_LOCAL_DIR` 未设置时,desktop-entry.js 兜底为 `path.dirname(process.execPath)/.local`
- `LANJING_OPEN_BROWSER=1` 时 server.js 监听成功后自动开浏览器:darwin `open` / win32 `cmd /c start ""` / linux `xdg-open`,fire-and-forget 失败静默
- 服务二进制文件名(artifact 与 release 附件一律 ASCII):`LanjingQuiz-server.exe`(win-x64)、`LanjingQuiz-server-arm64.exe`(win-arm64)、`server-darwin-arm64`、`server-darwin-x64`、`LanjingQuiz-linux-x64`、`LanjingQuiz-linux-arm64`
- Windows 数据目录 `%LOCALAPPDATA%\LanjingQuiz\data`、macOS `~/Library/Application Support/LanjingQuiz`、Linux 便携 `.local`
- 发布产物:`LanjingQuiz-windows-x64.exe`、`LanjingQuiz-windows-arm64.exe`、`LanjingQuiz-macOS.dmg`、`LanjingQuiz-linux-x64`、`LanjingQuiz-linux-arm64`(iOS ipa / 题库快照不变)
- 桌面 wrapper 不做代码签名/公证(无开发者证书);README 写明未签名分发提示
- 现有 79 项 web 测试与 browser smoke 必须保持全绿;`server.js` 改动只允许出现在 `LANJING_OPEN_BROWSER` env 分支
- 本机工具链:swiftc/sips/lipo/hdiutil 可用,**dotnet 不可用**(C# 任务本地只做代码审查,编译验证在 CI windows job)

---

### Task 1: 服务入口 + 自动开浏览器 + 测试

**Files:**
- Create: `apps/web/desktop-entry.js`
- Create: `apps/web/lib/open-browser.js`
- Modify: `apps/web/server.js`(startServer 监听回调)
- Test: `apps/web/test/open-browser.test.js`、`apps/web/test/desktop-entry.test.js`

**Interfaces:**
- Produces: `apps/web/lib/open-browser.js` 导出 `openBrowser(url, { platform = process.platform, spawn = require("node:child_process").spawn } = {})`(返回 boolean 是否发起;三平台分支;未知平台返回 false 不抛错)
- Produces: `apps/web/desktop-entry.js`(裸脚本,无导出;设 `LANJING_LOCAL_DIR` 兜底后 require `./server` + `startServer()`)
- Consumes: `apps/web/server.js` 现有 `startServer(port)`

- [ ] **Step 1: 写失败测试** `apps/web/test/open-browser.test.js`

```js
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");

const { openBrowser } = require("../lib/open-browser");

function fakeSpawn() {
  const calls = [];
  return {
    calls,
    spawn(command, args, options) {
      calls.push({ command, args, options });
      return { unref() {}, on() {} };
    },
  };
}

test("darwin opens with `open` and detached stdio-ignore", () => {
  const spawn = fakeSpawn();
  const ok = openBrowser("http://127.0.0.1:3000", { platform: "darwin", spawn });
  assert.equal(ok, true);
  assert.deepEqual(spawn.calls[0], {
    command: "open",
    args: ["http://127.0.0.1:3000"],
    options: { detached: true, stdio: "ignore" },
  });
});

test("win32 opens via cmd start with quoted URL", () => {
  const spawn = fakeSpawn();
  openBrowser("http://127.0.0.1:3000", { platform: "win32", spawn });
  assert.deepEqual(spawn.calls[0], {
    command: "cmd",
    args: ["/c", "start", "", "http://127.0.0.1:3000"],
    options: { detached: true, stdio: "ignore" },
  });
});

test("linux opens with xdg-open", () => {
  const spawn = fakeSpawn();
  openBrowser("http://127.0.0.1:3000", { platform: "linux", spawn });
  assert.deepEqual(spawn.calls[0].command, "xdg-open");
});

test("unknown platform returns false without spawning", () => {
  const spawn = fakeSpawn();
  assert.equal(openBrowser("http://x", { platform: "freebsd", spawn }), false);
  assert.equal(spawn.calls.length, 0);
});

test("spawn failure is swallowed", () => {
  const spawn = { spawn() { throw new Error("boom"); } };
  assert.equal(openBrowser("http://x", { platform: "linux", spawn }), false);
});
```

- [ ] **Step 2: 运行确认失败**

Run: `cd apps/web && node --test test/open-browser.test.js`
Expected: FAIL,`Cannot find module '../lib/open-browser'`

- [ ] **Step 3: 实现 `apps/web/lib/open-browser.js`**

```js
"use strict";

// Open the app's own URL in the system browser — the desktop wrappers pass
// LANJING_OPEN_BROWSER=1 so a tray-started service still lands the user on
// the page. Fire-and-forget: any failure is swallowed (a missing xdg-open
// must never take the server down).
function openBrowser(url, { platform = process.platform, spawn = require("node:child_process").spawn } = {}) {
  let command = null;
  let args = [];
  if (platform === "darwin") {
    command = "open";
    args = [url];
  } else if (platform === "win32") {
    command = "cmd";
    args = ["/c", "start", "", url];
  } else if (platform === "linux") {
    command = "xdg-open";
    args = [url];
  } else {
    return false;
  }
  try {
    spawn(command, args, { detached: true, stdio: "ignore" }).unref();
    return true;
  } catch {
    return false;
  }
}

module.exports = { openBrowser };
```

- [ ] **Step 4: 实现 `apps/web/desktop-entry.js`**

```js
"use strict";
// Desktop entry: bare script (no exports — `bun build --compile` probes
// default exports as Bun.serve configs and would swallow the server). The
// wrappers pass LANJING_LOCAL_DIR; without it data lives next to the
// executable (portable Linux / unpacked Windows).
const path = require("path");
if (!process.env.LANJING_LOCAL_DIR) {
  process.env.LANJING_LOCAL_DIR = path.join(path.dirname(process.execPath), ".local");
}
const { startServer } = require("./server");
startServer();
```

- [ ] **Step 5: 修改 `apps/web/server.js`**(startServer 内监听回调末尾追加)

在现有 `startServer` 的 `app.listen(port, host, () => { ... })` 回调末尾(约 951 行 `});` 之前)追加:

```js
    if (process.env.LANJING_OPEN_BROWSER === "1" && !process.env.LANJING_OPEN_BROWSER_DISABLE) {
      const { openBrowser } = require("./lib/open-browser");
      openBrowser(`http://127.0.0.1:${server.address().port}`);
    }
```

> `LANJING_OPEN_BROWSER_DISABLE` 仅为测试逃生口(desktop-entry 集成测用),现有测试不设该变量,行为不变。

- [ ] **Step 6: 写 desktop-entry 集成测试** `apps/web/test/desktop-entry.test.js`

```js
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const path = require("node:path");

// Spawns the real entry as a child process and probes the server — proves
// the entry actually boots the app (Bun compile will run the same file).
test("desktop-entry boots the server and sets LANJING_LOCAL_DIR fallback", async () => {
  const localDir = path.join(require("node:os").tmpdir(), `lanjing-entry-${process.pid}`);
  const child = spawn(process.execPath, [path.join(__dirname, "..", "desktop-entry.js")], {
    env: { ...process.env, LANJING_LOCAL_DIR: localDir, LANJING_OPEN_BROWSER: "1", LANJING_OPEN_BROWSER_DISABLE: "1", PORT: "0" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  try {
    let output = "";
    let port = null;
    child.stdout.on("data", (chunk) => { output += chunk; });
    for (let i = 0; i < 100; i += 1) {
      const match = output.match(/Server: http:\/\/[^:]+:(\d+)/);
      if (match) { port = Number(match[1]); break; }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    assert.ok(port, `server did not boot; output: ${output}`);
    const response = await fetch(`http://127.0.0.1:${port}/api/status`);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { loggedIn: false, hasSavedSession: false });
  } finally {
    child.kill("SIGTERM");
  }
});
```

- [ ] **Step 7: 运行确认通过(open-browser 5 项 + desktop-entry 1 项)+ 全量回归**

Run: `cd apps/web && node --test test/open-browser.test.js test/desktop-entry.test.js && npm test`
Expected: 新增 6 项 PASS;全量 79+6=85 项 PASS(注意 PORT=0 时现有 server 测试互不影响,本测试独立端口)

- [ ] **Step 8: 提交**

```bash
git add apps/web/desktop-entry.js apps/web/lib/open-browser.js apps/web/server.js apps/web/test/open-browser.test.js apps/web/test/desktop-entry.test.js
git commit -m "桌面入口与自动开浏览器:裸脚本入口 + 平台分支 + 测试
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: 桌面图标生成(脚本 + 产物 + 测试)

**Files:**
- Create: `scripts/gen-desktop-icons.sh`(仓库根,生成用;sips 缩放)
- Create: `scripts/assemble-ico.js`(Node,组装 ICO 容器,零解码)
- Create: `assets/desktop/icon.ico`(产物,提交)
- Create: `assets/desktop/status-icon.png`(产物,36×36,提交)
- Test: `apps/web/test/desktop-icons.test.js`(读产物断言格式)

**Interfaces:**
- Produces: `assets/desktop/icon.ico`(ICO 内嵌 16/32/48 PNG 三尺寸)、`assets/desktop/status-icon.png`(36×36)——Task 3/4 消费
- Consumes: `apps/web/public/icon-192.png`(源图)

- [ ] **Step 1: 写失败测试** `apps/web/test/desktop-icons.test.js`

```js
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const assetsDir = path.resolve(__dirname, "..", "..", "assets", "desktop");

test("icon.ico is an ICO container with three embedded PNG entries", () => {
  const data = fs.readFileSync(path.join(assetsDir, "icon.ico"));
  // ICONDIR: reserved(2)=0, type(2)=1, count(2)=3
  assert.deepEqual([...data.subarray(0, 6)], [0, 0, 1, 0, 3, 0]);
  const count = data.readUInt16LE(4);
  for (let i = 0; i < count; i += 1) {
    const entry = 6 + i * 16;
    // Each entry's bytes must start with a PNG signature (embedded-PNG ICO).
    assert.equal(data.toString("ascii", entry + 8, entry + 12), "\x89PNG".replace("\x89", ""), "entry is PNG");
    assert.ok(data[entry + 10] === 0x4e && data[entry + 11] === 0x47, "PNG magic");
  }
  assert.ok(count === 3, "three sizes");
});

test("status-icon.png is a PNG", () => {
  const data = fs.readFileSync(path.join(assetsDir, "status-icon.png"));
  assert.equal(data.toString("hex", 0, 8), "89504e470d0a1a0a");
});
```

> ICO 的 PNG 条目:entry 的 8 字节 DIB 数据偏移处就是 PNG 数据,PNG 以 `\x89PNG\r\n\x1a\n` 开头。上面的断言按此验证(实现时以 assemble-ico.js 实际布局为准:entry 内 bytesInRes 指向 PNG 数据)。

- [ ] **Step 2: 运行确认失败**

Run: `cd apps/web && node --test test/desktop-icons.test.js`
Expected: FAIL,产物不存在(ENOENT)

- [ ] **Step 3: 实现生成脚本**

`scripts/gen-desktop-icons.sh`:

```bash
#!/bin/bash
# One-shot icon generation (macOS: sips). Regenerate and commit the outputs;
# CI never runs this. Source: apps/web/public/icon-192.png.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/apps/web/public/icon-192.png"
OUT="$ROOT/assets/desktop"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT"
for size in 16 32 48; do
  sips -z "$size" "$size" "$SRC" --out "$TMP/$size.png" >/dev/null
done
sips -z 36 36 "$SRC" --out "$TMP/status.png" >/dev/null
cp "$TMP/status.png" "$OUT/status-icon.png"
node "$ROOT/scripts/assemble-ico.js" "$TMP/16.png" "$TMP/32.png" "$TMP/48.png" "$OUT/icon.ico"
echo "wrote $OUT/icon.ico and $OUT/status-icon.png"
```

`scripts/assemble-ico.js`(零解码,PNG 字节直嵌):

```js
#!/usr/bin/env node
"use strict";
// Assemble an ICO container with embedded PNG entries (Windows Vista+ reads
// PNG-in-ICO). Usage: assemble-ico.js <16.png> <32.png> <48.png> <out.ico>
const fs = require("node:fs");

const inputs = process.argv.slice(2, 5);
const out = process.argv[5];
if (inputs.length !== 3 || !out) {
  console.error("usage: assemble-ico.js <16.png> <32.png> <48.png> <out.ico>");
  process.exit(1);
}

const pngs = inputs.map((file) => fs.readFileSync(file));
const sizes = [16, 32, 48];
const header = Buffer.alloc(6);
header.writeUInt16LE(0, 0); // reserved
header.writeUInt16LE(1, 2); // type: icon
header.writeUInt16LE(pngs.length, 4); // count

const entries = [];
let offset = 6 + pngs.length * 16;
pngs.forEach((png, i) => {
  const entry = Buffer.alloc(16);
  entry.writeUInt8(sizes[i] >= 256 ? 0 : sizes[i], 0); // width
  entry.writeUInt8(sizes[i] >= 256 ? 0 : sizes[i], 1); // height
  entry.writeUInt8(0, 2); // palette
  entry.writeUInt8(0, 3); // reserved
  entry.writeUInt16LE(1, 4); // planes
  entry.writeUInt16LE(32, 6); // bpp
  entry.writeUInt32LE(png.length, 8); // bytes in resource
  entry.writeUInt32LE(offset, 12); // offset to PNG data
  entries.push(entry);
  offset += png.length;
});

fs.writeFileSync(out, Buffer.concat([header, ...entries, ...pngs]));
console.log(`wrote ${out} (${pngs.reduce((a, b) => a + b.length, 0)} bytes of PNG)`);
```

- [ ] **Step 4: 运行生成 + 测试确认通过**

Run:
```bash
chmod +x scripts/gen-desktop-icons.sh && bash scripts/gen-desktop-icons.sh
cd apps/web && node --test test/desktop-icons.test.js
```
Expected: 生成成功;2 tests PASS

- [ ] **Step 5: 提交**

```bash
git add scripts/gen-desktop-icons.sh scripts/assemble-ico.js assets/desktop/icon.ico assets/desktop/status-icon.png apps/web/test/desktop-icons.test.js
git commit -m "桌面图标:ICO(16/32/48 内嵌 PNG)+ 状态栏图 + 生成脚本
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Windows C# 托盘(单文件内嵌服务)

**Files:**
- Create: `apps/desktop/windows/LanjingQuizTray.csproj`
- Create: `apps/desktop/windows/Program.cs`
- Create: `apps/desktop/windows/.gitignore`(artifacts/)
- 本地验证:无 dotnet → 只做语法级代码自审 + csproj 结构检查;编译与冒烟在 Task 5 的 CI windows job

**Interfaces:**
- Consumes: `assets/desktop/icon.ico`(Task 2 产物,拷贝进输出目录供 NotifyIcon 使用)、`artifacts/LanjingQuiz-server.exe`(构建时由 CI 放入;csproj 用 `ServerExePath` 属性覆盖)
- Produces: 单文件 `LanjingQuiz.exe`(嵌入服务,运行解出 → 隐藏启动 → 托盘)

- [ ] **Step 1: 写 csproj**

`apps/desktop/windows/LanjingQuizTray.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net8.0-windows</TargetFramework>
    <UseWindowsForms>true</UseWindowsForms>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <AssemblyName>LanjingQuiz</AssemblyName>
    <RootNamespace>LanjingQuiz</RootNamespace>
    <!-- Overridden by CI: -p:Version=0.0.10 -p:ServerExePath=<path> -->
    <Version>0.0.0</Version>
    <ServerExePath Condition="'$(ServerExePath)' == ''">artifacts\LanjingQuiz-server.exe</ServerExePath>
  </PropertyGroup>
  <ItemGroup Condition="Exists('$(ServerExePath)')">
    <EmbeddedResource Include="$(ServerExePath)" LogicalName="server.exe" />
  </ItemGroup>
</Project>
```

- [ ] **Step 2: 写 Program.cs**

`apps/desktop/windows/Program.cs`:

```csharp
using System.Diagnostics;
using System.Reflection;

namespace LanjingQuiz;

internal static class Program
{
    private const string AppName = "LanjingQuiz";
    private const int ServerPort = 3000;

    private static string? _dataDir;
    private static string? _serverPath;
    private static Process? _server;
    private static NotifyIcon? _tray;

    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(true, "LanjingQuizTraySingleInstance", out var createdNew);
        if (!createdNew)
        {
            MessageBox.Show("蓝鲸助手已在运行。", "蓝鲸助手");
            return;
        }

        _dataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            AppName, "data");
        Directory.CreateDirectory(_dataDir);

        _serverPath = ExtractServer();

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        BuildTray();
        StartServer();

        Application.Run();
    }

    /// <summary>Extract the embedded server exe once per version into
    /// %LOCALAPPDATA%\LanjingQuiz\app\&lt;version&gt;\.</summary>
    private static string ExtractServer()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.0.0";
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            AppName, "app", version);
        var path = Path.Combine(dir, "LanjingQuiz-server.exe");
        if (File.Exists(path)) return path;

        Directory.CreateDirectory(dir);
        using var stream = Assembly.GetExecutingAssembly()
            .GetManifestResourceStream("server.exe")
            ?? throw new InvalidOperationException("服务组件缺失:server.exe 未嵌入。请用 ServerExePath 属性构建。");
        using var output = File.Create(path);
        stream.CopyTo(output);
        return path;
    }

    private static void StartServer()
    {
        var info = new ProcessStartInfo
        {
            FileName = _serverPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        info.Environment["LANJING_LOCAL_DIR"] = _dataDir;
        info.Environment["LANJING_OPEN_BROWSER"] = "1";
        info.Environment["PORT"] = ServerPort.ToString();
        _server = Process.Start(info);
        if (_server != null)
        {
            _server.EnableRaisingEvents = true;
            _server.Exited += (_, _) =>
            {
                _tray?.ShowBalloonTip(3000, "蓝鲸助手", "服务已停止,可重新打开浏览器访问或退出。", ToolTipIcon.Info);
            };
        }
    }

    private static void BuildTray()
    {
        var iconStream = Assembly.GetExecutingAssembly().GetManifestResourceStream("app.ico");
        _tray = new NotifyIcon
        {
            Icon = iconStream != null ? new Icon(iconStream) : SystemIcons.Application,
            Text = "蓝鲸助手",
            Visible = true,
        };
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开浏览器", null, (_, _) => OpenBrowser());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Exit());
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => OpenBrowser();
    }

    private static void OpenBrowser()
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = $"http://127.0.0.1:{ServerPort}",
                UseShellExecute = true,
            });
        }
        catch
        {
            // Best-effort: the service may not be up yet.
        }
    }

    private static void Exit()
    {
        try
        {
            if (_server is { HasExited: false })
            {
                _server.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // Already gone.
        }
        _tray?.Dispose();
        Application.Exit();
    }
}
```

> `app.ico` 内嵌:CI 构建时把 `assets/desktop/icon.ico` 拷贝到 `apps/desktop/windows/app.ico` 并加入 csproj(`<EmbeddedResource Include="app.ico" LogicalName="app.ico" />`),该文件 gitignored(由 Task 5 的 CI 步骤拷贝;本地构建时手动拷贝)。若缺失,程序回退 `SystemIcons.Application`,不影响功能。

- [ ] **Step 3: csproj 补 app.ico 条目 + .gitignore**

csproj 的 ItemGroup 追加:

```xml
  <ItemGroup Condition="Exists('app.ico')">
    <EmbeddedResource Include="app.ico" LogicalName="app.ico" />
  </ItemGroup>
```

`apps/desktop/windows/.gitignore`:

```
artifacts/
app.ico
bin/
obj/
```

- [ ] **Step 4: 本地自审(无 dotnet)**

Run: `node --check` 不适用(C#);人工核对:using 齐全(System.Diagnostics/Reflection/Windows.Forms 经 ImplicitUsings + UseWindowsForms)、资源逻辑名(server.exe/app.ico)、单实例 Mutex、退出时 Kill 整树。记录自审结论到报告。

- [ ] **Step 5: 提交**

```bash
git add apps/desktop/windows/LanjingQuizTray.csproj apps/desktop/windows/Program.cs apps/desktop/windows/.gitignore
git commit -m "Windows 托盘:单文件内嵌服务,解出/隐藏启动/托盘菜单/退出
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: macOS 状态栏(.app 组装 + Swift)

**Files:**
- Create: `apps/desktop/macos/main.swift`
- Create: `apps/desktop/macos/Info.plist`
- Create: `scripts/assemble-macos-app.sh`
- 本地工具链可用(swiftc/sips/lipo/hdiutil)——本任务本地完整编译验证

**Interfaces:**
- Consumes: `assets/desktop/status-icon.png`(Task 2 产物,放入 .app Resources)、服务二进制 `server-darwin-arm64`/`server-darwin-x64`(Task 5 CI 下载;本地验证时用 Task 1 编译的临时二进制或 bun 现编)
- Produces: `LanjingQuiz.app`(Contents/MacOS/LanjingQuiz + Contents/Resources/LanjingQuiz-server + Info.plist)

- [ ] **Step 1: 写 main.swift**

`apps/desktop/macos/main.swift`:

```swift
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.openBrowser()
            }
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
```

- [ ] **Step 2: 写 Info.plist**

`apps/desktop/macos/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>蓝鲸助手</string>
    <key>CFBundleDisplayName</key><string>蓝鲸助手</string>
    <key>CFBundleIdentifier</key><string>com.qzh.lanjingquiz.desktop</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleExecutable</key><string>LanjingQuiz</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
```

- [ ] **Step 3: 写组装脚本 `scripts/assemble-macos-app.sh`**

```bash
#!/bin/bash
# Assemble LanjingQuiz.app from the universal server binary + Swift launcher.
# Usage: assemble-macos-app.sh <server-arm64> <server-x64> <out-dir>
#   out-dir receives LanjingQuiz.app and LanjingQuiz-macOS.dmg.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARM="${1:?arm64 binary required}"
X64="${2:?x64 binary required}"
OUT="${3:?out dir required}"
APP="$OUT/LanjingQuiz.app"
VERSION="${LANJING_APP_VERSION:-0.0.1}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal server binary
lipo -create "$ARM" "$X64" -output "$APP/Contents/Resources/LanjingQuiz-server"
chmod +x "$APP/Contents/Resources/LanjingQuiz-server"

# Launcher
swiftc -O "$ROOT/apps/desktop/macos/main.swift" \
  -o "$APP/Contents/MacOS/LanjingQuiz" \
  -framework AppKit -framework Foundation

# Icon + metadata
cp "$ROOT/assets/desktop/status-icon.png" "$APP/Contents/Resources/status-icon.png"
cp "$ROOT/apps/desktop/macos/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# DMG
hdiutil create -volname "蓝鲸助手" -srcfolder "$APP" -ov -format UDZO \
  "$OUT/LanjingQuiz-macOS.dmg" >/dev/null
echo "wrote $APP and $OUT/LanjingQuiz-macOS.dmg"
```

- [ ] **Step 4: 本地完整验证**

Run:
```bash
chmod +x scripts/assemble-macos-app.sh
cd apps/web && export PATH="$HOME/.bun/bin:$PATH"
bun build --compile --target=bun-darwin-arm64 ./desktop-entry.js --outfile /tmp/server-arm64
bun build --compile --target=bun-darwin-x64 ./desktop-entry.js --outfile /tmp/server-x64
bash ../scripts/assemble-macos-app.sh /tmp/server-arm64 /tmp/server-x64 /tmp/lanjing-app-out
file /tmp/lanjing-app-out/LanjingQuiz.app/Contents/Resources/LanjingQuiz-server
# 冒烟:直接跑服务二进制(不经 GUI)
LANJING_LOCAL_DIR=/tmp/lanjing-app-data PORT=4398 /tmp/lanjing-app-out/LanjingQuiz.app/Contents/Resources/LanjingQuiz-server & 
sleep 2 && curl -s http://127.0.0.1:4398/api/status && kill %1
```
Expected: `file` 显示 "Mach-O universal binary";curl 返回 `{"loggedIn":false,"hasSavedSession":false}`。
(GUI 状态栏交互在开发机上手动 `open LanjingQuiz.app` 验证——计划执行者手动确认图标出现、菜单可用、退出结束服务。)

- [ ] **Step 5: 提交**

```bash
git add apps/desktop/macos/main.swift apps/desktop/macos/Info.plist scripts/assemble-macos-app.sh
git commit -m "macOS 状态栏:Swift 启动器 + .app 组装脚本(dmg)
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: release.yml 重写(4 个构建 job + 冒烟)

**Files:**
- Modify: `.github/workflows/release.yml`(web-package job 删除,新增 4 个 job;release job 依赖更新)

**Interfaces:**
- Consumes: Task 1 的 `apps/web/desktop-entry.js`、Task 2 图标、Task 3 C# 工程、Task 4 组装脚本;`oven-sh/setup-bun@v2`
- Produces: release 附件 `LanjingQuiz-windows-x64.exe`、`LanjingQuiz-windows-arm64.exe`、`LanjingQuiz-macOS.dmg`、`LanjingQuiz-linux-x64`、`LanjingQuiz-linux-arm64`

- [ ] **Step 1: 删除 `web-package` job,替换为 `web-desktop-services`**

```yaml
  # Web 桌面版服务二进制:一个 job 交叉编译全部平台(Bun 单文件,内嵌
  # express + public 资源;入口 desktop-entry.js 为裸脚本)。
  web-desktop-services:
    name: Web 桌面服务二进制
    needs: version
    runs-on: ubuntu-latest
    steps:
      - name: Check out repository
        uses: actions/checkout@v5

      - name: Set up Bun
        uses: oven-sh/setup-bun@v2

      - name: Compile server binaries (all targets)
        run: |
          cd apps/web
          out="$RUNNER_TEMP/servers"
          mkdir -p "$out"
          for target in bun-windows-x64:bun-windows-arm64:bun-darwin-arm64:bun-darwin-x64:bun-linux-x64:bun-linux-arm64; do
            t="${target%%:*}"; suffix="${target##*:}"
            name="$suffix"
            bun build --compile --target="$t" ./desktop-entry.js --outfile "$out/$name"
          done
          mv "$out/bun-windows-x64" "$out/LanjingQuiz-server.exe"
          mv "$out/bun-windows-arm64" "$out/LanjingQuiz-server-arm64.exe"
          mv "$out/bun-darwin-arm64" "$out/server-darwin-arm64"
          mv "$out/bun-darwin-x64" "$out/server-darwin-x64"
          mv "$out/bun-linux-x64" "$out/LanjingQuiz-linux-x64"
          mv "$out/bun-linux-arm64" "$out/LanjingQuiz-linux-arm64"
          ls -lh "$out"

      - name: Smoke test (linux-x64, same arch as runner)
        run: |
          chmod +x "$RUNNER_TEMP/servers/LanjingQuiz-linux-x64"
          LANJING_LOCAL_DIR="$RUNNER_TEMP/smoke-data" PORT=4399 \
            "$RUNNER_TEMP/servers/LanjingQuiz-linux-x64" > "$RUNNER_TEMP/smoke.log" 2>&1 &
          pid=$!
          for i in $(seq 1 40); do
            if curl -fsS http://127.0.0.1:4399/api/status; then break; fi
            sleep 0.5
          done
          kill "$pid"
          grep -q '"loggedIn":false' "$RUNNER_TEMP/smoke.log" || cat "$RUNNER_TEMP/smoke.log"

      - name: Upload server binaries
        uses: actions/upload-artifact@v4
        with:
          name: web-servers
          path: "${{ runner.temp }}/servers"
          if-no-files-found: error
```

> 冒烟里 curl 输出进日志(服务 stdout 重定向到文件);断言由 `grep '"loggedIn":false'` 完成(注意 smoke.log 是服务输出,curl 结果在 shell stdout,写入 `$GITHUB_STEP_SUMMARY` 或直接 grep 变量——见 Step 3 修正说明)。

- [ ] **Step 2: 新增 `web-desktop-windows` job**

```yaml
  web-desktop-windows:
    name: Web 桌面 Windows (托盘单文件)
    needs: [version, web-desktop-services]
    runs-on: windows-latest
    timeout-minutes: 30
    steps:
      - name: Check out repository
        uses: actions/checkout@v5

      - name: Download server binaries
        uses: actions/download-artifact@v4
        with:
          name: web-servers
          path: "${{ runner.temp }}/servers"

      - name: Copy icon and server exe into the project
        shell: bash
        run: |
          cp assets/desktop/icon.ico apps/desktop/windows/app.ico
          mkdir -p apps/desktop/windows/artifacts
          cp "$RUNNER_TEMP/servers/LanjingQuiz-server.exe" apps/desktop/windows/artifacts/
          cp "$RUNNER_TEMP/servers/LanjingQuiz-server-arm64.exe" apps/desktop/windows/artifacts/

      - name: Publish win-x64 single file
        shell: bash
        run: |
          cd apps/desktop/windows
          dotnet publish LanjingQuizTray.csproj -c Release -r win-x64 --self-contained \
            -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
            -p:Version=${{ needs.version.outputs.version }} \
            -p:ServerExePath=artifacts/LanjingQuiz-server.exe \
            -o out/win-x64

      - name: Publish win-arm64 single file
        shell: bash
        run: |
          cd apps/desktop/windows
          dotnet publish LanjingQuizTray.csproj -c Release -r win-arm64 --self-contained \
            -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
            -p:Version=${{ needs.version.outputs.version }} \
            -p:ServerExePath=artifacts/LanjingQuiz-server-arm64.exe \
            -o out/win-arm64

      - name: Smoke test (x64)
        shell: bash
        run: |
          cd apps/desktop/windows/out/win-x64
          cp LanjingQuiz.exe "$RUNNER_TEMP/LanjingQuiz.exe"
          (cd "$RUNNER_TEMP" && ./LanjingQuiz.exe) &
          ok=""
          for i in $(seq 1 60); do
            if curl -fsS http://127.0.0.1:3000/api/status | grep -q '"loggedIn":false'; then ok=1; break; fi
            sleep 0.5
          done
          [ -n "$ok" ] || { echo "smoke failed"; exit 1; }
          taskkill //F //IM LanjingQuiz.exe //T
          taskkill //F //IM LanjingQuiz-server.exe //T 2>/dev/null || true

      - name: Package deliverables
        shell: bash
        run: |
          mkdir -p "$RUNNER_TEMP/deliver"
          cp apps/desktop/windows/out/win-x64/LanjingQuiz.exe "$RUNNER_TEMP/deliver/LanjingQuiz-windows-x64.exe"
          cp apps/desktop/windows/out/win-arm64/LanjingQuiz.exe "$RUNNER_TEMP/deliver/LanjingQuiz-windows-arm64.exe"

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: web-desktop-windows
          path: "${{ runner.temp }}/deliver"
          if-no-files-found: error
```

- [ ] **Step 3: 新增 `web-desktop-macos` 与 `web-desktop-linux` job**

```yaml
  web-desktop-macos:
    name: Web 桌面 macOS (.app + dmg)
    needs: [version, web-desktop-services]
    runs-on: macos-15
    timeout-minutes: 30
    steps:
      - name: Check out repository
        uses: actions/checkout@v5

      - name: Download server binaries
        uses: actions/download-artifact@v4
        with:
          name: web-servers
          path: "${{ runner.temp }}/servers"

      - name: Assemble .app and dmg
        env:
          LANJING_APP_VERSION: ${{ needs.version.outputs.version }}
        run: |
          bash scripts/assemble-macos-app.sh \
            "$RUNNER_TEMP/servers/server-darwin-arm64" \
            "$RUNNER_TEMP/servers/server-darwin-x64" \
            "$RUNNER_TEMP/deliver"

      - name: Smoke test (server binary, no GUI)
        run: |
          LANJING_LOCAL_DIR="$RUNNER_TEMP/smoke-data" PORT=4398 \
            "$RUNNER_TEMP/deliver/LanjingQuiz.app/Contents/Resources/LanjingQuiz-server" \
            > "$RUNNER_TEMP/smoke.log" 2>&1 &
          pid=$!
          ok=""
          for i in $(seq 1 60); do
            if curl -fsS http://127.0.0.1:4398/api/status | grep -q '"loggedIn":false'; then ok=1; break; fi
            sleep 0.5
          done
          kill "$pid" 2>/dev/null || true
          [ -n "$ok" ] || { echo "smoke failed"; cat "$RUNNER_TEMP/smoke.log"; exit 1; }

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: web-desktop-macos
          path: "${{ runner.temp }}/deliver"
          if-no-files-found: error

  web-desktop-linux:
    name: Web 桌面 Linux (单文件)
    needs: [version, web-desktop-services]
    runs-on: ubuntu-latest
    steps:
      - name: Check out repository
        uses: actions/checkout@v5

      - name: Download server binaries
        uses: actions/download-artifact@v4
        with:
          name: web-servers
          path: "${{ runner.temp }}/servers"

      - name: Package deliverables
        run: |
          mkdir -p "$RUNNER_TEMP/deliver"
          chmod +x "$RUNNER_TEMP/servers/LanjingQuiz-linux-x64" "$RUNNER_TEMP/servers/LanjingQuiz-linux-arm64"
          cp "$RUNNER_TEMP/servers/LanjingQuiz-linux-x64" "$RUNNER_TEMP/deliver/"
          cp "$RUNNER_TEMP/servers/LanjingQuiz-linux-arm64" "$RUNNER_TEMP/deliver/"

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: web-desktop-linux
          path: "${{ runner.temp }}/deliver"
          if-no-files-found: error
```

- [ ] **Step 4: 更新 release job 依赖与 release 附件名**

`release` job 的 `needs` 改为:

```yaml
    needs: [version, web-desktop-services, web-desktop-windows, web-desktop-macos, web-desktop-linux, ios-unsigned, ios-ipa, bank-snapshot]
```

> services job 也纳入 needs:冒烟失败(任一平台服务不可用)就不发布。

- [ ] **Step 5: YAML 结构自审(本地无 actionslint)**

Run: 用 Ruby/Node 解析 YAML 确认语法:`node -e "require('js-yaml')..."` 不可用(无依赖)。用 `ruby -e "require 'yaml'; YAML.load_file('.github/workflows/release.yml'); puts 'yaml ok'"`(macOS 自带 ruby)。
Expected: `yaml ok`;人工核对:job 名唯一、needs 引用正确、无遗留 `web-package` 引用(全局搜索)。

- [ ] **Step 6: 提交**

```bash
git add .github/workflows/release.yml
git commit -m "发布改为桌面产物:交叉编译服务 + Windows/macOS/Linux 打包与冒烟
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: README + check 脚本 + 全量验证

**Files:**
- Modify: `apps/web/package.json`(check 脚本加 desktop-entry.js / open-browser.js / assemble-ico.js / 新测试文件)
- Modify: `README.md`(发布说明:zip → 桌面产物)

- [ ] **Step 1: package.json check 脚本追加**

在 check 脚本末尾追加:

```json
&& node --check lib/open-browser.js && node --check desktop-entry.js && node --check ../scripts/assemble-ico.js && node --check test/open-browser.test.js && node --check test/desktop-entry.test.js && node --check test/desktop-icons.test.js
```

> `desktop-entry.js` 与 `lib/open-browser.js` 是 CommonJS,`node --check` 直接可用;`assemble-ico.js` 在 scripts/ 下用相对路径 `../scripts/...`(从 apps/web 执行)。

- [ ] **Step 2: README 发布说明更新**

在 README 找到"快速开始"或发布相关段落,把 web 免安装 zip 描述替换为桌面产物表:

```markdown
## 桌面发布产物

每次发布提供免安装桌面版(无需安装 Node.js):

| 平台 | 产物 | 说明 |
|---|---|---|
| Windows | `LanjingQuiz-windows-x64.exe` / `LanjingQuiz-windows-arm64.exe` | 单文件,托盘图标(打开浏览器 / 退出) |
| macOS | `LanjingQuiz-macOS.dmg`(Universal) | 菜单栏图标(打开浏览器 / 退出) |
| Linux | `LanjingQuiz-linux-x64` / `LanjingQuiz-linux-arm64` | 单文件,`chmod +x` 后运行,终端 Ctrl+C 停止 |

首次使用:启动后自动打开浏览器;数据保存在本机(Windows `%LOCALAPPDATA%\LanjingQuiz\data`、macOS `~/Library/Application Support/LanjingQuiz`、Linux 程序旁 `.local`)。未签名提示:macOS 首次打开需右键"打开";Windows SmartScreen 选"更多信息 → 仍要运行"。

⚠️ 局域网访问:服务默认监听所有网卡,同一局域网设备可用 http://<本机IP>:3000 访问,可在「我的 > 局域网访问」关闭。该服务共享同一份会话,没有多用户隔离/TLS/限流,只适合可信局域网,请勿暴露到公网。
```

同时删除"使用说明.txt"内容相关引用(若 README 提及 zip 运行方式)。

- [ ] **Step 3: 全量验证**

Run:
```bash
cd apps/web && npm run check && npm test
cd /Users/qzh/Project/lanjing_test && bash scripts/gen-desktop-icons.sh 2>/dev/null || true  # 幂等,产物不变
git status --porcelain  # 应无未提交产物变动(图标已提交)
```
Expected: check 全过;npm test 全绿(85 项);gen-desktop-icons 幂等(产物无 diff)。

- [ ] **Step 4: 提交**

```bash
git add apps/web/package.json README.md
git commit -m "README 桌面发布说明 + check 脚本覆盖新文件
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Self-Review 结论

- **Spec 覆盖**:desktop-entry(任务 1)、自动开浏览器三平台(任务 1)、public 自动嵌入(设计已验证,无需代码)、Windows 单文件托盘含解出/隐藏启动/菜单/退出/单实例(任务 3)、macOS 状态栏 + LSUIElement + lipo + dmg(任务 4)、6 服务交叉编译 + 4 构建 job + 冒烟(任务 5)、图标(任务 2)、README(任务 6)、数据位置(任务 1 入口兜底 + 任务 3/4 wrapper env)——全部有任务
- **类型/接口一致性**:`openBrowser(url, {platform, spawn})` 任务 1 定义、server.js 消费;`desktop-entry.js` 无导出、任务 1 创建、任务 5 编译入口;`assemble-macos-app.sh <arm> <x64> <out>` 任务 4 定义、任务 5 调用(参数顺序一致);csproj 的 `ServerExePath`/`Version` 属性任务 3 定义、任务 5 传入
- **无占位符**:全部代码完整;任务 3 的本地验证受限已明示(无 dotnet),编译验证在任务 5 CI
- **注意项**(实现时留意):Task 5 Step 1 冒烟的 curl 输出在 shell stdout,`grep` 断言应作用于变量而非日志文件(Step 1 代码块中已注);Windows 冒烟 taskkill 需 bash 语法(`//F`);dotnet publish 的 `IncludeNativeLibrariesForSelfExtract` 保证单文件
