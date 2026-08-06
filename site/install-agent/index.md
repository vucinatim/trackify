# Install Trackify with a coding agent

Status: conditional stable protocol

This is Trackify's stable agent-installation endpoint. Installation is available only when both of these release-owned files exist:

- `https://vucinatim.github.io/trackify/release-manifest.json`
- `https://vucinatim.github.io/trackify/release-manifest.json.sig`
- `https://vucinatim.github.io/trackify/release-public-key.txt`

If either file is absent, malformed, or disagrees with the latest GitHub Release, stop: no installable stable release is published yet. Do not download or execute unofficial binaries or scripts claiming to install Trackify.

## Trust boundary

The manifest selects an immutable GitHub Release asset and supplies its size and SHA-256 digest. The final trust decision is the downloaded application itself:

```text
Apple code signature is valid
AND TeamIdentifier is PNTJNS22UU
AND bundle identifier is com.zoulabs.trackify
AND Gatekeeper assessment succeeds
AND artifact size and SHA-256 match the manifest
```

HTTPS, GitHub, the manifest, or a checksum alone are insufficient. Never remove quarantine, bypass Gatekeeper, request `sudo`, read provider credentials, or weaken macOS privacy controls.

## Agent protocol

1. Confirm macOS 14 or later, architecture, free space, and whether `~/Applications/Trackify.app` already exists.
2. Fetch the three stable metadata files and the latest GitHub Release metadata. Verify the detached Ed25519 manifest signature against the published raw base64 public key using CryptoKit or an equivalent trusted local verifier; stop if verification cannot be performed. Require matching version, build, asset URL, and tag.
3. Create a fresh private temporary directory. Download the manifest-selected universal ZIP and verify exact byte size and SHA-256.
4. Extract with `/usr/bin/ditto`. Require exactly one `Trackify.app` bundle with the identifiers above, a bundled executable at `Contents/SharedSupport/trackify`, Universal 2 `arm64` and `x86_64` slices, valid code signatures, Team ID `PNTJNS22UU`, and successful `/usr/sbin/spctl --assess --type execute`.
5. Ask for confirmation before first installation or replacement. Quit Trackify, stage the verified bundle beneath `~/Applications`, preserve an existing app as one timestamped backup, and atomically rename the staged bundle to `~/Applications/Trackify.app`.
6. Create `~/.local/bin` if needed and link `~/.local/bin/trackify` to `~/Applications/Trackify.app/Contents/SharedSupport/trackify`. Refuse to replace an unrelated file. Do not edit shell startup files; report a missing PATH entry instead.
7. Run `trackify bootstrap inspect --json`. Use only its bounded aggregate root recommendations, provider states, history footprint, and report ceilings plus reliable information already present in the user's conversation.
8. Present one concise confirmation covering primary groups, provider choice, all-or-none local evidence import, and a recent report window no longer than 14 days.
9. Run the confirmed `trackify bootstrap apply --provider <auto|codex|claude> --backfill-evidence <all|none> --backfill-reports <14d|none> --launch --json`.
10. Run `trackify doctor --json`, open Trackify if needed, and report installed version, roots/repository count, selected provider, collection health, and any explicit macOS or provider-login action still owned by the user.

Bootstrap may mark Claude authentication `authentication_unknown` when the installed Claude Code version has no safe non-interactive status command. That is not permission to read credentials or start an interactive auth probe; the first enabled report verifies access and falls back deterministically if unavailable.

## Repair and rollback

Repair only the verified app bundle, Trackify-owned CLI link, launch-at-login state, migrations, and idempotent collection. Preserve the ledger at `~/Library/Application Support/Trackify/`. Do not reset roots, exclusions, provider choice, or evidence.

Uninstall preserves the ledger by default and moves the app and Trackify-owned link to Trash. Complete data removal requires a separate explicit confirmation and moves the exact Trackify Application Support directory to Trash; never use a broad recursive target.

Full rationale and failure handling remain in the [installation design](https://github.com/vucinatim/trackify/blob/main/docs/INSTALLATION.md). Source and releases live in the [public repository](https://github.com/vucinatim/trackify).
