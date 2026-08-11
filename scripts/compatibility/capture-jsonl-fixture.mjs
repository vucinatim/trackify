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
  process.stderr.write("usage: capture-jsonl-fixture.mjs <codex|claude>\n");
  process.exit(2);
}

const files = [];
const visit = (directory) => {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) visit(path);
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
      const stat = statSync(path);
      files.push({ path, modifiedAt: stat.mtimeMs, size: stat.size });
    }
  }
};

visit(roots[source]);
files.sort((left, right) => right.modifiedAt - left.modifiedAt);
const sample = files.find((file) => file.size >= 4_096);

if (!sample) {
  process.stderr.write(`No representative ${source} JSONL cache was found\n`);
  process.exit(1);
}

const sanitize = createFixtureSanitizer();
const selected = new Map();
const input = readline.createInterface({
  input: createReadStream(sample.path),
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
  const type = typeof record?.type === "string" ? record.type : "unknown";
  const contentTypes = Array.isArray(record?.message?.content)
    ? record.message.content
        .map((block) => (typeof block?.type === "string" ? block.type : "unknown"))
        .sort()
        .join(",")
    : "none";
  const variant = [
    type,
    record?.subtype ?? "none",
    record?.operation ?? "none",
    record?.payload?.type ?? "none",
    record?.payload?.status ?? "none",
    record?.message?.stop_reason ?? "none",
    contentTypes,
  ].join(":");
  if (!selected.has(variant)) selected.set(variant, sanitize(record));
  if (selected.size >= 24) break;
}

for (const record of selected.values()) {
  process.stdout.write(`${JSON.stringify(record)}\n`);
}
