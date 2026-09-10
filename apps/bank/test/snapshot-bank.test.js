"use strict";

// 快照打包测试：CRC32 已知向量、manifest 构建（mime/byCategory/缺图报错）、
// zip 写入 + 校验往返、篡改检测、以及可重复构建。

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const { crc32, detectMime, buildManifest, writeSnapshotZip, verifySnapshotZip } = require("../lib/snapshot");

// ---------- 测试脚手架 ----------

const PNG_BYTES = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  Buffer.from("假 PNG 数据假 PNG 数据", "utf8"),
]);
const JPEG_BYTES = Buffer.concat([
  Buffer.from([0xff, 0xd8, 0xff, 0xe0]),
  Buffer.from("假 JPEG 数据假 JPEG 数据", "utf8"),
]);
const GIF_BYTES = Buffer.concat([Buffer.from("GIF89a", "latin1"), Buffer.from("假 GIF", "utf8")]);
const WEBP_BYTES = Buffer.concat([Buffer.from("RIFF"), Buffer.from([0x24, 0, 0, 0]), Buffer.from("WEBP"), Buffer.from("假 WebP", "utf8")]);

function sha1Name(url) {
  return crypto.createHash("sha1").update(url).digest("hex") + ".png";
}

function makeTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-snapshot-"));
}

/** 造一个假题库目录：records 按分类写 JSONL，images 写图片字节（可选 manifest.json）。 */
function makeBank({ records, images = {}, manifest = null }) {
  const dir = makeTempDir();
  fs.mkdirSync(path.join(dir, "images"), { recursive: true });
  for (const [category, rows] of Object.entries(records)) {
    fs.writeFileSync(path.join(dir, category + ".jsonl"), rows.map((r) => JSON.stringify(r)).join("\n") + "\n", "utf8");
  }
  for (const [name, bytes] of Object.entries(images)) {
    fs.writeFileSync(path.join(dir, "images", name), bytes);
  }
  if (manifest) {
    fs.writeFileSync(path.join(dir, "images", "manifest.json"), JSON.stringify(manifest, null, 2) + "\n", "utf8");
  }
  return dir;
}

const imgRecord = (url) => ({ question: `<p>题干</p><p><img src="${url}"></p>`, options: [], analysis: "" });

/** 最简 zip 目录解析（测试内独立实现，不复用 lib 里的解析路径）。 */
function readZipEntries(zipPath) {
  const buf = fs.readFileSync(zipPath);
  const eocd = buf.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  assert.ok(eocd >= 0, "找不到 EOCD");
  const count = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  const entries = [];
  for (let i = 0; i < count; i += 1) {
    assert.equal(buf.readUInt32LE(p), 0x02014b50, "中央目录签名非法");
    const method = buf.readUInt16LE(p + 10);
    const size = buf.readUInt32LE(p + 24);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const localOffset = buf.readUInt32LE(p + 42);
    entries.push({ name: buf.toString("utf8", p + 46, p + 46 + nameLen), method, size, localOffset });
    p += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

// ---------- CRC32 ----------

test("crc32 匹配已知向量", () => {
  assert.equal(crc32("123456789"), 0xcbf43926);
  assert.equal(crc32(Buffer.from("123456789", "utf8")), 0xcbf43926);
  assert.equal(crc32(""), 0);
  assert.equal(crc32("The quick brown fox jumps over the lazy dog"), 0x414fa339);
});

// ---------- detectMime ----------

test("detectMime 按字节魔数判定真实类型", () => {
  assert.equal(detectMime(PNG_BYTES), "image/png");
  assert.equal(detectMime(JPEG_BYTES), "image/jpeg");
  assert.equal(detectMime(GIF_BYTES), "image/gif");
  assert.equal(detectMime(WEBP_BYTES), "image/webp");
  assert.equal(detectMime(Buffer.from("纯文本不是图片", "utf8")), "application/octet-stream");
  assert.equal(detectMime(Buffer.alloc(0)), "application/octet-stream");
});

// ---------- buildManifest ----------

test("buildManifest 统计题目/分类/图片，并给出 mime 与 sha256", () => {
  const pngUrl = "https://cdn.example.com/a.png";
  const jpgUrl = "https://cdn.example.com/b.jpg";
  const dir = makeBank({
    records: {
      甲类: [imgRecord(pngUrl), { question: "<p>没图的题</p>", options: [], analysis: "" }],
      乙类: [imgRecord(jpgUrl), { question: "<p>还是没图的题</p>" }],
    },
    images: { [sha1Name(pngUrl)]: PNG_BYTES, [sha1Name(jpgUrl)]: JPEG_BYTES },
  });

  const manifest = buildManifest(dir, { generatedAt: "2026-09-10T00:00:00.000Z", categories: ["甲类", "乙类"] });
  assert.equal(manifest.formatVersion, 1);
  assert.equal(manifest.generatedAt, "2026-09-10T00:00:00.000Z");
  assert.deepEqual(manifest.counts, { questions: 4, images: 2, byCategory: { 甲类: 2, 乙类: 2 } });
  assert.deepEqual(manifest.images.map((i) => i.url), [pngUrl, jpgUrl]); // 按 url 排序

  const png = manifest.images[0];
  assert.equal(png.file, sha1Name(pngUrl)); // 走 sha1 命名回退
  assert.equal(png.mime, "image/png");
  assert.equal(png.bytes, PNG_BYTES.length);
  assert.equal(png.sha256, crypto.createHash("sha256").update(PNG_BYTES).digest("hex"));
  assert.equal(manifest.images[1].mime, "image/jpeg");
});

test("buildManifest 优先用 images/manifest.json 的映射，并支持 stem/analysis/options 里的图", () => {
  const stemUrl = "https://cdn.example.com/stem.png";
  const analysisUrl = "https://cdn.example.com/analysis.png";
  const optionUrl = "https://cdn.example.com/option.png";
  const dir = makeBank({
    records: {
      资料分析: [
        {
          question: "<p>材料题</p>",
          stem: `<p><img src="${stemUrl}"></p>`,
          options: [`<p><img src="${optionUrl}"></p>`, "<p>文字选项</p>"],
          analysis: `<p><img src="${analysisUrl}"></p>`,
        },
      ],
    },
    images: { "custom-stem.png": PNG_BYTES, "custom-analysis.png": JPEG_BYTES, "custom-option.png": GIF_BYTES },
    manifest: { [stemUrl]: "custom-stem.png", [analysisUrl]: "custom-analysis.png", [optionUrl]: "custom-option.png" },
  });

  const manifest = buildManifest(dir, { categories: ["资料分析"] });
  assert.equal(manifest.counts.questions, 1);
  assert.equal(manifest.counts.images, 3);
  assert.deepEqual(
    manifest.images.map((i) => [i.url, i.file, i.mime]),
    [
      [analysisUrl, "custom-analysis.png", "image/jpeg"],
      [optionUrl, "custom-option.png", "image/gif"],
      [stemUrl, "custom-stem.png", "image/png"],
    ]
  );
});

test("buildManifest 缺图时报错并列出缺失 URL（最多 10 个 + 总数）", () => {
  const okUrl = "https://cdn.example.com/ok.png";
  // 用零填充编号，让「前 10 个」在字典序下也是 missing-00 … missing-09，断言不歧义。
  const missingUrls = Array.from({ length: 12 }, (_, i) => `https://cdn.example.com/missing-${String(i).padStart(2, "0")}.png`);
  const dir = makeBank({
    records: { 甲类: [imgRecord(okUrl), ...missingUrls.map(imgRecord)] },
    images: { [sha1Name(okUrl)]: PNG_BYTES },
  });

  assert.throws(
    () => buildManifest(dir, { categories: ["甲类"] }),
    (err) => {
      assert.match(err.message, /12 个被引用的图片/);
      assert.match(err.message, /missing-00\.png/);
      assert.match(err.message, /missing-09\.png/);
      assert.doesNotMatch(err.message, /missing-10\.png/); // 只列前 10 个
      assert.equal(err.missingTotal, 12);
      assert.equal(err.missing.length, 12);
      return true;
    }
  );
});

test("buildManifest 缺分类文件时直接报错", () => {
  const dir = makeBank({ records: { 甲类: [imgRecord("https://cdn.example.com/a.png")] }, images: { [sha1Name("https://cdn.example.com/a.png")]: PNG_BYTES } });
  assert.throws(() => buildManifest(dir, { categories: ["甲类", "乙类"] }), /缺少分类文件: 乙类\.jsonl/);
});

// ---------- zip 往返 ----------

test("writeSnapshotZip/verifySnapshotZip 往返：全 STORED、条目顺序固定、校验通过", () => {
  const pngUrl = "https://cdn.example.com/a.png";
  const jpgUrl = "https://cdn.example.com/b.jpg";
  const dir = makeBank({
    records: {
      甲类: [imgRecord(pngUrl), imgRecord(pngUrl)],
      乙类: [imgRecord(jpgUrl)],
    },
    images: { [sha1Name(pngUrl)]: PNG_BYTES, [sha1Name(jpgUrl)]: JPEG_BYTES },
  });
  const zipPath = path.join(makeTempDir(), "bank.zip");
  const manifest = buildManifest(dir, { generatedAt: "2026-09-10T00:00:00.000Z", categories: ["甲类", "乙类"] });
  const written = writeSnapshotZip(dir, zipPath, manifest);
  assert.equal(written.entries, 1 + 2 + 2);

  const names = readZipEntries(zipPath).map((e) => e.name);
  assert.deepEqual(names, [
    "manifest.json",
    "questions/甲类.jsonl",
    "questions/乙类.jsonl",
    `images/${sha1Name(pngUrl)}`,
    `images/${sha1Name(jpgUrl)}`,
  ]);
  for (const entry of readZipEntries(zipPath)) assert.equal(entry.method, 0, `${entry.name} 应为 STORED`);

  const result = verifySnapshotZip(zipPath);
  assert.deepEqual(result.problems, []);
  assert.equal(result.ok, true);
  assert.equal(result.entries, 5);
  const expectedBytes =
    Buffer.byteLength(JSON.stringify(manifest)) +
    Buffer.byteLength(fs.readFileSync(path.join(dir, "甲类.jsonl"))) +
    Buffer.byteLength(fs.readFileSync(path.join(dir, "乙类.jsonl"))) +
    PNG_BYTES.length +
    JPEG_BYTES.length;
  assert.equal(result.bytes, expectedBytes);
});

test("writeSnapshotZip 拒绝 manifest 与原始文件不一致的情况", () => {
  const url = "https://cdn.example.com/a.png";
  const dir = makeBank({ records: { 甲类: [imgRecord(url)] }, images: { [sha1Name(url)]: PNG_BYTES } });
  const manifest = buildManifest(dir, { categories: ["甲类"] });
  // 生成后文件被改动（同长度、不同内容）→ 写包时必须报错，不能产出清单对不上的包。
  const imagePath = path.join(dir, "images", sha1Name(url));
  const tampered = Buffer.from(fs.readFileSync(imagePath));
  tampered[tampered.length - 1] ^= 0xff;
  fs.writeFileSync(imagePath, tampered);
  assert.throws(
    () => writeSnapshotZip(dir, path.join(makeTempDir(), "bank.zip"), manifest),
    /sha256 与 manifest 记录不符/
  );
});

test("verifySnapshotZip 能发现被篡改的图片字节", () => {
  const url = "https://cdn.example.com/a.png";
  const dir = makeBank({ records: { 甲类: [imgRecord(url)] }, images: { [sha1Name(url)]: PNG_BYTES } });
  const zipPath = path.join(makeTempDir(), "bank.zip");
  writeSnapshotZip(dir, zipPath, buildManifest(dir, { categories: ["甲类"] }));
  assert.equal(verifySnapshotZip(zipPath).ok, true);

  // 在图片条目数据区翻一个字节，CRC32 立刻对不上。
  const buf = fs.readFileSync(zipPath);
  const nameAt = buf.indexOf(Buffer.from(`images/${sha1Name(url)}`, "utf8"));
  assert.ok(nameAt > 0, "没找到图片条目");
  const localAt = nameAt - 30; // 本地头正好 30 字节，紧随其后是文件名
  assert.equal(buf.readUInt32LE(localAt), 0x04034b50, "本地头签名非法");
  const dataAt = nameAt + buf.readUInt16LE(localAt + 26) + buf.readUInt16LE(localAt + 28);
  buf[dataAt + 5] ^= 0xff; // 落在 PNG 魔数之后的数据里
  fs.writeFileSync(zipPath, buf);

  const result = verifySnapshotZip(zipPath);
  assert.equal(result.ok, false);
  assert.ok(result.problems.some((p) => /CRC32 不匹配/.test(p)), result.problems.join("\n"));
});

test("verifySnapshotZip 能发现 manifest 里被改过的 sha256（CRC 已同步修正）", () => {
  const url = "https://cdn.example.com/a.png";
  const dir = makeBank({ records: { 甲类: [imgRecord(url)] }, images: { [sha1Name(url)]: PNG_BYTES } });
  const zipPath = path.join(makeTempDir(), "bank.zip");
  writeSnapshotZip(dir, zipPath, buildManifest(dir, { categories: ["甲类"] }));

  // manifest.json 是第一个条目：本地头在 0，数据紧随文件名之后。
  const buf = fs.readFileSync(zipPath);
  const nameLen = buf.readUInt16LE(26);
  const dataAt = 30 + nameLen + buf.readUInt16LE(28);
  const size = buf.readUInt32LE(18);
  const json = buf.toString("utf8", dataAt, dataAt + size);
  const fake = json.replace(/"sha256":"([0-9a-f])/, (_, c) => `"sha256":"${c === "0" ? "1" : "0"}`);
  assert.notEqual(fake, json, "应当替换掉一个 sha256 字符");
  assert.equal(Buffer.byteLength(fake), size, "替换后长度必须一致");
  buf.write(fake, dataAt, "utf8");
  // 同步修正 manifest.json 的 CRC32（本地头 +14，中央目录 +16），把问题限定在 sha256 上。
  const crc = crc32(Buffer.from(fake, "utf8"));
  buf.writeUInt32LE(crc, 14);
  const cdAt = buf.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
  assert.ok(cdAt > 0, "没找到中央目录");
  buf.writeUInt32LE(crc, cdAt + 16);
  fs.writeFileSync(zipPath, buf);

  const result = verifySnapshotZip(zipPath);
  assert.equal(result.ok, false);
  assert.ok(result.problems.some((p) => /sha256 不符/.test(p)), result.problems.join("\n"));
});

// ---------- 可重复构建 ----------

test("同一输入构建两次：manifest 除 generatedAt 外一致，zip 字节完全一致", () => {
  const pngUrl = "https://cdn.example.com/a.png";
  const jpgUrl = "https://cdn.example.com/b.jpg";
  const dir = makeBank({
    records: { 甲类: [imgRecord(pngUrl)], 乙类: [imgRecord(jpgUrl)] },
    images: { [sha1Name(pngUrl)]: PNG_BYTES, [sha1Name(jpgUrl)]: JPEG_BYTES },
  });

  const categories = ["甲类", "乙类"];
  const first = buildManifest(dir, { generatedAt: "2026-09-10T00:00:00.000Z", categories });
  const second = buildManifest(dir, { generatedAt: "2026-09-11T00:00:00.000Z", categories });
  // 除 generatedAt 外，两次构建的 manifest 完全一致（含图片排序与 file/sha256）。
  const strip = (m) => ({ ...m, generatedAt: null });
  assert.deepEqual(strip(second), strip(first));

  // 同一份 manifest 写两次：条目顺序与 zip 字节完全一致（时间戳固定为 1980-01-01）。
  const zipA = path.join(makeTempDir(), "a.zip");
  const zipB = path.join(makeTempDir(), "b.zip");
  writeSnapshotZip(dir, zipA, first);
  writeSnapshotZip(dir, zipB, buildManifest(dir, { generatedAt: "2026-09-10T00:00:00.000Z", categories }));
  assert.deepEqual(readZipEntries(zipB).map((e) => e.name), readZipEntries(zipA).map((e) => e.name));
  assert.deepEqual(fs.readFileSync(zipB), fs.readFileSync(zipA));
  assert.equal(verifySnapshotZip(zipB).ok, true);
});
