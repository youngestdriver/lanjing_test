# 兰鲸助手 Android

`LanjingQuiz` 是蓝鲸微课考试平台的原生安卓客户端,与原生 iOS 版**逐字契约对齐**的移植:
登录/会话、考试(列表/作答/答题卡/交卷/结果)、练习(直连爬取题库/分类/离线刷题/进度恢复)、
我的(设置/CookieCloud 同步/退出登录)。应用直连上游服务(`https://test.lanjingweike.com`),
不依赖 `apps/web/server.js`。

完整契约基准见设计文档:
[docs/superpowers/specs/2026-08-12-android-port-design.md](../../docs/superpowers/specs/2026-08-12-android-port-design.md)
(端点、JSON 键、业务规则、用户可见字符串均以 iOS 蓝本为基准,移植时逐字对齐)。

## 技术栈

- Kotlin + Jetpack Compose + Material 3(信息结构与交互对齐 iOS)
- Hilt 依赖注入、OkHttp 网络层、kotlinx.serialization JSON
- 会话 Cookie 持久化在**加密 SharedPreferences**(Security-Crypto,Android Keystore 密钥),
  等价于 iOS Keychain 的会话存储
- Gradle 8.10.2 + AGP 8.x,JDK 17,minSdk 26 / targetSdk 35,支持手机与平板

## 环境要求

- JDK 17+
- Android SDK:platform 35、build-tools、platform-tools;跑 UI 测试还需 emulator + `system-images;android-35;google_apis;x86_64`
- 命令行构建需设置 `ANDROID_HOME`(Homebrew 安装示例):

```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
```

## 构建与测试

```bash
cd apps/android

./gradlew assembleDebug                 # debug APK
./gradlew testDebugUnitTest             # JVM 单元测试(无网络,全部离线)
./gradlew connectedDebugAndroidTest     # 仪器化 UI 测试(需模拟器/真机)
./gradlew assembleRelease -PversionName=1.1.0 -PversionCode=10100   # release APK(版本可覆盖)
```

- **单元测试不触真实上游**,不依赖任何本地服务,提交前必须全绿。
- **UI 测试(ExamFlowUiTest / PracticeFlowUiTest)封闭运行**:进程内 MockWebServer
  (MockUpstreamServer)复刻全部考试与练习路由与 wfs 语义,base URL 经测试 intent extra
  注入(TestConfig),**绝不访问真实上游**;CI 的 `android-ui` job 在 API 35 模拟器上执行。
- 常用:`./gradlew clean testDebugUnitTest assembleDebug assembleRelease assembleDebugAndroidTest`
  (全量验证,见仓库根 README「验证与 CI」)。

## 目录结构

```text
apps/android/
├── LanjingQuiz/
│   ├── src/main/java/com/qzh/lanjingquiz/
│   │   ├── App/          # 入口、路由与全局状态(AppState/AppRoot)
│   │   ├── Data/         # 本地存储(题库 JSONL/会话/进度/设置/加密 Cookie)
│   │   ├── Domain/       # 纯逻辑:解析器、判定、分类器、爬取器、CookieCloudSync
│   │   ├── Network/      # 上游客户端、CookieJar、CookieCloud 客户端、DTO
│   │   ├── Support/      # 设计系统、表单编码、哈希、加解密、富文本渲染
│   │   └── UI/           # Compose 界面:登录/考试列表/答题/结果/练习/我的
│   ├── src/test/         # JVM 单元测试(与 iOS 用例逐项对齐)
│   └── src/androidTest/  # 仪器化 UI 测试 + MockUpstreamServer
├── gradle/libs.versions.toml
├── build.gradle.kts
└── settings.gradle.kts
```

## 网络与会话

`ApiClient` 直连 `https://test.lanjingweike.com`,经 `CookieStore` 维护会话 Cookie jar;
登录凭据仅用于该服务的认证。会话 Cookie 存于加密 SharedPreferences;退出登录与会话过期
会清理本地会话。

可选 CookieCloud 同步(`CookieCloudSync`,与 Web/iOS/官方浏览器扩展同一协议):
登录后自动上传、启动时拉取(4s 硬边界)、我的页手动双向探活同步;服务器地址/UUID/开关
存设置,密码存加密存储。测试与 CI 均不触真实上游。

## 免责声明

本客户端仅用于学习与授权测试。请只在获得授权的账号与场景中使用,遵守平台规则。
