# 蓝鲸微课考试平台 API 接口文档

> **测试环境**：`https://test.lanjingweike.com`
>
> **文档版本**：v2.1
>
> **最后更新**：2026-06-15

---

## 目录

1. [通用约定](#1-通用约定)
2. [接口列表](#2-接口列表)
   - [2.1 获取会话 ID](#21-获取会话-id)
   - [2.2 登录](#22-登录)
   - [2.3 获取考试列表](#23-获取考试列表)
   - [2.4 进入考试（继续考试）](#24-进入考试继续考试)
   - [2.5 新考试初始化流程](#25-新考试初始化流程)
   - [2.6 批量获取题目详情](#26-批量获取题目详情)
   - [2.7 提交答案](#27-提交答案)
3. [考试页面 HTML 解析规范](#3-考试页面-html-解析规范)
4. [业务流程](#4-业务流程)
5. [附录](#5-附录)

---

## 1. 通用约定

### 1.1 基础 URL

所有请求路径均基于以下地址拼接：

```
https://test.lanjingweike.com
```

### 1.2 公共请求头

除特殊说明外，所有接口均需携带以下请求头：

```http
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0
X-Requested-With: XMLHttpRequest
Origin: https://test.lanjingweike.com
Referer: https://test.lanjingweike.com/exam
Accept: application/json, text/javascript, */*; q=0.01
sec-ch-ua: "Microsoft Edge";v="149", "Chromium";v="149", "Not)A;Brand";v="24"
sec-ch-ua-mobile: ?0
sec-ch-ua-platform: "Windows"
```

POST 请求额外补充：

```http
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
```

> **注意**：某些接口（特别是新考试初始化流程中的接口）对 `Referer` 有严格要求，必须设置为前置页面的完整 URL，否则服务端可能拒绝处理。

### 1.3 认证与 Cookie

| 阶段 | Cookie | 来源 | 说明 |
|------|--------|------|------|
| 会话初始化 | `JSESSIONID` | `GET /` 响应头 `Set-Cookie` | 标识浏览器会话 |
| 登录后 | `sessionId` | `POST /login/account/login` 响应头 `Set-Cookie` | 标识已登录用户 |
| 考试过程中 | `KSX_CID=1` | 部分接口响应头 | 考试环境标识 |

- 后续所有请求均需在 `Cookie` 头中携带以上全部 Cookie
- `sessionId` 有效期约 48 小时，过期后需重新登录
- 可通过文件持久化 Cookie 以复用会话，避免频繁登录

### 1.4 通用响应结构

所有 JSON 接口均遵循以下格式：

```json
{
  "code": 10000,
  "desc": "成功",
  "englishDesc": "Success",
  "success": true,
  "bizContent": { }
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `code` | int | 业务状态码，见 [附录 A](#a-错误码表) |
| `desc` | string | 中文状态描述 |
| `englishDesc` | string | 英文状态描述 |
| `success` | bool | 请求是否成功 |
| `bizContent` | object | 业务数据，结构视具体接口而定 |

### 1.5 重定向策略

所有请求均应设置 `redirect: "manual"`，原因如下：

- 登录接口的 302 重定向中包含 `Set-Cookie: sessionId`，自动跟随将丢失此 Cookie
- 继续考试时，直接访问 `exam_start` 可能触发 302 跳转至考前说明页，手动处理可判断考试状态

---

## 2. 接口列表

### 2.1 获取会话 ID

初始化浏览器会话，获取后续请求所需的 `JSESSIONID`。

#### 请求

```http
GET /
```

#### 响应

- `Status: 200`
- `Content-Type: text/html`
- `Set-Cookie: JSESSIONID={value}; Path=/; HttpOnly`
- 响应体为首页 HTML，无需解析

---

### 2.2 登录

#### 请求

```http
POST /login/account/login
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
```

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|:----:|------|
| `userName` | string | ✓ | 完整用户名，格式 `手机号@公司ID`，如 `13800000000@1` |
| `userNameInput` | string | ✓ | 纯手机号，即 `@` 之前的部分 |
| `password` | string | ✓ | 明文密码经 **SHA256** 哈希后的 64 位十六进制小写字符串 |
| `passwordMD5` | string | ✓ | 明文密码经 **MD5** 哈希后的 32 位十六进制小写字符串 |
| `companyId` | string | ✓ | 公司 ID，固定值 `"1"` |
| `newCompanyId` | string | ✓ | 固定值 `"1"` |
| `remember` | string | | 固定 `"false"` |
| `phoneAccount` | string | | 留空 |
| `authCode` | string | | 短信验证码（留空） |
| `captchaText` | string | | 图形验证码（留空） |
| `nextUrl` | string | | 登录后跳转地址（留空） |

> **说明**：平台要求同时提交明文密码的 SHA256 与 MD5 值。MD5 已不被视为安全算法，此处仅为兼容后端旧有校验逻辑。

#### 成功响应

```json
{
  "code": 10000,
  "success": true,
  "desc": "成功",
  "bizContent": {
    "url": "/exam/pc/home/#/",
    "role": "staff"
  }
}
```

| 字段 | 说明 |
|------|------|
| `bizContent.url` | 登录后前端的跳转路径 |
| `bizContent.role` | 用户角色标识，`staff` 表示普通考生 |

- 响应头 `Set-Cookie` 包含 `sessionId`，后续所有请求须携带

#### 失败响应

```json
{
  "code": -1,
  "success": false,
  "desc": "密码错误"
}
```

---

### 2.3 获取考试列表

获取当前用户有权限访问的全部考试与练习。

#### 请求

```http
POST /exam/current_exam_list
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
```

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|:----:|------|
| `examStyle` | string | ✓ | 分类筛选，`"0"` 表示不筛选、返回全部 |
| `timeSort` | string | | 时间排序方式，留空表示默认 |
| `status` | string | | 状态筛选，留空表示全部 |
| `setProcess` | string | ✓ | 固定值 `"-1"` |
| `page` | string | ✓ | 页码，起始值为 `"1"` |
| `firstVisit` | string | ✓ | 是否首次访问，`"true"` 或 `"false"` |
| `name` | string | | 按名称模糊搜索，留空表示全部 |
| `rowCount` | string | ✓ | 每页条数，建议设为 `"100"` 以单次拉取全部 |
| `participation` | string | | 参与状态筛选，留空表示全部 |

#### 成功响应

```json
{
  "code": 10000,
  "success": true,
  "bizContent": {
    "total": 34,
    "styles": [
      { "id": 1052373, "name": "【中石化模考套餐（2027年度）】" },
      { "id": 1052372, "name": "【机考题库（2027年度）】" }
    ],
    "examInfoModelList": [ { } ]
  }
}
```

##### `bizContent` 字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `total` | int | 符合条件的考试总数 |
| `styles` | array | 分类/风格列表 |
| `styles[].id` | int | 分类唯一标识 |
| `styles[].name` | string | 分类显示名称 |
| `examInfoModelList` | array | 考试详情列表 |

##### `examInfoModelList` 条目核心字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | int | **考试唯一标识**（进入考试、获取题目的核心参数） |
| `examName` | string | 考试名称 |
| `examStyle` | int | 所属分类 ID，关联 `styles[].id` |
| `examStyleName` | string | 分类名称（服务端通常返回 `"未初始化"`，应通过 `styles` 查找） |
| `paperInfoId` | int | 试卷模板 ID |
| `practiceMode` | int | 考试模式：`0` = 正式模拟考试，`1` = MOCK，`2` = 刷题练习 |
| `examMode` | string | 考试类型，`"1"` 为标准模式 |
| `examTime` | int | 考试限时（**分钟**），`0` 表示不限时 |
| `examTimeRestrict` | string | 是否限时：`"0"` 不限时，`"1"` 限时 |
| `examTimesNum` | int | 允许作答次数 |
| `examTimesRestrict` | string | 是否限次：`"0"` 不限次，`"1"` 限次 |
| `wfs` | int | **作答状态**：`0` = 已有作答记录，`1` = 从未作答 |
| `timeLeft` | int | 剩余可用时间（**秒**），`0` 表示无限制或未开始 |
| `paid` | bool | 是否已付费（对于付费考试） |
| `status` | string | 发布状态，`"0"` 表示已发布 |
| `examStartTime` | string | 考试开放起始时间（`yyyy-MM-dd HH:mm`） |
| `examEndTime` | string | 考试开放截止时间（`yyyy-MM-dd HH:mm`） |
| `beforeAnswerNotice` | string | 考前须知文本（可能包含 `\r\n` 换行符） |

> 完整字段列表见 [附录 B](#b-examInfoModelList-完整字段)。

---

### 2.4 进入考试（继续考试）

对于已有作答记录的考试（`wfs = 0`），可直接访问考试页面。

#### 请求

```http
GET /exam/exam_start/{examInfoId}
```

#### 说明

- `examInfoId` 来自 [2.3](#23-获取考试列表) 返回的 `id`
- 必须设置 `redirect: "manual"` 防止自动跳转
- 页面 HTML 的解析规范见 [第 3 章](#3-考试页面-html-解析规范)

---

### 2.5 新考试初始化流程

对于从未作答的考试（`wfs = 1`），**不可直接访问 `exam_start`**，必须先执行以下初始化流程。该流程模拟浏览器端 JavaScript 的完整交互逻辑。

#### 流程概览

```
Step 0:  GET  /exam/enter_exam/1/{examInfoId}    → 302 重定向
Step 1:  POST /exam/faceCheckCondition            → 检查是否需要人脸核验
Step 2:  POST /exam/start_exam_queue              → 发起考试排队
Step 3:  POST /exam/check_queue_status            → 轮询排队状态（可能重复多次）
Step 4:  POST /exam/test_complete                 → 轮询组卷状态（可能重复多次）
Step 5:  GET  /exam/exam_start/{examInfoId}       → 获取考试页面 HTML
```

> 该流程源于 `before_answer_notice` 页面中「开始答题」按钮的 JS 逻辑。不同考试类型（普通/严肃/付费/人脸核验）可能在中途分支，本文档以最常见的普通练习考试为主线。

---

#### Step 0：进入考试入口

```http
GET /exam/enter_exam/1/{examInfoId}
```

- 浏览器端自动跟随 302 重定向，服务端可能在重定向过程中写入会话状态
- 最终落点（302 的 `Location`）为 `/exam/before_answer_notice/{examInfoId}`
- 实现时需**跟随重定向**，并捕获途中所有 `Set-Cookie`

---

#### Step 1：人脸核验条件检查

```http
POST /exam/faceCheckCondition
```

| 参数 | 类型 | 说明 |
|------|------|------|
| `examInfoId` | string | 考试 ID |

**响应示例**：

```json
{
  "success": true,
  "bizContent": {
    "condition": 0
  }
}
```

| `condition` 值 | 含义 | 后续操作 |
|:---:|---|---|
| `0` | 无需核验 | 直接进入 Step 2 |
| `1` | 需拍照核验 | 弹窗采集照片，核验通过后进入 Step 2 |
| `2` | 未上传核验照片 | 终止流程 |
| `3` | 人脸识别余额不足 | 终止流程 |

> 普通练习考试（`practiceMode = 2`，未开启监考）通常返回 `condition = 0`。

---

#### Step 2：发起考试排队

```http
POST /exam/start_exam_queue
```

| 参数 | 类型 | 说明 |
|------|------|------|
| `examId` | string | 考试 ID |

> ⚠️ 注意此接口的参数名为 `examId`，而非 `examInfoId`。

**响应示例**：

```json
{
  "success": true,
  "bizContent": {
    "isOk": true,
    "waitTime": 0
  }
}
```

| 字段 | 说明 |
|------|------|
| `bizContent.isOk` | `true` = 无需排队，直接进入组卷；`false` = 需要排队，进入 Step 3 轮询 |
| `bizContent.waitTime` | 预计等待秒数（仅当 `isOk = false` 时有意义） |

**特殊错误码**：

| code | 含义 | 处理方式 |
|------|------|---------|
| `60011` | 免排队 | 视同 `isOk = true`，直接进入 Step 4 |
| `50012` | 考试尚未开始 | 终止流程或等待开放时间 |

---

#### Step 3：轮询排队状态

```http
POST /exam/check_queue_status
```

| 参数 | 类型 | 说明 |
|------|------|------|
| `examId` | string | 考试 ID |

> ⚠️ 仅当 Step 2 返回 `isOk = false` 时才需调用此接口。

- 轮询间隔：建议 **2 秒**
- 终止条件：`bizContent.isOk` 变为 `true` 或超时（建议最多 30 次）
- 请求超时建议设为 15 秒

---

#### Step 4：轮询组卷完成状态

```http
POST /exam/test_complete
```

| 参数 | 类型 | 说明 |
|------|------|------|
| `examId` | string | 考试 ID |

- 响应体为纯文本（非 JSON）：`true` 表示组卷完成，`false` 表示仍在组卷
- 轮询间隔：**2 秒**
- 终止条件：响应体为 `true` 或超时（建议最多 30 次）
- JavaScript 端使用 `async: false` 同步 AJAX 调用此接口

> 浏览器端实际会在 `test_complete` 之前调用 `check_hard_over_count`（检查试题数量是否超限）。该接口参数为 `examId` 与 `setIpRange`，非超限场景下返回 `success = false`（即为可继续），对普通练习可省略。

---

#### Step 5：进入考试

同 [2.4](#24-进入考试继续考试)。

---

### 2.6 批量获取题目详情

获取指定题目的完整内容、选项及正确答案。

#### 请求

```http
POST /exam/get_question_info/
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
```

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|:----:|------|
| `examResultsId` | string | ✓ | 考试结果 ID |
| `examInfoId` | string | ✓ | 考试信息 ID |
| `testIds` | string | ✓ | 题目 ID 列表，以逗号 `,` 分隔 |
| `uuids` | string | ✓ | 与 `testIds` 一一对应的 `uuid`，以逗号 `,` 分隔（所有题目共享同一 uuid 值） |

> **建议**：单次请求不超过 **50** 题。超出时应分批请求。

#### 成功响应

```json
[
  {
    "_id": 12345,
    "question": "<p>题目正文（可含 HTML 标签）</p>",
    "difficult": 1,
    "test_ans_right": "A",
    "key1": "1",
    "key2": "0",
    "key3": "0",
    "key4": "0",
    "answer1": "<p>选项 A 内容</p>",
    "answer2": "<p>选项 B 内容</p>",
    "answer3": "<p>选项 C 内容</p>",
    "answer4": "<p>选项 D 内容</p>"
  }
]
```

#### 题目对象字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `_id` | int | 题目唯一标识 |
| `question` | string | 题目正文（可能包含 `<p>`、`<img>`、`<table>` 等 HTML 标签） |
| `difficult` | int/string | 难度等级 |
| `key1` ~ `key4` | string | 正确答案标记：`"1"` 表示该选项为正确答案，`"0"` 表示非正确答案 |
| `answer1` ~ `answer4` | string | 四个选项的 HTML 内容 |
| `test_ans_right` | string | 正确答案字母（备选回退字段） |

#### 正确答案判断逻辑

按优先级：

1. 遍历 `key1` ~ `key4`，值为 `"1"` 者即为正确答案
2. 若四项均为 `"0"`，则回退使用 `test_ans_right` 字段

| `keyN` | 对应选项 | 答案字母 |
|--------|---------|:------:|
| `key1` | `answer1` | A |
| `key2` | `answer2` | B |
| `key3` | `answer3` | C |
| `key4` | `answer4` | D |

---

### 2.7 提交答案

作答后上报单题答案。

#### 请求

```http
POST /exam/exam_start_ing_multi
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
```

#### 请求参数

| 参数 | 类型 | 说明 |
|------|------|------|
| `examTestList` | string | JSON 序列化的答案数组（需 URL encode） |
| `timeStamp` | string | 毫秒时间戳 |

`examTestList` 解码后结构：

```json
[{
  "exam_results_id": "87380582",
  "test_id": "661e26a4ee9c16509b879ea7",
  "test_ans": "key3,",
  "exam_info_id": "1439658",
  "correct": false
}]
```

| 字段 | 说明 |
|------|------|
| `exam_results_id` | 考试结果 ID |
| `test_id` | 题目 questionsId |
| `test_ans` | 答案键，格式 `keyN,`，多选用逗号拼接，如 `key1,key3,` |
| `exam_info_id` | 考试信息 ID |
| `correct` | 是否正确 |

答案键对照：

| `test_ans` | 含义 |
|-----------|------|
| `key1,` | 选 A |
| `key2,` | 选 B |
| `key3,` | 选 C |
| `key4,` | 选 D |
| `key1,key3,` | 选 A 和 C（多选） |

> **注意**：即使单选，末尾逗号也需保留。

---

## 3. 考试页面 HTML 解析规范

考试页面（`/exam/exam_start/{id}`）为服务端渲染的完整 HTML 页面，需从中提取以下结构化数据。

### 3.1 JavaScript 变量提取

从 `<script>` 标签中按正则提取：

```js
var exam_results_id = '87380582';      // 考试结果 ID（本次作答会话）
var exam_info_id    = '1439658';       // 考试信息 ID
var uuId            = '7404753692344238080';  // 用户唯一标识
```

正则模式：`/var\s+变量名\s*=\s*['"]([^'"]+)['"]/`

### 3.2 答题卡题目状态解析

每道题在答题卡中以 `<a>` 包裹的 `<div>` 呈现，class 直接反映作答状态。

#### HTML 结构

```html
<a href="#6620dfdfee9c16509b87a928">
  <div class="box normal-box question_cbox s2 practice-mode-2 right">
    <span class="iconBox currentThemeBackgroundColor questions_xxx"
          questionsId="6620dfdfee9c16509b87a928"
          uuId="7404753692344238080"
          num="questions_xxx" perScore="" timeInterval="">1</span>
    <span class="icon-box question_marked icon-p_exam_tag_se"></span>
    <span class="icon-box unsaved_mark icon-a_warning"></span>
  </div>
</a>
```

#### 作答状态对照

| `<div>` class 模式 | 含义 |
|---|---|
| `question_cbox s1 practice-mode-N` | 尚未作答 |
| `question_cbox s2 practice-mode-N right` | 已作答，回答正确 |
| `question_cbox s2 practice-mode-N error` | 已作答，回答错误 |

- `s1` = Section 1（未作答阶段）
- `s2` = Section 2（已作答阶段）
- `right` / `error` 仅在 `s2` 状态下出现

#### 关于 `marked` 与 `unsaved` 标记

```html
<span class="icon-box question_marked icon-p_exam_tag_se"></span>
<span class="icon-box unsaved_mark icon-a_warning"></span>
```

这两个 `<span>` 在服务端渲染的 HTML 中**每题均存在**（为模板固定元素），其是否可见由前端 JavaScript 动态控制。通过解析静态 HTML **无法可靠判断**某题是否真的被标记或未保存，不应作为提取依据。

#### 提取参数汇总

| 参数 | 来源 | 提取方式 |
|------|------|---------|
| `examResultsId` | JS 变量 `exam_results_id` | 正则提取 |
| `examInfoId` | JS 变量 `exam_info_id` | 正则提取 |
| `uuid` | `<span>` 属性 `uuId` | 正则提取（所有题目共享同一值） |
| `questionsId` | `<span>` 属性 `questionsId` | 正则提取 |
| 题号 | `<span>` 文本内容 | 正则提取 `>(\d+)<\/span>` |
| 作答状态 | `<div>` class 中的 `right` / `error` | 正则提取，无则为 `unanswered` |

### 3.3 分区（Section）结构

部分考试试卷按知识板块分节，每节在答题卡中对应一个 `card-content` 区块。

#### HTML 结构

```html
<div class="card-content-list">
  <div class="card-content">
    <div class="card-content-title">科技常识(共50题,每题1分,合计50.0分)</div>
    <div class="box-list">
      <!-- 该节全部题目卡片 -->
    </div>
  </div>
  <div class="card-content">
    <div class="card-content-title">人文常识(共50题,每题1分,合计50.0分)</div>
    <div class="box-list">
      <!-- 该节全部题目卡片 -->
    </div>
  </div>
</div>
```

#### 分区归属判断

- 提取所有 `card-content-title` 文本及其在 HTML 中的位置
- 对每道题，根据其 `questionsId` 在 HTML 中出现的位置，判断归属于哪个分区

---

## 4. 业务流程

### 4.1 继续考试（`wfs = 0`）

```
① GET  /                            → 获取 JSESSIONID
② POST /login/account/login         → 登录，获取 sessionId
③ POST /exam/current_exam_list      → 获取考试列表
④ GET  /exam/exam_start/{id}        → 获取考试页面 HTML（含答题卡）
⑤ POST /exam/get_question_info/     → 分批获取题目详情与答案
⑥ POST /exam/exam_start_ing_multi   → 逐题提交作答结果
```

### 4.2 新考试初始化（`wfs = 1`）

```
① GET  /                            → 获取 JSESSIONID
② POST /login/account/login         → 登录，获取 sessionId
③ POST /exam/current_exam_list      → 获取考试列表
④ GET  /exam/enter_exam/1/{id}      → 进入考试入口（跟随 302）
⑤ POST /exam/faceCheckCondition     → 检查人脸核验
⑥ POST /exam/start_exam_queue       → 发起排队
⑦ POST /exam/check_queue_status     → 轮询排队（如需排队）
⑧ POST /exam/test_complete          → 轮询组卷
⑨ GET  /exam/exam_start/{id}        → 获取考试页面 HTML（含答题卡）
⑩ POST /exam/get_question_info/     → 分批获取题目详情与答案
⑪ POST /exam/exam_start_ing_multi   → 逐题提交作答结果
```

---

## 5. 附录

### A. 错误码表

| code | 含义 |
|:----:|------|
| `10000` | 操作成功 |
| `-1` | 通用失败（详见 `desc` 字段） |
| `60011` | 免排队（`start_exam_queue` 特返回此码表示可直接进入组卷） |
| `50012` | 考试尚未到达开放时间 |

### B. `examInfoModelList` 完整字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | int | 考试唯一标识 |
| `examName` | string | 考试名称 |
| `examStyle` | int | 分类 ID |
| `examStyleName` | string | 分类名称 |
| `paperInfoId` | int | 试卷模板 ID |
| `practiceMode` | int | `0` 模拟考试 / `1` MOCK / `2` 练习 |
| `examMode` | string | 考试模式 |
| `examTime` | int | 限时（分钟），`0` 不限时 |
| `examTimeRestrict` | string | 是否限时 |
| `examTimesNum` | int | 允许作答次数 |
| `examTimesRestrict` | string | 是否限次 |
| `wfs` | int | `0` 有作答记录 / `1` 新试卷 |
| `timeLeft` | int | 剩余时间（秒） |
| `paid` | bool | 是否已付费 |
| `joinStatus` | int | 参与状态 |
| `status` | string | 发布状态 |
| `sortOrder` | int | 排序 |
| `createTime` | string | 创建时间 |
| `modifiedTime` | string | 修改时间 |
| `examStartTime` | string | 开放起始时间 |
| `examEndTime` | string | 开放截止时间 |
| `beforeAnswerNotice` | string | 考前须知 |
| `setReleaseNotice` | string | 发布公告 |
| `coverFile` | string | 封面图 URL |
| `prohibitScreenCutout` | int | 禁止切屏 |
| `setDisablePaste` | string | 禁止粘贴 |
| `setFullScreen` | string | 强制全屏 |
| `setRandomOrderTest` | string | 随机乱序 |
| `onebyoneMode` | int | 逐题模式 |
| `feedback` | int | 允许反馈 |
| `forSale` | int | 是否付费考试 |
| `isArchive` | int | 是否归档 |
| `isVisible` | int | 是否可见 |

### C. 接口参数命名差异

| 接口 | 参数名 |
|------|--------|
| `/exam/faceCheckCondition` | `examInfoId` |
| `/exam/start_exam_queue` | `examId` |
| `/exam/check_queue_status` | `examId` |
| `/exam/check_hard_over_count` | `examId` |
| `/exam/test_complete` | `examId` |
| `/exam/get_question_info/` | `examInfoId` |
| `/exam/exam_start/{id}` | 路径参数 |

> ⚠️ 排队与组卷相关接口的参数名为 `examId`，而非列表/进入接口使用的 `examInfoId`。二者值相同（均为考试 ID），但 key 不同。用错将导致服务端错误。

### D. 重要注意事项

1. **密码双哈希**：登录时须同时提交 SHA256 和 MD5 两种明文密码哈希，缺一不可。
2. **Cookie 持久化**：登录成功后将 Cookie 保存至文件，后续运行可直接读取以跳过登录（有效期约 48 小时）。
3. **重定向手动处理**：所有请求设置 `redirect: "manual"`，自行捕获并处理重定向响应，以保存 `Set-Cookie`。
4. **题目 ID 去重**：答题卡中同一 `questionsId` 可能在多处 DOM 位置出现，需做去重处理。
5. **批量请求分片**：`get_question_info` 单次建议不超过 50 题，超过时需分批并发请求。
6. **时间单位差异**：`examTime` 单位为**分钟**，`timeLeft` 单位为**秒**，`examStartTime` / `examEndTime` 为**日期字符串**。
7. **新/旧考试流程不同**：`wfs = 1` 必须走完整的初始化链（[4.2](#42-新考试初始化wfs--1)），不可直接访问 `exam_start`。
8. **分区信息**：`card-content-title` 元素仅在分节考试中存在，单区考试无此元素。
