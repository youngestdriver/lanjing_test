"use strict";

// 打包「完整题库快照」zip（离线分发包，供 iOS 导入题库用）。
// 零网络：只读本地 <bankDir>/*.jsonl 与 <bankDir>/images/。
//
// Usage: node scripts/snapshot-bank.js [--bank-dir <path>] [--out <path.zip>] [--report]
//   --report 只统计不落盘：引用图片数 / 已覆盖 / 缺失 / 题目数 / 总字节 / 各分类题数，
//            退出码 0=全部覆盖，1=有缺失。

const fs = require("node:fs");
const path = require("node:path");
const { buildManifest, writeSnapshotZip, verifySnapshotZip } = require("../lib/snapshot");

const USAGE = `用法: node scripts/snapshot-bank.js [选项]

选项:
  --bank-dir <path>  题库目录 (默认 apps/bank/data)
  --out <path.zip>   产物路径 (默认 <bank-dir>/lanjing-bank-<YYYYMMDD>.zip)
  --report           只打印统计不落盘
  -h, --help         显示本帮助`;

function parseArgs(argv) {
  const opts = { bankDir: null, out: null, report: false };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = () => argv[++i];
    switch (flag) {
      case "--bank-dir": opts.bankDir = value(); break;
      case "--out": opts.out = value(); break;
      case "--report": opts.report = true; break;
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

function formatBytes(n) {
  if (n >= 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
  return `${(n / 1024).toFixed(0)} KB`;
}

/** 本地日期 YYYYMMDD（产物名用，不涉及时区换算）。 */
function dateStamp(date = new Date()) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}`;
}

function printCounts(counts) {
  console.log(`题目: ${counts.questions} 题`);
  for (const [category, n] of Object.entries(counts.byCategory)) {
    console.log(`  ${category}  ${n} 题`);
  }
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const bankDir = path.resolve(opts.bankDir || path.join(__dirname, "..", "data"));
  const outPath = path.resolve(opts.out || path.join(bankDir, `lanjing-bank-${dateStamp()}.zip`));

  if (opts.report) {
    const manifest = buildManifest(bankDir); // 缺图会抛错，走下面的 catch
    const imageBytes = manifest.images.reduce((sum, img) => sum + img.bytes, 0);
    const mimes = new Map();
    for (const img of manifest.images) mimes.set(img.mime, (mimes.get(img.mime) || 0) + 1);
    console.log(`== 题库快照报告 ==`);
    console.log(`目录: ${bankDir}`);
    printCounts(manifest.counts);
    console.log(`引用图片: ${manifest.counts.images}`);
    console.log(`已覆盖:   ${manifest.counts.images}`);
    console.log(`缺失:     0`);
    console.log(`总字节:   ${imageBytes} (${formatBytes(imageBytes)})`);
    console.log(`类型:     ${[...mimes].sort().map(([mime, n]) => `${mime} ${n}`).join(", ")}`);
    return 0;
  }

  console.log(`== 构建题库快照 ==`);
  console.log(`题库目录: ${bankDir}`);
  const manifest = buildManifest(bankDir);
  printCounts(manifest.counts);
  const imageBytes = manifest.images.reduce((sum, img) => sum + img.bytes, 0);
  console.log(`图片: ${manifest.counts.images} 张, ${formatBytes(imageBytes)}`);

  const written = writeSnapshotZip(bankDir, outPath, manifest);
  console.log(`产物: ${outPath}`);
  console.log(`条目: ${written.entries}`);

  const size = fs.statSync(outPath).size;
  console.log(`大小: ${size} 字节 (${formatBytes(size)})`);

  const result = verifySnapshotZip(outPath);
  if (!result.ok) {
    console.error(`自检失败: ${result.problems.length} 个问题`);
    for (const problem of result.problems.slice(0, 20)) console.error(`  ${problem}`);
    return 1;
  }
  console.log(`自检: ok（${result.entries} 条目，${formatBytes(result.bytes)}，CRC32 与 sha256 全部一致）`);
  return 0;
}

try {
  process.exit(main());
} catch (err) {
  // buildManifest 的错误信息里已经带了缺失清单（前 10 个 + 总数），直接打印即可。
  if (err.missing) console.error(`图片缺失: ${err.message}`);
  else if (err.missingCategories) console.error(err.message);
  else console.error(`快照打包失败: ${err.message}`);
  process.exit(1);
}
