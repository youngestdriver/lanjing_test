"use strict";

// Open the app's own URL in the system browser — the desktop wrappers pass
// LANJING_OPEN_BROWSER=1 so a tray-started service still lands the user on
// the page. Fire-and-forget: any failure is swallowed (a missing xdg-open
// must never take the server down).
function openBrowser(url, { platform = process.platform, spawn = require("node:child_process").spawn } = {}) {
  let command = null;
  let args = [];
  if (platform === "darwin") {
    command = "open";
    args = [url];
  } else if (platform === "win32") {
    command = "cmd";
    args = ["/c", "start", "", url];
  } else if (platform === "linux") {
    command = "xdg-open";
    args = [url];
  } else {
    return false;
  }
  try {
    const run = typeof spawn === "function" ? spawn : spawn.spawn;
    run(command, args, { detached: true, stdio: "ignore" }).unref();
    return true;
  } catch {
    return false;
  }
}

module.exports = { openBrowser };
