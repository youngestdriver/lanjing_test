# 蓝鲸答题助手

[![CI Web](https://github.com/youngestdriver/lanjing_test/actions/workflows/ci-web.yml/badge.svg)](https://github.com/youngestdriver/lanjing_test/actions/workflows/ci-web.yml)
[![CI iOS](https://github.com/youngestdriver/lanjing_test/actions/workflows/ci-ios.yml/badge.svg)](https://github.com/youngestdriver/lanjing_test/actions/workflows/ci-ios.yml)

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
| 云端会话同步 | 可选启用 CookieCloud 同步：登录后自动上传、启动时拉取、设置中手动同步（协议与官方扩展兼容） | 可选启用 CookieCloud 同步：登录后自动上传、启动时拉取、"我的"中手动同步（同一协议） |
| 自动化验证 | 78 项 Node 单元测试；真实 Chrome + mock API 的浏览器回归；无真实上游 E2E | 9 个 XCTest 套件、67 项单元测试；尚无 UI、真机或真实上游 E2E |

Web 与 iOS 登录后都以“考试列表 / 练习 / 我的”组织一级导航；主题、自动下一题、Cookie 云端同步和退出登录集中在“我的”，局域网访问开关仅 Web 提供。Web 额外提供桌面浏览器入口、响应式布局、触控和键盘答题以及可安装的 PWA 应用壳，iOS 提供原生分页手势、iPad 键盘导航、原生富文本容器和系统级会话存储。两端的“练习”页目前都只是返回考试列表的入口，不是独立练习题库。

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

服务默认绑定所有网卡接口（`0.0.0.0`），登录后可在"我的 > 局域网访问"关闭，或用 `HOST` 环境变量指定绑定地址（例如仅本机访问）：

```bash
HOST=127.0.0.1 npm --prefix apps/web start
```

启动时服务会打印本机可用的局域网访问地址（如 `http://192.168.1.5:3000`）并提示风险；`TRUSTED_HOSTS`（逗号分隔）可额外允许指定主机名，如 `TRUSTED_HOSTS=my-mac.local`。

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
> Web 后端使用进程级全局 Cookie 和缓存，只适合本机单用户运行。服务默认绑定所有网卡接口并允许局域网访问（可在"我的 > 局域网访问"关闭），同时拒绝非白名单 Host、跨源和非 JSON 的写请求，但仍没有多用户会话隔离、TLS、CSRF token 或限流。同一局域网的设备都会共享这份会话，请只在可信网络使用，不要通过反向代理把它暴露到公网，也不要共享 `apps/web/.local/` 和包含会话信息的终端日志。

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

签名团队通过环境变量注入，**不提交具体的 Team ID**（它是与开发者账号关联的个人信息，历史提交中出现过的 ID 不应继续出现在新提交中）：

```bash
DEVELOPMENT_TEAM=XXXXXX xcodegen generate
```

未设置时生成的工程不含团队 ID，模拟器构建和 CI（`CODE_SIGNING_ALLOWED=NO`）不受影响；真机运行前在 Xcode 的 Signing & Capabilities 中选择团队即可。另外，Xcode 打开工程时可能自动向 `.xcodeproj/project.pbxproj` 写回签名团队、格式规范化等本地改动——提交前用 `git status` 检查该文件，仅包含这类本地改动的差异应当丢弃（`git checkout -- apps/ios/LanjingQuiz.xcodeproj/project.pbxproj`），不要提交。

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

## 题库收集器

`apps/web/scripts/collect-bank.js` 是一个独立 CLI，把机考题库中的题目（题干、选项、正确答案、解析）逐份收集并去重保存，用于为后续功能准备本地题库。

上游平台的实际结构（已对真实服务验证）：每份机考卷（【言语理解（二）】机考题库 等）是**固定题池**——重新进入只会拿到同一批题，同类不同卷（一）（二）（三）之间题目互不重叠；分类写在**卷名**里（言语理解/数字运算/逻辑推理/资料分析/特有题型），卷内 section 是子题型（逻辑填空、图形推理、时政等）。因此收集 = 每份目标卷进入一次即可全量（目前共 14 份目标卷、约 3000 题）：进入 → 抓取 → 空答案提交放弃（或对用户进行中的卷只读收集）→ 下一份。

```text
node apps/web/scripts/collect-bank.js [--exam <id>] [--max-rounds N]
       [--idle-limit N] [--round-delay ms] [--bank-dir <path>]
       [--targets a,b,c] [--skip-in-progress]
```

| 选项 | 默认 | 作用 |
|---|---|---|
| `--exam <id>` | 全部 | 只收集指定考试（可强制处理 `wfs=0` 的进行中卷） |
| `--max-rounds N` | 200 | 最大轮数安全上限 |
| `--idle-limit N` | 3 | 连续 N 轮无新题即停止 |
| `--round-delay ms` | 1500 | 每轮间隔 |
| `--bank-dir <path>` | `.local/bank/` | 题库输出目录 |
| `--targets a,b,c` | 5 个机考分类 | 目标分类（按卷名子串匹配；可自行加"常识判断"等） |
| `--skip-in-progress` | 收集 | 跳过进行中的作答（默认只读收集用户进行中的卷，**不提交**） |

- 数据落盘在 `apps/web/.local/bank/`（已 gitignore）：每个目标分类一个 JSONL（`言语理解.jsonl` 等），外加 `meta.json` 记录轮次、各卷状态与统计；任意中断后重跑同一目录即可续接（去重按题目 `_id`，损坏尾行自动丢弃）。每条记录含 `_id`、`category`（分类）、`section`（子题型，已去掉"(共N题…)"后缀）、`question`、`options`（4 槽）、`answer`（单选字母/多选数组/兜底/`null`）、`analysis`（解析）、来源卷与轮次
- 会话复用本地保存的登录态；没有可用会话时在交互式终端提示输入手机号和密码，密码仅在运行时存在于内存，**绝不落盘**。后台无人值守运行可改用 `LANJING_PHONE` / `LANJING_PASSWORD` 环境变量提供凭据（同样只存在于进程内，不写入任何文件）
- ⚠️ 与 `enter`/`submit` 相关：收集器对 `wfs=1` 的卷每轮会创建一份空答案作答并立即放弃（消耗考试次数）；对 `wfs=0` 的卷（你自己的进行中作答）只读取题、绝不提交。机考卷的交卷接口返回 JSON 成功而非成绩页，收集器通过重拉考试列表验证 wfs 翻回判定放弃成功
- 停止条件：所有目标卷耗尽、连续 `--idle-limit` 轮无新题、轮数上限，或 Ctrl+C（完成当前轮后停止，数据已落盘）

## 项目结构

```text
.
├── .github/workflows/ci-web.yml    # Web 持续集成（路径检测 + 条件跳过）
├── .github/workflows/ci-ios.yml    # iOS 持续集成（路径检测 + 条件跳过）
├── apps/
│   ├── ios/
│   │   ├── LanjingQuiz.xcodeproj/  # 已提交的 Xcode 工程与共享 scheme
│   │   ├── LanjingQuiz/            # SwiftUI 应用源码
│   │   ├── LanjingQuizTests/       # XCTest 单元测试
│   │   ├── project.yml             # XcodeGen 工程定义
│   │   └── README.md               # iOS 详细文档
│   └── web/
│       ├── lib/parsers.js          # 考试页、成绩页与会话解析器
│       ├── lib/cookiecloud.js      # CookieCloud 加密协议与 cookie 转换（与官方扩展互操作）
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

当前 78 项单元与安全测试覆盖历史答案映射、考试页与成绩页解析、会话失效识别、多选集合判定、答案编码、下一未答题、陈旧考试抑制，本地 API 的 Host、Origin、JSON 写请求、登录重定向识别、退出登录、旧上游响应隔离、局域网默认绑定与 `TRUSTED_HOSTS` 白名单、局域网访问开关的即时生效与持久化，以及 CookieCloud 的两种加密算法与官方扩展互操作向量（crypto-js 参考实现 + openssl 交叉验证）、fail-closed 解密、cookie 转换与域名过滤、配置校验与密码掩码、拉取/推送/合并/去重语义、重启后配置持久化。题库收集器测试覆盖卷名分类匹配、section 清洗（去"(共N题…)"后缀）、题卡位置关联、记录 schema（单选/多选/兜底答案/填空）、考试选择策略（pendingSubmit 优先、目标卷过滤、`wfs=0` 只读收集、强制 `--exam`）、502 交卷验证（重拉列表判定 wfs 翻回）、"未创建的作答绝不提交"保护、跨轮去重与 resume、损坏尾行容错、空闲/上限/会话失效停止，以及真实服务器 + stub 上游的端到端收集（新卷流程、JSON 成功交卷、进行中卷只读收集、非目标卷不进入）。浏览器回归会启动本地服务和真实 Chrome，并完全拦截 `/api/*`：它验证三个首页入口及其深链接和浏览器历史、桌面侧栏与移动底栏、主题和自动切题设置持久化、CookieCloud 设置 UI（开关、输入框、警告文案与手动同步）、真实退出入口、多选提交、历史答案恢复、同步失败重试、交卷与旧 `401` 响应的竞态隔离、成绩页终态、键盘和触控交互、PWA 应用壳预缓存与离线导航回退，以及桌面、390px、320px 和低高度横屏布局。两类测试都不访问真实上游；浏览器回归需要系统已安装 Google Chrome，或通过 `CHROME_PATH` 指定兼容的 Chromium 可执行文件。

启动服务后，还可按“快速开始”中的命令请求 `/api/status`；CI 会执行同样的无副作用 HTTP smoke test。

### iOS

当前 `LanjingQuizTests` 包含 9 个测试套件、67 个单元测试，覆盖答案映射、HTML 与结果解析、登录表单、会话失效、富文本、哈希、答题逻辑，以及 CookieCloud 加密（与 Web 相同的互操作向量）与 cookie 转换。

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

持续集成拆分为两个 workflow，在推送到 `main` 或创建目标为 `main` 的 PR 时运行；每个 workflow 都会执行一个轻量的改动检测 job（`dorny/paths-filter`），与检测范围不匹配时实际构建 job 会被跳过：

- [`ci-web.yml`](.github/workflows/ci-web.yml)（`Node`）：当改动涉及 `apps/web/`、`docs/`、`README.md` 或该 workflow 自身时运行 Node job；Ubuntu、Node 22、依赖安装、JavaScript 语法检查、51 项单元与安全测试、mock API 浏览器回归和 `/api/status` smoke test
- [`ci-ios.yml`](.github/workflows/ci-ios.yml)（`iOS`）：当改动涉及 `apps/ios/` 或该 workflow 自身时运行 iOS job；macOS 15、Xcode 16.4、动态选择可用 iPhone 模拟器并运行测试

workflow 本身始终运行（而不是在事件级用 `paths` 过滤）：GitHub 只对**被跳过的 job** 自动放行 required check，对因路径过滤而从未运行的 workflow 不会放行——那样纯 Web 或纯 iOS 的 PR 会永远卡在分支保护上。不匹配任何检测范围时（例如仅修改 `.github/` 下其他文件）两个构建 job 都会被跳过，`Node` 与 `iOS` 检查自动通过。

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
- 主动退出登录（Web 的 `/api/logout` 与 iOS 的"退出登录"）会先调用上游 `POST /login/public/logout` 使会话失效（尽力而为，失败仍清本地），该会话在其他设备上随之失效；会话过期被动清理不会调用上游登出。
- `apps/web/server.js` 的 Cookie 和考试缓存是进程级单例，因此不能作为多用户后端部署。
- Web 默认绑定 `0.0.0.0`（所有网卡）并允许局域网访问；可在“我的 > 局域网访问”关闭，或用 `HOST` 环境变量指定绑定地址。开启时 Host/Origin 白名单包含本机所有非内部 IPv4 网卡地址，`TRUSTED_HOSTS` 可额外允许指定主机名；但共享会话、无 TLS 与限流等风险依旧，只应在可信网络使用。设置保存于 `apps/web/.local/settings.json`（权限 `0600`）。
- CookieCloud 同步（Web 与 iOS 均可选启用，协议与官方浏览器扩展兼容）：登录成功后自动上传会话，启动时拉取一次云端会话，也可在设置中手动同步；推送前会先拉取远端数据，合并保留其中所有非 lanjingweike 域名条目，避免覆盖扩展同步的其他站点 cookie。手动同步与启动拉取会**双向校验有效性**：云端与本地会话分别通过上游轻量接口探测（复用会话失效识别），只有有效的会话才会被应用或推送——过期的云端会话不会覆盖本地有效会话，反之本地无效会话也不会被传播。UUID 与密码需与浏览器扩展一致才能互通；加密在客户端完成（Web 用 Node 内置 crypto，iOS 用 CommonCrypto），服务端只保存密文，未知算法或解密失败一律不应用。Web 端密码保存在 `apps/web/.local/settings.json`（权限 `0600`），iOS 端存入 Keychain；`/api/cookiecloud` 等读取接口永不下发密码。退出登录不会清除云端 blob，其他设备保持登录。
- iOS 仅对本地网络放行明文 HTTP（`NSAllowsLocalNetworking`，配合 `NSLocalNetworkUsageDescription` 权限文案），不会放开任意 HTTP；Web 端到自建 CookieCloud 服务的请求限 http/https 且带 10 秒超时。
- 上游接口和 HTML 结构不属于本仓库控制范围；页面、字段或认证流程变化都可能导致解析失败。
- `apps/web/tools/login-demo.js` 是历史调试工具，可能直接访问上游，不应作为普通启动命令或无人值守测试执行。

## 文档

- [本地 API 与上游映射](docs/web-api.md)
- [原生 iOS 构建、架构与验证](apps/ios/README.md)
- [Web 持续集成](.github/workflows/ci-web.yml) 与 [iOS 持续集成](.github/workflows/ci-ios.yml)

## 许可与免责声明

本仓库当前没有提供开源许可证。公开可见不代表自动授予复制、修改、分发或商业使用权。

本项目仅用于学习、研究和经授权的测试。使用者应自行确认账号权限、平台规则、当地法律和操作后果；维护者不对未授权使用、考试记录变更或由上游服务变化造成的损失负责。
