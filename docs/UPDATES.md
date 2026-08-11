# Trackify Updates and Release Delivery

Status: Sparkle integration and non-notarized release pipeline implemented; first published update pending
Last updated: 2026-08-11

## 1. Purpose

Trackify should tell the user when a trusted update is available and install it with one action:

```text
Trackify 1.2.0 is available
Adapter compatibility and reporting improvements

[Later]                         [Update & Relaunch]
```

Official application bundles are hosted as assets on the public Trackify GitHub repository. Trackify uses [Sparkle 2](https://sparkle-project.org/documentation/) for update discovery, verification, installation, and relaunch. The project does not implement a custom privileged updater.

This document defines the update contract. Initial installation and guided bootstrap are defined in [INSTALLATION.md](./INSTALLATION.md).

## 2. Goals

- Check for stable updates automatically without interrupting work.
- Show a compact update action in the menu and full release notes in Settings.
- Download, verify, install, and relaunch a direct installation with one click.
- Update the application and bundled CLI as one versioned unit.
- Preserve the ledger, configuration, login item, and collection state.
- Make updates equally operable by the UI, CLI, Codex, and Claude Code.
- Recover cleanly from an interrupted download, invalid artifact, failed replacement, or failed database migration.
- Publish reproducible release metadata from the public GitHub repository.

## 3. Non-goals

- Building a custom update framework.
- Pretending a non-notarized first download has Apple-verified publisher identity.
- Replacing Homebrew- or organization-managed installations behind their package manager.
- Running application updates during development builds or pull-request builds.
- Automatically downgrading a ledger after a new application has migrated it.
- Allowing the report provider or conversation collectors to participate in update decisions.

## 4. Update authority by installation origin

Trackify records its installation origin during installation:

```text
direct       release app installed from GitHub
homebrew     installed and owned by Homebrew
managed      installed by an organization or MDM
development  unsigned or locally built development copy
```

Only one system owns updates for an installation:

| Origin | Update authority | Trackify behavior |
|---|---|---|
| Direct | Sparkle | Check, download, verify, install, and relaunch in app |
| Homebrew | Homebrew | Report availability and show the exact `brew upgrade --cask trackify` action |
| Managed | Organization/MDM | Report the installed version; defer replacement to management policy |
| Development | Developer | Disable update checks by default |

The V1 one-link agent installer uses the direct channel. Trackify still records
the installation origin so an externally managed or future Homebrew package
never receives a misleading in-app replacement action.

## 5. User experience

### 5.1 Menu bar dropdown

When an update is ready, the normal footer gains one calm row:

```text
├──────────────────────────────────────────────────┤
│ ↑ Trackify 1.2.0 is available                    │
│   Adapter compatibility and reporting fixes      │
│                                                  │
│ [ Later ]                    [ Update & Relaunch ]│
├──────────────────────────────────────────────────┤
│ Updated 11 seconds ago                       ↻ ⚙ │
└──────────────────────────────────────────────────┘
```

The row does not replace live work data or reports. `Later` dismisses the prompt for the current version until the next reasonable reminder. A security-critical update may be labeled urgent but still must not pretend that installation succeeded before verification and relaunch complete.

### 5.2 Settings

```text
Updates

Current version     1.1.3 (113)
Available version   1.2.0 (120)
Channel             Stable

✓ Check for updates automatically
  Download updates automatically

Adapter compatibility and reporting improvements…
[Release notes]                 [Update & Relaunch]
```

V1 exposes only the stable channel. Automatic checks default on. Automatic downloads may be enabled by the user; installation and relaunch remain explicit unless a later release introduces a clearly disclosed unattended policy.

When no update is available, Settings shows `Check for Updates…`. The menu stays unchanged.

### 5.3 Update states

The UI and CLI use the same state machine:

```text
idle
→ checking
→ available
→ downloading
→ ready_to_install
→ preparing
→ installing
→ relaunching
→ current

checking/downloading/preparing/installing
→ failed, with a recoverable reason and retry action
```

Progress belongs in the update row or Settings. Normal collection stays visible while a download occurs.

## 6. Delivery architecture

### 6.1 GitHub Releases

Each stable Git tag produces one GitHub Release containing:

```text
Trackify-<version>-universal.zip
Trackify-<version>.dmg
release-manifest.json
release-manifest.json.sig
SHA256SUMS
release notes
optional generated SBOM
```

The ZIP is the Sparkle enclosure and contains an internally valid, ad-hoc-signed universal application with its CLI. The DMG supports human installation. The EdDSA-signed JSON manifest supports the one-link installer and repair workflow.

GitHub Releases are the artifact store. A stable GitHub Pages URL serves the Sparkle appcast:

```text
https://vucinatim.github.io/trackify/appcast.xml
```

The appcast points to immutable, versioned GitHub Release assets. Its public location may later move behind an owned custom domain without changing the application trust model.

### 6.2 Two metadata formats, one release

Trackify deliberately publishes two small metadata formats:

- `appcast.xml` follows Sparkle's update protocol and is consumed by the running app.
- `release-manifest.json` follows Trackify's installation protocol and is consumed by installer agents and the narrow repair workflow.

Both are generated from the same tag, version, build, checksums, minimum macOS version, release notes, and immutable asset URLs. Generation fails when these values disagree.

### 6.3 Sparkle integration

The native app owns one update coordinator around Sparkle. SwiftUI and CLI-facing application services depend on a small Trackify-defined interface rather than importing Sparkle throughout the codebase:

```swift
protocol UpdateService {
    func status() async -> UpdateStatus
    func check() async throws -> UpdateStatus
    func installAndRelaunch() async throws
}
```

Production uses `SparkleUpdateService`. Tests and simulations use an in-memory implementation. Update state is operational state, not work evidence, and never enters activity metrics or reports.

## 7. Release pipeline

A protected GitHub Actions release workflow performs:

```text
versioned Git tag
→ clean checkout
→ build and test app + CLI
→ build universal release archive
→ ad-hoc sign the app and every nested executable with hardened runtime
→ verify bundle identities, architectures, versions, and deep code-signature validity
→ sign Sparkle enclosure with EdDSA
→ generate checksums, manifest, appcast, notes, and SBOM
→ create GitHub Release and upload immutable assets
→ publish the stable appcast only after every verification passes
```

Trackify deliberately does not require a paid Apple Developer Program membership. The first download is therefore not notarized and macOS may require the user to confirm opening it. Every installed release pins the Sparkle EdDSA public key, and Sparkle verifies subsequent update archives according to its [publishing guidance](https://sparkle-project.org/documentation/publishing/). The application and every nested executable are still ad-hoc signed so macOS and Sparkle can validate their internal integrity.

Release credentials exist only in the protected GitHub Actions release environment:

- Sparkle EdDSA private key.

The repository implements this as the manually dispatched, protected `Release` workflow. Its `release` environment must provide:

```text
SPARKLE_EDDSA_PUBLIC_KEY
SPARKLE_EDDSA_PRIVATE_KEY
```

The workflow validates tag/build input, reruns tests and privacy checks, builds Universal 2 with `direct` origin, ad-hoc signs nested Sparkle code and the app, verifies identities/architectures/version/deep signature validity, generates the Sparkle appcast, signed manifest, checksums, DMG, and SwiftPM dependency SBOM, then publishes one immutable GitHub Release. GitHub Pages downloads release metadata only after publication. Missing Sparkle credentials fail closed before publication.

Pull-request workflows cannot read release credentials or publish artifacts to the stable feed. The Sparkle public key is compiled into the application. Because Trackify has no Developer ID fallback, losing or rotating the private key without a transition release would break automatic updates; the key must be treated as permanent release infrastructure and backed up outside GitHub Actions.

The public key is pinned in `site/release-public-key.txt`; its SHA-256 fingerprint is `8653df20f10e3ef15a7448b2884444e91d2ceadc76d630b2cc39e248039a65e7`. The private key is stored in the release environment and in the owner's macOS Keychain under account `com.zoulabs.trackify`. The workflow derives the public key from the private seed and requires both to match the committed key before building or publishing.

## 8. Safe update lifecycle

### 8.1 Before replacement

When the user chooses `Update & Relaunch`, Sparkle owns verified download, installation, application termination, and relaunch. Trackify's imports use short transactions and advance a source cursor only after durable writes; derived work is idempotent. An interrupted scan or report therefore leaves the last committed ledger valid and is repaired by normal reconciliation after relaunch. V1 does not add a second custom quiescence protocol around Sparkle.

The app does not wait for external Codex, Claude, build, or test processes to stop. Their later durable cache and Git evidence is reconciled after relaunch. Provider processes also have a bounded deadline, and unfinished report generation never blocks ledger recovery.

### 8.2 After relaunch

The new version:

1. Opens the private ledger and verifies/migrates its schema before collection.
2. Creates a recoverable database backup before applying any migration to an existing schema.
3. Runs migrations transactionally.
4. Starts normal idempotent collection and report catch-up only after the ledger opens successfully.

Interrupted collection is expected and is repaired by normal reconciliation. Trackify must never create a silent empty ledger merely because opening or migrating the existing ledger failed.

### 8.3 Migration failure

If migration fails:

- Preserve the original ledger and backup.
- Do not run collectors against a partially migrated schema.
- Open a focused recovery view with the failure identifier and paths.
- Expose the same state through `trackify doctor --json`.
- Offer retry only when safe.
- Explain when the previous app version cannot reopen a ledger already migrated by a newer version.

Rolling back the application before any schema change is safe. Rolling back after a successful forward migration is allowed only when the previous version explicitly declares the new schema readable.

## 9. Application and CLI versioning

The CLI ships inside `Trackify.app` and the user-scoped installation creates a stable link:

```text
~/.local/bin/trackify
→ ~/Applications/Trackify.app/Contents/SharedSupport/trackify
```

Replacing the bundle therefore updates the app and CLI together. The link is validated after relaunch and repaired when missing. `trackify --version` reports the semantic version; `trackify update status --json` adds build identifier, installation origin, channel, and update authority. Schema migrations remain visible through `trackify doctor --json`.

A CLI binary that is already executing may finish using its loaded old executable. New invocations resolve to the new bundle. Long-running mutating CLI commands participate in the same database lease and graceful-shutdown contract as app jobs.

## 10. CLI and agent contract

```bash
trackify update status [--json]
trackify update check [--json]
trackify update install --relaunch [--json]
```

Representative status:

```json
{
  "schemaVersion": 1,
  "origin": "direct",
  "channel": "stable",
  "currentVersion": "1.1.3",
  "build": "113",
  "state": "idle",
  "installAction": "sparkle",
  "instruction": "Open Trackify to install the signed update.",
  "requiresRelaunch": true
}
```

Agents may check status without confirmation. They may install when the user has asked them to update Trackify or when update permission is explicit in a broader repair request. They must not replace Homebrew or managed installations through the direct channel.

For direct releases, CLI update commands open the registered `trackify://update/check` or `trackify://update/install` application request. The app presents Sparkle's verified update flow; the CLI never reimplements bundle replacement. Homebrew, managed, development, and direct bundles without a configured Sparkle key refuse this path and return their actual owner or disabled state. The local status command reports installed version, build, origin, authority, and instruction; detailed download/install progress remains in Sparkle's app-owned UI in V1.

## 11. Scheduling and network behavior

- Check shortly after launch and then on Sparkle's normal periodic schedule, with jitter rather than synchronized polling.
- Do not delay app launch, collection, or queries while checking.
- Apply exponential backoff after network failure.
- Treat offline, captive-portal, or unavailable-feed states as nonfatal.
- Cache only bounded release metadata and the pending verified archive.
- Never interpret update traffic as development activity.
- Do not send repository names, paths, ledger contents, provider state, or user identifiers in update requests.

V1 has one stable channel. Prerelease channels, phased rollout, critical-update policy, and delta updates may be added later using Sparkle capabilities without changing the domain ledger.

## 12. Security model

After first installation, update trust requires all of the following:

- HTTPS transport.
- Immutable versioned release assets.
- Sparkle EdDSA enclosure signature.
- The public key already embedded in the installed application.
- A valid Sparkle EdDSA signature over the update archive.
- A deeply valid ad-hoc signature over the app and nested executables.
- Version and downgrade policy checks.

Initial installation is explicitly trust-on-first-use from the public GitHub project over HTTPS. A compromised hosting account is therefore in scope for the first download. After installation, control of hosting alone is insufficient to publish an accepted update without the separate Sparkle private key.

Trackify never:

- Executes release-note content.
- Loads code from an update before verification.
- Exposes signing credentials to builds from pull requests.
- Replaces an app with a different bundle identifier.
- Deletes the ledger to recover from an update error.

## 13. Testing

### Update-service tests

- No update, available update, dismissed update, and retry behavior.
- Invalid appcast, invalid enclosure signature, wrong version, and downgrade rejection.
- Offline, interrupted, resumed, and corrupted downloads.
- UI and CLI observe the same update state.
- Development, Homebrew, managed, and direct origins choose the correct action.

### Application lifecycle tests

- Update while collection is idle and active.
- Update while a report, backfill, or rebuild is pending.
- Parallel external agents continue running across app relaunch.
- WAL checkpoint and graceful connection closure.
- Login item and CLI link survive bundle replacement.
- Relaunch resumes reconciliation and idempotent jobs.

### Migration and recovery tests

- Upgrade from every supported ledger schema.
- Migration success, transactional failure, retry, and preserved backup.
- Failure never produces an empty replacement ledger.
- Older application behavior against a newer schema is explicit and safe.
- Disk-full failure before and during migration.

### Release-pipeline tests

- Version and build agree across app, CLI, manifest, appcast, and tag.
- Universal archive contains the expected signed nested binaries.
- App and nested executables have valid ad-hoc signatures and the expected identifiers.
- Sparkle signature verifies with the public key embedded in the previous stable app.
- Pull requests cannot access production signing or publishing credentials.
- Published URLs are immutable and all advertised checksums match.

## 14. V1 acceptance criteria

1. A direct installation discovers a stable update automatically.
2. The menu and Settings show the available version, concise notes, and `Update & Relaunch`.
3. One action downloads, verifies, installs, and relaunches through Sparkle.
4. Invalid or unsigned artifacts are rejected without replacing the current app.
5. The app and CLI advance to the same version.
6. Collection state, source cursors, configuration, login item, and ledger survive the update.
7. An interrupted update leaves either the old or new verified application runnable, never a partial bundle presented as successful.
8. A failed migration preserves the original ledger and exposes a recoverable diagnostic state.
9. Homebrew, managed, and development copies do not present a false direct-install action.
10. Codex or Claude Code can inspect and invoke the same update flow through versioned JSON CLI commands.
11. GitHub Releases host immutable artifacts and the stable appcast is published only after release verification succeeds.
12. The Sparkle private key is unavailable to pull-request builds and recoverably backed up.

## 15. Deferred capabilities

- Beta and nightly channels.
- Phased rollouts.
- Delta updates after full-package reliability is established.
- Explicit critical-update policy.
- Organization-controlled maintenance windows.
- Fully unattended installation and relaunch.
- A non-GitHub artifact mirror.

These additions stay behind the update-service boundary and do not change the evidence ledger or reporting architecture.
