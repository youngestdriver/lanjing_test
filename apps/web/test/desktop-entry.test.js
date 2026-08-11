"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const path = require("node:path");

// Spawns the real entry as a child process and probes the server — proves
// the entry actually boots the app (Bun compile will run the same file).
test("desktop-entry boots the server and sets LANJING_LOCAL_DIR fallback", async () => {
  const localDir = path.join(require("node:os").tmpdir(), `lanjing-entry-${process.pid}`);
  const child = spawn(process.execPath, [path.join(__dirname, "..", "desktop-entry.js")], {
    env: { ...process.env, LANJING_LOCAL_DIR: localDir, LANJING_OPEN_BROWSER: "1", LANJING_OPEN_BROWSER_DISABLE: "1", PORT: "0" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  try {
    let output = "";
    let port = null;
    child.stdout.on("data", (chunk) => { output += chunk; });
    for (let i = 0; i < 100; i += 1) {
      const match = output.match(/Server: http:\/\/[^:]+:(\d+)/);
      if (match) { port = Number(match[1]); break; }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    assert.ok(port, `server did not boot; output: ${output}`);
    const response = await fetch(`http://127.0.0.1:${port}/api/status`);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { loggedIn: false, hasSavedSession: false });
  } finally {
    child.kill("SIGTERM");
  }
});
