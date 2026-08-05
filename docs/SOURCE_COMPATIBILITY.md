# Trackify Conversation Source Compatibility

Status: Initial compatibility spike complete
Last updated: 2026-08-05

## 1. Purpose

This document records the evidence-backed V1 import contract for local Codex and Claude Code history. It deliberately separates documented locations, observed formats, normalized evidence, and inference.

The initial spike ran on:

```text
Codex CLI          0.147.0-alpha.1.2
Claude Code        2.1.29
macOS              26.5.2, arm64
Codex sessions     425 active + 13 archived JSONL files
Claude sessions    885 JSONL files
```

No raw conversation content, private path, repository name, command output, or credential was copied into the repository. Structural fixtures were sanitized locally before being written.

## 2. Shared adapter contract

Both adapters emit the same minimal source-independent records:

```text
ConversationSession
- source
- sourceSessionId
- startedAt
- lastObservedAt
- workingDirectory, optional
- sourceVersion, optional
- observedState

ConversationTurn
- sourceTurnId or deterministic content identity
- sessionId
- startedAt, optional
- completedAt, optional
- observedState

ConversationMessage
- sourceMessageId or deterministic content identity
- turnId, optional
- role
- occurredAt, optional
- normalizedText

RunObservation
- sessionId
- turnId, optional
- kind
- occurredAt
- state
```

Normalized states remain limited to:

```text
in_progress
completed
failed
interrupted
waiting
unknown
```

The adapter may emit `unknown`; it may not turn a missing lifecycle signal into `completed`.

## 3. File ingestion rules

- Stream JSONL by byte range rather than loading whole files.
- Identify a source file by stable filesystem identity plus logical session ID.
- Persist byte offset, last complete-record hash, file size, and observation time.
- Advance the cursor only after the containing database transaction commits.
- Ignore an incomplete final line and retry it on the next observation.
- Re-read from the last safe boundary after truncation or replacement.
- Treat unknown extra fields as forward-compatible.
- Quarantine records missing required identity or type fields instead of partially importing them.
- Deduplicate by source identifier when present and by canonical content hash otherwise.
- Store occurrence time separately from import observation time.

## 4. Codex history source

### 4.1 Discovery

The official Codex [configuration documentation](https://learn.chatgpt.com/docs/config-file/config-advanced) defines `CODEX_HOME`, and its [troubleshooting documentation](https://learn.chatgpt.com/docs/reference/troubleshooting) documents the session locations:

```text
$CODEX_HOME/sessions
$CODEX_HOME/archived_sessions
```

with `CODEX_HOME` defaulting to `~/.codex`. Trackify resolves `CODEX_HOME` from the environment used to launch the app and otherwise uses the default. It never reads `auth.json` or provider credentials.

### 4.2 Production input

Observed persisted session files are JSONL with top-level `timestamp`, `type`, and `payload` fields. The initial fixture contains these record families:

```text
session_meta
turn_context
event_msg
response_item
world_state
compacted
```

Observed lifecycle event payloads include:

```text
task_started
user_message
agent_message
task_complete
thread_settings_applied
```

Other observed payloads include reasoning, token counts, file changes, tool calls, web search, image generation, and context compaction. V1 imports only fields required for session identity, message text, repository association, run lifecycle, and inspectable work evidence. Raw reasoning, token accounting, encrypted content, audio, image bytes, terminal output, and arbitrary tool payloads are not retained.

### 4.3 Lifecycle interpretation

```text
task_started without later terminal event   in_progress
task_complete                               completed
explicit failure event                      failed
newer turn/session after missing terminal
event or process disappearance              interrupted or unknown
approval/wait signal when explicit          waiting
```

Absence of `task_complete` is not failure. A stale unmatched start becomes `interrupted` only when supporting process and later-session evidence exists; otherwise it remains `unknown` or provisionally `in_progress` within the recency window.

### 4.4 App-server decision

The compatibility spike successfully used Codex app-server `thread/list` and `thread/read`, and the protocol exposes useful versioned schemas. However, the current official [Codex App Server documentation](https://learn.chatgpt.com/docs/app-server) labels the command and WebSocket transport experimental and unsupported for production workloads.

Therefore:

- V1 does not depend on app-server for correctness.
- Persisted JSONL is the production history source.
- App-server may remain a development oracle for comparing normalized results and detecting schema drift.
- A later stable app-server guarantee could replace private record parsing behind the same adapter boundary.

This avoids building V1 on an explicitly unsupported production dependency while preserving an easy migration path.

### 4.5 Internal report exclusion

Trackify invokes Codex reports with `--ephemeral` and an internal operation marker. Ephemeral report runs must not create persisted history. The collector also excludes any record carrying the marker as defense in depth.

## 5. Claude Code history source

### 5.1 Discovery

The observed V1 location is:

```text
~/.claude/projects/**/*.jsonl
```

This is treated as an adapter-specific observed cache, not a promised stable public API. Trackify never reads authentication configuration or credentials.

### 5.2 Observed record families

The Claude Code 2.1.29 fixture includes:

```text
user
assistant
system
queue-operation
attachment
ai-title
custom-title
last-prompt
mode
```

Message content variants include:

```text
text
thinking
tool_use
tool_result
image
fallback
```

Observed identity and association fields include `sessionId`, `uuid`, `parentUuid`, `timestamp`, `cwd`, `gitBranch`, and `version`.

V1 retains normalized user and assistant text, session/parent identity, timestamps, working-directory association, and selected tool lifecycle metadata. It does not retain thinking content, image data, arbitrary attachments, hook payloads, tool arguments, raw tool results, usage accounting, or diagnostic payloads.

### 5.3 Lifecycle interpretation

```text
user record followed by assistant tool_use  in_progress
assistant stop_reason = tool_use             in_progress
assistant stop_reason = end_turn             completed turn
explicit error/refusal/failed subtype        failed only when source semantics say failure
truncated final line                          still being written; retry
stale nonterminal session with no process    interrupted or unknown
```

Model refusal fallback records are evidence of a provider transition, not proof that development work failed. Queue operations describe local session mechanics and are not work by themselves.

### 5.4 Internal report exclusion

Trackify invokes Claude with `--no-session-persistence` and an internal operation marker. The collector excludes marked records if a future Claude version persists them despite that option.

## 6. Compatibility policy

Adapters select behavior by record shape and source schema fingerprint, not only by CLI semantic version.

- Known required fields plus unknown additional fields: import known fields.
- Missing required identity/type fields: quarantine the record and report degraded health.
- Known record type with new optional content variants: import supported variants and report omitted counts.
- Unknown record type: retain a bounded operational count, not the raw payload.
- Large unsupported format shift: stop that adapter before advancing its cursor; unrelated sources continue.

`trackify doctor --json` reports:

```json
{
  "source": "claude",
  "detectedVersion": "2.1.29",
  "adapterVersion": 1,
  "schemaFingerprint": "<hash>",
  "status": "supported",
  "unknownRecordCount": 0,
  "omittedPayloadCount": 14
}
```

The first public release advertises the exact fixture-tested versions and any shape-compatible versions exercised in CI. New versions become supported after sanitized fixtures pass the same contract suite.

## 7. Fixtures and tools

Fixtures:

```text
Tests/Fixtures/Codex/app-server-thread-read.v2.json
Tests/Fixtures/Codex/runtime-events-0.147.0.jsonl
Tests/Fixtures/Claude/session-2.1.29.jsonl
Tests/Fixtures/Claude/session-partial-tail.jsonl
```

Profiling and capture tools:

```text
scripts/compatibility/profile-codex-app-server.mjs
scripts/compatibility/profile-jsonl-cache.mjs
scripts/compatibility/capture-codex-fixture.mjs
scripts/compatibility/capture-jsonl-fixture.mjs
scripts/compatibility/sanitize-fixture.mjs
```

These tools output only structural profiles or sanitized fixtures. Raw cache files are never copied into the workspace.

## 8. Remaining compatibility tests

- [x] Completed Codex turns.
- [x] Interrupted Codex turn observed through the app-server comparison profile.
- [x] Active Codex lifecycle represented by unmatched `task_started` evidence.
- [x] Completed Claude turn using `end_turn`.
- [x] Active Claude tool cycle using `tool_use`.
- [x] Truncated Claude final record.
- [x] Unknown and optional fields tolerated structurally.
- [ ] Explicit failed Codex turn fixture.
- [ ] Explicit failed Claude turn fixture.
- [ ] Cache truncation and replacement while the app is offline.
- [ ] Same fixture suite on at least one coworker's Claude Code installation.

The remaining cases are implementation tests, not blockers to scaffolding. They remain blockers to advertising full failure-state support in the signed V1 release.
