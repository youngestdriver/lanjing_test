"use strict";

// 完整题库快照打包：把 5 个分类 JSONL 和题图目录打成一个「零网络、可重复、可校验」
// 的 zip，供 iOS 端「导入题库」离线读取（不联网、不依赖服务端）。
//
// 设计要点：
//   * 全 STORED（不压缩，method=0）：题图本身已是 PNG/JPEG/GIF/WebP 等压缩格式，
//     deflate 基本省不下空间；而 iOS 侧只要解析 zip 目录、按偏移拷贝字节即可读出，
//     不需要实现 inflate。这是刻意取舍，不是遗漏。
//   * zip 条目时间戳固定为 1980-01-01：同一份输入重复构建得到字节一致的产物。
//   * 只用 node:crypto / node:fs / node:path，无第三方依赖、无网络访问。
//   * 图片引用规则完全复用 bank-export.js 的 collectImageSources（question/stem/
//     analysis/options 四个字段 + 实体解码 + URL 归一化），保证与导出侧同源。

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const { TARGET_CATEGORIES, collectImageSources } = require("./bank-export");

const FORMAT_VERSION = 1;
const IMAGES_DIR = "images";
const IMAGES_MANIFEST = "manifest.json";

// ---------- CRC32（表驱动） ----------

const CRC32_TABLE = (() => {
  const table = new Int32Array(256);
  for (let i = 0; i < 256; i += 1) {
    let c = i;
    for (let k = 0; k < 8; k += 1) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[i] = c;
  }
  return table;
})();

/** 计算 CRC32（zip 校验用）；接受 Buffer 或字符串（按 UTF-8 编码）。返回无符号数。 */
function crc32(input) {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(String(input), "utf8");
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i += 1) {
    crc = CRC32_TABLE[(crc ^ buf[i]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

// ---------- 字节魔数 → MIME ----------

/**
 * 按字节魔数判定图片类型（文件名统一是 .png，但字节可能是 JPEG/GIF/WebP，不能靠
 * 扩展名）。识别不了就回退 application/octet-stream，由调用方决定怎么处理。
 */
function detectMime(buf) {
  if (!buf || buf.length < 12) return "application/octet-stream";
  if (buf[0] === 0x89 && buf.toString("latin1", 1, 4) === "PNG" && buf[4] === 0x0d && buf[5] === 0x0a && buf[6] === 0x1a && buf[7] === 0x0a) {
    return "image/png";
  }
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return "image/jpeg";
  const head6 = buf.toString("latin1", 0, 6);
  if (head6 === "GIF87a" || head6 === "GIF89a") return "image/gif";
  if (buf.toString("latin1", 0, 4) === "RIFF" && buf.toString("latin1", 8, 12) === "WEBP") return "image/webp";
  return "application/octet-stream";
}

// ---------- 文件名安全 ----------

/** 只接受 images/ 下的纯文件名，挡掉 manifest 里可能混入的路径穿越。 */
function assertSafeFileName(name, label) {
  const value = String(name ?? "");
  if (!value || value === "." || value === ".." || value.includes("/") || value.includes("\\") || value.includes("\0")) {
    throw new Error(`${label} 不是合法的文件名: ${JSON.stringify(value)}`);
  }
  return value;
}

function sha1Name(url) {
  return crypto.createHash("sha1").update(url).digest("hex") + ".png";
}

// ---------- 读题库 ----------

/**
 * 统计 <bankDir>/<分类>.jsonl 的记录数并返回文件内容。分类文件缺失直接报错——
 * 快照是「完整题库」分发包，缺一个分类属于硬错误，不能静默产出残包。
 */
function readCategoryFiles(bankDir, categories) {
  const files = [];
  const missing = [];
  for (const category of categories) {
    const file = path.join(bankDir, category + ".jsonl");
    let text;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch {
      missing.push(category + ".jsonl");
      continue;
    }
    let questions = 0;
    for (const line of text.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        JSON.parse(trimmed);
      } catch {
        continue; // 与 collectImageSources 一致：坏行跳过，不影响计数与配图
      }
      questions += 1;
    }
    files.push({ category, file, text, questions });
  }
  if (missing.length) {
    const err = new Error(`题库缺少分类文件: ${missing.join("、")}（目录 ${bankDir}）`);
    err.missingCategories = missing;
    throw err;
  }
  return files;
}

/** 读 <bankDir>/images/manifest.json（{url: 文件名}），缺失/损坏时返回空表。 */
function readImagesManifest(imagesDir) {
  try {
    const parsed = JSON.parse(fs.readFileSync(path.join(imagesDir, IMAGES_MANIFEST), "utf8"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

/**
 * 扫描题库，生成快照清单（不落盘、不联网）：
 *   { formatVersion, generatedAt, counts: { questions, images, byCategory }, images: [...] }
 * images 每项 { url, file, mime, bytes, sha256 }，按 url 排序保证可重复。
 * 被引用但 images/ 下找不到文件的 URL 会抛错，err.missing 里带上完整列表。
 *
 * 选项：generatedAt（ISO 时间串，默认当前时间）、categories（默认 5 个机考分类）。
 */
function buildManifest(bankDir, opts = {}) {
  const { generatedAt = new Date().toISOString(), categories = TARGET_CATEGORIES } = opts;
  const root = path.resolve(bankDir);
  const imagesDir = path.join(root, IMAGES_DIR);

  const files = readCategoryFiles(root, categories);
  const byCategory = {};
  let questions = 0;
  for (const f of files) {
    byCategory[f.category] = f.questions;
    questions += f.questions;
  }

  // 引用集合以 bank-export.collectImageSources 为准（四个字段 + 归一化）。
  const referenced = [...collectImageSources(root, categories)].sort();
  const known = readImagesManifest(imagesDir);

  const images = [];
  const missing = [];
  for (const url of referenced) {
    // 优先用 images/manifest.json 的映射，其次回退到 sha1(url)+".png" 命名约定。
    let file = "";
    try {
      file = assertSafeFileName(known[url] || sha1Name(url), `图片 URL ${url} 对应的文件名`);
    } catch {
      file = "";
    }
    const abs = file ? path.join(imagesDir, file) : "";
    let buf;
    if (abs) {
      try {
        buf = fs.readFileSync(abs);
      } catch {
        buf = null;
      }
    }
    if (!buf) {
      missing.push(url);
      continue;
    }
    images.push({
      url,
      file,
      mime: detectMime(buf),
      bytes: buf.length,
      sha256: crypto.createHash("sha256").update(buf).digest("hex"),
    });
  }

  if (missing.length) {
    const shown = missing.slice(0, 10);
    const err = new Error(
      `有 ${missing.length} 个被引用的图片在 ${imagesDir} 下找不到文件` +
        `${missing.length > shown.length ? `（只列出前 ${shown.length} 个）` : ""}:\n  ` +
        shown.join("\n  ")
    );
    err.missing = missing;
    err.missingTotal = missing.length;
    throw err;
  }

  return {
    formatVersion: FORMAT_VERSION,
    generatedAt,
    counts: { questions, images: images.length, byCategory },
    images,
  };
}

// ---------- 最小 ZIP writer（全 STORED） ----------

const ZIP_LOCAL_SIG = 0x04034b50;
const ZIP_CENTRAL_SIG = 0x02014b50;
const ZIP_EOCD_SIG = 0x06054b50;
const ZIP_VERSION = 20; // 2.0：STORED + 目录结构
const ZIP_UTF8_FLAG = 0x0800; // bit 11：文件名按 UTF-8 编码（分类名是中文）
const ZIP_METHOD_STORED = 0;
// 固定时间戳（DOS 格式 1980-01-01 00:00:00）：让产物字节可重复。
const ZIP_DOS_TIME = 0x0000;
const ZIP_DOS_DATE = 0x0021;
const ZIP_UNIX_MODE = (0o100644 << 16) >>> 0; // external attributes：普通文件 0644（>>> 0 转无符号，最高位是 1）
const UINT16_MAX = 0xffff;
const UINT32_MAX = 0xffffffff;

/** 列出快照 zip 的全部条目（顺序固定：manifest → questions → images）。 */
function snapshotEntryDescriptors(bankDir, manifest) {
  const root = path.resolve(bankDir);
  const byCategory = (manifest && manifest.counts && manifest.counts.byCategory) || {};
  const images = (manifest && manifest.images) || [];

  const descriptors = [
    {
      name: "manifest.json",
      read: () => Buffer.from(JSON.stringify(manifest), "utf8"),
    },
  ];
  for (const category of Object.keys(byCategory)) {
    const name = "questions/" + assertSafeFileName(category, "分类名") + ".jsonl";
    const abs = path.join(root, category + ".jsonl");
    descriptors.push({ name, read: () => fs.readFileSync(abs) });
  }
  for (const image of images) {
    const file = assertSafeFileName(image.file, `图片 URL ${image.url} 对应的文件名`);
    const abs = path.join(root, IMAGES_DIR, file);
    descriptors.push({
      name: IMAGES_DIR + "/" + file,
      read: () => {
        const buf = fs.readFileSync(abs);
        // 边写边核：manifest 过期（体积/哈希对不上原始文件）时立刻报错，
        // 不产出「清单与实际内容不一致」的包。
        if (buf.length !== image.bytes) {
          throw new Error(`图片 ${file} 实际 ${buf.length} 字节，与 manifest 记录的 ${image.bytes} 不符`);
        }
        const sha = crypto.createHash("sha256").update(buf).digest("hex");
        if (sha !== image.sha256) {
          throw new Error(`图片 ${file} 的 sha256 与 manifest 记录不符（文件可能已变更，请重新生成 manifest）`);
        }
        return buf;
      },
    });
  }
  return descriptors;
}

/**
 * 写全 STORED 的 zip 到 outPath。条目：
 *   manifest.json / questions/<分类>.jsonl ×N / images/<文件名> ×M
 * 见文件头注释：不压缩是刻意决定（iOS 侧无需实现 inflate）。
 */
function writeSnapshotZip(bankDir, outPath, manifest) {
  if (!manifest || typeof manifest !== "object") throw new Error("writeSnapshotZip 需要 buildManifest 生成的清单");
  const descriptors = snapshotEntryDescriptors(bankDir, manifest);
  if (descriptors.length > UINT16_MAX) {
    throw new Error(`条目数 ${descriptors.length} 超出 zip 上限 ${UINT16_MAX}，需要 ZIP64（未实现）`);
  }

  fs.mkdirSync(path.dirname(path.resolve(outPath)), { recursive: true });
  const fd = fs.openSync(path.resolve(outPath), "w");
  const central = [];
  let offset = 0;
  try {
    for (const descriptor of descriptors) {
      const data = descriptor.read();
      const nameBuf = Buffer.from(descriptor.name, "utf8");
      if (nameBuf.length > UINT16_MAX) throw new Error(`条目名过长: ${descriptor.name}`);
      if (data.length > UINT32_MAX) throw new Error(`条目 ${descriptor.name} 超过 4 GiB，需要 ZIP64（未实现）`);
      const sum = crc32(data);

      const local = Buffer.alloc(30);
      local.writeUInt32LE(ZIP_LOCAL_SIG, 0);
      local.writeUInt16LE(ZIP_VERSION, 4);
      local.writeUInt16LE(ZIP_UTF8_FLAG, 6);
      local.writeUInt16LE(ZIP_METHOD_STORED, 8);
      local.writeUInt16LE(ZIP_DOS_TIME, 10);
      local.writeUInt16LE(ZIP_DOS_DATE, 12);
      local.writeUInt32LE(sum, 14);
      local.writeUInt32LE(data.length, 18); // STORED：压缩后大小 == 原始大小
      local.writeUInt32LE(data.length, 22);
      local.writeUInt16LE(nameBuf.length, 26);
      local.writeUInt16LE(0, 28); // extra field 长度
      fs.writeSync(fd, local, 0, local.length, offset);
      offset += local.length;
      fs.writeSync(fd, nameBuf, 0, nameBuf.length, offset);
      offset += nameBuf.length;
      if (data.length) {
        fs.writeSync(fd, data, 0, data.length, offset);
        offset += data.length;
      }
      central.push({ name: nameBuf, crc: sum, size: data.length, localOffset: offset - nameBuf.length - data.length - local.length });
    }

    const centralOffset = offset;
    for (const entry of central) {
      const header = Buffer.alloc(46);
      header.writeUInt32LE(ZIP_CENTRAL_SIG, 0);
      header.writeUInt16LE(ZIP_VERSION, 4); // version made by
      header.writeUInt16LE(ZIP_VERSION, 6); // version needed
      header.writeUInt16LE(ZIP_UTF8_FLAG, 8);
      header.writeUInt16LE(ZIP_METHOD_STORED, 10);
      header.writeUInt16LE(ZIP_DOS_TIME, 12);
      header.writeUInt16LE(ZIP_DOS_DATE, 14);
      header.writeUInt32LE(entry.crc, 16);
      header.writeUInt32LE(entry.size, 20);
      header.writeUInt32LE(entry.size, 24);
      header.writeUInt16LE(entry.name.length, 28);
      header.writeUInt16LE(0, 30); // extra field 长度
      header.writeUInt16LE(0, 32); // 注释长度
      header.writeUInt16LE(0, 34); // 起始磁盘号
      header.writeUInt16LE(0, 36); // 内部属性
      header.writeUInt32LE(ZIP_UNIX_MODE, 38); // 外部属性
      header.writeUInt32LE(entry.localOffset, 42);
      fs.writeSync(fd, header, 0, header.length, offset);
      offset += header.length;
      fs.writeSync(fd, entry.name, 0, entry.name.length, offset);
      offset += entry.name.length;
    }
    const centralSize = offset - centralOffset;
    if (centralOffset > UINT32_MAX || centralSize > UINT32_MAX) {
      throw new Error("中央目录超出 4 GiB，需要 ZIP64（未实现）");
    }

    const eocd = Buffer.alloc(22);
    eocd.writeUInt32LE(ZIP_EOCD_SIG, 0);
    eocd.writeUInt16LE(0, 4); // 本磁盘号
    eocd.writeUInt16LE(0, 6); // 中央目录起始磁盘号
    eocd.writeUInt16LE(central.length, 8);
    eocd.writeUInt16LE(central.length, 10);
    eocd.writeUInt32LE(centralSize, 12);
    eocd.writeUInt32LE(centralOffset, 16);
    eocd.writeUInt16LE(0, 20); // 注释长度
    fs.writeSync(fd, eocd, 0, eocd.length, offset);
    offset += eocd.length;
  } finally {
    fs.closeSync(fd);
  }
  return { entries: descriptors.length, bytes: offset };
}

// ---------- ZIP 校验 ----------

function readAt(fd, buffer, position) {
  let read = 0;
  while (read < buffer.length) {
    const n = fs.readSync(fd, buffer, read, buffer.length - read, position + read);
    if (n <= 0) break;
    read += n;
  }
  return read;
}

/** 从文件尾部找 EOCD（注释最长 65535，所以最多回扫 22+65535 字节）。 */
function findEocd(fd, size) {
  const tailLen = Math.min(size, 22 + UINT16_MAX);
  const start = size - tailLen;
  const tail = Buffer.alloc(tailLen);
  readAt(fd, tail, start);
  for (let i = tailLen - 22; i >= 0; i -= 1) {
    if (tail.readUInt32LE(i) === ZIP_EOCD_SIG) return { offset: start + i, tail, base: start, index: i };
  }
  return null;
}

/**
 * 读回快照 zip 逐条校验：条目 CRC32 与大小、以及 manifest 里每个图片的
 * bytes/sha256 是否与实际条目一致。返回 { ok, entries, bytes, problems }，
 * bytes 是所有条目原始字节之和；problems 为空即 ok。
 */
function verifySnapshotZip(zipPath) {
  const file = path.resolve(zipPath);
  const problems = [];
  const fd = fs.openSync(file, "r");
  let entries = 0;
  let bytes = 0;
  try {
    const size = fs.fstatSync(fd).size;
    const eocd = findEocd(fd, size);
    if (!eocd) throw new Error(`不是合法的 zip（找不到 EOCD）: ${file}`);
    const entryCount = eocd.tail.readUInt16LE(eocd.index + 10);
    const centralSize = eocd.tail.readUInt32LE(eocd.index + 12);
    const centralOffset = eocd.tail.readUInt32LE(eocd.index + 16);
    const diskEntries = eocd.tail.readUInt16LE(eocd.index + 8);
    if (diskEntries !== entryCount) problems.push(`EOCD 条目数不一致: ${diskEntries} vs ${entryCount}`);
    if (centralOffset + centralSize > size) problems.push("中央目录越界");

    // 1) 逐个中央目录条目读取本地头 + 数据，核 CRC32/大小，并记录条目内容摘要。
    const cd = Buffer.alloc(centralSize);
    readAt(fd, cd, centralOffset);
    const found = new Map(); // 条目名 → { bytes, sha256 }
    let p = 0;
    for (let i = 0; i < entryCount; i += 1) {
      if (p + 46 > cd.length) {
        problems.push(`中央目录第 ${i} 条越界`);
        break;
      }
      if (cd.readUInt32LE(p) !== ZIP_CENTRAL_SIG) {
        problems.push(`中央目录第 ${i} 条签名非法`);
        break;
      }
      const method = cd.readUInt16LE(p + 10);
      const crc = cd.readUInt32LE(p + 16);
      const compSize = cd.readUInt32LE(p + 20);
      const rawSize = cd.readUInt32LE(p + 24);
      const nameLen = cd.readUInt16LE(p + 28);
      const extraLen = cd.readUInt16LE(p + 30);
      const commentLen = cd.readUInt16LE(p + 32);
      const localOffset = cd.readUInt32LE(p + 42);
      const name = cd.toString("utf8", p + 46, p + 46 + nameLen);
      p += 46 + nameLen + extraLen + commentLen;
      entries += 1;

      if (method !== ZIP_METHOD_STORED) problems.push(`条目 ${name} 不是 STORED（method=${method}）`);
      if (compSize !== rawSize) problems.push(`条目 ${name} 压缩大小 ${compSize} != 原始大小 ${rawSize}`);
      if (found.has(name)) problems.push(`条目名重复: ${name}`);

      if (localOffset + 30 > size) {
        problems.push(`条目 ${name} 本地头越界`);
        continue;
      }
      const local = Buffer.alloc(30);
      readAt(fd, local, localOffset);
      if (local.readUInt32LE(0) !== ZIP_LOCAL_SIG) {
        problems.push(`条目 ${name} 本地头签名非法`);
        continue;
      }
      const dataLen = local.readUInt32LE(18); // STORED：压缩大小 == 原始大小
      const dataOffset = localOffset + 30 + local.readUInt16LE(26) + local.readUInt16LE(28);
      if (dataOffset + dataLen > size) {
        problems.push(`条目 ${name} 数据越界`);
        continue;
      }
      const data = Buffer.alloc(dataLen);
      readAt(fd, data, dataOffset);
      bytes += dataLen;
      const actualCrc = crc32(data);
      if (actualCrc !== crc) {
        problems.push(`条目 ${name} CRC32 不匹配（期望 ${crc.toString(16)}，实际 ${actualCrc.toString(16)}）`);
      }
      if (local.readUInt32LE(14) !== actualCrc) {
        problems.push(`条目 ${name} 本地头 CRC32 与中央目录不一致`);
      }
      found.set(name, data);
    }

    // 2) 用 manifest.json 里的 bytes/sha256 核对每个图片条目。
    const manifestBuf = found.get("manifest.json");
    if (!manifestBuf) {
      problems.push("缺少 manifest.json");
      return { ok: false, entries, bytes, problems };
    }
    let manifest;
    try {
      manifest = JSON.parse(manifestBuf.toString("utf8"));
    } catch (err) {
      problems.push(`manifest.json 不是合法 JSON: ${err.message}`);
      return { ok: false, entries, bytes, problems };
    }
    const images = Array.isArray(manifest.images) ? manifest.images : [];
    for (const image of images) {
      const name = IMAGES_DIR + "/" + image.file;
      const data = found.get(name);
      if (!data) {
        problems.push(`缺少 manifest 声明的图片: ${name}`);
        continue;
      }
      if (data.length !== image.bytes) {
        problems.push(`图片 ${image.file} 大小不符（manifest ${image.bytes}，实际 ${data.length}）`);
      }
      const sha = crypto.createHash("sha256").update(data).digest("hex");
      if (sha !== image.sha256) {
        problems.push(`图片 ${image.file} sha256 不符（manifest ${String(image.sha256).slice(0, 12)}…，实际 ${sha.slice(0, 12)}…）`);
      }
    }
    // 3) manifest 声明的分类题目文件是否都在。
    const byCategory = (manifest.counts && manifest.counts.byCategory) || {};
    for (const category of Object.keys(byCategory)) {
      const name = "questions/" + category + ".jsonl";
      if (!found.has(name)) problems.push(`缺少题目文件: ${name}`);
    }
    if (manifest.counts && manifest.counts.images !== images.length) {
      problems.push(`manifest.counts.images=${manifest.counts.images} 与 images 数组长度 ${images.length} 不一致`);
    }
  } finally {
    fs.closeSync(fd);
  }
  return { ok: problems.length === 0, entries, bytes, problems };
}

module.exports = {
  FORMAT_VERSION,
  crc32,
  detectMime,
  buildManifest,
  writeSnapshotZip,
  verifySnapshotZip,
};
