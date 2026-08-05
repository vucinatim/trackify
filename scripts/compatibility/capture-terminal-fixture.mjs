#!/usr/bin/env node

import { createReadStream, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import readline from "node:readline";
import { createFixtureSanitizer } from "./sanitize-fixture.mjs";

const source = process.argv[2];
const roots = {
  claude: join(homedir(), ".claude", "projects"),
  codex: join(homedir(), ".codex", "sessions"),
};

if (!roots[source]) {
  process.stderr.write("usage: capture-terminal-fixture.mjs <codex|claude>\n");
  process.exit(2);
}

const files = [];
const visit = (directory) => {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) visit(path);
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
      const stat = statSync(path);
      files.push({ path, modifiedAt: stat.mtimeMs });
    }
  }
};

visit(roots[source]);
files.sort((left, right) => right.modifiedAt - left.modifiedAt);

const sanitize = createFixtureSanitizer();
const selected = new Map();

const terminalKind = (record) => {
  const candidates = [
    record?.type,
    record?.status,
    record?.subtype,
    record?.stop_reason,
    record?.payload?.type,
    record?.payload?.status,
    record?.message?.stop_reason,
  ].filter((value) => typeof value === "string");

  return candidates.find((value) =>
    /failed|failure|error|interrupted|abort|aborted|cancel|cancelled/i.test(value),
  );
};

for (const file of files) {
  const input = readline.createInterface({
    input: createReadStream(file.path),
    crlfDelay: Infinity,
  });

  for await (const line of input) {
    if (!line.trim()) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }

    const kind = terminalKind(record);
    if (!kind) continue;
    const key = [
      record?.type ?? "none",
      record?.payload?.type ?? "none",
      record?.status ?? record?.payload?.status ?? "none",
      record?.subtype ?? "none",
      kind,
    ].join(":");
    if (!selected.has(key)) selected.set(key, sanitize(record));
    if (selected.size >= 12) break;
  }

  if (selected.size >= 12) break;
}

if (selected.size === 0) {
  process.stderr.write(`No explicit terminal ${source} records were found\n`);
  process.exit(1);
}

for (const record of selected.values()) {
  process.stdout.write(`${JSON.stringify(record)}\n`);
}
