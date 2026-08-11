"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");

const { openBrowser } = require("../lib/open-browser");

function fakeSpawn() {
  const calls = [];
  return {
    calls,
    spawn(command, args, options) {
      calls.push({ command, args, options });
      return { unref() {}, on() {} };
    },
  };
}

test("darwin opens with `open` and detached stdio-ignore", () => {
  const spawn = fakeSpawn();
  const ok = openBrowser("http://127.0.0.1:3000", { platform: "darwin", spawn });
  assert.equal(ok, true);
  assert.deepEqual(spawn.calls[0], {
    command: "open",
    args: ["http://127.0.0.1:3000"],
    options: { detached: true, stdio: "ignore" },
  });
});

test("win32 opens via cmd start with quoted URL", () => {
  const spawn = fakeSpawn();
  openBrowser("http://127.0.0.1:3000", { platform: "win32", spawn });
  assert.deepEqual(spawn.calls[0], {
    command: "cmd",
    args: ["/c", "start", "", "http://127.0.0.1:3000"],
    options: { detached: true, stdio: "ignore" },
  });
});

test("linux opens with xdg-open", () => {
  const spawn = fakeSpawn();
  openBrowser("http://127.0.0.1:3000", { platform: "linux", spawn });
  assert.deepEqual(spawn.calls[0].command, "xdg-open");
});

test("unknown platform returns false without spawning", () => {
  const spawn = fakeSpawn();
  assert.equal(openBrowser("http://x", { platform: "freebsd", spawn }), false);
  assert.equal(spawn.calls.length, 0);
});

test("spawn failure is swallowed", () => {
  const spawn = { spawn() { throw new Error("boom"); } };
  assert.equal(openBrowser("http://x", { platform: "linux", spawn }), false);
});
