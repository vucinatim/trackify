#!/usr/bin/env node

import { spawn } from "node:child_process";
import readline from "node:readline";

const codex = process.env.TRACKIFY_CODEX_BIN ?? "codex";
const child = spawn(codex, ["app-server", "--listen", "stdio://"], {
  stdio: ["pipe", "pipe", "pipe"],
});

const lines = readline.createInterface({ input: child.stdout });
let stderr = "";
let timeout;

child.stderr.on("data", (chunk) => {
  if (stderr.length < 4_096) stderr += String(chunk);
});

const send = (message) => {
  child.stdin.write(`${JSON.stringify(message)}\n`);
};

const keys = (value) =>
  value && typeof value === "object" && !Array.isArray(value)
    ? Object.keys(value).sort()
    : [];

const arrayField = (value, candidates) => {
  for (const candidate of candidates) {
    if (Array.isArray(value?.[candidate])) return value[candidate];
  }
  return [];
};

const safeEnum = (value) =>
  typeof value === "string" && /^[A-Za-z][A-Za-z0-9_.-]{0,63}$/.test(value)
    ? value
    : "unknown";

const countEnums = (values) =>
  Object.fromEntries(
    [...new Set(values.map(safeEnum))]
      .sort()
      .map((value) => [value, values.map(safeEnum).filter((item) => item === value).length]),
  );

const finish = (result, exitCode = 0) => {
  clearTimeout(timeout);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  child.kill("SIGTERM");
  setTimeout(() => child.kill("SIGKILL"), 1_000).unref();
  process.exitCode = exitCode;
};

let listResult;

lines.on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    finish({ ok: false, error: "app-server emitted invalid JSON" }, 1);
    return;
  }

  if (message.id === 1) {
    if (message.error) {
      finish({ ok: false, stage: "initialize", errorCode: message.error.code }, 1);
      return;
    }

    send({ method: "initialized", params: {} });
    send({
      method: "thread/list",
      id: 2,
      params: { limit: 3, sortKey: "updated_at", sortDirection: "desc" },
    });
    return;
  }

  if (message.id === 2) {
    if (message.error) {
      finish({ ok: false, stage: "thread/list", errorCode: message.error.code }, 1);
      return;
    }

    listResult = message.result;
    const threads = arrayField(listResult, ["data", "threads"]);
    const first = threads[0];

    if (!first?.id) {
      finish({
        ok: true,
        listResultKeys: keys(listResult),
        threadCount: threads.length,
        threadKeys: [],
        readSupported: false,
      });
      return;
    }

    send({
      method: "thread/read",
      id: 3,
      params: { threadId: first.id, includeTurns: true },
    });
    return;
  }

  if (message.id === 3) {
    if (message.error) {
      finish({
        ok: true,
        listResultKeys: keys(listResult),
        threadCount: arrayField(listResult, ["data", "threads"]).length,
        threadKeys: keys(arrayField(listResult, ["data", "threads"])[0]),
        readSupported: false,
        readErrorCode: message.error.code,
      });
      return;
    }

    const thread = message.result?.thread ?? message.result;
    const turns = arrayField(thread, ["turns"]);
    const items = turns.flatMap((turn) => arrayField(turn, ["items"]));

    finish({
      ok: true,
      listResultKeys: keys(listResult),
      threadCount: arrayField(listResult, ["data", "threads"]).length,
      threadKeys: keys(arrayField(listResult, ["data", "threads"])[0]),
      readSupported: true,
      readResultKeys: keys(message.result),
      readThreadKeys: keys(thread),
      threadStatus: safeEnum(thread?.status?.type ?? thread?.status),
      turnCount: turns.length,
      turnKeys: keys(turns[0]),
      turnStatusCounts: countEnums(turns.map((turn) => turn?.status)),
      itemCount: items.length,
      itemKeys: [...new Set(items.flatMap(keys))].sort(),
      itemTypeCounts: countEnums(items.map((item) => item?.type)),
    });
  }
});

child.on("error", () => {
  finish({ ok: false, error: "unable to start Codex app-server" }, 1);
});

child.on("exit", (code) => {
  if (process.exitCode === undefined) {
    finish(
      {
        ok: false,
        error: "Codex app-server exited before profiling completed",
        exitCode: code,
        hadStderr: stderr.trim().length > 0,
      },
      1,
    );
  }
});

timeout = setTimeout(() => {
  finish({ ok: false, error: "Codex app-server profiling timed out" }, 1);
}, 20_000);

send({
  method: "initialize",
  id: 1,
  params: {
    clientInfo: {
      name: "trackify_compatibility_spike",
      title: "Trackify Compatibility Spike",
      version: "0.0.0",
    },
  },
});
