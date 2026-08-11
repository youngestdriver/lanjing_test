#!/usr/bin/env node
"use strict";
// Assemble an ICO container with embedded PNG entries (Windows Vista+ reads
// PNG-in-ICO). Usage: assemble-ico.js <16.png> <32.png> <48.png> <out.ico>
const fs = require("node:fs");

const inputs = process.argv.slice(2, 5);
const out = process.argv[5];
if (inputs.length !== 3 || !out) {
  console.error("usage: assemble-ico.js <16.png> <32.png> <48.png> <out.ico>");
  process.exit(1);
}

const pngs = inputs.map((file) => fs.readFileSync(file));
const sizes = [16, 32, 48];
const header = Buffer.alloc(6);
header.writeUInt16LE(0, 0); // reserved
header.writeUInt16LE(1, 2); // type: icon
header.writeUInt16LE(pngs.length, 4); // count

const entries = [];
let offset = 6 + pngs.length * 16;
pngs.forEach((png, i) => {
  const entry = Buffer.alloc(16);
  entry.writeUInt8(sizes[i] >= 256 ? 0 : sizes[i], 0); // width
  entry.writeUInt8(sizes[i] >= 256 ? 0 : sizes[i], 1); // height
  entry.writeUInt8(0, 2); // palette
  entry.writeUInt8(0, 3); // reserved
  entry.writeUInt16LE(1, 4); // planes
  entry.writeUInt16LE(32, 6); // bpp
  entry.writeUInt32LE(png.length, 8); // bytes in resource
  entry.writeUInt32LE(offset, 12); // offset to PNG data
  entries.push(entry);
  offset += png.length;
});

fs.writeFileSync(out, Buffer.concat([header, ...entries, ...pngs]));
console.log(`wrote ${out} (${pngs.reduce((a, b) => a + b.length, 0)} bytes of PNG)`);
