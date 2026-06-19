# 蓝鲸答题助手 API 文档

> 文档版本：3.0
>
> 最后更新：2026-06-19
>
> 对应代码：`server.js`

本文档描述本项目本地 Express 后端对前端开放的 `/api/...` 接口，以及这些接口背后调用的蓝鲸微课考试平台上游接口。

## 目录

1. [通用约定](#1-通用约定)
2. [本地后端 API](#2-本地后端-api)
3. [上游接口映射](#3-上游接口映射)
4. [数据结构](#4-数据结构)
5. [错误与会话处理](#5-错误与会话处理)
6. [业务流程](#6-业务流程)

---

## 1. 通用约定

### 1.1 本地服务地址

默认端口由 `PORT` 环境变量控制，未设置时使用 `3000`。

```http
http://localhost:3000
```

### 1.2 请求格式

前端调用本地 API 时统一使用 JSON：

```http
Content-Type: application/json
```

GET 请求无请求体。POST 请求体为 JSON 对象。

### 1.3 登录状态

后端维护一个进程内 `cookieJar`，并在登录成功后将上游 Cookie 写入：

```text
session_cookies.txt
```

服务启动时会尝试读取该文件恢复会话。

除以下接口外，所有 `/api/...` 接口都要求后端已有 `sessionId`：

| Method | Path |
|---|---|
| `GET` | `/api/status` |
| `POST` | `/api/login` |

未登录时返回：

```json
{
  "error": "Not logged in"
}
```

HTTP 状态码为 `401`。

### 1.4 上游服务地址

后端代理调用的上游地址固定为：

```http
https://test.lanjingweike.com
```

上游请求由 `server.js` 统一补充浏览器请求头、`Cookie`、`Origin`、`Referer`，并使用 `redirect: "manual"` 处理大多数接口。

---

## 2. 本地后端 API

### 2.1 查询会话状态

检查当前后端进程是否持有已保存或已登录的会话。

```http
GET /api/status
```

#### 响应

```json
{
  "loggedIn": true,
  "hasSavedSession": true
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `loggedIn` | boolean | `cookieJar` 中是否包含 `sessionId=` |
| `hasSavedSession` | boolean | `cookieJar` 是否非空，可能只有 `JSESSIONID` |

---

### 2.2 登录

使用手机号和明文密码登录上游平台。后端会自动计算 SHA256 和 MD5 后提交给上游。

```http
POST /api/login
Content-Type: application/json
```

#### 请求体

```json
{
  "phone": "13800000000",
  "password": "plain-password"
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|:---:|---|
| `phone` | string | 是 | 手机号，不包含 `@1` |
| `password` | string | 是 | 明文密码，后端负责哈希 |

#### 成功响应

```json
{
  "success": true
}
```

登录成功后：

- 后端保存上游 Cookie 到 `session_cookies.txt`
- 清空考试列表缓存 `examsCache`

#### 失败响应

缺少参数：

```json
{
  "error": "phone and password required"
}
```

HTTP 状态码为 `400`。

无法获取 `JSESSIONID`：

```json
{
  "error": "Failed to get JSESSIONID"
}
```

HTTP 状态码为 `500`。

上游登录失败：

```json
{
  "error": "密码错误"
}
```

HTTP 状态码为 `401`。

---

### 2.3 获取考试列表

获取当前登录用户可见的考试和练习列表。

```http
GET /api/exams
```

#### 成功响应

```json
{
  "total": 34,
  "styles": {
    "1052373": "分类名称"
  },
  "exams": [
    {
      "id": 1439658,
      "name": "考试名称",
      "style": "分类名称",
      "practiceMode": 2,
      "examMode": "1",
      "totalTime": 0,
      "paperInfoId": 123456,
      "examTimes": 0,
      "examTimesRestrict": "0",
      "paid": false,
      "timeRestrict": "0",
      "wfs": 1,
      "timeLeft": 0
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `total` | number | 上游返回的考试总数 |
| `styles` | object | 分类 ID 到分类名称的映射 |
| `exams` | array | 归一化后的考试列表 |

`exams[]` 字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | number | 考试 ID，也是后续接口的 `:id` |
| `name` | string | 考试名称 |
| `style` | string | 分类名称 |
| `practiceMode` | number | 考试模式，常见值：`0` 模拟考试、`1` MOCK、`2` 练习 |
| `examMode` | string | 上游考试模式 |
| `totalTime` | number | 限时分钟数，`0` 表示不限时 |
| `paperInfoId` | number | 试卷模板 ID |
| `examTimes` | number | 允许作答次数 |
| `examTimesRestrict` | string | 是否限制次数 |
| `paid` | boolean | 是否付费考试 |
| `timeRestrict` | string | 是否限制时间 |
| `wfs` | number | `1` 表示新考试，`0` 表示已有作答记录 |
| `timeLeft` | number | 剩余时间，单位秒 |

#### 失败响应

```json
{
  "error": "Not logged in"
}
```

HTTP 状态码为 `401`。

上游业务失败时：

```json
{
  "error": "上游错误描述"
}
```

HTTP 状态码为 `500`。

---

### 2.4 进入考试

进入指定考试，并解析考试页面中的题卡状态、题目 ID、考试结果 ID、分区统计等信息。

```http
POST /api/exams/:id/enter
```

路径参数：

| 参数 | 类型 | 说明 |
|---|---|---|
| `id` | string | 考试 ID，即 `/api/exams` 返回的 `exams[].id` |

#### 行为

- 如果 `examsCache` 中该考试的 `wfs === 1`，按新考试流程进入
- 其他情况直接访问上游 `exam_start`
- 解析成功后写入 `examCache[id]`

#### 成功响应

```json
{
  "examResultsId": "87380582",
  "examInfoId": "1439658",
  "uuid": "7404753692344238080",
  "testIds": [
    "6620dfdfee9c16509b87a928"
  ],
  "questionStates": [
    {
      "questionsId": "6620dfdfee9c16509b87a928",
      "uuId": "7404753692344238080",
      "num": 1,
      "section": "科技常识",
      "state": "unanswered",
      "marked": false
    }
  ],
  "sections": {
    "科技常识": {
      "total": 50,
      "right": 0,
      "error": 0,
      "unanswered": 50
    }
  }
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `examResultsId` | string | 本次作答记录 ID |
| `examInfoId` | string | 考试信息 ID |
| `uuid` | string/null | 上游题目请求所需 UUID |
| `testIds` | string[] | 题目 ID 列表 |
| `questionStates` | array | 题卡状态列表 |
| `sections` | object | 分区统计，来自内部 `sectionMap` |

#### 失败响应

```json
{
  "error": "Failed to enter exam",
  "examResultsId": null
}
```

HTTP 状态码为 `500`。

---

### 2.5 获取题目与答案

获取当前考试的题目详情、选项、正确答案和解析。

调用前必须先成功调用 `/api/exams/:id/enter`，否则后端没有 `examCache`。

```http
GET /api/exams/:id/questions
```

#### 成功响应

```json
{
  "questions": [
    {
      "_id": "6620dfdfee9c16509b87a928",
      "question": "<p>题干 HTML</p>",
      "answer1": "<p>选项 A</p>",
      "answer2": "<p>选项 B</p>",
      "answer3": "<p>选项 C</p>",
      "answer4": "<p>选项 D</p>",
      "key1": "1",
      "key2": "0",
      "key3": "0",
      "key4": "0",
      "test_ans_right": "A",
      "analysis": "<p>解析 HTML</p>",
      "_isMulti": false,
      "_answers": ["A"],
      "_answer": "A",
      "_answerHtml": "<p>选项 A</p>",
      "_analysis": "<p>解析 HTML</p>"
    }
  ],
  "states": [
    {
      "questionsId": "6620dfdfee9c16509b87a928",
      "uuId": "7404753692344238080",
      "num": 1,
      "section": "科技常识",
      "state": "unanswered",
      "marked": false
    }
  ],
  "sections": {
    "科技常识": {
      "total": 50,
      "right": 0,
      "error": 0,
      "unanswered": 50
    }
  }
}
```

后端会按每批 50 题调用上游 `/exam/get_question_info/`。

增强字段说明：

| 字段 | 类型 | 说明 |
|---|---|---|
| `_isMulti` | boolean | 是否多选，依据 `key1` 到 `key4` 中正确项数量判断 |
| `_answers` | string[] | 正确答案字母数组，例如 `["A", "C"]` |
| `_answer` | string | 第一个正确答案；如果无 `keyN=1`，回退到 `test_ans_right` |
| `_answerHtml` | string | 正确选项 HTML，多个正确答案用 `<br>` 拼接 |
| `_analysis` | string | 解析 HTML，来自上游 `analysis` |

#### 失败响应

未先进入考试：

```json
{
  "error": "Exam not entered yet"
}
```

HTTP 状态码为 `400`。

---

### 2.6 提交单题答案

将单题作答结果上报到上游。

```http
POST /api/exams/:id/answer
Content-Type: application/json
```

#### 请求体

```json
{
  "testId": "6620dfdfee9c16509b87a928",
  "testAns": "key1,",
  "correct": true
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|:---:|---|
| `testId` | string | 是 | 题目 ID |
| `testAns` | string | 是 | 上游答案键，单选也需要保留末尾逗号 |
| `correct` | boolean | 是 | 前端判定的是否正确 |

`testAns` 对照：

| 值 | 含义 |
|---|---|
| `key1,` | 选择 A |
| `key2,` | 选择 B |
| `key3,` | 选择 C |
| `key4,` | 选择 D |
| `key1,key3,` | 选择 A 和 C |

#### 成功响应

```json
{
  "success": true,
  "code": 10000
}
```

#### 失败响应

未先进入考试：

```json
{
  "error": "Exam not entered"
}
```

HTTP 状态码为 `400`。

---

### 2.7 标记或取消标记题目

切换某道题的标记状态，并同步到上游。

```http
POST /api/exams/:id/mark
Content-Type: application/json
```

#### 请求体

```json
{
  "testId": "6620dfdfee9c16509b87a928",
  "isMark": true
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|:---:|---|
| `testId` | string | 是 | 题目 ID |
| `isMark` | boolean | 是 | `true` 标记，`false` 取消标记 |

#### 成功响应

```json
{
  "success": true
}
```

#### 失败响应

未先进入考试：

```json
{
  "error": "Exam not entered"
}
```

HTTP 状态码为 `400`。

---

### 2.8 交卷并获取结果

结束考试，跟随上游跳转到结果页，并从 HTML 中解析成绩、击败比例和排名。

```http
POST /api/exams/:id/submit
```

#### 行为

如果当前考试不在 `examCache` 中，后端会轻量访问一次：

```http
GET https://test.lanjingweike.com/exam/exam_start/:id
```

只提取 `exam_results_id` 和 `exam_info_id`，不拉取全部题目。

随后依次调用：

1. `POST /exam/get_remian_time`
2. `GET /exam/exam_ending?examInfoId=...&examResultsId=...&isForce=0&switchScreen=0&noOpsAutoCommit=0`

注意：上游接口名为 `get_remian_time`，代码保持了上游拼写。

#### 成功响应

```json
{
  "success": true,
  "score": "95",
  "beatRate": "88",
  "rank": "12"
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `score` | string | 成绩文本，解析失败时为 `"0"` |
| `beatRate` | string | 击败比例，解析失败时为 `"?"` |
| `rank` | string | 排名，解析失败时为 `"?"` |

#### 失败响应

无法从考试页解析 `exam_results_id`：

```json
{
  "error": "Cannot find exam_results_id"
}
```

HTTP 状态码为 `400`。

---

### 2.9 刷新题卡状态

重新进入考试页并刷新题卡状态、标记状态和分区统计。

```http
GET /api/exams/:id/states
```

#### 成功响应

响应结构与 `/api/exams/:id/enter` 相同：

```json
{
  "examResultsId": "87380582",
  "examInfoId": "1439658",
  "uuid": "7404753692344238080",
  "testIds": [
    "6620dfdfee9c16509b87a928"
  ],
  "questionStates": [
    {
      "questionsId": "6620dfdfee9c16509b87a928",
      "uuId": "7404753692344238080",
      "num": 1,
      "section": "科技常识",
      "state": "right",
      "marked": true
    }
  ],
  "sections": {
    "科技常识": {
      "total": 50,
      "right": 1,
      "error": 0,
      "unanswered": 49
    }
  }
}
```

#### 失败响应

```json
{
  "error": "Failed to get states"
}
```

HTTP 状态码为 `500`。

---

### 2.10 退出登录

清空后端进程内会话、考试缓存，并删除 `session_cookies.txt`。

```http
GET /api/logout
```

#### 成功响应

```json
{
  "success": true
}
```

---

## 3. 上游接口映射

| 本地接口 | 上游接口 | 说明 |
|---|---|---|
| `POST /api/login` | `GET /login/account/login/1` | 获取 `JSESSIONID` |
| `POST /api/login` | `POST /login/account/login` | 登录并获取 `sessionId` |
| `GET /api/exams` | `POST /exam/current_exam_list` | 获取考试列表 |
| `POST /api/exams/:id/enter` | `GET /exam/exam_start/:id` | 继续考试或最终进入考试 |
| `POST /api/exams/:id/enter` | `GET /exam/enter_exam/1/:id` | 新考试入口 |
| `POST /api/exams/:id/enter` | `POST /exam/faceCheckCondition` | 新考试人脸校验条件检查 |
| `POST /api/exams/:id/enter` | `POST /exam/start_exam_queue` | 新考试排队 |
| `POST /api/exams/:id/enter` | `POST /exam/check_queue_status` | 新考试排队状态轮询 |
| `POST /api/exams/:id/enter` | `POST /exam/test_complete` | 新考试组卷完成轮询 |
| `GET /api/exams/:id/questions` | `POST /exam/get_question_info/` | 批量获取题目详情 |
| `POST /api/exams/:id/answer` | `POST /exam/exam_start_ing_multi` | 上报单题答案 |
| `POST /api/exams/:id/mark` | `POST /exam/exam_question_mark` | 标记或取消标记题目 |
| `POST /api/exams/:id/submit` | `POST /exam/get_remian_time` | 交卷前获取剩余时间 |
| `POST /api/exams/:id/submit` | `GET /exam/exam_ending` | 结束考试并进入结果页 |
| `GET /api/exams/:id/states` | `GET /exam/exam_start/:id` | 刷新题卡状态 |

---

## 4. 数据结构

### 4.1 `questionStates[]`

题卡状态来自考试页 HTML 中的答题卡 DOM。

```json
{
  "questionsId": "6620dfdfee9c16509b87a928",
  "uuId": "7404753692344238080",
  "num": 1,
  "section": "科技常识",
  "state": "unanswered",
  "marked": false
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `questionsId` | string | 题目 ID |
| `uuId` | string/null | 上游题目详情接口需要的 UUID |
| `num` | number | 题号 |
| `section` | string | 分区标题，单区试卷可能为空字符串 |
| `state` | string | `unanswered`、`right` 或 `error` |
| `marked` | boolean | 是否已标记 |

### 4.2 `sections`

分区统计对象。键为分区标题；没有分区标题时，内部使用 `"(无分类"` 作为默认键。

```json
{
  "科技常识": {
    "total": 50,
    "right": 20,
    "error": 5,
    "unanswered": 25
  }
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `total` | number | 分区总题数 |
| `right` | number | 已答且正确 |
| `error` | number | 已答且错误 |
| `unanswered` | number | 未作答 |

### 4.3 题目详情对象

上游题目对象字段较多，前端主要使用以下字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `_id` | string/number | 题目 ID |
| `question` | string | 题干 HTML |
| `answer1` 到 `answer4` | string | 选项 HTML |
| `key1` 到 `key4` | string | `"1"` 表示该选项正确，`"0"` 表示不正确 |
| `test_ans_right` | string | 上游备用正确答案字母 |
| `analysis` | string | 解析 HTML |
| `_isMulti` | boolean | 后端增强字段，是否多选 |
| `_answers` | string[] | 后端增强字段，正确答案数组 |
| `_answer` | string | 后端增强字段，首个正确答案或备用答案 |
| `_answerHtml` | string | 后端增强字段，正确选项 HTML |
| `_analysis` | string | 后端增强字段，解析 HTML |

正确答案判断优先级：

1. 遍历 `key1` 到 `key4`，值为 `"1"` 的选项为正确答案
2. 如果没有任何 `keyN` 为 `"1"`，使用 `test_ans_right`

---

## 5. 错误与会话处理

### 5.1 本地鉴权中间件

除 `/api/login` 和 `/api/status` 外，所有 `/api/...` 路由都会先检查：

```js
cookieJar.includes("sessionId=")
```

不满足时直接返回 `401`：

```json
{
  "error": "Not logged in"
}
```

### 5.2 上游会话过期

`proxyRequest` 会识别以下情况为会话过期：

- 上游返回 `302`，并且 `Location` 包含 `/login/account/login`
- 响应 HTML 中同时包含 `/login/account/login` 和 `<!DOCTYPE`
- 响应文本中出现 `"onlineStatus": 0` 或 `"onlineStatus": "0"`

识别到过期后，后端会调用 `clearSession()`：

- 清空 `cookieJar`
- 清空 `examCache`
- 清空 `examsCache`
- 删除 `session_cookies.txt`

并返回：

```json
{
  "error": "Session expired"
}
```

HTTP 状态码为 `401`。

### 5.3 常见 HTTP 状态码

| 状态码 | 场景 |
|---|---|
| `200` | 请求成功 |
| `400` | 请求前置条件不满足，例如未进入考试就请求题目 |
| `401` | 未登录、登录失败或上游会话过期 |
| `500` | 上游业务失败、解析失败或进入考试失败 |

---

## 6. 业务流程

### 6.1 首次使用

```text
GET  /api/status
POST /api/login
GET  /api/exams
POST /api/exams/:id/enter
GET  /api/exams/:id/questions
POST /api/exams/:id/answer
POST /api/exams/:id/submit
```

### 6.2 已有保存会话

```text
GET  /api/status
GET  /api/exams
POST /api/exams/:id/enter
GET  /api/exams/:id/questions
```

如果任一接口返回 `401` 且 `error` 为 `Session expired` 或 `Not logged in`，前端应回到登录页。

### 6.3 新考试进入流程

当前端先调用 `/api/exams` 后，后端可根据 `wfs` 判断是否为新考试。

当 `wfs === 1` 时，`POST /api/exams/:id/enter` 内部流程为：

```text
GET  /exam/enter_exam/1/:id
POST /exam/faceCheckCondition
POST /exam/start_exam_queue
POST /exam/check_queue_status    可选，最多 30 次，每 2 秒一次
POST /exam/test_complete         最多 30 次，每 2 秒一次
GET  /exam/exam_start/:id
```

### 6.4 继续考试进入流程

当 `wfs !== 1`，或未命中 `examsCache` 时，`POST /api/exams/:id/enter` 会直接：

```text
GET /exam/exam_start/:id
```

然后解析考试页 HTML。

### 6.5 交卷流程

```text
POST /api/exams/:id/submit
  -> POST /exam/get_remian_time
  -> GET  /exam/exam_ending
  -> 解析结果页 HTML
```

返回的 `score`、`beatRate`、`rank` 都是从上游 HTML 中按正则解析出的字符串。若上游页面结构变化，字段可能回退为 `"0"` 或 `"?"`。
