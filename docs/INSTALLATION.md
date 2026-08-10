# Trackify Installation and Distribution

Status: V1 protocol implemented; signed release publication pending
Last updated: 2026-08-05

## 1. Purpose

Trackify should be installable by giving Codex or Claude Code one stable link and asking the agent to install it.

The target experience is:

> Install and set up Trackify using https://vucinatim.github.io/trackify/install-agent/

The agent downloads a signed release, verifies it, installs the macOS application and CLI, detects the user's existing coding-agent environment, starts repository discovery and backfill, runs diagnostics, and opens Trackify.

Installation can be almost entirely automatic. Provider authentication and macOS-protected folder access may still require explicit user approval; Trackify must guide those approvals rather than attempting to bypass them.

Provider behavior is defined in [LLM_PROVIDERS.md](./LLM_PROVIDERS.md).
Application update delivery is defined in [UPDATES.md](./UPDATES.md).

## 2. Goals

- Install the native application and CLI from one stable agent-readable entry point.
- Support Codex-driven and Claude-driven installation equally.
- Avoid requiring the user to understand package managers or shell configuration.
- Preserve macOS code-signing, notarization, Gatekeeper, and privacy controls.
- Detect installed Codex and Claude CLIs, proving authentication only when the observed CLI exposes a safe non-interactive status command.
- Configure a working summary provider without copying credentials.
- Discover likely repository roots and prepare concise group recommendations.
- Ask one consolidated setup question covering groups and backfill scope.
- Import broad local evidence while limiting initial model-generated reports to a useful recent window.
- Launch the menu bar app and show partial results immediately.
- Make install, repair, update, and bootstrap operations idempotent.
- Produce machine-readable diagnostics agents can act on safely.

## 3. Non-goals

- Silently bypassing macOS security or privacy prompts.
- Copying Codex or Claude credentials.
- Bundling provider CLIs inside Trackify.
- Installing a provider CLI without making that action explicit.
- Requiring root access for the default installation path.
- Executing an unverifiable remote shell script as the only installation method.
- Blocking first launch until all repositories and historical sessions are backfilled.
- Asking a model to inspect raw filesystem trees, repository lists, transcripts, or diffs during setup.

## 4. Release artifacts

Each release contains:

- A signed and notarized universal macOS application.
- A signed universal `trackify` CLI executable built from the same source revision.
- A user-scoped installation archive or installer.
- An optional signed system package for managed deployment.
- A Homebrew cask for developer-friendly installation.
- A signed update manifest.
- SHA-256 checksums for every downloadable artifact.
- Release notes and schema compatibility information.

The app and CLI report the same semantic version and build identifier.

The provisional V1 baseline is macOS 14 or later with a Universal 2 application and CLI. It remains subject to a one-time workplace fleet check before release. The release manifest exposes the final target so the installation agent can reject incompatible systems before downloading an artifact.

## 5. Installation channels

### 5.1 Agent-driven direct installation

This is the canonical experience. The agent reads a versioned protocol, downloads a signed artifact, verifies it, installs it into user-writable locations, bootstraps Trackify, and opens the app.

Default locations:

```text
Application: ~/Applications/Trackify.app
CLI:         ~/.local/bin/trackify
Data:        ~/Library/Application Support/Trackify/
```

The agent may use `/Applications` when the user requests a system-wide install and authorization is available. User-scoped installation is preferred because it avoids unnecessary administrator privileges.

### 5.2 Homebrew

When Homebrew is installed and healthy, the agent may use the official Trackify cask. The cask installs the app and links the CLI into the active Homebrew prefix.

Representative future command:

```bash
brew install --cask trackify
```

The agent-readable protocol determines whether Homebrew or the direct signed artifact is the cleaner path on the current machine.

### 5.3 Managed package

A signed package may later support company-managed distribution through MDM. Managed installation remains optional and does not shape the personal V1 bootstrap flow beyond using the same application, CLI, and configuration formats.

## 6. Agent-readable installation endpoint

`https://vucinatim.github.io/trackify/install-agent/` serves concise Markdown containing:

- The current stable release manifest URL.
- Supported macOS versions and architectures.
- Exact download and verification steps.
- Expected Team ID and bundle identifiers.
- Installation paths.
- Bootstrap commands.
- Known user-approval boundaries.
- Repair and rollback guidance.
- A clear completion checklist.

The endpoint must be stable and human-readable. Versioned protocol pages remain available for older installers:

```text
https://vucinatim.github.io/trackify/install-agent/
https://vucinatim.github.io/trackify/install-agent/v1/
```

The unversioned endpoint selects the current stable protocol. It must not contain instructions that disable Gatekeeper, quarantine checks, code signing, or macOS privacy protections.

## 7. Release manifest

The installation endpoint references a machine-readable manifest:

```json
{
  "schemaVersion": 1,
  "version": "1.0.0",
  "build": "100",
  "minimumMacOS": "14.0",
  "assets": {
    "universal": {
      "url": "https://github.com/vucinatim/trackify/releases/download/v1.0.0/Trackify-1.0.0-universal.zip",
      "sha256": "<sha256>",
      "size": 12345678
    }
  },
  "signing": {
    "teamId": "PNTJNS22UU",
    "applicationBundleId": "com.zoulabs.trackify",
    "cliIdentifier": "com.zoulabs.trackify.cli"
  }
}
```

The update manifest itself is signed. An HTTPS URL and checksum alone are not treated as the complete application-update trust model.

## 8. Agent installation protocol

The installer agent follows these steps.

### Step 1: Inspect

- Confirm the operating system is macOS.
- Detect architecture and macOS version.
- Check whether Trackify is already installed.
- Check whether Homebrew is available.
- Check available disk space.
- Detect `codex` and `claude` executables without reading their credential files.
- Detect documented lifecycle-hook capability, existing Trackify integration state, trust requirements, and managed-policy restrictions without changing provider configuration.

### Step 2: Resolve release

- Fetch the stable agent installation document.
- Fetch and validate the signed release manifest.
- Select the matching architecture or universal artifact.
- Refuse unsupported systems with a clear explanation.

### Step 3: Download safely

- Download into a newly created temporary directory.
- Verify artifact size and SHA-256 checksum.
- Verify Apple code signature and expected Team ID.
- Verify notarization and Gatekeeper assessment.
- Stop without installing if any verification fails.

### Step 4: Install

- Quit an existing Trackify process gracefully when upgrading.
- Preserve the current database and configuration.
- Install or replace the application atomically.
- Install or link the CLI.
- Ensure the CLI location is available to the user's normal shell, using the smallest necessary shell-path change.
- Never overwrite unrelated files or shell configuration.

### Step 5: Bootstrap

Run deterministic local inspection:

```bash
trackify bootstrap inspect --json

trackify bootstrap inspect --json
```

Inspection:

- Creates the database and initial migrations.
- Detects supported provider CLIs and the authentication certainty each version can report safely.
- Locates likely repository roots and counts repositories beneath them.
- Suggests deterministic labels from folder names, session paths, and existing installer context.
- Estimates available evidence, active report periods, provider calls, and input tokens.
- Returns a bounded setup manifest rather than raw paths, transcripts, or file listings.

The installer agent combines this manifest with reliable knowledge already present in its conversation, then presents one concise recommendation and confirmation question.

After confirmation, run:

```bash
trackify roots add <path> --name <group>
trackify bootstrap apply \
  --provider <codex|claude> \
  --backfill-evidence all \
  --backfill-reports 14d \
  --launch \
  --json
```

Apply:

- Configures the confirmed roots and group labels.
- Selects the confirmed report provider.
- Reports the optional bounded Codex/Claude hook target without rewriting provider configuration.
- Opens the app immediately with collection temporarily paused, then performs evidence import and recent-report generation as separate bounded phases against the shared ledger.
- Registers launch-at-login.
- Starts the app.
- Returns structured progress and outstanding user actions.

### Step 6: Diagnose

Run:

```bash
trackify doctor --json
```

The agent repairs only safe, in-scope problems. It leaves authentication and macOS privacy approval to the user and explains exactly what remains.

### Step 7: Open and hand off

The agent opens Trackify and reports:

- Installed version.
- Selected report provider.
- Discovered roots and repository count.
- Backfill progress.
- Outstanding user approvals.
- Overall health.

## 9. Bootstrap contract

`trackify bootstrap inspect` is read-only apart from creating an empty initialized ledger when one does not exist. `trackify bootstrap apply` is idempotent. Running apply repeatedly:

- Does not duplicate roots, repositories, sessions, evidence, or reports with the same stable revision identity.
- Does not overwrite an explicit provider selection.
- Does not reset exclusions or user settings.
- Leaves application/CLI-link repair to the narrow installer repair tool.
- Applies pending database migrations once.
- Rechecks provider and source health.
- Safely repeats idempotent import after an interrupted apply.

Options:

```bash
trackify bootstrap inspect --json
trackify bootstrap apply --provider auto|codex|claude
trackify bootstrap apply --backfill-evidence all|none
trackify bootstrap apply --backfill-reports <duration>|none
trackify bootstrap apply --launch
trackify bootstrap apply --json
```

Bootstrap never silently installs or authenticates Codex or Claude.

V1 does not rewrite Codex or Claude configuration during bootstrap. It exposes the bounded `trackify integrations emit` hook target and durable cache reconciliation; a user or managed provider configuration may point documented lifecycle hooks at that target. Automatic provider-configuration editing remains deferred until both providers expose stable, versioned contracts. This keeps setup additive and prevents Trackify from replacing unrelated settings or bypassing trust and organization policy.

## 10. Provider detection during setup

Trackify checks:

```bash
codex --version
codex login status

claude --version
```

Outcomes:

```text
Only Codex ready
  select Codex automatically

Only Claude installed, authentication unknown
  select Claude automatically and verify on the first enabled report;
  fall back to a deterministic report if access is unavailable

Both available
  installer agent may pass the provider explicitly;
  otherwise request one lightweight choice

Neither ready
  finish installing Trackify;
  open the appropriate provider login flow;
  keep deterministic reports and statistics working;
  let the user enable a provider later
```

The provider choice affects report generation only. Trackify still imports every supported local Codex and Claude session source it discovers.

Hook configuration is independent from report-provider readiness. `trackify integrations status` reports the private local inbox and confirms that durable cache reconciliation remains active. Hooks are optional accelerators; cache-only collection remains a complete supported mode.

## 11. Repository-root discovery during setup

Bootstrap performs a bounded one-time search for likely development roots. It may use:

- Existing Codex and Claude session working directories.
- Directories containing several Git working copies.
- Common development folder names.
- Explicit paths supplied by the installer agent.

High-confidence roots can be configured automatically when accessible. Ambiguous candidates are shown as suggestions rather than causing a full-home continuous watch.

### 11.1 Bounded setup manifest

`trackify bootstrap inspect --json` returns aggregate setup evidence:

```json
{
  "providers": [
    {
      "id": "claude",
      "status": "ready",
      "recommended": true
    }
  ],
  "candidateRoots": [
    {
      "path": "~/Developer/Work",
      "suggestedLabel": "Work",
      "repositoryCount": 38,
      "recentRepositoryCount": 17,
      "associationEvidence": ["folder-name", "recent-sessions"]
    },
    {
      "path": "~/Developer/Personal",
      "suggestedLabel": "Personal",
      "repositoryCount": 24,
      "recentRepositoryCount": 8,
      "associationEvidence": ["folder-name"]
    }
  ],
  "unassignedRepositoryCount": 0
}
```

The manifest is capped to a small number of candidate roots and contains aggregate evidence only. It does not send the installer agent every repository path, raw message, file path, diff, commit, or source-code fragment.

### 11.2 Recommendation behavior

The installer agent recommends groups using this precedence:

1. Explicit information already supplied by the user.
2. Reliable knowledge from the current installation conversation.
3. Discovery-root folder names and relative hierarchy.
4. Repository density beneath a candidate root.

The agent states uncertainty when a label is ambiguous. It does not infer employers, clients, or sensitive semantic categories from source code.

The recommended interaction is one consolidated question:

```text
Trackify found 62 repositories:

• Work — ~/Developer/Work
  38 repositories, including most recent work activity

• Personal — ~/Developer/Personal
  24 repositories

I recommend tracking both groups, importing all available Git and
conversation evidence, and generating detailed reports for the last
14 days. Claude is installed and will be used for reports with Opus;
this version verifies authentication on the first report call.

Should I apply this setup and begin the backfill?
```

Additional questions are asked only when ambiguity would materially change what is monitored, which provider is billed, or how much report generation is requested.

Example agent-supplied setup:

```bash
trackify roots add ~/Developer/Work --name Work
trackify roots add ~/Developer/Personal --name Personal
trackify bootstrap apply \
  --provider codex \
  --backfill-evidence all \
  --backfill-reports 14d \
  --launch
```

Repository discovery and grouping are defined in [REPOSITORY_DISCOVERY.md](./REPOSITORY_DISCOVERY.md).

## 12. Backfill planning and token control

Evidence import and model-generated reporting are separate choices.

Recommended first-run policy:

```text
All available history
├── Evidence and statistics: import locally
└── AI-generated reports
    ├── Last 14 days: generate initially
    └── Older periods: generate on demand
```

Evidence import includes available commits, sessions, timestamps, repository associations, and deterministic statistics. It does not consume model tokens.

`trackify bootstrap inspect --json` includes a bounded backfill plan before the agent asks for confirmation:

```json
{
  "historyFiles": 317,
  "historyBytes": 28490123,
  "initialReportDays": 14,
  "maximumProviderCalls": 14,
  "maximumInputTokens": 86016,
  "note": "Evidence import is local and token-free. Reports run only for active days; smart compilation caps provider evidence at 20 KiB per call."
}
```

The plan reports the discovered history-file footprint and conservative ceilings. Actual provider calls are lower because inactive days make no model call. It does not claim a dollar cost because subscription, API, and organization billing differ.

Token controls:

- Never invoke a provider for `no_activity`.
- Reduce evidence locally before provider invocation.
- Aggregate repeated file changes and omit unchanged observations.
- Prefer file paths, commit messages, statistics, and selected session excerpts over full diffs or transcripts.
- Enforce a per-period evidence budget.
- Use packet-local aliases instead of sending stable ledger identifiers.
- Preserve user intent, concrete outcomes, final state, and parallel-project
  coverage before lower-value progress narration.
- Batch adjacent report periods when the provider contract can return one validated result per period.
- Build daily reports from hourly reports and day-level deltas.
- Defer older reports until a user or agent opens, searches, or explicitly requests them.
- Keep evidence import and report-generation phases separate in structured bootstrap output.

## 13. Required user interaction

Trackify and installer agents must be honest about actions macOS or providers require the user to approve.

### 13.1 Provider login

If no selected provider is authenticated, the user must complete the provider's browser or organization login flow. The installer can start the flow but cannot complete identity verification on the user's behalf.

### 13.2 Provider hook trust and policy

Codex may require the user to review and trust a newly installed non-managed hook definition. Organization policy may disable or restrict user and plugin hooks in either provider. Trackify and the installer agent surface the exact state and normal provider-native review action; they never bypass trust or managed policy.

Declining or being unable to enable hooks does not block setup. Trackify continues with persisted-cache observation and labels current-state latency accordingly.

### 13.3 Protected folder access

Desktop, Documents, network volumes, external volumes, and other protected locations may require access approval for the Trackify application itself. Existing permission granted to Codex or Claude does not automatically transfer to Trackify.

The app opens a focused approval screen:

```text
Trackify needs access to your development folders:

□ ~/Developer/Work
□ ~/Developer/Personal

[Allow folders]
```

Trackify uses normal macOS permission and folder-selection mechanisms. The installer never instructs an agent to bypass TCC, grant Full Disk Access through unsupported means, remove quarantine attributes to evade Gatekeeper, or alter system security settings.

### 13.4 First launch and login item

macOS may present first-launch, downloaded-application, background-item, or login-item notifications. Signing and notarization minimize friction but do not eliminate policy-controlled approval.

### 13.5 Administrator authorization

User-scoped installation should not need administrator authorization. A system-wide installation or managed package may require it and must ask explicitly.

## 14. Immediate experience

Trackify opens before discovery and backfill complete.

```text
● Trackify is running

Repositories discovered       31 of 64
Git history imported          18 of 64
Claude sessions               Importing…
Reports                       Available for 12 repositories
```

Requirements:

- Partial results become visible immediately.
- Repository discovery, Git/conversation import, activity querying, and report generation fail independently and remain safe to repeat.
- The menu bar remains responsive during setup.
- Backfill resumes after restart.
- Missing provider authentication does not prevent Git statistics.
- Missing permission for one root does not block accessible roots.

## 15. CLI installation

The CLI executable ships with the app and is linked into a user-accessible binary directory.

Requirements:

- `trackify --version` matches the installed app build.
- The CLI can locate the shared Application Support database without environment configuration.
- The app can repair a missing CLI link.
- The CLI can print an agent-oriented command for repairing shell-path configuration.
- Installation does not replace an unrelated executable named `trackify` without explicit confirmation.

The app should also expose an `Install or Repair CLI` action in Diagnostics for users who do not use the agent-driven installer.

## 16. Launch at login

Trackify registers itself using the supported macOS login-item mechanism from the application. The agent does not create an ad hoc shell LaunchAgent plist.

Requirements:

- Registration is idempotent.
- The user can disable it in Trackify settings.
- Diagnostics report whether the login item is registered and permitted.
- App updates preserve registration.
- Login-item failure does not prevent manual launch.

## 17. Updates

Trackify needs dependable updates because Codex and Claude local formats and CLI behavior may evolve.

Direct installations use Sparkle 2. Signed, notarized application archives are hosted as immutable GitHub Release assets, and a stable appcast is published through GitHub Pages. The separate signed JSON release manifest remains the protocol for one-link agent installation and repair; both metadata formats describe the same release artifacts.

Trackify records whether an installation is direct, Homebrew-owned, managed, or a development build. Only direct installations are replaced by Sparkle. The other origins defer to their owning update mechanism.

The app checks the stable channel automatically and exposes `Update & Relaunch` in the menu and Settings. The CLI exposes the same coordinator:

```bash
open -a Trackify
```

Sparkle owns verified replacement and relaunch. Trackify relies on transactional imports, post-commit cursors, bounded subprocesses, and idempotent reconciliation rather than a second custom updater protocol. After relaunch it opens the ledger, creates a recoverable backup before migrating an existing schema, runs migrations transactionally, and resumes reconciliation. A failure preserves the existing ledger rather than silently creating an empty database.

The complete release pipeline, trust model, user experience, migration behavior, and acceptance criteria are specified in [UPDATES.md](./UPDATES.md).

## 18. Repair

Agent-readable health command:

```bash
trackify doctor --json
```

Safe repair may:

- Restore a missing CLI link.
- Re-register launch at login.
- Validate and reopen the database.
- Rebuild derived indexes.
- Retry failed migrations when safe.
- Re-detect provider executables.
- Resume interrupted backfill.
- Re-run source discovery.

Repair does not delete source evidence, reset configuration, log out providers, or request broad permissions automatically.

The source tree includes `scripts/repair-local.sh` for the currently implemented user-scoped repair. It verifies the expected bundle identity, refuses to replace an unrelated `~/.local/bin/trackify`, restores only Trackify's CLI link, and runs `trackify doctor`. Signed-release repair will use the same narrow behavior after artifact verification.

## 19. Uninstallation and data retention

Uninstallation separates application binaries from the user-owned ledger.

```bash
scripts/uninstall-local.sh
scripts/uninstall-local.sh --delete-data
```

Default uninstall:

- Stops Trackify.
- Quits the running app before changing files.
- Moves the app and Trackify-owned CLI link to Trash.
- Preserves the ledger and configuration.

`--delete-data` is explicit and moves the exact Application Support directory to Trash rather than permanently deleting it. An unrelated CLI-path file is never replaced or removed. Launch-at-login registration is harmless once the bundle is absent and is removed through the app when available; signed installer validation still covers that lifecycle.

For a locally built bundle, `scripts/install-local.sh <Trackify.app> [--launch]` stages the app, preserves an existing bundle as a timestamped backup, installs to `~/Applications`, creates the stable CLI link, and runs diagnostics. Published direct bundles must pass Developer ID Team `PNTJNS22UU` and Gatekeeper verification; unsigned development bundles require the explicit `TRACKIFY_ALLOW_UNSIGNED=1` override. The installer never edits shell startup files or uses `sudo`.

## 20. Security requirements

- All official release artifacts are signed and notarized.
- Agents verify checksum, signature identity, and Gatekeeper assessment.
- Downloads use HTTPS and a signed manifest.
- Installation uses a fresh temporary directory.
- Archive extraction rejects path traversal and unexpected absolute paths.
- User-scoped install never invokes `sudo`.
- Shell commands use explicit paths and validated targets.
- Existing installations are backed up or replaced atomically.
- Database and configuration remain user-only readable.
- Provider credentials are never read, copied, logged, or transmitted by Trackify.
- Installer logs redact usernames, home paths when exported, tokens, and environment secrets.
- The agent installation protocol never recommends disabling macOS security controls.

## 21. Testing

### Installer matrix

- Apple silicon and supported Intel macOS when included in V1 support.
- Clean user without Homebrew.
- User with Homebrew.
- Existing current installation.
- Existing older installation with migration.
- Read-only `/Applications` with writable `~/Applications`.
- CLI path present and absent.
- Existing unrelated `trackify` executable.

### Provider matrix

- Codex installed and authenticated.
- Claude installed and authenticated.
- Both installed and authenticated.
- Installed but logged out.
- Unsupported CLI version.
- Organization policy blocks the requested model.
- Neither provider installed.
- External hooks sending valid allowlisted events.
- Hooks absent or disabled while cache ingestion remains healthy.
- Duplicate hook and cache observations.
- Malformed or oversized hook envelopes rejected without blocking provider work.
- Repeated integration install and removal preserve unrelated provider configuration.

### Guided setup matrix

- Two obvious roots and one ready provider produce one recommendation question.
- Ambiguous root labels are identified without source-code inspection.
- Existing conversation knowledge can refine a folder label.
- The setup manifest remains within its candidate and output limits.
- Evidence-all/report-recent recommendations produce the correct separate bounded phases.
- The agent asks again before materially expanding report history.

### Permission matrix

- Repositories in unprotected folders.
- Repositories under Desktop or Documents.
- External drive unavailable at setup.
- One accessible and one inaccessible root.
- User declines folder access.
- Login item disabled by policy.

### Failure and recovery

- Checksum mismatch.
- Signature mismatch.
- Notarization or Gatekeeper failure.
- Network interruption during download.
- App replacement interrupted.
- Bootstrap interrupted during backfill.
- Migration failure with preserved original database.
- Repair run after partial installation.
- Repeated bootstrap and installation remain idempotent.
- Invalid Sparkle enclosure signature.
- Update during collection, report generation, backfill, and simulation.
- Bundle replacement followed by successful and failed ledger migrations.
- Direct, Homebrew, managed, and development update ownership.

## 22. V1 acceptance criteria

1. Giving Codex the stable installation link is sufficient for it to install, bootstrap, diagnose, and open Trackify except for explicit user approvals.
2. Giving Claude Code the same link produces the same result.
3. Release artifacts are verified before installation.
4. The default installation path requires no administrator privileges.
5. App and CLI versions match.
6. Codex authentication is detected through its non-interactive status command; Claude Code versions without such a command remain explicitly `authentication_unknown` until the first enabled report invocation, without reading credentials.
7. A single ready provider is selected automatically; when readiness is unknown, the first enabled generation verifies it without a separate setup step.
8. Both-provider and no-provider states produce clear bounded setup actions.
9. The app opens before bounded backfill finishes; temporary collection pause prevents a duplicate app import while bootstrap owns the first pass.
10. Protected folder access uses standard macOS approval.
11. Launch-at-login is registered through the application and remains user-controllable.
12. Repeating bootstrap does not duplicate configuration or ledger data.
13. Failed installation or update does not destroy the existing ledger.
14. `trackify doctor --json` gives an installer agent enough information to verify completion.
15. Updates remain signed, recoverable, and compatible with database migrations.
16. Uninstallation preserves the ledger unless data removal is explicitly requested.
17. The installer agent recommends primary groups from a bounded deterministic setup manifest and reliable conversation knowledge.
18. Normal installation requires at most one consolidated setup confirmation beyond provider login and macOS approvals.
19. The default recommendation imports all available local evidence but generates reports only for a recent window.
20. Backfill planning exposes history footprint plus conservative provider-call and input-token ceilings before confirmation.
21. Direct installations expose a verified one-click Sparkle update while other installation origins defer to their owner.
22. The app and bundled CLI update as one versioned unit from GitHub Release artifacts.
23. Supported Codex and Claude hooks can target the bounded `integrations emit` bridge without changing the ledger contract.
24. Missing, disabled, or unsupported hooks do not block cache-only collection.
25. Trackify V1 does not own or rewrite provider configuration, so disabling an external hook leaves durable imported history intact.

## 23. Completion boundary

Agent-driven installation is successful when:

```text
signed app and CLI installed
→ provider state detected
→ optional hook target reported; cache reconciliation remains active
→ repository roots discovered or awaiting explicit folder approval
→ app opened and initial bounded backfill performed idempotently
→ launch at login registered
→ Trackify opened
→ doctor reports healthy or lists only explicit user actions
```

“One-link installation” means the agent performs every safe mechanical step. It does not mean the agent impersonates the user, bypasses authentication, or defeats macOS privacy controls.
