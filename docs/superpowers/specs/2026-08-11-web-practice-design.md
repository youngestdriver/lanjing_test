# Web 练习页对齐 iOS:直连爬取题库 + 两级分类刷题

- 日期:2026-08-11
- 状态:已批准(用户确认方案 A:复用 bank 模块 + SSE 进度)
- 范围:`apps/web`(server.js / public / test)+ README;不涉及 `apps/ios`、`apps/bank` 代码改动

## 背景与目标

三端(Web / iOS / Bank)进度对齐时发现唯一的功能级不对称:**iOS 练习页已具备直连爬取全量机考题库 + 本地两级分类(大类→题型细分)离线刷题,Web 练习页仍是占位页**(只有"前往考试列表"按钮)。本次把该能力对齐到 Web。

对齐范围(用户已确认):
1. 题库存 `apps/web/.local/practice/`(不与 `apps/bank/data` 共享)
2. 爬取行为与 iOS 一致:首次使用自动全量爬取(逐卷进度 + 断点续爬);"更新题库"重爬全部并原子替换
3. 答题页零网络:题面/选项/判分/解析全在浏览器内存,不依赖服务器(考试主流程仍需服务器)
4. "我的"页新增题库分区:更新题库、删除题库(确认弹窗)、日志导出(txt)——与 iOS 全对齐

## 现状复用点(探索结论)

- `server.js` 已具备爬取所需的全部上游能力:`startNewExam`(队列流程)、`fetchAllQuestions`(combId 分组 + 批量重试)、`proxyRequest`、共享会话 `cookieJar`、auth 中间件、`syncInFlight` 单飞模式
- `apps/bank/lib/question-bank.js` 的 `buildRecord`/`joinQuestions`/`cleanSection`/`matchCategory` 与 `question-classifier.js` 的 `classify` 是纯 Node 函数,**直接 require 复用**,不重复移植
- `apps/bank` 存储函数 `appendRecords`/`saveMeta` 接受 `bankDir` 参数,传 `.local/practice/` 路径即可复用
- iOS 侧 `crawlAllPapers` 的"遍历全部试卷"模式是爬取循环的参照(区别于 bank CLI 的多轮 `runCollection` 循环)

## 架构与数据流

```
浏览器练习页 / 我的-题库分区
  │  HTTP(fetch + SSE)
  ▼
server.js(现有 Express,共享会话 cookieJar)
  │  复用 proxyRequest / fetchSessionText / startNewExam / fetchAllQuestions
  ▼
apps/web/lib/practice-crawl.js   ← require apps/bank/lib/question-bank + question-classifier
  │  fs 原子写
  ▼
apps/web/.local/practice/
    ├─ 言语理解.jsonl / 数字运算.jsonl / 逻辑推理.jsonl / 资料分析.jsonl / 特有题型.jsonl
    ├─ meta.json    { version:1, targets, round, lastRun, papers:{paperId:true}, counts }
    └─ crawl_log.jsonl   CrawlLogEntry 逐步骤日志
```

数据格式与 iOS 完全同构:JSONL 记录含 `_id/category/section/subCategory/question/stem/options/answer/analysis/sourceExamName/round/collectedAt`(stem 为组合题共享材料);`meta.papers` 驱动断点续爬;`crawl_log.jsonl` 为 CrawlLogEntry(paperList/enter/save/endAttempt/skip × success/failure/skipped)。

## 服务端设计

### 新文件 `apps/web/lib/practice-crawl.js`(纯 Node,可直接单测)

- `crawlAllPapers({ refresh })` — iOS `crawlAllPapers` 的 Node 移植:
  - 试卷列表:`/api/exams` 同款请求 + `isTargetExam`/`matchCategory`(复用 bank)
  - 逐卷:`enter`(wfs=1 走 `startNewExam`,wfs=0 只读进入)→ `fetchAllQuestions`(combId 分组)→ `joinQuestions` + `buildRecord`(复用 bank)→ `classify` 填 subCategory → `appendRecords` 写分类文件
  - wfs=1 卷:抓完即结束作答,`submit` 返回 502"考试未能结束"是预期成功(JSON success),吞掉并记录
  - 首次模式:已爬卷(meta.papers)跳过;每卷后写 meta(断点续爬);连续 3 卷失败停止
  - refresh 模式:重爬全部;任一卷失败 → 不提交,旧题库保留;成功则先写 5 个分类文件、meta 最后写(原子提交)
  - 每个步骤 append `CrawlLogEntry` 到 `crawl_log.jsonl`(日志写失败不影响爬取)
- `runCrawlTask({ refresh })` — 后台任务单例(借鉴 `syncInFlight`):进程内持有任务状态(进行中/完成/失败/错误信息)、SSE 订阅者列表;任务运行中重复触发返回 null

### `server.js` 新增 `/api/practice/*` 路由

| 路由 | 方法 | 认证 | 说明 |
|---|---|---|---|
| `/api/practice/status` | GET | 免登录 | 登录态、isPopulated、meta 摘要(counts/round/lastRun)、进行中任务进度 |
| `/api/practice/categories/:name` | GET | 免登录 | 返回单个分类 JSONL 全文(前端加载题库) |
| `/api/practice/crawl` | POST | 需登录 | 首次全量爬取;任务已运行返回 409 |
| `/api/practice/update` | POST | 需登录 | refresh 重爬全部、原子替换 |
| `/api/practice/events` | GET | 免登录 | SSE:逐卷进度(`第 N/XX 卷 · 卷名`)、完成、失败、会话过期 |
| `/api/practice/delete` | POST | 需登录 | 删除整个 `.local/practice/` 目录 |
| `/api/practice/log` | GET | 免登录 | 爬取日志导出 txt(`Content-Disposition` 下载,文件名 `爬取日志_YYYYMMDD_HHmm.txt` 用 `filename*` 编码) |

认证语义对齐 iOS:爬取/管理类操作需登录(会话失效 → 401 → 前端跳登录);读取题库/日志(本地数据)免登录,离线刷题不受会话影响。

错误处理:上游失败在日志中记录为 failure 步骤并继续(首次模式连续 3 次失败停止);refresh 模式任一失败则不提交;任务内存状态在服务重启后丢失,但 meta.json 保证续爬。

## 前端设计

### 新文件 `apps/web/public/js/practice-core.js`(无 DOM 纯逻辑,Node/浏览器双环境)

- `parseJSONL(text)` / `groupBySubcategory(questions)`(未分类 → "未分类")
- `grade(selected, question)` — 单选/多选精确集合相等判分
- `shuffledKeepingGroups(questions, seed)` + SplitMix64 种子随机(JS 移植 iOS `BankLogic`;组合题同 stem 相邻成组洗牌)
- 洗牌偏好按大类存取 `localStorage` key `practice.shuffle.<category>`(与 iOS 的 `practice.shuffle.<category>` 同名同义)

### 新文件 `apps/web/public/js/practice.js`(练习页 UI + 状态机)

练习 tab 视图流(JS 栈导航 push/pop,与现有 hash 路由互不干扰):

1. 未爬取:`开始爬取题库` 按钮(未登录先跳登录;爬取中显示 SSE 进度 `第 N/XX 卷 · 卷名`)
2. 大类列表:5 个分类 + 题数(counts)
3. 题型细分列表:该大类 JSONL 一次 fetch 后 `parseJSONL` + `groupBySubcategory`,显示名称+题数
4. 答题页:题干 + stem 材料块(组合题)+ 4 选项(单选点击即判、多选确认后判)→ 判分着色 → 解析 → 下一题;进度 X/N;随机顺序开关(按大类);**题目数据全在内存,零网络**

### `index.html` 与 `app.js`

- 练习 tab 占位区替换为视图容器;引入 `practice-core.js` / `practice.js`
- "我的"页新增"题库"分区:更新题库(SSE 进度)→ 删除题库(`confirm` 弹窗,删除后练习页回到未爬取态)→ 日志导出(触发下载)

## 测试

- `apps/web/test/practice-core.test.js` — 纯函数单测:parse/group/grade/shuffle(组合题相邻性、洗牌偏好 key),沿用现有 node:test 风格
- `apps/web/test/server-practice.test.js` — mock 上游(`LANJING_BASE_URL` 指向 stub,沿用 server-bank.test.js 机制):
  - 首次爬取全流程(试卷列表 → 逐卷 → JSONL/meta 落盘 → 日志)
  - 断点续爬(meta.papers 已标记的卷跳过)
  - refresh 原子替换(任一失败 → 旧题库保留、不提交)
  - 删除、日志导出内容与文件名
  - 409 并发(任务运行中重复触发)、401(会话过期)、免登录读取分类/日志
- 浏览器 smoke 回归:`browser-smoke.js` 确认练习 tab 不再报错(占位页替换)

## 文档

- README:功能表补 Web 练习描述(直连爬取 + 本地两级分类刷题 + 组合题 + 删除/日志),更新三端差异表与测试数

## 范围外(明确不做)

- 题库写入 Service Worker 缓存(已定:答题页零网络即可,本地服务常开)
- 局域网多设备练习数据共享(题库在服务端 `.local`,同机浏览器共用;不做多用户隔离)
- iOS / bank 代码任何改动(本次只对齐 Web)
