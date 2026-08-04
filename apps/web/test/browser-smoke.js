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

async function main() {
  const server = spawn(process.execPath, ["server.js"], {
    cwd: WEB_DIR,
    env: { ...process.env, PORT: String(PORT) },
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
      { questionsId: "q1", uuId: "u1", num: 1, section: "综合", state: "unanswered", marked: false },
      { questionsId: "q2", uuId: "u2", num: 2, section: "综合", state: "error", marked: false },
      { questionsId: "q3", uuId: "u3", num: 3, section: "综合", state: "unanswered", marked: false },
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
    let loggedIn = true;
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
      if (url.pathname === "/api/status") return json(route, { loggedIn, hasSavedSession: loggedIn });
      if (url.pathname === "/api/exams") {
        return json(route, {
          total: 1,
          styles: { 1: "机考题库" },
          exams: [{ id: 101, name: "Web parity fixture", style: "机考题库", practiceMode: 2, totalTime: 30, wfs: 0 }],
        });
      }
      if (url.pathname === "/api/exams/101/enter") {
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
      if (url.pathname === "/api/logout") return json(route, { success: true });
      return json(route, { error: `Unhandled fixture route: ${url.pathname}` }, 500);
    });

    await page.goto(BASE_URL, { waitUntil: "domcontentloaded" });
    await page.locator(".exam-card-inner").click();
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
    const autoAdvanceControl = page.locator('[data-auto-advance]:visible');
    assert.equal(await autoAdvanceControl.isChecked(), false);
    await autoAdvanceControl.check();
    assert.equal(await page.evaluate(() => localStorage.getItem("quiz.autoAdvanceOnCorrect")), "true");

    await page.reload({ waitUntil: "domcontentloaded" });
    await page.locator('.opt-row[data-opt="A"]').waitFor();
    assert.equal(await page.locator('[data-auto-advance]:visible').isChecked(), true);
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
    await page.locator("#examListPage.active").waitFor();
    const hiddenProgress = await page.locator("#qProgress").textContent();
    await page.evaluate(() => {
      const target = document.querySelector("#examListPage");
      const start = new Event("touchstart", { bubbles: true });
      Object.defineProperty(start, "touches", { value: [{ clientX: 40, clientY: 100 }] });
      target.dispatchEvent(start);
      const end = new Event("touchend", { bubbles: true });
      Object.defineProperty(end, "changedTouches", { value: [{ clientX: 140, clientY: 100 }] });
      target.dispatchEvent(end);
    });
    assert.equal(await page.locator("#qProgress").textContent(), hiddenProgress);
    await page.locator(".exam-card-inner").click();
    await page.locator('.opt-row[data-opt="A"]').waitFor();
    releaseFirstSubmit.resolve();
    await firstSubmitServed.promise;
    await page.evaluate(() => new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    }));
    assert.equal(await page.getByRole("button", { name: "重新提交" }).count(), 0);
    assert.equal(await page.locator("#quizPage.active").count(), 1);
    assert.equal(await page.locator("#loginPage.active").count(), 0);
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
    overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    assert.ok(overflow <= 0, `mobile result layout overflows by ${overflow}px`);
    await page.screenshot({ path: "/tmp/lanjing-web-result-mobile.png", fullPage: true });

    loggedIn = false;
    await page.setViewportSize({ width: 568, height: 320 });
    await page.goto(`${BASE_URL}/login`, { waitUntil: "domcontentloaded" });
    const loginButton = page.locator("#loginPage .btn");
    await loginButton.scrollIntoViewIfNeeded();
    const loginButtonBox = await loginButton.boundingBox();
    assert.ok(loginButtonBox && loginButtonBox.y >= 0 && loginButtonBox.y + loginButtonBox.height <= 320, "login button is unreachable in landscape");
    await page.screenshot({ path: "/tmp/lanjing-web-login-landscape.png", fullPage: true });

    assert.equal(submitAttempts, 3);
    assert.deepEqual(pageErrors, []);

    console.log(JSON.stringify({
      browser: chromeExecutable(),
      answerAttempts,
      submitAttempts,
      screenshots: [
        "/tmp/lanjing-web-desktop.png",
        "/tmp/lanjing-web-mobile.png",
        "/tmp/lanjing-web-compact-320.png",
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
