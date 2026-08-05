# 蓝鲸答题助手

[![CI](https://github.com/youngestdriver/lanjing_test/actions/workflows/ci.yml/badge.svg)](https://github.com/youngestdriver/lanjing_test/actions/workflows/ci.yml)

面向蓝鲸微课考试流程的第三方学习客户端。本仓库按应用维护 Web/PWA 与原生 iOS 两套独立实现。两端现已覆盖同一组核心考试流程，但仍拥有各自的网络层、会话存储、界面代码和测试体系，不共享运行时或业务实现。

> [!IMPORTANT]
> 本项目会把进入考试、提交答案、标记题目和交卷等操作发送到上游服务，可能直接改变账号中的真实考试记录。只应在获得授权的账号和场景中使用，不要把它用于违规答题、未授权访问或公开服务。

## 项目组成

| 客户端 | 定位 | 代码位置 | 运行方式 | 会话存储 |
|---|---|---|---|---|
| 原生 iOS | SwiftUI 原生客户端 | `apps/ios/` | Xcode 构建并安装到模拟器或设备 | iOS Keychain |
| Web / PWA | 响应式浏览器客户端与本地代理 | `apps/web/` | 浏览器访问本地 Express 服务 | Node 进程内存与 `apps/web/.local/` |

两套客户端的网络路径不同：

```text
浏览器 / PWA ──> 本地 Express API ──> https://test.lanjingweike.com

原生 iOS ────────────────────────> https://test.lanjingweike.com
```

Web 版必须启动 `apps/web/server.js`。iOS 版直接访问上游，不依赖 Node.js，也不需要同时运行 Web 服务。

## 功能

两端都覆盖登录、会话恢复、考试列表、开始或继续考试、逐题作答、题目标记、答题卡、交卷和结果展示。Web 的核心答题行为已与 iOS 对齐，但平台交互和自动化范围仍有差异：

| 能力 | Web / PWA | 原生 iOS |
|---|---|---|
| 客户端形态 | 响应式单页应用、可安装 PWA，无前端构建步骤 | SwiftUI 原生应用，支持 iPhone 与 iPad |
| 登录后首页 | “考试列表 / 练习 / 我的”三个一级入口；桌面为左侧导航，移动端为底部导航 | “考试列表 / 练习 / 我的”三个原生 `TabView` 入口 |
| 单选题 | 点击选项后立即判定并提交 | 点击选项后立即判定并提交 |
| 多选题 | 选择多个选项后确认，按完整集合判定并上报 | 选择多个选项后确认，按完整集合判定并上报 |
| 历史作答 | 恢复状态及用户之前选择的选项 | 恢复状态及用户之前选择的选项 |
| 自动切题 | 用户可配置，默认关闭；手动导航会取消待执行跳转 | 用户可配置，默认关闭；手动导航会取消待执行跳转 |
| 列表与失败恢复 | 主动刷新、空态、加载重试及放弃考试后的陈旧记录抑制 | 下拉刷新、空态、加载重试及放弃考试后的陈旧记录抑制 |
| 答案上报失败 | 保留本地选择、显示未同步状态并允许重试 | 统一处理会话失效；其他上报失败暂不提供重试 UI |
| 会话持久化 | 进程级全局 Cookie，写入权限为 `0600` 的本地文件 | Cookie 存入 Keychain，会话失效时统一清理并返回登录页 |
| 自动化验证 | 20 项 Node 单元测试；真实 Chrome + mock API 的浏览器回归；无真实上游 E2E | 8 个 XCTest 套件、56 项单元测试；尚无 UI、真机或真实上游 E2E |

Web 与 iOS 登录后都以“考试列表 / 练习 / 我的”组织一级导航；主题、自动下一题和退出登录集中在“我的”。Web 额外提供桌面浏览器入口、响应式布局、触控和键盘答题以及可安装的 PWA 应用壳，iOS 提供原生分页手势、iPad 键盘导航、原生富文本容器和系统级会话存储。两端的“练习”页目前都只是返回考试列表的入口，不是独立练习题库。

## 快速开始

### Web / PWA

环境要求：

- Node.js 22 或更高版本
- 能访问上游测试服务的网络环境

从仓库根目录安装锁定版本的依赖并启动：

```bash
npm --prefix apps/web ci
npm --prefix apps/web start
```

浏览器打开：

```text
http://127.0.0.1:3000
```

可通过 `PORT` 修改端口：

```bash
PORT=43127 npm --prefix apps/web start
```

默认只监听 `127.0.0.1`。需要让局域网内其他设备访问时，用 `HOST` 指定绑定地址（`0.0.0.0` 绑定所有网卡）：

```bash
HOST=0.0.0.0 npm --prefix apps/web start
```

服务会打印本机可用的局域网访问地址（如 `http://192.168.1.5:3000`）并提示风险；`TRUSTED_HOSTS`（逗号分隔）可额外允许指定主机名，如 `TRUSTED_HOSTS=my-mac.local`。

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
> Web 后端使用进程级全局 Cookie 和缓存，只适合本机单用户运行。服务默认仅监听 `127.0.0.1`，并拒绝非白名单 Host、跨源和非 JSON 的写请求，但仍没有多用户会话隔离、TLS、CSRF token 或限流。设置 `HOST` 开启局域网监听后，同一局域网的设备都会共享这份会话，请只在可信网络使用，不要通过反向代理把它暴露到公网，也不要共享 `apps/web/.local/` 和包含会话信息的终端日志。

### 原生 iOS

环境要求：

- macOS
- Xcode 16 或更高版本
- iOS 17 或更高版本的模拟器，或者配置了签名团队的真机

打开已提交的工程：

```bash
open apps/ios/LanjingQuiz.xcodeproj
```

在 Xcode 中选择共享的 `LanjingQuiz` scheme 和目标设备，然后 Build & Run。模拟器构建不需要签名；真机运行需要在 Signing & Capabilities 中选择有效的 Development Team。

日常开发不要求安装 XcodeGen。只有主动修改 `apps/ios/project.yml` 并准备重新生成工程时，才需要执行：

```bash
cd apps/ios
xcodegen generate
```

生成后必须检查 Git diff，确认 `project.yml` 与已提交的 `.xcodeproj` 变化符合预期。当前 CI 直接使用已提交工程，不负责验证两者完全一致。

完整的构建说明、用户流程和 iOS 架构见 [apps/ios/README.md](apps/ios/README.md)。

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
| `POST` | `/api/logout` | 清除本地会话 |

`enter`、`answer`、`mark` 和 `submit` 都可能改变上游状态。其中 `submit` 会结束当前考试，前端的“放弃考试”也使用这条提交路径，不是单纯删除本地记录。

请求、响应、错误处理和上游映射详见 [docs/web-api.md](docs/web-api.md)。

## 项目结构

```text
.
├── .github/workflows/ci.yml        # Node 与 iOS 持续集成
├── apps/
│   ├── ios/
│   │   ├── LanjingQuiz.xcodeproj/  # 已提交的 Xcode 工程与共享 scheme
│   │   ├── LanjingQuiz/            # SwiftUI 应用源码
│   │   ├── LanjingQuizTests/       # XCTest 单元测试
│   │   ├── project.yml             # XcodeGen 工程定义
│   │   └── README.md               # iOS 详细文档
│   └── web/
│       ├── lib/parsers.js          # 考试页、成绩页与会话解析器
│       ├── public/
│       │   ├── js/                 # 浏览器应用与可测试答题逻辑
│       │   ├── index.html          # 单页应用结构
│       │   ├── styles.css
│       │   └── sw.js               # Service Worker
│       ├── test/                   # Node 单元测试与浏览器回归
│       ├── tools/login-demo.js     # 敏感历史调试工具
│       ├── package.json
│       └── server.js               # 静态服务、会话和 API 代理
├── docs/web-api.md                 # 本地 API 与上游映射
└── README.md
```

## 验证与 CI

### Node

Web 使用 Node 内置测试框架验证解析器和答题纯逻辑，并通过本机 Chrome 验证完整浏览器交互。提交前运行：

```bash
npm --prefix apps/web ci
npm --prefix apps/web run check
npm --prefix apps/web test
npm --prefix apps/web run test:browser
```

当前 26 项单元与安全测试覆盖历史答案映射、考试页与成绩页解析、会话失效识别、多选集合判定、答案编码、下一未答题、陈旧考试抑制，以及本地 API 的 Host、Origin、JSON 写请求、登录重定向识别、退出登录、旧上游响应隔离和局域网模式下的 Host/`TRUSTED_HOSTS` 白名单。浏览器回归会启动本地服务和真实 Chrome，并完全拦截 `/api/*`：它验证三个首页入口及其深链接和浏览器历史、桌面侧栏与移动底栏、主题和自动切题设置持久化、真实退出入口、多选提交、历史答案恢复、同步失败重试、交卷与旧 `401` 响应的竞态隔离、成绩页终态、键盘和触控交互、PWA 应用壳预缓存与离线导航回退，以及桌面、390px、320px 和低高度横屏布局。两类测试都不访问真实上游；浏览器回归需要系统已安装 Google Chrome，或通过 `CHROME_PATH` 指定兼容的 Chromium 可执行文件。

启动服务后，还可按“快速开始”中的命令请求 `/api/status`；CI 会执行同样的无副作用 HTTP smoke test。

### iOS

当前 `LanjingQuizTests` 包含 8 个测试套件、56 个单元测试，覆盖答案映射、HTML 与结果解析、登录表单、会话失效、富文本、哈希和答题逻辑。

先查看当前 Xcode 可用的 destination：

```bash
xcodebuild \
  -project apps/ios/LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -showdestinations
```

再用其中一个可用模拟器运行测试：

```bash
xcodebuild \
  -project apps/ios/LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=<可用设备>' \
  -derivedDataPath /tmp/LanjingQuizDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

确认放弃考试或交卷会修改真实上游状态，不应把这些操作加入无人值守 smoke test。

### GitHub Actions

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) 在推送到 `main` 或创建目标为 `main` 的 PR 时运行：

- `Node`：Ubuntu、Node 22、依赖安装、JavaScript 语法检查、20 项单元与安全测试、mock API 浏览器回归和 `/api/status` smoke test
- `iOS`：macOS 15、Xcode 16.4、动态选择可用 iPhone 模拟器并运行测试

这些检查验证基础构建、单元测试和本地浏览器流程，不等同于真实账号、真实上游、真机、签名或归档验证。

## 开发流程

`main` 是唯一长期分支，并受分支保护：

1. 从最新 `main` 创建短期分支，例如 `feat/web-multi-select` 或 `fix/ios-session`。
2. 一个分支只处理一个明确变更。
3. 通过 Pull Request 合回 `main`。
4. 等待 `Node` 与 `iOS` CI 通过后再合并。
5. 合并后删除短期分支。

不要提交以下本地数据或产物：

- `apps/web/.local/`、账号凭据和调试日志
- `node_modules/`
- Xcode `xcuserdata/`、DerivedData 和本地构建目录
- `.ipa`、归档包和其他发布制品

iOS 安装包应通过受控的 Release、TestFlight 或 CI artifact 分发，而不是提交到 Git 历史。

## 安全与限制

- 上游地址目前固定为 `https://test.lanjingweike.com`，没有 `.env` 或运行时切换配置。
- PWA 只缓存应用壳和静态资源；登录、试卷、答题与结果流程都依赖网络和上游服务，不能离线答题。
- Web 后端会把上游 Cookie 明文保存到忽略跟踪的 `apps/web/.local/session_cookies.txt`；目录权限为 `0700`，文件权限为 `0600`，退出登录会删除该文件。
- iOS 仅在登录请求中使用账号凭据，并把会话 Cookie 存入 Keychain；退出或会话失效时会清理 Cookie。
- `apps/web/server.js` 的 Cookie 和考试缓存是进程级单例，因此不能作为多用户后端部署。
- Web 默认只监听 `127.0.0.1`。`HOST` 环境变量可改为绑定局域网地址（如 `0.0.0.0`），此时 Host/Origin 白名单自动包含本机所有非内部 IPv4 网卡地址，`TRUSTED_HOSTS` 可额外允许指定主机名；但共享会话、无 TLS 与限流等风险依旧，只应在可信网络使用。
- 上游接口和 HTML 结构不属于本仓库控制范围；页面、字段或认证流程变化都可能导致解析失败。
- `apps/web/tools/login-demo.js` 是历史调试工具，可能直接访问上游，不应作为普通启动命令或无人值守测试执行。

## 文档

- [本地 API 与上游映射](docs/web-api.md)
- [原生 iOS 构建、架构与验证](apps/ios/README.md)
- [持续集成配置](.github/workflows/ci.yml)

## 许可与免责声明

本仓库当前没有提供开源许可证。公开可见不代表自动授予复制、修改、分发或商业使用权。

本项目仅用于学习、研究和经授权的测试。使用者应自行确认账号权限、平台规则、当地法律和操作后果；维护者不对未授权使用、考试记录变更或由上游服务变化造成的损失负责。
