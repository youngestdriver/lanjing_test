"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { chromium } = require("playwright-core");

const WEB_DIR = path.resolve(__dirname, "..");
const PORT = 43129;
const BASE_URL = `http://127.0.0.1:${PORT}`;

function chromeExecutable() {
  const candidates = [
    process.env.CHROME_PATH,
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ].filter(Boolean);
  const executable = candidates.find((candidate) => fs.existsSync(candidate));
  if (!executable) throw new Error("Chrome was not found; set CHROME_PATH to run browser smoke tests");
  return executable;
}

async function waitForServer(child) {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    if (child.exitCode !== null) throw new Error(`Web server exited with ${child.exitCode}`);
    try {
      const response = await fetch(`${BASE_URL}/api/status`);
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Timed out waiting for the Web server");
}

function json(route, body, status = 200) {
  return route.fulfill({
    status,
    contentType: "application/json; charset=utf-8",
    body: JSON.stringify(body),
  });
}

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

async function expectPath(page, expected) {
  assert.equal(new URL(page.url()).pathname, expected);
}

async function expectNoHorizontalOverflow(page, label) {
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  assert.ok(overflow <= 0, `${label} overflows by ${overflow}px`);
}

async function elementContrast(locator) {
  return locator.evaluate(async (element) => {
    await Promise.all(element.getAnimations().map((animation) => animation.finished.catch(() => {})));
    const context = document.createElement("canvas").getContext("2d", { willReadFrequently: true });
    context.canvas.width = 1;
    context.canvas.height = 1;
    const rgb = (color) => {
      context.clearRect(0, 0, 1, 1);
      context.fillStyle = color;
      context.fillRect(0, 0, 1, 1);
      return [...context.getImageData(0, 0, 1, 1).data].slice(0, 3);
    };
    const luminance = (color) => color
      .map((channel) => channel / 255)
      .map((channel) => channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4)
      .reduce((sum, channel, index) => sum + channel * [0.2126, 0.7152, 0.0722][index], 0);
    const style = getComputedStyle(element);
    const foreground = luminance(rgb(style.color));
    const background = luminance(rgb(style.backgroundColor));
    return (Math.max(foreground, background) + 0.05) / (Math.min(foreground, background) + 0.05);
  });
}

async function verifyOfflineShell(browser) {
  const context = await browser.newContext({ serviceWorkers: "allow" });
  try {
    await context.route("**/api/**", (route) => json(route, { loggedIn: false, hasSavedSession: false }));
    const page = await context.newPage();
    await page.goto(BASE_URL, { waitUntil: "domcontentloaded" });
    await page.evaluate(() => navigator.serviceWorker.ready);
    if (!await page.evaluate(() => Boolean(navigator.serviceWorker.controller))) {
      await page.reload({ waitUntil: "domcontentloaded" });
      await page.waitForFunction(() => Boolean(navigator.serviceWorker.controller));
    }

    const shell = ["/", "/manifest.json", "/styles.css", "/js/quiz-core.js", "/js/app.js", "/icon-192.png", "/icon-512.png"];
    const cacheReport = await page.evaluate(async (paths) => {
      const cacheNames = await caches.keys();
      const cacheName = cacheNames.find((name) => name === "quiz-v5");
      if (!cacheName) return { cacheName: null, missing: paths };
      const cache = await caches.open(cacheName);
      const matches = await Promise.all(paths.map((path) => cache.match(path)));
      return { cacheName, missing: paths.filter((path, index) => !matches[index]) };
    }, shell);
    assert.equal(cacheReport.cacheName, "quiz-v5");
    assert.deepEqual(cacheReport.missing, []);

    await context.setOffline(true);
    const response = await page.goto(`${BASE_URL}/practice`, { waitUntil: "domcontentloaded" });
    assert.ok(response && response.ok(), "offline navigation did not return the cached app shell");
    assert.equal(response.fromServiceWorker(), true);
    assert.equal(await page.locator("#appPage").count(), 1);
    assert.equal(await page.evaluate(() => [...document.styleSheets].some((sheet) => sheet.href?.endsWith("/styles.css"))), true);
  } finally {
    await context.close();
  }
}

async function verifyPracticeOffline(browser) {
  // Standalone practice scenario (fresh context, full mocks): the local bank
  // is populated, categories render from /api/practice/status, the JSONL
  // bank is served per category, and a whole quiz session runs with zero
  // network calls beyond the initial bank fetch.
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    serviceWorkers: "block",
  });
  try {
    await context.route("**/api/status", (route) => json(route, { loggedIn: true, hasSavedSession: true }));
    await context.route("**/api/practice/status", (route) => json(route, {
      loggedIn: true, isPopulated: true,
      meta: { counts: { 言语理解: 2, 数字运算: 1 }, round: 1, lastRun: "2026-08-11T00:00:00.000Z", papers: 2 },
      task: { running: false, index: 0, total: 0, paperName: "", error: null, doneAt: "2026-08-11T00:00:00.000Z" },
    }));
    const practiceJSONL = [
      JSON.stringify({ _id: "p1", subCategory: "逻辑填空", question: "<p>第一题题干</p>", options: ["正确选项", "干扰项二", "干扰项三", "干扰项四"], answer: "A", analysis: "因为 A 正确。", stem: "" }),
      JSON.stringify({ _id: "p2", subCategory: "成语辨析", question: "<p>第二题题干</p>", options: ["甲", "乙", "丙", "丁"], answer: ["A", "C"], analysis: "应同时选择甲和丙。", stem: "" }),
    ].join("\n");
    await context.route("**/api/practice/categories/*", (route) => route.fulfill({
      status: 200,
      contentType: "application/x-ndjson; charset=utf-8",
      body: practiceJSONL,
    }));
    const page = await context.newPage();
    await page.goto(BASE_URL + "/practice", { waitUntil: "domcontentloaded" });
    await page.waitForSelector("[data-practice-category]");
    const names = await page.$$eval("[data-practice-category]", (els) => els.map((el) => el.textContent.trim()));
    assert.ok(names.some((name) => name.includes("言语理解")), `categories rendered: ${names.join(",")}`);
    await page.click('[data-practice-category*="言语理解"]');
    await page.waitForSelector("[data-practice-subcategory]");
    await page.click("[data-practice-subcategory]");
    await page.waitForSelector("[data-practice-question]");
    await page.click("[data-practice-option]"); // first option is correct (answer A)
    await page.waitForSelector("[data-practice-result]");
    const result = await page.$eval("[data-practice-result]", (el) => el.textContent.trim());
    assert.ok(result.includes("答对"), `reveal shows result: ${result}`);
    await page.close();
  } finally {
    await context.close();
  }
}

async function main() {
  const server = spawn(process.execPath, ["server.js"], {
    cwd: WEB_DIR,
    env: {
      ...process.env,
      PORT: String(PORT),
      HOST: "127.0.0.1",
      // The real logout flow now calls the upstream; point it at an
      // unreachable address so the regression never touches the real service.
      LANJING_BASE_URL: "http://127.0.0.1:1",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let serverOutput = "";
  server.stdout.on("data", (chunk) => { serverOutput += chunk; });
  server.stderr.on("data", (chunk) => { serverOutput += chunk; });

  let browser;
  try {
    await waitForServer(server);
    browser = await chromium.launch({ executablePath: chromeExecutable(), headless: true });
    const context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      serviceWorkers: "block",
    });
    const page = await context.newPage();
    const pageErrors = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));

    const states = [
      { questionsId: "q1", uuId: "u1", num: "1", section: "综合", combId: null, state: "unanswered", marked: false },
      { questionsId: "q2", uuId: "u2", num: "2", section: "综合", combId: null, state: "error", marked: false },
      { questionsId: "q3", uuId: "u3", num: "3", section: "综合", combId: null, state: "unanswered", marked: false },
    ];
    const questions = [
      {
        _id: "q1", question: "以下哪些选项属于正确集合？", answer1: "甲", answer2: "乙", answer3: "丙", answer4: "丁",
        _isMulti: true, _answers: ["A", "C"], _answerHtml: "甲<br>丙", _analysis: "需要同时选择甲和丙。", _previousAnswers: [],
      },
      {
        _id: "q2", question: "继续考试时应恢复哪一个历史错选？", answer1: "正确答案", answer2: "历史错选", answer3: "干扰项", answer4: "干扰项",
        _isMulti: false, _answers: ["A"], _answerHtml: "正确答案", _analysis: "B 是此前选择，A 是参考答案。", _previousAnswers: ["B"],
      },
      {
        _id: "q3", question: "用于验证自动切题设置的单选题", answer1: "A", answer2: "B", answer3: "C", answer4: "D",
        _isMulti: false, _answers: ["D"], _answerHtml: "D", _analysis: "测试题。", _previousAnswers: [],
      },
    ];
    const answerBodies = [];
    let answerAttempts = 0;
    let markAttempts = 0;
    let submitAttempts = 0;
    let logoutAttempts = 0;
    let examListAttempts = 0;
    let examEnterAttempts = 0;
    let lanEnabledSetting = true;
    let cookieCloudConfig = { enabled: false, server: "", uuid: "", hasPassword: false };
    let cookieCloudSyncCalls = 0;
    let loggedIn = true;
    let delayNextExamList = false;
    let delayNextStatus = false;
    let delayNextEnter = false;
    let delayAuthStatus = false;
    let rejectNextExamList = false;
    const delayedExamStarted = deferred();
    const releaseDelayedExam = deferred();
    const delayedStatusStarted = deferred();
    const releaseDelayedStatus = deferred();
    const delayedStatusServed = deferred();
    const delayedEnterStarted = deferred();
    const releaseDelayedEnter = deferred();
    const authStatusStarted = deferred();
    const releaseAuthStatus = deferred();
    const authStatusServed = deferred();
    const firstAnswerStarted = deferred();
    const releaseFirstAnswer = deferred();
    const firstMarkStarted = deferred();
    const releaseFirstMark = deferred();
    const firstSubmitStarted = deferred();
    const releaseFirstSubmit = deferred();
    const firstSubmitServed = deferred();

    await page.route("**/api/**", async (route) => {
      const request = route.request();
      const url = new URL(request.url());
      if (url.pathname === "/api/status") {
        if (delayAuthStatus) {
          delayAuthStatus = false;
          authStatusStarted.resolve();
          await releaseAuthStatus.promise;
          await json(route, { loggedIn, hasSavedSession: loggedIn });
          authStatusServed.resolve();
          return;
        }
        if (delayNextStatus) {
          delayNextStatus = false;
          delayedStatusStarted.resolve();
          await releaseDelayedStatus.promise;
          await json(route, { loggedIn, hasSavedSession: loggedIn });
          delayedStatusServed.resolve();
          return;
        }
        return json(route, { loggedIn, hasSavedSession: loggedIn });
      }
      if (url.pathname === "/api/exams") {
        examListAttempts += 1;
        if (rejectNextExamList) {
          rejectNextExamList = false;
          return json(route, { error: "会话已失效" }, 401);
        }
        if (delayNextExamList) {
          delayNextExamList = false;
          delayedExamStarted.resolve();
          await releaseDelayedExam.promise;
        }
        return json(route, {
          total: 1,
          styles: { 1: "机考题库" },
          exams: [{ id: 101, name: "Web parity fixture", style: "机考题库", practiceMode: 2, totalTime: 30, wfs: 0 }],
        });
      }
      if (url.pathname === "/api/exams/101/enter") {
        examEnterAttempts += 1;
        if (delayNextEnter) {
          delayNextEnter = false;
          delayedEnterStarted.resolve();
          await releaseDelayedEnter.promise;
        }
        return json(route, {
          examInfoId: "101", examResultsId: "501", uuid: "u1", testIds: ["q1", "q2", "q3"],
          questionStates: states, sections: { "综合": { total: 3, right: 0, error: 1, unanswered: 2 } },
        });
      }
      if (url.pathname === "/api/exams/101/questions") {
        return json(route, { questions, states, sections: { "综合": { total: 3, right: 0, error: 1, unanswered: 2 } } });
      }
      if (url.pathname === "/api/exams/101/answer") {
        answerAttempts += 1;
        answerBodies.push(request.postDataJSON());
        if (answerAttempts === 1) {
          firstAnswerStarted.resolve();
          await releaseFirstAnswer.promise;
        }
        return json(route, answerAttempts === 1 ? { success: false } : { success: true });
      }
      if (url.pathname === "/api/exams/101/mark") {
        markAttempts += 1;
        if (markAttempts === 1) {
          firstMarkStarted.resolve();
          await releaseFirstMark.promise;
        }
        return json(route, { success: true });
      }
      if (url.pathname === "/api/exams/101/submit") {
        submitAttempts += 1;
        if (submitAttempts === 1) {
          firstSubmitStarted.resolve();
          await releaseFirstSubmit.promise;
          await json(route, { error: "旧请求会话失效" }, 401);
          firstSubmitServed.resolve();
          return;
        }
        return submitAttempts === 2
          ? json(route, { error: "考试未能结束，请刷新后重试" }, 502)
          : json(route, { success: true, score: "88", beatRate: "76", rank: "24" });
      }
      if (url.pathname === "/api/logout") {
        assert.equal(request.method(), "POST");
        logoutAttempts += 1;
        loggedIn = false;
        return json(route, { success: true });
      }
      if (url.pathname === "/api/settings") {
        if (request.method() === "POST") {
          lanEnabledSetting = JSON.parse(request.postData() || "{}").lanEnabled;
        }
        return json(route, { lanEnabled: lanEnabledSetting, host: "127.0.0.1", envHost: false });
      }
      if (url.pathname === "/api/cookiecloud") {
        if (request.method() === "POST") {
          const body = JSON.parse(request.postData() || "{}");
          if (typeof body.enabled === "boolean") cookieCloudConfig.enabled = body.enabled;
          if (typeof body.server === "string") cookieCloudConfig.server = body.server;
          if (typeof body.uuid === "string") cookieCloudConfig.uuid = body.uuid;
          if (body.password) cookieCloudConfig.hasPassword = true;
        }
        return json(route, { ...cookieCloudConfig, lastPush: null, lastPull: null, lastError: null });
      }
      if (url.pathname === "/api/cookiecloud/sync") {
        cookieCloudSyncCalls++;
        return json(route, { applied: false, pushed: false, lastPush: null, lastPull: null, lastError: null });
      }
      if (url.pathname === "/api/practice/status") {
        // Main-flow fixture: the bank exists but is not populated yet, so the
        // practice tab renders the crawl gate. The crawl POST itself is left
        // unmocked (500) to assert the gate stays put on failure.
        return json(route, {
          loggedIn: true, isPopulated: false,
          meta: { counts: {}, round: 0, lastRun: null, papers: 0 },
          task: { running: false, index: 0, total: 0, paperName: "", error: null, doneAt: null },
        });
      }
      return json(route, { error: `Unhandled fixture route: ${url.pathname}` }, 500);
    });

    await page.goto(BASE_URL, { waitUntil: "domcontentloaded" });
    await page.locator("#card-101 .exam-card-main").waitFor();
    await expectPath(page, "/");
    assert.equal(await page.title(), "考试列表 · 蓝鲸助手");
    assert.equal(await page.locator('.app-tabs[aria-label="主导航"] .app-tab:visible').count(), 3);
    assert.equal(await page.locator('[data-home-tab="exams"][aria-current="page"]:visible').count(), 1);
    assert.ok(await elementContrast(page.locator('[data-home-tab="exams"]')) >= 4.5, "light active navigation contrast is too low");

    const examMenu = page.getByRole("button", { name: "试卷操作：Web parity fixture" });
    const abandonButton = page.getByRole("button", { name: "放弃考试：Web parity fixture" });
    await examMenu.focus();
    await page.keyboard.press("Enter");
    assert.equal(await examMenu.getAttribute("aria-expanded"), "true");
    await abandonButton.waitFor({ state: "visible" });
    assert.equal(await abandonButton.isVisible(), true);
    await examMenu.focus();
    await page.keyboard.press("Enter");
    assert.equal(await examMenu.getAttribute("aria-expanded"), "false");
    await abandonButton.waitFor({ state: "hidden" });
    assert.equal(await abandonButton.isVisible(), false);
    await page.evaluate(() => document.activeElement?.blur());

    const desktopRail = await page.locator(".app-rail").boundingBox();
    const desktopContent = await page.locator(".app-content").boundingBox();
    assert.ok(desktopRail && desktopContent && desktopRail.x + desktopRail.width <= desktopContent.x + 1, "desktop navigation is not left of content");
    const desktopTabBoxes = await page.locator(".app-tab:visible").evaluateAll((links) => links.map((link) => {
      const box = link.getBoundingClientRect();
      return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
    }));
    assert.ok(desktopTabBoxes[0].y < desktopTabBoxes[1].y && desktopTabBoxes[1].y < desktopTabBoxes[2].y, "desktop navigation is not vertical");
    assert.ok(Math.max(...desktopTabBoxes.map((box) => box.x)) - Math.min(...desktopTabBoxes.map((box) => box.x)) <= 1, "desktop navigation is not aligned");
    await page.screenshot({ path: "/tmp/lanjing-web-home-desktop.png", fullPage: true });

    delayNextExamList = true;
    await page.getByRole("button", { name: "刷新考试列表" }).click();
    await delayedExamStarted.promise;
    await page.locator('[data-home-tab="practice"]').click();
    await page.locator('[data-home-view="practice"].active').waitFor();
    await expectPath(page, "/practice");
    releaseDelayedExam.resolve();
    await page.evaluate(() => new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    }));
    await expectPath(page, "/practice");
    assert.equal(await page.locator('[data-home-view="practice"].active').count(), 1);
    assert.equal(await page.locator('[data-home-tab="practice"][aria-current="page"]:visible').count(), 1);

    await page.locator('[data-home-tab="profile"]').click();
    await page.locator('[data-home-view="profile"].active').waitFor();
    await expectPath(page, "/profile");
    await page.goBack();
    await page.locator('[data-home-view="practice"].active').waitFor();
    await expectPath(page, "/practice");

    await page.locator('[data-home-tab="profile"]').click();
    await page.locator('[data-theme-choice="dark"]').click();
    const profileAutoAdvance = page.locator('[data-home-view="profile"] [data-auto-advance]');
    assert.equal(await profileAutoAdvance.isChecked(), false);
    await profileAutoAdvance.check();
    const profileLanToggle = page.locator('[data-home-view="profile"] [data-lan-toggle]');
    assert.equal(await profileLanToggle.isChecked(), true);
    await profileLanToggle.uncheck();
    assert.equal(lanEnabledSetting, false);
    await profileLanToggle.check();
    assert.equal(lanEnabledSetting, true);

    const ccToggle = page.locator('[data-home-view="profile"] [data-cookiecloud-toggle]');
    const ccSyncButton = page.locator('[data-home-view="profile"] [data-cookiecloud-sync]');
    const ccServerInput = page.locator('[data-home-view="profile"] [data-cookiecloud-server]');
    const ccUuidInput = page.locator('[data-home-view="profile"] [data-cookiecloud-uuid]');
    const ccStatus = page.locator('[data-home-view="profile"] [data-cookiecloud-status]');
    assert.equal(await ccToggle.isChecked(), false);
    assert.ok(await ccSyncButton.isDisabled(), "sync button disabled while sync is off");
    assert.ok(await ccServerInput.isEnabled(), "inputs stay editable so config can be entered before enabling");
    assert.ok((await page.locator('[data-home-view="profile"] .cookiecloud-warn').textContent()).includes("加密"));
    // Enter config first (debounced save on blur), then enable and sync.
    await ccServerInput.fill("http://cc.example.com");
    await ccServerInput.blur();
    await ccUuidInput.fill("test-uuid");
    await ccUuidInput.blur();
    await ccToggle.check();
    // check() flips the native checkbox immediately; the enable round-trip
    // completing is what enables the sync button — wait for that signal.
    await page.waitForFunction(() => document.querySelector('[data-cookiecloud-sync]')?.disabled === false);
    await ccSyncButton.click();
    // The click only dispatches the event; the sync request and its status
    // update are async — wait for the UI result before asserting counters.
    await page.waitForFunction(() => (document.querySelector('[data-cookiecloud-status]')?.textContent || "").includes("同步完成"));
    assert.ok(cookieCloudSyncCalls >= 1);
    assert.equal(await page.evaluate(() => localStorage.getItem("theme")), "dark");
    assert.equal(await page.evaluate(() => localStorage.getItem("quiz.autoAdvanceOnCorrect")), "true");
    assert.equal(await page.title(), "我的 · 蓝鲸助手");
    assert.ok(await elementContrast(page.locator('[data-home-tab="profile"]')) >= 4.5, "dark active navigation contrast is too low");
    await page.screenshot({ path: "/tmp/lanjing-web-profile-desktop.png", fullPage: true });

    await page.reload({ waitUntil: "domcontentloaded" });
    await page.locator('[data-home-view="profile"].active').waitFor();
    await expectPath(page, "/profile");
    assert.equal(await page.locator('html[data-theme="dark"]').count(), 1);
    assert.equal(await page.locator('[data-theme-choice="dark"][aria-pressed="true"]').count(), 1);
    assert.equal(await profileAutoAdvance.isChecked(), true);
    assert.equal(await profileLanToggle.isChecked(), true);
    await page.locator('[data-theme-choice="light"]').click();
    assert.equal(examListAttempts, 2);

    await page.locator('[data-home-tab="practice"]').click();
    const practiceCta = page.getByRole("button", { name: "爬取题库" });
    // The gate is rendered after the (mocked) status round-trip; wait for it
    // before pressing Tab so focus lands on the CTA in the first pass.
    await practiceCta.waitFor({ state: "visible" });
    await page.keyboard.press("Tab");
    assert.equal(await practiceCta.evaluate((element) => element === document.activeElement), true);
    const ctaFocusStyle = await practiceCta.evaluate((element) => {
      const style = getComputedStyle(element);
      return { style: style.outlineStyle, width: parseFloat(style.outlineWidth) };
    });
    assert.equal(ctaFocusStyle.style, "solid");
    assert.ok(ctaFocusStyle.width >= 3, "practice CTA focus indicator is too thin");
    assert.ok(await elementContrast(practiceCta) >= 4.5, "practice CTA contrast is too low");
    // The crawl POST is unmocked here (500); the gate must stay put and the
    // exam list must not be touched by a failed crawl attempt.
    await practiceCta.click();
    await page.locator("[data-practice-start]").waitFor();
    await expectPath(page, "/practice");
    assert.equal(await page.locator("#homeRouteStatus").textContent(), "已打开练习");
    assert.equal(examListAttempts, 2, "a crawl attempt must not touch the exam list");
    await page.evaluate(() => document.activeElement?.blur());
    assert.deepEqual(
      await page.locator(".app-tab.active").evaluateAll((links) => links.map((link) => link.dataset.homeTab)),
      ["practice"],
    );

    await page.setViewportSize({ width: 390, height: 844 });
    const mobileRail = await page.locator(".app-rail").boundingBox();
    const mobileTabBoxes = await page.locator(".app-tab:visible").evaluateAll((links) => links.map((link) => {
      const box = link.getBoundingClientRect();
      return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
    }));
    assert.ok(mobileRail && Math.abs(mobileRail.y + mobileRail.height - 844) <= 1, "mobile navigation is not anchored to the bottom grid row");
    assert.ok(mobileTabBoxes[0].x < mobileTabBoxes[1].x && mobileTabBoxes[1].x < mobileTabBoxes[2].x, "mobile navigation is not horizontal");
    assert.ok(Math.max(...mobileTabBoxes.map((box) => box.y)) - Math.min(...mobileTabBoxes.map((box) => box.y)) <= 1, "mobile navigation is not aligned");
    await expectNoHorizontalOverflow(page, "390px home layout");
    await page.screenshot({ path: "/tmp/lanjing-web-home-mobile.png", fullPage: true });

    await page.setViewportSize({ width: 320, height: 568 });
    for (const tab of ["exams", "practice", "profile"]) {
      await page.locator(`[data-home-tab="${tab}"]`).click();
      await page.locator(`[data-home-view="${tab}"].active`).waitFor();
      await expectNoHorizontalOverflow(page, `320px ${tab} layout`);
    }
    const logoutButton = page.getByRole("button", { name: "退出登录" });
    await logoutButton.scrollIntoViewIfNeeded();
    const compactLogoutBox = await logoutButton.boundingBox();
    const compactRailBox = await page.locator(".app-rail").boundingBox();
    assert.ok(compactLogoutBox && compactRailBox && compactLogoutBox.y + compactLogoutBox.height <= compactRailBox.y, "profile action is hidden behind mobile navigation");
    await page.screenshot({ path: "/tmp/lanjing-web-profile-mobile.png", fullPage: true });

    await page.locator('[data-home-tab="exams"]').click();
    await page.setViewportSize({ width: 1440, height: 900 });
    const examButton = page.getByRole("button", { name: "打开试卷：Web parity fixture" });
    await examButton.focus();
    await page.keyboard.press("Enter");
    await page.locator('.opt-row[data-opt="A"]').waitFor();
    assert.equal(examEnterAttempts, 1);
    await page.goBack();
    await page.locator('[data-home-view="exams"].active').waitFor();
    await page.locator("#card-101 .exam-card-main").waitFor();
    await expectPath(page, "/");
    assert.equal(examListAttempts, 4);

    delayNextStatus = true;
    delayNextEnter = true;
    await page.goForward();
    await delayedStatusStarted.promise;
    await expectPath(page, "/quiz/101");
    assert.equal(await page.locator("#appPage.active").count(), 1);
    await page.locator("#card-101 .exam-card-main").click();
    await delayedEnterStarted.promise;
    releaseDelayedStatus.resolve();
    await delayedStatusServed.promise;
    await page.evaluate(() => new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    }));
    assert.equal(examEnterAttempts, 2, "a stale route response entered the exam again");
    releaseDelayedEnter.resolve();
    await page.locator('.opt-row[data-opt="A"]').waitFor();
    await expectPath(page, "/quiz/101");
    await page.locator("#questionTimerWrap:not(.paused)").waitFor();

    await page.goBack();
    await page.locator('[data-home-view="exams"].active').waitFor();
    await page.locator("#card-101 .exam-card-main").waitFor();
    assert.equal(examListAttempts, 5);
    await page.goForward();
    await page.locator('.opt-row[data-opt="A"]').waitFor();
    await expectPath(page, "/quiz/101");
    await page.locator("#questionTimerWrap:not(.paused)").waitFor();
    assert.equal(examEnterAttempts, 3);
    await page.locator('.opt-row[data-opt="A"]').click();
    await page.locator('.opt-row[data-opt="C"]').click();
    await page.locator("#confirmSelectionBtn").click();
    await firstAnswerStarted.promise;
    assert.equal(await page.locator("#submitExamBtn").isDisabled(), true);
    assert.match(await page.locator("#submitExamBtn").textContent(), /同步中/);
    releaseFirstAnswer.resolve();
    await page.locator(".sync-status.error").waitFor();

    assert.equal(answerBodies.length, 1);
    assert.deepEqual(answerBodies[0], { testId: "q1", testAns: "key1,key3,", correct: true });
    await page.getByRole("button", { name: "重新同步" }).click();
    await page.locator(".sync-status.error").waitFor({ state: "detached" });
    assert.equal(answerBodies.length, 2);

    await page.locator(".answer-dot").nth(1).click();
    await page.locator('.opt-row[data-opt="A"].correct').waitFor();
    await page.locator('.opt-row[data-opt="B"].wrong').waitFor();
    await page.locator(".btn-mark").focus();
    await page.keyboard.press("Enter");
    await page.locator(".btn-mark.marked").waitFor();
    await firstMarkStarted.promise;
    assert.equal(await page.locator("#submitExamBtn").isDisabled(), true);
    releaseFirstMark.resolve();
    await page.locator(".btn-mark:not(:disabled)").waitFor();
    assert.equal(markAttempts, 1);
    assert.equal(await page.locator('[data-auto-advance]:visible').count(), 0);
    assert.equal(await page.evaluate(() => localStorage.getItem("quiz.autoAdvanceOnCorrect")), "true");

    await page.reload({ waitUntil: "domcontentloaded" });
    await page.locator('.opt-row[data-opt="A"]').waitFor();
    assert.equal(await page.locator('[data-home-view="profile"] [data-auto-advance]').isChecked(), true);
    assert.equal(await page.evaluate(() => localStorage.getItem("quiz.autoAdvanceOnCorrect")), "true");
    await page.locator(".answer-dot").nth(1).click();
    await page.locator('.opt-row[data-opt="B"].wrong').waitFor();
    await page.locator("#explainBox").evaluate((element) => Promise.all(
      element.getAnimations({ subtree: true }).map((animation) => animation.finished.catch(() => {})),
    ));

    await page.screenshot({ path: "/tmp/lanjing-web-desktop.png", fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: "/tmp/lanjing-web-mobile.png", fullPage: true });
    let overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    assert.ok(overflow <= 0, `390px layout overflows by ${overflow}px`);

    await page.setViewportSize({ width: 320, height: 568 });
    await page.locator(".answer-dot").nth(2).click();
    await page.waitForTimeout(350); // let the question ease-in transition finish before measuring layout
    const compactOptions = page.locator(".opt-row.compact");
    assert.equal(await compactOptions.count(), 4);
    for (const option of await compactOptions.all()) {
      const box = await option.boundingBox();
      assert.ok(box && box.x >= 0 && box.x + box.width <= 320, "compact option is clipped at 320px");
    }
    for (const control of [page.locator(".btn-close"), page.locator("#questionTimerWrap"), page.locator(".quiz-header .btn-theme-toggle")]) {
      const box = await control.boundingBox();
      assert.ok(box && box.x >= 0 && box.x + box.width <= 320, "quiz header control is clipped at 320px");
    }
    overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    assert.ok(overflow <= 0, `320px layout overflows by ${overflow}px`);
    await page.screenshot({ path: "/tmp/lanjing-web-compact-320.png", fullPage: true });

    await page.setViewportSize({ width: 1440, height: 900 });
    page.once("dialog", (dialog) => dialog.accept());
    await page.locator("#submitExamBtn").click();
    await firstSubmitStarted.promise;
    await page.locator(".btn-close").click();
    await page.locator("#appPage.active").waitFor();
    await page.locator('[data-home-view="exams"].active').waitFor();
    await expectPath(page, "/");
    assert.equal(await page.locator('[data-home-tab="exams"][aria-current="page"]:visible').count(), 1);
    const hiddenProgress = await page.locator("#qProgress").textContent();
    await page.evaluate(() => {
      const target = document.querySelector('[data-home-view="exams"]');
      const start = new Event("touchstart", { bubbles: true });
      Object.defineProperty(start, "touches", { value: [{ clientX: 40, clientY: 100 }] });
      target.dispatchEvent(start);
      const end = new Event("touchend", { bubbles: true });
      Object.defineProperty(end, "changedTouches", { value: [{ clientX: 140, clientY: 100 }] });
      target.dispatchEvent(end);
    });
    assert.equal(await page.locator("#qProgress").textContent(), hiddenProgress);
    await page.locator("#card-101 .exam-card-main").click();
    await page.locator('.opt-row[data-opt="A"]').waitFor();
    releaseFirstSubmit.resolve();
    await firstSubmitServed.promise;
    await page.evaluate(() => new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    }));
    assert.equal(await page.getByRole("button", { name: "重新提交" }).count(), 0);
    assert.equal(await page.locator("#quizPage.active").count(), 1);
    assert.equal(await page.locator("#loginPage.active").count(), 0);
    assert.equal(await page.locator(".app-tabs:visible").count(), 0);
    assert.match(await page.locator("#qBlock").textContent(), /以下哪些选项属于正确集合/);

    page.once("dialog", (dialog) => dialog.accept());
    await page.locator("#submitExamBtn").click();
    await page.locator("#quizStatus.error").waitFor();
    assert.match(await page.locator("#quizStatus").textContent(), /考试未能结束/);
    await page.getByRole("button", { name: "重新提交" }).click();
    const score = page.locator("#quizScroll .num");
    await score.waitFor();
    assert.match(await score.textContent(), /^88\s*分$/);
    await page.screenshot({ path: "/tmp/lanjing-web-result.png", fullPage: true });
    assert.equal(await page.locator("#submitExamBtn").isDisabled(), true);
    assert.match(await page.locator("#submitExamBtn").textContent(), /已交卷/);
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("a");
    await page.keyboard.press("Enter");
    await score.waitFor();

    await page.setViewportSize({ width: 390, height: 844 });
    await expectNoHorizontalOverflow(page, "mobile result layout");
    await page.screenshot({ path: "/tmp/lanjing-web-result-mobile.png", fullPage: true });

    await page.getByRole("button", { name: "返回路线图" }).click();
    await page.locator('[data-home-view="exams"].active').waitFor();
    await page.locator("#card-101 .exam-card-main").waitFor();

    delayAuthStatus = true;
    rejectNextExamList = true;
    await page.evaluate(() => {
      history.pushState(null, "", "/practice");
      dispatchEvent(new PopStateEvent("popstate"));
    });
    await authStatusStarted.promise;
    await page.getByRole("button", { name: "刷新考试列表" }).click();
    await page.locator("#loginPage.active").waitFor();
    await expectPath(page, "/login");
    releaseAuthStatus.resolve();
    await authStatusServed.promise;
    await page.evaluate(() => new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    }));
    assert.equal(await page.locator("#loginPage.active").count(), 1);
    assert.equal(await page.locator("#appPage.active").count(), 0);
    await expectPath(page, "/login");

    await page.goto(BASE_URL, { waitUntil: "domcontentloaded" });
    await page.locator("#card-101 .exam-card-main").waitFor();
    await page.locator('[data-home-tab="profile"]').click();
    await page.setViewportSize({ width: 568, height: 320 });
    await page.getByRole("button", { name: "退出登录" }).scrollIntoViewIfNeeded();
    await page.getByRole("button", { name: "退出登录" }).click();
    await page.locator("#loginPage.active").waitFor();
    await expectPath(page, "/login");
    assert.equal(logoutAttempts, 1);
    assert.equal(await page.locator(".app-tabs:visible").count(), 0);
    const loginButton = page.locator("#loginPage .btn");
    await loginButton.scrollIntoViewIfNeeded();
    const loginButtonBox = await loginButton.boundingBox();
    assert.ok(loginButtonBox && loginButtonBox.y >= 0 && loginButtonBox.y + loginButtonBox.height <= 320, "login button is unreachable in landscape");
    await page.screenshot({ path: "/tmp/lanjing-web-login-landscape.png", fullPage: true });

    // Cloud-sync auto-login: the server imports a CookieCloud session
    // asynchronously at startup; a session that becomes available while the
    // login page is shown must route the app in without a manual refresh.
    loggedIn = true;
    await page.locator("#card-101 .exam-card-main").waitFor({ timeout: 15000 });
    await expectPath(page, "/");
    assert.equal(await page.locator('[data-home-tab="exams"][aria-current="page"]').count(), 1);
    // back to login for the remaining assertions
    await page.locator('[data-home-tab="profile"]').click();
    await page.getByRole("button", { name: "退出登录" }).click();
    await page.locator("#loginPage.active").waitFor();

    assert.equal(submitAttempts, 3);
    assert.deepEqual(pageErrors, []);
    await verifyPracticeOffline(browser);
    await verifyOfflineShell(browser);

    console.log(JSON.stringify({
      browser: chromeExecutable(),
      answerAttempts,
      submitAttempts,
      offlineShell: true,
      screenshots: [
        "/tmp/lanjing-web-desktop.png",
        "/tmp/lanjing-web-mobile.png",
        "/tmp/lanjing-web-compact-320.png",
        "/tmp/lanjing-web-home-desktop.png",
        "/tmp/lanjing-web-home-mobile.png",
        "/tmp/lanjing-web-profile-desktop.png",
        "/tmp/lanjing-web-profile-mobile.png",
        "/tmp/lanjing-web-result.png",
        "/tmp/lanjing-web-result-mobile.png",
        "/tmp/lanjing-web-login-landscape.png",
      ],
    }));
  } finally {
    if (browser) await browser.close();
    if (server.exitCode === null) server.kill("SIGTERM");
    await new Promise((resolve) => {
      if (server.exitCode !== null) return resolve();
      server.once("exit", resolve);
      setTimeout(resolve, 2000);
    });
    if (server.exitCode && server.exitCode !== 0 && server.exitCode !== null) {
      process.stderr.write(serverOutput);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
