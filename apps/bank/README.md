# 题库工具 (apps/bank)

独立于 Web 与 iOS 应用的机考题库工具:把蓝鲸微课平台的机考题库**完整保存**到本地,再做子分类和 Markdown 导出。纯 Node.js(≥22),**零 npm 依赖**,直接 `node` 运行,不需要启动 Web 服务。

```
apps/bank/
├── package.json            # scripts: collect / classify / export / test / check
├── lib/
│   ├── question-bank.js        # 收集器核心(进入/抓取/去重/JSONL 存储/续接)
│   ├── question-classifier.js  # 子分类规则引擎(subCategory)
│   ├── bank-export.js          # Markdown 导出(HTML→纯文本转换)
│   ├── parsers.js              # 上游页面解析(与 apps/web/lib/parsers.js 保持同步的独立副本)
│   └── upstream.js             # 直连上游客户端(cookie/登录/会话/API,不依赖 Web 服务)
├── scripts/
│   ├── collect-bank.js         # 收集 CLI
│   ├── classify-bank.js        # 子分类 CLI
│   └── export-bank.js          # 导出 CLI
├── test/                       # node:test 单元 + 集成测试(stub 上游)
└── data/                       # 收集/分类/导出的数据(gitignore,不入库)
```

## 快速开始

```bash
# 收集(完整题库;首次需登录,之后复用 data/session_cookies.txt 会话)
npm run collect            # 或 node scripts/collect-bank.js

# 子分类(给每条记录追加 subCategory)
npm run classify

# 导出为人类可读 Markdown(公式图片下载到 data/export/images/)
npm run export

# 测试与语法检查
npm test
npm run check
```

## 数据目录 `data/`

- 每个目标分类一个 JSONL(`言语理解.jsonl` 等)+ `meta.json`(轮次、各卷状态与统计);任意中断后重跑同一目录即可续接(去重按题目 `_id`,损坏尾行自动丢弃)。
- `session_cookies.txt` — 收集器**自己的登录会话**(与 Web 应用的会话相互独立,登录一次后复用)。
- `export/` — Markdown 导出与下载的公式图片。

全部在 `apps/bank/data/`,已被 gitignore,不会入库。

## 会话与登录

收集器通过 `lib/upstream.js` **直连上游**,不复用 Web 应用的会话:

- 会话保存在 `data/session_cookies.txt`(mode 0o600);有会话时直接复用。
- 无会话时:优先 `LANJING_PHONE` / `LANJING_PASSWORD` 环境变量,否则交互式输入(密码不回显、不落盘,只有登录产生的会话 cookie 会保存)。
- 会话过期时自动清空并停止,重新登录后重跑即可续接。

## 与 Web / iOS 的关系

- Web 服务(`apps/web/server.js`)把 `apps/bank/data/` 静态托管在 `/bank`,供 iOS 练习页下载题库。Web 应用本身不再包含任何收集/分类/导出代码。
- 本目录的 `lib/parsers.js` 是 `apps/web/lib/parsers.js` 的独立副本,两边改动需保持同步。
- 详细的收集/分类/导出规则与上游行为说明见仓库根 `README.md` 对应章节。
