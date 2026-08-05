# Repository Discovery and Grouping

Status: Proposed
Last updated: 2026-08-05

## 1. Purpose

Trackify must passively discover and monitor all relevant local Git repositories without requiring users to register repositories individually.

Discovery roots provide deterministic organization for machines with many repositories. For the initial expected setup:

```text
Work
└── ~/Developer/Work
    └── repositories and folder hierarchy

Personal
└── ~/Developer/Personal
    └── repositories and folder hierarchy
```

This document defines discovery, path-based grouping, identity, reconciliation, UI behavior, CLI access, and testing. It supplements [DESIGN.md](./DESIGN.md), [V1.md](./V1.md), and [UI.md](./UI.md).

## 2. Goals

- Discover repositories recursively beneath configured roots.
- Handle more than 60 repositories with negligible ongoing overhead.
- Detect newly cloned, created, moved, and deleted working copies.
- Recognize normal repositories, Git worktrees, submodules, and bare repositories.
- Group repositories automatically using root labels and relative folder hierarchy.
- Preserve repository history when filesystem paths change.
- Avoid double-counting the same working copy or Git history.
- Keep discovery deterministic and explainable without LLM inference.
- Make root and group scopes available to the UI and CLI.

## 3. Non-goals

- Inferring clients, products, or semantic project relationships.
- Treating folders as manually maintained project-management entities.
- Following every filesystem symlink.
- Repeatedly scanning the entire startup disk.
- Modifying repositories or writing Trackify identifiers into them.
- Automatically merging separate clones solely because they share a remote URL.

## 4. Discovery roots

A discovery root is a configured filesystem location with a stable Trackify identifier and display label.

```text
DiscoveryRoot
- id
- canonicalPath
- displayName
- enabled
- sortOrder
- exclusionRules
- createdAt
- lastScannedAt
```

Example configuration:

```bash
trackify roots add ~/Developer/Work --name Work
trackify roots add ~/Developer/Personal --name Personal
```

The initial setup suggests a display name derived from the directory name. The user may rename it once, but routine grouping requires no interaction.

During agent-driven installation, deterministic discovery returns a bounded candidate-root manifest. The installer agent may combine that manifest with reliable knowledge from the current conversation to recommend primary groups, but it never receives or analyzes raw source code to decide group labels.

Trackify may offer a one-time broader discovery scan to suggest additional roots. Continuous monitoring remains limited to explicitly enabled roots to avoid unnecessary filesystem access and noise.

## 5. Initial discovery

For each enabled root, the scanner recursively traverses accessible directories and recognizes:

### Normal working copies

A directory containing a `.git` directory.

### Git worktrees and submodules

A directory containing a `.git` file that points to a Git directory or common directory.

### Bare repositories

A directory with the expected bare Git structure, including `HEAD`, `objects`, and refs metadata. Bare repositories appear in the catalog but do not produce working-tree statistics.

### Nested repositories

Independent nested repositories and configured submodules are registered separately. The scanner never descends into the internal `.git` object database.

The scanner canonicalizes discovered paths and validates candidates with Git before writing them to the ledger.

## 6. Traversal rules

The scanner skips known noisy or generated locations by default:

```text
.git
node_modules
.build
DerivedData
vendor
.cache
.Trash
```

Additional rules:

- User-configured exclusions override default discovery.
- Filesystem symlinks are not followed by default, preventing cycles and duplicate discovery.
- A symlink may be registered explicitly as a root, after which its canonical target is monitored.
- Permission failures are recorded in source health rather than terminating the entire scan.
- Package directories and application bundles are skipped unless explicitly configured.
- The scanner applies a bounded concurrency limit to avoid excessive disk pressure.
- Discovery never invokes commands that modify a repository.

The exact default exclusion list must be validated against real development roots and remain user-visible.

## 7. Continuous discovery

Discovery uses two complementary mechanisms.

### Filesystem observation

macOS filesystem events provide prompt detection of:

- Newly cloned or created repositories.
- Renamed or moved directories.
- Removed working copies.
- Changes that may require repository reinspection.

Events are coalesced before scanning affected paths so a large clone or dependency installation does not trigger excessive work.

### Periodic reconciliation

A periodic root scan repairs state missed because of:

- Application restart.
- Machine sleep.
- Event coalescing or event-stream loss.
- Permission changes.
- Sources being mounted or restored later.

Reconciliation is idempotent. An unchanged repository produces no duplicate ledger records.

## 8. Repository and working-copy identity

Filesystem paths are locations, not identities.

```text
Repository
├── Remote identities
└── WorkingCopy
    ├── Git common-directory evidence
    └── WorkingCopyLocation history
```

### Repository

Represents a logical Git history known to Trackify.

```text
Repository
- id
- displayName
- kind
- firstSeenAt
- lastSeenAt
```

### Working copy

Represents one local checkout or worktree.

```text
WorkingCopy
- id
- repositoryId
- kind
- gitDirectoryFingerprint
- firstSeenAt
- lastSeenAt
- missingSince
```

### Location history

Tracks paths and root membership over time.

```text
WorkingCopyLocation
- id
- workingCopyId
- discoveryRootId
- canonicalPath
- relativePath
- observedFrom
- observedUntil
```

This allows historical work to remain associated with the root under which it occurred, even when a working copy later moves.

## 9. Moves, clones, and ambiguity

### Live rename or move

When filesystem observation provides a reliable rename relationship, Trackify updates the working copy's location history while preserving identity.

### Move discovered after downtime

Trackify attempts a conservative match using available evidence such as:

- Git common-directory structure.
- Normalized remote identities.
- HEAD and reference fingerprints.
- The disappearance and appearance timing of candidates.

An automatic match occurs only when the result is unique and sufficiently supported. Otherwise Trackify preserves separate records rather than incorrectly merging histories.

### Separate clones

Separate clones remain separate working copies even when they reference the same remote. They may share one logical repository when identity is clear, but time and filesystem observations remain attributable to the correct working copy.

### Remote changes

Remote URLs are evidence, not primary identity. Remote history is retained because repositories may change hosting providers or remote names.

## 10. Automatic grouping

Grouping is derived from the discovery root and current or historical relative path.

```text
Work
├── clients/client-a/api
├── clients/client-a/web
├── internal/tools
└── experiments/demo

Personal
├── trackify
├── finance-tool
└── experiments/demo
```

Rules:

- The discovery-root display name is the primary group.
- Relative folder segments form optional visual subgroups.
- Subfolders do not require database entities.
- Chains containing a single child can be visually collapsed.
- Folder hierarchy is used only for navigation and filtering, not as repository identity.
- Moving a repository changes its current group while location history preserves prior grouping.
- Similar folder names under separate roots remain distinct.

This grouping is deterministic. No LLM or statistical classifier is involved.

## 11. Application behavior

The menu dropdown shows only repositories active today:

```text
TODAY
3 repositories

trackify          2h 38m    3 commits
client-api        1h 21m    3 commits
website             13m    no commits
```

The sidebar shows recent repositories beneath collapsed root groups:

```text
REPOSITORIES

▾ Work                                      38
    client-api                         ● active
    internal-tools                   42m today
    View all 38…

▾ Personal                                  24
    trackify                           ● active
    another-project                   18m today
    View all 24…

▸ Other                                      3
```

The repository catalog provides the complete searchable list. Full UI behavior is defined in [UI.md](./UI.md).

## 12. CLI behavior

Required root commands:

```bash
trackify bootstrap inspect --json
trackify roots list
trackify roots add <path> --name <name>
trackify roots scan [<root>]
trackify roots enable <id>
trackify roots disable <id>
trackify roots exclude <id> <pattern>
```

Required repository queries:

```bash
trackify repos
trackify repos --group Work
trackify repos --path clients/client-a
trackify today --group Personal
trackify timeline --group Work --since 30d
trackify context --group Personal --since 7d
```

All commands support stable identifiers and query commands support `--json`.

`roots scan` runs the same idempotent discovery pipeline used by continuous collection. It does not create a separate CLI-only discovery implementation.

## 13. Data and query behavior

- Repository queries may scope by repository, working copy, discovery root, or relative path prefix.
- Root totals aggregate repository evidence without double-counting shared or overlapping work intervals.
- Historical queries use location membership valid at the event time.
- Current repository lists use the latest active location.
- Missing working copies remain in history and are marked unavailable rather than deleted.
- Rediscovered working copies clear `missingSince` when identity matches.
- Excluded repositories retain existing history but stop receiving new observations unless explicitly deleted.

## 14. Performance expectations

Sixty repositories do not require a special scaling architecture.

V1 should target:

- Streaming traversal rather than loading the entire filesystem tree into memory.
- Bounded concurrent Git inspection.
- Coalesced filesystem events.
- Incremental reconciliation based on path and repository fingerprints.
- No Git history walk when HEAD and relevant refs are unchanged.
- No working-tree diff calculation when status fingerprints are unchanged.
- Background work scheduled with low user-visible impact.

Performance tests should include at least 100 working copies and a mixture of clean, dirty, nested, missing, and inaccessible repositories.

## 15. Backfill behavior

Initial discovery triggers configurable historical Git backfill for each repository.

- Commit history is imported for the requested date range.
- Current working-tree state is observable, but historical uncommitted states cannot be reconstructed unless another source retained that evidence.
- Conversation sessions may supply historical repository associations and activity.
- Repeating discovery and backfill does not duplicate repositories or evidence.
- Newly discovered repositories can be backfilled independently without rebuilding unrelated history.

Trackify must be explicit about unavailable historical information rather than inferring file activity that no source preserved.

## 16. Failure behavior

- An inaccessible root is marked degraded while other roots continue collecting.
- A missing root is not immediately deleted; its last known repositories remain queryable.
- Invalid Git candidates are ignored and recorded only in diagnostics when useful.
- A slow or corrupt repository cannot block the entire root scan.
- Git command timeouts produce retryable collector errors.
- Exclusion or permission changes trigger targeted reconciliation.

## 17. Testing

### Discovery fixtures

- Normal repositories.
- Git worktrees.
- Submodules.
- Bare repositories.
- Nested independent repositories.
- Symlink loops.
- Inaccessible directories.
- Default and configured exclusions.

### Identity scenarios

- Repository renamed while Trackify is running.
- Repository moved while Trackify is offline.
- Two clones sharing one remote.
- Local repository without a remote.
- Remote URL changed.
- Working copy deleted and later restored.
- Git history rebased or force-pushed.

### Scale scenarios

- At least 100 repositories under several nested folders.
- Large dependency folders excluded from traversal.
- Many filesystem events emitted during a clone.
- Reconciliation after application sleep or restart.

### Grouping scenarios

- Two roots with similar folder names.
- Repository moved between Work and Personal.
- Single-child folder chains collapsed visually.
- Historical query uses the root valid at event time.
- Root-scoped totals avoid interval double-counting.

## 18. V1 acceptance criteria

1. Adding a discovery root automatically finds all supported repositories beneath it.
2. Newly created or cloned repositories appear without manual registration.
3. More than 60 repositories remain searchable and navigable without filling the menu or sidebar.
4. Root labels provide automatic Work, Personal, or equivalent top-level grouping.
5. Relative folder hierarchy provides deterministic subgrouping.
6. Normal repositories, worktrees, submodules, and bare repositories are classified correctly.
7. Known noisy directories and configured exclusions are not traversed unnecessarily.
8. Repository moves observed live preserve working-copy history.
9. Ambiguous offline moves do not cause destructive automatic merges.
10. Missing or inaccessible roots do not stop collection for healthy roots.
11. Reconciliation and repeated scanning remain idempotent.
12. Root and folder scopes are available through the GUI and CLI.
13. Historical root membership remains queryable after a repository moves.
14. Initial Git backfill imports available commit history without pretending to reconstruct unavailable uncommitted work.
15. Agent-driven setup recommends root groups from bounded aggregate evidence rather than raw repository contents.
