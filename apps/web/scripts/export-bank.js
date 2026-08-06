"use strict";

// Question-bank Markdown exporter. Reads <bankDir>/*.jsonl (the collected and
// sub-classified bank) and writes one Markdown file per (category, subCategory)
// with readable plain-text 题干/选项/答案/解析, e.g.:
//
//   <out>/言语理解-成语辨析.md
//   <out>/数字运算-行程问题.md
//
// Usage: node scripts/export-bank.js [--bank-dir <path>] [--out <path>]
//         [--targets a,b,c]

const path = require("node:path");
const { TARGET_CATEGORIES, exportBank } = require("../lib/bank-export");

const USAGE = `用法: node scripts/export-bank.js [选项]

选项:
  --bank-dir <path>  题库目录 (默认 apps/bank)
  --out <path>       导出目录 (默认 <bank-dir>/export)
  --targets a,b,c    目标分类 (默认 5 个机考分类)
  -h, --help         显示本帮助`;

function parseArgs(argv) {
  const opts = { bankDir: null, out: null, targets: null };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = () => argv[++i];
    switch (flag) {
      case "--bank-dir": opts.bankDir = value(); break;
      case "--out": opts.out = value(); break;
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
  const outDir = path.resolve(opts.out || path.join(bankDir, "export"));
  const targets = opts.targets || TARGET_CATEGORIES;

  const { total, files } = exportBank(bankDir, outDir, targets);
  if (!total) {
    console.error(`题库目录没有可导出的记录: ${bankDir}`);
    process.exit(1);
  }
  console.log(`== 导出完成：${total} 题 → ${outDir} ==`);
  let mdSize = 0;
  for (const f of files) {
    console.log(`  ${f.name}  ${f.count} 题  ${(f.size / 1024).toFixed(0)} KB`);
    mdSize += f.size;
  }
  console.log(`共 ${files.length} 个 Markdown 文件，${(mdSize / 1024 / 1024).toFixed(1)} MB`);
}

main();
