# 主仓拆分实施计划：iOS / Android / Web 独立成仓

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 iOS / Android / Web 三个客户端拆成独立公开仓库、各自独立发版，主仓收敛为题库工具仓（`lanjing-bank` 包 + 文档）。

**Architecture:** 新仓 = 文件复制（`git archive`，不搬历史）+ 一条注明来源的初始提交；每仓自验证通过后，主仓在**同一笔提交**里删除目录与其 `release.yml` job。客户端仓库之间的唯一代码依赖（规则引擎）由主仓以 npm git 依赖（`lanjing-bank`）形式提供。

**Tech Stack:** git / gh CLI、GitHub Actions、Node 22、Xcode（`xcodebuild`）、Gradle 8.10.2 + JDK 17、Bun 1.3.14。

**Spec:** `docs/superpowers/specs/2026-09-13-repo-split-design.md`

## Global Constraints

- 三个新仓均为 **public**，仓库名：`youngestdriver/lanjing-ios`、`youngestdriver/lanjing-android`、`youngestdriver/lanjing-web`。
- 新仓**不保留原提交历史**：文件复制 + 一条初始提交，提交信息注明来源与日期。
- **不重写主仓历史**；主仓只做普通提交，任何一步可 revert 回退。
- 拆走某端的**同一笔提交**里必须同步删除主仓 `release.yml` 中该端的 job 及 `release` job 的 `needs` 引用——否则主仓推 main 的自动发布会构建已不存在的路径而变红。
- 顺序严格：**iOS → Android → 主仓做成包 → Web → 主仓收尾**（Web 依赖"主仓已是包"，不可提前）。
- 主仓 tag 只沿用 `v<major>.<minor>.<patch>` 序列（`release.yml` 的自动版本号解析依赖该格式）；**不要**引入 `bank-v*` 之类新命名空间。
- 新仓版本起点 `v1.0.0`（首次手动发版时传入）；此后沿用"最新 tag patch+1"。
- 新仓 release 触发：**先只开 `workflow_dispatch`**，手动发一次验证通过后再加 `push: main` 触发。
- 产物文件名保持 ASCII。每个 commit 以 `Co-Authored-By: Claude Code <noreply@anthropic.com>` 结尾。
- 不新增 PR 测试 CI（与现状一致，如需另开计划）；不动主仓与旧 release 的任何 tag/发布。
- 工作目录约定：主仓 `/Users/qzh/Project/lanjing_test`，新仓 `/Users/qzh/Project/lanjing-{ios,android,web}`。

---

## Phase 0：基线

### Task 0: 记录拆分前基线

**产出:** 一份"拆之前就是绿的"的记录，后续每步对照。

- [ ] **Step 1: 跑 bank 测试**

```bash
cd /Users/qzh/Project/lanjing_test/apps/bank && npm test
```

Expected: 全部通过（5 个测试文件）。

- [ ] **Step 2: 跑 web 测试**

```bash
cd /Users/qzh/Project/lanjing_test/apps/web && npm ci && npm test && npm run check
```

Expected: `node --test` 全绿；`check` 无语法错误。

- [ ] **Step 3: 跑 android 单测**

```bash
cd /Users/qzh/Project/lanjing_test/apps/android && ./gradlew testDebugUnitTest
```

Expected: BUILD SUCCESSFUL。

- [ ] **Step 4: 跑 iOS 单测**

```bash
cd /Users/qzh/Project/lanjing_test
xcodebuild -project apps/ios/LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected: `** TEST SUCCEEDED **`。若提示找不到 iPhone 17，用
`xcodebuild -project apps/ios/LanjingQuiz.xcodeproj -scheme LanjingQuiz -showdestinations`
挑一个可用模拟器名替换。`BankImportUITests` 此刻会因找不到题库包而 skip，属预期。

- [ ] **Step 5: 记录结果**

把四条结果写进本计划的执行记录（谁执行、日期、结论）；有任何红的先停下修好再开工。

---

## Phase 1：iOS 拆出

### Task 1.1: 组装 lanjing-ios 并推初始提交

**Files:**
- Create: `/Users/qzh/Project/lanjing-ios/`（由 `git archive` 展开）
- Create: `/Users/qzh/Project/lanjing-ios/.gitignore`

**产出:** 一个可构建的独立 iOS 仓（尚无 CI）。

- [ ] **Step 1: 用 git archive 展开已跟踪文件（自动排除构建产物与 xcuserdata）**

```bash
mkdir -p /Users/qzh/Project/lanjing-ios
cd /Users/qzh/Project/lanjing_test
git archive HEAD apps/ios | tar -x -C /Users/qzh/Project/lanjing-ios --strip-components=2
ls /Users/qzh/Project/lanjing-ios
```

Expected 输出含：`GlassHelpers.swift`、`LanjingQuiz`、`LanjingQuiz.xcodeproj`、`LanjingQuizTests`、`LanjingQuizUITests`、`project.yml`、`README.md`。

- [ ] **Step 2: 写 .gitignore（从主仓根 .gitignore 提取 iOS 规则 + 题库目录）**

Create `/Users/qzh/Project/lanjing-ios/.gitignore`:

```gitignore
# iOS 构建产物
build/
dist/
*.ipa
*.xcuserstate
**/xcuserdata/

# 本地题库数据（含上游 IP，不入库）
bank-data/

# OS
.DS_Store
```

- [ ] **Step 3: 初始化仓库并提交**

```bash
cd /Users/qzh/Project/lanjing-ios
git init -b main
git add -A
git commit -m "$(cat <<'EOF'
chore: 从 youngestdriver/lanjing_test 迁入 iOS 客户端（apps/ios，不含历史）

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: 建公开仓并推送**

```bash
cd /Users/qzh/Project/lanjing-ios
gh repo create youngestdriver/lanjing-ios --public --source=. --remote=origin --push
gh repo view youngestdriver/lanjing-ios --json visibility,defaultBranchRef
```

Expected: `"visibility":"PUBLIC"`，默认分支 `main`。

### Task 1.2: 修 iOS 的题库路径耦合

**Files:**
- Modify: `/Users/qzh/Project/lanjing-ios/LanjingQuizUITests/BankImportUITests.swift:4-29`

**产出:** UI 测试不再依赖主仓目录结构，改为 `LANJING_BANK_DATA` 环境变量或仓根 `bank-data/`。

- [ ] **Step 1: 替换文件头注释与 `snapshotPackageURL()`**

把 `BankImportUITests.swift` 开头注释中的

```swift
/// 题库包是本机数据(`apps/bank/data` 在 .gitignore 里,含上游 IP),不随仓库
/// 分发,所以找不到产物时跳过而不是失败;跑之前先 `cd apps/bank && npm run
/// snapshot` 生成。
```

替换为：

```swift
/// 题库包是本机数据(含上游 IP),不随仓库分发,所以找不到产物时跳过而不是
/// 失败;跑之前在主仓(`lanjing_test` 的 `apps/bank`)`npm run snapshot` 生成,
/// 再用 LANJING_BANK_DATA 指向它,或把包放进本仓根的 bank-data/。
```

把 `snapshotPackageURL()` 整个函数替换为：

```swift
    /// 题库包所在目录里最近一次 snapshot 的产物(按文件名倒序取最新一个)。
    /// 拆仓后不再依赖主仓的目录层级:优先 LANJING_BANK_DATA,其次本仓根
    /// 的 bank-data/。
    private static func snapshotPackageURL() -> URL? {
        let candidates: [URL?] = [
            ProcessInfo.processInfo.environment["LANJING_BANK_DATA"]
                .map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // LanjingQuizUITests/
                .deletingLastPathComponent()   // 仓库根
                .appendingPathComponent("bank-data"),
        ]
        for directory in candidates.compactMap({ $0 }) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            if let package = files
                .filter { $0.lastPathComponent.hasPrefix("lanjing-bank-") && $0.pathExtension == "zip" }
                .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
                .first {
                return package
            }
        }
        return nil
    }
```

同时把 `XCTSkip("没有题库包产物 —— 先跑 cd apps/bank && npm run snapshot")` 改为
`XCTSkip("没有题库包产物 —— 主仓 apps/bank 跑 npm run snapshot,再用 LANJING_BANK_DATA 指向输出目录")`。

- [ ] **Step 2: 验证"没有题库包时仍然 skip"**

```bash
cd /Users/qzh/Project/lanjing-ios
xcodebuild -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:LanjingQuizUITests/BankImportUITests test
```

Expected: 该测试被 **skipped**（不是失败）。

- [ ] **Step 3: 验证"指向题库包时真的跑起来"**

先在主仓生成一个题库包，再用环境变量指向它：

```bash
cd /Users/qzh/Project/lanjing_test/apps/bank && npm run snapshot
ls /Users/qzh/Project/lanjing_test/apps/bank/data/lanjing-bank-*.zip
cd /Users/qzh/Project/lanjing-ios
LANJING_BANK_DATA=/Users/qzh/Project/lanjing_test/apps/bank/data \
  xcodebuild -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:LanjingQuizUITests/BankImportUITests test
```

Expected: `** TEST SUCCEEDED **`，且该用例是 **passed** 而非 skipped。

- [ ] **Step 4: 全量测试**

```bash
cd /Users/qzh/Project/lanjing-ios
xcodebuild -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected: `** TEST SUCCEEDED **`。

- [ ] **Step 5: 提交**

```bash
cd /Users/qzh/Project/lanjing-ios
git add LanjingQuizUITests/BankImportUITests.swift
git commit -m "$(cat <<'EOF'
fix(ios): 题库包路径改为 LANJING_BANK_DATA / 仓根 bank-data

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push
```

### Task 1.3: iOS 仓发布 workflow（先只开手动触发）

**Files:**
- Create: `/Users/qzh/Project/lanjing-ios/.github/workflows/release-ios.yml`

**产出:** 手动可发的未签名 ipa 流水线；**不含**签名 ipa（短期不配证书）、**不含**题库包（只在主仓发布）。

- [ ] **Step 1: 写 workflow**

Create `.github/workflows/release-ios.yml`（注意：**暂不写 `push:` 触发**，Task 1.4 验证通过后再加）：

```yaml
name: Release

# 未签名 ipa 发布。题库包只在主仓 youngestdriver/lanjing_test 发布,本仓不
# 分发;签名 ipa(ADHOC)暂未接入(短期不配证书),需要时参考主仓历史的
# ios-ipa job 补回(secrets: IOS_CERT_BASE64 / IOS_CERT_PASSWORD /
# IOS_PROVISIONING_BASE64 / DEVELOPMENT_TEAM)。
#
# 手动:gh workflow run release-ios.yml -f version=v1.0.0
on:
  workflow_dispatch:
    inputs:
      version:
        description: "发布版本号,如 v1.0.0(留空自动 +1 patch)"
        required: false
        default: ""

permissions:
  contents: read

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

jobs:
  version:
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.compute.outputs.version }}
    steps:
      - name: Check out repository
        uses: actions/checkout@v5
        with:
          fetch-depth: 0
          fetch-tags: true

      - name: Compute release version
        id: compute
        run: |
          if [ -n "${{ inputs.version }}" ]; then
            echo "version=${{ inputs.version }}" >> "$GITHUB_OUTPUT"
          else
            latest=$(git tag --sort=-v:refname | head -1)
            [ -z "$latest" ] && latest="v0.0.0"
            next=$(echo "$latest" | awk -F. '{printf "v%d.%d.%d", $1+0, $2+0, $3+1}')
            echo "version=$next" >> "$GITHUB_OUTPUT"
          fi
          echo "Release version: $(grep '^version=' "$GITHUB_OUTPUT" | cut -d= -f2)"

  ios-unsigned:
    name: iOS 未签名 ipa
    needs: version
    runs-on: macos-15
    timeout-minutes: 30
    steps:
      - name: Check out repository
        uses: actions/checkout@v5

      - name: Build Release without code signing
        run: |
          xcodebuild build \
            -project LanjingQuiz.xcodeproj \
            -scheme LanjingQuiz \
            -configuration Release \
            -sdk iphoneos \
            -derivedDataPath "$RUNNER_TEMP/unsigned-dd" \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

      - name: Package unsigned ipa and install notes
        run: |
          app="$RUNNER_TEMP/unsigned-dd/Build/Products/Release-iphoneos/LanjingQuiz.app"
          if [ ! -d "$app" ]; then
            echo "::error::未找到构建产物 $app"
            exit 1
          fi
          pkg="$RUNNER_TEMP/assets"
          mkdir -p "$pkg/Payload"
          cp -R "$app" "$pkg/Payload/"
          cd "$pkg"
          zip -r -q "LanjingQuiz-unsigned-${{ needs.version.outputs.version }}.ipa" Payload
          # ASCII filename on purpose: upload/download-artifact mangles
          # non-ASCII names through the artifact backend.
          cat > "ipa-install-notes.txt" <<'EOF'
          未签名 ipa(LanjingQuiz-unsigned-*.ipa)不能直接安装。它没有签名,
          需要用免费工具 + 你自己的 Apple ID 签名后装到真机(每 7 天重新签名一次):

          1. 下载 Sideloadly(https://sideloadly.io,macOS/Windows)或 AltStore;
          2. iPhone 连接电脑并解锁;
          3. Sideloadly 中选择本 ipa,填入你的 Apple ID 和密码(仅用于签名,
             官方工具本地处理,不上传);
          4. 点击 Start;完成后到手机:设置 → 通用 → VPN 与设备管理 →
             开发者 App → 信任;
          5. 信任后即可使用;7 天后过期需重新签名。

          题库包不随本发布分发,请到主仓发布页下载:
          https://github.com/youngestdriver/lanjing_test/releases
          下载 LanjingQuiz-bank-*.zip 后,在 App 内「我的 > 题库 > 导入题库」导入。
          EOF

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: ios-unsigned
          path: "${{ runner.temp }}/assets"
          if-no-files-found: error

  release:
    name: 创建 Release
    needs: [version, ios-unsigned]
    if: ${{ !cancelled() && !contains(needs.*.result, 'failure') }}
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Download all artifacts
        uses: actions/download-artifact@v4
        with:
          path: "${{ runner.temp }}/assets"
          merge-multiple: true

      - name: Create GitHub Release with assets
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          assets=()
          for f in "${{ runner.temp }}"/assets/*; do
            [ -f "$f" ] && assets+=("$f")
          done
          if [ "${#assets[@]}" -eq 0 ]; then
            echo "::error::没有可发布的产物"
            exit 1
          fi
          gh release create "${{ needs.version.outputs.version }}" \
            "${assets[@]}" \
            --title "蓝鲸助手 iOS ${{ needs.version.outputs.version }}" \
            --generate-notes \
            --repo "${{ github.repository }}"
          echo "Release: https://github.com/${{ github.repository }}/releases/tag/${{ needs.version.outputs.version }}"
```

- [ ] **Step 2: 校验 YAML 与提交**

```bash
cd /Users/qzh/Project/lanjing-ios
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release-ios.yml')); print('YAML OK')"
git add .github/workflows/release-ios.yml
git commit -m "$(cat <<'EOF'
ci(ios): 独立发布流水线 —— 未签名 ipa（手动触发起步）

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push
```

Expected: `YAML OK`；推送后 Actions 页**不**产生运行（手动触发未开启）。

### Task 1.4: iOS 仓端到端验证 + 开自动触发

**产出:** 新仓首个 release（v1.0.0）可下载可安装；此后推 main 自动发版。

- [ ] **Step 1: 手动发首个版本**

```bash
cd /Users/qzh/Project/lanjing-ios
gh workflow run release-ios.yml -f version=v1.0.0
sleep 5 && gh run list --workflow release-ios.yml --limit 1
gh run watch $(gh run list --workflow release-ios.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

Expected: 运行成功；`gh release view v1.0.0` 能看到两个资产：
`LanjingQuiz-unsigned-v1.0.0.ipa`、`ipa-install-notes.txt`。

- [ ] **Step 2: 验证 ipa 内容**

```bash
cd /tmp && rm -rf lanjing-ipa-check && mkdir lanjing-ipa-check && cd lanjing-ipa-check
gh release download v1.0.0 -R youngestdriver/lanjing-ios -p '*.ipa'
unzip -q LanjingQuiz-unsigned-v1.0.0.ipa -d payload
ls payload/Payload/LanjingQuiz.app/LanjingQuiz && echo "ipa 结构 OK"
```

Expected: 打印 `ipa 结构 OK`。（真机安装属签名后动作，本次不验证。）

- [ ] **Step 3: 打开自动触发**

在 `.github/workflows/release-ios.yml` 的 `on:` 下、`workflow_dispatch:` 之前加入：

```yaml
  push:
    branches:
      - main
```

即 `on:` 块变为：

```yaml
on:
  push:
    branches:
      - main
  workflow_dispatch:
```

- [ ] **Step 4: 提交并确认自动发布生效**

```bash
cd /Users/qzh/Project/lanjing-ios
git add .github/workflows/release-ios.yml
git commit -m "$(cat <<'EOF'
ci(ios): 开启推 main 自动发版

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push
sleep 20 && gh run list --workflow release-ios.yml --limit 2
```

Expected: 出现一次由 push 触发的运行，版本为 `v1.0.1`；等它成功后
`gh release view v1.0.1` 资产齐全（这一步同时证明"最新 tag +1"逻辑可用）。

### Task 1.5: 主仓移除 iOS

**Files:**
- Delete: `/Users/qzh/Project/lanjing_test/apps/ios/`（整目录）
- Modify: `/Users/qzh/Project/lanjing_test/.github/workflows/release.yml`（删 `ios-unsigned`、`ios-ipa` 两个 job；`release` job 的 `needs` 去掉这两项）

**产出:** 主仓不再构建 iOS，且自动发布仍然健康。

- [ ] **Step 1: 删目录、改 workflow**

```bash
cd /Users/qzh/Project/lanjing_test
git rm -r apps/ios
```

编辑 `.github/workflows/release.yml`：

1. 删除整个 `ios-unsigned:` job 段（从 `  # Always built: unsigned Release ipa.` 注释到 `android-apk:` 之前）。
2. 删除整个 `ios-ipa:` job 段（含其上方注释）。
3. 把 `release` job 的 needs 行

```yaml
    needs: [version, web-desktop-services, web-desktop-windows, web-desktop-macos, web-desktop-linux, ios-unsigned, ios-ipa, bank-snapshot, android-apk]
```

改为：

```yaml
    needs: [version, web-desktop-services, web-desktop-windows, web-desktop-macos, web-desktop-linux, bank-snapshot, android-apk]
```

4. 文件头注释中"Artifacts"第 2、3 条（iOS 未签名 ipa / 签名 ipa）删除，"iOS signing secrets"整段删除。

- [ ] **Step 2: 校验 YAML**

```bash
cd /Users/qzh/Project/lanjing_test
python3 -c "
import yaml
d = yaml.safe_load(open('.github/workflows/release.yml'))
jobs = list(d['jobs'])
assert 'ios-unsigned' not in jobs and 'ios-ipa' not in jobs, jobs
assert all(j in jobs for j in ['version','web-desktop-services','web-desktop-windows','web-desktop-macos','web-desktop-linux','android-apk','bank-snapshot','release']), jobs
print('jobs:', jobs)
"
```

Expected: 打印 jobs 列表，其中无任何 ios job。

- [ ] **Step 3: 提交并推 PR（走仓库既有 PR 流程）**

```bash
cd /Users/qzh/Project/lanjing_test
git checkout -b chore/split-out-ios
git add -A
git commit -m "$(cat <<'EOF'
chore: iOS 客户端迁出至 youngestdriver/lanjing-ios

同笔提交删除 release.yml 的 ios-unsigned / ios-ipa job 及 needs 引用,
避免主仓自动发布构建已删除的路径。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push -u origin chore/split-out-ios
gh pr create --title "chore: iOS 客户端迁出至 lanjing-ios" --body "$(cat <<'EOF'
iOS 已拆至 https://github.com/youngestdriver/lanjing-ios（含首个 release v1.0.0）。
本仓删除 apps/ios 与 release.yml 的 iOS jobs，主仓发布改为不含 iOS。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr merge --auto --merge
```

- [ ] **Step 4: 合并后确认主仓发布健康**

```bash
cd /Users/qzh/Project/lanjing_test
gh run list --workflow release.yml --limit 1
gh run watch $(gh run list --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

Expected: main 上的自动发布运行成功；该 release 不再含 ipa 资产
（`gh release view <tag> --json assets -q '.assets[].name'` 里无 `.ipa`）。

---

## Phase 2：Android 拆出

### Task 2.1: 组装 lanjing-android 并推初始提交

**Files:**
- Create: `/Users/qzh/Project/lanjing-android/`（由 `git archive` 展开，含已有的 `.gitignore`）

**产出:** 可构建的独立 Android 仓。

- [ ] **Step 1: 展开文件**

```bash
mkdir -p /Users/qzh/Project/lanjing-android
cd /Users/qzh/Project/lanjing_test
git archive HEAD apps/android | tar -x -C /Users/qzh/Project/lanjing-android --strip-components=2
ls -a /Users/qzh/Project/lanjing-android
```

Expected 含：`.gitignore`（已自带，覆盖 `build/`、`.gradle/`、`.kotlin/` 等，无需新建）、`LanjingQuiz`、`gradle`、`gradlew`、`build.gradle.kts`、`settings.gradle.kts`、`README.md`。

- [ ] **Step 2: 初始化并提交**

```bash
cd /Users/qzh/Project/lanjing-android
git init -b main
git add -A
git commit -m "$(cat <<'EOF'
chore: 从 youngestdriver/lanjing_test 迁入 Android 客户端（apps/android，不含历史）

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: 建仓推送 + 建仓后先跑一遍测试**

```bash
cd /Users/qzh/Project/lanjing-android
gh repo create youngestdriver/lanjing-android --public --source=. --remote=origin --push
./gradlew testDebugUnitTest
```

Expected: `BUILD SUCCESSFUL`。

### Task 2.2: Android 仓发布 workflow（先只开手动触发）

**Files:**
- Create: `/Users/qzh/Project/lanjing-android/.github/workflows/release-android.yml`

- [ ] **Step 1: 写 workflow**

Create `.github/workflows/release-android.yml`（同样先只留 `workflow_dispatch`）：

```yaml
name: Release

# 未签名 release APK(debug 签名,可直接安装)。手动:
#   gh workflow run release-android.yml -f version=v1.0.0
on:
  workflow_dispatch:
    inputs:
      version:
        description: "发布版本号,如 v1.0.0(留空自动 +1 patch)"
        required: false
        default: ""

permissions:
  contents: read

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

jobs:
  version:
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.compute.outputs.version }}
    steps:
      - name: Check out repository
        uses: actions/checkout@v5
        with:
          fetch-depth: 0
          fetch-tags: true

      - name: Compute release version
        id: compute
        run: |
          if [ -n "${{ inputs.version }}" ]; then
            echo "version=${{ inputs.version }}" >> "$GITHUB_OUTPUT"
          else
            latest=$(git tag --sort=-v:refname | head -1)
            [ -z "$latest" ] && latest="v0.0.0"
            next=$(echo "$latest" | awk -F. '{printf "v%d.%d.%d", $1+0, $2+0, $3+1}')
            echo "version=$next" >> "$GITHUB_OUTPUT"
          fi
          echo "Release version: $(grep '^version=' "$GITHUB_OUTPUT" | cut -d= -f2)"

  android-apk:
    name: Android 未签名 APK
    needs: version
    runs-on: ubuntu-latest
    steps:
      - name: Check out repository
        uses: actions/checkout@v5

      - name: Set up JDK
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - name: Set up Gradle
        uses: gradle/actions/setup-gradle@v4
        with:
          gradle-version: 8.10.2

      # 版本来自 tag(去 v 前缀);versionCode 派生 = major*10000+minor*100+patch。
      # build.gradle.kts 读取 -PversionName/-PversionCode(缺省回退 1.0/1)。
      - name: Build unsigned release APK
        run: |
          ver="${{ needs.version.outputs.version }}"; ver="${ver#v}"
          ./gradlew assembleRelease -PversionName="$ver" \
            -PversionCode="$(echo "$ver" | awk -F. '{print $1*10000+$2*100+$3}')" --no-daemon

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: android-apk
          path: LanjingQuiz/build/outputs/apk/release/*.apk
          if-no-files-found: error

  release:
    name: 创建 Release
    needs: [version, android-apk]
    if: ${{ !cancelled() && !contains(needs.*.result, 'failure') }}
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Download all artifacts
        uses: actions/download-artifact@v4
        with:
          path: "${{ runner.temp }}/assets"
          merge-multiple: true

      - name: Create GitHub Release with assets
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          for f in "${{ runner.temp }}"/assets/*.apk; do
            [ -f "$f" ] || continue
            mv "$f" "${{ runner.temp }}/assets/LanjingQuiz-android-${{ needs.version.outputs.version }}.apk"
          done
          assets=()
          for f in "${{ runner.temp }}"/assets/*; do
            [ -f "$f" ] && assets+=("$f")
          done
          if [ "${#assets[@]}" -eq 0 ]; then
            echo "::error::没有可发布的产物"
            exit 1
          fi
          gh release create "${{ needs.version.outputs.version }}" \
            "${assets[@]}" \
            --title "蓝鲸助手 Android ${{ needs.version.outputs.version }}" \
            --generate-notes \
            --repo "${{ github.repository }}"
          echo "Release: https://github.com/${{ github.repository }}/releases/tag/${{ needs.version.outputs.version }}"
```

- [ ] **Step 2: 校验并提交**

```bash
cd /Users/qzh/Project/lanjing-android
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release-android.yml')); print('YAML OK')"
git add .github/workflows/release-android.yml
git commit -m "$(cat <<'EOF'
ci(android): 独立发布流水线 —— 未签名 APK（手动触发起步）

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push
```

### Task 2.3: Android 仓验证 + 开自动触发

- [ ] **Step 1: 手动发首个版本**

```bash
cd /Users/qzh/Project/lanjing-android
gh workflow run release-android.yml -f version=v1.0.0
sleep 5
gh run watch $(gh run list --workflow release-android.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh release view v1.0.0 --json assets -q '.assets[].name'
```

Expected: 资产含 `LanjingQuiz-android-v1.0.0.apk`。

- [ ] **Step 2: 验证 APK 可解析**

```bash
cd /tmp && rm -rf lanjing-apk-check && mkdir lanjing-apk-check && cd lanjing-apk-check
gh release download v1.0.0 -R youngestdriver/lanjing-android -p '*.apk'
"$ANDROID_HOME/build-tools/$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -1)/aapt2" dump badging *.apk | head -3
```

Expected: 打印 package 名 `com.qzh.lanjingquiz` 与版本号 1.0。
（若 `ANDROID_HOME` 未设置，用 `unzip -l *.apk | grep -m1 AndroidManifest` 兜底确认包完整。）

- [ ] **Step 3: 打开自动触发并提交**

在 `on:` 下加：

```yaml
  push:
    branches:
      - main
```

```bash
cd /Users/qzh/Project/lanjing-android
git add .github/workflows/release-android.yml
git commit -m "$(cat <<'EOF'
ci(android): 开启推 main 自动发版

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push
sleep 20 && gh run list --workflow release-android.yml --limit 2
```

Expected: push 触发一次运行，版本 `v1.0.1`，成功后资产齐全。

### Task 2.4: 主仓移除 Android

**Files:**
- Delete: `apps/android/`（整目录）
- Modify: `.github/workflows/release.yml`（删 `android-apk` job + `release` 的 needs 项）

- [ ] **Step 1: 删目录、改 workflow**

```bash
cd /Users/qzh/Project/lanjing_test
git rm -r apps/android
```

编辑 `.github/workflows/release.yml`：

1. 删除 `android-apk:` job 整段（含其上方注释）。
2. `release` job 的 needs 行从

```yaml
    needs: [version, web-desktop-services, web-desktop-windows, web-desktop-macos, web-desktop-linux, bank-snapshot, android-apk]
```

改为：

```yaml
    needs: [version, web-desktop-services, web-desktop-windows, web-desktop-macos, web-desktop-linux, bank-snapshot]
```

3. `release` job 里 apk 改名的循环（

```bash
          # android-apk 的 apk 改名为平台化名称(LanjingQuiz-android-<version>.apk)
          for f in "${{ runner.temp }}"/assets/*.apk; do
            [ -f "$f" ] || continue
            mv "$f" "${{ runner.temp }}"/assets/LanjingQuiz-android-${{ needs.version.outputs.version }}.apk
          done
```

整段删除。）

- [ ] **Step 2: 校验并提交 PR**

```bash
cd /Users/qzh/Project/lanjing_test
python3 -c "
import yaml
d = yaml.safe_load(open('.github/workflows/release.yml'))
jobs = list(d['jobs'])
assert 'android-apk' not in jobs, jobs
print('jobs:', jobs)
"
git checkout -b chore/split-out-android
git add -A
git commit -m "$(cat <<'EOF'
chore: Android 客户端迁出至 youngestdriver/lanjing-android

同笔提交删除 release.yml 的 android-apk job 及 needs 引用。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push -u origin chore/split-out-android
gh pr create --title "chore: Android 客户端迁出至 lanjing-android" --body "$(cat <<'EOF'
Android 已拆至 https://github.com/youngestdriver/lanjing-android（含 release v1.0.0）。
本仓删除 apps/android 与 release.yml 的 android job。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr merge --auto --merge
```

- [ ] **Step 3: 合并后确认主仓发布健康**

```bash
cd /Users/qzh/Project/lanjing_test
gh run watch $(gh run list --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

Expected: 成功；该 release 资产里无 `.apk`。

---

## Phase 3：主仓做成包 → Web 拆出

### Task 3.1: 主仓加根 package.json 并打 tag

**Files:**
- Create: `/Users/qzh/Project/lanjing_test/package.json`

**产出:** web 可依赖的 `lanjing-bank` 包（经 git 引用），带版本 tag。

- [ ] **Step 1: 写 package.json**

Create `/Users/qzh/Project/lanjing_test/package.json`：

```json
{
  "name": "lanjing-bank",
  "version": "1.0.0",
  "private": true,
  "description": "Lanjing Weike question-bank tool: collector, classifier, snapshot. Consumed by lanjing-web as a git dependency.",
  "exports": {
    ".": "./apps/bank/lib/question-bank.js",
    "./classifier": "./apps/bank/lib/question-classifier.js"
  },
  "files": [
    "apps/bank/lib"
  ],
  "engines": {
    "node": ">=22"
  }
}
```

说明：`lib/` 内的文件只依赖 node 内置模块（已核对），因此作为包被安装时零额外依赖。

- [ ] **Step 2: 提交、推送、合并**

```bash
cd /Users/qzh/Project/lanjing_test
git checkout main && git pull
git checkout -b chore/bank-package
git add package.json
git commit -m "$(cat <<'EOF'
chore: 主仓加根 package.json —— 对外提供 lanjing-bank 包（exports lib）

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push -u origin chore/bank-package
gh pr create --title "chore: 主仓提供 lanjing-bank 包" --body "$(cat <<'EOF'
供 lanjing-web 以 git 依赖方式引用规则引擎（exports 只暴露 apps/bank/lib）。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr merge --auto --merge
git checkout main && git pull
```

- [ ] **Step 3: 打 tag（用主仓下一个版本号）**

```bash
cd /Users/qzh/Project/lanjing_test
git tag --sort=-v:refname | head -1        # 当前最大,例如 v0.0.36
# 取该号 +1(例如 v0.0.37),不要引入 bank-v* 之类新命名空间:
git tag v0.0.37 && git push origin v0.0.37
```

- [ ] **Step 4: 本地验证包可被 git 依赖安装**

```bash
cd /tmp && rm -rf bank-pkg-check && mkdir bank-pkg-check && cd bank-pkg-check
npm init -y >/dev/null
TAG=$(git -C /Users/qzh/Project/lanjing_test describe --tags --abbrev=0)
npm install "github:youngestdriver/lanjing_test#$TAG" 2>&1 | tail -3
node -e "const c=require('lanjing-bank/classifier'); const q=require('lanjing-bank'); console.log('classify:', typeof c.classify, '/ bank:', typeof q)"
```

Expected: 安装成功，输出 `classify: function / bank: object`。

### Task 3.2: 组装 lanjing-web 并推初始提交

**Files:**
- Create: `/Users/qzh/Project/lanjing-web/`（web + desktop + scripts + assets 合并展开）
- Create: `/Users/qzh/Project/lanjing-web/.gitignore`
- Create: `/Users/qzh/Project/lanjing-web/README.md`

**产出:** 独立的 Web+桌面仓（路径改写前，测试尚不能全绿）。

- [ ] **Step 1: 展开四个目录（注意 --strip-components 不同）**

```bash
mkdir -p /Users/qzh/Project/lanjing-web
cd /Users/qzh/Project/lanjing_test
git archive HEAD apps/web | tar -x -C /Users/qzh/Project/lanjing-web --strip-components=2      # → 仓根
git archive HEAD apps/desktop | tar -x -C /Users/qzh/Project/lanjing-web --strip-components=1  # → desktop/
git archive HEAD scripts | tar -x -C /Users/qzh/Project/lanjing-web --strip-components=1       # → scripts/
git archive HEAD assets | tar -x -C /Users/qzh/Project/lanjing-web --strip-components=1        # → assets/
mkdir -p /Users/qzh/Project/lanjing-web/docs
git archive HEAD docs/web-api.md | tar -x -C /Users/qzh/Project/lanjing-web/docs --strip-components=1
ls /Users/qzh/Project/lanjing-web
```

Expected 含：`assets`、`desktop`、`docs`、`lib`、`public`、`scripts`、`server.js`、`test`、`tools`、`desktop-entry.js`、`package.json`、`package-lock.json`。

- [ ] **Step 2: 写 .gitignore**

Create `/Users/qzh/Project/lanjing-web/.gitignore`：

```gitignore
# Session & credentials
session_cookies.txt
.local/

# Saved exam data
*_2026-*/
public/index.backup.html

# 桌面构建生成的静态资源包
public-bundle.js

# Server certs
.cert/

# Dependencies
node_modules/

# OS
Thumbs.db
.DS_Store
```

- [ ] **Step 3: 写 README.md**

Create `/Users/qzh/Project/lanjing-web/README.md`：以主仓根 README 的 Web 部分（「项目组成」表中 Web 行、三端网络路径图、Web 相关功能表、「本地验证」里的 web 命令）为素材重写，至少包含：

```markdown
# 蓝鲸答题助手 — Web / PWA 与桌面版

浏览器客户端与本地 Express 代理（`server.js`），同一份代码打包为 Windows / macOS / Linux 桌面版
（托盘单文件，内嵌 Bun 编译的服务二进制）。

- 启动：`npm ci && npm start`（默认 http://127.0.0.1:3000）
- 测试：`npm test`；语法检查：`npm run check`
- 规则引擎（题型分类）来自主仓 youngestdriver/lanjing_test 的 `lanjing-bank` 包，
  以 git 依赖固定在 `package.json` 里
- 发布：推 main 自动发版（见 `.github/workflows/release.yml`），产物为
  Windows 托盘单文件 ×2 / macOS .app+dmg / Linux 单文件 ×2
- 题库包不在本仓发布，见主仓发布页
```

（可再摘录主仓 README 中 Web 的功能说明补全，不必逐字。）

- [ ] **Step 4: 初始化并提交（先不建仓，Task 3.3 改完路径跑绿后再推）**

```bash
cd /Users/qzh/Project/lanjing-web
git init -b main
git add -A
git commit -m "$(cat <<'EOF'
chore: 从 youngestdriver/lanjing_test 迁入 Web 客户端与桌面壳（不含历史）

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

### Task 3.3: Web 仓路径改写（8 处）+ 依赖改包引用 + 测试全绿

**Files:**
- Modify: `/Users/qzh/Project/lanjing-web/server.js:28`
- Modify: `/Users/qzh/Project/lanjing-web/lib/practice-crawl.js:21-22`
- Modify: `/Users/qzh/Project/lanjing-web/test/desktop-icons.test.js:7-8`
- Modify: `/Users/qzh/Project/lanjing-web/test/public-bundle.test.js:19-20`
- Modify: `/Users/qzh/Project/lanjing-web/package.json`（check 脚本两处路径 + 依赖）
- Modify: `/Users/qzh/Project/lanjing-web/scripts/build-public-bundle.js:18`
- Modify: `/Users/qzh/Project/lanjing-web/scripts/assemble-macos-app.sh:41,43,49,50,51,66`

**产出:** 独立可跑、测试全绿的 web 仓。

- [ ] **Step 1: 逐处改写（精确替换）**

1. `server.js:28`：

```js
const BANK_DIR = path.resolve(process.env.LANJING_BANK_DIR || path.join(LOCAL_DIR, "bank-data"));
```

（注释同步说明：题库目录默认在本地 `.local/bank-data`，用 `LANJING_BANK_DIR` 覆盖。）

2. `lib/practice-crawl.js:21-22`：

```js
const bank = require("lanjing-bank");
const classifier = require("lanjing-bank/classifier");
```

（同时把上方注释 "Pure-function reuse from apps/bank keeps one shared rule engine." 改为 "Pure-function reuse from the lanjing-bank package keeps one shared rule engine."）

3. `test/desktop-icons.test.js:7-8`：

```js
// __dirname is test/; the repo root (with assets/) is 2 levels up.
const assetsDir = path.resolve(__dirname, "..", "..", "assets", "desktop");
```

4. `test/public-bundle.test.js:19-20`：

```js
const repoRoot = path.resolve(__dirname, "..");
const webDir = path.resolve(__dirname, "..");
```

5. `package.json` 的 `check` 脚本里两处：

   `node --check ../../scripts/assemble-ico.js` → `node --check scripts/assemble-ico.js`
   `node --check ../../scripts/build-public-bundle.js` → `node --check scripts/build-public-bundle.js`

6. `scripts/build-public-bundle.js:18`：

```js
const webDir = path.resolve(__dirname, "..");
```

（注释中 `apps/web/public-bundle.js` 改为 `public-bundle.js`。）

7. `scripts/assemble-macos-app.sh` 中四处 `$ROOT/apps/desktop/` → `$ROOT/desktop/`、
   两处 `$ROOT/assets/desktop/` 保持不变（assets 仍在仓根）。精确替换：

   `"$ROOT/apps/desktop/macos/main.swift"` → `"$ROOT/desktop/macos/main.swift"`（两行）
   `"$ROOT/apps/desktop/macos/Info.plist"` → `"$ROOT/desktop/macos/Info.plist"`（两行）

- [ ] **Step 2: 加依赖并安装**

```bash
cd /Users/qzh/Project/lanjing-web
TAG=$(git -C /Users/qzh/Project/lanjing_test describe --tags --abbrev=0)
echo "使用 tag: $TAG"
npm install "github:youngestdriver/lanjing_test#$TAG"
```

确认 `package.json` 的 `dependencies` 增加了以
`"lanjing-bank": "github:youngestdriver/lanjing_test#` 开头的一行（值即上一步打印的 tag），
且 `package-lock.json` 同步更新。

- [ ] **Step 3: 跑测试**

```bash
cd /Users/qzh/Project/lanjing-web
npm test && npm run check
```

Expected: 全绿。若有失败，逐条对照 Step 1 的替换清单排查遗漏的路径。

- [ ] **Step 4: 冒烟起服务**

```bash
cd /Users/qzh/Project/lanjing-web
LANJING_LOCAL_DIR=/tmp/lanjing-web-smoke PORT=4401 node server.js > /tmp/lanjing-web-smoke.log 2>&1 &
sleep 1
curl -fsS http://127.0.0.1:4401/api/status | head -c 200; echo
kill %1 2>/dev/null || true
```

Expected: 输出含 `"loggedIn":false`。

- [ ] **Step 5: 建仓推送**

```bash
cd /Users/qzh/Project/lanjing-web
git add -A
git commit -m "$(cat <<'EOF'
chore(web): 拆仓路径改写 —— 规则引擎改 lanjing-bank 包、题库目录本地化

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
gh repo create youngestdriver/lanjing-web --public --source=. --remote=origin --push
```

### Task 3.4: Web 仓发布 workflow（先只开手动触发）

**Files:**
- Create: `/Users/qzh/Project/lanjing-web/.github/workflows/release.yml`

**产出:** 桌面三平台产物的独立发布流水线。

- [ ] **Step 1: 从主仓复制 workflow 作为底稿**

```bash
cd /Users/qzh/Project/lanjing-web
mkdir -p .github/workflows
git -C /Users/qzh/Project/lanjing_test show main:.github/workflows/release.yml > .github/workflows/release.yml
```

- [ ] **Step 2: 应用改写**

对复制来的文件做以下修改（保留的 job：`version`、`web-desktop-services`、
`web-desktop-windows`、`web-desktop-macos`、`web-desktop-linux`、`release`；删除
`ios-unsigned`、`ios-ipa`、`android-apk` 三个 job 段）：

1. `on:` 块改为**只留** `workflow_dispatch`（Task 3.5 验证后再加 `push: main`）。
2. `web-desktop-services` job：

   `run: npm ci --prefix apps/web` → `run: npm ci`

   `run: node scripts/build-public-bundle.js` → 不变

   `cd apps/web` → 删除该行（bun 构建在仓根执行），即

   ```yaml
        - name: Compile server binaries (all targets)
          run: |
            out="$RUNNER_TEMP/servers"
            mkdir -p "$out"
            for target in bun-windows-x64 bun-windows-arm64 bun-darwin-arm64 bun-darwin-x64 bun-linux-x64 bun-linux-arm64; do
              bun build --compile --target="$target" ./desktop-entry.js --outfile "$out/$target"
            done
            mv "$out/bun-windows-x64.exe" "$out/LanjingQuiz-server.exe"
            mv "$out/bun-windows-arm64.exe" "$out/LanjingQuiz-server-arm64.exe"
            mv "$out/bun-darwin-arm64" "$out/server-darwin-arm64"
            mv "$out/bun-darwin-x64" "$out/server-darwin-x64"
            mv "$out/bun-linux-x64" "$out/LanjingQuiz-linux-x64"
            mv "$out/bun-linux-arm64" "$out/LanjingQuiz-linux-arm64"
            ls -lh "$out"
   ```

3. `web-desktop-windows` job：

   `cp assets/desktop/icon.ico apps/desktop/windows/app.ico` → `cp assets/desktop/icon.ico desktop/windows/app.ico`

   `mkdir -p apps/desktop/windows/artifacts` → `mkdir -p desktop/windows/artifacts`

   `cp "$RUNNER_TEMP/servers/..." apps/desktop/windows/artifacts/` → `... desktop/windows/artifacts/`（两行）

   `cd apps/desktop/windows` → `cd desktop/windows`（三处：两个 publish 步骤 + Smoke test 步骤）

   `cp apps/desktop/windows/out/win-x64/LanjingQuiz.exe "$RUNNER_TEMP/deliver/..."` →
   `cp desktop/windows/out/win-x64/LanjingQuiz.exe ...`（同样改 arm64 一行）

4. `web-desktop-macos` job：`bash scripts/assemble-macos-app.sh` 不变；其余无 `apps/` 引用。

5. `release` job：删除 apk 改名循环与题库包改名段（题库包只在主仓发布），保留
   `rm -f ... LanjingQuiz-server.exe` 等中间产物清理；`needs` 改为
   `[version, web-desktop-services, web-desktop-windows, web-desktop-macos, web-desktop-linux]`；
   release 标题改为 `蓝鲸助手桌面版 ${{ needs.version.outputs.version }}`。

6. 文件头注释重写为：

```yaml
# 桌面版发布:推 main 自动(启用后)+ 手动。产物:
#   1. Windows 托盘单文件 x64/arm64(内嵌 Bun 编译的服务二进制)
#   2. macOS .app + dmg(Universal,Swift 状态栏)
#   3. Linux 单文件 x64/arm64
# 手动:gh workflow run release.yml -f version=v1.0.0
```

- [ ] **Step 3: 校验 YAML 并核对无残留**

```bash
cd /Users/qzh/Project/lanjing-web
python3 -c "
import yaml
d = yaml.safe_load(open('.github/workflows/release.yml'))
jobs = list(d['jobs'])
assert jobs == ['version','web-desktop-services','web-desktop-windows','web-desktop-macos','web-desktop-linux','release'], jobs
print('jobs:', jobs)
"
grep -n 'apps/' .github/workflows/release.yml || echo "无 apps/ 残留"
sort .github/workflows/release.yml | uniq -d | grep -v '^\s*$' || true
```

Expected: jobs 列表匹配；`无 apps/ 残留`。

- [ ] **Step 4: 提交**

```bash
cd /Users/qzh/Project/lanjing-web
git add .github/workflows/release.yml
git commit -m "$(cat <<'EOF'
ci(web): 独立发布流水线 —— 桌面三平台产物（手动触发起步）

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push
```

### Task 3.5: Web 仓验证 + 开自动触发

- [ ] **Step 1: 手动发首个版本**

```bash
cd /Users/qzh/Project/lanjing-web
gh workflow run release.yml -f version=v1.0.0
sleep 5
gh run watch $(gh run list --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh release view v1.0.0 --json assets -q '.assets[].name'
```

Expected: 运行成功，资产为
`LanjingQuiz-windows-x64.exe`、`LanjingQuiz-windows-arm64.exe`、`LanjingQuiz-macOS.dmg`、
`LanjingQuiz-linux-x64`、`LanjingQuiz-linux-arm64`。

- [ ] **Step 2: 本机冒烟下载版**

```bash
cd /tmp && rm -rf lanjing-web-check && mkdir lanjing-web-check && cd lanjing-web-check
gh release download v1.0.0 -R youngestdriver/lanjing-web -p 'LanjingQuiz-linux-*' 2>/dev/null || true
gh release download v1.0.0 -R youngestdriver/lanjing-web -p 'LanjingQuiz-macOS.dmg'
hdiutil verify LanjingQuiz-macOS.dmg
```

Expected: `hdiutil verify` 通过（dmg 结构完整）。

- [ ] **Step 3: 打开自动触发并提交**

`on:` 块加入：

```yaml
  push:
    branches:
      - main
```

```bash
cd /Users/qzh/Project/lanjing-web
git add .github/workflows/release.yml
git commit -m "$(cat <<'EOF'
ci(web): 开启推 main 自动发版

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push
sleep 20 && gh run list --workflow release.yml --limit 2
```

Expected: push 触发一次运行（版本 `v1.0.1`），成功后资产齐全。

### Task 3.6: 主仓移除 Web / 桌面壳 / 资源

**Files:**
- Delete: `apps/web/`、`apps/desktop/`、`scripts/`、`assets/`、`docs/web-api.md`
- Modify: `.github/workflows/release.yml`（删 `web-desktop-*` 四个 job + `release` needs 与残留引用）

- [ ] **Step 1: 删目录、改 workflow**

```bash
cd /Users/qzh/Project/lanjing_test
git rm -r apps/web apps/desktop scripts assets docs/web-api.md
```

编辑 `.github/workflows/release.yml`：删除 `web-desktop-services`、`web-desktop-windows`、
`web-desktop-macos`、`web-desktop-linux` 四个 job 段；`release` job 的 `needs` 改为
`[version, bank-snapshot]`；删除 `release` job 里清理服务二进制的 `rm -f` 段；文件头注释
只保留题库包一节。

- [ ] **Step 2: 校验 YAML**

```bash
cd /Users/qzh/Project/lanjing_test
python3 -c "
import yaml
d = yaml.safe_load(open('.github/workflows/release.yml'))
jobs = list(d['jobs'])
assert jobs == ['version','bank-snapshot','release'], jobs
print('jobs:', jobs)
"
```

Expected: `jobs: ['version', 'bank-snapshot', 'release']`。

- [ ] **Step 3: 提交 PR**

```bash
cd /Users/qzh/Project/lanjing_test
git checkout -b chore/split-out-web
git add -A
git commit -m "$(cat <<'EOF'
chore: Web 与桌面壳迁出至 youngestdriver/lanjing-web

同笔提交删除 release.yml 的四个桌面 job 及 needs 引用,主仓只剩题库包发布。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push -u origin chore/split-out-web
gh pr create --title "chore: Web 与桌面壳迁出至 lanjing-web" --body "$(cat <<'EOF'
Web+桌面壳已拆至 https://github.com/youngestdriver/lanjing-web。
主仓 `release.yml` 只剩 version / bank-snapshot / release。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr merge --auto --merge
```

- [ ] **Step 4: 确认主仓发布健康**

```bash
cd /Users/qzh/Project/lanjing_test
gh run watch $(gh run list --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh release view $(git tag --sort=-v:refname | head -1) --json assets -q '.assets[].name'
```

Expected: 成功；资产只剩 `LanjingQuiz-bank-<version>.zip`。

---

## Phase 4：主仓收尾

### Task 4.1: bank 挪到根并更新包路径

**Files:**
- Move: `apps/bank/*` → 仓根（`lib/`、`scripts/`、`test/`、`data/`、`package.json`→移除，README 合并）
- Modify: `package.json`（exports/files 路径去 `apps/bank/` 前缀）
- Modify: `.github/workflows/release.yml`（`apps/bank/...` → 新路径）

**产出:** 主仓根即题库工具（`lib/ scripts/ test/ data/`）。

- [ ] **Step 1: 挪目录**

```bash
cd /Users/qzh/Project/lanjing_test
git mv apps/bank/lib lib
git mv apps/bank/scripts scripts
git mv apps/bank/test test
git mv apps/bank/data data            # 目录本身不入库,git 会报错则跳过
git mv apps/bank/README.md BANK-README.md
git mv apps/bank/package.json bank-package.json   # 暂存,其 scripts 合并进新根 package.json
git rm apps/bank/.DS_Store 2>/dev/null || true
```

若 `git mv apps/bank/data` 报 `not under version control`，说明它未被跟踪（预期），跳过即可。

- [ ] **Step 2: 合并 package.json**

把根 `package.json` 改成（把 `bank-package.json` 的 `scripts` 原样并入，`exports`/`files`
路径去掉前缀），然后删除 `bank-package.json`：

```json
{
  "name": "lanjing-bank",
  "version": "1.1.0",
  "private": true,
  "description": "Lanjing Weike question-bank tool: collector, classifier, snapshot, export. Consumed by lanjing-web as a git dependency.",
  "exports": {
    ".": "./lib/question-bank.js",
    "./classifier": "./lib/question-classifier.js"
  },
  "files": [
    "lib"
  ],
  "scripts": {
    "collect": "node scripts/collect-bank.js",
    "classify": "node scripts/classify-bank.js",
    "export": "node scripts/export-bank.js",
    "snapshot": "node scripts/snapshot-bank.js",
    "test": "node --test test/*.test.js",
    "check": "node --check lib/question-bank.js && node --check lib/question-classifier.js && node --check lib/bank-export.js && node --check lib/snapshot.js && node --check lib/parsers.js && node --check lib/upstream.js && node --check scripts/collect-bank.js && node --check scripts/classify-bank.js && node --check scripts/export-bank.js && node --check scripts/snapshot-bank.js && node --check test/question-bank.test.js && node --check test/question-classifier.test.js && node --check test/export-bank.test.js && node --check test/snapshot-bank.test.js && node --check test/upstream.test.js"
  },
  "engines": {
    "node": ">=22"
  },
  "dependencies": {}
}
```

- [ ] **Step 3: 更新 release.yml 里的 bank 路径**

`.github/workflows/release.yml` 中所有 `apps/bank/` 前缀去掉，精确替换共 3 处：

1. `-d apps/bank/data` → `-d data`
2. `node apps/bank/scripts/snapshot-bank.js --out` → `node scripts/snapshot-bank.js --out`
3. `node apps/bank/scripts/snapshot-bank.js --verify` → `node scripts/snapshot-bank.js --verify`

以及注释里的 `apps/bank/data` 描述改为 `data/`。

- [ ] **Step 4: 跑测试**

```bash
cd /Users/qzh/Project/lanjing_test
npm test && npm run check
```

Expected: 全绿（脚本内 `__dirname/../data` 的引用在挪动后仍指向根 `data/`，已核对）。

- [ ] **Step 5: 提交 PR**

```bash
cd /Users/qzh/Project/lanjing_test
git checkout -b chore/bank-to-root
git add -A
git commit -m "$(cat <<'EOF'
chore: 题库工具挪到仓根,主仓收敛为 lanjing-bank 包

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push -u origin chore/bank-to-root
gh pr create --title "chore: 题库工具挪到仓根" --body "$(cat <<'EOF'
主仓只剩题库工具：lib/ scripts/ test/ data/(gitignore) + docs。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr merge --auto --merge
```

### Task 4.2: 主仓 README 重写 + workflow 更名

**Files:**
- Modify: `README.md`（重写为题库工具说明）
- Rename: `.github/workflows/release.yml` → `.github/workflows/release-bank.yml`

- [ ] **Step 1: 重写 README.md**

内容至少包含：项目定位（题库工具：采集 / 分类 / 快照 / 导出）、三个客户端仓库的链接
（lanjing-ios / lanjing-android / lanjing-web，注明客户端代码已迁出、本仓不再包含）、
常用命令（`npm run collect|classify|export|snapshot|test`）、题库数据不入库的说明
（上游 IP）、题库包发布流程（三级来源解析 + 校验）、`lanjing-bank` 包被 web 以 git
依赖引用的说明（含"改规则引擎后：主仓打 tag → web bump 依赖 → iOS/Android 各移植一次"
的跨仓同步约定）。删除已迁出的 Web/iOS/Android 功能与架构描述。

- [ ] **Step 2: workflow 更名**

```bash
cd /Users/qzh/Project/lanjing_test
git mv .github/workflows/release.yml .github/workflows/release-bank.yml
```

并把文件内 `name: Release` 改为 `name: Release Bank`（避免与各客户端仓的 Release 混淆）。

- [ ] **Step 3: 提交 PR**

```bash
cd /Users/qzh/Project/lanjing_test
git checkout -b chore/finalize-bank-repo
git add -A
git commit -m "$(cat <<'EOF'
docs: 主仓 README 重写为题库工具说明,release workflow 更名 release-bank

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push -u origin chore/finalize-bank-repo
gh pr create --title "docs: 主仓收尾（README + workflow 更名）" --body "$(cat <<'EOF'
主仓最终形态：题库工具 + release-bank 流水线。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr merge --auto --merge
```

### Task 4.3: 最终验证

- [ ] **Step 1: 主仓发布一次题库包并核对**

```bash
cd /Users/qzh/Project/lanjing_test
gh workflow run release-bank.yml
sleep 5
gh run watch $(gh run list --workflow release-bank.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh release view $(git tag --sort=-v:refname | head -1) --json assets -q '.assets[].name'
```

Expected: 资产只有 `LanjingQuiz-bank-<version>.zip`。

- [ ] **Step 2: 确认 web 依赖新 tag（可选，推荐）**

`apps/bank` 挪根后包内路径变化，仅影响新 tag 的包；web 现锁在旧 tag 仍可正常构建。
Task 4.1 合并后给主仓打一个新 tag（沿用 `v0.0.x` 序列），再把 web 依赖指过去并验证：

```bash
cd /Users/qzh/Project/lanjing_test
git tag v0.0.38 && git push origin v0.0.38    # 号以当前最大 tag +1 为准
cd /Users/qzh/Project/lanjing-web
TAG=$(git -C /Users/qzh/Project/lanjing_test describe --tags --abbrev=0)
npm install "github:youngestdriver/lanjing_test#$TAG"
npm test && npm run check
git add package.json package-lock.json
git commit -m "$(cat <<'EOF'
chore(web): lanjing-bank 依赖升级到挪根后的新版本

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push
```

- [ ] **Step 3: 四处收尾清单**

- 主仓：`git ls-files | awk -F/ '{print $1}' | sort -u` 只剩 `docs`、`lib`、`scripts`、`test`、`package.json`、`README.md`、`.github`、`.gitignore`。
- 三客户端仓：各自 `gh run list --limit 1` 最近一次自动发布为绿色。
- 主仓与三客户端仓的旧 tag/release 均未被删除（`gh release list -R <repo> | wc -l` 与拆分前一致）。
- 本计划的四个 Phase 在 PR 里均可追溯到对应的 revert 提交点。

---

## 自检记录（写计划时已核对）

- **Spec 覆盖**：四仓拓扑（Phase 1/2/3）、不保留历史（各 Task \*.1 Step 1）、规则引擎成包（Task 3.1/3.3）、题库目录本地化（Task 3.3 Step 1.1）、题库包只在主仓（Task 1.3/3.4）、iOS 测试路径（Task 1.2）、杂物归属（Task 3.2/3.6）、发布流水线（各 Phase）、顺序与回退（Global Constraints + 各 Phase）。
- **路径细节已核实**：`desktop-icons.test.js`、`public-bundle.test.js`、`build-public-bundle.js`、`assemble-macos-app.sh`、`package.json check` 的实际引用行号与内容；bank lib 仅依赖 node 内置模块；android 自带 `.gitignore`。
- **风险点**：主仓 `release.yml` 的 job 删除必须与目录删除同笔提交；新仓首个 workflow 先只开手动触发，避免初始提交触发意外发版。
