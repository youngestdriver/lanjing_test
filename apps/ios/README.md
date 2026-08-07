# LanjingQuiz iOS

`LanjingQuiz` is the native iOS client for the Lanjing Weike quiz platform. It is a SwiftUI rewrite of the web workflow and communicates directly with the upstream service; it does not require `apps/web/server.js` to run.

## Requirements

- macOS with Xcode 16 or later
- iOS 17.0 or later deployment target
- An iOS Simulator runtime or an Apple Developer signing team for a physical device
- XcodeGen only when regenerating `LanjingQuiz.xcodeproj` from `project.yml`

The app is written in Swift 6 and supports iPhone and iPad. Session cookies are persisted in the Keychain on device.

## Open And Run

1. Open `LanjingQuiz.xcodeproj` in Xcode.
2. Select the shared `LanjingQuiz` scheme.
3. Select an iOS Simulator or a connected iPhone.
4. For a physical device, set a valid Development Team in the target's Signing & Capabilities settings.
5. Build and run with Product > Run.

The project is checked in, so XcodeGen is not needed for normal development. When `project.yml` changes, regenerate the project from this directory:

```sh
xcodegen generate
```

## Command Line

Build for an available simulator:

```sh
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

Run the unit tests:

```sh
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

If that simulator name is unavailable, use a destination listed by:

```sh
xcodebuild -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -showdestinations
```

## User Flow

After sign-in, the root screen has three native tabs:

- **Exam List**: The default tab. It groups available exams and supports starting a new exam or resuming an active one.
- **Practice**: On first use the app **crawls the whole 机考题库 directly from the upstream platform** (every paper, questions with answer keys + 解析) and stores it locally — one JSONL file per category, same format as the collector's `apps/bank/data`, with per-paper crawl progress in `meta.json` so an interrupted crawl resumes without re-entering papers. Practice then aggregates the local bank by 一级分类 (大类) → 二级分类 (题型细分, classified locally by the rule engine ported from `apps/bank/lib/question-classifier.js`) and runs entirely offline. Answers are graded **locally and never submitted upstream**; crawling a 新开 (wfs=1) paper creates a real upstream attempt that is best-effort-ended after fetching, while 进行中 (wfs=0) papers are read-only and never ended. Practice requires a login session; 我的 > 更新题库 re-crawls (completed papers are skipped).
- **Me**: Theme selection and sign-out.

On iOS 26 and later, the system-provided `TabView` automatically uses Apple's Liquid Glass tab bar. Earlier supported iOS releases use the system tab bar appearance for their platform version.

The quiz flow includes question paging, keyboard navigation on iPad, answer reporting, an answer-card sheet, question marking, and result parsing. The result page returns to the default Exam List tab.

### Abandoning An Exam

Swipe an active exam, tap **Abandon**, then confirm the action. The app does not allow a full-swipe destructive action.

After a confirmed upstream completion, the app immediately hides the old active-exam state. It refreshes the list twice and continues to suppress an unchanged stale entry, so an invalid "resume" record cannot be opened while the upstream list is catching up. A record with the same exam ID may reappear only after the upstream service reports a changed state.

## Project Layout

```text
apps/ios/
├── LanjingQuiz.xcodeproj/       Xcode project
├── LanjingQuiz/
│   ├── App/                     App entry point, route and theme state
│   ├── Models/                  Exam, question, result and API models
│   ├── Networking/              Upstream requests, cookies and HTML parsers
│   ├── Support/                 Design system, formatting and utilities
│   ├── ViewModels/              Login, exam-list and quiz state
│   └── Views/                   SwiftUI screens and reusable view components
├── LanjingQuizTests/            Unit tests and fixtures
└── project.yml                  XcodeGen project definition
```

## Networking And Credentials

`APIClient` connects to `https://test.lanjingweike.com` and maintains its session cookie jar through `CookieStore`. Login credentials are used only to authenticate with that service. The app persists session cookies in the Keychain; sign-out and session-expiry handling clear those cookies.

Optional CookieCloud sync (`CookieCloudSync`, same protocol as the web client and the official browser extension) shares the session across devices: the app pushes the session after login, pulls once at launch (bounded by a 4 s timeout), and exposes a manual sync button in "我的". The server URL, UUID, and enabled flag live in `UserDefaults`; the password lives in the Keychain. The Info.plist enables `NSAllowsLocalNetworking` (plus the local-network usage description) so plain-HTTP self-hosted CookieCloud servers on the LAN work; arbitrary HTTP is not enabled.

Network calls mirror the upstream login, exam-list, enter, answer, mark, submit, and result flows. Do not commit account credentials, cookies, derived data, or Xcode `xcuserdata` files.

## Verification

The `LanjingQuizTests` target currently contains 130 unit tests covering answer mapping, exam and result parsing, session expiry detection, login form encoding, rich HTML content, hashing, quiz logic, CookieCloud crypto/conversion (same interop vectors as the web client), the practice 题型细分 classifier (ported from the collector's rule engine), the practice-upstream mapping (paper filtering, section cleaning, state join, DTO → question), and the local bank persistence (incremental append, meta with per-paper crawl progress, JSONL encode/decode round trip in the collector's format).

The UI test (`LanjingQuizUITests`) runs the whole crawl-and-practice flow end-to-end against an in-process mock upstream (`MockUpstreamServer`, selected via the `LANJING_BASE_URL` launch environment; the local bank is wiped via the `-reset-bank` launch argument so the crawl runs on every execution) — it is hermetic and runs in CI without any local server.

Before delivering a change, build `LanjingQuiz`, run the test target, and validate affected user flows on a simulator or a signed physical device. Confirming **Abandon** has a real upstream effect, so do not use it as an unattended smoke test.

## Disclaimer

This client is intended for learning and research. Use it only with authorization and in accordance with the platform's rules.
