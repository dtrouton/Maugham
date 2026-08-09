# formal/ — model-checked specs

Machine-checked models of Maugham protocols. Written for the 2026-08-01
formal-methods evaluation spike; see
[`docs/superpowers/specs/2026-08-01-formal-methods-spike-design.md`](../docs/superpowers/specs/2026-08-01-formal-methods-spike-design.md).

## Running

```
./formal/check.sh OpLogSync                    # baseline, expect GREEN
./formal/check.sh OpLogSync OpLogSync_shared   # expect VIOLATION
```

First run downloads `tools/tla2tools.jar` (~10 MB, gitignored).

## Java

Needs a JDK: `brew install openjdk`.

Deliberately the **formula**, not the `temurin` cask. The cask installs into
`/Library/Java/JavaVirtualMachines` and needs `sudo`; the formula installs into
the Homebrew prefix and needs no password. The formula is keg-only — it is not
symlinked into `PATH`, and `/usr/bin/java` will not find it — so `check.sh`
resolves the interpreter itself (`JAVA_HOME`, then `PATH`, then the Homebrew
prefix). Nothing needs to be added to your shell profile.

## Configs

| Config | Constants | Expected |
|---|---|---|
| `OpLogSync.cfg` | production values, `MaxCps = 0` | no violation |
| `OpLogSync_shared.cfg` | `PerDeviceFiles = FALSE` | `LocalNoLoss` violated |
| `OpLogSync_suspend.cfg` | `SealHasSuspensionPoint = TRUE` | `LocalNoLoss` violated |
| `OpLogSync_monotonic.cfg` | adds `RemoteMonotonic` | `RemoteMonotonic` violated |
| `OpLogSync_cpshared.cfg` | `PerDeviceCheckpoints = FALSE` | `CheckpointNoLoss` violated |
| `OpLogSync_cppartitioned.cfg` | `PerDeviceCheckpoints = TRUE` | no violation |
| `OpLogSync_dangling.cfg` | checkpoints partitioned | `DanglingMeansLost` violated |
| `OpLogSync_cpdetect.cfg` | `PerDeviceCheckpoints = FALSE` | `CheckpointLossIsDetected` violated |

The first four set `MaxCps = 0`, which disables checkpoints entirely — so they
measure exactly what they measured before checkpoints were added to the model,
and remain a clean regression signal.

**`OpLogSync_cpshared.cfg` modelled production as it shipped until FM-1.**
`PerDeviceCheckpoints = FALSE` was not a hypothetical: `CheckpointStore` pointed
every device at one `.maugham/checkpoints.jsonl`, and `PublicationStore` at one
`.maugham/publications.jsonl`. Its violation described a live defect. Its
partner `OpLogSync_cppartitioned.cfg` is the same spec with ADR 0012's pattern
applied, and is green — that pair is the proof that partitioning is the fix
rather than a tidy-up.

**Since FM-1 it is `_cppartitioned` that models production**, and `_cpshared`
has become an ordinary falsification partner: it must keep exiting 12, because
what it now describes is the regression. `CheckpointStore.fileURL` /
`PublicationStore.fileURL` cannot name the unsuffixed file, so re-sharing the
stream is not reachable by accident; the Swift-side pins are
`MaughamTests/CheckpointPartitioningTests.swift`.

**A non-zero exit from a falsification config is the intended result.** Each
pair exists to prove an assumption is load-bearing rather than decorative
(spec §5): the model is run *without* the assumption to confirm TLC produces a
counterexample, then *with* it to confirm green. An assumption that cannot be
falsified is decorative and is dropped from the findings.

A falsification config that starts *passing* means the model drifted — not
that a bug was fixed.

One `.tla` with four `.cfg`s, rather than four spec variants, is deliberate: a
falsification that requires editing the model proves nothing, because the
edited model is a different model. Driving falsification from constants makes
the green run and the counterexample run provably the same spec.

## AnnotationRace.tla

A second, separate model: the annotation lifecycle against the manuscript text
it splices. Smaller and independent of `OpLogSync.tla` — it abstracts the op
log to a totally-ordered set, which is the contract `OpLogSync` established.

    ./formal/check.sh AnnotationRace AnnotationRace_NoRejectedButSpliced

| Config | Expected |
|---|---|
| `AnnotationRace_NoRejectedButSpliced` | **violated** — rejected, yet the change is in the manuscript |
| `AnnotationRace_NoOpenButSpliced` | **violated** — unresolved, yet the change is in the manuscript |
| `AnnotationRace_AcceptedImpliesSpliced` | no violation (a useful negative — bounds the defect to the two shapes above) |
| `AnnotationRace_NoArchivedButSpliced` | violated, and **not a bug** — archiving an accepted annotation legitimately leaves the text spliced. Asserted only to make the archive arm visible in a counterexample. |

Predictions were pre-registered in `PREDICTIONS-annotation.md` and committed
before the model existed, so confirmation can be told from discovery. That file
is deliberately **never edited** — its value is entirely in having been written
first.

## BackupRetention.tla

Backup retention against auto-bisect (ADR 0014) — deliberately **off** the op
log, as a test of whether the approach generalises.

    ./formal/check.sh BackupRetention BackupRetention_NoCorruptRetainedOverIntact

| Config | Expected |
|---|---|
| `BackupRetention_NoCorruptRetainedOverIntact` | **violated** — prune deletes an intact generation while keeping a corrupt one |
| `BackupRetention_NoWedgedOnCorruptNewest` | **violated** — a corrupt newest generation with a surviving marker suppresses all further backups |
| `BackupRetention_Fixed_NoCorruptRetainedOverIntact` | no violation — `IntactAwarePrune = TRUE` |
| `BackupRetention_Fixed_NoWedgedOnCorruptNewest` | no violation — `IntactAwareSkip = TRUE` |
| `BackupRetention_Fixed_All` | no violation — both fixes on, all four properties, so fixing one is shown not to break the two that already held |
| `BackupRetention_Full_R2C1`, `_Full_R3C2` | no violation — with retention full, fewer corruptions than the retention count always leaves something recoverable |
| `BackupRetention_RunLeavesAnIntact` | no violation |

**The two `Fixed_` configs are FM-2's red/green pair**, and they are pairs in
the same sense `cpshared`/`cppartitioned` are: one constant apart, same spec.
`IntactAwarePrune = FALSE` and `IntactAwareSkip = FALSE` are the shipped
behaviour the first two rows describe, which is why every pre-existing config
pins both to `FALSE` — those configs remain falsification partners and are
*meant* to exit 12. A `Fixed_` config that starts failing means the Swift's
model drifted; a non-`Fixed_` one that starts passing means the model drifted.

Each `Fixed_` config turns on exactly ONE constant, so the pair proves which
change closes which property rather than showing that some combination does.

`BackupRetention_FewerCorruptionsThanRetentionKeepsAnIntact.cfg` is **retained
deliberately as a bad example** and is expected to be violated: the property
omits the "retention is actually full" antecedent, so it fails on one
generation and one corruption — trivially true and nothing to do with the
system. Kept because §10.3 counts it, and because a property-formulation error
is the most likely way this directory produces a wrong answer.

## Bounds

2 devices, 3 ops/device, 1 seal/device. Widening is a deliberate act — TLC's
state count grows fast and the spike has a stopping rule (spec §9).

## What this does not do

TLC verifies the **model**, not `OpLogStore.swift`. No trace validation links
the two; the refinement gap is real and is stated as a first-class input to the
spike's verdict rather than papered over. Where a model's conclusion is pinned
in Swift, it is pinned by a test that cites the config that produced it.
