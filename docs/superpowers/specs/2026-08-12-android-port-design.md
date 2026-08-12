# 兰鲸助手安卓版移植设计

> **日期:** 2026-08-12
> **依据:** iOS 版兰鲸题库(`apps/ios/LanjingQuiz`)完整盘点(7 子系统蓝本,端点/JSON 键/业务规则精确到字符串级)
> **决策:** 全量对齐 iOS;Kotlin + Jetpack Compose + Material 3;题库同 iOS 直连爬取;minSdk 26 + 手机平板;完整 CI + 发布产物

**Goal:** 以 iOS 版为功能与行为基准,在 `apps/android/` 新建原生安卓应用,全量覆盖 iOS 的功能面(登录/会话、考试、练习刷题+爬取、CookieCloud、我的),行为与数据格式与 iOS/Web 兼容。

## 一、产品决策记录(用户已确认)

| 决策点 | 结论 |
|---|---|
| 移植范围 | 全量对齐 iOS(考试 + 练习 + CookieCloud + 我的) |
| 题库来源 | 同 iOS:首次使用直连蓝鲸平台爬取全部机考题库到本地(断点续爬、原子更新、可删除) |
| 设备/基线 | minSdk 26(Android 8.0)、targetSdk 35;手机与平板自适应(同 iOS iPhone/iPad 支持) |
| CI/发布 | 新增 ci-android.yml(构建+单元+UI 测试);release.yml 增加安卓产物 |
| 视觉风格 | Material 3 原生风;信息结构与交互对齐 iOS |
| 技术栈 | Kotlin + Jetpack Compose + Material 3,单 Activity + MVVM + Repository + Hilt,OkHttp 网络层 |

## 二、工程结构

```
apps/android/
├── settings.gradle.kts / build.gradle.kts / gradle/libs.versions.toml / gradlew
├── LanjingQuiz/
│   ├── build.gradle.kts        ← applicationId com.qzh.lanjingquiz,minSdk 26,targetSdk 35,Compose
│   └── src/
│       ├── main/java/com/qzh/lanjingquiz/
│       │   ├── App/            AppContainer(Hilt)、AppState(路由 StateFlow)、MainActivity、Application
│       │   ├── Network/        APIClient、PersistentCookieJar、UpstreamDTOs、MockUpstreamServer(test)
│       │   ├── Support/        Hashers(SHA-256/MD5)、FormEncoder、SplitMix64、Formatters、CookieCloudCrypto
│       │   ├── Domain/         QuizLogic、BankLogic、QuestionClassifier、ExamHTMLParser、ResultPageParser
│       │   ├── Data/           BankStorage、PracticeSessionStore、PracticeProgressStore、CookieStore、SettingsStore、SecureStore
│       │   └── UI/             Login/ExamList/Quiz/AnswerCard/Result/Practice/Profile + Theme
│       ├── test/               JVM 单元测试
│       └── androidTest/        Compose UI 测试(进程内 mock 上游)
```

### iOS → Android 平台映射

| iOS | Android |
|---|---|
| Keychain(service `com.qzh.lanjingquiz`,account `cookies` / `cookiecloud.password`) | EncryptedSharedPreferences(androidx.security-crypto),键位语义保留 |
| UserDefaults(键 `theme`、`theme.manual`、`quiz.autoAdvanceOnCorrect`、`practice.shuffle.<大类>`、`quiz.cookieCloud`、`quiz.cookieCloud.lastPushedHash`) | SharedPreferences,**键名逐字保留** |
| Application Support/LanjingQuiz/ | `filesDir/LanjingQuiz/` |
| WKWebView + 文档模板 + contentHeight JS 桥 | WebView + 同模板 + onPageFinished/JS 高度回读 |
| URLSession + HTTPCookieStorage | OkHttp + 自研持久 CookieJar |
| SwiftUI TabView(.page) | Compose 导航 + 手势分页 |
| UIActivityViewController 分享 | FileProvider + ACTION_SEND |
| `.sheet`/overlay 答题卡 | Compose overlay/ModalBottomSheet(安卓无 iOS17 隐藏 tabbar 下 sheet 的 bug,但保持 overlay 形态) |
| iPad 硬件键盘导航(方向键/A-D/Escape/Return) | **不做**(iOS 专属功能,触屏 UX 不需要;安卓系统自带键盘导航不额外实现) |
| `-reset-bank` DEBUG 启动参数 + `LANJING_BASE_URL` 环境变量 | 仪器化测试:BuildConfig 字段或测试启动参数,清空 bank + session + progress;Base URL 指向 MockWebServer |

## 三、全局约束(计划中每个任务必须逐字遵守)

以下全部为与上游/数据格式/用户可见的**精确契约**,移植时逐字照抄,不允许翻译或改造。

### 3.1 上游网络契约

- Base URL:`https://test.lanjingweike.com`(硬编码;测试可用 `LANJING_BASE_URL`/BuildConfig 覆盖)
- User-Agent:`Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0`
- 默认请求头:`X-Requested-With: XMLHttpRequest`;`Origin: <baseURL>`;`Referer: <referer 参数或 baseURL>/exam`;`Accept: application/json, text/javascript, */*; q=0.01`;`sec-ch-ua: "Microsoft Edge";v="149", "Chromium";v="149", "Not)A;Brand";v="24"`;`sec-ch-ua-mobile: ?0`;`sec-ch-ua-platform: "Windows"`
- 表单编码:UTF-8 百分号编码,允许集 = ASCII 字母数字 + `-._~`,`k=v` 以 `&` 连接(URLSearchParams 语义)。**禁止** `java.net.URLEncoder`(空格 `+`、允许集不同)
- 端点(全部):
  - `GET /login/account/login/1` — JSESSIONID 暖启动,关闭过期检测
  - `POST /login/account/login` — 表单:`userName=<去空白手机号>@1`、`userNameInput=<去空白手机号>`、`password=<SHA-256 小写 hex>`、`passwordMD5=<MD5 小写 hex>`、`companyId="1"`、`newCompanyId="1"`、`remember="false"`、`phoneAccount=""`、`authCode=""`、`captchaText=""`、`nextUrl=""`;响应 `{success: Bool, desc: String?}`
  - `POST /exam/current_exam_list` — 表单:`examStyle="0"`、`timeSort=""`、`status=""`、`setProcess="-1"`、`page="1"`、`firstVisit="true"`、`name=""`、`rowCount="100"`、`participation=""`;响应 `bizContent.{total, styles[{id,name}], examInfoModelList[{id, examName, examStyle, examStyleName, practiceMode, examMode, examTime, paperInfoId, examTimesNum, examTimesRestrict, paid, examTimeRestrict, wfs, timeLeft}]}`
  - `GET /exam/enter_exam/1/{examInfoId}`(新卷步骤 0,跟随重定向)
  - `POST /exam/faceCheckCondition` — 表单 `[examInfoId]`
  - `POST /exam/start_exam_queue` — 表单 `[examId]`;成功 = `bizContent.isOk == true` **或** `code == "60011"`
  - `POST /exam/check_queue_status` — 表单 `[examId]`;轮询 ≤30 次 × 2s 至 `isOk`
  - `POST /exam/test_complete` — 表单 `[examId]`;轮询 ≤30 次 × 2s 至 body(trim+小写)== `"true"`
  - `GET /exam/exam_start/{examInfoId}` — 返回考试 HTML 页(答题卡)
  - `POST /exam/get_question_info/` — 表单:`examResultsId`、`examInfoId`、`testIds`(逗号连接)、`uuids`(uuid 每题重复或 `"null"`,逗号连接)、`combId`(仅资料分析组合批);响应为裸 JSON 数组;每批 ≤50 题且不混 combId;解码失败重试 3 次 × 3s;**sessionExpired 不重试**
  - `POST /exam/exam_start_ing_multi` — 表单:`examTestList` = JSON 字符串数组 `[{exam_results_id, test_id, test_ans, exam_info_id, correct}]`、`timeStamp` = 毫秒;`test_ans` 键带尾逗号:`"key1,"` / `"key1,key3,"`
  - `POST /exam/exam_question_mark` — 表单:`test_id`、`exam_results_id`、`exam_info_id`、`isMark="1"|"0"`、`timeStamp`
  - `POST /exam/get_remian_time` — 表单 `[examResultId]`(上游拼写错误 `remian`,保持)
  - `GET /exam/exam_ending?examInfoId={infoId}&examResultsId={resultsId}&isForce=0&switchScreen=0&noOpsAutoCommit=0` — 跳结果页;成功守卫:响应含 `class="score"`(大小写不敏感),否则 `APIError.upstream("考试未能结束，请刷新后重试")`
  - `POST /login/public/logout` — Referer `baseURL/exam/pc/home/`,关闭过期检测
- 各请求 Referer:作答/标记/交卷用 `baseURL/exam/exam_start/{examInfoId}`;进卷用 `baseURL/exam/before_answer_notice/{examInfoId}`
- Cookie:`sessionId`(会话存在性)、`JSESSIONID`;尊重 Set-Cookie 的 domain/path/secure
- **会话过期三规则**(命中即清 cookie + 抛 sessionExpired):(1) 任一重定向目标路径含 `/login/account/login`;(2) body 含 `/login/account/login` 且含 `<!DOCTYPE`(大小写不敏感);(3) 正则 `"onlineStatus"\s*:\s*"?0"?` 匹配
- 结果页正则:`class="score"[^>]*>\s*([\d.]+)\s*<`(兜底 "0");`exam-result-percentage[^>]*>\s*(\d+)` 第一个匹配 = beatRate(兜底 "?"),第二个 = rank(兜底第一个或 "?")
- 考试 HTML 契约:JS 变量 `exam_results_id`/`exam_info_id`;section div class 含 `card-content-title`(容忍尾随空格);组合题容器 class 含 `insert-list` + `questionsId` 属性;卡片锚 `href="#..."`;卡片属性 `questionsId`/`uuId`;题号 `<span>N</span>` 或 `N.N`;状态 div class token `question_cbox` + `right`/`error`/`marked`;无标题 section 归 `(无分类)`

### 3.2 本地数据契约

- 目录:`filesDir/LanjingQuiz/`:`bank/<大类>.jsonl` × 5、`bank/meta.json`、`bank/crawl_log.jsonl`、`practice-session.json`、`practice-progress.json`
- JSONL 行键(精确):`_id`、`category`、`section`、`subCategory`、`question`、`stem`、`options`、`answer`、`analysis`、`sourceExamName`、`round`、`collectedAt`;`answer` 三态:字符串 `"A"`(单选)/ 数组 `["A","C"]`(多选)/ null 或缺失(无答案);`options` 恒 4 槽,空串 = 填空;未知多余键(如 `sourceExamId`)忽略不报错;仅 `_id` 必需,缺失字段容错为默认值
- meta.json 键:`version`、`round`、`lastRun`、`targets`、`counts`(大类→Int)、`papers`(paperId→true);**文件名字恒从硬编码 `BankLogic.categories` 派生,绝不从 `targets` 派生**(历史错别字 "语言理解")
- crawl_log.jsonl 行键:`timestamp`(ISO8601)、`paperId`(String?,paperList 步为 null)、`paperName`、`step`、`outcome`、`message`(String?);`step ∈ paperList|enter|save|endAttempt|skip`;`outcome ∈ success|failure|skipped`
- 五大类中文串(数据契约键,不可本地化):`言语理解`、`数字运算`、`逻辑推理`、`资料分析`、`特有题型`;兜底 `未分类`;section 占位 `(无分类)`;试卷 style 标记 `机考题库`
- 练习会话 JSON(`practice-session.json`):`PracticeSession{category, subCategory, questions, index, answers}`;`PracticeAnswer{selected, revealed, correct}`(correct 三态 true/false/null);`selected` 是集合语义——**读入时不比较数组顺序**(iOS 写出的 Set 编码顺序不定),自己写出时归一化排序
- 进度注册表(`practice-progress.json`):字典,键 `"<category>/<subCategory>"` → `{"answeredIDs": [string]}`;answeredIDs 去重;大类聚合 = 键前缀 `<category>/` 求和

### 3.3 分类器规则(爬取时写 subCategory)

- 移植 `apps/bank/lib/question-classifier.js`(iOS 已移植一次,可对照 `QuestionClassifier.swift` 与 `QuestionClassifierTests.swift` 的用例)
- `特有题型`/`资料分析` 两卷绕过规则引擎:答题卡 HTML section 即 subCategory,空 section → `其他`
- HTML 剥离顺序(严格):`<[^>]*>` → " " → `&nbsp;` → " "(大小写不敏感)→ `&lt;` → "<" → `&gt;` → ">" → `&amp;` → "&" → `&quot;` → `"` → `&#\d+;` → " "(大小写不敏感)→ `\s+` → " " → trim;**`&ldquo;/&rdquo;` 故意不解码**(规则匹配原文全角引号)
- section 清洗:仅剥离尾部 `\(共[^)]*\)\s*$`(全角括号),如 `逻辑填空(共200题,每题1分,合计200.0分)` → `逻辑填空`;空/纯空白 → `(无分类)`

### 3.4 CookieCloud 契约

- 端点:`POST {server}/update`(body JSON:`uuid`、`encrypted`、`crypto_type`;成功 iff HTTP < 300 且 `{"action": "done"}`);`GET {server}/get/{uuid}`(404 = 空云端)
- `crypto_type`:`"aes-128-cbc-fixed"`(本 app 恒推送此值)/ `"legacy"`;未知类型 fail-closed
- 固定格式:裸 base64 的 AES-128-CBC PKCS7 密文;key = `"{uuid}-{password}"` 的 MD5 小写 hex 前 16 字符的 UTF-8 字节;IV = 16 个零字节
- legacy 格式:base64 的 `"Salted__"`(8 字符)+ 8 字节随机盐 + AES-256-CBC PKCS7;EVP_BytesToKey MD5(key=32B, IV=16B)
- 解密规则:先按声明类型,失败再试另一算法,双失败抛最后错误;解密结果非 UTF-8 → 拒绝;同 iOS 测试互操作向量必须通过
- 上传 payload:`{"cookie_data": {domain → [cookie]}, "local_storage_data": {}}`;cookie 字段:`name`、`value`、`domain`、`path`、`secure`、`expirationDate`(epoch 秒)、`session`(仅会话 cookie)、`sameSite`("lax"/"strict","none" 不写)
- 导入:仅 `domain 含 "lanjingweike.com"` 的 cookie 生效;且必须含名为 `sessionId` 的 cookie;`secure` 缺省 true、`path` 缺省 "/"
- 同步时机:登录后 push(去重 hash = cookieData 的 sortedKeys JSON 的 SHA-256 hex,记录于 `quiz.cookieCloud.lastPushedHash`);启动 pull 限 4s;我的页手动同步双向探活(本地会话过期则不覆盖、云端过期则不推送)
- 探活:POST `{baseURL}/exam/current_exam_list` body `page=1&pageSize=1`,过期检测三规则判定有效性;探活用无 cookie 持久化的独立 client

### 3.5 设计系统与字符串

- DS 调色板 hex(映射 M3 ColorScheme):accent `0x58cc02`、accentHover `0x61e002`、accentActive `0x58a700`、orange `0xff9600`、blue `0x1cb0f6`、pink `0xce82ff`、red `0xff4b4b`、yellow `0xffc800`、gray `0xafafaf`;圆角 12/16/20/9999
- HTML 渲染模板:viewport meta;body 前景 `#3c3c3c`(浅)/ `#ffffff`(深);字号模板 `"{size}px/1.55 -apple-system, BlinkMacSystemFont, sans-serif"`(安卓换系统 sans-serif);背景全透明 `*{background-color: transparent !important}`;暗色加 `color: inherit !important`(html/body 自身不受此规则,它们带 `color: <fg> !important`);图片 src 优先 `src` 后 `data-src`,实体解码 `&amp; &lt; &gt; &quot;`,拒绝 `data:` URI,相对路径按上游 base 解析
- 顶部 Tab 文案:考试列表 / 练习 / 我的;用户可见字符串(登录、考试、练习、我的)全部按 iOS 逐字移植,详见各功能章节与 iOS 蓝本
- 通知文案:"登录已过期，请重新登录"、"登录已失效，请重新登录"、"题库已删除，重新进入练习页会重新爬取全部试卷"
- API 错误文案:"未登录"、"无法获取考试记录 ID"、"服务器响应异常"、"网络错误：{msg}"、"进入考试失败"、"考试未能结束，请刷新后重试"、"获取考试列表失败"、"登录失败"

### 3.6 行为常量

- 考试:每未答题 60s 倒计时(mmss `%02d:%02d`,答过题停表 "01:00",过期 "00:00");答对自动下一题(默认关,键 `quiz.autoAdvanceOnCorrect`,仅答对触发,延迟 1200ms,手动导航取消);答题卡 7 列弹性、dot 36dp、当前题 3dp 蓝圈、marked 🔖;进度条高 16dp
- 练习:连续 3 卷进入失败停止增量爬取;增量爬每卷后存 meta;刷新爬任一失败不提交;`round` 每次完成 +1;`lastRun` = ISO8601 当前时间
- 洗牌:SplitMix64 常量 `0x9E3779B97F4A7C15`、`0xBF58476D1CE4E5B9`、`0x94D049BB133111EB`,每次会话随机种子;资料分析同材料组合题保持相邻、组内顺序不变;`practice.shuffle.<大类>` 默认 false
- 网络:请求超时 30s;OKHttp 禁缓存;队列轮询 2s、批重试 3s

## 四、功能行为基准(考试)

- 考试列表:过滤卷名含 `常识判断` 的项;按 style 分组,含 `机考题库` 的组排前,组内按 style 名排序;`wfs==1` 显示 "新试卷" 走新卷流程,否则 "继续考试";放弃考试后抑制陈旧记录(按 id+wfs 精确匹配丢弃,服务端返回新 wfs 时解除)
- 逐题作答:单选点选立即上报并判定;多选点选仅切换待选集,出现 `提交` 按钮,确认后按完整集合判定并上报(字母 A-D 排序);🔖 乐观标记 + fire-and-forget 上报,失败回滚(过期类错误除外)
- 判定上色(仅在作答后):选中且错 → 红;正确答案 → 绿(多选答错时参考答案仍 ✅);其余 → 原色
- 状态恢复:进入/继续考试时从 exam_start HTML 解析 right/error/unanswered + marked;已选恢复自 `test_ans`(`"key1,key3,"` → {A,C});当前题 = 第一个未答题
- 答题卡:raw 题号("1.1" 组合子题原样显示);答对绿/答错红/未答灰/当前蓝圈;section 过滤(含 "全部");自动滚动当前题居中;点题跳转(目标题状态从 answers 恢复)
- 交卷:两段确认 `确定提交试卷吗？`;放弃:确认 `确定放弃「{name}」吗？放弃后本次作答将直接交卷。`;`isSubmitting` 防重入
- 结果:分数 `{score} 分`、`击败全国 {beatRate}% 的考生`、`当前排名 #{rank}`
- 自动下一题目标:`nextIndex(after:)` 循环扫描第一个 `.unanswered`,全答完则 `min(index+1, count-1)`

## 五、功能行为基准(练习)

- 爬取目标:style 含 `机考题库` 且卷名含五大类之一(首次命中优先)
- 尝试生命周期:`wfs=1` 进卷创建新作答,抓取后 fire-and-forget `submitExam(paper.id, session)`(全部错误吞掉);`wfs=0` 只读永不结束;练习答案**永不**上报上游
- 恢复规则:存档可恢复 iff `category`、`subCategory` 相等 且 未完成 且 存档题目 ID 集合 == 当前筛选后题目 ID 集合(顺序无关);恢复后不复洗、不重复持久化
- 判定:单选即点即判;多选 `提交` 后按集合相等判;无答案(answer null)点选 → selected=[字母]、revealed=true、correct=nil(计 answeredCount 与进度注册表,不计对错)
- 统计派生:rightCount/wrongCount/answeredCount 全部从 answers 派生(无答案 reveal 不算错);进度 = index/questions.count
- 入口进度行:answered > 0 显示 `x/N`,否则 `N 题`;大类行聚合所有子类;分类列表 footer `题库版本 round <n> · 共 <n> 题`
- 练习底栏:答对/答错/未答统计 + 答题卡入口,**无交卷按钮**;答题卡 overlay、当前题自动居中、跳转持久化 index
- 题库管理:更新题库(重爬全部 + 成功才原子替换 + 清 session/progress);删除题库(清空 bank + 日志 + session/progress,通知"题库已删除…",bankResetVersion 触发重爬);日志导出 `爬取日志_yyyyMMdd_HHmm.txt`(FileProvider)
- 错误面:题库缺失 → "本地题库缺少 <大类>.jsonl，请在 我的 > 更新题库 重新爬取";爬取失败 → "题库爬取失败 / 请检查网络后重试；已爬取的题目会保留，重试会从中断处继续。";批量失败 → "重试 2 次后仍失败；{detail}";刷新失败 → "{N} 份试卷爬取失败：{names}"

## 六、我的 + CookieCloud

- 我的页:账户(已登录)、外观(跟随系统/深色模式)、答题设置(答对后自动下一题)、题库设置(更新/删除/日志导出)、Cookie 云端同步(服务器地址/UUID/密码/立即同步 + 状态)、退出登录(先 best-effort 调上游 logout,再清本地,失败也清)、版本 `1.0 (1)` 格式
- 同步状态文案:同步完成 + 已导入云端会话 / 已上传本地会话(逗号连接);未配置时错误文案 `CookieCloud 同步未配置`

## 七、测试策略

| 层 | 覆盖 | 工具 |
|---|---|---|
| JVM 单元测试 | 考试/结果 HTML 解析、过期三规则、表单编码(SHA256/MD5/空白剥离/`@1` 后缀)、JSONL 容错解析(未知键/缺键/三态 answer)、分类器(iOS + web 收集器同用例)、CookieCloud 加解密(iOS 互操作向量)、SplitMix64 确定性、恢复规则、进度聚合、hashers | JUnit + kotlinx-coroutines-test |
| 仪器化 UI 测试 | MockWebServer 复刻 MockUpstreamServer 全部路由与 wfs 语义;登录→列表→答题→答题卡→交卷→结果;练习:爬取→刷题→进度恢复;封闭原则:不触真实上游 | Compose UI Test + MockWebServer |
| 构建 | `./gradlew test assembleDebug` 本地与 CI | Gradle + AGP 8.x |

测试红线:iOS 全部单元测试用例(180 项)中有可移植价值的逐项对齐;iOS 蓝本中的互操作向量(登录哈希、CookieCloud 密文、分类规则、洗牌序列)必须通过。

## 八、CI 与发布

- `ci-android.yml`:dorny/paths-filter 门控(`apps/android/**` 或本文件变更才跑,否则 job 跳过且 check 自动通过,与 ci-ios 一致);ubuntu-latest + JDK 17 + setup-java + gradle/actions/setup-gradle 缓存;job: unit(单元 + assembleDebug)、ui(模拟器 API 35,固定 AVD 名 `pixel_6_api_35`)
- `release.yml` 扩展:新增 producer `android-apk`(always):`./gradlew assembleRelease`(未签名,安卓可直接安装)→ 上传 `LanjingQuiz-android-<version>.apk` 至 release job 合并;版本复用 `vX.Y.Z`;versionCode 从版本号派生单调整数(如 `versionCode = major*10000 + minor*100 + patch`);签名 keystore 预留 secrets(ANDROID_KEYSTORE_BASE64 / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD),接线与否后续再定
- 根 README 的组件表补充安卓行;`apps/android/README.md` 说明构建/测试/运行

## 九、实施阶段(供计划拆解)

1. **T0 工程脚手架**:Gradle 多模块?否——单模块;版本目录、Hilt、M3 主题、三 Tab 壳、路由骨架、ci-android.yml —— 可构建可跑
2. **T1 网络与认证**:DTO、PersistentCookieJar、APIClient(端点全家桶+过期三规则)、登录表单、会话恢复/清理、MockWebServer 测试基建
3. **T2 考试模块**:列表(分组/过滤/放弃抑制)→ 进入队列轮询 → 题目批拉取 → WebView 渲染 → 作答/标记 → 答题卡 → 交卷 → 结果页
4. **T3 练习模块**:爬取器(wfs 生命周期/断点/原子更新)、JSONL 存储、分类器、两级列表 + x/N 进度、刷题会话(判定/恢复/洗牌/底栏/答题卡)、进度注册表
5. **T4 我的 + CookieCloud**:设置项、AES-CBC 同步(双向探活)、日志导出
6. **T5 收尾**:UI 测试补齐、README、release.yml 接线、全量验证

每个阶段独立可测;测试与 iOS 用例一一对应。
