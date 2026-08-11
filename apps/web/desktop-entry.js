"use strict";
// Desktop entry: bare script (no exports — `bun build --compile` probes
// default exports as Bun.serve configs and would swallow the server). The
// wrappers pass LANJING_LOCAL_DIR; without it data lives next to the
// executable (portable Linux / unpacked Windows).
const path = require("path");
if (!process.env.LANJING_LOCAL_DIR) {
  process.env.LANJING_LOCAL_DIR = path.join(path.dirname(process.execPath), ".local");
}
const { startServer } = require("./server");
startServer();
