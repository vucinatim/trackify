# Goal 2 Acceptance Audit

Status: Goal 2 product implementation accepted; release gates tracked separately
Last updated: 2026-08-06

This is the evidence-backed closure record for the 18 acceptance criteria in
[GOAL_2.md](./GOAL_2.md). “Proven locally” means the behavior is implemented and
covered by deterministic tests, an isolated CLI exercise, native screenshot
validation, or a local packaged build. It does not relabel a missing live release,
signed update drill, or real elapsed soak evidence as successful.

| # | Requirement | Result | Evidence |
|---:|---|---|---|
| 1 | Work with no provider | Proven locally | Local-only and quiet-period queue tests produce deterministic artifacts without invoking a provider. |
| 2 | Separate sources and generators | Proven locally | Independent `SourceCapability` and `GenerationCapability` records, Preferences sections, and CLI payloads; Codex/Claude history does not imply generation readiness. |
| 3 | Common Codex/Claude artifact contract | Proven by contract tests | Both adapters use the same structured response, usage, run, and artifact model. Live synthetic reconciliation is a release-matrix gate below. |
| 4 | Explicit provider never changes | Proven locally | Explicit Claude failure invokes Claude once, creates a local fallback, and never calls Codex. |
| 5 | Provider never holds collection lease | Proven locally | A gated slow provider runs while collection independently acquires and releases the collection lease. |
| 6 | Smart bounded compiler | Proven locally and measured | Parallel work, user intent, outcomes, failures, unfinished state, aliases, redaction, and the 20 KiB cap pass; the production-ledger measurement reduced the prior input shape by about 6.7×. |
| 7 | Full-day hierarchy | Proven locally | Daily packets use closed hourly summaries across the whole day and retain quiet-hour metadata. |
| 8 | Recipe policy cannot be bypassed | Proven locally | Unsafe focus text is rejected; locked prompt, schema, packet size, tool prohibition, and privacy filtering remain outside custom instructions. |
| 9 | Durable honest run telemetry | Proven locally | Provider, requested/effective model, invocation/compiler/prompt/schema versions, duration, token categories, known/unknown cost, outcome, and artifact are persisted. |
| 10 | Budgets prevent invocation | Proven locally | Byte, token, call, and configured money ceilings are checked before process start; exhaustion creates a visible local fallback. |
| 11 | Backfill requires preview/confirmation | Proven locally | Evidence backfill is independent; model backfill is bounded to 14 days and cannot enqueue before explicit confirmation. |
| 12 | Preserve V1 reports | Proven locally | Migration 0006 creates immutable `legacy:<report-id>` artifacts with the original report and evidence links and starts no provider process. |
| 13 | Immutable traceable artifacts | Proven locally | Insert-only database trigger and store tests preserve exact recipe version, run, period state, revision, scope, evidence, and generation provenance. |
| 14 | Safe local delivery | Proven locally | Clipboard, Markdown, versioned JSON, and mock destinations enforce privacy rank, permissions, private files, no conflicting overwrite, and idempotency. |
| 15 | App/CLI parity | Proven locally | The native Reports workspace and `reports`/`recipes` CLI expose template management, one-off instructions, preview, manual generation, history, copy, usage, and provenance. Settings expose source/provider selection and budgets. |
| 16 | Credential boundary | Proven locally | Discovery uses documented executable/version/status commands only. The Claude Desktop adapter imports audit transcript records but never reads `.audit-key`, retains HMACs, or decodes account/configuration fields. |
| 17 | Fixed-clock and install matrix | Partially proven | Fixed-clock foundation/showcase, source-state fixtures, light/dark Preferences, packaged CLI, and local install pass. The installed Universal candidate and fresh ledgers execute natively on arm64 and through Rosetta on x86_64. A live Codex synthetic run succeeded with emitted usage; the newest Claude Desktop Code CLI correctly reported its expired OAuth context as an authentication failure. A successful Claude reconciliation and the full workplace-machine matrix remain release validation. |
| 18 | Release candidate and soak | External release gate | Source CI, privacy, Universal package, deep ad-hoc signing, direct-origin routing, and simulated failure/wake recovery pass. Sparkle enclosure signing, first-install confirmation, a live update, and a seven-day real release-build soak require release operations and elapsed operation. |

## Additional measured checks

- The full automated test suite passes across eight suites, including repeated
  manual generation, immutable per-run configuration, and internal-message filtering.
- A synthetic 120-repository, 365-day, 2,190-event ledger produced all 365
  dashboard snapshots, the grouped repository catalog, and the bounded latest
  500 events in under one second on the reference machine.
- Goal 2 screenshots pass for the Reports workspace and in-window Sources,
  AI Providers, Usage, and General settings alongside the existing main-window matrix.
- The packaged CLI contract was exercised against an isolated 42-day showcase
  ledger for source/provider status, usage, recipes, artifacts, Markdown, and
  versioned JSON.
- The actual machine exposes distinct available surfaces for Codex current and
  archived history, Claude terminal history, and Claude Desktop Code audit
  history.
- Release-mode Universal development build `0.2.0` (`201`) is installed and
  running from `~/Applications/Trackify.app`; its bundled CLI, schema-6 ledger,
  deep ad-hoc signature, first heavy reconciliation, and diagnostics pass on
  arm64 and through Rosetta on x86_64.
- Cache-level availability is independent, while displayed imported totals and
  last-import time are honestly labeled as deduplicated Codex/Claude family
  ledger metrics because current and archived caches can overlap.

## Separate release-owner procedure

These are distribution gates, not missing Goal 2 product features:

1. Re-authenticate Claude Code, rerun its tiny synthetic provider test, and
   compare Trackify's captured usage with the CLI's emitted usage. The Codex
   reconciliation already passes.
2. Publish a release candidate through the protected release workflow using the
   already provisioned and recoverably retained Sparkle EdDSA key; verify
   deep ad-hoc signatures, hardened runtime, appcast, enclosure signature,
   checksum, universal slices, SBOM, app/CLI version, and first-open guidance.
3. Run the signed candidate continuously for seven elapsed days across sleep,
   wake, provider timeout/loss, budget exhaustion, and recovery; confirm no
   collection stalls or unexpected provider calls.
4. Complete clean install, upgrade, rollback/repair, and uninstall on the
   confirmed workplace macOS/architecture matrix.
