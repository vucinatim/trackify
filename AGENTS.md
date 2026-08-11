# Trackify Agent Guidance

## Engineering standard

Prefer the cleanest minimal architecture. Simplicity and explicit boundaries are more valuable than speculative configurability.

- Do not add shortcuts that duplicate business logic across the app and CLI.
- Stop and propose a structural refactor when a change would otherwise introduce lasting coupling.
- Keep source adapters, domain rules, persistence, application use cases, and presentation separate.
- Preserve user work and unrelated changes in a dirty worktree.
- Use `rg` or `rg --files` for repository search.
- Use `apply_patch` for deliberate text edits.

## Privacy

Never inspect or commit raw local conversation content when a structural profile is sufficient. Raw Codex and Claude cache files must not enter the workspace. Use the sanitized compatibility workflow documented in `Tests/Fixtures/README.md`.

Before committing fixture changes, run:

```bash
bash scripts/check-fixture-privacy.sh
```

## Architecture

- `Trackify.app` owns continuous scheduling.
- The CLI and GUI share domain and application use cases.
- Durable source evidence is immutable; derived records are rebuildable.
- Time-dependent code receives an injected clock and scheduler.
- Unknown or incomplete evidence remains explicit.
- No daemon, cloud backend, telemetry SDK, semantic search, or editor plugin belongs in V1.

Build and test commands will be added after the Swift package is scaffolded.
