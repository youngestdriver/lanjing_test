# 蓝鲸答题助手

[![CI](https://github.com/youngestdriver/lanjing_test/actions/workflows/ci.yml/badge.svg)](https://github.com/youngestdriver/lanjing_test/actions/workflows/ci.yml)

面向蓝鲸微课考试流程的第三方学习客户端。本仓库同时维护 Web/PWA 与原生 iOS 两套实现：它们提供相近的登录、试卷、答题和结果流程，但运行架构与会话存储彼此独立。

> [!IMPORTANT]
> 本项目会把进入考试、提交答案、标记题目和交卷等操作发送到上游服务，可能直接改变账号中的真实考试记录。只应在获得授权的账号和场景中使用，不要把它用于违规答题、未授权访问或公开服务。

## 项目组成

| 客户端 | 代码位置 | 运行方式 | 会话存储 |
|---|---|---|---|
| Web / PWA | `frontend/`、`server.js` | 浏览器访问本地 Express 服务 | Node 进程内存与根目录 `session_cookies.txt` |
| 原生 iOS | `ios/` | Xcode 构建并安装到模拟器或设备 | iOS Keychain |

两套客户端的网络路径不同：

```text
浏览器 / PWA ──> 本地 Express API ──> https://test.lanjingweike.com

原生 iOS ────────────────────────> https://test.lanjingweike.com
```

Web 版必须启动仓库根目录的 Node.js 服务。iOS 版直接访问上游，不依赖 `server.js`，也不需要同时运行 Web 服务。

## 功能

两套客户端共同覆盖：

- 手机号与密码登录、会话恢复和退出登录
- 按分类展示考试，支持开始新考试和继续已有记录
- 逐题作答、即时判定、答案解析和答题计时
- 题目标记、分区答题卡、正确/错误/未答状态统计
- 作答结果上报、题卡状态刷新、交卷与成绩解析
- 浅色和深色主题

平台相关能力：

| Web / PWA | 原生 iOS |
|---|---|
| 响应式桌面与移动布局 | SwiftUI 原生界面，支持 iPhone 与 iPad |
| Service Worker 与可安装 PWA；考试流程仍需联网 | Keychain 会话持久化 |
| 触控滑动与键盘答题 | iPad 键盘导航与原生分页手势 |
| 单击选项后立即提交并锁定当前题目 | 单选与多选确认，可配置答对后自动切题 |
| 浏览器端答题卡和主题存储 | 题干文本选择、原生答题卡和主题设置 |
| 无需前端构建步骤 | 原生考试列表、复用考试列表的练习入口和个人设置页 |

## 快速开始

### Web / PWA

环境要求：

- Node.js 18 或更高版本
- 能访问上游测试服务的网络环境

从仓库根目录安装锁定版本的依赖并启动：

```bash
npm ci
npm start
```

浏览器打开：

```text
http://localhost:3000
```

可通过 `PORT` 修改端口：

```bash
PORT=43127 npm start
```

服务启动后可以用无副作用的状态接口确认运行情况：

```bash
curl --fail http://127.0.0.1:3000/api/status
```

未登录时的正常响应为：

```json
{
  "loggedIn": false,
  "hasSavedSession": false
}
```

> [!WARNING]
> Web 后端使用进程级全局 Cookie 和缓存，只适合本机单用户运行。它没有多用户会话隔离、TLS、CSRF 防护或限流，并且当前监听地址不限定为 loopback。不要把端口暴露到局域网或公网，也不要共享 `session_cookies.txt` 和包含会话信息的终端日志。

### 原生 iOS

环境要求：

- macOS
- Xcode 16 或更高版本
- iOS 17 或更高版本的模拟器，或者配置了签名团队的真机

打开已提交的工程：

```bash
open ios/LanjingQuiz.xcodeproj
```

在 Xcode 中选择共享的 `LanjingQuiz` scheme 和目标设备，然后 Build & Run。模拟器构建不需要签名；真机运行需要在 Signing & Capabilities 中选择有效的 Development Team。

日常开发不要求安装 XcodeGen。只有主动修改 `ios/project.yml` 并准备重新生成工程时，才需要在 `ios/` 目录执行：

```bash
xcodegen generate
```

生成后必须检查 Git diff，确认 `project.yml` 与已提交的 `.xcodeproj` 变化符合预期。当前 CI 直接使用已提交工程，不负责验证两者完全一致。

完整的构建说明、用户流程和 iOS 架构见 [ios/README.md](ios/README.md)。

## 本地 API

Web 前端通过同源的 `/api` 路由访问本地 Express 代理：

| Method | Path | 作用 |
|---|---|---|
| `GET` | `/api/status` | 查询本地会话状态 |
| `POST` | `/api/login` | 访问上游登录并在本地保存会话 |
| `GET` | `/api/exams` | 从上游获取考试和练习列表 |
| `POST` | `/api/exams/:id/enter` | 开始或继续考试；可能创建真实作答记录 |
| `GET` | `/api/exams/:id/questions` | 获取题目、答案和题卡状态 |
| `POST` | `/api/exams/:id/answer` | 向上游写入真实答案 |
| `POST` | `/api/exams/:id/mark` | 更新上游题目标记 |
| `GET` | `/api/exams/:id/states` | 从上游刷新题卡状态 |
| `POST` | `/api/exams/:id/submit` | 结束真实考试并解析结果 |
| `GET` | `/api/logout` | 清除本地会话 |

`enter`、`answer`、`mark` 和 `submit` 都可能改变上游状态。其中 `submit` 会结束当前考试，前端的“放弃考试”也使用这条提交路径，不是单纯删除本地记录。

请求、响应、错误处理和上游映射详见 [API.md](API.md)。

## 项目结构

```text
.
├── .github/workflows/ci.yml       # Node 与 iOS 持续集成
├── frontend/
│   ├── index.html                 # 无构建步骤的单页应用
│   ├── manifest.json              # PWA manifest
│   └── sw.js                      # Service Worker
├── ios/
│   ├── LanjingQuiz.xcodeproj/     # 已提交的 Xcode 工程与共享 scheme
│   ├── LanjingQuiz/               # SwiftUI 应用源码
│   ├── LanjingQuizTests/          # XCTest 单元测试
│   ├── project.yml                # XcodeGen 工程定义
│   └── README.md                  # iOS 详细文档
├── API.md                         # 本地 API 与上游映射
├── server.js                      # 静态文件服务、会话和 API 代理
├── login_demo.js                  # 历史调试脚本，不是正常运行入口
├── package.json
└── README.md
```

## 验证与 CI

### Node

仓库没有完整的 Web E2E 测试。提交前至少应安装依赖并检查 JavaScript 语法：

```bash
npm ci
node --check server.js
node --check login_demo.js
node --check frontend/sw.js
```

启动服务后，再按“快速开始”中的命令请求 `/api/status`。CI 会自动执行同样的无上游副作用 smoke test。

### iOS

当前 `LanjingQuizTests` 包含 8 个测试套件、56 个单元测试，覆盖答案映射、HTML 与结果解析、登录表单、会话失效、富文本、哈希和答题逻辑。

先查看当前 Xcode 可用的 destination：

```bash
xcodebuild \
  -project ios/LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -showdestinations
```

再用其中一个可用模拟器运行测试：

```bash
xcodebuild \
  -project ios/LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=<可用设备>' \
  -derivedDataPath /tmp/LanjingQuizDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

确认放弃考试或交卷会修改真实上游状态，不应把这些操作加入无人值守 smoke test。

### GitHub Actions

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) 在推送到 `main` 或创建目标为 `main` 的 PR 时运行：

- `Node`：Ubuntu、Node 22、依赖安装、三个 JavaScript 语法检查和 `/api/status` smoke test
- `iOS`：macOS 15、Xcode 16.4、动态选择可用 iPhone 模拟器并运行测试

这些检查验证基础构建和单元测试，不等同于真实账号、真机、签名、归档或完整端到端验证。

## 开发流程

`main` 是唯一长期分支，并受分支保护：

1. 从最新 `main` 创建短期分支，例如 `feat/ios-timer` 或 `fix/web-session`。
2. 一个分支只处理一个明确变更。
3. 通过 Pull Request 合回 `main`。
4. 等待 `Node` 与 `iOS` CI 通过后再合并。
5. 合并后删除短期分支。

不要提交以下本地数据或产物：

- `session_cookies.txt`、账号凭据和调试日志
- `node_modules/`
- Xcode `xcuserdata/`、DerivedData 和本地构建目录
- `.ipa`、归档包和其他发布制品

iOS 安装包应通过受控的 Release、TestFlight 或 CI artifact 分发，而不是提交到 Git 历史。

## 安全与限制

- 上游地址目前固定为 `https://test.lanjingweike.com`，没有 `.env` 或运行时切换配置。
- PWA 只缓存应用壳和静态资源；登录、试卷、答题与结果流程都依赖网络和上游服务，不能离线答题。
- Web 后端会把上游 Cookie 明文保存到忽略跟踪的 `session_cookies.txt`；退出登录会删除该文件。
- iOS 仅在登录请求中使用账号凭据，并把会话 Cookie 存入 Keychain；退出或会话失效时会清理 Cookie。
- `server.js` 的 Cookie 和考试缓存是进程级单例，因此不能作为多用户后端部署。
- 上游接口和 HTML 结构不属于本仓库控制范围；页面、字段或认证流程变化都可能导致解析失败。
- `login_demo.js` 是历史调试工具，可能直接访问上游，不应作为普通启动命令或无人值守测试执行。

## 文档

- [本地 API 与上游映射](API.md)
- [原生 iOS 构建、架构与验证](ios/README.md)
- [持续集成配置](.github/workflows/ci.yml)

## 许可与免责声明

本仓库当前没有提供开源许可证。公开可见不代表自动授予复制、修改、分发或商业使用权。

本项目仅用于学习、研究和经授权的测试。使用者应自行确认账号权限、平台规则、当地法律和操作后果；维护者不对未授权使用、考试记录变更或由上游服务变化造成的损失负责。
