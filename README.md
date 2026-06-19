# 答题助手 / Quiz Assistant

> 蓝鲸微课考试平台第三方答题工具
>
> Third-party quiz tool for the Lanjing Weike exam platform.

---

## 功能 / Features

- **登录鉴权** / **Login** — 手机号 + 密码登录，Session 持久化
- **考试列表** / **Exam List** — 按分类展示，区分新试卷 / 继续考试
- **逐题答题** / **One Question at a Time** — 选项常驻底部，题干可滚动
- **即时判对错** / **Instant Judge** — 选择后立刻显示对错 + 解析
- **答题卡** / **Answer Card** — 分区标签、颜色状态、横竖屏自适应展收
- **左右滑动切题** / **Swipe Navigation** — 手机端手势翻题
- **深色模式** / **Dark Mode** — 一键切换
- **PWA 支持** / **PWA Support** — 可安装到桌面
- **答案上报** / **Answer Sync** — 每题作答自动上报服务端

---

## 快速开始 / Quick Start

### 环境要求 / Prerequisites

- [Node.js](https://nodejs.org/) >= 18

### 安装 / Install

```bash
npm install
```

### 启动 / Run

```bash
node server.js
```

浏览器打开 / Open: `http://localhost:3000`

### 使用 / Usage

1. 输入手机号与密码登录
2. 从列表中选择考试
3. 点击选项作答，右侧答题卡显示进度
4. 左右滑动或点击圆点切换题目

---

## 项目结构 / Project Structure

```
├── server.js              # Express 后端 / Backend server
├── login_demo.js          # 原始调试脚本 / Original debug script
├── frontend/
│   └── index.html         # SPA 前端 / Single-page frontend
├── API.md                 # 接口文档 / API documentation
├── package.json
├── .gitignore
└── README.md
```

---

## 后端 API / Backend API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/status` | 会话状态 / Session status |
| `POST` | `/api/login` | 登录 / Login |
| `GET` | `/api/exams` | 考试列表 / Exam list |
| `POST` | `/api/exams/:id/enter` | 进入考试 / Enter exam |
| `GET` | `/api/exams/:id/questions` | 题目 + 答案 / Questions & answers |
| `POST` | `/api/exams/:id/answer` | 上报答案 / Submit answer |
| `POST` | `/api/exams/:id/mark` | 标记题目 / Toggle question mark |
| `POST` | `/api/exams/:id/submit` | 交卷并获取结果 / Submit exam |
| `GET` | `/api/exams/:id/states` | 刷新题卡状态 / Refresh answer states |
| `GET` | `/api/logout` | 退出 / Logout |

详见 / See [API.md](API.md)

---

## 技术栈 / Tech Stack

| 层 / Layer | 技术 / Tech |
|-----------|------------|
| 前端 / Frontend | Vanilla HTML/CSS/JS, CSS Grid, CSS Variables |
| 后端 / Backend | Node.js, Express |
| 上游 / Upstream | 蓝鲸微课考试平台 REST API |

---

## 免责声明 / Disclaimer

本项目仅供学习研究使用，请勿用于商业或违规用途。
For educational purposes only. Do not use for commercial or unauthorized purposes.
