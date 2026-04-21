import { spawn } from "node:child_process";

import { desktopDir } from "./electron-launcher.mjs";

const childEnv = { ...process.env };
delete childEnv.ELECTRON_RUN_AS_NODE;

const childSpecs = [
  { name: "dev:bundle", args: ["run", "dev:bundle"] },
  { name: "dev:electron", args: ["run", "dev:electron"] },
];

const children = new Set();
let shuttingDown = false;
let exitCode = 0;

function stopChildren(signal = "SIGTERM") {
  if (shuttingDown) {
    return;
  }

  shuttingDown = true;
  for (const child of children) {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill(signal);
    }
  }
}

function trackChild(spec) {
  const child = spawn(process.execPath, spec.args, {
    cwd: desktopDir,
    env: childEnv,
    stdio: "inherit",
  });
  children.add(child);

  child.once("exit", (code, signal) => {
    children.delete(child);

    if (!shuttingDown) {
      exitCode = code ?? 1;
      console.error(
        `[desktop-dev] ${spec.name} exited unexpectedly (code=${code ?? "null"}, signal=${signal ?? "null"})`,
      );
      stopChildren(signal ?? "SIGTERM");
    }

    if (children.size === 0) {
      if (signal) {
        process.kill(process.pid, signal);
        return;
      }

      process.exit(exitCode);
    }
  });

  child.once("error", (error) => {
    children.delete(child);
    if (!shuttingDown) {
      exitCode = 1;
      console.error(`[desktop-dev] failed to start ${spec.name}:`, error);
      stopChildren();
    }

    if (children.size === 0) {
      process.exit(exitCode);
    }
  });
}

for (const spec of childSpecs) {
  trackChild(spec);
}

process.once("SIGINT", () => {
  stopChildren("SIGINT");
});

process.once("SIGTERM", () => {
  stopChildren("SIGTERM");
});
