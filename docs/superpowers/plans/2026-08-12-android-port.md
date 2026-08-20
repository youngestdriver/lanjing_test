# 兰鲸助手安卓版移植实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `apps/android/` 新建原生安卓应用(兰鲸助手),全量移植 iOS 版功能:登录/会话、考试、练习刷题(直连爬取题库)、CookieCloud 同步、我的页。

**Architecture:** 单 Activity + Jetpack Compose(Material 3),MVVM + Repository 分层,Hilt 依赖注入,OkHttp 网络层 + 自研持久 CookieJar,SharedPreferences/EncryptedSharedPreferences 持久化,WebView 渲染题干 HTML。路由为状态切换(sealed Route),不引入 Navigation 库——与 iOS 的路由枚举完全同构。

**Tech Stack:** Kotlin 2.1.0、AGP 8.7.3、Compose BOM 2024.12.01、Hilt 2.53.1、OkHttp/MockWebServer 4.12.0、kotlinx-serialization 1.7.3、kotlinx-coroutines 1.9.0、androidx.security-crypto 1.0.0。minSdk 26 / targetSdk 35 / compileSdk 35。

## 全局约束

以下全部为逐字契约,移植时**不允许翻译或改造**;所有任务的实现者必须**先 Read** 设计文档 `docs/superpowers/specs/2026-08-12-android-port-design.md`(仓库内已提交,commit 34ab9d5):

- **契约唯一来源:** spec §3.1(上游端点/表单/请求头/过期三规则)、§3.2(本地数据格式/JSONL/meta)、§3.3(分类器)、§3.4(CookieCloud 加密参数)、§3.5(设计系统/文案)、§3.6(行为常量)。本计划代码中出现的长契约值一律从 spec 逐字抄录,以 spec 为准。
- **包结构:** 全部代码位于 `apps/android/LanjingQuiz/src/main/java/com/qzh/lanjingquiz/`;测试在 `src/test/`(JVM)、`src/androidTest/`(仪器化)。
- **applicationId:** `com.qzh.lanjingquiz`;测试 applicationId `com.qzh.lanjingquiz.test`。
- **app 显示名:** 蓝鲸助手;版本格式 `1.0 (1)`(versionName (versionCode))。
- **用户可见文案:** 与 iOS 逐字一致,中文(见 spec §3.5 与各功能章节);不本地化。
- **五大类字符串(数据契约键,不可本地化):** `言语理解`、`数字运算`、`逻辑推理`、`资料分析`、`特有题型`;兜底 `未分类`;section 占位 `(无分类)`;试卷 style 标记 `机考题库`。
- **SharedPreferences 键名逐字保留:** `theme`、`theme.manual`、`quiz.autoAdvanceOnCorrect`、`practice.shuffle.<大类>`、`quiz.cookieCloud`、`quiz.cookieCloud.lastPushedHash`;加密存储键位:会话 cookies、`cookiecloud.password`。
- **本地文件:** `filesDir/LanjingQuiz/bank/{五大类}.jsonl`、`bank/meta.json`、`bank/crawl_log.jsonl`、`practice-session.json`、`practice-progress.json`;写入一律临时文件 + 原子 rename。
- **网络:** 请求超时 30s;OkHttp 关闭缓存;表单编码手写百分号编码(允许集字母数字 + `-._~`),**禁用 `java.net.URLEncoder`**;UA/请求头逐字复刻(spec §3.1)。
- **会话:** `sessionId` 与 `JSESSIONID` cookie 持久化;过期三规则命中即清 cookie;`sessionExpired` 是唯一把用户踢回登录页的错误(通知"登录已过期，请重新登录")。
- **封闭测试原则:** 测试绝不触真实上游;UI 测试用进程内 MockWebServer 版 MockUpstreamServer + 启动参数清本地题库。
- **本地工具链:** ANDROID_HOME 已装于 `/opt/homebrew/share/android-commandlinetools`(brew cask android-commandlinetools);本地验证命令统一为 `cd apps/android && ./gradlew testDebugUnitTest`(单元)与 `./gradlew assembleDebug`(构建);Compose UI 测试本地不跑,只在 CI 模拟器上跑。首次运行需 `export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools`(写入实现者 shell 即可,不写全局 profile)。
- **提交纪律:** 每个任务至少一个 commit,中文消息;不得把 `build/`、`.gradle/`、`local.properties` 提交进仓库。

---

## Task 0: 工程脚手架(可构建可跑的壳 + CI)

**Files:**
- Create: `apps/android/settings.gradle.kts`
- Create: `apps/android/build.gradle.kts`
- Create: `apps/android/gradle/libs.versions.toml`
- Create: `apps/android/gradle.properties`
- Create: `apps/android/gradle/wrapper/gradle-wrapper.properties`(及 wrapper jar,见步骤)
- Create: `apps/android/LanjingQuiz/build.gradle.kts`
- Create: `apps/android/LanjingQuiz/src/main/AndroidManifest.xml`
- Create: `apps/android/LanjingQuiz/src/main/res/values/strings.xml`(app 名 `蓝鲸助手`)
- Create: `apps/android/LanjingQuiz/src/main/res/xml/network_security_config.xml`
- Create: `apps/android/LanjingQuiz/src/main/res/values/themes.xml`
- Create: `apps/android/LanjingQuiz/src/main/res/drawable/ic_launcher_foreground.xml` 与 `mipmap-anydpi-v26/ic_launcher.xml`(简单矢量,无品牌图片)
- Create: `apps/android/LanjingQuiz/src/main/java/com/qzh/lanjingquiz/App/LanjingQuizApp.kt`
- Create: `apps/android/LanjingQuiz/src/main/java/com/qzh/lanjingquiz/App/MainActivity.kt`
- Create: `apps/android/LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Theme.kt`
- Create: `apps/android/LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/AppRoot.kt`(占位三 Tab 壳)
- Create: `.github/workflows/ci-android.yml`

**Interfaces:**
- Produces: 工程骨架;`LanjingQuizApp`(@HiltAndroidApp)、`MainActivity`(@AndroidEntryPoint,setContent { LanjingQuizTheme { AppRoot() } })、`LanjingQuizTheme(darkTheme: Boolean, content)`;`AppRoot()` 占位渲染三 Tab(考试列表/练习/我的)空屏。Hilt 仅骨架(空 `@Module` 清单),正式绑定在 T1。

- [ ] **Step 1: 创建 Gradle 工程文件**

`settings.gradle.kts`:
```kotlin
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "LanjingQuiz"
include(":LanjingQuiz")
```

`gradle/libs.versions.toml`:
```toml
[versions]
agp = "8.7.3"
kotlin = "2.1.0"
composeBom = "2024.12.01"
hilt = "2.53.1"
okhttp = "4.12.0"
kotlinxSerialization = "1.7.3"
kotlinxCoroutines = "1.9.0"
securityCrypto = "1.0.0"
coreKtx = "1.15.0"
lifecycle = "2.8.7"
activityCompose = "1.9.3"
junit = "4.13.2"
androidxTestExt = "1.2.1"
espresso = "3.6.1"
mockwebserver = "4.12.0"

[libraries]
androidx-core-ktx = { group = "androidx.core", name = "core-ktx", version.ref = "coreKtx" }
androidx-lifecycle-runtime-ktx = { group = "androidx.lifecycle", name = "lifecycle-runtime-ktx", version.ref = "lifecycle" }
androidx-lifecycle-viewmodel-compose = { group = "androidx.lifecycle", name = "lifecycle-viewmodel-compose", version.ref = "lifecycle" }
androidx-activity-compose = { group = "androidx.activity", name = "activity-compose", version.ref = "activityCompose" }
androidx-compose-bom = { group = "androidx.compose", name = "compose-bom", version.ref = "composeBom" }
compose-ui = { group = "androidx.compose.ui", name = "ui" }
compose-ui-graphics = { group = "androidx.compose.ui", name = "ui-graphics" }
compose-ui-tooling-preview = { group = "androidx.compose.ui", name = "ui-tooling-preview" }
compose-material3 = { group = "androidx.compose.material3", name = "material3" }
compose-material-icons = { group = "androidx.compose.material", name = "material-icons-extended" }
hilt-android = { group = "com.google.dagger", name = "hilt-android", version.ref = "hilt" }
hilt-compiler = { group = "com.google.dagger", name = "hilt-compiler", version.ref = "hilt" }
okhttp = { group = "com.squareup.okhttp3", name = "okhttp", version.ref = "okhttp" }
kotlinx-serialization-json = { group = "org.jetbrains.kotlinx", name = "kotlinx-serialization-json", version.ref = "kotlinxSerialization" }
kotlinx-coroutines-android = { group = "org.jetbrains.kotlinx", name = "kotlinx-coroutines-android", version.ref = "kotlinxCoroutines" }
kotlinx-coroutines-test = { group = "org.jetbrains.kotlinx", name = "kotlinx-coroutines-test", version.ref = "kotlinxCoroutines" }
security-crypto = { group = "androidx.security", name = "security-crypto", version.ref = "securityCrypto" }
junit = { group = "junit", name = "junit", version.ref = "junit" }
androidx-test-ext-junit = { group = "androidx.test.ext", name = "junit", version.ref = "androidxTestExt" }
espresso-core = { group = "androidx.test.espresso", name = "espresso-core", version.ref = "espresso" }
mockwebserver = { group = "com.squareup.okhttp3", name = "mockwebserver", version.ref = "mockwebserver" }
compose-ui-test-junit4 = { group = "androidx.compose.ui", name = "ui-test-junit4" }
compose-ui-test-manifest = { group = "androidx.compose.ui", name = "ui-test-manifest" }
compose-ui-tooling = { group = "androidx.compose.ui", name = "ui-tooling" }

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
kotlin-compose = { id = "org.jetbrains.kotlin.plugin.compose", version.ref = "kotlin" }
kotlin-serialization = { id = "org.jetbrains.kotlin.plugin.serialization", version.ref = "kotlin" }
hilt = { id = "com.google.dagger.hilt.android", version.ref = "hilt" }
```

`gradle.properties`:
```properties
org.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8
android.useAndroidX=true
android.nonTransitiveRClass=true
org.gradle.configuration-cache=true
```

`build.gradle.kts`(根):
```kotlin
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.hilt) apply false
}
```

`LanjingQuiz/build.gradle.kts`:
```kotlin
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.hilt)
    kotlin("kapt")
}

android {
    namespace = "com.qzh.lanjingquiz"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.qzh.lanjingquiz"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // 版本号可由 CI 覆盖:./gradlew assembleRelease -PversionName=1.1.0 -PversionCode=10100
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug") // 未签名发布版可安装;正式签名 T7 接线
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    testOptions { unitTests.isReturnDefaultValues = true }
}

kapt { correctErrorTypes = true }

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.hilt.android)
    kapt(libs.hilt.compiler)
    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.security.crypto)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.mockwebserver)

    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
    debugImplementation(libs.compose.ui.test.manifest)
    debugImplementation(libs.compose.ui.tooling)
}
```

- [ ] **Step 2: 创建 Manifest、资源、网络配置**

`src/main/AndroidManifest.xml`(骨架,后续任务追加):
```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <application
        android:name=".App.LanjingQuizApp"
        android:label="@string/app_name"
        android:icon="@mipmap/ic_launcher"
        android:supportsRtl="true"
        android:theme="@style/Theme.LanjingQuiz"
        android:networkSecurityConfig="@xml/network_security_config">
        <activity android:name=".App.MainActivity"
            android:exported="true"
            android:windowSoftInputMode="adjustResize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
```

`res/values/strings.xml`:
```xml
<resources>
    <string name="app_name">蓝鲸助手</string>
</resources>
```

`res/xml/network_security_config.xml`(仅允许局域网明文,CookieCloud 自建服务场景;上游是 https 不受影响):
```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="false" />
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
        <domain includeSubdomains="true">192.168.0.0</domain>
        <domain includeSubdomains="true">10.0.0.0</domain>
    </domain-config>
</network-security-config>
```
注意:域名配置不支持 CIDR 通配(192.168.0.0 只匹配字面主机名);真正的局域网 IP 明文放行在 T6 的测试/自建场景再评估,这里先保证构建骨架。若 `lint` 报 cleartext 域名错误,以 domain 字面量保留 `127.0.0.1` 并把其余两项删除。

`res/values/themes.xml`:
```xml
<resources>
    <style name="Theme.LanjingQuiz" parent="android:Theme.Material.Light.NoActionBar" />
</resources>
```

图标:创建 `res/drawable/ic_launcher_foreground.xml`(一个蓝色圆角方块 + 白色对勾的简单 vector)与 `res/mipmap-anydpi-v26/ic_launcher.xml`:
```xml
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
</adaptive-icon>
```
`res/values/colors.xml` 增加 `launcher_background` = `#58CC02`(DS accent)。

- [ ] **Step 3: 创建应用骨架代码**

`App/LanjingQuizApp.kt`:
```kotlin
package com.qzh.lanjingquiz.App

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class LanjingQuizApp : Application()
```

`App/MainActivity.kt`:
```kotlin
package com.qzh.lanjingquiz.App

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.qzh.lanjingquiz.UI.AppRoot
import com.qzh.lanjingquiz.UI.LanjingQuizTheme
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            LanjingQuizTheme { AppRoot() }
        }
    }
}
```

`UI/Theme.kt`(DS 调色板映射 M3;hex 值来自 spec §3.5,逐字):
```kotlin
package com.qzh.lanjingquiz.UI

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// DS 调色板(spec §3.5):accent 0x58cc02, accentHover 0x61e002, accentActive 0x58a700,
// orange 0xff9600, blue 0x1cb0f6, pink 0xce82ff, red 0xff4b4b, yellow 0xffc800, gray 0xafafaf
val DSAccent = Color(0xFF58CC02)
val DSAccentHover = Color(0xFF61E002)
val DSAccentActive = Color(0xFF58A700)
val DSOrange = Color(0xFFFF9600)
val DSBlue = Color(0xFF1CB0F6)
val DSPink = Color(0xFFCE82FF)
val DSRed = Color(0xFFFF4B4B)
val DSYellow = Color(0xFFFFC800)
val DSGray = Color(0xFFAFAFAF)

val DSRadiusSM = 12.dp
val DSRadiusMD = 16.dp
val DSRadiusLG = 20.dp
val DSRadiusFull = 9999.dp

private val LightColors = lightColorScheme(
    primary = DSAccent, secondary = DSBlue, error = DSRed, tertiary = DSPink,
)
private val DarkColors = darkColorScheme(
    primary = DSAccent, secondary = DSBlue, error = DSRed, tertiary = DSPink,
)

@Composable
fun LanjingQuizTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        content = content,
    )
}
```
(注意 `dp` 需要 `import androidx.compose.ui.unit.dp`。)

`UI/AppRoot.kt`(占位三 Tab 壳,后续任务替换):
```kotlin
package com.qzh.lanjingquiz.UI

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier

enum class HomeTab { Exams, Practice, Profile }

@Composable
fun AppRoot() {
    var selected by remember { mutableStateOf(HomeTab.Exams) }
    Scaffold(bottomBar = {
        NavigationBar {
            NavigationBarItem(
                selected = selected == HomeTab.Exams,
                onClick = { selected = HomeTab.Exams },
                icon = { Icon(Icons.Filled.CheckCircle, contentDescription = null) },
                label = { Text("考试列表") },
            )
            NavigationBarItem(
                selected = selected == HomeTab.Practice,
                onClick = { selected = HomeTab.Practice },
                icon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                label = { Text("练习") },
            )
            NavigationBarItem(
                selected = selected == HomeTab.Profile,
                onClick = { selected = HomeTab.Profile },
                icon = { Icon(Icons.Filled.Person, contentDescription = null) },
                label = { Text("我的") },
            )
        }
    }) { padding ->
        Text("蓝鲸助手", Modifier.padding(padding))
    }
}
```

- [ ] **Step 4: 本地构建验证**

```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
cd apps/android
# 生成 wrapper(首次需要 gradle;若无 gradle,用 brew install gradle 临时生成 wrapper 后即可删)
gradle wrapper --gradle-version 8.10.2
./gradlew assembleDebug
```
Expected: BUILD SUCCESSFUL,产出 `LanjingQuiz/build/outputs/apk/debug/LanjingQuiz-debug.apk`。若 SDK 组件缺失,`sdkmanager "platforms;android-35" "build-tools;35.0.0"` 补装。

- [ ] **Step 5: 创建 ci-android.yml**

`.github/workflows/ci-android.yml`(与 ci-ios 同款门控:paths-filter 控制 job 跳过,事件级不做 paths 过滤):
```yaml
name: CI Android

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            android:
              - 'apps/android/**'
              - '.github/workflows/ci-android.yml'
      - if: steps.filter.outputs.android == 'true'
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'
      - if: steps.filter.outputs.android == 'true'
        uses: gradle/actions/setup-gradle@v4
        with:
          gradle-version: 8.10.2
      - if: steps.filter.outputs.android == 'true'
        name: Unit tests + build
        working-directory: apps/android
        run: |
          ./gradlew testDebugUnitTest assembleDebug --no-daemon
          mkdir -p ../../artifact && cp LanjingQuiz/build/outputs/apk/debug/LanjingQuiz-debug.apk ../../artifact/
      - if: steps.filter.outputs.android == 'true'
        uses: actions/upload-artifact@v4
        with:
          name: android-debug-apk
          path: artifact/
```
(UI 测试 job 在 T7 追加——先保证单元 + 构建在 CI 上绿。)

- [ ] **Step 6: 本地全量验证 + 提交**

```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
cd apps/android && ./gradlew testDebugUnitTest assembleDebug
```
Expected: 全部成功。然后:
```bash
git add apps/android .github/workflows/ci-android.yml
git commit -m "feat(android): 工程脚手架与 CI 工作流(可构建三 Tab 壳)"
```

---

## Task 1: 网络契约层(Hashers/编码/DTO/Cookie/APIClient/加密)

**Files:**
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Support/Hashers.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Support/FormEncoder.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Support/Formatters.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Support/SplitMix64.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Support/CookieCloudCrypto.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Data/SettingsStore.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Data/SecureStore.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Network/UpstreamDto.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Network/CookieStore.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Network/PersistentCookieJar.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Network/ApiClient.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/App/AppModule.kt`(Hilt 绑定)
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Support/HashersTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Support/FormEncoderTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Support/CookieCloudCryptoTests.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Support/SplitMix64Test.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Network/ApiClientTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Network/CookieStoreTest.kt`(JVM 用 InMemory 实现)

**Interfaces:**
- Consumes: Task 0 工程骨架。
- Produces(供 T2-T6 使用,签名固定):
  - `object Hashers { fun sha256Hex(s: String): String; fun md5Hex(s: String): String }`(小写 hex,UTF-8 字节)
  - `object FormEncoder { fun encode(params: Map<String, String>): String }`(百分号编码,允许集 ASCII 字母数字 + `-._~`,`k=v` 以 `&` 连接)
  - `object Formatters { fun mmss(seconds: Int): String; fun isoNow(): String; fun displayTime(epochMillis: Long): String; fun exportFileName(now: java.time.ZonedDateTime): String }`
  - `class SplitMix64(seed: ULong) : kotlin.random.Random`(常量 `0x9E3779B97F4A7C15UL`、`0xBF58476D1CE4E5B9UL`、`0x94D049BB133111EBUL`)
  - `object CookieCloudCrypto { fun deriveKey(uuid: String, password: String): ByteArray; fun fixedEncrypt(plain: String, key: ByteArray): String; fun fixedDecrypt(base64Cipher: String, key: ByteArray): String; fun legacyDecrypt(base64Cipher: String, uuid: String, password: String): String; fun encryptAny(plain: String, uuid: String, password: String): Pair<String, String>; fun decryptAny(encrypted: String, uuid: String, password: String, cryptoType: String?): String }`
  - `class SettingsStore(context: Context)`:`fun getString(key: String, default: String? = null): String?`、`fun putString(key: String, value: String)`、`fun getBoolean(key: String, default: Boolean): Boolean`、`fun putBoolean(key: String, value: Boolean)`、`fun remove(key: String)`;内部 `context.getSharedPreferences("settings", MODE_PRIVATE)`(普通明文)
  - `class SecureStore(context: Context)`:`fun getString(key: String): String?`、`fun putString(key: String, value: String)`、`fun remove(key: String)`;内部 EncryptedSharedPreferences(`masterKey = MasterKey.Builder(context).setKeyScheme(KeyScheme.AES256_GCM).build()`,文件名 `"secure"`)
  - `data class StoredCookie(name: String, value: String, domain: String, path: String, secure: Boolean, httpOnly: Boolean, expiry: Long?, sessionOnly: Boolean, sameSite: String?)`
  - `interface CookieStore { fun load(): List<StoredCookie>; fun save(cookies: List<StoredCookie>); fun clear(); fun hasSession(): Boolean; fun headerString(): String }` + `class PrefsCookieStore(private val secureStore: SecureStore) : CookieStore`(JSON 序列化存键 `"cookies"`;`hasSession()` = 存在 name=="sessionId" 的 cookie;`headerString()` = `name=value` 用 `; ` 连接)
  - `interface UpstreamApi { suspend fun warmUpJsSession(); suspend fun login(phone: String, password: String); suspend fun examList(): ExamListResult; suspend fun enterExam(examInfoId: String): EnterExamResult; suspend fun fetchQuestions(req: QuestionBatchRequest): List<QuestionDto>; suspend fun submitAnswer(examResultsId: String, examInfoId: String, testId: String, testAns: String, correct: Boolean); suspend fun markQuestion(testId: String, examResultsId: String, examInfoId: String, isMark: Boolean); suspend fun submitExam(examInfoId: String, examResultsId: String): ExamResult; suspend fun logout(); fun hasSession(): Boolean; fun clearSession(); val cookieHeader: String }`
  - `class ApiException(code: Int, override val message: String) : Exception(message)`;code 常量:`SESSION_EXPIRED`、`NOT_LOGGED_IN`、`INVALID_RESPONSE`、`UPSTREAM`、`NETWORK`
  - `data class ExamListResult(total: Int, styles: List<StyleDto>, exams: List<ExamDto>)`
  - `data class EnterExamResult(examResultsId: String, examInfoId: String, uuid: String?)`
  - `data class ExamResult(score: String, beatRate: String, rank: String)`
  - `data class QuestionBatchRequest(examResultsId: String, examInfoId: String, testIds: List<String>, uuids: List<String>, combId: String?)`
  - `class ApiClient(client: OkHttpClient, cookieJar: PersistentCookieJar, baseUrl: String = DEFAULT_BASE_URL) : UpstreamApi` + `companion object { const val DEFAULT_BASE_URL = "https://test.lanjingweike.com"; const val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0" }`
  - `class PersistentCookieJar(private val store: CookieStore) : okhttp3.CookieJar`(内存映射 + 每次请求前从 store 刷新、响应后持久化;额外提供 `fun headerStringForBase(): String`(store 内全部 cookie 的 `name=value; ` 连接)、`fun hasCookie(name: String): Boolean`、`fun hasSession(): Boolean`、`fun clear()`(均委托 store))

**测试向量(从 iOS 测试移植,必须通过):**
- 登录哈希:任一手机号/密码组合的 `sha256Hex`/`md5Hex` 与 iOS `HashingTests`/`LoginFormTests` 一致(实现后与 spec 校验:先手动验证 `Hashers.sha256Hex("123456")` 与 iOS 已知值一致,写入测试断言)。
- CookieCloud 互操作:用 iOS `CookieCloudCryptoTests` 的向量(从 `apps/ios/LanjingQuizTests/CookieCloudCryptoTests.swift` 读取,逐字搬入 Kotlin 测试)。
- FormEncoder:`FormEncoder.encode(mapOf("a" to "b c", "空格" to "&="))` → 精确字符串(空格 `%20`,`&`→`%26`,`=`→`%3D`,UTF-8 中文百分号)。

- [ ] **Step 1: 写 Hashers/FormEncoder/Formatters 测试(先红)**

`HashersTest.kt`:
```kotlin
package com.qzh.lanjingquiz.Support

import org.junit.Assert.assertEquals
import org.junit.Test

class HashersTest {
    @Test fun `sha256 lowercase hex`() {
        assertEquals("8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92", Hashers.sha256Hex("123456"))
        assertEquals("e10adc3949ba59abbe56e057f20f883e", Hashers.md5Hex("123456"))
    }
    @Test fun `empty string hashes`() {
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", Hashers.sha256Hex(""))
        assertEquals("d41d8cd98f00b204e9800998ecf8427e", Hashers.md5Hex(""))
    }
}
```
(以上为公开已知向量;`md5Hex("123456")` 即 e10adc...)

`FormEncoderTest.kt`:
```kotlin
package com.qzh.lanjingquiz.Support

import org.junit.Assert.assertEquals
import org.junit.Test

class FormEncoderTest {
    @Test fun `percent encodes with alphanumerics and dash underscore tilde allowed`() {
        val out = FormEncoder.encode(mapOf(
            "userName" to "13800000000@1",
            "remember" to "false",
            "备注" to "a b&c=d",
        ))
        assertEquals("userName=13800000000%401&remember=false&%E5%A4%87%E6%B3%A8=a%20b%26c%3Dd", out)
    }
    @Test fun `ordered by map iteration and joined with ampersand`() {
        assertEquals("a=1&b=2", FormEncoder.encode(linkedMapOf("a" to "1", "b" to "2")))
    }
}
```
注意:`@` 不在允许集内 → `%40`;`=` 在 value 里 → `%3D`。若上述预期与你的实现不符,以"允许集 = ASCII 字母数字 + `-._~`"规则为准修正测试,不要改规则。

- [ ] **Step 2: 实现 Hashers/FormEncoder/Formatters/SplitMix64**

`Hashers.kt`:
```kotlin
package com.qzh.lanjingquiz.Support

import java.security.MessageDigest

object Hashers {
    fun sha256Hex(s: String): String = hexDigest("SHA-256", s)
    fun md5Hex(s: String): String = hexDigest("MD5", s)
    private fun hexDigest(algorithm: String, s: String): String =
        MessageDigest.getInstance(algorithm).digest(s.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}
```

`FormEncoder.kt`:
```kotlin
package com.qzh.lanjingquiz.Support

object FormEncoder {
    private val ALLOWED = ('a'..'z') + ('A'..'Z') + ('0'..'9') + listOf('-', '_', '.', '~')

    fun encode(params: Map<String, String>): String =
        params.entries.joinToString("&") { (k, v) -> encodeComponent(k) + "=" + encodeComponent(v) }

    private fun encodeComponent(s: String): String {
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = (b.toInt() and 0xFF).toChar()
            if (c in ALLOWED) sb.append(c)
            else sb.append('%').append("%02X".format(b.toInt() and 0xFF))
        }
        return sb.toString()
    }
}
```

`Formatters.kt`:
```kotlin
package com.qzh.lanjingquiz.Support

import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

object Formatters {
    fun mmss(seconds: Int): String = String.format(Locale.US, "%02d:%02d", seconds / 60, seconds % 60)
    fun isoNow(): String = Instant.now().toString()
    fun displayTime(epochMillis: Long): String =
        ZonedDateTime.ofInstant(Instant.ofEpochMilli(epochMillis), ZoneId.systemDefault())
            .format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.US))
    fun exportFileName(now: ZonedDateTime = ZonedDateTime.now()): String =
        "爬取日志_" + now.format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmm", Locale.US)) + ".txt"
}
```

`SplitMix64.kt`(与 iOS `BankLogic` 洗牌同一算法,测试用固定种子断言序列):
```kotlin
package com.qzh.lanjingquiz.Support

import kotlin.random.Random

/** SplitMix64 确定性 RNG,与 iOS SeededGenerator 同算法(spec §3.6)。 */
class SplitMix64(seed: ULong) : Random(seed.toLong()) {
    private var state = seed
    override fun nextBits(bitCount: Int): Int = nextLong().toInt().shr(32 - bitCount) and ((1 shl bitCount) - 1)
    override fun nextLong(): Long {
        state += 0x9E3779B97F4A7C15UL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9UL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBUL
        return (z xor (z shr 31)).toLong()
    }
}
```

- [ ] **Step 3: 实现 CookieCloudCrypto + 移植互操作测试**

`CookieCloudCrypto.kt`(参数逐字来自 spec §3.4):
```kotlin
package com.qzh.lanjingquiz.Support

import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

object CookieCloudCrypto {
    // key = UTF-8 字节 of 前16字符 of MD5("{uuid}-{password}") 小写 hex
    fun deriveKey(uuid: String, password: String): ByteArray {
        val hex = Hashers.md5Hex("$uuid-$password")
        return hex.substring(0, 16).toByteArray(Charsets.UTF_8)
    }

    fun fixedEncrypt(plain: String, key: ByteArray): String {
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(ByteArray(16)))
        return Base64.getEncoder().encodeToString(cipher.doFinal(plain.toByteArray(Charsets.UTF_8)))
    }

    fun fixedDecrypt(base64Cipher: String, key: ByteArray): String {
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(ByteArray(16)))
        return String(cipher.doFinal(Base64.getDecoder().decode(base64Cipher)), Charsets.UTF_8)
    }

    /** legacy: base64(Salted__ + 8B salt + AES-256-CBC(PKCS7), key=32B, iv=16B via EVP_BytesToKey MD5) */
    fun legacyDecrypt(base64Cipher: String, uuid: String, password: String): String {
        val full = Base64.getDecoder().decode(base64Cipher)
        if (full.size < 16 || !String(full, 0, 8, Charsets.US_ASCII).equals("Salted__")) {
            throw IllegalArgumentException("missingSaltedHeader")
        }
        val salt = full.copyOfRange(8, 16)
        val (key, iv) = evpBytesToKey(password.toByteArray(Charsets.UTF_8), salt, 48)
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
        return String(cipher.doFinal(full.copyOfRange(16, full.size)), Charsets.UTF_8)
    }

    /** EVP_BytesToKey MD5:D_i = MD5(D_{i-1} + passphrase + salt);key=前32B, iv=次16B。 */
    private fun evpBytesToKey(password: ByteArray, salt: ByteArray, total: Int): Pair<ByteArray, ByteArray> {
        val md = java.security.MessageDigest.getInstance("MD5")
        var prev = ByteArray(0)
        val out = java.io.ByteArrayOutputStream()
        while (out.size() < total) {
            md.reset()
            md.update(prev)
            md.update(password)
            md.update(salt)
            prev = md.digest()
            out.write(prev)
        }
        val all = out.toByteArray()
        return all.copyOfRange(0, 32) to all.copyOfRange(32, 48)
    }

    fun encryptAny(plain: String, uuid: String, password: String): Pair<String, String> {
        val key = deriveKey(uuid, password)
        return fixedEncrypt(plain, key) to "aes-128-cbc-fixed"
    }

    /** 先按声明类型,失败再试另一算法;双失败抛最后一次错误。 */
    fun decryptAny(encrypted: String, uuid: String, password: String, cryptoType: String?): String {
        val key = deriveKey(uuid, password)
        val errors = ArrayList<Throwable>()
        val attempt: (() -> String) = when (cryptoType ?: "legacy") {
            "aes-128-cbc-fixed" -> ({ fixedDecrypt(encrypted, key) })
            else -> ({ legacyDecrypt(encrypted, uuid, password) })
        }
        try { return attempt() } catch (e: Throwable) { errors.add(e) }
        try {
            return if (cryptoType == "aes-128-cbc-fixed") legacyDecrypt(encrypted, uuid, password)
                   else fixedDecrypt(encrypted, key)
        } catch (e: Throwable) { errors.add(e) }
        throw errors.last()
    }
}
```

`CookieCloudCryptoTests.kt`:从 `apps/ios/LanjingQuizTests/CookieCloudCryptoTests.swift` 与 `apps/web/lib/cookiecloud.js` 读取既有互操作向量(uuid/password/明文 → 密文、legacy 密文 → 明文),逐字搬入;至少覆盖:fixed 加解密往返、legacy 解密(用 iOS/web 现有密文样例)、错误密码 → 异常、未知 crypto_type → 尝试另一算法。

- [ ] **Step 4: 实现 SettingsStore/SecureStore + JVM 测试(store 用 InMemory 变体)**

`SettingsStore.kt` 与 `SecureStore.kt` 按 Interfaces 签名实现;SecureStore 用 `androidx.security.crypto.MasterKey` + `EncryptedSharedPreferences`。JVM 单测只测接口层逻辑:写 `InMemorySettingsStore`/`InMemorySecureStore`(内存 Map 实现同一接口语义)供后续任务测试用;`PrefsCookieStore` 的 JSON 序列化往返用 InMemorySecureStore 测(`StoredCookie` 全字段序列化 → 反序列化相等,含 null expiry/sameSite)。

`CookieStore.kt`:
```kotlin
package com.qzh.lanjingquiz.Network

import com.qzh.lanjingquiz.Data.SecureStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class StoredCookie(
    val name: String,
    val value: String,
    val domain: String,
    val path: String,
    val secure: Boolean,
    val httpOnly: Boolean,
    val expiry: Long? = null,
    val sessionOnly: Boolean = false,
    val sameSite: String? = null,
)

interface CookieStore {
    fun load(): List<StoredCookie>
    fun save(cookies: List<StoredCookie>)
    fun clear()
    fun hasSession(): Boolean   // 存在 name == "sessionId" 的 cookie
    fun headerString(): String  // "name=value; name2=value2"
}

class PrefsCookieStore(private val secureStore: SecureStore) : CookieStore {
    private val json = Json { ignoreUnknownKeys = true }
    override fun load(): List<StoredCookie> =
        secureStore.getString("cookies")?.let { json.decodeFromString<List<StoredCookie>>(it) } ?: emptyList()
    override fun save(cookies: List<StoredCookie>) =
        secureStore.putString("cookies", json.encodeToString(cookies))
    override fun clear() = secureStore.remove("cookies")
    override fun hasSession(): Boolean = load().any { it.name == "sessionId" }
    override fun headerString(): String =
        load().joinToString("; ") { "${it.name}=${it.value}" }
}
```

- [ ] **Step 5: 实现 DTO + PersistentCookieJar + APIClient + MockWebServer 测试**

`UpstreamDto.kt`(snake_case 键逐字;`StringValue` 自定义序列化器容忍 string/int/double):
```kotlin
package com.qzh.lanjingquiz.Network

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable(with = StringValue.Serializer::class)
data class StringValue(val value: String) {
    object Serializer : kotlinx.serialization.KSerializer<StringValue> {
        override val descriptor = kotlinx.serialization.descriptors.PrimitiveSerialDescriptor("StringValue", kotlinx.serialization.descriptors.PrimitiveKind.STRING)
        override fun serialize(encoder: kotlinx.serialization.encoding.Encoder, value: StringValue) = encoder.encodeString(value.value)
        override fun deserialize(decoder: kotlinx.serialization.decoding.Decoder): StringValue {
            val json = decoder as? JsonDecoder ?: error("StringValue only works with JSON")
            val el = json.decodeJsonElement()
            return StringValue(when (el) {
                is JsonPrimitive -> if (el.isString) el.content else el.contentOrNull ?: ""
                else -> ""
            })
        }
    }
}

@Serializable
data class LoginResponse(val success: Boolean, val desc: String? = null)

@Serializable
data class ExamListResponse(
    val success: Boolean,
    val desc: String? = null,
    @SerialName("bizContent") val biz: ExamListBiz? = null,
)

@Serializable
data class ExamListBiz(
    val total: Int = 0,
    val styles: List<StyleDto> = emptyList(),
    @SerialName("examInfoModelList") val exams: List<ExamDto> = emptyList(),
)

@Serializable
data class StyleDto(val id: String = "", val name: String = "")

@Serializable
data class ExamDto(
    val id: String = "",
    @SerialName("examName") val name: String = "",
    @SerialName("examStyle") val examStyle: String = "",
    @SerialName("examStyleName") val styleName: String = "",
    @SerialName("practiceMode") val practiceMode: String = "",
    @SerialName("examMode") val examMode: String = "",
    @SerialName("examTime") val examTime: String = "",
    @SerialName("paperInfoId") val paperInfoId: String = "",
    @SerialName("examTimesNum") val examTimesNum: String = "",
    @SerialName("examTimesRestrict") val examTimesRestrict: String = "",
    val paid: Boolean = false,
    @SerialName("examTimeRestrict") val timeRestrict: String = "",
    val wfs: String = "",          // "1" 新卷
    @SerialName("timeLeft") val timeLeft: String = "",
)

@Serializable
data class QuestionDto(
    @SerialName("_id") val id: String = "",
    val question: String = "",
    @SerialName("parent_info") val parentInfo: String? = null,
    @SerialName("answer1") val answer1: String = "",
    @SerialName("answer2") val answer2: String = "",
    @SerialName("answer3") val answer3: String = "",
    @SerialName("answer4") val answer4: String = "",
    @SerialName("key1") val key1: StringValue? = null,
    @SerialName("key2") val key2: StringValue? = null,
    @SerialName("key3") val key3: StringValue? = null,
    @SerialName("key4") val key4: StringValue? = null,
    @SerialName("test_ans") val testAns: String = "",
    @SerialName("test_ans_right") val testAnsRight: String = "",
    val analysis: String = "",
    @SerialName("_isMulti") val isMulti: Boolean = false,
) {
    fun optionTexts(): List<String> = listOf(answer1, answer2, answer3, answer4)
}
```

`PersistentCookieJar.kt`(OkHttp CookieJar;响应后合并写回 store,请求前加载;只持久化 domain 含 `lanjingweike.com` 或测试 base 域名的 cookie 之外全部保留——与 iOS 一致,一律全存):
```kotlin
package com.qzh.lanjingquiz.Network

import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

class PersistentCookieJar(private val store: CookieStore) : CookieJar {
    private val cache = LinkedHashMap<String, List<Cookie>>()

    fun headerStringForBase(): String = store.headerString()
    fun hasCookie(name: String): Boolean = store.load().any { it.name == name }
    fun hasSession(): Boolean = store.hasSession()
    fun clear() = store.clear()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        cache[url.host] = cookies
        store.save(store.load() + cookies.map { it.toStored() })
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        store.load().forEach { cache[it.domain] = listOf(it.toOkHttp(url)) }
        val now = System.currentTimeMillis()
        return cache.values.flatten()
            .filter { it.matches(url) && (it.expiresAt == Long.MAX_VALUE || it.expiresAt > now) }
    }

    private fun Cookie.matches(url: HttpUrl): Boolean =
        (url.host.endsWith(domain.removePrefix(".")) || domain.removePrefix(".") in url.host) && url.encodedPath.startsWith(path)

    private fun Cookie.toStored() = StoredCookie(
        name, value, domain.removePrefix("."), path, secure, httpOnly,
        expiry = if (expiresAt == Long.MAX_VALUE) null else expiresAt / 1000,
        sessionOnly = expiresAt == Long.MAX_VALUE, sameSite = null,
    )
    private fun StoredCookie.toOkHttp(url: HttpUrl) = Cookie.Builder()
        .domain(domain).path(path).name(name).value(value)
        .apply { if (secure) this.secure(); if (httpOnly) this.httpOnly() }
        .apply { if (sessionOnly || expiry == null) this.expiresAt(Long.MAX_VALUE) else this.expiresAt(expiry * 1000) }
        .build()
}
```
(domain 匹配语义以 OkHttp 默认行为为准,测试用 MockWebServer 的 `127.0.0.1` 验证 round-trip:save → loadForRequest 返回同名 cookie。)

`ApiClient.kt`(核心;端点表单逐字抄 spec §3.1):
```kotlin
package com.qzh.lanjingquiz.Network

import com.qzh.lanjingquiz.Support.FormEncoder
import com.qzh.lanjingquiz.Support.Hashers
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

class ApiException(val code: Int, override val message: String) : Exception(message) {
    companion object {
        const val SESSION_EXPIRED = 401
        const val NOT_LOGGED_IN = 4011
        const val INVALID_RESPONSE = 5000
        const val UPSTREAM = 5001
        const val NETWORK = 5002
        val SESSION_EXPIRED_ERROR = ApiException(SESSION_EXPIRED, "登录已过期，请重新登录")
    }
}

data class ExamListResult(val total: Int, val styles: List<StyleDto>, val exams: List<ExamDto>)
data class EnterExamResult(val examResultsId: String, val examInfoId: String, val uuid: String?)
data class ExamResult(val score: String, val beatRate: String, val rank: String)
data class QuestionBatchRequest(
    val examResultsId: String, val examInfoId: String,
    val testIds: List<String>, val uuids: List<String>, val combId: String? = null,
)

interface UpstreamApi {
    suspend fun warmUpJsSession()
    suspend fun login(phone: String, password: String)
    suspend fun examList(): ExamListResult
    suspend fun enterExam(examInfoId: String): EnterExamResult
    suspend fun fetchQuestions(req: QuestionBatchRequest): List<QuestionDto>
    suspend fun submitAnswer(examResultsId: String, examInfoId: String, testId: String, testAns: String, correct: Boolean)
    suspend fun markQuestion(testId: String, examResultsId: String, examInfoId: String, isMark: Boolean)
    suspend fun submitExam(examInfoId: String, examResultsId: String): ExamResult
    suspend fun logout()
    fun hasSession(): Boolean
    fun clearSession()
    val cookieHeader: String
}

class ApiClient(
    private val http: OkHttpClient,
    private val cookieJar: PersistentCookieJar,
    private val baseUrl: String = DEFAULT_BASE_URL,
) : UpstreamApi {

    private val json = Json { ignoreUnknownKeys = true }
    private val formType = "application/x-www-form-urlencoded; charset=UTF-8".toMediaType()

    override val cookieHeader: String get() = cookieJar.headerStringForBase()
    override fun hasSession(): Boolean = cookieJar.hasSession()
    override fun clearSession() = cookieJar.clear()

    override suspend fun warmUpJsSession() = withContext(Dispatchers.IO) {
        if (cookieJar.hasCookie("JSESSIONID")) return@withContext
        request("/login/account/login/1", detectExpiry = false)
    }

    override suspend fun login(phone: String, password: String) = withContext(Dispatchers.IO) {
        val normalized = phone.filterNot { it.isWhitespace() }
        val body = FormEncoder.encode(linkedMapOf(
            "userName" to "$normalized@1",
            "userNameInput" to normalized,
            "password" to Hashers.sha256Hex(password),
            "passwordMD5" to Hashers.md5Hex(password),
            "companyId" to "1", "newCompanyId" to "1", "remember" to "false",
            "phoneAccount" to "", "authCode" to "", "captchaText" to "", "nextUrl" to "",
        ))
        val resp = request("/login/account/login", form = body, referer = "$baseUrl/exam")
        val parsed = runCatching { json.decodeFromString(LoginResponse.serializer(), resp) }
            .getOrElse { throw ApiException(ApiException.INVALID_RESPONSE, "服务器响应异常") }
        if (!parsed.success) throw ApiException(ApiException.UPSTREAM, parsed.desc ?: "登录失败")
    }

    override suspend fun examList(): ExamListResult = withContext(Dispatchers.IO) {
        val body = FormEncoder.encode(linkedMapOf(
            "examStyle" to "0", "timeSort" to "", "status" to "", "setProcess" to "-1",
            "page" to "1", "firstVisit" to "true", "name" to "", "rowCount" to "100", "participation" to "",
        ))
        val resp = request("/exam/current_exam_list", form = body, referer = "$baseUrl/exam")
        val parsed = runCatching { json.decodeFromString(ExamListResponse.serializer(), resp) }
            .getOrElse { throw ApiException(ApiException.INVALID_RESPONSE, "服务器响应异常") }
        if (!parsed.success) throw ApiException(ApiException.UPSTREAM, parsed.desc ?: "获取考试列表失败")
        val biz = parsed.biz ?: ExamListBiz()
        ExamListResult(biz.total, biz.styles, biz.exams)
    }
    // ...(enterExam/fetchQuestions/submitAnswer/markQuestion/submitExam/logout 按 spec §3.1 同模式实现:
    //  enterExam = GET /exam/enter_exam/1/{id} 后依次 POST faceCheckCondition/start_exam_queue/check_queue_status(≤30×2s)/test_complete(≤30×2s)/GET exam_start,解析 JS 变量与卡片,返回 EnterExamResult;
    //  fetchQuestions = POST /exam/get_question_info/,50 题一批,解码失败重试 3×3s(挂起 3s);
    //  submitAnswer = POST /exam/exam_start_ing_multi(examTestList=JSON 数组字符串,timeStamp=epochMs);
    //  markQuestion = POST /exam/exam_question_mark(isMark "1"/"0", timeStamp);
    //  submitExam = GET /exam/exam_ending?...isForce=0&switchScreen=0&noOpsAutoCommit=0 → 结果页正则解析 score/beatRate/rank,无 class="score" → ApiException(UPSTREAM, "考试未能结束，请刷新后重试");
    //  logout = POST /login/public/logout,referer baseUrl/exam/pc/home/,detectExpiry=false,吞掉一切错误)

    /** 统一请求入口:请求头/表单编码/过期三规则/错误映射全部在此。 */
    private fun request(
        path: String,
        form: String? = null,
        referer: String = "$baseUrl/exam",
        detectExpiry: Boolean = true,
    ): String {
        val url = baseUrl + path
        val rb = form?.toRequestBody(formType)
        val builder = Request.Builder().url(url)
            .header("User-Agent", USER_AGENT)
            .header("X-Requested-With", "XMLHttpRequest")
            .header("Origin", baseUrl)
            .header("Referer", referer)
            .header("Accept", "application/json, text/javascript, */*; q=0.01")
            .header("sec-ch-ua", "\"Microsoft Edge\";v=\"149\", \"Chromium\";v=\"149\", \"Not)A;Brand\";v=\"24\"")
            .header("sec-ch-ua-mobile", "?0")
            .header("sec-ch-ua-platform", "\"Windows\"")
        val isGet = form == null && !path.startsWith("/exam/exam_ending")
        try {
            val call = http.newCall(if (isGet) builder.get().build() else builder.post(rb ?: "".toRequestBody(formType)).build())
            call.execute().use { resp ->
                val body = resp.body?.string().orEmpty()
                if (detectExpiry && detectSessionExpiry(resp.code, body)) {
                    clearSession()
                    throw ApiException.SESSION_EXPIRED_ERROR
                }
                if (resp.code !in 200..299) {
                    throw ApiException(ApiException.UPSTREAM, "服务器响应异常")
                }
                return body
            }
        } catch (e: ApiException) {
            throw e
        } catch (e: IOException) {
            throw ApiException(ApiException.NETWORK, "网络错误：${e.message}")
        }
    }

    internal fun detectSessionExpiry(status: Int, body: String): Boolean {
        if (status == 302 && location?.contains("/login/account/login") == true) return true
        val lc = body.lowercase()
        if (lc.contains("/login/account/login") && lc.contains("<!doctype")) return true
        return Regex("\"onlineStatus\"\\s*:\\s*\"?0\"?").containsMatchIn(body)
    }

    companion object {
        const val DEFAULT_BASE_URL = "https://test.lanjingweike.com"
        const val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0"
    }
}
```
注意:上述 `request()` 的 302 重定向检测需要 OkHttp 不自动跟随(检测规则 1)。**决策:** OkHttp 默认跟随重定向——为保留规则 1,构造 client 时 `followRedirects(false)` 并在代码内手动跟随一次(把 Location 相对解析后重发),或直接用 body 规则兜底。实现时选:**`followRedirects(false) + followSslRedirects(false)`,在 request() 内对 3xx 手动取 Location 重发一次并记录 redirectTargets**,这样三规则全部成立。测试 `ApiClientTest` 用 MockWebServer 覆盖:
- 登录成功(响应 `{"success":true}`)→ `hasSession()` 由 MockWebServer 下发的 `Set-Cookie: sessionId=abc; Path=/` 变为 true
- 登录失败(`{"success":false,"desc":"密码错误"}`)→ ApiException(UPSTREAM,"密码错误")
- 过期规则 2(body 含 `/login/account/login` + `<!DOCTYPE` html)→ ApiException(SESSION_EXPIRED)且 cookie 被清
- 过期规则 3(`{"onlineStatus":"0"}` 内嵌 JSON)→ 同上
- `warmUpJsSession` 不发过期检测(响应是过期页也不抛,仅暖机)

- [ ] **Step 6: Hilt 绑定 + 全量本地验证 + 提交**

`App/AppModule.kt`:
```kotlin
package com.qzh.lanjingquiz.App

import com.qzh.lanjingquiz.Data.SecureStore
import com.qzh.lanjingquiz.Data.SettingsStore
import com.qzh.lanjingquiz.Network.*
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {
    @Provides @Singleton
    fun settingsStore(context: android.content.Context): SettingsStore = SettingsStore(context)

    @Provides @Singleton
    fun secureStore(context: android.content.Context): SecureStore = SecureStore(context)

    @Provides @Singleton
    fun cookieStore(secureStore: SecureStore): CookieStore = PrefsCookieStore(secureStore)

    @Provides @Singleton
    fun cookieJar(store: CookieStore): PersistentCookieJar = PersistentCookieJar(store)

    @Provides @Singleton
    fun okHttp(cookieJar: PersistentCookieJar): OkHttpClient = OkHttpClient.Builder()
        .cookieJar(cookieJar)
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .cache(null)
        .build()

    @Provides @Singleton
    fun apiClient(http: OkHttpClient, cookieJar: PersistentCookieJar): ApiClient = ApiClient(http, cookieJar)
}
```

```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
cd apps/android && ./gradlew testDebugUnitTest assembleDebug
```
Expected: 全部通过。提交:
```bash
git add apps/android/LanjingQuiz
git commit -m "feat(android): 网络契约层(Hashers/表单编码/DTO/持久 CookieJar/APIClient/加密)"
```

---

## Task 2: 登录与会话(AppState 路由/登录页/会话恢复)

**Files:**
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/App/AppState.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Login/LoginViewModel.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Login/LoginScreen.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/AppRoot.kt`(改写:路由切换 + 三 Tab + 通知横幅 + 简单启动页)
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/EmptyScreens.kt`(考试列表/练习/我的占位屏)
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/App/AppStateTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/UI/Login/LoginViewModelTest.kt`

**Interfaces:**
- Consumes: Task 1 的 `UpstreamApi`/`CookieStore`/`SettingsStore`。
- Produces:
  - `sealed interface Route { data object Login; data object Home; data class Quiz(val exam: com.qzh.lanjingquiz.Network.ExamDto); data class Result(val result: com.qzh.lanjingquiz.Network.ExamResult, val examName: String) }`
  - `enum class ThemeMode { Light, Dark, System }`
  - `@HiltViewModel class AppState @Inject constructor(private val api: UpstreamApi, private val settings: SettingsStore) : ViewModel()`:
    - `val route: StateFlow<Route>`(初始 Login)、`val selectedTab: StateFlow<HomeTab>`、`val notice: StateFlow<String?>`、`val theme: StateFlow<ThemeMode>`(从 settings 键 `theme` 加载,缺省 System)、`val autoAdvance: StateFlow<Boolean>`(键 `quiz.autoAdvanceOnCorrect`,缺省 false)
    - `fun start()`: `if (api.hasSession()) route=Home else Login`(T6 在此追加 CookieCloud pull)
    - `fun finishLogin()`: `if (api.hasSession()) route=Home else Login`
    - `fun handleSessionExpiry()`: 清会话 + `notice="登录已过期，请重新登录"` + `route=Login`
    - `fun logout()`: 调 `api.logout()` best-effort(异常吞掉),然后 `api.clearSession()` + `route=Login` + `selectedTab=Exams`
    - `fun navigateTo(route: Route)`(唯一写 route 的入口;路由切换一律走它)、`fun showNotice(text: String?)`、`fun setTheme(mode: ThemeMode)`(写键 `theme`;setFollowsSystem(true) 时先存 `theme.manual`;toggleTheme: Light↔Dark、System→Dark 并清 follows)、`fun setAutoAdvance(b: Boolean)`(写键 `quiz.autoAdvanceOnCorrect`)
  - `LoginViewModel`: `val phone: MutableStateFlow<String>`、`val password: MutableStateFlow<String>`、`val errorMessage: StateFlow<String?>`、`val isSubmitting: StateFlow<Boolean>`、`val showPassword: MutableStateFlow<Boolean>`、`val agreedToTerms: MutableStateFlow<Boolean>`(默认 true)、`fun submit()`(校验失败 → errorMessage="请输入手机号和密码";成功 → `appState.finishLogin()`;sessionExpired/notLoggedIn 之外的错误 → `errorMessage = e.message`)
  - `LoginScreen(vm: LoginViewModel, onFinished: () -> Unit)`、`AppRoot()` 改版签名不变

**登录行为基准(spec §3.5 文案逐字):**
- 两屏流程:落地页("密码登录"入口 + "我已阅读并同意《用户协议》与《隐私政策》")→ 密码页(手机号 +86、密码、显示/隐藏、登录按钮)
- 手机号归一化:`phone.filterNot { it.isWhitespace() }`(含不间断空格)
- 未同意协议 → 提交拦截并弹 "请先同意协议";协议/隐私文案占位页 "蓝鲸助手用户协议将在后续版本中提供。"
- 会话失效(非本页主动):notice 覆盖显示 "登录已失效，请重新登录" 并回登录页

- [ ] **Step 1: 写 AppState/LoginViewModel 测试(先红,用 fake UpstreamApi)**

`FakeApi.kt`(test 源集,跨任务复用;放在 `src/test/java/com/qzh/lanjingquiz/Fakes.kt`):
```kotlin
package com.qzh.lanjingquiz

import com.qzh.lanjingquiz.Network.*

class FakeApi : UpstreamApi {
    var session: Boolean = false
    var loginError: ApiException? = null
    var logoutCalls = 0
    var loginCalls = 0
    override suspend fun warmUpJsSession() {}
    override suspend fun login(phone: String, password: String) {
        loginCalls++
        loginError?.let { throw it }
        session = true
    }
    override suspend fun examList(): ExamListResult = ExamListResult(0, emptyList(), emptyList())
    override suspend fun enterExam(examInfoId: String): EnterExamResult = EnterExamResult("r1", examInfoId, null)
    override suspend fun fetchQuestions(req: QuestionBatchRequest): List<QuestionDto> = emptyList()
    override suspend fun submitAnswer(examResultsId: String, examInfoId: String, testId: String, testAns: String, correct: Boolean) {}
    override suspend fun markQuestion(testId: String, examResultsId: String, examInfoId: String, isMark: Boolean) {}
    override suspend fun submitExam(examInfoId: String, examResultsId: String): ExamResult = ExamResult("0", "?", "?")
    override suspend fun logout() { logoutCalls++ }
    override fun hasSession(): Boolean = session
    override fun clearSession() { session = false }
    override val cookieHeader: String get() = ""
}
```

`AppStateTest.kt`:
```kotlin
package com.qzh.lanjingquiz.App

import com.qzh.lanjingquiz.FakeApi
import com.qzh.lanjingquiz.UI.HomeTab
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class AppStateTest {
    @Test fun `start routes home when session exists`() = runTest {
        val api = FakeApi().apply { session = true }
        val state = AppState(api, InMemorySettingsStore())
        state.start()
        assertEquals(Route.Home, state.route.value)
    }
    @Test fun `start routes login when no session`() = runTest {
        val state = AppState(FakeApi(), InMemorySettingsStore())
        state.start()
        assertEquals(Route.Login, state.route.value)
    }
    @Test fun `handleSessionExpiry clears session and shows notice`() = runTest {
        val api = FakeApi().apply { session = true }
        val state = AppState(api, InMemorySettingsStore())
        state.handleSessionExpiry()
        assertEquals(Route.Login, state.route.value)
        assertEquals("登录已过期，请重新登录", state.notice.value)
        assertFalse(api.hasSession())
    }
    @Test fun `logout calls upstream then clears locally`() = runTest {
        val api = FakeApi().apply { session = true }
        val state = AppState(api, InMemorySettingsStore())
        state.logout()
        assertEquals(1, api.logoutCalls)
        assertFalse(api.hasSession())
        assertEquals(Route.Login, state.route.value)
    }
}
```
`InMemorySettingsStore`(test 源集,内存 Map 实现 SettingsStore 接口语义——把 `SettingsStore` 声明为 `interface` 加 `class PrefsSettingsStore(context)` 实现,与 CookieStore 同模式;生产注入 PrefsSettingsStore,测试注入 InMemory)。

`LoginViewModelTest.kt`:空手机/密码 → "请输入手机号和密码" 且不调 login;空白手机号 `" 138 0000 0000 "` 提交 → 调 login 且 phone 归一;login 抛 UPSTREAM("密码错误") → errorMessage="密码错误";login 成功 → onFinished 回调(或 finishLogin 后 route==Home,按你设计的 onFinished 触发方式断言)。

- [ ] **Step 2: 实现 SettingsStore 接口化 + AppState + LoginViewModel**

按 Interfaces 签名实现。`SettingsStore` 改为:
```kotlin
interface SettingsStore {
    fun getString(key: String, default: String? = null): String?
    fun putString(key: String, value: String)
    fun getBoolean(key: String, default: Boolean): Boolean
    fun putBoolean(key: String, value: Boolean)
    fun remove(key: String)
}
class PrefsSettingsStore(context: Context) : SettingsStore { /* getSharedPreferences("settings", MODE_PRIVATE) */ }
```
(改动 Task 1 的 `AppModule` 中 `SettingsStore(context)` 构造调用为 `PrefsSettingsStore(context)`。)

- [ ] **Step 3: 实现 LoginScreen + AppRoot 改版**

`LoginScreen.kt` 两屏流程:
```kotlin
@Composable
fun LoginScreen(vm: LoginViewModel, onFinished: () -> Unit) {
    var page by remember { mutableStateOf(0) } // 0 落地页, 1 密码页
    val error by vm.errorMessage.collectAsState()
    val phone by vm.phone.collectAsState()
    val password by vm.password.collectAsState()
    val submitting by vm.isSubmitting.collectAsState()
    val showPassword by vm.showPassword.collectAsState()
    var agreed by remember { mutableStateOf(false) }
    var showAgreementAlert by remember { mutableStateOf(false) }
    var showHelp by remember { mutableStateOf(false) }
    var showTerms by remember { mutableStateOf(false) }
    var showPrivacy by remember { mutableStateOf(false) }
    var showUserAgreementAlert by remember { mutableStateOf(false) }

    if (page == 0) {
        // 落地页:标题"蓝鲸助手" + 副标题 + "密码登录" 按钮(未同意协议 → showAgreementAlert)
        // 底部:我已阅读并同意《用户协议》与《隐私政策》(Checkbox 或 TextButton 切换 agreed)
    } else {
        // 密码页:返回按钮(回落地页)、手机号 OutlinedTextField(keyboardType=Phone)、
        // 密码 OutlinedTextField(PasswordVisualTransformation + 显示/隐藏切换 "显示密码"/"隐藏密码")、
        // "登录" Button(全宽,DSAccent;submitting 时转圈禁用)、"忘记密码" 与 "帮助" 行
    }
    error?.let { /* 顶部红色错误条 */ }
    if (showAgreementAlert) AlertDialog(text = "请先同意协议", confirm = { showAgreementAlert = false })
    if (showHelp) AlertDialog(
        title = "登录帮助",
        text = "请输入注册手机号和密码。如果忘记密码，请联系管理员重置。",
        confirm = { showHelp = false },
        dismiss = { showHelp = false },
    )
    if (showUserAgreementAlert) AlertDialog(text = "请先同意协议", ...)  // 与 iOS 一致的“知道了”路径
    if (showTerms) AlertDialog(title = "用户协议", text = "蓝鲸助手用户协议将在后续版本中提供。", ...)
    if (showPrivacy) AlertDialog(title = "隐私政策", text = "蓝鲸助手隐私政策将在后续版本中提供。", ...)
    LaunchedEffect(Unit) {
        // onFinished 由 AppRoot 在 route==Home 时切换;submit 成功路径经 vm.onFinished 或 route 监听触发
    }
}
```
(按钮 testTag:`password-login-entry`、`password-login-submit`,供 UI 测试。)

`AppRoot.kt` 改版:
```kotlin
@Composable
fun AppRoot(vm: AppState = hiltViewModel()) {
    val route by vm.route.collectAsState()
    val notice by vm.notice.collectAsState()
    var splashDone by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { vm.start(); splashDone = true }
    Box {
        when (route) {
            Route.Login -> LoginScreen(vm = hiltViewModel(), onFinished = vm::finishLogin)
            Route.Home -> HomeTabHost(vm)
            is Route.Quiz -> QuizScreen(exam = route.exam)   // T3 实现
            is Route.Result -> ResultScreen(result = route.result, examName = route.examName) // T3 实现
        }
        notice?.let { NoticeBanner(it) { vm.showNotice(null) } }   // DSOrange 背景横幅,Text(13sp semibold 白),右上 xmark
        if (!splashDone) SplashScreen()   // 简单静态:图标 + "蓝鲸助手" + "让每一次练习，都更清晰";fade 0.45s
    }
}

@Composable
fun HomeTabHost(vm: AppState) {
    val tab by vm.selectedTab.collectAsState()
    Scaffold(bottomBar = {
        NavigationBar {
            NavigationBarItem(Exams, "考试列表", Icons.Filled.CheckCircle) { vm.selectedTab.value = HomeTab.Exams }
            NavigationBarItem(Practice, "练习", Icons.Filled.Edit) { vm.selectedTab.value = HomeTab.Practice }
            NavigationBarItem(Profile, "我的", Icons.Filled.Person) { vm.selectedTab.value = HomeTab.Profile }
        }
    }) { padding ->
        when (tab) {
            HomeTab.Exams -> ExamListScreenPlaceholder(padding)   // T3 替换
            HomeTab.Practice -> PracticeBankScreenPlaceholder(padding)  // T5 替换
            HomeTab.Profile -> ProfileScreenPlaceholder(padding)  // T6 替换
        }
    }
}
```
主题联动:MainActivity 里 `val theme by appState.theme.collectAsState()` 决定 `LanjingQuizTheme(darkTheme = when(theme){ Light->true; Dark->false; System->isSystemInDarkTheme() })`——把 theme 提升到 MainActivity 观察 AppState(经 `hiltViewModel()`),或直接在 AppRoot 里包一层,实现时选一致方案。

- [ ] **Step 4: 本地验证 + 提交**

```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
cd apps/android && ./gradlew testDebugUnitTest assembleDebug
```
Expected: 全部通过。提交:
```bash
git commit -am "feat(android): 登录与会话(AppState 路由/登录两屏/会话恢复/通知横幅)"
```

---

## Task 3: 考试模块(列表/进入/题目/作答/答题卡/交卷/结果)

**Files:**
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Domain/ExamHtmlParser.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Domain/QuizLogic.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Domain/ResultPageParser.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Support/HtmlRenderer.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Shared/RichWebView.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/ExamList/ExamListViewModel.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/ExamList/ExamListScreen.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Quiz/QuizViewModel.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Quiz/QuizScreen.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Quiz/QuestionScreen.kt`(单题页:题干 WebView + 选项)
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Quiz/AnswerCard.kt`(答题卡 overlay + section tabs + 统计条)
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Quiz/StatsBar.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Result/ResultScreen.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/androidTest/.../MockUpstreamServer.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/androidTest/.../ExamFlowUiTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Domain/ExamHtmlParserTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Domain/QuizLogicTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Domain/ResultPageParserTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Support/HtmlRendererTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/UI/Quiz/QuizViewModelTest.kt`

**Interfaces:**
- Consumes: Task 1 `UpstreamApi`(enterExam 含队列轮询、fetchQuestions 批拉、submitAnswer/markQuestion/submitExam)、Task 2 `AppState`/`Route`。
- Produces:
  - `data class CardInfo(questionsId: String, uuId: String?, number: String, section: String, state: String, marked: Boolean)`(state ∈ "unanswered"|"right"|"error")
  - `data class ExamPage(examResultsId: String, examInfoId: String, uuid: String?, sections: List<String>, cards: List<CardInfo>)`
  - `object ExamHtmlParser { fun parse(html: String): ExamPage }`(正则逐字抄 spec §3.1 考试 HTML 契约)
  - `object ResultPageParser { fun parse(html: String): ExamResult }`(正则逐字抄 spec §3.1 结果页契约)
  - `object QuizLogic`:
    - `fun correctLetters(dto: QuestionDto): List<String>`(key1..key4=="1" 优先,>1 → 多选;0 个则回退 `test_ans_right` 非空 → [回退值];否则空 = 无答案)
    - `fun letterFor(dto: QuestionDto): String?`(单选答案字母;多选/无答案 null)
    - `fun isMulti(dto: QuestionDto): Boolean`(正确字母数 > 1)
    - `fun optionResult(isAnswered: Boolean, isSelected: Boolean, isCorrect: Boolean?, isMulti: Boolean, questionState: String): OptionMarker?`(未答 → null;选中且(单选错 或 不在正确答案集)→ Wrong;在正确答案集 → Correct;其余 null;规则逐字 spec §五)
    - `fun nextIndex(after: Int, states: List<String>): Int`(循环扫描第一个 "unanswered";全答 → min(after+1, size-1);size==0 → 0)
    - `fun lettersToKeys(letters: List<String>): String`(归一 A-D 排序去重 → `"key1,"`/`"key1,key3,"` 尾逗号)
    - `fun keysToLetters(testAns: String): List<String>`(容忍 `"key3,key1,key3,unknown,"` → 去重 A-D 排序;空 → [])
  - `enum class OptionMarker { Correct, Wrong }`
  - `class RichWebView`(Compose AndroidView 封装):
    - `@Composable fun RichHtmlBody(html: String, fontSizeSp: Int, dark: Boolean, allowTextSelection: Boolean, modifier: Modifier, onHeightChange: (Int) -> Unit)`(WebView:`loadDataWithBaseURL(BASE, html, "text/html", "utf-8", null)`;注入 spec §3.5 模板 CSS;高度经 onPageFinished 后 `evaluateJavascript("document.documentElement.scrollHeight")` 回读,delta > 0.5dp 才更新;禁选时 `-webkit-user-select:none` + `isEnabled=false` 亦可,但保 JS 高度)
  - `object HtmlRenderer { fun document(html: String, fontSizePx: Int, dark: Boolean): String }`(模板逐字 spec §3.5;图片 src 解析:优先 src 后 data-src、实体解码、拒绝 data:、相对路径按 `https://test.lanjingweike.com` 解析)
  - `@HiltViewModel class ExamListViewModel`:`val phase: StateFlow<Phase>`(Loading/Ready/Empty/Failed(msg))、`val groups: StateFlow<List<ExamGroup>>`、`data class ExamGroup(styleName: String, exams: List<ExamDto>)`、`fun refresh()`、`fun enter(exam: ExamDto)`(进入成功后 `appState.navigateTo(Route.Quiz(exam))`)、`fun abandon(exam: ExamDto)`(确认后走放弃流程 + 抑制陈旧记录);列表规则:过滤名含"常识判断"、按 style 分组、"机考题库"组排前、`wfs=="1"` → "新试卷" 徽标
  - `@HiltViewModel class QuizViewModel(api: UpstreamApi, appState: AppState)` + `fun start(exam: ExamDto)`(QuizScreen 的 LaunchedEffect 调用;exam 不入构造器,VM 由 Hilt 提供):`val page: StateFlow<Int>`、`val questions: StateFlow<List<QuestionDto>>`、`val states: StateFlow<List<QuestionState>>`、`val answers: StateFlow<Map<String, List<String>>>`(testId → 已选字母)、`val markedIds: StateFlow<Set<String>>`、`val sectionTabs: StateFlow<List<String?>>`(首段为 null = "全部";单 section 隐藏 tabs)、`val timer: StateFlow<String>`(mmss)、`val isSubmitting`、`val pendingMulti: StateFlow<Set<String>>`、`val showAnswerCard: MutableStateFlow<Boolean>`
    - `fun tapOption(letter: String)`(单选:立即提交+判定;多选:切换 pendingMulti)、`fun confirmSelection()`、`fun toggleMark()`、`fun goTo(index: Int)`(分页单一路径;重启计时器一次 + runID 防陈旧)、`fun nextQuestion()`、`fun submit()`(两段确认由 UI 层做)、`fun abandon()`、`fun submitConfirmed()`(isSubmitting 防重入)、`fun abandonConfirmed()`、`fun openAnswerCard()/closeAnswerCard()`、`fun jumpToSection(section: String?)`、自动下一题:autoAdvance 开启且答对 → 1200ms 延迟 nextQuestion(手动导航取消)
  - `data class QuestionState(questionsId: String, uuId: String?, num: String, section: String, combId: String?, state: String, marked: Boolean)`
  - `MockUpstreamServer`(androidTest,单例 MockWebServer,复刻 spec §3.1 全部路由 + wfs 语义 + 队列轮询;提供 `start()`、`baseUrl()`、`resetBankFlag` 等)
  - `ExamFlowUiTest`(UI 测试:登录 → 考试列表 → 进入 → 答题 → 答题卡 → 交卷 → 结果,全程 MockUpstreamServer)

**考试行为基准(spec §四 逐字):** 见上。

- [ ] **Step 1: 写解析器与 QuizLogic 测试(先红,夹具从 iOS 测试搬)**

`ExamHtmlParserTest.kt`/`ResultPageParserTest.kt`:从 `apps/ios/LanjingQuizTests/ExamHTMLParserTests.swift` 与 `ResultPageParserTests.swift` 的 HTML 夹具逐字搬入(卡片的 questionsId/uuId/number/section/state/marked、空 section → `(无分类)`、组合题 `insert-list`、`exam_results_id`/`exam_info_id`/`uuId` JS 变量;结果页 score/beatRate/rank 的正则与兜底)。

`QuizLogicTest.kt`(用例从 iOS `QuizLogicTests`/`PracticeUpstreamMappingTests` 移植):
- correctLetters:key1=="1" → ["A"];key3=="1" → ["C"];key1+key3 → ["A","C"];全 0 且 test_ans_right 非空 → [test_ans_right 值];全 0 且空 → []
- lettersToKeys:["C","A"] → "key1,key3,"(排序+尾逗号);keysToLetters("key3,key1,key3,unknown,") → ["A","C"]
- optionResult:未答 → null;选中且错 → Wrong;正确答案 → Correct;多选答错时参考答案 → Correct
- nextIndex:after=0, states=[right,unanswered,unanswered] → 1;全答 → min(after+1, size-1)

- [ ] **Step 2: 实现 ExamHtmlParser/ResultPageParser/QuizLogic/HtmlRenderer/RichWebView**

正则与规则逐字来自 spec §3.1/§3.5/§四。`RichWebView` 的实现要点:AndroidView factory 里配置 WebView(`settings.javaScriptEnabled=true`、`mixedContentMode = MIXED_CONTENT_COMPATIBILITY_MODE`、`loadDataWithBaseURL("https://test.lanjingweike.com", ...)`);`webViewClient.onPageFinished` 里 `evaluateJavascript("document.documentElement.scrollHeight")`;高度变化仅当 `abs(new - old) > 0.5f` 才回调,`max(1, height)` 下限;`allowTextSelection=false` 时注入 `-webkit-user-select:none; user-select:none` 且 `webView.isEnabled=false`。

- [ ] **Step 3: 实现 ExamListViewModel/QuizViewModel + 测试**

`QuizViewModelTest.kt`(runTest + FakeApi):
- enterExam 后 questions/states 填充;tapOption 单选正确 → states 更新 + answers 写入 + submitAnswer 被调(correct=true)
- 多选:两 tap 未提交不调 submit;confirmSelection 提交完整集合
- 标记:toggleMark 乐观更新 + markQuestion 被调;错误(非过期)回滚
- 自动下一题:autoAdvance=true 且答对 → advanceOne(用 `mainDispatcherRule` + `advanceTimeBy(1300)` 断言跳题);答错不跳;手动 goTo 取消待执行
- 计时器:goTo 后 60s 倒计时,过期 "00:00";runID 防陈旧(goTo(0)→goTo(1)→回 0,旧 tick 不写)
- submitConfirmed:isSubmitting 防重入(第二次调用不重复网络请求)
- 交卷成功 → appState.route == Route.Result(result, examName)

- [ ] **Step 4: 实现 MockUpstreamServer + ExamFlowUiTest**

`MockUpstreamServer.kt`(androidTest):MockWebServer 自增 dispatcher,按 spec §3.1 路由返回:
- `GET /login/account/login/1` → 200 + `Set-Cookie: JSESSIONID=js; Path=/`
- `POST /login/account/login` → `{"success":true}` + `Set-Cookie: sessionId=s123; Path=/`
- `POST /exam/current_exam_list` → 固定 2 场考试 JSON(`bizContent` 结构按 spec;一场 `wfs="1"` 新卷、一场 `wfs="0"` 进行中;含一组 style `机考题库`)
- `GET /exam/enter_exam/1/{id}` → 200 空页(重定向链简化)
- `POST /exam/faceCheckCondition` → `{}`
- `POST /exam/start_exam_queue` → `{"bizContent":{"isOk":true}}`
- `POST /exam/check_queue_status` → `{"bizContent":{"isOk":true}}`
- `POST /exam/test_complete` → `true`
- `GET /exam/exam_start/{id}` → 固定 HTML 夹具(2 个 section、4 张卡,含 `exam_results_id=ER1`、`exam_info_id=EI1`、题目号、一题 right 一题 error 两题 unanswered)
- `POST /exam/get_question_info/` → 按 testIds 返回对应 QuestionDto 数组(4 题:单选答案 key1、多选 key1+key3、无答案全 0、单选 key3;question 为 `<p>题干N</p>` 简单 HTML)
- `POST /exam/exam_start_ing_multi` → `{"success":true}`
- `POST /exam/exam_question_mark` → `{"success":true}`
- `GET /exam/exam_ending?...` → 结果页 HTML 夹具(`class="score">88<`、两个 `exam-result-percentage` → beatRate 72/rank 35)
- `POST /login/public/logout` → `{"success":true}`
- 记录已提交答案(testId→testAns)与标记状态,供测试断言。

`ExamFlowUiTest.kt`:Compose UI 测试(androidTest):
```kotlin
@RunWith(AndroidJUnit4::class)
class ExamFlowUiTest {
    // 启动参数:activityIntent.putExtra("mockBaseUrl", server.baseUrl)
    // AppState/AppModule 在 debug 构建读取该 extra 覆盖 baseUrl(T3 步骤 5 接线)
    @Test fun fullExamFlow() {
        server.start()
        // 登录页:输入手机号/密码(测试固定值),点"密码登录"
        // 考试列表:"机考题库"组、新试卷徽标
        // 点"继续考试" → 答题页:第 1 题题干可见;点 B(错)→ 红;点答题卡 → 网格;跳第 3 题
        // 多选:点 A、C → 提交 → 绿;交卷 → 确认 → 结果页 "88 分"
    }
}
```
先跑通 `./gradlew connectedDebugAndroidTest` 前,先在 JVM 侧用 `Robolectric` 替代?——不引入 Robolectric;UI 测试只在 CI 跑,本地只保证编译通过(`assembleDebugAndroidTest`)。

- [ ] **Step 5: 接线 debug 构建的 baseUrl 覆盖 + 本地验证 + 提交**

`AppModule.kt` 增加(debug-only 逻辑;生产 baseUrl 恒为 spec 常量):
```kotlin
@Provides @Singleton
fun apiClient(http: OkHttpClient, cookieJar: PersistentCookieJar): ApiClient =
    ApiClient(http, cookieJar, BuildConfig.API_BASE_URL)
```
`build.gradle.kts` buildTypes.debug 增加:
```kotlin
buildConfigField("String", "API_BASE_URL", "\"https://test.lanjingweike.com\"")
```
测试时用 `-PmockBaseUrl` 或 test runner 参数改写(具体机制由实现者选:BuildConfig 字段 + gradle property `-PmockBaseUrl=http://127.0.0.1:port` 最简单——CI UI job 启动 MockWebServer 于固定端口有冲突风险,**选方案**:androidTest 内 `System.getProperty`/Intent extra 由 ActivityScenario 传入,ApiClient 构造从 `application` 单例读 extra——实现者定,原则:生产路径不受影响)。

```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
cd apps/android && ./gradlew testDebugUnitTest assembleDebug assembleDebugAndroidTest
```
Expected: 全部通过。提交:
```bash
git commit -am "feat(android): 考试模块(解析/作答/答题卡/交卷/结果 + mock 上游 UI 测试)"
```

---

## Task 4: 练习数据层(题库存储/分类器/爬取器/会话与进度持久化)

**Files:**
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Data/BankQuestion.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Data/BankMeta.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Data/CrawlLogEntry.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Data/BankStorage.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Data/PracticeSession.kt`(含 store)
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Data/PracticeProgress.kt`(含 store)
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Support/HtmlHelpers.kt`(`normalizeImgSrcs`/`resolveImgSrc`/实体解码)
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Domain/QuestionClassifier.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Domain/BankLogic.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Domain/Crawler.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Data/BankStorageTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Data/PracticeSessionStoreTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Data/PracticeProgressStoreTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Domain/QuestionClassifierTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Domain/BankLogicTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Domain/CrawlerTest.kt`

**Interfaces:**
- Consumes: Task 1 `UpstreamApi`(enterExam/fetchQuestions/submitExam 供爬取)、`Hashers`/`Formatters`/`SplitMix64`。
- Produces:
  - `@Serializable data class BankQuestion(...)`(键逐字 spec §3.2;`answer` 用 `JsonElement` 自定义解码:字符串 / 数组 / null;构造时 `HtmlHelpers.normalizeImgSrcs` 作用于 question/stem/analysis——`HtmlHelpers` 在 T1 或本任务建,签名 `fun normalizeImgSrcs(html: String?): String?`)
  - `data class BankMeta(version: Int = 1, round: Int = 0, lastRun: String? = null, targets: List<String>, counts: Map<String, Int> = emptyMap(), papers: Map<String, Boolean> = emptyMap())`(JSON 键逐字 spec §3.2)
  - `data class CrawlLogEntry(timestamp: String, paperId: String?, paperName: String, step: String, outcome: String, message: String?)`(step/outcome 枚举值逐字)
  - `interface BankStorage { fun readCategory(category: String): List<BankQuestion>; fun appendRecords(category: String, records: List<BankQuestion>); fun writeAll(files: Map<String, List<BankQuestion>>); fun readMeta(): BankMeta?; fun writeMeta(meta: BankMeta); fun isPopulated(): Boolean; fun clearAll(); fun readCrawlLog(): List<CrawlLogEntry>; fun appendCrawlLog(entry: CrawlLogEntry) }`
  - `class FileBankStorage(context: Context) : BankStorage`(目录 `filesDir/LanjingQuiz/bank/`;JSONL 逐行容错解析:仅 `_id` 必需、未知键忽略、损坏尾行丢弃、按 `_id` 去重;全部写入走临时文件 + rename;`writeAll` 先写 5 个分类文件再写 meta.json)
  - `data class PracticeSession(category: String, subCategory: String, questions: List<BankQuestion>, index: Int = 0, answers: List<PracticeAnswer> = questions.map { PracticeAnswer() })`、`data class PracticeAnswer(selected: List<String> = emptyList(), revealed: Boolean = false, correct: Boolean? = null)`(selected 读入时排序归一,写出排序;JSON 键 `selected/revealed/correct`、session 键 `category/subCategory/questions/index/answers` 逐字 spec §3.2)
  - `interface PracticeSessionStore { suspend fun load(): PracticeSession?; suspend fun save(session: PracticeSession); suspend fun clear() }` + `class FilePracticeSessionStore(context) : PracticeSessionStore`(`practice-session.json` 原子写)
  - `data class PracticeProgress(val answeredIDs: List<String> = emptyList())`、`interface PracticeProgressStore { suspend fun load(): Map<String, PracticeProgress>; suspend fun save(progress: Map<String, PracticeProgress>); suspend fun clear() }` + `class FilePracticeProgressStore(context) : PracticeProgressStore`(`practice-progress.json` 整字典快照)
  - `object QuestionClassifier { fun classify(category: String, section: String, question: String, analysis: String): String; fun stripHtml(s: String): String; fun cleanSection(section: String): String }`(规则逐字 spec §3.3;规则引擎移植自 `apps/bank/lib/question-classifier.js`,对照 `apps/ios/LanjingQuiz/Networking/QuestionClassifier.swift` 的已移植实现)
  - `object BankLogic { val categories: List<String> = listOf("言语理解","数字运算","逻辑推理","资料分析","特有题型"); fun parseJsonl(text: String): List<BankQuestion>; fun resumeCandidate(saved: PracticeSession?, category: String, subCategory: String, ordered: List<BankQuestion>): PracticeSession?; fun shuffledKeepingGroups(questions: List<BankQuestion>, rng: SplitMix64): List<BankQuestion>; fun groupShuffleQuestions(...) }`
  - `class Crawler(private val api: UpstreamApi, private val storage: BankStorage)`:
    - `suspend fun crawl(refresh: Boolean, onProgress: (CrawlProgress) -> Unit): Result<Unit>`(失败 `Result.failure(ApiException/异常)`;刷新模式失败消息 `"{N} 份试卷爬取失败：{paperName}、…"`)
    - `data class CrawlProgress(current: Int, total: Int, paperName: String?, phase: String)`(phase ∈ 获取试卷列表/进入试卷/保存题目/结束作答/跳过 的显示名或机器名,UI 用)
    - 行为逐字 spec §五:目标筛选(style 含"机考题库"且卷名含五类之一)、wfs=1 创建+best-effort endAttempt(fire-and-forget submitExam 吞错)、wfs=0 只读、批 50、分类器写 subCategory、增量模式每卷存 meta + 3 连败停、刷新模式全爬+失败不提交、round+1、lastRun=isoNow、meta 最后写
- `object HtmlHelpers { fun normalizeImgSrcs(html: String?): String?; fun decodeEntities(s: String): String; fun resolveImgSrc(src: String, baseUrl: String): String? }`:normalizeImgSrcs 仅处理 `src="//` 与 `src='//` → `https://`(作用于 question/stem/analysis,不动 options);decodeEntities 解码 `&amp; &lt; &gt; &quot;`;resolveImgSrc 拒绝 `data:` URI、相对路径按 baseUrl 解析

**练习数据行为基准(spec §3.2/§3.3/§五 逐字):** 见上。

- [ ] **Step 1: 写存储/分类器/BankLogic 测试(先红,夹具从 iOS 测试搬)**

`BankStorageTest.kt`:临时目录;JSONL 写读往返(`BankQuestion` 全字段含 answer 三态);容错:未知键 `sourceExamId` 忽略、缺 question/options 用默认、损坏尾行丢弃、按 `_id` 去重;`writeAll` 原子性(中途异常后旧内容保留——模拟第二次写失败?至少断言 meta 最后写:writeAll 后 meta 与文件一致,`isPopulated()` 逻辑);`appendRecords` 增量追加。夹具文本从 `apps/ios/LanjingQuizTests/BankStorageTests.swift` 与 `BankLogicTests.swift` 搬。
`PracticeSessionStoreTest.kt`:往返/缺失返回 null/clear;含 `selected` 乱序 JSON 输入仍正确读入(集合语义)。
`PracticeProgressStoreTest.kt`:往返/聚合键前缀(从 iOS `PracticeProgressStoreTests` 与 `PracticeBankViewModelTests` 聚合用例搬)。
`QuestionClassifierTest.kt`:从 iOS `QuestionClassifierTests.swift` 的用例(含 `&ldquo;` 不解析、剥离顺序、`特有题型`/`资料分析` 豁免、`(共…)` 清洗、`其他` 兜底)逐字搬。
`BankLogicTest.kt`:resumeCandidate 四规则(同序/异序 ID 集合/不同集合/已完成/null);shuffledKeepingGroups 组合题相邻且组内顺序不变(资料分析夹具,固定种子断言)。

- [ ] **Step 2: 实现数据模型与存储**

按 Interfaces 实现;`BankQuestion` 的 `answer` 序列化:
```kotlin
@Serializable
data class BankQuestion(
    @SerialName("_id") val id: String,
    val category: String = "",
    val section: String = "",
    @SerialName("subCategory") val subCategory: String = "",
    val question: String = "",
    val stem: String? = null,
    val options: List<String> = emptyList(),
    val answer: AnswerShape? = null,   // 自定义:字符串/数组/null
    val analysis: String? = null,
    @SerialName("sourceExamName") val sourceExamName: String? = null,
    val round: Int? = null,
    @SerialName("collectedAt") val collectedAt: String? = null,
)
```
`AnswerShape` 用 `JsonElement` 承载:`sealed interface AnswerShape { data class Single(val letter: String); data class Multi(val letters: List<String>); data object None }` + 自定义 serializer:字符串 → Single(恰 1 字符);数组 → Multi;null/缺失 → None;其他 → None(容错)。注意 iOS 编码规则:单选写字符串、多选写数组——解码只认这三种形态。
(实现细节:用 `@Serializable(with = ...)` 自定义 `BankQuestionSerializer` 或对 answer 字段用 `JsonElement` + 转换函数,实现者选;JSON 键与容错规则不变。)

- [ ] **Step 3: 实现 QuestionClassifier + Crawler + 测试**

`QuestionClassifier.kt` 规则引擎(从 `apps/bank/lib/question-classifier.js` 逐条移植,允许对照 iOS `QuestionClassifier.swift`——它的测试已覆盖全部规则)。
`CrawlerTest.kt`(用 MockWebServer + 最小 `FakeBankStorage` 内存实现):
- 目标筛选:style 含"机考题库"且名含五类 → 爬;不含 → 跳过
- wfs=1 卷:enterExam 创建后 fetch 全题,结束前调 submitExam(fire-and-forget 断言调用)
- 增量模式:meta.papers 标记已爬卷跳过;连续 3 卷进入失败 → 停止且已存卷保留
- 刷新模式:任一试卷失败 → 不写 meta(旧 meta 保留),错误消息 `"1 份试卷爬取失败：xxx"`
- 记录按 _id 去重、分类器结果写入 subCategory、round 递增、lastRun 非空
- 批拉取:testIds 按 50 分块、combId 批单独请求(用 >50 题夹具断言请求次数)

- [ ] **Step 4: 本地验证 + 提交**

```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
cd apps/android && ./gradlew testDebugUnitTest assembleDebug
```
Expected: 全部通过。提交:
```bash
git commit -am "feat(android): 练习数据层(JSONL 题库存储/分类器/爬取器/会话与进度持久化)"
```

---

## Task 5: 练习 UI(爬取入口/分类列表/刷题/答题卡/题库设置)

**Files:**
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Practice/PracticeBankViewModel.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Practice/PracticeBankScreen.kt`(爬取状态机 UI:检查中/需登录/爬取进度/就绪/失败)
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Practice/CategoryListScreen.kt`(大类行 + x/N)
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Practice/SubcategoryListScreen.kt`(题型细分行 + x/N + 随机顺序开关)
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Practice/PracticeQuizViewModel.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Practice/PracticeQuizScreen.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Practice/PracticeStatsBar.kt`(答对/答错/未答 + 答题卡,**无交卷**)
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Practice/PracticeAnswerCard.kt`(overlay)
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Practice/PracticeBankSettingsSection.kt`(更新/删除/日志导出)
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/UI/Practice/PracticeBankViewModelTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/UI/Practice/PracticeQuizViewModelTest.kt`
- Modify: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/AppRoot.kt`(练习 Tab 接入 PracticeBankScreen)

**Interfaces:**
- Consumes: Task 4 全部数据层(BankStorage/PracticeSessionStore/PracticeProgressStore/QuestionClassifier/BankLogic/Crawler)、Task 1 `UpstreamApi`(爬取用)、Task 2 `AppState`。
- Produces:
  - `sealed interface BankPhase { data object Idle; data object Checking; data object NeedsLogin; data class Crawling(val progress: CrawlProgress); data object Ready; data class Failed(val message: String) }`
  - `@HiltViewModel class PracticeBankViewModel @Inject constructor(api, storage, sessionStore, progressStore, settings, appState)`:
    - `val phase: StateFlow<BankPhase>`、`val categories: StateFlow<List<CategorySummary>>`、`data class CategorySummary(name: String, count: Int, answered: Int)`
    - `fun ensureBankReady()`(Idle 才跑:isPopulated → Ready;无会话 → NeedsLogin;否则 Crawler.crawl(false) → Ready/Failed)
    - `fun refreshBank()`(Crawler.crawl(true);成功后清 session + progress + 存进度)
    - `fun deleteBank()`(清空 + 清 session/progress + `appState.showNotice("题库已删除，重新进入练习页会重新爬取全部试卷")` + bankResetVersion+1)
    - `fun answeredCount(category: String): Int`(键前缀 `"$category/"` 聚合)、`fun answeredCount(category: String, subCategory: String): Int`
    - `fun subcategories(category: String): List<SubcategorySummary>`、`data class SubcategorySummary(name: String, count: Int, answered: Int)`
    - `fun recordAnswered(category: String, subCategory: String, questionId: String)`(去重追加 + 保存)
    - `fun startPractice(category: String, subCategory: String)`(建/恢复 session 并交给 PracticeQuizViewModel;恢复规则 = BankLogic.resumeCandidate)
    - `fun exportLog(): String?`(生成导出文本;空日志 → null 由 UI 提示 "暂无爬取日志（完成一次爬取后生成）")
  - `@HiltViewModel class PracticeQuizViewModel @Inject constructor(appState, storage, sessionStore, progressStore, settings)` + `fun start(session: PracticeSession)`(PracticeBankViewModel.startPractice 建/恢复会话后调用):
    - `val session: StateFlow<PracticeSession?>`、`val page: StateFlow<Int>`(随机顺序 = 会话顺序;index 持久化)、`val pendingMulti: StateFlow<Set<String>>`、`val showAnswerCard: MutableStateFlow<Boolean>`、`val shuffle: StateFlow<Boolean>`(键 `practice.shuffle.<category>`,切换后按新开关重建会话顺序但保留已答)
    - `fun tapOption(letter: String)`(单选/无答案 reveal 即记;多选切 pendingMulti)、`fun confirmSelection()`、`fun nextQuestion()`、`fun goTo(index: Int)`、`fun jumpToSection(...)`(答题卡 section 过滤,单 section 无 tabs)、`fun openAnswerCard()/closeAnswerCard()`、`fun endSession()`(返回题型列表:清文件保留内存)
    - 判定规则逐字 spec §五:单选即判 / 多选提交判(集合相等)/ 无答案 reveal 不计对错;reveal 后经**自己的 progressStore** 记录进度(键 `"$category/$subCategory"`,按 question.id 去重追加,等待持久化屏障同 iOS `awaitSaveCount` 模式);恢复时若 resumeCandidate 命中则载入存档(不复洗不重复持久化)
  - UI 文案逐字 spec §3.5 练习章节:正在检查题库… / 正在爬取题库(x/y) / 需要登录 / 练习题目直接从蓝鲸平台获取，登录后才能使用。 / 去登录 / 题库爬取失败 / 请检查网络后重试;已爬取的题目会保留，重试会从中断处继续。 / 重试 / 已恢复上次练习进度 / 第 x/y 题 / 多选 / 无答案 / 提交 / 下一题 / 完成 / 练习完成 / 答对 X 题 / 答错 X 题 / 共 N 题 / 返回题型列表 / 答题卡 / 题库分类 / 题型 / 随机顺序 / 开启后本大类下每次练习按随机顺序出题;资料分析中共享同一材料的题目会保持在一起 / 该分类暂无题目 / 本地题库可能不完整，请在 我的 > 更新题库 重新爬取。 / 题库 / 日志 / 更新题库 / 删除题库 / 取消 / 删除本地题库？ / 本地题库将被清空(含爬取日志),再次进入练习页会重新从蓝鲸平台爬取全部试卷，每张新卷占用一次作答机会并自动结束。 / 日志导出 / 暂无爬取日志(完成一次爬取后生成) / 导出失败:{message} / (填空)
  - 入口进度行:`answered > 0` → `"x/N"`,否则 `"N 题"`;分类 footer `"题库版本 round <n> · 共 <n> 题"`

**练习 UI 行为基准(spec §五 逐字):** 见上。

- [ ] **Step 1: 写 VM 测试(先红)**

`PracticeBankViewModelTest.kt`(FakeBankStorage/FakeSessionStore/FakeProgressStore/FakeApi,从 iOS `PracticeBankViewModelTests` 用例移植):
- ensureBankReady:isPopulated → Ready 不触网;无会话 → NeedsLogin;爬取中 → Crawling 进度;爬取失败 → Failed 消息
- answeredCount 聚合(预置 `言语理解/虚词辨析` 2 题 + 本会话成语辨析 1 题 → 大类 3)
- recordAnswered 去重(tap 两次同题 → saveCount 1)
- deleteBank → 清空 + 通知文案
- refreshBank 成功 → 清 session/progress;失败 → 旧题库保留
- startPractice 恢复:预置存档同 ID 集合 → resumed;不同集合 → 新会话

`PracticeQuizViewModelTest.kt`:
- 单选 tap:立即 reveal、判定、记录进度(awaitSaveCount 语义同 iOS:持久化 Task 用屏障等待)
- 多选:未提交不记;confirmSelection 记
- 无答案:reveal 但 correct==null,计 answeredCount 不计对错
- 恢复:预置 practice-session.json(乱序 ID)→ 载入且不复洗;结束后 endSession 清文件
- 随机顺序:shuffle=true 用固定种子断言顺序(组内不变)、切换开关重建顺序但已答保留(answers 按题目 ID 索引而非位置——**决策:answers 以 question.id 为键**)

- [ ] **Step 2: 实现 PracticeBankViewModel + 各屏**

`PracticeBankScreen`:
```kotlin
@Composable
fun PracticeBankScreen(vm: PracticeBankViewModel = hiltViewModel(), onStart: (category: String, subCategory: String) -> Unit) {
    val phase by vm.phase.collectAsState()
    when (phase) {
        BankPhase.Checking -> CenterProgress("正在检查题库…")
        BankPhase.NeedsLogin -> EmptyState(
            title = "需要登录",
            message = "练习题目直接从蓝鲸平台获取，登录后才能使用。",
            action = { TextButton("去登录") { appState.route = Route.Login } },
        )
        is BankPhase.Crawling -> CrawlProgressUi(phase.progress)   // "正在爬取题库(x/y)" + 当前卷名
        is BankPhase.Failed -> ErrorRetry(phase.message, onRetry = vm::ensureBankReady)   // "题库爬取失败" + 说明 + "重试"
        BankPhase.Ready -> CategoryList(vm)
        BankPhase.Idle -> LaunchedEffect(Unit) { vm.ensureBankReady() }
    }
}
```
`CategoryListScreen`:LazyColumn,行 = 大类名 + `Text(if (answered > 0) "$answered/$count" else "$count 题")`,点击 → `SubcategoryListScreen`;footer `题库版本 round <n> · 共 <n> 题`。
`SubcategoryListScreen`:题型行同格式;顶部随机顺序 Switch(文案逐字);点击 → `PracticeQuizScreen`。
`PracticeQuizScreen`:VStack 结构同 iOS 版(VStack(spacing:0){header(第 x/y 题 + 多选/无答案徽标);恢复横幅?;分页容器;PracticeStatsBar}),`HorizontalPager`(Compose foundation `androidx.compose.foundation.pager.HorizontalPager`)绑定 `page` StateFlow(goTo 单一路径);作答后行着色同考试模块(选错红/对绿);底部 `PracticeStatsBar`(答对绿勾/答错红叉/未答灰圈 + 答题卡胶囊,`.padding(horizontal=16.dp).padding(vertical=10.dp).background(secondarySystemBackground 等价)`);完成页 summaryCard(练习完成/答对 X 题/答错 X 题/共 N 题/返回题型列表)。
`PracticeAnswerCard`:overlay(全屏 Box 覆盖,非 sheet),网格 + 当前题居中 + 点题 goTo + 关闭。

- [ ] **Step 3: 实现 PracticeBankSettingsSection + 日志导出(FileProvider)**

`res/xml/file_paths.xml` + Manifest provider:
```xml
<provider
    android:name="androidx.core.content.FileProvider"
    android:authorities="com.qzh.lanjingquiz.fileprovider"
    android:exported="false"
    android:grantUriPermissions="true">
    <meta-data android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/file_paths" />
</provider>
```
`file_paths.xml`:
```xml
<paths>
    <cache-path name="exports" path="BankExport/" />
</paths>
```
导出:写 `context.cacheDir/BankExport/爬取日志_yyyyMMdd_HHmm.txt`(UTF-8,行格式 `[yyyy-MM-dd HH:mm:ss] <paperName|- > · <step 显示名> — <outcome 显示名>(<message>)`;step 显示名 获取试卷列表/进入试卷/保存题目/结束作答/跳过,outcome 显示名 成功/失败/跳过)→ `ACTION_SEND text/plain` + FileProvider content:// URI;失败 → "导出失败：{message}";空日志 → "暂无爬取日志（完成一次爬取后生成）"。

- [ ] **Step 4: 接入 AppRoot + 本地验证 + 提交**

练习 Tab 替换占位为 `PracticeBankScreen(onStart = ...)`(导航经 AppState 内联状态或直接在当前 VM 层切换——实现者选,原则:进入练习后 route 仍在 Home 内,用 PracticeQuizViewModel 实例状态切换,返回题型列表回退)。系统返回键**不**清会话(仅退出练习页)。

```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
cd apps/android && ./gradlew testDebugUnitTest assembleDebug assembleDebugAndroidTest
```
Expected: 全部通过。提交:
```bash
git commit -am "feat(android): 练习 UI(爬取入口/分类进度/刷题/答题卡/题库设置/日志导出)"
```

---

## Task 6: 我的页 + CookieCloud 同步

**Files:**
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Network/CookieCloudClient.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/Domain/CookieCloudSync.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Profile/ProfileViewModel.kt`
- Create: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/UI/Profile/ProfileScreen.kt`
- Modify: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/App/AppState.kt`(start() 加云端拉取、finishLogin 加云端推送;注入 CookieCloudSync)
- Modify: `LanjingQuiz/src/main/java/com/qzh/lanjingquiz/App/AppModule.kt`(绑定 CookieCloudSync)
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Domain/CookieCloudSyncTest.kt`
- Test: `LanjingQuiz/src/test/java/com/qzh/lanjingquiz/Network/CookieCloudClientTest.kt`

**Interfaces:**
- Consumes: Task 1 `CookieCloudCrypto`/`CookieStore`/`SettingsStore`/`SecureStore`、Task 2 `AppState`、Task 5 题库设置入口。
- Produces:
  - `data class CloudConfig(enabled: Boolean, server: String, uuid: String)`(SettingsStore 键 `quiz.cookieCloud` JSON;密码在 SecureStore 键 `cookiecloud.password`;hash 在 SettingsStore 键 `quiz.cookieCloud.lastPushedHash`)
  - `class CookieCloudClient(server: String)`(独立 OkHttpClient,**不带** CookieJar 与缓存,超时 10s):
    - `suspend fun update(uuid: String, encrypted: String, cryptoType: String = "aes-128-cbc-fixed")`(成功 = HTTP<300 且 `{"action":"done"}`;否则抛异常)
    - `suspend fun get(uuid: String): Pair<String, String?>?`(404 → null;返回 encrypted + cryptoType)
    - `suspend fun probeSession(jarHeader: String): Boolean`(POST `{baseURL}/exam/current_exam_list` body `page=1&pageSize=1`,独立 client 发 Cookie 头;过期三规则 + 无 `sessionId=` → false;网络错误 → false)
  - `class CookieCloudSync @Inject constructor(api: UpstreamApi, cookieStore: CookieStore, secureStore: SecureStore, settings: SettingsStore)`:
    - `suspend fun pushIfNeeded()`(未配置/hasSession=false/hash 未变 → no-op;否则 encryptAny(JSON cookieData)→ update)
    - `suspend fun pullAndApplyIfNeeded(): Boolean`(4s 超时;远端存在 + 含 sessionId + hash 不同 + probe 通过 → apply;否则保持现状)
    - `suspend fun syncNow(): SyncResult`、`data class SyncResult(error: String?, applied: Boolean, pushed: Boolean)`(未配置 → error="CookieCloud 同步未配置";双向探活)
    - cookieData JSON 构造/解析逐字 spec §3.4:`cookie_data`(domain→cookies 数组,字段 name/value/domain/path/secure/expirationDate/session/sameSite)、`local_storage_data={}`;导入仅取 domain 含 `lanjingweike.com` 且含 sessionId;merge 时非 lanjingweike 域全量保留、lanjingweike 域用本地覆盖(先删后合);apply 后 `persist()` + 更新 hash
  - `ProfileViewModel`/`ProfileScreen`:账户(已登录)、外观(跟随系统/深色模式)、答题设置(答对后自动下一题)、题库设置(PracticeBankSettingsSection 复用)、Cookie 云端同步(服务器地址/UUID/密码/立即同步 + 状态文本"同步完成"/"已导入云端会话"/"已上传本地会话"逗号连接)、退出登录、版本 `1.0 (1)`(versionName (versionCode))
  - AppState 增补:`fun start()` 内先 `pullAndApplyIfNeeded()`(4s 边界)再 `api.hasSession()` 决定路由;`finishLogin()` 内 `pushIfNeeded()`;`syncNow()` 委托

**CookieCloud 行为基准(spec §3.4 逐字):** 见上(推送恒用 `aes-128-cbc-fixed`;未知类型 fail-closed;解密失败不应用;同步成功后更新 lastPushedHash)。

- [ ] **Step 1: 写测试(先红)**

`CookieCloudClientTest.kt`(MockWebServer):update 成功(`{"action":"done"}`)/被拒(其他 action → 异常);get 404 → null;probeSession:正常响应 → true、过期页 HTML → false、无 sessionId cookie → false。
`CookieCloudSyncTest.kt`(FakeApi + InMemory stores + MockWebServer):
- pushIfNeeded:未配置 no-op;hash 相同 no-op;配置齐 → update 被调且 payload 含 uuid/encrypted/crypto_type
- pullAndApplyIfNeeded:远端含 sessionId + probe 通过 → 本地 cookie 被合并且 hasSession 变 true;probe 失败 → 不应用
- 4s 超时:server 挂起 → 返回 hasSession 不变
- syncNow:双向(远端新会话导入 + 本地推送)
- cookie 字段 round-trip:expirationDate epoch 秒、secure/path 缺省、sameSite 不写 "none"

- [ ] **Step 2: 实现 CookieCloudClient/CookieCloudSync**

按 Interfaces 实现;加密参数逐字 spec §3.4(`CookieCloudCrypto` 已备)。

- [ ] **Step 3: 实现 ProfileScreen + AppState 接线**

Profile 各 Section 逐字文案(spec §3.5 我的章节);CookieCloud 字段:服务器地址(OutlinedTextField)/UUID/密码(PasswordVisualTransformation)/立即同步(Button,isConfigured 才可用:enabled && server 非空 && uuid 非空 && password 非空);同步状态文本。版本行 `Text("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")`。退出登录确认后 `appState.logout()`。

- [ ] **Step 4: 本地验证 + 提交**

```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
cd apps/android && ./gradlew testDebugUnitTest assembleDebug
```
Expected: 全部通过。提交:
```bash
git commit -am "feat(android): 我的页与 CookieCloud 同步(双向探活/加密互操作)"
```

---

## Task 7: 收尾(UI 测试 CI 接线/README/发布/全量验证)

**Files:**
- Modify: `.github/workflows/ci-android.yml`(追加 ui job:模拟器 + `connectedDebugAndroidTest`)
- Modify: `.github/workflows/release.yml`(追加 android-apk producer)
- Create: `apps/android/README.md`
- Modify: `README.md`(组件表加安卓行)
- Test: `LanjingQuiz/src/androidTest/.../PracticeFlowUiTest.kt`(练习全流程 UI 测试:登录 → 练习 → 爬取进度 → 分类 → 刷题 → 退出重进恢复进度)

**Interfaces:**
- Consumes: Task 0-6 全部。

- [ ] **Step 1: ci-android.yml 追加 UI job**

```yaml
  android-ui:
    runs-on: ubuntu-latest
    needs: android
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            android:
              - 'apps/android/**'
              - '.github/workflows/ci-android.yml'
      - if: steps.filter.outputs.android == 'true'
        uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '17' }
      - if: steps.filter.outputs.android == 'true'
        uses: gradle/actions/setup-gradle@v4
        with: { gradle-version: 8.10.2 }
      - if: steps.filter.outputs.android == 'true'
        name: AVD cache
        uses: actions/cache@v4
        with:
          path: ~/.android/avd
          key: avd-pixel6-api35
      - if: steps.filter.outputs.android == 'true'
        name: Create AVD
        working-directory: apps/android
        run: |
          echo "y" | sdkmanager --licenses > /dev/null
          sdkmanager "emulator" "system-images;android-35;google_apis;x86_64"
          avdmanager create avd -n pixel6_api35 -k "system-images;android-35;google_apis;x86_64" --device "pixel_6"
      - if: steps.filter.outputs.android == 'true'
        name: Run UI tests
        working-directory: apps/android
        run: |
          $ANDROID_HOME/emulator/emulator -avd pixel6_api35 -no-window -no-audio -no-snapshot -gpu swiftshader_indirect &
          ./gradlew connectedDebugAndroidTest --no-daemon
```
(UI 测试进程内 MockWebServer,不依赖外部服务;CI 上起模拟器的标准做法照抄即可。)

- [ ] **Step 2: release.yml 追加 android-apk producer**

参照现有 `ios-unsigned` job 模式:
```yaml
  android-apk:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '17' }
      - uses: gradle/actions/setup-gradle@v4
        with: { gradle-version: 8.10.2 }
      - name: Build unsigned release APK
        working-directory: apps/android
        env:
          VERSION_NAME: ${{ needs.version.outputs.version }}
        run: |
          V=$(echo "${VERSION_NAME#v}")   # v0.1.2 -> 0.1.2
          ./gradlew assembleRelease -PversionName=$V -PversionCode=$(echo $V | awk -F. '{print $1*10000+$2*100+$3}') --no-daemon
      - uses: actions/upload-artifact@v4
        with:
          name: android-apk
          path: apps/android/LanjingQuiz/build/outputs/apk/release/*.apk
```
(注意:release.yml 的 version 输出 job 名以现有文件为准;T7 实现者先读 release.yml 再按同模式接线;`release` job 的合并 job 需把 `android-apk` 加入 needs 与下载列表——只下载 `android-apk` 目录里的 apk 改名 `LanjingQuiz-android-<version>.apk` 后随 `gh release create` 上传;参考现有 `ios-unsigned` 的改名/上传步骤。)

- [ ] **Step 3: README + 全量验证**

`apps/android/README.md`:技术栈、环境要求(ANDROID_HOME 路径、JDK 17+)、构建/测试命令、目录结构、与 iOS 的契约一致性说明(spec 链接)、测试封闭原则。
根 `README.md` 组件表追加:
```
| 原生安卓 | Kotlin/Compose 原生客户端 | `apps/android/` | Android Studio 或 Gradle 构建 | 加密 SharedPreferences |
```
并把功能对齐表加一行安卓说明(考试/练习/CookieCloud 与 iOS 对齐;UI 测试在 CI 模拟器)。

全量验证:
```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
cd apps/android && ./gradlew clean testDebugUnitTest assembleDebug assembleRelease assembleDebugAndroidTest
```
Expected: 全部成功。检查 `git status` 无 `build/`、`.gradle/`、`local.properties` 误提交。

- [ ] **Step 4: 提交**

```bash
git add -A apps/android README.md .github/workflows/ci-android.yml .github/workflows/release.yml
git commit -m "feat(android): CI UI 测试与发布产物接线 + README"
```

---


