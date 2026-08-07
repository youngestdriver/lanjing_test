"use strict";

// Question-bank sub-classifier CLI. Adds a `subCategory` field to every
// record in <bankDir>/*.jsonl based on question + analysis text (rule tables
// in lib/question-classifier.js). One-time .bak backups, atomic per-file
// rewrite, idempotent (rerunning produces byte-identical files).
//
// Usage: node scripts/classify-bank.js [--bank-dir <path>] [--dry-run]
//         [--no-backup] [--targets a,b,c]

const fs = require("node:fs");
const path = require("node:path");
const { TARGET_CATEGORIES, classifyBank } = require("../lib/question-classifier");

const USAGE = `用法: node scripts/classify-bank.js [选项]

选项:
  --bank-dir <path>  题库目录 (默认 apps/bank)
  --dry-run          只统计并打印，不写盘
  --no-backup        不创建 .bak 备份 (默认首次写盘前备份原文件)
  --targets a,b,c    目标分类 (默认 言语理解,数字运算,逻辑推理,资料分析,特有题型)
  -h, --help         显示本帮助`;

function parseArgs(argv) {
  const opts = { bankDir: null, dryRun: false, noBackup: false, targets: null };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = () => argv[++i];
    switch (flag) {
      case "--bank-dir": opts.bankDir = value(); break;
      case "--dry-run": opts.dryRun = true; break;
      case "--no-backup": opts.noBackup = true; break;
      case "--targets": opts.targets = value().split(",").map((s) => s.trim()).filter(Boolean); break;
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

function main() {
  const opts = parseArgs(process.argv.slice(2));
  // The bank lives in its own top-level directory (apps/bank), independent of
  // the web app's private .local state (session etc.).
  const bankDir = path.resolve(opts.bankDir || path.join(__dirname, "..", "..", "bank"));
  const targets = opts.targets || TARGET_CATEGORIES;

  const result = classifyBank(bankDir, targets);
  if (!result.total) {
    console.error(`题库目录没有可分类的记录: ${bankDir}`);
    process.exit(1);
  }

  // Sorted per-(category|subCategory) count table.
  console.log(`== 子分类统计 (${result.total} 题, 变更 ${result.changed}) ==`);
  let currentCategory = null;
  let categoryTotal = 0;
  const categoryOthers = {};
  for (const key of Object.keys(result.byClass).sort()) {
    const [category, sub] = key.split("|");
    if (category !== currentCategory) {
      if (currentCategory) {
        const other = categoryOthers[currentCategory] || 0;
        console.log(`   ── ${currentCategory} 小计 ${categoryTotal} (其他 ${other} 题, ${(100 * other / categoryTotal).toFixed(1)}%)`);
      }
      currentCategory = category;
      categoryTotal = 0;
      console.log(`\n${category}`);
    }
    categoryTotal += result.byClass[key];
    if (sub === "其他") categoryOthers[category] = result.byClass[key];
    console.log(`  ${sub}: ${result.byClass[key]}`);
  }
  if (currentCategory) {
    const other = categoryOthers[currentCategory] || 0;
    console.log(`   ── ${currentCategory} 小计 ${categoryTotal} (其他 ${other} 题, ${(100 * other / categoryTotal).toFixed(1)}%)`);
  }
  const totalOthers = Object.values(categoryOthers).reduce((a, b) => a + b, 0);
  console.log(`\n总计: ${result.total} 题, "其他" ${totalOthers} 题 (${(100 * totalOthers / result.total).toFixed(1)}%)`);

  if (result.others.length) {
    console.log("\n其他样本 (≤20):");
    for (const o of result.others) {
      console.log(`  [${o.category}|${o.section}] ${o.question.slice(0, 60)}`);
    }
  }

  if (opts.dryRun) {
    console.log("\n(dry-run，未写盘)");
    return;
  }

  // Rewrite each category file: one-time .bak, atomic tmp+rename.
  fs.mkdirSync(bankDir, { recursive: true, mode: 0o700 });
  const backups = opts.noBackup ? [] : [];
  for (const target of Object.keys(result.fileLines)) {
    const file = path.join(bankDir, target + ".jsonl");
    const bak = file + ".bak";
    if (!opts.noBackup && !fs.existsSync(bak)) {
      fs.copyFileSync(file, bak);
      backups.push(bak);
    }
    const tmp = file + ".tmp";
    fs.writeFileSync(tmp, result.fileLines[target].join("\n") + "\n", { encoding: "utf8", mode: 0o600 });
    fs.renameSync(tmp, file);
  }
  if (backups.length) console.log(`\n已备份原文件: ${backups.join(", ")}`);
  console.log("已写入 subCategory (共 " + Object.keys(result.fileLines).length + " 个文件)");
}

main();
