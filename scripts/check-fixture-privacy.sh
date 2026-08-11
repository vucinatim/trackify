#!/usr/bin/env bash

set -euo pipefail

fixture_root="Tests/Fixtures"

if grep -R -n -E \
  'timvucina|zerodays|MyProjects|Authorization:|Bearer [A-Za-z0-9._-]+|BEGIN [A-Z ]*PRIVATE KEY|sk-[A-Za-z0-9]{12,}' \
  "$fixture_root"; then
  echo "Fixture privacy scan found a forbidden value." >&2
  exit 1
fi

if grep -R -n -E '"/(Users|Volumes|private|var|opt|Applications)/' "$fixture_root" \
  | grep -v '/Users/example/'; then
  echo "Fixture privacy scan found a non-synthetic absolute path." >&2
  exit 1
fi

jq -e . Tests/Fixtures/Codex/app-server-thread-read.v2.json >/dev/null

while IFS= read -r line; do
  jq -e . >/dev/null <<< "$line"
done < Tests/Fixtures/Codex/runtime-events-0.147.0.jsonl

while IFS= read -r line; do
  jq -e . >/dev/null <<< "$line"
done < Tests/Fixtures/Codex/terminal-failures-0.147.0.jsonl

while IFS= read -r line; do
  jq -e . >/dev/null <<< "$line"
done < Tests/Fixtures/Claude/session-2.1.29.jsonl

while IFS= read -r line; do
  jq -e . >/dev/null <<< "$line"
done < Tests/Fixtures/Claude/terminal-failures-2.1.29.jsonl

if tail -n 1 Tests/Fixtures/Claude/session-partial-tail.jsonl | jq -e . >/dev/null 2>&1; then
  echo "The partial-tail fixture must end with deliberately truncated JSON." >&2
  exit 1
fi

echo "Fixture privacy and structure checks passed."
