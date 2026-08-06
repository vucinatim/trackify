# Contributing to Trackify

Trackify is early-stage. Small, focused changes that preserve the local-first evidence architecture are welcome.

## Before contributing

Read:

- [VISION.md](docs/VISION.md)
- [DESIGN.md](docs/DESIGN.md)
- [V1.md](docs/V1.md)
- [PRIVACY_SECURITY.md](docs/PRIVACY_SECURITY.md)
- [SOURCE_COMPATIBILITY.md](docs/SOURCE_COMPATIBILITY.md)

## Architecture rules

- Keep source-specific behavior behind adapters.
- Keep durable evidence separate from derived interpretation.
- Keep business logic in shared Swift packages, not SwiftUI or CLI formatting.
- Prefer a small explicit type or boundary over configuration-driven indirection.
- Do not add a daemon, cloud service, telemetry SDK, or editor integration to V1.
- Do not treat keyboard or mouse idleness as authoritative work state.
- Do not claim completion when source evidence supports only in-progress or unknown state.

## Fixtures and privacy

Never commit a raw Codex or Claude cache file, repository diff, private path, command output, credential, employer/customer identifier, or real conversation text.

Compatibility fixtures must be deterministic and sanitized locally with the scripts under `scripts/compatibility/`. Run:

```bash
bash scripts/check-fixture-privacy.sh
```

## Changes

- Keep pull requests focused and explain architectural impact.
- Add tests for new evidence rules, source shapes, migrations, and time behavior.
- Use injected clocks for time-dependent code.
- Keep JSON CLI output versioned and backward-compatible within a major version.
- Update the relevant design document when changing a public contract.

Run the canonical local checks before opening a pull request:

```bash
swift format lint --recursive --strict Sources Tests Apps Package.swift
swift test
scripts/check-fixture-privacy.sh
git diff --check
```
