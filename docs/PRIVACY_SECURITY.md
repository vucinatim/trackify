# Trackify Privacy and Security Contract

Status: V1 baseline
Last updated: 2026-08-05

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
- Selected normalized tool, build, or test observations needed for work history.
- Source identifiers, timestamps, hashes, adapter versions, and observation cursors.

### Derived local data

- Activity intervals and work episodes.
- Hourly and daily rollups.
- Moving-average comparisons.
- Evidence packets.
- Reports and report revisions.
- Full-text search indexes.

### Operational data

- Configuration, exclusions, provider selection, and discovery roots.
- Health records, resumable jobs, leases, and application heartbeat.
- Update state and installation origin.
- Local diagnostic logs that exclude evidence content.

## 4. Storage minimization

V1 stores normalized session message text because durable search and historical context are core product functions. It does not copy every raw cache file wholesale.

Default rules:

- Store normalized message text, roles, timestamps, associations, and required lifecycle evidence.
- Store source hashes and adapter versions so changed records can be detected.
- Do not persist complete source-code file contents.
- Do not persist full Git diffs by default.
- Do not persist binary tool output, terminal screen buffers, images, attachments, or arbitrary raw tool payloads by default.
- Normalize only the tool fields required for activity, state, repository association, and evidence inspection.
- Keep unsupported payload categories out of the ledger until their use and privacy cost are defined.

The compatibility spike decides the smallest raw fields required for correct idempotency and parsing. Adding a new retained payload requires a schema review and an update to this contract.

## 5. Local filesystem protection

Canonical data root:

```text
~/Library/Application Support/Trackify/
```

V1 requirements:

- Data and runtime directories use mode `0700`.
- Ledger, configuration, logs, exports created by default, migration backups, and runtime files use mode `0600`.
- The local control socket is accessible only to the current user.
- Temporary files use fresh private directories and are removed after completion.
- The application never weakens source-file permissions.
- Exporting to a user-selected location clearly transfers responsibility for that copy.

V1 relies on macOS user separation and FileVault for at-rest protection. It does not add SQLCipher or a custom encryption layer. This avoids background key-unlock problems and substantial database complexity while the original Codex and Claude caches are already readable by the same logged-in user.

This protects against casual access by other unprivileged accounts. It does not protect against malware, administrators, root access, a compromised logged-in account, or a machine whose disk is accessible without FileVault. Diagnostics should warn when FileVault is disabled without blocking use.

## 6. Network boundaries

Trackify itself contacts only:

1. The configured Sparkle appcast and GitHub-hosted signed release assets.
2. The locally installed Codex or Claude CLI when the user has enabled model-generated reports or an explicit provider test.

Trackify has no analytics endpoint in V1.

Update requests contain normal network metadata such as IP address and user agent but no repository, session, path, provider, ledger, or productivity data.

Provider behavior follows [LLM_PROVIDERS.md](./LLM_PROVIDERS.md). Provider credentials remain owned by the provider CLI and are never read, copied, stored, or logged by Trackify.

## 7. Provider evidence packets

Before invoking Codex or Claude, Trackify constructs a local bounded packet. It may contain:

- Repository display aliases rather than absolute root paths.
- Relative file paths when useful.
- Commit messages and short hashes.
- File and line statistics.
- Run states and time boundaries.
- Selected redacted conversation excerpts.
- References to the local evidence identifiers supporting each period.

It does not contain by default:

- Full repository diffs.
- Full transcripts.
- Absolute home-directory paths.
- Environment dumps.
- Credential files or known secret-bearing files.
- Raw terminal buffers or arbitrary tool payloads.
- Evidence from unrelated repositories or periods.

Evidence selection and redaction happen before the provider process starts. A prompt instruction to ignore secrets is not a substitute for local filtering.

## 8. Deterministic redaction

The redaction pipeline runs locally and is versioned independently from prompts.

It removes or replaces:

- Private keys and certificate blocks.
- Common API keys, bearer tokens, access tokens, session cookies, and authorization headers.
- Credential-valued environment assignments.
- Password, secret, and token fields from structured payloads.
- Contents of known credential and environment files.
- Absolute home-directory prefixes and usernames.
- Provider credentials and authentication configuration.

Replacement markers retain useful structure without retaining the value:

```text
[REDACTED_SECRET]
[REDACTED_HOME]/Developer/project
[OMITTED_CREDENTIAL_FILE]
```

Requirements:

- Redaction occurs before evidence packet persistence and provider logging.
- Logs record counts and redaction-rule versions, never removed values.
- High-risk payload categories are omitted when safe redaction is uncertain.
- Adversarial fixtures test multiline secrets, split tokens, structured fields, command output, and false positives.
- A failed redaction stage fails the report job closed; collection continues.

No deterministic detector can guarantee discovery of every secret. The packet therefore also minimizes volume and excludes categories that do not materially improve the report.

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
- Inspect the locally stored packet for a report.
- See provider, model profile, packet version, redaction version, and generation time.
- Run a provider test using synthetic evidence.
- Regenerate a report after filtering rules change.

The CLI exposes equivalent packet metadata through versioned JSON. Raw redacted packet content is returned only when explicitly requested.

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

An exported diagnostic bundle is generated from an allowlist, not by zipping the Application Support directory. The user sees its exact contents before sharing.

## 12. Export and deletion

User data remains user-owned.

V1 provides explicit exports by date, repository, source type, and record type. Exports default to a private file and display a warning that they may contain conversation and repository information.

Deletion supports:

- A repository or working copy.
- A conversation source or session.
- A date range.
- Derived reports only.
- The complete ledger and configuration during explicit uninstall.

Removing a discovery root or adding an exclusion stops future observation but does not silently erase history. Deletion is a separate confirmed operation with a preview of affected record counts.

After deletion, Trackify removes matching FTS and derived records, checkpoints SQLite, and makes deleted rows unreachable through normal queries. Secure physical erasure cannot be guaranteed on APFS, SSDs, snapshots, or external backups; the UI must not claim otherwise.

## 13. Migration backups

- Backups inherit mode `0600` and remain under the private Application Support tree.
- A backup is created only when required for a nontrivial migration or repair.
- Trackify keeps the latest recoverable migration backup until at least one successful launch and reconciliation on the new schema.
- Obsolete migration backups are removed after 14 days unless recovery is still pending.
- Diagnostics show backup size, schema version, creation time, and scheduled removal.
- Backups are never uploaded automatically.

## 14. Permissions

Trackify requests only the folders needed for configured roots and supported local caches.

- It never directs users or installer agents to bypass TCC or Gatekeeper.
- It does not require Full Disk Access when selected-folder access is sufficient.
- It does not read provider credential files or the Keychain.
- A denied root degrades only that source.
- Permission health is visible without exposing private path details in exported diagnostics.

The non-App-Sandbox distribution choice is made for practical access to user-selected repositories and local provider caches. Code signing, hardened runtime, notarization, least-access behavior, and explicit source configuration remain required.

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
- SQLite corruption, migration rollback, disk-full, and backup-recovery tests.
- Redaction tests with synthetic secrets in messages, paths, commits, and tool output.
- Evidence-budget tests proving unrelated periods and repositories are excluded.
- Diagnostic-bundle allowlist tests.
- Update signature, Team ID, notarization, and downgrade tests.
- CLI control-socket authorization, size, version, and stale-endpoint tests.
- Tests proving no telemetry endpoint or unapproved network request exists.

## 17. V1 acceptance criteria

1. Statistics, search, and deterministic reports work with all network access unavailable.
2. Disabling AI reports prevents provider invocations without stopping collection.
3. Provider packets are bounded, locally redacted, inspectable, and associated with the producing report.
4. Known synthetic secrets never reach provider input, logs, diagnostics, or exported paths.
5. Trackify opens no TCP listener and sends no product analytics.
6. Private files and the local control socket are inaccessible to other unprivileged users.
7. Root exclusion stops future observation without silently deleting history.
8. Explicit deletion removes matching search and derived records and explains physical-erasure limitations.
9. Migration backups remain private, bounded, visible, and recoverable.
10. Exported diagnostics contain only allowlisted operational information.
