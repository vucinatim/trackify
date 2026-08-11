#!/usr/bin/env node

import { spawn } from "node:child_process";
import readline from "node:readline";
import { createFixtureSanitizer } from "./sanitize-fixture.mjs";

const codex = process.env.TRACKIFY_CODEX_BIN ?? "codex";
const sanitize = createFixtureSanitizer();
const child = spawn(codex, ["app-server", "--listen", "stdio://"], {
  stdio: ["pipe", "pipe", "inherit"],
});
const lines = readline.createInterface({ input: child.stdout });

const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);
let timeout;

const fail = (message) => {
  clearTimeout(timeout);
  process.stderr.write(`${message}\n`);
  child.kill("SIGTERM");
  process.exitCode = 1;
};

lines.on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    fail("Codex app-server emitted invalid JSON");
    return;
  }

  if (message.id === 1) {
    if (message.error) return fail("Codex app-server initialization failed");
    send({ method: "initialized", params: {} });
    send({
      method: "thread/list",
      id: 2,
      params: { limit: 5, sortKey: "updated_at", sortDirection: "desc" },
    });
    return;
  }

  if (message.id === 2) {
    const thread = message.result?.data?.find((candidate) => candidate?.id);
    if (!thread) return fail("No readable Codex thread was found");
    send({
      method: "thread/read",
      id: 3,
      params: { threadId: thread.id, includeTurns: true },
    });
    return;
  }

  if (message.id === 3) {
    if (message.error || !message.result?.thread) {
      return fail("Codex thread/read failed");
    }

    clearTimeout(timeout);
    const thread = message.result.thread;
    const selectedTurns = Array.isArray(thread.turns)
      ? thread.turns.slice(0, 2).map((turn) => ({
          ...turn,
          items: Array.isArray(turn.items) ? turn.items.slice(0, 24) : [],
        }))
      : [];

    const fixture = sanitize({
      id: 3,
      result: {
        thread: {
          ...thread,
          turns: selectedTurns,
        },
      },
    });

    process.stdout.write(`${JSON.stringify(fixture, null, 2)}\n`);
    child.kill("SIGTERM");
  }
});

child.on("error", () => fail("Unable to start Codex app-server"));

timeout = setTimeout(() => fail("Codex fixture capture timed out"), 20_000);

send({
  method: "initialize",
  id: 1,
  params: {
    clientInfo: {
      name: "trackify_fixture_capture",
      title: "Trackify Fixture Capture",
      version: "0.0.0",
    },
  },
});
