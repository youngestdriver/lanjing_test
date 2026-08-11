# 练习模块改造(考试式底栏/滑动切题/进度持久化/入口 x/xx)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 练习模块 4 项改造:① 底部一栏复用考试 StatsBarView 设计(去掉交卷),② 像考试一样左右滑动切换题目,③ 练习进度持久化(随机顺序下也能恢复),④ 做过的题型入口显示 "x/xx" 做题进度。

**Architecture:** 数据层零破坏性改动 —— ①会话恢复规则从"题目 ID 顺序一致"放宽为"题目 ID 集合一致"(一行条件改动,随机顺序恢复即生效);②新增 `practice-progress.json` 进度注册表(`[category/subCategory: answeredIDs]`),与现有 `practice-session.json` 并存,按题型细分累计已答题目 ID,入口行据此渲染 x/xx;③UI 层把 PracticeQuizView 改造成考试式 `VStack(header → TabView(.page) → 底栏)` 布局,底栏为新建的 PracticeStatsBarView(镜像 StatsBarView 设计,无交卷)。

**Tech Stack:** SwiftUI(iOS 17+,Swift 6 严格并发,XcodeGen 生成工程),XCTest 单元测试 + XCUITest UI 测试。设计令牌 DS.accent/DS.red/DS.radiusSM、KeycapButtonStyle,见 `Support/DesignSystem.swift`。

## Global Constraints

- 代码库语言:文件注释/UI 文案用中文,标识符/注释内单词用英文;accessibility identifier 用 kebab-case 英文(`practice-answer-card-grid` 风格)
- 设计令牌只用 DS.* 与系统色(Color(.systemGray5 / .secondarySystemBackground)),不复刻新颜色
- iOS 17 已知 bug:隐藏 tab bar 后 sheet 呈现静默失败 → 答题卡保持 overlay 呈现,不得改回 sheet
- 容器视图(如 ZStack)不得加 accessibilityIdentifier —— SwiftUI 会把容器 identifier 传播覆盖到所有后代(PracticeAnswerCardView.swift:38-41 注释)
- 新增 Swift 文件后必须 `cd apps/ios && xcodegen generate`(project.yml 用目录源,regenerate 自动纳入)
- 随机顺序种子每次进入随机生成(不改);`practice-session.json` 格式**不变**(answers 保持按索引对齐的数组)
- 单元测试隔离:VM 测试用 Fake 存储 actor(不得触真实文件);UserDefaults 用 `UserDefaults(suiteName: UUID())` 隔离
- 每任务 TDD:先写失败测试 → 跑通失败 → 最小实现 → 跑通 → commit;提交信息中文,如 `feat: 练习随机顺序恢复进度`
- PR 流程:实现完成后开 PR,`gh pr merge <n> --auto --merge`(仓库已开 allow_auto_merge/delete_branch_on_merge,见记忆)

---

### Task 1: 随机顺序下会话恢复(需求 3 核心)

**Files:**
- Modify: `apps/ios/LanjingQuiz/Support/BankLogic.swift:41-52`
- Test: `apps/ios/LanjingQuizTests/PracticeSessionTests.swift:146-151`
- Test: `apps/ios/LanjingQuizTests/PracticeBankViewModelTests.swift:280-301`

**Interfaces:**
- Consumes: `PracticeSession`(不变:`category/subCategory/questions/index/answers` 索引对齐)
- Produces: `BankLogic.resumeCandidate(saved:category:subCategory:ordered:)` 语义变化 —— 顺序相等 → ID 集合相等;签名不变

**背景:** 当前 `resumeCandidate` 要求存档题目 ID 顺序与当前题库顺序**完全一致**(BankLogic.swift:46-52)。随机顺序开启时每次进入种子随机(BankLogic 无种子改,`PracticeBankViewModel.resumeOrStart` 139 行 `UInt64.random`),顺序必不一致 → 存档永远无法恢复,`resumeOrStart` 直接新建并覆盖(150 行)。需求 3 要求随机顺序下也要记录/恢复进度。存档本身已包含完整题目列表与答案,恢复时直接用存档自身顺序即可,无需与当前顺序比对。

- [ ] **Step 1: 改写失败测试(顺序不同 → 恢复)**

把 `PracticeSessionTests.swift:146-151` 的 `testResumeCandidateRejectsDifferentIdOrder` 替换为:

```swift
func testResumeCandidateMatchesDifferentIdOrder() {
    let saved = makeSession()
    // 随机顺序(洗牌)只改变顺序、不改变 ID 集合 → 必须恢复存档(需求 3)。
    let shuffled = [makeQuestion("q2"), makeQuestion("q1"), makeQuestion("q3")]
    XCTAssertEqual(
        BankLogic.resumeCandidate(saved: saved, category: "言语理解", subCategory: "成语辨析", ordered: shuffled),
        saved
    )
}

func testResumeCandidateRejectsDifferentIdSet() {
    let saved = makeSession()
    // 题库更新后 ID 集合变化(增/删题)→ 存档失效,全新开始。
    let changedBank = [makeQuestion("q1"), makeQuestion("q2"), makeQuestion("q4")]
    XCTAssertNil(BankLogic.resumeCandidate(saved: saved, category: "言语理解", subCategory: "成语辨析", ordered: changedBank))
}
```

再把 `PracticeBankViewModelTests.swift:280-301` 的 `testResumeOrStartFreshOnDifferentIdOrder` 替换为:

```swift
func testResumeOrStartResumesOnDifferentIdOrder() async throws {
    let storage = FakeBankStorage()
    storage.categoryTexts = categoryTexts()
    let store = FakePracticeSessionStore()
    let original = orderedQuestions
    // 存档顺序与当前题库顺序不同(模拟随机顺序)但 ID 集合一致 → 必须恢复,
    // 且不再重新洗牌(存档自带其顺序)与不重复持久化(需求 3)。
    var saved = PracticeSession(category: "言语理解", subCategory: "成语辨析",
                                questions: [original[1], original[0], original[2]])
    saved.answers[0] = PracticeSession.PracticeAnswer(selected: ["B"], revealed: true, correct: false)
    saved.index = 1
    try await store.save(saved)

    let vm = makeVM(storage: storage, sessionStore: store)
    let resumed = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
    XCTAssertTrue(resumed)
    XCTAssertTrue(vm.resumedFromDisk)
    XCTAssertEqual(vm.session, saved)
    XCTAssertEqual(vm.session?.answers[0].correct, false)
    let saveCount = await store.saveCount
    XCTAssertEqual(saveCount, 1) // 恢复不重复持久化
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd apps/ios && xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:LanjingQuizTests/PracticeSessionTests \
  -only-testing:LanjingQuizTests/PracticeBankViewModelTests 2>&1 | tail -20
```

Expected: FAIL(`resumeCandidate` 对洗牌顺序仍返回 nil)。

- [ ] **Step 3: 最小实现**

`BankLogic.swift:41-52` 的文档注释与实现改为(顺序比对 → ID 集合比对):

```swift
    /// Whether a saved session may resume: same category/subCategory, not
    /// finished, and its question-ID SET identical to the current bank's
    /// `ordered` list. Order no longer matters — a saved run carries its own
    /// (possibly shuffled) order, so re-entering with 随机顺序 on resumes
    /// progress instead of starting fresh (需求 3). Only a real bank change
    /// (IDs added/removed) or a finished run forces a fresh start.
    static func resumeCandidate(saved: PracticeSession?, category: String, subCategory: String,
                                ordered: [BankQuestion]) -> PracticeSession? {
        guard let saved, saved.category == category, saved.subCategory == subCategory,
              !saved.isFinished,
              Set(saved.questions.map(\.id)) == Set(ordered.map(\.id)) else { return nil }
        return saved
    }
```

- [ ] **Step 4: 跑测试确认通过**

同 Step 2 命令。Expected: PASS。

- [ ] **Step 5: 更新过时注释并提交**

`PracticeBankViewModel.swift:125-130` 的 resumeOrStart 文档注释里 "resumes — and is NOT reshuffled (the archive already contains the shuffled order)" 依然正确,无需改;`crawlIfNeeded(force:)` 93-97 行注释提到"问题 ID 顺序比对"改为"问题 ID 集合比对"(仅注释):

```swift
                // 题库内容可能已变化:按恢复规则(问题 ID 集合比对)旧存档
                // 不可能再匹配,清掉避免残留;失败(refresh 模式)不清,
                // 旧库保留,存档依然有效。
```

```bash
git add apps/ios/LanjingQuiz/Support/BankLogic.swift apps/ios/LanjingQuiz/ViewModels/PracticeBankViewModel.swift \
  apps/ios/LanjingQuizTests/PracticeSessionTests.swift apps/ios/LanjingQuizTests/PracticeBankViewModelTests.swift
git commit -m "fix: 练习随机顺序下也能恢复进度(恢复规则改为题目 ID 集合比对)"
```

---

### Task 2: 练习进度注册表 PracticeProgressStore(需求 3 持久化 + 需求 4 数据源)

**Files:**
- Create: `apps/ios/LanjingQuiz/Support/PracticeProgressStore.swift`
- Create: `apps/ios/LanjingQuizTests/PracticeProgressStoreTests.swift`
- Modify: `apps/ios/LanjingQuiz/App/AppState.swift`(新增 store、deleteBank/-reset-bank 清除)
- Modify: `apps/ios/LanjingQuiz/ViewModels/PracticeBankViewModel.swift`(注入、加载、记录、清除、查询)
- Modify: `apps/ios/LanjingQuizTests/PracticeBankViewModelTests.swift`(makeVM 注入 FakeProgressStore + 新测试)

**Interfaces:**
- Consumes: `AppState.practiceSessionStore` 模式、`BankQuestion.id`(稳定上游 _id)
- Produces:
  - `protocol PracticeProgressStoring: Sendable { func load() async -> [String: PracticeProgress]?; func save(_: [String: PracticeProgress]) async throws; func clear() async throws }`
  - `struct PracticeProgress: Codable, Equatable, Sendable { var answeredIDs: [String] = [] }`
  - `actor FileManagerPracticeProgressStore: PracticeProgressStoring`(文件 `LanjingQuiz/practice-progress.json`)
  - `AppState.practiceProgressStore: FileManagerPracticeProgressStore`(init 默认参数)
  - VM:`func answeredCount(category: String, subCategory: String) -> Int`、`func answeredCount(category: String) -> Int`
  - 注册表键:`"\(category)/\(subCategory)"`;大类聚合 = 键前缀 `"\(category)/"` 求和

**设计说明:** 每个题型细分累计"已揭晓答案"的题目 ID(单选 tap、无答案 reveal、多选 confirm 三种 reveal 路径都记;多选未提交的选中不算)。完成一次练习不清注册表 —— 它是跨会话的做题进度(x/xx 数据源)。题库删除/强制重爬/-reset-bank 时清空(旧 ID 无意义)。

- [ ] **Step 1: 新 store + 单元测试**

创建 `Support/PracticeProgressStore.swift`:

```swift
import Foundation

/// Injectable persistence seam for per-subcategory practice progress
/// (mirrors PracticeSessionStoring).
protocol PracticeProgressStoring: Sendable {
    /// nil = 无存档(从未做过任何题或已清除)。
    func load() async -> [String: PracticeProgress]?
    func save(_ progress: [String: PracticeProgress]) async throws
    func clear() async throws
}

/// Answered-progress for one 题型细分. Keyed in the registry file by
/// "\(category)/\(subCategory)" — the category aggregate sums the prefix.
struct PracticeProgress: Codable, Equatable, Sendable {
    var answeredIDs: [String] = [] // 已揭晓答案的题目 _id(稳定,不受随机顺序影响)
}

/// FileManager-backed: Application Support/LanjingQuiz/practice-progress.json。
/// actor 串行化 save/load(镜像 FileManagerPracticeSessionStore)。
actor FileManagerPracticeProgressStore: PracticeProgressStoring {

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "LanjingQuiz/practice-progress.json")
    }

    func load() async -> [String: PracticeProgress]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: PracticeProgress].self, from: data)
    }

    func save(_ progress: [String: PracticeProgress]) async throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(progress).write(to: url, options: .atomic)
    }

    func clear() async throws {
        try? FileManager.default.removeItem(at: url)
    }
}
```

创建 `PracticeProgressStoreTests.swift`(镜像 PracticeSessionTests 的临时目录模式):

```swift
import XCTest
@testable import LanjingQuiz

final class PracticeProgressStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "PracticeProgressStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> FileManagerPracticeProgressStore {
        FileManagerPracticeProgressStore(url: dir.appending(path: "practice-progress.json"))
    }

    func testStoreLoadReturnsNilWhenAbsent() async {
        let loaded = await store().load()
        XCTAssertNil(loaded)
    }

    func testStoreSaveLoadRoundTrip() async throws {
        let store = store()
        let progress = ["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1", "q2"])]
        try await store.save(progress)
        let loaded = await store.load()
        XCTAssertEqual(loaded, progress)
    }

    func testStoreClearRemovesFile() async throws {
        let store = store()
        try await store.save(["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1"])])
        try await store.clear()
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }
}
```

- [ ] **Step 2: AppState 接线**

`AppState.swift`:

```swift
    let practiceSessionStore: FileManagerPracticeSessionStore
    /// 练习进度注册表(Application Support/LanjingQuiz/practice-progress.json),
    /// 与 sessionStore 同注入模式。
    let practiceProgressStore: FileManagerPracticeProgressStore
```

init 签名加参数并赋值:

```swift
    init(api: APIClient = APIClient(), bankStorage: BankStorage = FileManagerBankStorage(),
         practiceSessionStore: FileManagerPracticeSessionStore = FileManagerPracticeSessionStore(),
         practiceProgressStore: FileManagerPracticeProgressStore = FileManagerPracticeProgressStore()) {
        ...
        self.practiceSessionStore = practiceSessionStore
        self.practiceProgressStore = practiceProgressStore
```

`start()` 的 `-reset-bank` 分支追加:

```swift
            try? await practiceSessionStore.clear()
            // 进度注册表同样清零:入口行回到纯 "N 题" 基线(UI 测试断言)。
            try? await practiceProgressStore.clear()
```

`deleteBank()` 追加:

```swift
        Task { try? await practiceSessionStore.clear() }
        Task { try? await practiceProgressStore.clear() }
```

- [ ] **Step 3: VM 注入 + 加载 + 记录 + 清除 + 查询**

`PracticeBankViewModel.swift`:

```swift
    private let sessionStore: any PracticeSessionStoring
    private let progressStore: any PracticeProgressStoring
    /// 进度注册表内存副本(键 "\(category)/\(subCategory)")。
    private var progress: [String: PracticeProgress] = [:]
```

init:

```swift
    init(appState: AppState, storage: BankStorage? = nil, facade: PracticeUpstreamClient? = nil,
         sessionStore: (any PracticeSessionStoring)? = nil,
         progressStore: (any PracticeProgressStoring)? = nil) {
        self.appState = appState
        self.storage = storage ?? appState.bankStorage
        self.facade = facade ?? PracticeUpstreamClient(api: appState.api)
        self.sessionStore = sessionStore ?? appState.practiceSessionStore
        self.progressStore = progressStore ?? appState.practiceProgressStore
    }
```

加载(两个入口:`ensureBankReady` 的 `phase = .ready` 前、`resumeOrStart` 开头):

```swift
    /// 加载进度注册表(幂等,空表重载)。练习入口(题库列表/答题页)都会触发。
    private func loadProgressIfNeeded() async {
        guard progress.isEmpty else { return }
        if let loaded = await progressStore.load() { progress = loaded }
    }
```

`ensureBankReady()` 里 `phase = .ready` 赋值后加 `await loadProgressIfNeeded()`;`resumeOrStart()` 开头(guard 之后)加 `await loadProgressIfNeeded()`。

记录(三个 reveal 路径):`tapOption` 的 无答案分支与单选分支、`confirmSelection`,在设置 `answer.revealed = true` 之后、`persist()` 之前调用:

```swift
    private func recordAnswered(_ question: BankQuestion) {
        let key = "\(question.category)/\(question.subCategory)"
        var entry = progress[key] ?? PracticeProgress()
        if !entry.answeredIDs.contains(question.id) {
            entry.answeredIDs.append(question.id)
            progress[key] = entry
            let snapshot = progress
            let store = progressStore
            Task { try? await store.save(snapshot) }
        }
    }
```

调用点(三个):

```swift
        // tapOption 无答案分支内:
            answer.revealed = true
            answer.correct = nil
        // tapOption 单选分支内:
            answer.revealed = true
            answer.correct = BankLogic.grade(selected: answer.selected, question: question)
        // 两处 reveal 后、self.session = session 前:
            recordAnswered(question)
        // confirmSelection 内:
        answer.correct = BankLogic.grade(selected: answer.selected, question: question)
        answer.revealed = true
        recordAnswered(question)
```

清除:`bankWasDeleted()` 与 `crawlIfNeeded(force: true)` 的 `Task { try? await sessionStore.clear() }` 旁各加:

```swift
        progress = [:]
        Task { try? await progressStore.clear() }
```

查询(公开):

```swift
    // MARK: - 做题进度(需求 4)

    /// 某题型细分的已答数(跨会话累计)。
    func answeredCount(category: String, subCategory: String) -> Int {
        progress["\(category)/\(subCategory)"]?.answeredIDs.count ?? 0
    }

    /// 某大类下所有题型细分的已答数之和。
    func answeredCount(category: String) -> Int {
        progress.filter { $0.key.hasPrefix("\(category)/") }
            .values.reduce(0) { $0 + $1.answeredIDs.count }
    }
```

- [ ] **Step 4: 测试隔离 + 新单元测试**

`PracticeBankViewModelTests.swift` 加 Fake(与 FakePracticeSessionStore 同文件):

```swift
/// In-memory progress store: records saves/clears, never touches the file system.
actor FakePracticeProgressStore: PracticeProgressStoring {
    private(set) var stored: [String: PracticeProgress]?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    func load() async -> [String: PracticeProgress]? { stored }
    func save(_ progress: [String: PracticeProgress]) async throws {
        stored = progress
        saveCount += 1
    }
    func clear() async throws {
        stored = nil
        clearCount += 1
    }

    func awaitSaveCount(_ target: Int) async {
        while saveCount < target { await Task.yield() }
    }
}
```

`makeVM` 改为注入 fake progress store(否则 VM 默认走真实文件,污染测试):

```swift
    private func makeVM(storage: FakeBankStorage, sessionStore: FakePracticeSessionStore,
                        progressStore: FakePracticeProgressStore = FakePracticeProgressStore()) -> PracticeBankViewModel {
        PracticeBankViewModel(appState: AppState(), storage: storage, sessionStore: sessionStore,
                              progressStore: progressStore)
    }
```

新增测试(追加到 `PracticeBankViewModelTests`):

```swift
    // MARK: - 进度注册表(需求 4)

    func testTapRecordsAnsweredProgress() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // q1 单选 reveal → 记录
        await progressStore.awaitSaveCount(1)
        let saved = await progressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q1"])
        XCTAssertEqual(vm.answeredCount(category: "言语理解", subCategory: "成语辨析"), 1)
        XCTAssertEqual(vm.answeredCount(category: "言语理解"), 1)
    }

    func testPendingMultiSelectionNotRecordedUntilConfirm() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.nextQuestion()
        vm.nextQuestion() // → q3 多选
        vm.tapOption("A") // 未提交 → 不计入进度
        let saveCount = await progressStore.saveCount
        XCTAssertEqual(saveCount, 0)

        vm.confirmSelection()
        await progressStore.awaitSaveCount(1)
        let saved = await progressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q3"])
    }

    func testAnsweredProgressDeduplicatesAndAggregatesAcrossSubcategories() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // q1 reveal
        vm.tapOption("A") // 再次 tap 同题(已 reveal,无变化)—— 不重复记录
        await progressStore.awaitSaveCount(1)
        XCTAssertEqual(vm.answeredCount(category: "言语理解", subCategory: "成语辨析"), 1)

        // 手动预置另一题型细分的进度,验证大类聚合。
        try await progressStore.save([
            "言语理解/虚词辨析": PracticeProgress(answeredIDs: ["x1", "x2"]),
            "数字运算/速算": PracticeProgress(answeredIDs: ["y1"]),
        ])
        XCTAssertEqual(vm.answeredCount(category: "言语理解"), 3) // 1 + 2
        XCTAssertEqual(vm.answeredCount(category: "数字运算"), 1)
    }

    func testBankDeletedClearsProgressRegistry() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A")
        await progressStore.awaitSaveCount(1)
        XCTAssertEqual(vm.answeredCount(category: "言语理解"), 1)

        vm.bankWasDeleted()
        XCTAssertEqual(vm.answeredCount(category: "言语理解"), 0)
        await progressStore.awaitClearCount(1)
    }
```

- [ ] **Step 5: 跑测试确认失败 → 实现 → 通过**

```bash
cd apps/ios && xcodegen generate
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:LanjingQuizTests/PracticeProgressStoreTests \
  -only-testing:LanjingQuizTests/PracticeBankViewModelTests 2>&1 | tail -20
```

Expected: 先 FAIL(类型不存在/行为未实现)→ 实现后 PASS。`testTapOptionSingleWrongWritesSelected` 等既有测试的 saveCount 断言不受影响(progressStore 独立于 sessionStore)。

- [ ] **Step 6: 提交**

```bash
git add apps/ios/LanjingQuiz/Support/PracticeProgressStore.swift apps/ios/LanjingQuizTests/PracticeProgressStoreTests.swift \
  apps/ios/LanjingQuiz/App/AppState.swift apps/ios/LanjingQuiz/ViewModels/PracticeBankViewModel.swift \
  apps/ios/LanjingQuizTests/PracticeBankViewModelTests.swift apps/ios/LanjingQuiz.xcodeproj
git commit -m "feat: 练习进度注册表跨会话累计已做题(随机顺序下按题目 ID 记录)"
```

---

### Task 3: 题型入口显示 x/xx 进度(需求 4 展示)

**Files:**
- Modify: `apps/ios/LanjingQuiz/Views/Practice/PracticeSubcategoryListView.swift:17-27`
- Modify: `apps/ios/LanjingQuiz/Views/Practice/PracticeCategoryListView.swift:14-25`

**Interfaces:**
- Consumes: `vm.answeredCount(category:subCategory:) -> Int`、`vm.answeredCount(category:) -> Int`(Task 2)

**展示规则:** 已答数 > 0 的入口行把 `"N 题"` 替换为 `"x/N"`;未做过的不变(`"N 题"`,既有 UI 测试 `staticTexts["5 题"]` 保持通过)。子类行用精确键,大类行用聚合值。

- [ ] **Step 1: 子类行**

`PracticeSubcategoryListView.swift:17-27` 的 ForEach 内改为:

```swift
                ForEach(vm.subcategories, id: \.name) { group in
                    NavigationLink(value: PracticeRoute.quiz(category: category, subCategory: group.name)) {
                        HStack {
                            Text(group.name)
                            Spacer()
                            // 需求 4:做过的题型显示做题进度 x/xx,否则显示题量。
                            let answered = vm.answeredCount(category: category, subCategory: group.name)
                            Text(answered > 0 ? "\(answered)/\(group.count)" : "\(group.count) 题")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(group.count == 0)
                }
```

- [ ] **Step 2: 大类行**

`PracticeCategoryListView.swift:14-25` 的 ForEach 内改为:

```swift
                ForEach(BankLogic.categories, id: \.self) { category in
                    let count = vm.meta?.counts?[category] ?? 0
                    let answered = vm.answeredCount(category: category)
                    NavigationLink(value: PracticeRoute.subcategories(category: category)) {
                        HStack {
                            Text(category)
                            Spacer()
                            Text(answered > 0 ? "\(answered)/\(count)" : "\(count) 题")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(count == 0)
                }
```

- [ ] **Step 3: 编译 + 既有测试通过(展示逻辑由 Task 6 的 UI 测试端到端验证)**

```bash
cd apps/ios && xcodebuild build -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 提交**

```bash
git add apps/ios/LanjingQuiz/Views/Practice/PracticeSubcategoryListView.swift \
  apps/ios/LanjingQuiz/Views/Practice/PracticeCategoryListView.swift
git commit -m "feat: 题型入口显示做题进度 x/xx(需求 4)"
```

---

### Task 4: 底栏复用考试设计(去交卷)(需求 1)

**Files:**
- Create: `apps/ios/LanjingQuiz/Views/Practice/PracticeStatsBarView.swift`
- Modify: `apps/ios/LanjingQuiz/Views/Practice/PracticeQuizView.swift`(header 拆分 + 底栏接入)

**Interfaces:**
- Consumes: `vm.session`(rightCount/wrongCount/answeredCount)、`vm.resumedFromDisk`
- Produces: `struct PracticeStatsBarView: View { let vm: PracticeBankViewModel; let onOpenAnswerCard: () -> Void }`

**设计说明:** 镜像 `Views/AnswerCard/StatsBarView.swift` 的视觉(相同 HStack 结构、`.system(size: 13, weight: .bold)` 统计 Label、`Color(.systemGray5)` 答题卡胶囊、底栏 `Color(.secondarySystemBackground)` + `.padding(.horizontal)` + `.padding(.vertical, 10)`),**去掉交卷按钮及其 confirmationDialog/isSubmitting**。统计三格沿用考试语义:答对(checkmark.circle.fill DS.accent)/答错(xmark.circle.fill DS.red)/未答(circle .secondary)。考试 StatsBarView 保持不动,避免考试回归。

- [ ] **Step 1: 新建底栏视图**

创建 `Views/Practice/PracticeStatsBarView.swift`:

```swift
import SwiftUI

/// 练习答题页底部统计栏:镜像考试 StatsBarView 的设计(答对/答错/未答 +
/// 答题卡胶囊),但练习没有交卷 —— 无提交按钮与确认对话框(需求 1)。
struct PracticeStatsBarView: View {
    let vm: PracticeBankViewModel
    let onOpenAnswerCard: () -> Void

    private var session: PracticeSession? { vm.session }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Label("\(session?.rightCount ?? 0)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(DS.accent)
                Label("\(session?.wrongCount ?? 0)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(DS.red)
                Label("\(session?.questions.count ?? 0 - (session?.answeredCount ?? 0))", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .bold))
            Spacer()
            Button {
                onOpenAnswerCard()
            } label: {
                Text("答题卡")
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
```

- [ ] **Step 2: PracticeQuizView 布局拆分**

`PracticeQuizView.swift`:
1. `quizContent` 改为 `VStack(spacing: 0)`:`headerRow` 移出滚动区置于顶部,滚动区只保留题干/选项/解析,底部接底栏(底部栏容器样式仿考试 AnswerCardView.swift:10-13):

```swift
    private func quizContent(_ session: PracticeSession, _ question: BankQuestion) -> some View {
        VStack(spacing: 0) {
            headerRow(session, question)
                .padding(.horizontal)
                .padding(.top, 8)
            if vm.resumedFromDisk && !session.isFinished {
                resumeBanner
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Color.clear
                            .frame(height: 0)
                            .id("quiz-top")
                        if let stem = question.stem, !stem.isEmpty {
                            RichHTMLContent(html: stem, fontSize: 15)
                                .id(question.id)
                                .padding(.bottom, 4)
                                .overlay(alignment: .bottom) { Divider() }
                        }
                        RichHTMLContent(html: question.question, fontSize: 17)
                            .id(question.id)
                        options(for: session, question)
                        if let answer = session.currentAnswer, answer.revealed {
                            ExplainBannerView(
                                correct: answer.correct,
                                answerLabel: question.correctAnswers.joined(separator: "、"),
                                analysis: question.analysis
                            )
                            Button(session.isLast ? "完成" : "下一题") {
                                vm.nextQuestion()
                            }
                            .buttonStyle(KeycapButtonStyle(color: DS.accent, radius: DS.radiusSM))
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: question.id) { _, _ in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("quiz-top", anchor: .top)
                    }
                }
            }
            PracticeStatsBarView(vm: vm) { showAnswerCard = true }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
        }
    }
```

2. `headerRow` 删除 答题卡 按钮与 `答对 n · 答错 n` 文本(移入底栏),保留第 x/n 题胶囊与多选/无答案徽章:

```swift
    private func headerRow(_ session: PracticeSession, _ question: BankQuestion) -> some View {
        HStack(spacing: 8) {
            Text("第 \(session.index + 1)/\(session.questions.count) 题")
                .font(.system(size: 13, weight: .heavy))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
            if question.isMulti {
                Text("多选")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(DS.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DS.blue.opacity(0.12))
                    .clipShape(Capsule())
            }
            if !question.isGradable {
                Text("无答案")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(DS.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DS.orange.opacity(0.12))
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }
```

- [ ] **Step 3: 构建 + 既有 UI 测试回归**

```bash
cd apps/ios && xcodegen generate
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:LanjingQuizTests 2>&1 | tail -5
```

Expected: 单元测试 PASS(答题卡按钮从 header 移到底栏,label 未变,UI 测试仍按 `app.buttons["答题卡"]` 命中)。UI 测试全量回归放到 Task 6 之后。

- [ ] **Step 4: 提交**

```bash
git add apps/ios/LanjingQuiz/Views/Practice/PracticeStatsBarView.swift \
  apps/ios/LanjingQuiz/Views/Practice/PracticeQuizView.swift apps/ios/LanjingQuiz.xcodeproj
git commit -m "feat: 练习底栏复用考试设计(统计+答题卡,去交卷,需求 1)"
```

---

### Task 5: TabView 左右滑动切题(需求 2)

**Files:**
- Modify: `apps/ios/LanjingQuiz/Views/Practice/PracticeQuizView.swift`

**Interfaces:**
- Consumes: `vm.jumpTo(_ index: Int)`(越界/同索引 no-op,已持久化)、`vm.nextQuestion()`
- Produces: 无新接口;PracticeQuizView 内分页布局

**设计说明:** 镜像考试 QuizView.swift:56-63 的 `TabView(selection:).tabViewStyle(.page(indexDisplayMode: .never))`。每页是独立 ScrollView,页内取**本页索引的 answer**(`session.answers[index]`,不能再用 `session.currentAnswer` —— 相邻页渲染时全局 index 指向当前页,答案会错位)。`下一题/完成` 按钮保留(需求说"可以左右滑动",原有按钮导航不删)。`summaryCard` 仍在 `session.isFinished` 时整体替换。答题卡 overlay 的 jumpTo 通过 selection 绑定带动 TabView 动画。

- [ ] **Step 1: quizContent 改分页**

`PracticeQuizView.swift` 的 `quizContent` 内,把 `ScrollViewReader { ... }` 整体替换为:

```swift
            TabView(selection: pageSelection) {
                ForEach(Array(session.questions.enumerated()), id: \.offset) { index, q in
                    questionPage(session, index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxHeight: .infinity)
            PracticeStatsBarView(vm: vm) { showAnswerCard = true }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
```

并新增:

```swift
    /// 滑动/答题卡跳转共用:TabView selection 绑定走 vm.jumpTo(越界与同
    /// 索引为 no-op;索引已持久化,滑动位置重启后保留)。
    private var pageSelection: Binding<Int> {
        Binding(
            get: { vm.session?.index ?? 0 },
            set: { vm.jumpTo($0) }
        )
    }

    /// 单页 = 一个可滚动题目页。页内答案取本页索引,而不是全局
    /// currentAnswer(相邻页渲染时全局 index 指向当前页,会错位)。
    private func questionPage(_ session: PracticeSession, _ index: Int) -> some View {
        let question = session.questions[index]
        let answer = index < session.answers.count
            ? session.answers[index]
            : PracticeSession.PracticeAnswer()
        let isLast = index + 1 >= session.questions.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let stem = question.stem, !stem.isEmpty {
                    RichHTMLContent(html: stem, fontSize: 15)
                        .id(question.id)
                        .padding(.bottom, 4)
                        .overlay(alignment: .bottom) { Divider() }
                }
                RichHTMLContent(html: question.question, fontSize: 17)
                    .id(question.id)
                options(for: question, answer: answer)
                if answer.revealed {
                    ExplainBannerView(
                        correct: answer.correct,
                        answerLabel: question.correctAnswers.joined(separator: "、"),
                        analysis: question.analysis
                    )
                    Button(isLast ? "完成" : "下一题") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            vm.nextQuestion()
                        }
                    }
                    .buttonStyle(KeycapButtonStyle(color: DS.accent, radius: DS.radiusSM))
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
```

`options(for:question:answer:)` 签名改为按页传参:

```swift
    @ViewBuilder
    private func options(for question: BankQuestion, answer: PracticeSession.PracticeAnswer) -> some View {
        VStack(spacing: 12) {
            ForEach(question.letters, id: \.self) { letter in
                PracticeOptionRowView(
                    question: question,
                    letter: letter,
                    answer: answer,
                    onTap: { vm.tapOption(letter) }
                )
            }
        }
        if question.isMulti, !answer.revealed, !answer.selected.isEmpty {
            Button("提交") {
                vm.confirmSelection()
            }
            .buttonStyle(KeycapButtonStyle(color: DS.accent, radius: DS.radiusSM))
            .padding(.top, 4)
        }
    }
```

`quizContent` 里 `headerRow` 的 question 参数保持传当前题(`session.questions[session.index]`),body 里的 `if let question` 分支不变。

- [ ] **Step 2: 构建 + 单元测试**

```bash
cd apps/ios && xcodebuild build -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -5
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:LanjingQuizTests 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED + 单元测试 PASS(VM 层无改动,纯视图层)。

- [ ] **Step 3: 提交**

```bash
git add apps/ios/LanjingQuiz/Views/Practice/PracticeQuizView.swift
git commit -m "feat: 练习左右滑动切换题目(考试式 TabView 分页,需求 2)"
```

---

### Task 6: UI 测试 —— 分页适配 + 滑动/进度新断言(需求 2/4 端到端)

**Files:**
- Modify: `apps/ios/LanjingQuizUITests/PracticeFlowUITests.swift`

**背景:** TabView(.page) 会让相邻页同时存在于 a11y 树(可见页 + 邻页),`app.buttons["A"]`、`app.webViews.element(boundBy: 0)` 这类"取第一个"的查询可能命中屏幕外的邻页元素,导致 not-hittable 失败或量到错误高度。为所有页面内元素查询加"取可见帧元素"帮助函数。

- [ ] **Step 1: 帮助函数适配**

在 `PracticeFlowUITests` 加两个帮助函数:

```swift
    /// 页面上可见的选项按钮:TabView 分页让邻页同时存在于 a11y 树,裸
    /// firstMatch 可能命中屏幕外元素(not hittable)。
    private func optionButton(_ app: XCUIApplication, _ letter: String) -> XCUIElement {
        let matches = app.buttons.matching(identifier: letter).allElementsBoundByIndex
        return matches.first(where: \.isHittable) ?? matches.first!
    }

    /// 屏幕上可见的题干 web view(分页后元素(boundBy:) 顺序不再等于页码)。
    private func visibleStemWebView(_ app: XCUIApplication) -> XCUIElement? {
        let screen = app.windows.firstMatch.frame
        return app.webViews.allElementsBoundByIndex.first { view in
            let frame = view.frame
            return frame.minX >= 0 && frame.maxX <= screen.width && frame.maxY > 0
        }
    }
```

`answerCurrentQuestion` 改为用 `optionButton`:

```swift
    private func answerCurrentQuestion(_ app: XCUIApplication, letter: String, advance: String) {
        let option = optionButton(app, letter)
        XCTAssertTrue(option.waitForExistence(timeout: 5), "option row missing")
        option.tap()
        let button = app.buttons[advance]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "answer did not reveal the \(advance) button")
        button.tap()
    }
```

`testPracticeWrongOptionMarkedAndAnswerCard` 里 140-141 行的 `app.buttons["B"]` 与 `app.buttons["A"]` 处替换为 `optionButton(app, "B")` / `optionButton(app, "A")`。

`testPracticeStemHeightTracksQuestion` 里 `app.webViews.element(boundBy: 0)` 改为:

```swift
        let questionWebView = try XCTUnwrap(visibleStemWebView(app))
```

(其余 waitForElement 断言不变,页面切换后 visibleStemWebView 返回的是当前页的题干。)

- [ ] **Step 2: 新 UI 测试 1 —— 滑动切题(需求 2)**

```swift
    /// 需求 2:练习页像考试一样左右滑动切换题目,滑动位置(索引)已持久化。
    func testPracticeSwipeNavigatesQuestions() throws {
        continueAfterFailure = false

        let server = MockUpstreamServer()
        try server.start()
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchEnvironment["LANJING_BASE_URL"] = "http://127.0.0.1:\(server.port)"
        app.launchArguments = ["-reset-bank"]
        app.launch()
        logInIfNeeded(app)
        enterSubcategory("成语辨析", app: app)

        let header1 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 1/'")).firstMatch
        XCTAssertTrue(header1.waitForExistence(timeout: 10), "quiz screen is blank — no question header")

        // 左滑 → 第 2 题。
        app.swipeLeft()
        let header2 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 2/'")).firstMatch
        XCTAssertTrue(header2.waitForExistence(timeout: 5), "swipe left did not advance to question 2")

        // 右滑 → 回到第 1 题。
        app.swipeRight()
        XCTAssertTrue(header1.waitForExistence(timeout: 5), "swipe right did not return to question 1")

        // 答完收尾,不留脏状态。
        answerCurrentQuestion(app, letter: "A", advance: "下一题")
        answerCurrentQuestion(app, letter: "A", advance: "完成")
        XCTAssertTrue(app.staticTexts["练习完成"].waitForExistence(timeout: 10), "summary card never appeared")
    }
```

- [ ] **Step 3: 新 UI 测试 2 —— 入口 x/xx 进度(需求 4)**

```swift
    /// 需求 4:做完练习后,题型入口显示做题进度 x/xx(子类行精确值、
    /// 大类行聚合值)。
    func testPracticeEntryRowsShowProgressAfterRun() throws {
        continueAfterFailure = false

        let server = MockUpstreamServer()
        try server.start()
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchEnvironment["LANJING_BASE_URL"] = "http://127.0.0.1:\(server.port)"
        app.launchArguments = ["-reset-bank"]
        app.launch()
        logInIfNeeded(app)
        enterSubcategory("成语辨析", app: app)

        // 答完全部 3 题。
        let headers = ["第 1/", "第 2/", "第 3/"]
        for (index, expected) in headers.enumerated() {
            let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '\(expected)'")).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 10), "\(expected) header missing")
            answerCurrentQuestion(app, letter: "A", advance: index == headers.count - 1 ? "完成" : "下一题")
        }
        XCTAssertTrue(app.staticTexts["练习完成"].waitForExistence(timeout: 10), "summary card never appeared")

        // 返回题型列表:子类行显示 3/3。
        app.buttons["返回题型列表"].tap()
        let subRowProgress = app.staticTexts["3/3"]
        XCTAssertTrue(subRowProgress.waitForExistence(timeout: 10), "subcategory row did not show 3/3 progress")

        // 大类行显示聚合进度 3/5(成语辨析 3 题已做 + 虚词辨析 0 题)。
        let subListBar = app.navigationBars["言语理解"]
        XCTAssertTrue(subListBar.waitForExistence(timeout: 5), "subcategory list never reappeared")
        tapBackButton(in: subListBar)
        let categoryProgress = app.staticTexts["3/5"]
        XCTAssertTrue(categoryProgress.waitForExistence(timeout: 5), "category row did not show 3/5 progress")
    }
```

- [ ] **Step 4: 全量 UI 测试回归**

```bash
cd apps/ios && xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:LanjingQuizUITests 2>&1 | tail -20
```

Expected: 全部 PASS(既有 4 个 + 新增 2 个)。若失败,按 `ANSWER CARD UI TREE:` / `MOCK CALLS:` 诊断输出定位,回到对应 Task 修正后重跑。

- [ ] **Step 5: 提交**

```bash
git add apps/ios/LanjingQuizUITests/PracticeFlowUITests.swift
git commit -m "test: 练习滑动切题与入口 x/xx 进度 UI 测试 + 分页后元素查询适配"
```

---

### Task 7: 全量验证 + PR + 自动合并

**Files:** 无(流程任务)

- [ ] **Step 1: 全量测试(单元 + UI)**

```bash
cd apps/ios && xcodegen generate && \
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -30
```

Expected: 单元与 UI 测试全部 PASS,`** TEST SUCCEEDED **`。

- [ ] **Step 2: 推分支 + PR + auto-merge**

```bash
git checkout -b fix/practice-revamp
git push -u origin fix/practice-revamp
gh pr create --title "练习模块改造:底栏/滑动切题/进度持久化/入口 x/xx" \
  --body "1. 底栏复用考试设计(去交卷)\n2. 左右滑动切换题目\n3. 随机顺序下进度持久化(恢复规则改 ID 集合比对)\n4. 题型入口显示 x/xx 进度(新增 practice-progress.json 注册表)" 
gh pr merge <pr_number> --auto --merge
```

(合并后按记忆同步:`git checkout main && git pull && git branch -D fix/practice-revamp`。)

---

## Self-Review

**需求覆盖:**
1. ✅ 底栏复用考试设计去交卷 → Task 4(PracticeStatsBarView 镜像 StatsBarView,无交卷/确认框/ProgressView)
2. ✅ 左右滑动切题 → Task 5(TabView(.page),selection 绑定 vm.jumpTo;下一题按钮保留)
3. ✅ 随机顺序下持久化 → Task 1(恢复规则 ID 集合比对,存档自带顺序)+ 既有逐次持久化 + Task 2 注册表跨会话累计
4. ✅ 入口 x/xx → Task 2 数据源 + Task 3 两个列表展示 + Task 6 UI 断言

**占位符扫描:** 全部步骤含具体代码/命令;新接口签名在 Task 2 的 Interfaces 与后续 Task 引用处一致(`answeredCount(category:subCategory:)` / `answeredCount(category:)` / `PracticeStatsBarView(vm:onOpenAnswerCard:)`)。

**类型一致性:** `PracticeProgress.answeredIDs`(Task 2 定义)在 Task 2 测试/聚合与 Task 3 展示处一致;`pageSelection`/`questionPage(_:_:)`/`options(for:answer:)`(Task 5 定义)仅 Task 5 内部使用,无跨任务漂移。
