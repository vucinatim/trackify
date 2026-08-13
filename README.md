# Trackify

Trackify is a passive, native macOS development-work ledger. It observes local Git repositories and supported Codex and Claude Code histories, then produces simple statistics, searchable context, canonical work summaries, and user-configured reports.

The same local ledger is available through the macOS menu-bar application and a first-class `trackify` CLI for coding agents.

> [!IMPORTANT]
> Trackify V1 through Goal 5 are implemented and locally validated. The first public release and live update drill remain release operations; Trackify intentionally uses an ad-hoc-signed, non-notarized first install and EdDSA-signed Sparkle updates rather than paid Apple Developer ID distribution.

## Principles

- Passive by default: no timers, tasks, or routine manual classification.
- Evidence before interpretation: imported evidence is durable; activity snapshots, summaries, comparisons, and reports are rebuildable.
- Core history uses durable Git and conversation facts. Optional lifecycle telemetry may improve live status but never manufactures historical work.
- Completed, unfinished, investigating, waiting, and inactive work remain distinct.
- Local-first: no Trackify account, server, analytics, or automatic crash upload.
- GUI and CLI use the same domain queries and local SQLite ledger.

## Implemented capabilities

- Native Swift/SwiftUI menu-bar app with an interactive historical Overview, unified searchable Activity ledger, grouped Projects browser, configurable Reports workspace, and in-window Settings.
- Automatic Git repository discovery and deterministic folder-based grouping.
- Separate versioned Codex CLI/Desktop, Claude Code terminal, and Claude Desktop Code conversation-source adapters.
- Active evidence hours, LLM turns, commits, files, repository, and line statistics.
- A programmatic current-work snapshot refreshed every 15 minutes, a Codex or Claude summary for the immediately preceding hour when it contains work, and local daily rollups composed from those built-in summaries.
- Rich summary objects contain an overall narrative, dense menu-bar narrative, explicit per-project sections, intent, outcomes, open work, blockers, statistics, coverage, and provenance.
- User-configured reports consume canonical summaries plus direct evidence through a persisted, budgeted queue that never blocks collection.
- Versioned report recipes, immutable evidence-linked artifacts, private/team/client/public privacy profiles, and local clipboard/Markdown/JSON delivery.
- Native Sources, AI Providers, Usage, and General settings plus report-template editing, one-off prompts, manual generation, history, provenance, and copy.
- Historical backfill and accelerated virtual-time simulation.
- Agent-readable installation, diagnostics, context retrieval, and updates.

## Documentation

- [Vision](docs/VISION.md)
- [V1 specification](docs/V1.md)
- [Goal 2 specification](docs/GOAL_2.md)
- [Goal 2 acceptance audit](docs/GOAL_2_ACCEPTANCE_AUDIT.md)
- [Goal 3 canonical summaries](docs/GOAL_3_SUMMARIES.md)
- [Goal 4 canonical evidence integrity](docs/GOAL_4_EVIDENCE_INTEGRITY.md)
- [Goal 5 live evidence and responsive UI](docs/GOAL_5_LIVE_EVIDENCE.md)
- [System design](docs/DESIGN.md)
- [V1 readiness checklist](docs/V1_READINESS.md)
- [V1 acceptance audit](docs/V1_ACCEPTANCE_AUDIT.md)
- [Privacy and security](docs/PRIVACY_SECURITY.md)
- [Conversation-source compatibility](docs/SOURCE_COMPATIBILITY.md)
- [UI design](docs/UI.md)
- [Repository discovery](docs/REPOSITORY_DISCOVERY.md)
- [LLM providers](docs/LLM_PROVIDERS.md)
- [Installation](docs/INSTALLATION.md)
- [Updates](docs/UPDATES.md)
- [Brand and icon](docs/BRAND.md)
- [V1 validation record](docs/VALIDATION.md)

## Privacy

Statistics, search, evidence, summaries, and reports are stored locally. When AI summaries or reports are enabled, Trackify sends bounded, locally redacted evidence packets through the selected local CLI. Summary coverage includes complete sanitized user messages and commit messages across chunks; assistant responses are explicitly bounded. Trackify never sends full repositories or diffs.

See [PRIVACY_SECURITY.md](docs/PRIVACY_SECURITY.md) for the precise contract and threat boundary.

## Development status

The repository contains the native app, shared Swift domain and query layers, versioned GRDB migrations, bounded Git/Codex/Claude collection, optional lifecycle-hook inbox, report providers, deterministic simulation, bootstrap flow, and release-bundle tooling. Sanitized compatibility fixtures and contract tests cover both conversation adapters.

Requirements: macOS 14 or later and Swift 6.

```bash
swift test
swift run trackify --help
swift run trackify simulate --scenario foundation --speed instant --json
swift run trackify simulate --scenario foundation --speed instant --days 2 \
  --output-data-root /tmp/trackify-simulated-ledger

# Rich deterministic history for UI and integration validation
swift run trackify simulate --scenario showcase --speed instant --days 42 \
  --output-data-root /tmp/trackify-showcase-ledger
swift run trackify doctor --export /tmp/trackify-diagnostic.json
swift run trackify data export /tmp/trackify-ledger.sqlite
swift run trackify context --today --all --max-characters 12000
swift run trackify context --repo current --since 14d --json
swift run trackify sources status --json
swift run trackify providers status --json
swift run trackify usage runs --since 7d --json
swift run trackify summaries status --json
swift run trackify summaries refresh --days 2 --json
swift run trackify summaries list --limit 20 --json
swift run trackify recipes list --json
swift run trackify recipes create --from docs/examples/standup-recipe.json --json
swift run trackify recipes create --from docs/examples/clockify-entry-recipe.json --json
swift run trackify recipes preview daily-work-summary --period today --json
swift run trackify reporters list --json
swift run trackify reporters create --name "Daily work summary" \
  --template daily-work-summary --cadence daily --json
swift run trackify reporters disable <reporter-id>
swift run trackify reports preview --template stand-up-draft --period today \
  --instructions "Focus on completed work, current work, and blockers" --json
swift run trackify reports generate --template stand-up-draft --period today \
  --instructions "Focus on completed work, current work, and blockers" --json
swift run trackify reports list --since 7d --json
swift run trackify artifacts list --since 7d --json
swift run trackify show session <session-id> --message-limit 20 --json
swift run trackify show summary <summary-id> --json
swift run trackify update status --json
TRACKIFY_ARCHITECTURES=native scripts/build-app-bundle.sh .build/bundle
```

Local contributors with an Apple Development certificate should set
`TRACKIFY_DEVELOPMENT_SIGNING_IDENTITY` to its identity name or SHA-1 hash.
Keeping that identity stable across rebuilds lets macOS retain Files & Folders
permissions; the script falls back to ad-hoc signing when it is unset.

Source-build lifecycle scripts install a previously built and verified bundle without `sudo`, repair only Trackify's CLI link, and move uninstall targets to Trash:

```bash
TRACKIFY_ALLOW_UNSIGNED=1 scripts/install-local.sh .build/bundle/Trackify.app --launch
scripts/repair-local.sh
scripts/uninstall-local.sh                 # keeps the ledger
scripts/uninstall-local.sh --delete-data   # explicitly trashes the ledger too
```

`TRACKIFY_ALLOW_UNSIGNED=1` is for local development bundles only. Published direct releases must pass deep code-signature, identifier, embedded update-key, manifest-signature, and checksum verification. They are not Apple-notarized, so first launch may require macOS's one-time **Open Anyway** confirmation.

The implementation sequence and remaining gates are tracked in [V1_READINESS.md](docs/V1_READINESS.md).

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

The license does not grant rights to use project trade names or trademarks except as required for reasonable and customary description of the work's origin.
