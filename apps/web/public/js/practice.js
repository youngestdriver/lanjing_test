"use strict";

// 练习页(专项训练):本地题库四级视图(未爬取/爬取中/大类/题型细分/答题)。
// 题目数据一次 fetch 后全在内存,答题页零网络;判分/洗牌/分组由
// PracticeCore 提供。爬取进度走 SSE;会话过期时 API 返回 401 由 api()
// 统一跳登录(与 app.js 的全局 api() 行为一致)。

const Practice = (() => {
  const CATEGORY_ORDER = ["言语理解", "数字运算", "逻辑推理", "资料分析", "特有题型"];
  let view = "start"; // start | crawl | categories | subcategories | quiz
  let category = null;
  let subCategory = null;
  let groups = [];            // [{name, questions}]
  let questions = [];
  let index = 0;
  let selected = new Set();
  let revealed = null;        // { selected:Set, correct:bool|null }
  let right = 0;
  let wrong = 0;
  let eventSource = null;
  // 最近一次 /api/practice/status 结果。refreshStatus 写入,renderCategories
  // 读取(分类列表依赖 meta.counts,与窗口刷新后的状态保持一致)。
  let status = null;
  const root = () => document.getElementById("practiceRoot");
  const bankStatus = () => document.querySelector("[data-practice-bank-status]");

  function shuffleEnabled() {
    return localStorage.getItem(PracticeCore.shuffleKey(category)) === "true";
  }

  function setShuffleEnabled(enabled) {
    localStorage.setItem(PracticeCore.shuffleKey(category), String(enabled));
  }

  function esc(html) {
    return String(html).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function render() {
    const el = root();
    if (!el) return;
    const apiUrl = (path) => path; // local same-origin
    if (view === "start" || view === "crawl") {
      renderBankGate(el);
    } else if (view === "categories") {
      renderCategories(el);
    } else if (view === "subcategories") {
      renderSubcategories(el);
    } else {
      renderQuiz(el);
    }
  }

  async function refreshStatus() {
    status = await api("/api/practice/status");
    const meta = status.meta;
    const counts = meta ? meta.counts : {};
    if (status.isPopulated && view === "start") view = "categories";
    if (bankStatus()) {
      if (!status.isPopulated) bankStatus().textContent = "未爬取(进入练习页开始)";
      else bankStatus().textContent = `已爬取 ${Object.values(counts).reduce((a, b) => a + b, 0)} 题 · 最近 ${(meta.lastRun || "").slice(0, 10)}`;
    }
    if (view !== "quiz") render();
  }

  function renderBankGate(el) {
    if (view === "crawl") {
      el.innerHTML = `<div class="practice-center">
        <p class="practice-progress" data-practice-progress>正在爬取题库…</p>
        <p class="practice-paper" data-practice-paper></p>
      </div>`;
      return;
    }
    el.innerHTML = `<div class="practice-center empty-home-view">
      <div class="empty-home-symbol" aria-hidden="true"></div>
      <h2>开始练习</h2>
      <p>首次使用将直连蓝鲸平台爬取全部机考题库,之后完全离线刷题</p>
      <button type="button" class="cta-btn" data-practice-start onclick="PracticeStart()">爬取题库</button>
      <p class="practice-hint" data-practice-hint></p>
    </div>`;
  }

  function renderCategories(el) {
    const currentStatus = status || { meta: { counts: {} } };
    const counts = (currentStatus.meta && currentStatus.meta.counts) || {};
    const rows = CATEGORY_ORDER.filter((name) => counts[name]).map((name) => `
      <button type="button" class="practice-category" data-practice-category="${esc(name)}" onclick="PracticeOpenCategory('${esc(name)}')">
        <span class="practice-category-name">${esc(name)}</span>
        <span class="practice-category-count">${counts[name]} 题</span>
      </button>`).join("");
    el.innerHTML = `<div class="practice-categories">${rows || "<p>题库为空</p>"}</div>`;
  }

  async function openCategory(name) {
    category = name;
    const text = await (await fetch(`/api/practice/categories/${encodeURIComponent(name)}`)).text();
    const questionsList = PracticeCore.parseJSONL(text);
    groups = PracticeCore.groupBySubcategory(questionsList);
    view = "subcategories";
    render();
  }

  function renderSubcategories(el) {
    const rows = groups.map((group, i) => `
      <button type="button" class="practice-subcategory" data-practice-subcategory onclick="PracticeStartSession(${i})">
        <span class="practice-category-name">${esc(group.name)}</span>
        <span class="practice-category-count">${group.questions.length} 题</span>
      </button>`).join("");
    el.innerHTML = `<div class="practice-subheader">
        <button type="button" class="btn-style" onclick="PracticeBackToCategories()">← ${esc(category)}</button>
      </div>
      <div class="practice-categories">${rows}</div>`;
  }

  function startSession(groupIndex) {
    const group = groups[groupIndex];
    subCategory = group.name;
    questions = shuffleEnabled() ? PracticeCore.shuffledKeepingGroups(group.questions, BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER))) : group.questions;
    index = 0;
    selected = new Set();
    revealed = null;
    right = 0;
    wrong = 0;
    view = "quiz";
    render();
  }

  function renderQuiz(el) {
    const question = questions[index];
    if (!question) {
      el.innerHTML = `<div class="practice-center">
        <h2>练习完成</h2>
        <p>答对 ${right} 题 · 答错 ${wrong} 题 · 共 ${questions.length} 题</p>
        <button type="button" class="cta-btn" onclick="PracticeBackToSubcategories()">返回题型列表</button>
      </div>`;
      return;
    }
    const isMulti = Array.isArray(question.answer) && question.answer.length > 1;
    const stemHtml = question.stem ? `<div class="q-stem">${question.stem}</div>` : "";
    const optionRows = ["A", "B", "C", "D"].map((letter, i) => {
      const optionText = question.options[i] || "";
      const cls = [];
      if (revealed) {
        const isCorrect = (question.answer == null || question.answer === "" || question.answer === [] )
          ? false : (Array.isArray(question.answer) ? question.answer.includes(letter) : question.answer === letter);
        const isSelected = selected.has(letter);
        if (isCorrect) cls.push("correct");
        else if (isSelected) cls.push("wrong");
        if (isSelected) cls.push("selected");
      } else if (selected.has(letter)) {
        cls.push("selected");
      }
      return `<button type="button" class="practice-option ${cls.join(" ")}" data-practice-option="${letter}" onclick="PracticeTapOption('${letter}')">
        <span class="practice-option-letter">${letter}</span>
        <span>${optionText}</span>
      </button>`;
    }).join("");
    const badge = !revealed && isMulti ? "<span class=\"practice-badge\">多选</span>"
      : !revealed && (question.answer == null || question.answer === "") ? "<span class=\"practice-badge\">无答案</span>" : "";
    const resultHtml = revealed ? `<div class="practice-result" data-practice-result>
      ${revealed.correct === null ? "<p>无标准答案</p>" : revealed.correct ? "<p>答对 ✓</p>" : "<p>答错 ✗</p>"}
      ${question.analysis ? `<div class="practice-analysis">${question.analysis}</div>` : ""}
      <button type="button" class="cta-btn" data-practice-next onclick="PracticeNext()">${index + 1 >= questions.length ? "完成" : "下一题"}</button>
    </div>` : "";
    el.innerHTML = `<div class="practice-quiz" data-practice-question>
      <div class="practice-quiz-top">
        <span class="practice-count">第 ${index + 1}/${questions.length} 题</span>
        <span class="practice-stats">答对 ${right} · 答错 ${wrong}</span>
        <label class="switch-control" title="随机顺序">
          <input type="checkbox" data-practice-shuffle ${shuffleEnabled() ? "checked" : ""} onchange="PracticeToggleShuffle(this.checked)">
          <span aria-hidden="true"></span>
          <span class="sr-only">随机</span>
        </label>
      </div>
      ${badge}
      ${stemHtml}
      <div class="q-block">${question.question}</div>
      <div class="practice-options">${optionRows}</div>
      ${resultHtml}
    </div>`;
  }

  function tapOption(letter) {
    const question = questions[index];
    if (revealed || !question) return;
    if (Array.isArray(question.answer) && question.answer.length > 1) {
      if (selected.has(letter)) selected.delete(letter);
      else selected.add(letter);
      render();
      return;
    }
    selected = new Set([letter]);
    const correct = PracticeCore.grade(selected, question);
    revealed = { selected, correct };
    if (correct === true) right += 1;
    else if (correct === false) wrong += 1;
    render();
  }

  function nextQuestion() {
    if (!revealed) return;
    index += 1;
    selected = new Set();
    revealed = null;
    render();
  }

  function startCrawl() {
    api("/api/practice/crawl", { method: "POST" }).then((result) => {
      if (result.error) return;
      view = "crawl";
      render();
      openEvents();
    });
  }

  function updateBank() {
    api("/api/practice/update", { method: "POST" }).then((result) => {
      if (result.error) return;
      view = "crawl";
      render();
      openEvents();
    });
  }

  function openEvents() {
    if (eventSource) eventSource.close();
    eventSource = new EventSource("/api/practice/events");
    eventSource.onmessage = (event) => {
      const data = JSON.parse(event.data);
      const progress = root()?.querySelector("[data-practice-progress]");
      const paper = root()?.querySelector("[data-practice-paper]");
      if (data.type === "progress" && progress) {
        progress.textContent = `正在爬取题库（${data.index}/${data.total}）`;
        if (paper) paper.textContent = data.paperName || "";
      } else if (data.type === "done") {
        eventSource.close();
        eventSource = null;
        view = "categories";
        refreshStatus();
      } else if (data.type === "error") {
        eventSource.close();
        eventSource = null;
        view = "start";
        render();
      }
    };
  }

  function deleteBank() {
    if (!window.confirm("删除本地题库后,再次进入练习页会重新爬取全部试卷。确定删除?")) return;
    api("/api/practice/delete", { method: "POST" }).then(() => {
      view = "start";
      render();
      refreshStatus();
    });
  }

  function downloadLog() {
    window.location.href = "/api/practice/log";
  }

  // 全局钩子(与 app.js 的内联 onclick 约定一致)
  window.PracticeStart = startCrawl;
  window.PracticeOpenCategory = openCategory;
  window.PracticeStartSession = startSession;
  window.PracticeTapOption = tapOption;
  window.PracticeNext = nextQuestion;
  window.PracticeToggleShuffle = (enabled) => { setShuffleEnabled(enabled); render(); };
  window.PracticeBackToCategories = () => { view = "categories"; render(); };
  window.PracticeBackToSubcategories = () => { view = "subcategories"; render(); };
  window.practiceUpdateBank = updateBank;
  window.practiceDeleteBank = deleteBank;
  window.practiceDownloadLog = downloadLog;
  window.practiceRefreshBankStatus = refreshStatus;

  return { refreshStatus, render };
})();

// app.js 在激活 practice tab 时调用;也挂到 window 供内联使用。
window.PracticeRefresh = () => { Practice.refreshStatus(); };
