# Trackify

Trackify is a passive, native macOS development-work ledger. It observes local Git repositories and supported Codex and Claude Code histories, then produces simple statistics, searchable context, and concise evidence-backed hourly and daily reports.

The same local ledger is available through the macOS menu-bar application and a first-class `trackify` CLI for coding agents.

> [!IMPORTANT]
> Trackify V1 and the Goal 2 configurable work-intelligence source implementation are complete. Public distribution still requires the project owner's Developer ID certificate, notarization credentials, Sparkle signing key, and signed-release soak.

## Principles

- Passive by default: no timers, tasks, or routine manual classification.
- Evidence before interpretation: imported evidence is durable; activity snapshots, comparisons, and reports are rebuildable.
- Core history uses durable Git and conversation facts. Optional lifecycle telemetry may improve live status but never manufactures historical work.
- Completed, unfinished, investigating, waiting, and inactive work remain distinct.
- Local-first: no Trackify account, server, analytics, or automatic crash upload.
- GUI and CLI use the same domain queries and local SQLite ledger.

## Implemented capabilities

- Native Swift/SwiftUI menu-bar app with an interactive historical Overview, unified searchable Activity ledger, and grouped Projects browser.
- Automatic Git repository discovery and deterministic folder-based grouping.
- Separate versioned Codex CLI/Desktop, Claude Code terminal, and Claude Desktop Code conversation-source adapters.
- Active evidence hours, LLM turns, commits, files, repository, and line statistics.
- Deterministic reports plus optional Codex or Claude generation through a persisted, budgeted queue that never blocks collection.
- Versioned report recipes, immutable evidence-linked artifacts, private/team/client/public privacy profiles, and local clipboard/Markdown/JSON delivery.
- Native Sources, Summaries, Usage, and Recipes preferences with honest per-run token/cost provenance.
- Historical backfill and accelerated virtual-time simulation.
- Agent-readable installation, diagnostics, context retrieval, and updates.

## Documentation

- [Vision](docs/VISION.md)
- [V1 specification](docs/V1.md)
- [Goal 2 specification](docs/GOAL_2.md)
- [Goal 2 acceptance audit](docs/GOAL_2_ACCEPTANCE_AUDIT.md)
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

Statistics, search, evidence, and reports are stored locally. When AI reporting is enabled, Trackify sends a bounded, locally redacted evidence packet through the report provider selected during setup. It does not send full repositories, diffs, or transcripts by default.

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
swift run trackify recipes list --json
swift run trackify recipes create --from docs/examples/standup-recipe.json --json
swift run trackify recipes preview daily-work-summary --period today --json
swift run trackify artifacts list --since 7d --json
swift run trackify show session <session-id> --message-limit 20 --json
swift run trackify show report <report-id> --evidence-limit 20 --json
swift run trackify update status --json
TRACKIFY_ARCHITECTURES=native scripts/build-app-bundle.sh .build/bundle
```

Source-build lifecycle scripts install a previously built and verified bundle without `sudo`, repair only Trackify's CLI link, and move uninstall targets to Trash:

```bash
TRACKIFY_ALLOW_UNSIGNED=1 scripts/install-local.sh .build/bundle/Trackify.app --launch
scripts/repair-local.sh
scripts/uninstall-local.sh                 # keeps the ledger
scripts/uninstall-local.sh --delete-data   # explicitly trashes the ledger too
```

`TRACKIFY_ALLOW_UNSIGNED=1` is for local development bundles only. Published direct releases must pass the built-in Developer ID and Gatekeeper verification.

The implementation sequence and remaining gates are tracked in [V1_READINESS.md](docs/V1_READINESS.md).

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

The license does not grant rights to use project trade names or trademarks except as required for reasonable and customary description of the work's origin.
