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
| `OpLogSync.cfg` | production values | no violation |
| `OpLogSync_shared.cfg` | `PerDeviceFiles = FALSE` | `LocalNoLoss` violated |
| `OpLogSync_suspend.cfg` | `SealHasSuspensionPoint = TRUE` | `LocalNoLoss` violated |
| `OpLogSync_monotonic.cfg` | adds `RemoteMonotonic` | `RemoteMonotonic` violated |

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

## Bounds

2 devices, 3 ops/device, 1 seal/device. Widening is a deliberate act — TLC's
state count grows fast and the spike has a stopping rule (spec §9).

## What this does not do

TLC verifies the **model**, not `OpLogStore.swift`. No trace validation links
the two; the refinement gap is real and is stated as a first-class input to the
spike's verdict rather than papered over. Where a model's conclusion is pinned
in Swift, it is pinned by a test that cites the config that produced it.
