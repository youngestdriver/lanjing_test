"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// __dirname is apps/web/test; the repo root (with assets/) is 3 levels up.
const assetsDir = path.resolve(__dirname, "..", "..", "..", "assets", "desktop");

test("icon.ico is an ICO container with three embedded PNG entries", () => {
  const data = fs.readFileSync(path.join(assetsDir, "icon.ico"));
  // ICONDIR: reserved(2)=0, type(2)=1, count(2)=3
  assert.deepEqual([...data.subarray(0, 6)], [0, 0, 1, 0, 3, 0]);
  const count = data.readUInt16LE(4);
  assert.ok(count === 3, "three sizes");
  // PNG signature "\x89PNG\r\n\x1a\n" (the \x89 stays an escape sequence so
  // no raw control byte lands in this source file). Decode as latin1: Node's
  // "ascii" clears the high bit, so byte 0x89 would come back as 0x09.
  const pngSig = "\x89PNG".replace("\x89", "\x89") + "\r\n\x1a\n";
  for (let i = 0; i < count; i += 1) {
    const entry = 6 + i * 16;
    // ICONDIRENTRY: width(0) height(1) colors(2) reserved(3) planes(4-5)
    // bpp(6-7) bytesInRes(8-11) offset-to-data(12-15). The PNG bytes live at
    // the offset, not inside the entry itself.
    const pngLen = data.readUInt32LE(entry + 8);
    const pngStart = data.readUInt32LE(entry + 12);
    assert.equal(data.toString("latin1", pngStart, pngStart + 8), pngSig, "entry points at embedded PNG data");
    assert.ok(pngStart >= 6 + count * 16 && pngStart + pngLen <= data.length, "PNG sits in the data region");
  }
});

test("status-icon.png is a PNG", () => {
  const data = fs.readFileSync(path.join(assetsDir, "status-icon.png"));
  assert.equal(data.toString("hex", 0, 8), "89504e470d0a1a0a");
});

test("macOS app icon is an ICNS container", () => {
  const data = fs.readFileSync(path.join(assetsDir, "icon.icns"));
  assert.equal(data.toString("ascii", 0, 4), "icns");
  assert.equal(data.readUInt32BE(4), data.length, "ICNS header records the full file size");
});
