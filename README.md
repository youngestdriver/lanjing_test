# 蓝鲸题库工具 (lanjing-bank)

机考题库工具链：把蓝鲸微课平台的机考题库**完整采集**到本地，再做**子分类**、**快照打包**与
**Markdown 导出**。纯 Node.js（≥22），**零 npm 依赖**，直接 `node` 运行，不需要启动任何服务。

三个客户端已迁出到各自独立的仓库，本仓**不再包含** Web / iOS / Android 代码：

| 仓库 | 内容 |
|---|---|
| [youngestdriver/lanjing-web](https://github.com/youngestdriver/lanjing-web) | Web / PWA 与桌面版（Express 本地代理 + 桌面壳） |
| [youngestdriver/lanjing-ios](https://github.com/youngestdriver/lanjing-ios) | 原生 iOS（SwiftUI） |
| [youngestdriver/lanjing-android](https://github.com/youngestdriver/lanjing-android) | 原生安卓（Kotlin / Compose） |

本仓同时以 npm 包 `lanjing-bank` 的形式被 Web 仓以 git 依赖引用（见
[与客户端仓的关系](#与客户端仓的关系)）。

## 快速开始

```bash
# 采集完整题库（首次需登录，之后复用 data/session_cookies.txt 会话）
npm run collect            # = node scripts/collect-bank.js

# 子分类（给每条记录追加 subCategory）
npm run classify

# 打包题库快照 zip（发布用；离线分发包，供 iOS「导入题库」直接吃）
npm run snapshot

# 导出为人类可读 Markdown（公式图片下载到 data/export/images/）
npm run export

# 测试与语法检查
npm test
npm run check
```

## 目录结构

```text
.
├── package.json            # scripts: collect / classify / export / snapshot / test / check
├── lib/
│   ├── question-bank.js        # 收集器核心（进入/抓取/去重/JSONL 存储/续接）
│   ├── question-classifier.js  # 子分类规则引擎（subCategory）
│   ├── snapshot.js             # 题库快照 zip 的构建与校验（manifest/sha256/CRC32）
│   ├── bank-export.js          # Markdown 导出（HTML→纯文本转换）
│   ├── parsers.js              # 上游页面解析（与 Web 仓 lib/parsers.js 保持同步的独立副本）
│   └── upstream.js             # 直连上游客户端（cookie/登录/会话/API，不依赖任何服务）
├── scripts/
│   ├── collect-bank.js         # 采集 CLI
│   ├── classify-bank.js        # 子分类 CLI
│   ├── snapshot-bank.js        # 快照打包 / 校验 CLI
│   └── export-bank.js          # 导出 CLI
├── test/                       # node:test 单元 + 集成测试（stub 上游）
├── docs/                       # 设计/计划文档
└── data/                       # 采集/分类/导出的数据（gitignore，不入库）
```

## 题库数据 `data/`（不入库）

题库数据是**上游平台的版权内容（IP）**，整目录被 `.gitignore` 排除，**绝不入库**：

- 每个目标分类一个 JSONL（`言语理解.jsonl` 等），外加 `meta.json`（轮次、各卷状态与统计）。
  每条记录含 `_id`、`category`、`section`、`question`、`options`（4 槽）、`answer`、
  `analysis`、来源卷与轮次。任意中断后重跑同一目录即可续接（去重按题目 `_id`，损坏尾行自动丢弃）。
- `session_cookies.txt` — 收集器**自己的登录会话**（mode `0o600`，与任何客户端会话相互独立，
  登录一次后复用）。
- `export/` — Markdown 导出文件与下载的公式图片。

克隆本仓后 `data/` 是空的，题库需要自己采集（或从 release 的题库包恢复）。

## 采集 `npm run collect`

`scripts/collect-bank.js` 通过 `lib/upstream.js` **直连上游**，把机考题库中的题目（题干、选项、
正确答案、解析）逐份采集并去重保存。

上游平台的实际结构（已对真实服务验证）：每份机考卷（【言语理解（二）】机考题库 等）是**固定题池**
——重新进入只会拿到同一批题，同类不同卷（一）（二）（三）之间题目互不重叠；分类写在**卷名**里
（言语理解 / 数字运算 / 逻辑推理 / 资料分析 / 特有题型），卷内 section 是子题型（逻辑填空、
图形推理、时政等）。因此采集 = 每份目标卷进入一次即可全量（目前共 14 份目标卷、约 3000 题）：
进入 → 抓取 → 空答案提交放弃（或对用户进行中的卷只读采集）→ 下一份。

```text
node scripts/collect-bank.js [--exam <id>] [--max-rounds N]
       [--idle-limit N] [--round-delay ms] [--bank-dir <path>]
       [--targets a,b,c] [--skip-in-progress] [--refresh]
```

| 选项 | 默认 | 作用 |
|---|---|---|
| `--exam <id>` | 全部 | 只采集指定考试（可强制处理 `wfs=0` 的进行中卷） |
| `--max-rounds N` | 200 | 最大轮数安全上限 |
| `--idle-limit N` | 3 | 连续 N 轮无新题即停止 |
| `--round-delay ms` | 1500 | 每轮间隔 |
| `--bank-dir <path>` | `data/` | 题库输出目录 |
| `--targets a,b,c` | 5 个机考分类 | 目标分类（按卷名子串匹配；可自行加"常识判断"等） |
| `--skip-in-progress` | 采集 | 跳过进行中的作答（默认只读采集用户进行中的卷，**不提交**） |
| `--refresh` | 关 | 目标分类的 jsonl 改名 `.bak` 并清空续接状态，重新采集全部试卷（记录格式升级时用） |

- 会话由采集器**自己管理**（`data/session_cookies.txt`）。没有可用会话时：优先
  `LANJING_PHONE` / `LANJING_PASSWORD` 环境变量，否则在交互式终端提示输入手机号和密码；
  密码仅在运行时存在于内存，**绝不落盘**（只有登录产生的会话 cookie 会保存）。会话过期时
  自动清空并停止，重新登录后重跑即可续接。
- ⚠️ 与 `enter`/`submit` 相关：采集器对 `wfs=1` 的卷每轮会创建一份空答案作答并立即放弃
  （消耗考试次数）；对 `wfs=0` 的卷（你自己的进行中作答）只读取题、绝不提交。
- 停止条件：所有目标卷耗尽、连续 `--idle-limit` 轮无新题、轮数上限，或 Ctrl+C
  （完成当前轮后停止，数据已落盘）。

## 子分类 `npm run classify`

`scripts/classify-bank.js` 是离线子分类 CLI：为 `data/` 下每条记录追加 `subCategory`
（更细的题型类别，如 言语理解|阅读理解 → 主旨概括/意图推断/细节理解/标题选择…，
数字运算|数量关系 → 行程/工程/利润/浓度…，特有题型 → 直接用 section 名）。资料分析不做正则
分类——平台答题卡已把该类拆成 文字资料/统计表/统计图/…，HTML section 即子类（与特有题型同一约定）。

规则在 `lib/question-classifier.js`：按 `(category, section)` 分组的有序正则，对「题干+解析」
去 HTML 后的纯文本首条命中即定类，section 内规则优先，未命中落入各 section 兜底类
（如 数量关系→和差倍比与方程、逻辑填空→实词辨析）。

```text
node scripts/classify-bank.js [--bank-dir <path>] [--dry-run] [--no-backup] [--targets a,b,c]
```

- `--dry-run` 只统计并打印分类表，不写盘；正式运行首次写盘前把原文件备份为 `*.jsonl.bak`
  （一次性，重跑不覆盖），随后原子重写。
- 幂等：重跑输出与上次字节一致，不产生重复；新采集的题目补跑一次即可。

## 快照 `npm run snapshot`

`scripts/snapshot-bank.js` 把题库目录打成一个**离线分发包** zip（只读本地 `*.jsonl` 与
`images/`，零网络），供客户端「导入题库」直接使用；包内带 manifest（题目数、图片 CRC32、
长度、sha256），可用 `--verify` 校验完整性与 zip 对齐。

```text
node scripts/snapshot-bank.js [--bank-dir <path>] [--out <path.zip>] [--report]
node scripts/snapshot-bank.js --verify <path.zip>
```

- 默认产物 `<bank-dir>/lanjing-bank-<YYYYMMDD>.zip`。
- `--report` 只统计不落盘（引用图片数 / 已覆盖 / 缺失 / 题目数 / 各分类题数），退出码 0=全覆盖。
- `--verify` 校验既有 zip（CRC32 + 长度 + sha256 + manifest 与 zip 对齐），退出码 0=通过；
  发布流程在发布前用它校验「即将随 release 分发的那一个包」。

## 导出 `npm run export`

`scripts/export-bank.js` 把题库导出为**人类可读的 Markdown**：每个 (分类-子类) 一个文件
（`<bank-dir>/export/言语理解-成语辨析.md`），题干/选项/答案/解析清洗成纯文本（HTML 与实体
解码、段落保留）。**公式图片会下载到 `<out>/images/` 并本地引用**（按 URL 去重，重跑跳过已存在
文件，下载失败回退远程链接；纯图片题标注"（图片题）"）。

```text
node scripts/export-bank.js [--bank-dir <path>] [--out <path>] [--targets a,b,c] [--no-images]
```

## 发布题库包

[`.github/workflows/release-bank.yml`](.github/workflows/release-bank.yml)（`Release Bank`）
在**每次 push 到 `main` 时自动发布**（版本号 = 最新 tag 的 patch +1，沿用 `v0.0.x` 序列），
也可手动触发：

```bash
gh workflow run release-bank.yml -f version=v0.1.0
gh workflow run release-bank.yml -f bank_url=https://…/lanjing-bank.zip
```

每次发布**必须**带题库包 `LanjingQuiz-bank-<version>.zip`（数据本身不入库，所以包随 release
分发）。来源按三级顺序解析，三条都落空就**失败**——宁可让发布停下，也不静默发出一个没有题库的版本：

1. **工作区有 `data/`** → 用 snapshot CLI 现场打包（可复现，首选）；
2. **手动运行且给了 `bank_url`** → 直接下载该地址的包；
3. 否则 → **取最近一个带题库包的 release 资产**。

无论走哪条路，发布前都会用 `node scripts/snapshot-bank.js --verify` 校验一遍
（CRC32 / 长度 / sha256 / manifest 对齐），通过后才创建 GitHub Release。首次（历史 release 里
还没有题库资产时）需要手动 bootstrap 一次：

```bash
gh release upload <tag> lanjing-bank-*.zip --clobber
```

## 与客户端仓的关系

- 本仓只包含题库工具；Web / iOS / Android 客户端已迁出至各自独立的仓库（见文首链接）。
- Web 仓通过 npm git 依赖引用本仓的 `lanjing-bank` 包（`package.json` 的
  `"lanjing-bank": "github:youngestdriver/lanjing_test#<tag>"`），用的是包的两个导出入口：
  `.`（`lib/question-bank.js`）与 `./classifier`（`lib/question-classifier.js`），不再直接读本仓文件。
- 本仓 `lib/parsers.js` 与 Web 仓的 `lib/parsers.js` 是刻意保留的独立副本，两边改动需保持同步。
- **跨仓同步约定**（分类器沿用「JS 为源，Swift / Kotlin 忠实移植」）：改一条规则 =
  本仓规则引擎 + 测试 → 主仓打 tag → Web 仓 bump git 依赖 → iOS / Android 各移植一次。
  Web 仓不再从本仓读文件，所以**不 bump 依赖就不会生效**。

## 本地验证

零 npm 依赖，直接运行：

```bash
npm test     # node --test test/*.test.js
npm run check   # node --check 全部 lib/scripts/test 源文件
```

测试覆盖：采集器的卷名分类匹配、section 清洗、题卡位置关联、记录 schema（单选/多选/兜底答案/
填空）、考试选择策略（pendingSubmit 优先、目标卷过滤、`wfs=0` 只读采集、强制 `--exam`）、502 交卷
验证、"未创建的作答绝不提交"保护、跨轮去重与 resume、损坏尾行容错、空闲/上限/会话失效停止；
直连上游客户端的登录全流程（JSESSIONID 引导、表单编码、会话落盘）、未登录拦截、会话过期识别、
cookie jar 合并与失效、幂等读取的重试语义；快照的 manifest/校验/缺失图片报告；子分类的 HTML 剥离
与实体解码、各 section 规则命中、优先级、兜底类、字段保真与幂等重写。全部测试都不访问真实上游。

## 开发流程

`main` 是唯一长期分支，并受分支保护：

1. 从最新 `main` 创建短期分支，例如 `feat/bank-snapshot` 或 `fix/classifier-rule`。
2. 一个分支只处理一个明确变更。
3. 通过 Pull Request 合回 `main`；合并后 `main` 的 push 会自动触发 `Release Bank` 发布题库包。
4. 合并后删除短期分支。

不要提交：`data/`（题库数据与会话文件）、`node_modules/`、账号凭据与调试日志。

## 安全与限制

- 上游地址目前固定为 `https://test.lanjingweike.com`，没有 `.env` 或运行时切换配置。
- 采集器把上游 Cookie 明文保存到 `data/session_cookies.txt`（目录 `0700`、文件 `0600`），
  该目录已被 gitignore；会话仅保存在本机，不随仓库分发。
- 账号凭据只在登录请求中使用，仅存在于进程内存（或环境变量），绝不落盘。
- 上游接口和 HTML 结构不属于本仓库控制范围；页面、字段或认证流程变化都可能导致采集失败。
- 采集会对 `wfs=1` 的进行中卷创建空答案作答并放弃（消耗考试次数），不要在无人值守的自动化里跑。

## 许可与免责声明

本仓库当前没有提供开源许可证。公开可见不代表自动授予复制、修改、分发或商业使用权。

本项目仅用于学习、研究和经授权的测试。题库内容版权归上游平台所有，不应再分发。
使用者应自行确认账号权限、平台规则、当地法律和操作后果；维护者不对未授权使用、考试记录变更
或由上游服务变化造成的损失负责。
