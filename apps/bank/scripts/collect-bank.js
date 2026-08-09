"use strict";

// Question-bank collector CLI. Talks to the upstream platform directly via
// lib/upstream.js (its own cookie jar, login and session file — independent
// of the web app), reuses the saved session or prompts for credentials when
// running interactively, then drives the collection loop.
//
// Usage: node scripts/collect-bank.js [--exam <id>] [--max-rounds N]
//         [--idle-limit N] [--round-delay ms] [--bank-dir <path>]
//         [--targets a,b,c]
//
// Data lands in apps/bank/data/ (gitignored): one JSONL file per category,
// meta.json for resume, session_cookies.txt for the login session. Any
// interrupted run continues where it left off when rerun on the same bank
// dir.
//
// The password is prompted at runtime and never persisted; enter/submit write
// real (abandoned) attempt records on the upstream account.

const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");
const { createUpstreamApi } = require("../lib/upstream");
const { runCollection, TARGET_CATEGORIES } = require("../lib/question-bank");

const USAGE = `用法: node scripts/collect-bank.js [选项]

选项:
  --exam <id>       只收集指定考试 (可强制处理 wfs=0 的进行中卷)
  --max-rounds N    最大轮数上限 (默认 200)
  --idle-limit N    连续 N 轮无新题即停止 (默认 3)
  --round-delay ms  每轮之间的等待 (默认 1500)
  --bank-dir <path> 题库输出目录 (默认 apps/bank/data)
  --targets a,b,c   目标分类 (默认 言语理解,数字运算,逻辑推理,资料分析,特有题型)
  --skip-in-progress 跳过进行中的作答 (默认会只读收集用户进行中的卷，不提交)
  --refresh         目标分类的 jsonl 改名 .bak 并清空续接状态，重新爬取全部试卷
                    (记录格式升级时用，例如资料分析新增 stem 材料字段)
  -h, --help        显示本帮助`;

function parseArgs(argv) {
  const opts = { exam: null, maxRounds: 200, idleLimit: 3, roundDelay: 1500, bankDir: null, targets: null, skipInProgress: false, refresh: false };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = () => argv[++i];
    switch (flag) {
      case "--exam": opts.exam = value(); break;
      case "--max-rounds": opts.maxRounds = Number(value()); break;
      case "--idle-limit": opts.idleLimit = Number(value()); break;
      case "--round-delay": opts.roundDelay = Number(value()); break;
      case "--bank-dir": opts.bankDir = value(); break;
      case "--targets": opts.targets = value().split(",").map((s) => s.trim()).filter(Boolean); break;
      case "--skip-in-progress": opts.skipInProgress = true; break;
      case "--refresh": opts.refresh = true; break;
      case "-h":
      case "--help":
        console.log(USAGE);
        process.exit(0);
      default:
        console.error(`未知参数: ${flag}\n${USAGE}`);
        process.exit(1);
    }
  }
  return opts;
}

function prompt(query) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(query, (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

/** Password prompt that masks echoed input (readline's internal echo hook). */
function promptHidden(query) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    rl.question(query, (answer) => {
      process.stdout.write("\n");
      rl.close();
      resolve(answer);
    });
    const write = rl._writeToOutput.bind(rl);
    let promptShown = false;
    rl._writeToOutput = (chunk) => {
      if (!promptShown) {
        promptShown = true;
        write(chunk); // the query itself
      } else {
        write("*"); // mask user keystrokes
      }
    };
  });
}

const STOP_REASONS = {
  exhausted: "所有可进入的考试均已收集完（连续无新题）",
  idle: "连续多轮无新题，停止",
  maxRounds: "达到轮次上限",
  abort: "手动中断（当前轮已完成）",
  auth: "会话失效，停止（重新登录后重跑即可续接）",
  error: "连续失败过多，停止",
};

async function ensureLoggedIn(api) {
  const status = await api.status();
  if (status.loggedIn) {
    console.log("会话有效，复用已登录会话");
    return;
  }
  // Headless runs: credentials via environment. They exist only in this
  // process (never written to disk); the resulting session is saved exactly
  // as the app normally does.
  const envPhone = process.env.LANJING_PHONE;
  const envPassword = process.env.LANJING_PASSWORD;
  if (envPhone && envPassword) {
    const login = await api.login(envPhone, envPassword);
    if (!login.success) throw new Error(`登录失败: ${login.desc || "未知错误"}`);
    console.log("登录成功，开始收集");
    return;
  }
  if (!process.stdin.isTTY) {
    throw new Error(
      "没有可用会话，且当前不是交互式终端。请先用 LANJING_PHONE/LANJING_PASSWORD 环境变量提供凭据，"
      + "或用本脚本登录一次（会话保存在 <bank-dir>/session_cookies.txt），再重跑本脚本",
    );
  }
  const phone = await prompt("手机号: ");
  const password = await promptHidden("密码: ");
  const login = await api.login(phone, password);
  if (!login.success) throw new Error(`登录失败: ${login.desc || "未知错误"}`);
  console.log("登录成功，开始收集");
}

// --refresh: the collector dedupes by _id forever, so a record-format change
// (e.g. 资料分析 gaining the stem material field) can never reach existing
// records. Rename the target category files to .bak and reset the resume
// state so every paper is re-entered from scratch; the .bak keeps the old
// data until the refreshed run completes.
function applyRefresh(bankDir, targets) {
  const metaFile = path.join(bankDir, "meta.json");
  let meta = null;
  try { meta = JSON.parse(fs.readFileSync(metaFile, "utf8")); } catch {}
  for (const target of targets) {
    const file = path.join(bankDir, `${target}.jsonl`);
    if (!fs.existsSync(file)) continue;
    fs.renameSync(file, file + ".bak");
    console.log(`[refresh] ${target}.jsonl → ${target}.jsonl.bak`);
  }
  if (meta) {
    meta.examState = {};
    meta.counts = {};
    meta.round = 0;
    meta.stats = { totalRounds: 0, contentDupes: 0, answerUnknown: 0, consecutiveFailures: 0 };
    fs.writeFileSync(metaFile, JSON.stringify(meta, null, 2) + "\n", { encoding: "utf8", mode: 0o600 });
    console.log("[refresh] meta.json 续接状态已清空，将重新进入全部试卷");
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  // The bank lives in its own top-level directory (apps/bank): data and the
  // collector's own session live under apps/bank/data/, independent of the
  // web app's .local state.
  const bankDir = path.resolve(opts.bankDir || path.join(__dirname, "..", "data"));
  const targets = opts.targets || TARGET_CATEGORIES;

  if (opts.refresh) {
    applyRefresh(bankDir, targets);
  }

  const api = createUpstreamApi({ sessionFile: path.join(bankDir, "session_cookies.txt") });

  const controller = new AbortController();
  let interrupted = false;
  process.on("SIGINT", () => {
    if (interrupted) {
      console.log("\n强制退出");
      process.exit(130);
    }
    interrupted = true;
    console.log("\n收到 Ctrl+C：完成当前轮（含提交）后停止；再次 Ctrl+C 立即退出");
    controller.abort();
  });

  try {
    await ensureLoggedIn(api);
  } catch (err) {
    console.error(`\n无法开始收集: ${err.message}`);
    process.exit(1);
  }

  console.log(`题库目录: ${bankDir}`);
  console.log(`目标分类: ${targets.join(", ")}`);
  console.log("按 Ctrl+C 可在完成当前轮后停止（数据已落盘，重跑可续接）\n");

  const summary = await runCollection(api, {
    bankDir,
    targets,
    maxRounds: opts.maxRounds,
    idleLimit: opts.idleLimit,
    roundDelayMs: opts.roundDelay,
    singleExamId: opts.exam,
    collectInProgress: !opts.skipInProgress,
    signal: controller.signal,
  });

  console.log(`\n=== 收集结束：${STOP_REASONS[summary.stoppedBy] || summary.stoppedBy} ===`);
  let total = 0;
  for (const [category, count] of Object.entries(summary.countsByCategory)) {
    console.log(`  ${category}: ${count}`);
    total += count;
  }
  console.log(`  合计: ${total} 题（重复内容 ${summary.stats.contentDupes}，答案未知 ${summary.stats.answerUnknown}）`);
  console.log(`  共 ${summary.round} 轮，处理 ${summary.examsProcessed} 份考试`);
  console.log(`  数据位置: ${bankDir}`);

  process.exit(["auth", "error"].includes(summary.stoppedBy) ? 1 : 0);
}

main().catch((err) => {
  console.error(`收集器异常退出: ${err.message}`);
  process.exit(1);
});
