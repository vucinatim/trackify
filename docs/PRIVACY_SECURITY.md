# Trackify Privacy and Security Contract

Status: V1 baseline plus Goal 2 work-intelligence controls
Last updated: 2026-08-06

## 1. Purpose

Trackify observes repositories and local coding-agent conversations. Those sources may contain proprietary code, customer names, credentials, private paths, debugging output, and personal messages. Privacy is therefore part of the evidence architecture, not a settings-page addition.

This document defines what Trackify stores, what may leave the machine, and what V1 deliberately does not protect against.

## 2. Core promise

Trackify is local-first and user-owned:

- No Trackify account or server is required.
- Statistics, search, rollups, and evidence storage operate locally.
- V1 contains no product analytics, advertising SDK, tracking pixel, or automatic crash-report upload.
- Repository contents, conversations, reports, and metrics are not synchronized by Trackify.
- Network access is limited to signed update checks and explicitly enabled report-provider invocations.
- Disabling AI reports leaves collection, statistics, history, search, and deterministic no-activity reports functional.

“Local-first” does not mean every operation is offline. When Codex or Claude is selected for reports, that provider CLI may send the bounded evidence packet to its configured service under the user's existing provider account and organization policy.

## 3. Data classes

### Imported source evidence

- Repository and working-copy identity.
- Git commits and machine-readable file/line statistics.
- Working-tree state and normalized change metadata.
- Codex and Claude session metadata, messages, and supported lifecycle evidence.
- Allowlisted structural lifecycle observations delivered through optional Codex and Claude hooks.
- Selected normalized tool, build, or test observations needed for work history.
- Source identifiers, timestamps, hashes, adapter versions, and observation cursors.

### Derived local data

- Activity intervals and query-time continuity projections.
- Hourly and daily activity snapshots.
- Moving-average comparisons.
- Evidence packets.
- Versioned report recipes, durable run telemetry, immutable artifacts, and local delivery attempts.
- Full-text search indexes.

### Operational data

- Configuration, exclusions, provider selection, and discovery roots.
- Health records, collector cursors, leases, and application heartbeat.
- Update state and installation origin.
- Local diagnostic logs that exclude evidence content.

## 4. Storage minimization

V1 stores sanitized normalized session message text because durable search and historical context are core product functions. It does not copy every raw cache file wholesale.

Default rules:

- Redact recognized credentials and strip transport-only attachment markup before message fingerprinting, storage, search indexing, or display.
- Store sanitized normalized message text, roles, timestamps, associations, and required lifecycle evidence.
- Store source hashes and adapter versions so changed records can be detected.
- Do not persist complete source-code file contents.
- Do not persist full Git diffs by default.
- Do not persist binary tool output, terminal screen buffers, images, attachments, or arbitrary raw tool payloads by default.
- Normalize only the tool fields required for activity, state, repository association, and evidence inspection.
- Keep unsupported payload categories out of the ledger until their use and privacy cost are defined.
- Reduce hook input immediately to an allowlist before it enters the event inbox; never spool the complete provider hook payload.

The compatibility spike decides the smallest raw fields required for correct idempotency and parsing. Adding a new retained payload requires a schema review and an update to this contract.

## 5. Local filesystem protection

Canonical data root:

```text
~/Library/Application Support/Trackify/
```

V1 requirements:

- Data and runtime directories use mode `0700`.
- Ledger, configuration, logs, exports created by default, migration backups, and runtime files use mode `0600`.
- V1 exposes no TCP listener or local control socket; CLI coordination uses the private SQLite ledger and collection lease.
- The live-event inbox is mode `0700`; each atomic hook envelope is mode `0600` and removed after durable ingestion.
- Temporary files use fresh private directories and are removed after completion.
- The application never weakens source-file permissions.
- Exporting to a user-selected location clearly transfers responsibility for that copy.

V1 relies on macOS user separation and FileVault for at-rest protection. It does not add SQLCipher or a custom encryption layer. This avoids background key-unlock problems and substantial database complexity while the original Codex and Claude caches are already readable by the same logged-in user.

This protects against casual access by other unprivileged accounts. It does not protect against malware, administrators, root access, a compromised logged-in account, or a machine whose disk is accessible without FileVault. Documentation recommends FileVault; V1 does not invoke privileged disk-encryption diagnostics or block use.

## 6. Network boundaries

Trackify itself contacts only:

1. The configured Sparkle appcast and GitHub-hosted signed release assets.
2. The locally installed Codex or Claude CLI when the user has enabled model-generated reports or an explicit provider test.

Trackify has no analytics endpoint in V1.

Provider hook ingestion is local command execution into a private filesystem inbox. It opens no TCP listener and sends no network request.

Update requests contain normal network metadata such as IP address and user agent but no repository, session, path, provider, ledger, or productivity data.

Provider behavior follows [LLM_PROVIDERS.md](./LLM_PROVIDERS.md). Provider credentials remain owned by the provider CLI and are never read, copied, stored, or logged by Trackify.

Claude Desktop Code history is read from its local audit stream. Trackify never
reads the adjacent `.audit-key`, never retains `_audit_hmac`, and allowlist-decodes
only session identity and working-directory metadata. Account, email, system
prompt, organization policy, MCP, and Desktop configuration fields remain owned
by Claude and outside the ledger.

## 7. Provider evidence packets

Before invoking Codex or Claude, Trackify constructs a transient local packet. It contains:

- Period boundaries, locally derived report state, and aggregate statistics.
- At most 30 selected hourly events or 12 selected day-level events, plus at most
  24 active hourly report digests for a hierarchical daily report.
- Packet-local aliases for events, repositories, sessions, and prior hourly
  reports. Stable ledger identifiers and report evidence identifiers remain local.
- Repository display names when they are known.
- Commit metadata, working-tree counts and states, and agent/build/test lifecycle outcomes present in those events.
- Selected normalized conversation excerpts, each redacted locally and capped at
  280 characters. Allowlisted payload values are capped at 160 characters and
  prior hourly summaries at 220 characters.
- Selection and omission counts, including context coverage and omitted quiet
  hourly reports.

It does not contain by default:

- Full repository diffs.
- Full transcripts.
- Absolute home-directory paths.
- Environment dumps.
- Credential files or known secret-bearing files.
- Raw terminal buffers or arbitrary tool payloads.
- More than the bounded event selection for the requested period and its required continuity evidence.

Evidence selection and redaction happen before the provider process starts.
Exact configured repository paths and `/Users/<name>` or `/home/<name>` path
components are replaced locally. The compiled evidence packet is capped at 20
KiB and the provider prompt retains an independent 256 KiB defense-in-depth cap;
either failure falls closed to deterministic reporting. A prompt instruction to
ignore secrets is not a substitute for local filtering.

## 8. Deterministic redaction

The V1 redaction and omission pipeline runs locally before provider invocation. It:

- Replaces recognized OpenAI, GitHub, AWS, Slack, and bearer-token patterns.
- Replaces exact configured repository paths and usernames in conventional macOS/Linux home paths.
- Omits provider credentials and authentication configuration because Trackify never reads those sources.
- Omits prompt bodies, assistant bodies, thinking, tool arguments, tool results, command output, and environment data received by a provider hook.
- Bounds every selected conversation excerpt and structured payload value before serialization.

The same recognized-secret redactor also runs at conversation ingestion, storage, legacy migration, defensive decode, report persistence, search-index rebuild, and agent-context rendering. Attachment markup emitted by provider transports is excluded from normalized message text and identity. Migration backups are private but may retain the exact pre-migration ledger until the user removes them under the retention policy.

Replacement markers retain useful structure without retaining the value:

```text
[REDACTED_OPENAI_KEY]
/Users/[REDACTED_USER]/Developer/project
[REPOSITORY_PATH]
```

Requirements:

- Redaction occurs before serialization and provider invocation.
- The transient packet and provider's raw response are not persisted or logged; the validated report and selected evidence references are persisted.
- High-risk payload categories are omitted when safe redaction is uncertain.
- Regression tests cover recognized synthetic token patterns, exact repository paths, and home usernames.
- Packet encoding, size, or provider-validation failure falls back to deterministic reporting; collection continues.

No deterministic detector can guarantee discovery of every secret. The packet therefore also minimizes volume and excludes categories that do not materially improve the report.

Trackify never edits the original Codex or Claude cache. Redacting the Trackify ledger cannot revoke a credential or remove it from its upstream conversation history; a credential that was pasted into any agent must still be rotated at its provider.

## 9. Consent and visibility

Initial setup clearly states:

```text
Local statistics and search stay on this Mac.

When AI reports are enabled, Trackify sends a small redacted evidence
packet through your selected Codex or Claude CLI. Full repositories,
diffs, and transcripts are not sent by default.
```

Selecting a provider and applying setup records this consent. Trackify does not interrupt every hourly report with another prompt.

The user can:

- Disable model-generated reports without disabling collection.
- Inspect the stable evidence references retained by a report through the CLI.
- See the provider and model recorded on a generated report.
- Run provider readiness diagnostics without sending repository evidence.

The CLI exposes report and evidence metadata through versioned JSON. V1 does not persist or expose the transient provider packet.

## 10. Search, display, and clipboard

- Full-text search is local.
- Search excerpts may contain imported conversation text and should not appear in notifications or lock-screen content.
- Menu-bar summaries use concise derived text and avoid exposing raw messages.
- Copy actions are explicit and place the requested report on the macOS clipboard.
- Trackify does not monitor, retain, or clear unrelated clipboard contents.
- Clipboard exports may remain visible to other local applications until replaced; the UI communicates that normal macOS behavior.

## 11. Logs and diagnostics

Operational logs may include:

- Component and adapter names.
- Stable opaque record identifiers.
- Counts, durations, versions, health state, and error categories.
- Redacted relative paths only when necessary.

They must not include:

- Conversation text.
- Commit messages by default.
- Source code or diffs.
- Absolute personal paths in exported diagnostics.
- Environment values, command output, tokens, or credentials.
- Provider prompt or response bodies.

`trackify doctor --export <file>` creates diagnostic JSON from an explicit allowlist rather than zipping the Application Support directory. It contains schema/version information, counts, sizes, and health states, but not the data-root path, source paths, raw issue messages, prompts, or message content. The CLI tells the user to review the file before sharing.

## 12. Export and deletion

User data remains user-owned.

V1 deliberately keeps destructive data management small:

- `trackify data export <destination.sqlite>` creates a consistent complete-ledger snapshot with mode `0600`, refuses to overwrite a destination, and warns that the snapshot may contain conversation and repository information.
- `trackify data delete-reports --confirm` removes generated reports and their search entries without deleting source evidence or statistics.
- The source-install uninstall tool preserves the ledger by default. Its explicit `--delete-data` form moves the exact Trackify Application Support directory to Trash so it remains recoverable until Trash is emptied.

Repository-, source-, session-, and date-range deletion are deferred until real usage establishes the safest cascade and preview UX. V1 does not expose a generic SQL-like deletion surface.

Removing a discovery root or adding an exclusion stops future observation but does not silently erase history. Deletion is a separate confirmed operation with a preview of affected record counts.

Report deletion transactionally removes matching FTS rows. Complete-data uninstall uses a recoverable move rather than claiming secure erasure. Secure physical erasure cannot be guaranteed on APFS, SSDs, snapshots, or external backups; the UI and CLI do not claim otherwise.

## 13. Migration backups

- Backups inherit mode `0600` and remain under the private Application Support tree.
- A backup is created only when required for a nontrivial migration or repair.
- Trackify preserves migration backups rather than guessing that recovery is complete.
- Diagnostics show total backup count and size. Automatic retention/pruning is deferred until recovery-success state is explicit; V1 prefers a visible private backup over premature deletion.
- Backups are never uploaded automatically.

## 14. Permissions

Trackify requests only the folders needed for configured roots and supported local caches.

- It never directs users or installer agents to bypass TCC or Gatekeeper.
- It does not require Full Disk Access when selected-folder access is sufficient.
- It does not read provider credential files or the Keychain.
- A denied root degrades only that source.
- Permission health is visible without exposing private path details in exported diagnostics.

The non-App-Sandbox distribution choice is made for practical access to user-selected repositories and local provider caches. Deep ad-hoc code signing, hardened runtime, EdDSA-pinned updates, least-access behavior, and explicit source configuration remain required. The initial non-notarized download is an acknowledged trust-on-first-use boundary.

## 15. Threat boundary

V1 is designed to protect against:

- Accidental upload of excessive local work evidence.
- Accidental credential inclusion in provider packets and diagnostics.
- Other unprivileged local accounts reading the ledger.
- Unauthorized remote access caused by Trackify opening a network service.
- Corrupt or untrusted application updates.
- Accidental deletion during migration, repair, or source exclusion.

V1 does not claim to protect against:

- Malware or code executing as the same user.
- Root or administrator access.
- A compromised Codex, Claude, Git, Sparkle, or macOS installation.
- Provider-side retention after a redacted packet is submitted.
- Secrets that no local rule can recognize.
- Physical recovery from unencrypted storage or retained APFS snapshots.
- Employer device-management or endpoint-monitoring software.

## 16. Security testing

- File and socket permission tests.
- Path traversal and symlink tests for roots, exports, archives, and temporary files.
- Malformed and oversized cache-record tests.
- Malformed, oversized, concurrent, and adversarial hook-envelope tests proving raw payload fields never reach the inbox or ledger.
- SQLite corruption, migration rollback, disk-full, and backup-recovery tests.
- Redaction tests with synthetic secrets in messages, paths, commits, and tool output.
- Evidence-budget tests proving unrelated periods and repositories are excluded.
- Diagnostic-bundle allowlist tests.
- Update-signature, bundle-identity, nested code-integrity, trust-on-first-use, and downgrade tests.
- Collection-lease ownership, expiry, and recovery tests.
- Tests proving no telemetry endpoint or unapproved network request exists.

## 17. V1 acceptance criteria

1. Statistics, search, and deterministic reports work with all network access unavailable.
2. Disabling AI reports prevents provider invocations without stopping collection.
3. Provider packets are bounded, locally redacted, inspectable, and associated with the producing report.
4. Known synthetic secrets never reach provider input, logs, diagnostics, or exported paths.
5. Trackify opens no TCP listener and sends no product analytics.
6. Provider hooks persist only allowlisted structural lifecycle fields and cannot block or alter an agent run.
7. Private ledger, settings, inbox, and database sidecar files are inaccessible to other unprivileged users.
8. Root exclusion stops future observation without silently deleting history.
9. Explicit deletion removes matching search and derived records and explains physical-erasure limitations.
10. Migration backups remain private, bounded, visible, and recoverable.
11. Exported diagnostics contain only allowlisted operational information.
