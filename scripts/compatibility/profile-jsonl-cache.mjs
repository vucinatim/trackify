#!/usr/bin/env node

import { createReadStream, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import readline from "node:readline";

const source = process.argv[2];
const roots = {
  claude: join(homedir(), ".claude", "projects"),
  codex: join(homedir(), ".codex", "sessions"),
};

if (!roots[source]) {
  process.stderr.write("usage: profile-jsonl-cache.mjs <codex|claude>\n");
  process.exit(2);
}

const jsonlFiles = [];
const visit = (directory) => {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) visit(path);
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
      const stat = statSync(path);
      jsonlFiles.push({ path, modifiedAt: stat.mtimeMs, size: stat.size });
    }
  }
};

try {
  visit(roots[source]);
} catch (error) {
  process.stderr.write(`unable to inspect ${source} cache: ${error.code ?? "unknown"}\n`);
  process.exit(1);
}

jsonlFiles.sort((left, right) => right.modifiedAt - left.modifiedAt);
const sample =
  jsonlFiles.find((file) => file.size >= 4_096) ??
  jsonlFiles.find((file) => file.size > 0);

if (!sample) {
  process.stdout.write(`${JSON.stringify({ source, fileCount: 0 }, null, 2)}\n`);
  process.exit(0);
}

const keyTypes = new Map();
const recordTypes = new Map();
const nestedKeys = new Map();
let parsedLines = 0;
let malformedLines = 0;

const valueType = (value) =>
  value === null ? "null" : Array.isArray(value) ? "array" : typeof value;

const safeEnum = (value) =>
  typeof value === "string" && /^[A-Za-z][A-Za-z0-9_.-]{0,63}$/.test(value)
    ? value
    : "unknown";

const addNestedKeys = (prefix, value) => {
  if (!value || typeof value !== "object" || Array.isArray(value)) return;
  const existing = nestedKeys.get(prefix) ?? new Set();
  Object.keys(value).forEach((key) => existing.add(key));
  nestedKeys.set(prefix, existing);
};

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
    malformedLines += 1;
    continue;
  }

  if (!record || typeof record !== "object" || Array.isArray(record)) continue;
  parsedLines += 1;

  const type = safeEnum(record.type);
  recordTypes.set(type, (recordTypes.get(type) ?? 0) + 1);

  for (const [key, value] of Object.entries(record)) {
    const types = keyTypes.get(key) ?? new Set();
    types.add(valueType(value));
    keyTypes.set(key, types);
  }

  addNestedKeys("message", record.message);
  addNestedKeys("payload", record.payload);
  addNestedKeys("data", record.data);

  const content = Array.isArray(record.message?.content)
    ? record.message.content
    : Array.isArray(record.content)
      ? record.content
      : [];
  for (const block of content) {
    addNestedKeys(`content.${safeEnum(block?.type)}`, block);
  }
}

const sortedObject = (entries) =>
  Object.fromEntries([...entries].sort(([left], [right]) => left.localeCompare(right)));

process.stdout.write(
  `${JSON.stringify(
    {
      source,
      fileCount: jsonlFiles.length,
      sampledFileSize: sample.size,
      parsedLines,
      malformedLines,
      recordTypes: sortedObject(recordTypes),
      topLevelKeyTypes: sortedObject(
        [...keyTypes].map(([key, types]) => [key, [...types].sort()]),
      ),
      nestedKeys: sortedObject(
        [...nestedKeys].map(([key, values]) => [key, [...values].sort()]),
      ),
    },
    null,
    2,
  )}\n`,
);
