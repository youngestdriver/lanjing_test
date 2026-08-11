# 托盘设置 Cookie 服务器(桌面端 CookieCloud 配置入口)

- 日期:2026-08-12
- 状态:已批准(原生对话框 + 预填当前配置)
- 范围:`apps/desktop/windows/`(C#)与 `apps/desktop/macos/`(Swift)两个 wrapper;server 零改动

## 需求

桌面端托盘/菜单栏右键菜单新增"设置 Cookie 服务器…",原生对话框配置 CookieCloud(服务器地址/UUID/密码),不必打开浏览器进"我的"页。

已确认:
1. **原生对话框**(非浏览器跳转)
2. **预填当前配置**(打开时 GET 现有配置填入表单)

## 服务端现状(零改动,全部已存在且免登录)

| API | 说明 |
|---|---|
| `GET /api/cookiecloud` | 返回 `{enabled, server, uuid, hasPassword, lastPush, lastPull, lastError}`(password 永不下发) |
| `POST /api/cookiecloud` | 部分字段更新:`{enabled?, server?, uuid?, password?}`;password 为空字符串或缺失 → 保留旧值 |
| `POST /api/cookiecloud/sync` | 立即同步(单飞由 server 保证,永不 reject) |

## 交互与数据流(两平台一致)

```
托盘菜单:打开浏览器 / 设置 Cookie 服务器… / 退出
                    ▼ 点击
原生对话框(异步 GET /api/cookiecloud 预填)
  ├─ ☑ 启用同步        CheckBox ← enabled
  ├─ 服务器地址        TextBox ← server
  ├─ UUID              TextBox ← uuid
  ├─ 密码              PasswordBox(留空 = 不修改;若 hasPassword 显示"已保存,留空不修改")
  ├─ 同步状态          只读文案:lastError 优先,否则"上次拉取 HH:MM · 上次推送 HH:MM",无则"尚未同步"
  ├─ [取消] [保存]
                    ▼ 保存
POST /api/cookiecloud {enabled, server, uuid, password?}
  ├─ 成功 → POST /api/cookiecloud/sync(立即同步)→ 关闭对话框
  └─ 失败 → 对话框内显示错误文案,不关闭
```

- 密码不回显(API 安全设计只有 hasPassword);留空 = 不修改
- 保存后自动触发一次同步(配置即生效)
- 对话框打开期间 GET 失败 → 显示错误并允许继续编辑(保存仍可用)

## Windows 实现(C# .NET 8 WinForms)

文件:`apps/desktop/windows/` 新增 `CookieCloudForm.cs`,修改 `Program.cs`(菜单项 + 打开对话框)。

- 菜单:`ContextMenuStrip.Items` 在"打开浏览器"后插入"设置 Cookie 服务器…",点击 `ShowCookieCloudDialog()`
- `CookieCloudForm`:Form(Title "Cookie 服务器",FormBorderStyle.FixedDialog,MaximizeBox/MinimizeBox 关,StartPosition.CenterScreen)
  - 控件:CheckBox(启用同步)+ TextBox(服务器地址/UUID)+ TextBox(密码,`UseSystemPasswordChar=true`)+ Label(同步状态,灰色小字)+ 错误 Label(红色)+ 取消/保存按钮
  - 预填:`HttpClient` GET `http://127.0.0.1:{ServerPort}/api/cookiecloud`(async,UI 线程 await 恢复)
  - 保存:POST JSON `{enabled, server, uuid, password?}`(password 非空才带);成功后 POST `/api/cookiecloud/sync`;失败显示 `result.error`
  - HttpClient 单例/Dispose 生命周期与 Program 一致;所有 UI 更新在主线程(async void 处理器内 await 后自然回 UI)
- 端口:`Program.ServerPort = 3000` 常量复用

## macOS 实现(Swift AppKit)

文件:`apps/desktop/macos/` 修改 `main.swift`(菜单项 + `NSAlert` 对话框)。

- 菜单:`NSMenu` 在"打开浏览器"后插入"设置 Cookie 服务器…",target/action 打开对话框
- 对话框:`NSAlert` + `accessoryView`(NSStackView:启用 checkbox + 3 个 NSTextField(密码用 `NSSecureTextField`)+ 同步状态 label + 错误 label);`alert.addButton(withTitle: "保存")`/`"取消"`
  - 预填:`URLSession` GET `http://127.0.0.1:3000/api/cookiecloud`,完成后 `DispatchQueue.main.async` 填字段
  - 保存:POST JSON(同上),成功后 POST `/sync`,失败在错误 label 显示
  - 模态:`alert.runModal()` 在主线程;网络请求在后台队列
- `homeURL` 端口常量复用(3000)

## 测试与验证

- server 无改动 → 现有 93 项测试与 browser smoke 不动
- macOS:本地 swiftc 编译(组装脚本流程)+ 手动验证对话框(GET 预填、保存、错误路径、密码留空保留)
- Windows:本地无 dotnet → CI windows job 编译 + 冒烟验证(冒烟不弹对话框,只验证构建通过)
- release.yml 无需改动(构建流程不变)

## 范围外

- 密码回显(API 只有 hasPassword)
- 多 CookieCloud 服务器配置
- 托盘菜单其他定制项
