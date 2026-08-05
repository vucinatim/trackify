# Compatibility Fixtures

These fixtures preserve the observed structure of local Codex and Claude Code history while replacing every user-controlled value with deterministic synthetic content.

They contain no real conversation text, repository name, employer or customer identifier, username, home path, credential, command output, or source code.

## Codex

- `Codex/app-server-thread-read.v2.json` is a sanitized `thread/read` response captured through the versioned Codex app-server protocol.
- `Codex/runtime-events-0.147.0.jsonl` is a sanitized structural sample of persisted JSONL events used only for live lifecycle detection when a turn has started but has not yet appeared as completed through history reads.

The historical adapter should prefer app-server `thread/list` and `thread/read`. The runtime tail adapter recognizes only a small allowlist of lifecycle event types and remains version-gated.

## Claude Code

- `Claude/session-2.1.29.jsonl` contains sanitized structural variants observed in a representative Claude Code cache: user, assistant, system, queue, attachment, title, and mode records; tool use and results; thinking, text, image, and fallback content; and both `tool_use` and `end_turn` stop reasons.
- `Claude/session-partial-tail.jsonl` deliberately ends with invalid truncated JSON. It verifies that an actively written final record is ignored and retried without advancing the durable source cursor.

Claude's local cache format is treated as a versioned adapter input rather than a public stable protocol.

## Regeneration

Structural profiling:

```bash
node scripts/compatibility/profile-codex-app-server.mjs
node scripts/compatibility/profile-jsonl-cache.mjs codex
node scripts/compatibility/profile-jsonl-cache.mjs claude
```

Sanitized fixture capture:

```bash
node scripts/compatibility/capture-codex-fixture.mjs \
  > Tests/Fixtures/Codex/app-server-thread-read.v2.json

node scripts/compatibility/capture-jsonl-fixture.mjs codex \
  > Tests/Fixtures/Codex/runtime-events-0.147.0.jsonl

node scripts/compatibility/capture-jsonl-fixture.mjs claude \
  > Tests/Fixtures/Claude/session-2.1.29.jsonl
```

Every regenerated fixture must pass the repository privacy scan before commit. Do not add raw cache files to the repository, even temporarily.
