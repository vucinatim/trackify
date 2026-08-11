# Trackify Conversation Source Compatibility

Status: Initial compatibility spike complete
Last updated: 2026-08-06

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

SourceEvidenceRef
- source
- ingestionPath: cache or hook
- sourceRecordId, optional
- deterministicFingerprint
- observedAt
- adapterVersion
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
- Redact recognized credentials and remove transport-only attachment markup before message fingerprinting, persistence, or indexing.
- Treat otherwise-identical attachment-bearing and text-only representations from the same session, role, and bounded occurrence window as one canonical message while retaining source aliases.
- Store occurrence time separately from import observation time.
- Version the directory cursor independently from individual evidence records. V1 cursor version 2 adds normalized message-observation evidence; a version-1 cursor is reset once so existing caches replay through the newer adapter without losing data or duplicating stable records.

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
thread_rolled_back
```

Other observed payloads include reasoning, token counts, file changes, tool calls, web search, image generation, and context compaction. V1 imports only fields required for session identity, message text, repository association, run lifecycle, and inspectable work evidence. Raw reasoning, token accounting, encrypted content, audio, image bytes, terminal output, and arbitrary tool payloads are not retained.

`thread_rolled_back` is retained as control evidence. It does not create a work
message, change historical metrics, or imply that a turn failed.

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

## 5.5 Claude Desktop Code history source

Claude Desktop Code is a distinct source surface from terminal Claude Code. The
observed macOS location is:

```text
~/Library/Application Support/Claude/local-agent-mode-sessions/**/audit.jsonl
```

Each audit stream may have adjacent session metadata. Trackify decodes only
`sessionId`, `cliSessionId`, and `cwd` from that metadata so the normalized
session can retain identity and repository association. It does not decode or
store account name, email, system prompt, organization policy, MCP configuration,
selected folders, or other Desktop configuration.

Audit records use `_audit_timestamp` and `session_id`; the adapter maps those to
the shared Claude conversation contract, retains user and assistant text blocks,
and ignores thinking, tool arguments/results, diagnostics, and unsupported
record families. It removes `_audit_hmac` before normalization and never reads
the sibling `.audit-key`. The audit stream is treated as an observed local cache,
not as an authentication or integrity API.

Terminal and Desktop sources have independent cursors and health states. If the
same stable Claude session appears through both surfaces, the normal canonical
evidence rules reconcile it rather than double-counting work. Ordinary Claude
Desktop chat outside Desktop Code remains out of scope.

## 6. Live hook bridge

Persisted caches remain the durable production source for history, backfill, and recovery. Codex and Claude expose lifecycle hooks that can optionally target Trackify's provider-neutral normalized bridge to improve live state and timing.

- Codex supports lifecycle events including session start/end, prompt submission, stopping, tool activity, and subagent lifecycle through its documented [hooks system](https://learn.chatgpt.com/docs/hooks).
- Claude Code exposes corresponding session, prompt, tool, failure, stop, subagent, worktree, and related events through its documented [hooks system](https://code.claude.com/docs/en/hooks).
- V1 does not parse either provider's raw hook payload or mutate provider configuration. A user, managed configuration, or later provider-specific adapter maps a supported hook event into the normalized command below.
- A missing, disabled, unsupported, policy-blocked, or untrusted hook configuration affects live precision only. Cache reconciliation continues normally.

### 6.1 Ingestion contract

The normalized bridge is:

```bash
trackify integrations emit <codex|claude> \
  --session <provider-session-id> \
  --turn <provider-turn-id> \
  --phase <started|waiting|completed|failed|interrupted> \
  [--at <iso-8601>] [--cwd <working-directory>]
```

The command validates the normalized allowlist, caps the encoded envelope at 64 KiB, appends one complete line under an exclusive file lock to a mode-`0600` inbox inside the private data root, and exits. It does not open the ledger, inspect Git, invoke a provider, access the network, or wait for the Trackify app.

Allowed normalized fields are limited to:

- Provider.
- Nonempty provider session and turn identifiers.
- One normalized lifecycle phase.
- Occurrence timestamp.
- Optional working-directory association.

The bridge discards prompt text, assistant text, thinking, tool arguments, tool results, command output, environment data, credentials, arbitrary nested payloads, and provider diagnostics. Searchable messages continue to come from the cache adapter under the normal storage policy.

### 6.2 Delivery and reconciliation

Hook delivery is best-effort and may be absent, delayed, duplicated, or out of order. Stable normalized inputs are idempotent. Concurrent invocations append complete locked records beneath the mode-`0700` Trackify data tree. Empty identifiers and oversized envelopes fail before creating or changing the inbox; provider hook configuration should treat this optional telemetry command as non-authoritative.

The app drains the inbox and normalizes hook evidence through the same adapter contract as cache records. When the cache later exposes the same lifecycle fact, Trackify reconciles it using:

1. Provider event, session, turn, or tool identity when stable identifiers exist.
2. Otherwise, a deterministic fingerprint over provider, semantic event kind, session relationship, bounded occurrence time, and non-sensitive structural fields.

Both observation records may be retained as provenance, but they resolve to one canonical session, run transition, interval boundary, and metric contribution. Hook arrival order cannot change the final rebuilt ledger.

### 6.3 Installation and trust

V1 exposes the bridge and inbox status but does not install, merge, or inspect provider hook configuration. Automatic provider-specific setup is deferred until stable versioned contracts justify the maintenance and trust surface. Trackify never bypasses Codex hook trust review or organization-managed provider policy.

Trackify never requires hooks for historical import or report generation.

## 7. Compatibility policy

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
  "adapterVersion": 2,
  "schemaFingerprint": "<hash>",
  "status": "supported",
  "unknownRecordCount": 0,
  "omittedPayloadCount": 14
}
```

The first public release advertises the exact fixture-tested versions and any shape-compatible versions exercised in CI. New versions become supported after sanitized fixtures pass the same contract suite.

## 8. Fixtures and tools

Fixtures:

```text
Tests/Fixtures/Codex/app-server-thread-read.v2.json
Tests/Fixtures/Codex/runtime-events-0.147.0.jsonl
Tests/Fixtures/Codex/terminal-failures-0.147.0.jsonl
Tests/Fixtures/Claude/session-2.1.29.jsonl
Tests/Fixtures/Claude/session-partial-tail.jsonl
Tests/Fixtures/Claude/terminal-failures-2.1.29.jsonl
```

Profiling and capture tools:

```text
scripts/compatibility/profile-codex-app-server.mjs
scripts/compatibility/profile-jsonl-cache.mjs
scripts/compatibility/capture-codex-fixture.mjs
scripts/compatibility/capture-jsonl-fixture.mjs
scripts/compatibility/capture-terminal-fixture.mjs
scripts/compatibility/sanitize-fixture.mjs
```

These tools output only structural profiles or sanitized fixtures. Raw cache files are never copied into the workspace.

## 9. Remaining compatibility tests

- [x] Completed Codex turns.
- [x] Interrupted Codex turn observed through the app-server comparison profile.
- [x] Active Codex lifecycle represented by unmatched `task_started` evidence.
- [x] Completed Claude turn using `end_turn`.
- [x] Active Claude tool cycle using `tool_use`.
- [x] Truncated Claude final record.
- [x] Unknown and optional fields tolerated structurally.
- [x] Explicit failed, aborted, interrupted, and error Codex record variants.
- [x] Explicit top-level Claude API-error record variant. Error-like strings inside nested content are not treated as lifecycle evidence.
- [x] Cache truncation and replacement while the app is offline, including same-inode truncation and atomic replacement.
- [ ] Same fixture suite on at least one coworker's Claude Code installation.
- [x] Exercise deterministic normalized lifecycle envelopes for both provider identities.
- [x] Verify hook-first/cache reconciliation and duplicate delivery against stable canonical records.
- [ ] Verify delayed and out-of-order hook reconciliation across an extended live run.
- [x] Verify an absent hook inbox preserves cache-only collection.

The remaining cases are implementation tests, not blockers to scaffolding. They remain blockers to advertising full hook and failure-state support in the signed V1 release.
