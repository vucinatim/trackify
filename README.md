# Trackify

Trackify is a passive, native macOS development-work ledger. It observes local Git repositories and supported Codex and Claude Code histories, then produces simple statistics, searchable context, and concise evidence-backed hourly and daily reports.

The same local ledger is available through the macOS menu-bar application and a first-class `trackify` CLI for coding agents.

> [!IMPORTANT]
> Trackify is currently in the V1 architecture and compatibility-spike phase. There is no installable release yet.

## Principles

- Passive by default: no timers, tasks, or routine manual classification.
- Evidence before interpretation: imported evidence is durable; reports and rollups are rebuildable.
- Agent work counts even while the keyboard and mouse are idle.
- Completed, unfinished, investigating, waiting, and inactive work remain distinct.
- Local-first: no Trackify account, server, analytics, or automatic crash upload.
- GUI and CLI use the same domain queries and local SQLite ledger.

## Planned V1

- Native Swift/SwiftUI menu-bar app with Today, Calendar, repository, and search views.
- Automatic Git repository discovery and deterministic folder-based grouping.
- Versioned Codex and Claude Code conversation adapters.
- Tracked work, agent runtime, commits, files, and line statistics.
- Hourly and daily reports through an authenticated Codex or Claude CLI.
- Historical backfill, range rebuilds, and accelerated virtual-time simulation.
- Agent-readable installation, diagnostics, context retrieval, and updates.

## Documentation

- [Vision](docs/VISION.md)
- [V1 specification](docs/V1.md)
- [System design](docs/DESIGN.md)
- [V1 readiness checklist](docs/V1_READINESS.md)
- [Privacy and security](docs/PRIVACY_SECURITY.md)
- [Conversation-source compatibility](docs/SOURCE_COMPATIBILITY.md)
- [UI design](docs/UI.md)
- [Repository discovery](docs/REPOSITORY_DISCOVERY.md)
- [LLM providers](docs/LLM_PROVIDERS.md)
- [Installation](docs/INSTALLATION.md)
- [Updates](docs/UPDATES.md)
- [Brand and icon](docs/BRAND.md)

## Privacy

Statistics, search, evidence, and reports are stored locally. When AI reporting is enabled, Trackify sends a bounded, locally redacted evidence packet through the report provider selected during setup. It does not send full repositories, diffs, or transcripts by default.

See [PRIVACY_SECURITY.md](docs/PRIVACY_SECURITY.md) for the precise V1 contract and threat boundary.

## Development status

The compatibility fixtures and design documents are ready. The next implementation step is the headless Swift ledger vertical slice described in [V1_READINESS.md](docs/V1_READINESS.md).

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

The license does not grant rights to use project trade names or trademarks except as required for reasonable and customary description of the work's origin.
