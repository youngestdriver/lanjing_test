"use strict";

// Question-bank Markdown exporter. Reads <bankDir>/*.jsonl (the collected and
// sub-classified bank) and writes one Markdown file per (category, subCategory)
// with readable plain-text 题干/选项/答案/解析 and the formula images preserved:
// images are downloaded once into <out>/images/ and referenced locally
// (reruns skip existing files via the manifest; failed downloads fall back to
// the remote URL).
//
// Usage: node scripts/export-bank.js [--bank-dir <path>] [--out <path>]
//         [--targets a,b,c] [--no-images]

const path = require("node:path");
const { TARGET_CATEGORIES, exportBank, collectImageSources, downloadImages } = require("../lib/bank-export");

const USAGE = `用法: node scripts/export-bank.js [选项]

选项:
  --bank-dir <path>  题库目录 (默认 apps/bank/data)
  --out <path>       导出目录 (默认 <bank-dir>/export)
  --targets a,b,c    目标分类 (默认 5 个机考分类)
  --no-images        不下载图片 (Markdown 里直接引用远程 URL)
  -h, --help         显示本帮助`;

function parseArgs(argv) {
  const opts = { bankDir: null, out: null, targets: null, noImages: false };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = () => argv[++i];
    switch (flag) {
      case "--bank-dir": opts.bankDir = value(); break;
      case "--out": opts.out = value(); break;
      case "--targets": opts.targets = value().split(",").map((s) => s.trim()).filter(Boolean); break;
      case "--no-images": opts.noImages = true; break;
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

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  // The bank lives in its own top-level directory (apps/bank); data sits
  // under apps/bank/data/.
  const bankDir = path.resolve(opts.bankDir || path.join(__dirname, "..", "data"));
  const outDir = path.resolve(opts.out || path.join(bankDir, "export"));
  const targets = opts.targets || TARGET_CATEGORIES;

  // 1. Download formula images (dedup by URL, skip existing).
  let imageMap = null;
  if (!opts.noImages) {
    const sources = collectImageSources(bankDir, targets);
    if (sources.size) {
      console.log(`== 图片: ${sources.size} 张，下载到 ${path.join(outDir, "images")} ==`);
      const result = await downloadImages(sources, outDir, { log: console });
      imageMap = result.map;
      console.log(`图片下载完成: 成功 ${result.total - result.failed}/${result.total}${result.failed ? `，失败 ${result.failed} 张（将回退为远程链接）` : ""}`);
    }
  }
  const imageResolver = imageMap
    ? (url) => imageMap.get(url) || url // failed downloads → remote URL
    : null;

  // 2. Generate Markdown.
  const { total, files } = exportBank(bankDir, outDir, { targets, imageResolver });
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

main().catch((err) => {
  console.error(`导出失败: ${err.message}`);
  process.exit(1);
});
