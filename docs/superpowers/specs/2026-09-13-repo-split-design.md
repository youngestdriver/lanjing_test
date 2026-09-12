# 主仓拆分设计：iOS / Android / Web 独立成仓

- 日期：2026-09-13
- 状态：待评审
- 主仓：`youngestdriver/lanjing_test`（公开）

## 1. 背景与目标

今天的 `lanjing_test` 是单仓多端：`apps/{ios,android,web,bank,desktop}` 五部分同处一仓，推一次 `main` 就由 `.github/workflows/release.yml` 全平台构建、自动 +1 patch、共用一个版本号发出一个 release。

本次拆分要解决三个已确认的问题：

1. **发版解耦** —— iOS 改动不该连带桌面端 / 安卓 / 题库一起发版、共用版本号；各端要有自己的构建与发布节奏。
2. **仓库独立** —— 客户端各自成仓（均设为公开，与主仓一致），主仓不再保留客户端代码。
3. **开发上下文变轻** —— 在单端仓库里开发时，文件、历史、搜索都只面对本端。

非目标：不改任何客户端的功能与代码边界；不重写主仓历史；不建 submodule。

## 2. 目标结构：四仓拓扑

```text
youngestdriver/lanjing_test   主仓 = 题库工具仓
├── package.json              "lanjing-bank"，对外暴露 lib/
├── lib/                      (原 apps/bank/lib)
├── scripts/                  (原 apps/bank/scripts)
├── test/                     (原 apps/bank/test)
├── data/                     (gitignore，本地题库数据，含上游 IP 不入库)
├── docs/                     (上游接口与题库文档，含 bug 记录)
├── README.md                 (重写为题库工具说明)
└── .github/workflows/release-bank.yml

youngestdriver/lanjing-web    Web + 桌面壳（desktop 是 web 的打包壳，不单拆）
├── server.js  lib/  public/  test/  tools/  desktop-entry.js  package.json
├── desktop/                  (原 apps/desktop：macOS / Windows 壳)
├── scripts/                  (原根 scripts/：assemble-macos-app.sh 等)
├── assets/                   (原根 assets/：桌面图标、dmg 背景)
├── docs/web-api.md
├── README.md                 (新写，取材根 README 的 Web 部分)
└── .github/workflows/release.yml

youngestdriver/lanjing-ios    iOS
├── LanjingQuiz/  LanjingQuizTests/  LanjingQuizUITests/
├── LanjingQuiz.xcodeproj  project.yml  GlassHelpers.swift
├── README.md  .gitignore
└── .github/workflows/release-ios.yml

youngestdriver/lanjing-android  Android
├── LanjingQuiz/  gradle/  gradlew  gradlew.bat
├── build.gradle.kts  settings.gradle.kts  gradle.properties
├── README.md  .gitignore
└── .github/workflows/release-android.yml
```

## 3. 迁移方式：新仓从零开始，不保留原提交

- 每个新仓 = **复制对应目录的文件 + 一条初始提交**。初始提交信息注明来源（`youngestdriver/lanjing_test`）与迁移日期，供溯源。
- 不使用 `git subtree split` / `filter-repo` 提取历史；原提交历史完整保留在主仓公开历史中，随时可查（若要翻旧账或重拆，主仓历史都在）。
- 各新仓自带 `.gitignore`：从根 `.gitignore` 提取本端相关规则（构建产物、依赖目录等）。
- 主仓在每端迁走后各做一笔"删除该目录"的普通提交；**不重写历史**。
- **同笔提交里必须同步删掉主仓 `release.yml` 中该端的 job 及汇总处的 `needs` 引用**——主仓推 main 即自动发版，留下的 job 会构建已不存在的路径，直接把主仓发布打红。

## 4. 跨仓接口

拆分后仅剩以下接触面，逐条给接法。

### 4.1 JS 规则引擎（唯一硬代码依赖）

现状：`apps/web/lib/practice-crawl.js` 运行时 `require("../../bank/lib/question-bank")` 与 `question-classifier`。

接法（已确认）：**主仓把自己做成可被 npm git 依赖消费的包**。

- 主仓根 `package.json`：`name: "lanjing-bank"`，`main` 指向 `lib/question-bank.js`，`exports` 暴露 `.` 与 `./classifier`，`files: ["lib"]`。
- web 仓依赖：`"lanjing-bank": "github:youngestdriver/lanjing_test#<tag 或 commit>"`；公开仓免授权，`package-lock.json` 锁定解析到的具体提交。
- 代码引用改为 `require("lanjing-bank/classifier")` 等；web 只能拿到 `lib/` 白名单内的文件，边界是硬的。
- 规则改动流程：主仓改引擎 + 测试 → 打 tag（或记 commit）→ web 仓 bump 版本号 → `npm install` → 提交。
- 题库数据不入库，装包不会带上数据；Bun 桌面编译照旧把依赖打进二进制，用户端无运行时网络依赖。
- 若日后"改规则要两仓各提交一遍"变得频繁到不可忍受，届时再把引擎独立成第四个小仓，两端都当普通依赖装。

### 4.2 题库数据目录（Web 的 `/bank` 兼容路由）

现状：`server.js` 把 `../bank/data` 静态挂在 `/bank`；README 注明该端点是"原 iOS 练习页数据源，iOS 已改直连上游，保留为兼容"。

接法：web 仓默认目录改为 `LANJING_LOCAL_DIR/bank-data`，`LANJING_BANK_DIR` 覆盖语义不变；需要兼容旧用法的用户把题库包内容放到该目录。

### 4.3 题库包（只在主仓发布）

- 题库包的产源与发布都留在主仓（`data/` 不入库，CI 按"工作区 → bank_url → 历史 release"三级解析来源，校验后发布）。
- **iOS 仓不取题库包、不随 iOS release 分发**（已确认）。用户在 iOS 发布页拿 ipa，题库包到主仓发布页取——ipa 的安装说明文本（现 workflow 内嵌的 `ipa-install-notes.txt`）里写清这一点。
- 跨仓下载因此完全不必要，跨仓脆弱性归零。

### 4.4 分类器三端同步（约定不变）

"JS 为源，Swift / Kotlin 忠实移植"的约定不变，只是执行变成跨仓：改一条规则 = 主仓 PR（引擎 + 测试）→ web 仓 bump 依赖 → iOS / Android 各一个移植 PR，同一会话连续完成。

暂不引入机制（如从主仓导出测试向量给 Swift / Kotlin 测试加载）——出现漂移再加。

### 4.5 iOS 测试的路径耦合（迁移时必须改）

`BankImportUITests` 靠 `#filePath` 上溯 4 层到仓库根再取 `apps/bank/data`；拆仓后层级变化且数据不存在。改为：先读 `LANJING_BANK_DATA` 环境变量，缺省看仓根 `bank-data/`，仍找不到则维持现状的 `XCTSkip`。

### 4.6 杂物归属

| 内容 | 去向 |
|---|---|
| `assets/`（桌面图标、dmg 背景） | web 仓 |
| `docs/web-api.md`（描述 web 本地 API） | web 仓 |
| `docs/bug-record-*.md`（上游 `key1~key4` 类型 bug，`bank/lib/upstream.js` 同源） | 主仓 |
| 根 `README.md` | 拆写：主仓重写为题库工具说明；iOS / Android 已各有 README；web 仓新写一份 |

## 5. 各仓发布流水线

触发方式照搬现状（推 main 自动发版 + 手动入口），各仓只管发自己。

| 仓 | workflow | 内容 | 产物 |
|---|---|---|---|
| 主仓 | `release-bank.yml` | 题库包三级解析 + 校验（原 `bank-snapshot` job） | `LanjingQuiz-bank-<version>.zip` |
| web | `release.yml` | 服务二进制交叉编译 + Windows 托盘 / macOS .app+dmg / Linux 单文件（原四个 job，路径去 `apps/` 前缀） | 桌面三平台产物 |
| ios | `release-ios.yml` | 未签名 ipa（原 `ios-unsigned` job，工程路径改为仓根） | `LanjingQuiz-unsigned-<version>.ipa` |
| android | `release-android.yml` | 未签名 release APK（原 `android-apk` job） | `LanjingQuiz-android-<version>.apk` |

要点：

- **签名 ipa（ADHOC）暂不搬**（已确认：短期不配证书）。旧主仓历史里该 job 完整保留，日后配好证书再搬回或照写。
- iOS 仓需要单独配置的 secrets：无（未签名构建不需要；证书相关 secrets 待搬签名 job 时再配）。
- **版本号**：主仓沿用现有 `v0.0.x` 序列继续自动递增（同一仓库、tag 连续）；三个新仓各自从 `v1.0.0` 起步（与 iOS 工程内 `MARKETING_VERSION 1.0` 对齐），沿用"取最新 tag +1 patch"逻辑。
- **发布页从 1 个变 3 个**（外加主仓的题库包页），这是"各仓独立发版"的既定代价。主仓旧 release 与 tag 一律不动，老下载链接不失效。

## 6. 执行顺序、验证与回退

### 顺序：从牵连最少开始，一仓验完再拆下一仓

1. **基线**：先跑一遍三端现有测试，记录"拆之前就是绿的"。
2. **iOS**（零外部引用，仅 4.5 一处小改）→ 收益最大，先拆。
3. **Android**（独立 Gradle 工程，纯搬运）。
4. **主仓先改造成题库包**（必须排在 Web 拆出之前，Web 要依赖它）：bank 挪到根 + 加根 `package.json` + 主仓内 web 的 require 改相对新路径 + web 的 `BANK_DIR` 默认值改为本地目录；主仓内 bank 与 web 测试跑通。
5. **Web**（牵扯最多：规则引擎改为包引用、桌面壳、图标、文档）。
6. **主仓收尾**：删掉 web 目录、`release.yml` 精简为 `release-bank.yml`、根 README 重写、清理空壳。

### 每端的动作

1. 复制对应目录到新目录，清掉构建产物，提取 `.gitignore`；
2. GitHub 建仓（公开），初始化并推第一条提交；
3. 改路径相关处（CI 里的工程/目录路径；iOS 另有 4.5；Web 改为 `lanjing-bank` 包引用并补齐独立 README）；
4. 新仓跑测试 + 手动触发一次发布，产物在真机/真桌面验证；
5. 通过后，回主仓提交"删除该目录 + 同步删 `release.yml` 对应 job 与 `needs` 引用"。

### 验证清单

- 新仓：单测与 UI 测试全绿；手动发版成功；产物可下载、可安装/可运行。
- 主仓：删除目录并同步删 job 后，主仓自动发版仍能正常跑完（发一次题库包验证）。
- 旧 release 与 tag 全部原样，老链接不失效。

### 回退

全程只做普通提交、不重写历史：删错了 revert 那笔删除提交，新仓不想要了直接删仓，即可回到今天的状态。唯一"做出去"的动作是在新仓发了首个 release，删掉即可。天然保险：所有代码都在主仓公开历史里，随时可以重拆。

## 7. 明确不做

- 不重写主仓历史（代码已公开，重写带不来保密收益且破坏 tag/release/PR 引用）。
- 不建 submodule（双仓提交摩擦大于收益）。
- 不搬签名 ipa job（待证书）。
- 不做跨仓题库包分发（题库包只发主仓）。
- 暂不做分类器测试向量同步机制（4.4，出现漂移再加）。
- 不做 desktop 单独拆仓（它是 web 的打包壳）。

## 8. 决策记录

| 决策点 | 结论 | 备注 |
|---|---|---|
| 拆分范围 | iOS / Android / Web 全部独立，主仓不保留客户端代码 | 用户确认 |
| 主仓定位 | 题库工具仓（bank + 全局资产/文档） | 用户确认 |
| 新仓可见性 | 公开，与主仓一致 | 用户确认 |
| 发布模型 | 各仓独立发版，各自 tag | 用户确认 |
| 历史 | 新仓不保留原提交，从零开始 | 用户确认 |
| 规则引擎 | 主仓做成 npm git 依赖包供 web 引用 | 用户确认 |
| 题库包 | 只在主仓发布，iOS 仓不取不分发 | 用户确认 |
| 签名 ipa | 暂不搬，仅发未签名 ipa | 用户确认 |
