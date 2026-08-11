# 桌面发布:免安装 exe / .app / Linux 单文件(替代 web zip)

- 日期:2026-08-11
- 状态:已批准(用户确认方案 A:原生 wrapper + 严格单文件 + universal + Linux 单文件)
- 范围:apps/web(desktop-entry.js、server.js 小改)、apps/desktop/{windows,macos}、assets/desktop 图标、.github/workflows/release.yml、README

## 背景与目标

发布产物从"web 免安装 zip(需用户自装 Node.js)"改为各平台免安装可执行程序:

| 产物 | 形态 | 托盘 | 停止方式 |
|---|---|---|---|
| LanjingQuiz-windows-x64.exe | C# 单文件(嵌入服务) | ✅ 托盘图标 | 托盘"退出" |
| LanjingQuiz-windows-arm64.exe | 同上 | ✅ | 同上 |
| LanjingQuiz-macOS.dmg | .app Universal(arm64+x64) | ✅ 菜单栏图标 | 菜单"退出" |
| LanjingQuiz-linux-x64 / -arm64 | 单文件终端版 | 无(Linux 无统一托盘) | Ctrl+C |
| LanjingQuiz-unsigned-*.ipa | 保留不变 | — | — |
| 题库快照(可选) | 保留不变 | — | — |

## 关键技术验证(已实测)

- Bun `bun build --compile` 可将 server.js(express 5)打成单文件(62MB,145 模块),启动正常
- **入口必须是无 exports 的裸脚本**:server.js 的 `module.exports` 会被映射为 default export,被 Bun 误判为 server 配置入口(实测启动失败);专用入口 `desktop-entry.js`(require server + startServer)解决
- **public/ 静态资源自动嵌入**:编译时静态解析 `path.join(__dirname, "public")`,运行时从嵌入文件系统读取(实测 styles.css/index.html 200);写入嵌入路径不可行 → 数据目录必须显式指定
- 交叉编译:一个 job 产出 bun-windows-x64/arm64、bun-darwin-arm64/x64、bun-linux-x64/arm64
- `LANJING_LOCAL_DIR` 环境变量 server.js 已支持;`BANK_DIR` 缺失时 /bank 404(同 CI 行为)
- Bun 无 Tray API(实测 1.3.14 无 `Bun.Tray`)→ 托盘用平台原生 wrapper

## 组件设计

### 1. 服务入口 `apps/web/desktop-entry.js`(新)

```js
"use strict";
// Desktop entry: bare script (no exports — bun build --compile probes
// default exports as Bun.serve configs). Local data lives next to the
// executable unless the wrapper passes LANJING_LOCAL_DIR.
const path = require("path");
if (!process.env.LANJING_LOCAL_DIR) {
  process.env.LANJING_LOCAL_DIR = path.join(path.dirname(process.execPath), ".local");
}
const { startServer } = require("./server");
startServer();
```

### 2. `server.js` 小改:自动打开浏览器

`LANJING_OPEN_BROWSER=1` 时,监听成功后自动打开页面(异步 fire-and-forget,失败静默):

```js
// darwin: open http://127.0.0.1:3000
// win32:  start "" "http://127.0.0.1:3000" (via cmd /c)
// linux:  xdg-open http://127.0.0.1:3000
```

监听回调(现有 `startServer` 的 listen 回调)末尾追加;用 `child_process.spawn` 带 `{detached:true, stdio:"ignore"}` + `unref()`。

### 3. Windows 托盘 `apps/desktop/windows/`(C# .NET 8)

- `LanjingQuizTray.csproj`:服务 exe 作 `EmbeddedResource`;`dotnet publish -c Release -r win-x64|win-arm64 --self-contained /p:PublishSingleFile=true`
- 启动时把嵌入的服务 exe 解出到 `%LOCALAPPDATA%\LanjingQuiz\app\<version>\LanjingQuiz-server.exe`(按版本缓存,已存在跳过;版本来自程序集版本)
- `Process.Start` 隐藏窗口(`CreateNoWindow=true`、`WindowStyle=Hidden`)+ 环境变量 `LANJING_LOCAL_DIR=%LOCALAPPDATA%\LanjingQuiz\data`、`LANJING_OPEN_BROWSER=1`
- `NotifyIcon`(assets/desktop/icon.ico)+ 菜单:打开浏览器(`http://127.0.0.1:3000`)/ 退出(结束服务进程 + `Application.Exit`)
- 服务进程 `Exited` 事件 → 托盘气泡提示"服务已停止"
- 单实例:`Mutex` 防双开

### 4. macOS 状态栏 `apps/desktop/macos/`(Swift AppKit)

- `main.swift`:NSStatusItem + NSMenu(打开浏览器 `NSWorkspace.shared.open` / 退出);spawn `Resources/LanjingQuiz-server`;退出时 `terminate`
- `.app` 结构:`Contents/MacOS/LanjingQuiz`(swiftc 编译的 wrapper)+ `Contents/Resources/LanjingQuiz-server`(lipo universal)+ `Contents/Info.plist`(`LSUIElement=true` 无 Dock 图标)
- 环境:`LANJING_LOCAL_DIR=$HOME/Library/Application Support/LanjingQuiz`、`LANJING_OPEN_BROWSER=1`
- 编译:CI macos runner 直接 `swiftc main.swift -o wrapper -framework AppKit -framework Foundation`;`lipo -create arm64 x64`

### 5. 图标(提交仓库,一次性生成)

- `assets/desktop/icon.ico`(Windows 托盘,含 16/32/48)
- `assets/desktop/iconTemplate.png`(macOS 状态栏模板图,黑色 + alpha,约 18×18)
- 基于现有 `apps/web/public/icon-192.png` 视觉风格简单绘制/转换

## CI 改造(release.yml)

`web-package` job 重写为 4 个 job(`ios-unsigned`/`ios-ipa`/`bank-snapshot`/`release` 不变):

1. **web-desktop-services**(ubuntu-latest,`oven-sh/setup-bun` action):
   `bun build --compile --target=<t> apps/web/desktop-entry.js --outfile <name>`,6 个目标
   → upload artifacts(6 个服务二进制)
2. **web-desktop-windows**(windows-latest,needs services):
   dotnet publish x2(各自嵌入对应架构服务 exe)→ **冒烟**:启动 exe,`curl http://127.0.0.1:3000/api/status` 断言 200,结束进程 → upload
3. **web-desktop-macos**(macos-15,needs services):
   lipo universal → swiftc wrapper → 组装 .app → `hdiutil create` dmg → **冒烟**:直接运行 .app 内服务二进制 + curl 断言 → upload
4. **web-desktop-linux**(ubuntu-latest,needs services):
   两个服务二进制即为交付物 → **冒烟**:跑 linux-x64 二进制 + curl 断言 → upload
5. `release` job 增加新 artifact 依赖;删除 zip 打包/启动脚本/使用说明.txt(README 发布说明更新)

GitHub Actions 缓存:bun 安装走 setup-bun;dotnet SDK 在 windows runner 预装。

## 数据与安全

- 数据位置:Windows `%LOCALAPPDATA%\LanjingQuiz\data`;macOS `~/Library/Application Support/LanjingQuiz`;Linux 可执行文件旁 `.local`(便携,入口兜底)
- 未签名分发说明(README + release 说明):macOS 首次打开右键"打开";Windows SmartScreen"更多信息→仍要运行";Linux 需 `chmod +x`
- 局域网访问警告维持现有文案(共享会话无多用户隔离)

## 测试与验证

- server.js 改动仅在 `LANJING_OPEN_BROWSER` env 分支,现有 79 项单测不受影响;桌面入口 `desktop-entry.js` 加 `node --check` 到 check 脚本
- CI 冒烟覆盖每个平台产物(启动 + curl /api/status)
- 本地手动验证:构建全平台产物、Windows/macOS 托盘交互、Linux 终端运行
- README 发布说明替换 zip 描述

## 范围外(明确不做)

- 自动更新机制
- 代码签名/公证(无开发者证书;Windows 无签名、macOS 无 notarization)
- Linux 托盘/AppImage
- 服务端代码打包之外的任何功能改动
