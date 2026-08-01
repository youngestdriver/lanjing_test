# 蓝鲸助手 · iOS（原生版）

> 蓝鲸微课考试平台答题助手的原生 iOS 客户端（SwiftUI 全重写）。
> Web 版（`../server.js` + `../frontend/`）保留作为参考实现，本目录为独立原生工程。

## 环境要求

- macOS + Xcode 26.x（含 iOS 模拟器运行时）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

## 构建与运行

```bash
cd ios
xcodegen generate            # 生成 LanjingQuiz.xcodeproj（修改 project.yml 后需重新生成）
open LanjingQuiz.xcodeproj   # 或在命令行构建
```

命令行构建 / 测试：

```bash
xcodebuild -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

> 注意：模拟器构建需要与 Xcode 配套的模拟器运行时（`xcodebuild -downloadPlatform iOS`）。

## 架构

| 目录 | 职责 |
|---|---|
| `App/` | 入口、`AppState`（路由/主题/会话枢纽）、`Theme`（持久化 key 与 web 版一致为 `theme`） |
| `Models/` | 上游 JSON DTO + 领域模型；`Question` 内嵌 `_isMulti/_answers` 等派生逻辑 |
| `Networking/` | `APIClient`：`server.js` 代理逻辑的忠实移植（浏览器头伪装、cookie jar、会话过期检测、新考试队列状态机、批量拉题、交卷解析）；`ExamHTMLParser`/`ResultPageParser` 正则移植；`CookieStore` 用 Keychain 持久化 cookie |
| `ViewModels/` | `@Observable @MainActor`；`QuizViewModel` 承载答题状态机（单选即点即答 / 多选勾选+确认、答对 1200ms 自动跳题、每题 60s 计时器、键盘选择与提交分离） |
| `Views/` | SwiftUI 屏幕与组件（登录 / 考试列表 / 答题 / 答题卡 Sheet / 结果） |
| `Support/` | Duolingo 设计系统、HTML→AttributedString 渲染、加密与格式化 |

## 与 web 版的行为差异（有意为之）

- **多选题为真多选交互**：可勾选多个选项后手动提交，选中集合与正确答案完全一致才判对（web 版点任意正确选项即判对）。
- 其余交互（答对自动跳题、60s 计时器、答题卡分区/状态色、深色模式、iPad 键盘导航、交卷出分）均保持 web 版一致。

## 验证说明

单元测试覆盖解析器 / 加密 / 答案映射 / 会话过期检测 / 答题逻辑，无需真实账号。

登录 → 考试列表 → 答题 → 交卷需要真实凭据，用你自己的手机号 + 密码在模拟器里手动验证。

## 免责声明

仅供学习研究使用，请勿用于商业或违规用途。
