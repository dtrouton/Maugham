# Formal Methods Evaluation Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decide whether TLA+ earns a standing place in Maugham, by modelling the op-log sync + seal protocol and producing a written list of its load-bearing but unwritten assumptions.

**Architecture:** A PlusCal spec (`formal/OpLogSync.tla`) of N devices over an adversarial filesystem, checked with TLC. The spec carries **two boolean model constants** that each drive a falsification pair — the same spec, two configs, one expected green and one expected to produce a counterexample trace. Nothing under `Maugham/` or `Packages/` changes except one test and one comment.

**Tech Stack:** PlusCal / TLA+, TLC (`tla2tools.jar`), Eclipse Temurin JDK, Bash, Swift/XCTest for the one landed guard.

## Global Constraints

- **Spec source:** `docs/superpowers/specs/2026-08-01-formal-methods-spike-design.md`. Every task below implements a numbered section of it; cite the section in the commit.
- **This is a spike with a stopping rule (spec §9).** If Task 3 and Task 4 both come back green *and* no assumption survived falsification, stop and write the "no" in Task 6. Do not widen bounds looking for a result.
- **Production behaviour must not change.** The only files touched under `Maugham/` or `Packages/` are `MaughamTests/TripwireGrepTests.swift` (Task 5) and a comment in `OpLogStore.swift` (Task 5). If the spike finds a live defect, it is *reported and scheduled*, never fixed inline.
- **Bounds (spec §4.5):** 2 devices, 3 ops per device, 1 seal per device for the first cycle. Widen only if green and cheap.
- **`formal/tools/` is gitignored.** `tla2tools.jar` is ~10 MB of third-party binary and must never be committed.
- **Every falsification is two-directional (spec §5):** run the model *without* the assumption and confirm TLC produces a counterexample, then *with* it and confirm green. An assumption that cannot be falsified is decorative and is dropped from the findings.
- **Do not run the full Maugham test suite** for Tasks 1–4 and 6 — they touch no Swift. Only Task 5 needs `xcodebuild`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `formal/README.md` | how to run a check; what each config means; the bounds table |
| `formal/check.sh` | one-command driver: verify Java, fetch the jar if missing, translate PlusCal, run TLC |
| `formal/.gitignore` | excludes `tools/` and TLC's `states/` scratch output |
| `formal/OpLogSync.tla` | the model — grows across Tasks 2, 3, 4 |
| `formal/OpLogSync.cfg` | baseline config: both knobs set to the true-to-production values; expected GREEN |
| `formal/OpLogSync_shared.cfg` | `PerDeviceFiles = FALSE`; expected LocalNoLoss VIOLATION (Task 2) |
| `formal/OpLogSync_suspend.cfg` | `SealHasSuspensionPoint = TRUE`; expected LocalNoLoss VIOLATION (Task 3) |
| `formal/OpLogSync_monotonic.cfg` | adds `RemoteMonotonic`; expected VIOLATION (Task 4) |
| `MaughamTests/TripwireGrepTests.swift` | the one landed guard (Task 5) |
| `docs/superpowers/notes/2026-08-01-formal-methods-spike-findings.md` | assumption list, traces, verdict (Task 6) |

**Why one `.tla` and four `.cfg`s rather than four spec variants:** a falsification that requires *editing the model* proves nothing — the edited model is a different model. Driving falsification from constants means the green run and the counterexample run are provably the same spec.

---

### Task 1: Toolchain and the one-command driver

**Files:**
- Create: `formal/README.md`
- Create: `formal/check.sh`
- Create: `formal/.gitignore`
- Create: `formal/Hello.tla`, `formal/Hello.cfg` (throwaway smoke target, deleted in Task 2)

**Interfaces:**
- Consumes: nothing.
- Produces: `./formal/check.sh <SpecName>` — translates `formal/<SpecName>.tla` from PlusCal and runs TLC against `formal/<SpecName>.cfg`. Optional second arg overrides the config basename: `./formal/check.sh OpLogSync OpLogSync_shared`. Exit code 0 on TLC success, non-zero on any violation. Tasks 2–4 rely on this exact contract.

- [ ] **Step 1: Install the JDK**

```bash
brew install openjdk
"$(brew --prefix openjdk)/bin/java" -version
```

Expected: version output.

**Use the formula, not the `temurin` cask the spec named.** The cask installs
into `/Library/Java/JavaVirtualMachines` and requires `sudo` — an interactive
password prompt that blocks unattended execution. The formula installs into the
Homebrew prefix and needs no password. It is *keg-only*: not symlinked into
`PATH`, so bare `java` will still report "Unable to locate a Java Runtime".
That is expected, and `check.sh` Step 3 resolves the interpreter itself.

- [ ] **Step 2: Write the gitignore**

Create `formal/.gitignore`:

```gitignore
# Third-party checker binary — ~10MB, fetched by check.sh on demand
tools/
# TLC scratch output
states/
*.old
```

- [ ] **Step 3: Write the driver**

Create `formal/check.sh` (then `chmod +x formal/check.sh`):

```bash
#!/usr/bin/env bash
# Translate a PlusCal spec and model-check it with TLC.
#
#   ./formal/check.sh OpLogSync                  # uses OpLogSync.cfg
#   ./formal/check.sh OpLogSync OpLogSync_shared # uses OpLogSync_shared.cfg
#
# Exit 0 = TLC found no violation. Non-zero = violation or tooling error.
# A non-zero exit is an EXPECTED outcome for the falsification configs;
# see formal/README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="${1:?usage: check.sh <SpecName> [ConfigName]}"
CFG="${2:-$SPEC}"
JAR="$HERE/tools/tla2tools.jar"
JAR_URL="https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar"

if ! command -v java >/dev/null 2>&1 || ! java -version >/dev/null 2>&1; then
  echo "error: no Java runtime. Run: brew install --cask temurin" >&2
  exit 127
fi

if [ ! -f "$JAR" ]; then
  echo "fetching tla2tools.jar ..."
  mkdir -p "$HERE/tools"
  curl -fsSL "$JAR_URL" -o "$JAR"
fi

cd "$HERE"

# PlusCal -> TLA+. Rewrites the .tla in place between the BEGIN/END
# TRANSLATION markers. Skipped for specs with no PlusCal block.
if grep -q '^(\*--algorithm' "$SPEC.tla"; then
  echo "== translating PlusCal =="
  java -cp "$JAR" pcal.trans "$SPEC.tla"
fi

echo "== TLC: $SPEC.tla against $CFG.cfg =="
java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC \
    -config "$CFG.cfg" -workers auto -cleanup "$SPEC.tla"
```

- [ ] **Step 4: Write the smoke target — a spec that must pass**

Create `formal/Hello.tla`:

```tla
------------------------------- MODULE Hello -------------------------------
EXTENDS Integers
VARIABLE x
Init == x = 0
Next == x' = (x + 1) % 3
Spec == Init /\ [][Next]_x
InRange == x \in 0..2
=============================================================================
```

Create `formal/Hello.cfg`:

```
SPECIFICATION Spec
INVARIANT InRange
```

- [ ] **Step 5: Run it — verify the toolchain works end to end**

```bash
./formal/check.sh Hello
```

Expected: jar downloads, then `Model checking completed. No error has been found.` Exit 0.

- [ ] **Step 6: Verify the driver actually reports failures**

Temporarily change `Hello.cfg`'s invariant line to `INVARIANT Broken`, and add `Broken == x \in 0..1` to `Hello.tla` above the `====` line. Run:

```bash
./formal/check.sh Hello; echo "exit=$?"
```

Expected: `Invariant Broken is violated.` and a non-zero exit. **This step is not optional** — a driver that always exits 0 would make every falsification in Tasks 2–4 vacuous. Revert both edits afterwards and re-run to confirm green.

- [ ] **Step 7: Write the README**

Create `formal/README.md`:

```markdown
# formal/ — model-checked specs

Machine-checked models of Maugham protocols. Written for the 2026-08-01
formal-methods evaluation spike; see
`docs/superpowers/specs/2026-08-01-formal-methods-spike-design.md`.

## Running

    ./formal/check.sh OpLogSync                    # baseline, expect GREEN
    ./formal/check.sh OpLogSync OpLogSync_shared   # expect VIOLATION

First run downloads `tools/tla2tools.jar` (~10 MB, gitignored). Needs a JDK:
`brew install --cask temurin`.

## Configs

| Config | Constants | Expected |
|---|---|---|
| `OpLogSync.cfg` | production values | no violation |
| `OpLogSync_shared.cfg` | `PerDeviceFiles = FALSE` | `LocalNoLoss` violated |
| `OpLogSync_suspend.cfg` | `SealHasSuspensionPoint = TRUE` | `LocalNoLoss` violated |
| `OpLogSync_monotonic.cfg` | adds `RemoteMonotonic` | `RemoteMonotonic` violated |

**A non-zero exit from a falsification config is the intended result.** Each
pair exists to prove an assumption is load-bearing rather than decorative
(spec §5). A falsification config that starts passing means the model drifted,
not that a bug was fixed.

## Bounds

2 devices, 3 ops/device, 1 seal/device. Widening is a deliberate act — TLC's
state count grows fast and the spike has a stopping rule (spec §9).
```

- [ ] **Step 8: Commit**

```bash
git add formal/
git commit -m "chore(formal): TLC toolchain and one-command check driver

Spec §3. check.sh verifies Java, fetches tla2tools.jar on demand, translates
PlusCal and runs TLC. Step 6 of the plan verifies the driver actually reports
violations non-zero — a driver that always exits 0 would make every
falsification in this spike vacuous.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The core model — append, propagate, merge

Models ADR 0012: per-device partition files, whole-file propagation, merge by union-and-dedup. **The falsification reproduces the historical bug ADR 0012 was written to prevent** — if the model cannot reproduce a defect we know was real, the model is wrong, and this is the strongest available validation of the model itself.

**Files:**
- Create: `formal/OpLogSync.tla`
- Create: `formal/OpLogSync.cfg`, `formal/OpLogSync_shared.cfg`
- Delete: `formal/Hello.tla`, `formal/Hello.cfg`

**Interfaces:**
- Consumes: `./formal/check.sh <Spec> [Config]` from Task 1.
- Produces: variables `tail`, `sealed`, `viewTail`, `viewSealed`, `appended`; operators `Merged(e)`, `LocalNoLoss`, `Convergence`; constants `Devices`, `MaxOps`, `MaxSeals`, `PerDeviceFiles`, `SealHasSuspensionPoint`. Tasks 3 and 4 extend this file and rely on these exact names.

**Modelling note for the implementer — why sets, not sequences.** Ops are modelled as an unordered *set*, with no ULID ordering in the state. This is sound and is a deliberate abstraction (spec §4.4): ULID order is a total order, so sorting any set of ops yields a unique sequence, so derived state is a function of the *set* alone. Convergence-of-sets therefore implies convergence-of-derived-state. Modelling the order explicitly would multiply the state space for no additional coverage.

- [ ] **Step 1: Write the model**

Create `formal/OpLogSync.tla`:

```tla
----------------------------- MODULE OpLogSync -----------------------------
(***************************************************************************)
(* Maugham's op-log sync protocol (ADR 0012) and seal (ADR 0016).          *)
(*                                                                          *)
(* Ops are an unordered SET. Sound because ULID order is total, so the      *)
(* sorted sequence is a function of the set, so derived state is too        *)
(* (spec §4.4). The deriver is not modelled: it is a pure fold, so equal    *)
(* op sets imply equal derived state by construction.                      *)
(*                                                                          *)
(* The filesystem is ADVERSARIAL (spec §4.1): propagation is per-file,      *)
(* arbitrarily delayed and arbitrarily ordered between any two devices.     *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Devices,                \* symmetry set of device ids
    MaxOps,                 \* per-device append bound
    MaxSeals,               \* per-device seal bound
    PerDeviceFiles,         \* TRUE  = ADR 0012 partitioning (production)
                            \* FALSE = pre-0012 single shared file
    SealHasSuspensionPoint  \* TRUE  = an `await` splits the seal's read
                            \*         from its delete (Task 3)

ASSUME MaxOps \in Nat /\ MaxSeals \in Nat
ASSUME PerDeviceFiles \in BOOLEAN
ASSUME SealHasSuspensionPoint \in BOOLEAN

VARIABLES
    tail,       \* tail[d]        : set of ops in d's live tail file
    sealed,     \* sealed[d]      : set of ops in d's sealed segments
    viewTail,   \* viewTail[e][d] : e's currently-visible version of d's tail
    viewSealed, \* viewSealed[e][d]
    appended,   \* appended[d]    : history variable — every op d ever
                \*                  durably appended. Never shrinks.
    opsUsed,    \* opsUsed[d]     : bound counter
    sealsUsed   \* sealsUsed[d]   : bound counter

vars == << tail, sealed, viewTail, viewSealed, appended, opsUsed, sealsUsed >>

\* An op is identified by its origin device and a per-device counter. This
\* stands in for the ULID: globally unique, and that is all merge needs.
Ops == [dev : Devices, seq : 1..MaxOps]

\* What device e can see right now, across every device's files.
Merged(e) ==
    UNION { viewTail[e][d] \union viewSealed[e][d] : d \in Devices }

TypeOK ==
    /\ tail       \in [Devices -> SUBSET Ops]
    /\ sealed     \in [Devices -> SUBSET Ops]
    /\ viewTail   \in [Devices -> [Devices -> SUBSET Ops]]
    /\ viewSealed \in [Devices -> [Devices -> SUBSET Ops]]
    /\ appended   \in [Devices -> SUBSET Ops]
    /\ opsUsed    \in [Devices -> 0..MaxOps]
    /\ sealsUsed  \in [Devices -> 0..MaxSeals]

Init ==
    /\ tail       = [d \in Devices |-> {}]
    /\ sealed     = [d \in Devices |-> {}]
    /\ viewTail   = [e \in Devices |-> [d \in Devices |-> {}]]
    /\ viewSealed = [e \in Devices |-> [d \in Devices |-> {}]]
    /\ appended   = [d \in Devices |-> {}]
    /\ opsUsed    = [d \in Devices |-> 0]
    /\ sealsUsed  = [d \in Devices |-> 0]

(***************************************************************************)
(* Append. A device writes to its own tail, and sees its own write         *)
(* immediately — local writes do not propagate, they simply are.           *)
(***************************************************************************)
Append(d) ==
    /\ opsUsed[d] < MaxOps
    /\ LET op == [dev |-> d, seq |-> opsUsed[d] + 1] IN
        /\ tail'     = [tail     EXCEPT ![d] = @ \union {op}]
        /\ appended' = [appended EXCEPT ![d] = @ \union {op}]
        /\ viewTail' = [viewTail EXCEPT ![d][d] = @ \union {op}]
    /\ opsUsed' = [opsUsed EXCEPT ![d] = @ + 1]
    /\ UNCHANGED << sealed, viewSealed, sealsUsed >>

(***************************************************************************)
(* Propagation. Whole-file replace, per file, in any order, at any time —   *)
(* which is what iCloud Drive actually does and the reason ADR 0012 exists. *)
(* The two actions are INDEPENDENT: this is what lets an observer see a     *)
(* tail deletion before the segment carrying those ops arrives (spec §7.2). *)
(***************************************************************************)
PropagateTail(d, e) ==
    /\ d # e
    /\ viewTail' = [viewTail EXCEPT ![e][d] = tail[d]]
    /\ UNCHANGED << tail, sealed, viewSealed, appended, opsUsed, sealsUsed >>

PropagateSealed(d, e) ==
    /\ d # e
    /\ viewSealed' = [viewSealed EXCEPT ![e][d] = sealed[d]]
    /\ UNCHANGED << tail, sealed, viewTail, appended, opsUsed, sealsUsed >>

(***************************************************************************)
(* The pre-ADR-0012 world, enabled only when PerDeviceFiles = FALSE.        *)
(* Every device appends to ONE shared file. iCloud reconciles divergence by *)
(* whole-file replace: one version wins, the loser's ops become an          *)
(* unopened conflict twin and are gone. Modelled as d's file overwriting    *)
(* e's, destroying whatever e had not yet propagated.                       *)
(***************************************************************************)
ReconcileSharedFile(d, e) ==
    /\ ~PerDeviceFiles
    /\ d # e
    /\ tail'     = [tail     EXCEPT ![e] = tail[d]]
    /\ viewTail' = [viewTail EXCEPT ![e][e] = tail[d], ![d][d] = tail[d]]
    /\ UNCHANGED << sealed, viewSealed, appended, opsUsed, sealsUsed >>

Next ==
    \/ \E d \in Devices : Append(d)
    \/ \E d, e \in Devices : PropagateTail(d, e)
    \/ \E d, e \in Devices : PropagateSealed(d, e)
    \/ \E d, e \in Devices : ReconcileSharedFile(d, e)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* THE property. An op a device durably appended is in that device's OWN
\* view, forever. This is the constitution's "the words are safe" as an
\* invariant. It is deliberately about the LOCAL view: a remote observer
\* legitimately lags, and conflating the two would make the property
\* unprovable for reasons that have nothing to do with correctness.
LocalNoLoss ==
    \A d \in Devices : appended[d] \subseteq Merged(d)

\* Two devices that have observed every file at its current version derive
\* identical state. `FullySynced(e)` is the antecedent; without it this would
\* be false for the trivial and uninteresting reason that propagation lags.
FullySynced(e) ==
    \A d \in Devices :
        /\ viewTail[e][d]   = tail[d]
        /\ viewSealed[e][d] = sealed[d]

Convergence ==
    \A e, f \in Devices :
        (FullySynced(e) /\ FullySynced(f)) => (Merged(e) = Merged(f))
=============================================================================
```

- [ ] **Step 2: Write the falsification config first**

Create `formal/OpLogSync_shared.cfg`:

```
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT LocalNoLoss
INVARIANT Convergence
CONSTANTS
    Devices = {d1, d2}
    MaxOps = 3
    MaxSeals = 1
    PerDeviceFiles = FALSE
    SealHasSuspensionPoint = FALSE
```

Add the device symbols by declaring them in the config's constant set — TLC treats `{d1, d2}` as model values automatically.

- [ ] **Step 3: Run the falsification — confirm the historical bug reproduces**

```bash
./formal/check.sh OpLogSync OpLogSync_shared; echo "exit=$?"
```

Expected: `Invariant LocalNoLoss is violated.` with a trace in which `d1` appends, `d2` appends, and `ReconcileSharedFile` overwrites one device's tail with the other's — leaving an op in `appended` that is in no view. Non-zero exit.

**If this passes instead of failing, stop and debug the model, not the config.** The model must be able to reproduce a defect ADR 0012 documents as real. A model that cannot is not describing the system.

Save the trace — Task 6 quotes it.

- [ ] **Step 4: Write the baseline config**

Create `formal/OpLogSync.cfg`:

```
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT LocalNoLoss
INVARIANT Convergence
CONSTANTS
    Devices = {d1, d2}
    MaxOps = 3
    MaxSeals = 1
    PerDeviceFiles = TRUE
    SealHasSuspensionPoint = FALSE
```

- [ ] **Step 5: Run the baseline — confirm green**

```bash
./formal/check.sh OpLogSync; echo "exit=$?"
```

Expected: `Model checking completed. No error has been found.` Exit 0. Record the state count from TLC's output — Task 6 needs it for the practicality assessment, and Task 3 needs it as a baseline to see how much the seal costs.

- [ ] **Step 6: Delete the smoke target**

```bash
rm formal/Hello.tla formal/Hello.cfg
```

- [ ] **Step 7: Commit**

```bash
git add -A formal/
git commit -m "feat(formal): model op-log append, propagation and merge (ADR 0012)

Spec §4. Adversarial per-file propagation; ops as an unordered set (sound
because ULID order is total, so derived state is a function of the set).

The falsification config reproduces the pre-ADR-0012 defect: with
PerDeviceFiles = FALSE, TLC finds the whole-file-replace trace that drops a
device's ops. That the model can reproduce a bug we know was real is the
strongest available validation that the model describes the system.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The seal, the MainActor lock, and the motivating finding

Models ADR 0016's two-step seal and Swift's actor semantics. **This task tests the spike's motivating hypothesis (spec §1.2):** that the seal's safety rests on the incidental absence of an `await` in `sealTailIfNeeded`.

**Files:**
- Modify: `formal/OpLogSync.tla` (add seal state, actions, and the lock)
- Create: `formal/OpLogSync_suspend.cfg`

**Interfaces:**
- Consumes: everything from Task 2 by the names given there.
- Produces: variable `lock`, variable `captured`, operator `SealPreservesLocalOps`. Task 4 relies on `lock` existing in `vars`.

**Modelling note — why a lock and two roles.** `OpLogStore` is `@MainActor`. Two callers reach it concurrently: something appending, and the sealer. On one device they cannot run simultaneously, but an `async` function *releases actor isolation at every `await`*. So: the MainActor is a lock; a seal with no suspension point holds it across all three steps and is atomic; a seal with one releases it mid-way and lets an append interleave. `SealHasSuspensionPoint` is exactly that difference, and nothing else in the model changes between the two runs.

- [ ] **Step 1: Add the seal state to the model**

In `formal/OpLogSync.tla`, extend the `VARIABLES` block and `vars`:

```tla
VARIABLES
    tail, sealed, viewTail, viewSealed, appended, opsUsed, sealsUsed,
    lock,       \* lock[d]     : "free", or the role holding d's MainActor
    captured    \* captured[d] : the seal's step-1 read buffer

vars == << tail, sealed, viewTail, viewSealed, appended, opsUsed,
           sealsUsed, lock, captured >>
```

Extend `TypeOK`:

```tla
    /\ lock     \in [Devices -> {"free", "appender", "sealer"}]
    /\ captured \in [Devices -> SUBSET Ops]
```

Extend `Init`:

```tla
    /\ lock     = [d \in Devices |-> "free"]
    /\ captured = [d \in Devices |-> {}]
```

- [ ] **Step 2: Make Append respect the lock**

Replace the `Append(d)` definition with one that can only run when the device's MainActor is free. Every existing conjunct is retained; the change is the `lock[d] = "free"` guard and the two new `UNCHANGED` entries:

```tla
Append(d) ==
    /\ lock[d] = "free"
    /\ opsUsed[d] < MaxOps
    /\ LET op == [dev |-> d, seq |-> opsUsed[d] + 1] IN
        /\ tail'     = [tail     EXCEPT ![d] = @ \union {op}]
        /\ appended' = [appended EXCEPT ![d] = @ \union {op}]
        /\ viewTail' = [viewTail EXCEPT ![d][d] = @ \union {op}]
    /\ opsUsed' = [opsUsed EXCEPT ![d] = @ + 1]
    /\ UNCHANGED << sealed, viewSealed, sealsUsed, lock, captured >>
```

Also add `UNCHANGED << lock, captured >>` to `PropagateTail`, `PropagateSealed`, and `ReconcileSharedFile` — TLC will reject the spec until you do, which is the intended feedback.

- [ ] **Step 3: Add the seal, decomposed**

Add above `Next`:

```tla
(***************************************************************************)
(* The seal (ADR 0016, OpLogStore.sealTailIfNeeded:177).                   *)
(*                                                                          *)
(* Three steps, deliberately NOT one atomic action — the decomposition IS   *)
(* the hypothesis under test (spec §1.2):                                  *)
(*                                                                          *)
(*   SealRead    line 194 — coordinated read of the tail's bytes            *)
(*   SealWrite   line 217 — atomic rename of the .mzseg into place          *)
(*   SealDelete  line 224 — coordinated delete, a SEPARATE coordination     *)
(*                          scope from the read                             *)
(*                                                                          *)
(* SealHasSuspensionPoint = TRUE releases the MainActor between the read    *)
(* and the delete, exactly as an `await` in that body would.                *)
(***************************************************************************)
SealRead(d) ==
    /\ lock[d] = "free"
    /\ sealsUsed[d] < MaxSeals
    /\ tail[d] # {}
    /\ captured'  = [captured  EXCEPT ![d] = tail[d]]
    /\ sealsUsed' = [sealsUsed EXCEPT ![d] = @ + 1]
    /\ lock'      = [lock EXCEPT ![d] = IF SealHasSuspensionPoint
                                        THEN "free" ELSE "sealer"]
    /\ UNCHANGED << tail, sealed, viewTail, viewSealed, appended, opsUsed >>

\* Segment-before-delete. This ordering is correct and must NOT be swapped:
\* a mid-seal reader sees both files and dedup-by-opId absorbs the duplicate.
\* Reversing these two actions is the bug this ordering already avoids.
SealWrite(d) ==
    /\ captured[d] # {}
    /\ lock[d] \in {"free", "sealer"}
    /\ sealed'     = [sealed     EXCEPT ![d] = @ \union captured[d]]
    /\ viewSealed' = [viewSealed EXCEPT ![d][d] = @ \union captured[d]]
    /\ UNCHANGED << tail, viewTail, appended, opsUsed, sealsUsed, lock,
                    captured >>

\* Deletes the WHOLE tail — not `tail \ captured`. This mirrors the code:
\* `fm.removeItem(at: wu)` removes the file, and anything appended since the
\* read goes with it.
SealDelete(d) ==
    /\ captured[d] # {}
    /\ captured[d] \subseteq sealed[d]
    /\ lock[d] \in {"free", "sealer"}
    /\ tail'     = [tail     EXCEPT ![d] = {}]
    /\ viewTail' = [viewTail EXCEPT ![d][d] = {}]
    /\ captured' = [captured EXCEPT ![d] = {}]
    /\ lock'     = [lock     EXCEPT ![d] = "free"]
    /\ UNCHANGED << sealed, viewSealed, appended, opsUsed, sealsUsed >>
```

Extend `Next`:

```tla
    \/ \E d \in Devices : SealRead(d)
    \/ \E d \in Devices : SealWrite(d)
    \/ \E d \in Devices : SealDelete(d)
```

- [ ] **Step 4: Write the falsification config**

Create `formal/OpLogSync_suspend.cfg`:

```
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT LocalNoLoss
INVARIANT Convergence
CONSTANTS
    Devices = {d1, d2}
    MaxOps = 3
    MaxSeals = 1
    PerDeviceFiles = TRUE
    SealHasSuspensionPoint = TRUE
```

- [ ] **Step 5: Run the falsification — confirm the hypothesis**

```bash
./formal/check.sh OpLogSync OpLogSync_suspend; echo "exit=$?"
```

Expected: `Invariant LocalNoLoss is violated.` The trace should read: `SealRead(d1)` captures `{op1}` and releases the lock → `Append(d1)` adds `op2` to the tail → `SealWrite(d1)` seals only `{op1}` → `SealDelete(d1)` removes the whole tail → `op2` is in `appended[d1]` and in no view. Non-zero exit.

**This trace is the spike's headline artifact.** Save the full TLC output verbatim; Task 5 cites it in the tripwire's failure message and Task 6 quotes it.

- [ ] **Step 6: Run the baseline — confirm the assumption closes the hole**

```bash
./formal/check.sh OpLogSync; echo "exit=$?"
```

Expected: no violation, exit 0. Both directions of spec §5 are now satisfied for this assumption: without it, TLC finds op loss; with it, green. That is what promotes it from "something I noticed" to a load-bearing assumption.

Record the new state count and compare against Task 2's — the delta is the seal's cost and feeds Task 6's practicality section.

- [ ] **Step 7: Commit**

```bash
git add -A formal/
git commit -m "feat(formal): model the two-step seal and @MainActor isolation

Spec §1.2, §4.3. The MainActor is a lock; an async function releases it at
every await. SealHasSuspensionPoint = TRUE models an await between
sealTailIfNeeded's coordinated read (line 194) and its coordinated delete
(line 224), and TLC finds the op-loss trace: read captures op1, append lands
op2, the segment carries only op1, the delete takes the whole tail.

With the constant FALSE the same spec is green. Both directions run, so the
assumption is load-bearing rather than decorative (spec §5).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Transient invisibility — a plausible property that is false

Spec §7.2. Demonstrates that a remote observer's op set can *shrink*, by stating the property a reasonable reader would assume holds and letting TLC refute it. There is no green direction here: the counterexample **is** the deliverable.

**Files:**
- Modify: `formal/OpLogSync.tla` (add `RemoteMonotonic` and its history variable)
- Create: `formal/OpLogSync_monotonic.cfg`

**Interfaces:**
- Consumes: `Merged(e)`, `vars`, all Task 2/3 names.
- Produces: variable `everSeen`. Task 6 cites the counterexample.

- [ ] **Step 1: Add the history variable**

A shrinking-set property needs to compare against the past, so it needs a history variable. In `formal/OpLogSync.tla`:

```tla
VARIABLES
    tail, sealed, viewTail, viewSealed, appended, opsUsed, sealsUsed,
    lock, captured,
    everSeen    \* everSeen[e] : every op e has ever had visible. Grows only.

vars == << tail, sealed, viewTail, viewSealed, appended, opsUsed,
           sealsUsed, lock, captured, everSeen >>
```

`TypeOK`: `/\ everSeen \in [Devices -> SUBSET Ops]`
`Init`: `/\ everSeen = [e \in Devices |-> {}]`

Rather than updating `everSeen` in all eight actions, define `Next` to maintain it uniformly. Replace the `Next` and `Spec` definitions with:

```tla
BaseNext ==
    \/ \E d \in Devices : Append(d)
    \/ \E d, e \in Devices : PropagateTail(d, e)
    \/ \E d, e \in Devices : PropagateSealed(d, e)
    \/ \E d, e \in Devices : ReconcileSharedFile(d, e)
    \/ \E d \in Devices : SealRead(d)
    \/ \E d \in Devices : SealWrite(d)
    \/ \E d \in Devices : SealDelete(d)

Next ==
    /\ BaseNext
    /\ everSeen' = [e \in Devices |-> everSeen[e] \union Merged(e)']

Spec == Init /\ [][Next]_vars
```

Every action already has an `UNCHANGED` list that omits `everSeen`; because `Next` now conjoins the `everSeen'` update, remove `everSeen` from no `UNCHANGED` list — the actions never mention it and must not.

- [ ] **Step 2: State the plausible-but-false property**

Add below `Convergence`:

```tla
(***************************************************************************)
(* PLAUSIBLE AND FALSE (spec §7.2).                                        *)
(*                                                                          *)
(* "Once a device can see an op, it can always see it." A reasonable reader *)
(* of ADR 0016 would assume this. It is false, and the counterexample is a  *)
(* finding, not a bug in the model.                                        *)
(*                                                                          *)
(* Cause: the seal's segment-write and tail-delete propagate as TWO         *)
(* INDEPENDENT file events with no ordering guarantee. A remote observer    *)
(* can receive the tail deletion before the segment carrying those ops      *)
(* arrives, opening a window in which the ops are visible to nobody but     *)
(* their owner.                                                            *)
(*                                                                          *)
(* Transient invisibility is harmless in itself. It becomes damage when     *)
(* something reacts to it DURABLY — and IntegrityChecks / IntegrityQuarantine*)
(* live in exactly that neighbourhood. Out of scope to model here (spec §2);*)
(* this property exists to prove the window is real, which is what makes it *)
(* worth scheduling.                                                       *)
(***************************************************************************)
RemoteMonotonic ==
    \A e \in Devices : everSeen[e] \subseteq Merged(e)
```

- [ ] **Step 3: Write the config**

Create `formal/OpLogSync_monotonic.cfg`:

```
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT LocalNoLoss
INVARIANT RemoteMonotonic
CONSTANTS
    Devices = {d1, d2}
    MaxOps = 3
    MaxSeals = 1
    PerDeviceFiles = TRUE
    SealHasSuspensionPoint = FALSE
```

- [ ] **Step 4: Run it — confirm the window is real**

```bash
./formal/check.sh OpLogSync OpLogSync_monotonic; echo "exit=$?"
```

Expected: `Invariant RemoteMonotonic is violated`, with a trace in which `d1` appends and its tail propagates to `d2`, then `d1` seals, then `PropagateTail(d1, d2)` delivers the now-empty tail *before* `PropagateSealed(d1, d2)` delivers the segment. `LocalNoLoss` must remain unviolated throughout — if it also fails here, the model has a defect, because `d1`'s own view is never affected by propagation.

Save the trace for Task 6.

- [ ] **Step 5: Confirm the baseline is still green**

```bash
./formal/check.sh OpLogSync; echo "exit=$?"
```

Expected: exit 0. Adding `everSeen` must not disturb the baseline; if it does, the history variable is being updated wrongly.

- [ ] **Step 6: Commit**

```bash
git add -A formal/
git commit -m "feat(formal): refute RemoteMonotonic — the transient-invisibility window

Spec §7.2. States the property a reasonable reader of ADR 0016 would assume
holds — once visible, always visible — and lets TLC refute it. The seal's
segment-write and tail-delete propagate as two independent events with no
ordering guarantee, so a remote observer can see the deletion first.

The counterexample IS the deliverable; there is no green direction. Transient
invisibility is harmless until something reacts to it durably, which is why
IntegrityChecks/IntegrityQuarantine is (a)'s first target.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Land the guard in Swift

Spec §8. Converts Task 3's finding into a durable tripwire so the spike's value survives a "no" on (a).

**Files:**
- Modify: `MaughamTests/TripwireGrepTests.swift` (append a new test at the end of the class)
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift` (comment only, above line 177)

**Interfaces:**
- Consumes: the counterexample trace from Task 3 Step 5.
- Produces: `test_sealTailIfNeededHasNoSuspensionPoint`.

**Why a grep tripwire and not a runtime test:** the property is *syntactic* — "no suspension point exists in this body." No runtime test can observe the absence of an `await`. The repo already uses grep tripwires for exactly this class (tripwires 13, 14, 23, 32).

- [ ] **Step 1: Write the failing test**

Append to the class in `MaughamTests/TripwireGrepTests.swift`:

```swift
    // MARK: - Seal atomicity (formal-methods spike, 2026-08-01)

    /// Recurrence-tripper: `OpLogStore.sealTailIfNeeded` reads the tail's
    /// bytes in one `NSFileCoordinator` scope and deletes the tail in a
    /// DIFFERENT one. An append landing between those two points is captured
    /// in the segment by neither, and is then deleted with the tail — silent
    /// op loss, the constitution's "the words are safe" failing.
    ///
    /// The only thing preventing it is that `OpLogStore` is `@MainActor` and
    /// this `async` body contains no `await`, so it runs to completion without
    /// a suspension point and `append` cannot interleave. Swift releases actor
    /// isolation at every `await`; adding one anywhere between the read and
    /// the delete reopens the window with no diagnostic.
    ///
    /// Model-checked: `formal/OpLogSync.tla` with
    /// `SealHasSuspensionPoint = TRUE` yields a `LocalNoLoss` counterexample —
    /// SealRead captures {op1} and releases, Append lands op2, SealWrite seals
    /// only {op1}, SealDelete removes the whole tail. With the constant FALSE
    /// the same spec is green. Run: `./formal/check.sh OpLogSync OpLogSync_suspend`
    func test_sealTailIfNeededHasNoSuspensionPoint() throws {
        let storeURL = repoRoot
            .appendingPathComponent(
                "Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift")
        let source = try String(contentsOf: storeURL, encoding: .utf8)
        let lines = source.components(separatedBy: .newlines)

        guard let start = lines.firstIndex(where: {
            $0.contains("func sealTailIfNeeded(")
        }) else {
            return XCTFail(
                "sealTailIfNeeded not found in OpLogStore.swift. If it was "
                + "renamed, update this tripwire — do not delete it; the "
                + "hazard is in the two-coordination-scope shape, not the name.")
        }
        // The method's closing brace is the first line that is exactly four
        // spaces and a brace; every nested closure closes at eight or more.
        guard let offset = lines[(start + 1)...].firstIndex(where: {
            $0 == "    }"
        }) else {
            return XCTFail("Could not find the end of sealTailIfNeeded's body.")
        }
        let body = Array(lines[start...offset])

        // Landmark assertion: if the extraction above silently grabs the wrong
        // range, the `await` scan below would pass vacuously. This repo has
        // shipped helpers that could not fail (3167365); this one must be able
        // to. Both landmarks are load-bearing lines of the real body.
        XCTAssertTrue(
            body.contains(where: { $0.contains("coordinate(readingItemAt:") }),
            "Body extraction is broken — the coordinated READ is missing from "
            + "the extracted range, so the await scan below proves nothing.")
        XCTAssertTrue(
            body.contains(where: { $0.contains(".forDeleting") }),
            "Body extraction is broken — the coordinated DELETE is missing from "
            + "the extracted range, so the await scan below proves nothing.")

        let offenders = body.enumerated().filter { _, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return false }
            return trimmed.contains("await ")
        }.map { "OpLogStore.swift:\(start + $0.offset + 1): \($0.element)" }

        XCTAssertTrue(offenders.isEmpty,
            "`await` inside sealTailIfNeeded. Swift releases actor isolation at "
            + "every suspension point, so an append can now interleave between "
            + "the coordinated read (line ~194) and the coordinated delete "
            + "(line ~224) — and the interleaved op is sealed into no segment, "
            + "then deleted with the tail. Silent op loss.\n\n"
            + "Model-checked: ./formal/check.sh OpLogSync OpLogSync_suspend "
            + "produces the LocalNoLoss counterexample.\n\n"
            + "If the suspension point is genuinely needed, the fix is to make "
            + "the delete remove only the captured ops rather than the whole "
            + "file, or to re-read and diff under one coordination scope — not "
            + "to delete this test. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }
```

- [ ] **Step 2: Run it — verify it passes against current code**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/TripwireGrepTests/test_sealTailIfNeededHasNoSuspensionPoint \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: PASS. (Run `./gen.sh` first if `Maugham.xcodeproj` is absent.)

- [ ] **Step 3: Verify the test can actually fail — plant the offender**

Temporarily insert `        _ = await Task.yield()` immediately after line 197's `if let coordErr { throw coordErr }` in `OpLogStore.swift`. Re-run the command from Step 2.

Expected: FAIL, with the op-loss explanation. **This step is mandatory.** A tripwire that cannot fail is worse than none — it reports safety it never checked, and this repo has shipped exactly that (commit `3167365`, "fix two helpers that could not fail").

- [ ] **Step 4: Revert the planted offender and re-run**

```bash
git checkout Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift
```

Re-run Step 2's command. Expected: PASS.

- [ ] **Step 5: Add the comment at the source**

In `OpLogStore.swift`, immediately above `public func sealTailIfNeeded(`:

```swift
    /// **The absence of `await` in this body is load-bearing, not incidental.**
    /// The tail is read in one `NSFileCoordinator` scope and deleted in a
    /// different one; because `OpLogStore` is `@MainActor` and this body has no
    /// suspension point, `append` cannot interleave between them. Add an
    /// `await` and an interleaved op is sealed into no segment and then deleted
    /// with the tail. Model-checked in `formal/OpLogSync.tla`; pinned by
    /// `TripwireGrepTests.test_sealTailIfNeededHasNoSuspensionPoint`.
```

- [ ] **Step 6: Run the surrounding suites**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/TripwireGrepTests \
  -only-testing:MaughamTests/OpLogStoreSegmentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: all pass. A doc comment cannot break behaviour, but `OpLogStoreSegmentTests` is the seal's own suite and confirms the file still compiles as expected.

- [ ] **Step 7: Commit**

```bash
git add MaughamTests/TripwireGrepTests.swift \
        Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift
git commit -m "test(oplog): pin the seal's no-suspension-point assumption

Spec §8. sealTailIfNeeded reads the tail in one NSFileCoordinator scope and
deletes it in another; the only thing stopping an interleaved append from
being lost is that this @MainActor async body happens to contain no await.
Nothing documented or pinned that.

Grep tripwire because the property is syntactic — no runtime test can observe
the absence of a suspension point. Verified failable by planting
'await Task.yield()' in the body (plan Task 5 Step 3).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Findings and the verdict

Spec §1.1, §7, §9, §11. The actual deliverable of the spike.

**Files:**
- Create: `docs/superpowers/notes/2026-08-01-formal-methods-spike-findings.md`
- Modify: `CLAUDE.md` (add the tripwire row **only if** the verdict is go, or if Task 5's guard warrants standing visibility — decide in Step 3)

**Interfaces:**
- Consumes: the three saved traces (Tasks 2, 3, 4), TLC state counts (Tasks 2 Step 5, 3 Step 6), and the guard from Task 5.

- [ ] **Step 1: Write the findings note**

Create `docs/superpowers/notes/2026-08-01-formal-methods-spike-findings.md` with these sections, filled from the recorded runs. **Every claim about TLC output must quote the actual output** — no reconstructed traces.

1. **Verdict** — go or no-go on (a), one paragraph, at the top. Then the recommendation on (b), which after a single spike should almost certainly be "not yet."
2. **Assumptions surfaced** — one subsection each, and for each: the assumption stated in one sentence; where it lives in the code with a file:line; the falsification config that violates it; the verbatim counterexample trace; whether it is now pinned, and by what. An assumption with no falsification does not appear (spec §5).
3. **Predicted vs discovered** — spec §7 predicted three findings. Say which were confirmed and, plainly, whether anything was discovered that was not predicted. **If nothing was, say so in those words**: a spike that surfaces only its own predictions has demonstrated the method's floor, not its value (spec §7.4).
4. **Practicality** — wall-clock to write the spec; TLC state counts and runtimes at each stage from Tasks 2 and 3; where the bounds started to bite. This is the section that answers the question that prompted the spike.
5. **What formal methods cannot do here** — the refinement gap (the spec verifies the model, not `OpLogStore.swift`; no trace validation was attempted); and the environment-modelling limit that excluded the editor loop (spec §2), which is the most transferable finding and should be stated as a general selection criterion.
6. **If (a) proceeds** — the ordered target list, starting with `IntegrityChecks`/`IntegrityQuarantine` versus the §7.2 window.

- [ ] **Step 2: Self-check the note against the stopping rule**

Re-read spec §9's table. Confirm the verdict matches the outcome that actually occurred — green-with-assumptions is a continue, green-with-nothing-surfaced is a stop-and-write-the-no. **Do not let a sunk-cost reading turn a "no" into a "maybe."** A cheap, clearly-stated no is a successful spike.

- [ ] **Step 3: Decide on the CLAUDE.md row**

Task 5's guard exists either way. The question is only whether it earns a numbered tripwire row (a standing visibility cost paid by every future session) or stays a well-commented test.

Add row 33 **only if** the verdict is go. Otherwise add a single line to the "Outstanding correctness concerns" section pointing at the test and the note. If adding the row, keep it to two sentences and point at the test for detail — per CLAUDE.md rule 10, sweep `Packages/MaughamCore/` and `Maugham/OpLog/AREA.md` for now-false claims in the same commit.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/notes/2026-08-01-formal-methods-spike-findings.md CLAUDE.md
git commit -m "docs: formal-methods spike findings and verdict

Spec §1.1, §7, §9. Assumption list with verbatim counterexample traces, the
practicality numbers, and the go/no-go on (a).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 5: Report to the user**

Summarise in the session: the verdict, the assumptions surfaced, whether anything was discovered beyond the three predictions, and the practicality numbers. Flag explicitly if the answer is a no — the staging agreed at the outset makes that a legitimate stopping point, not a failure.

---

## Self-Review

**Spec coverage:**

| Spec § | Task |
|---|---|
| §1.1 the bar | 6 (note §2) |
| §1.2 motivating finding | 3, 5 |
| §2 scope + exclusions | 6 (note §5) |
| §3 tooling | 1 |
| §4.1 adversarial environment | 2 |
| §4.2 actions | 2, 3 |
| §4.3 MainActor as lock | 3 |
| §4.4 abstraction budget | 2 (modelling note), 6 |
| §4.5 bounds | 1 (README), all configs |
| §5 falsify-first | 2, 3, 4 — and Task 1 Step 6 + Task 5 Step 3, which apply it to the *tooling* |
| §6 properties 1–3 | 2, 3, 4 |
| §6 property 4 (liveness) | **not implemented** — see below |
| §7.1–7.3 predicted findings | 3, 4, 6 |
| §7.4 discovered | 6 (note §3) |
| §8 Swift guards | 5 |
| §9 stopping rule | 6 Step 2, Global Constraints |
| §10 artifacts | all |
| §11 risks | 6 (note §4, §5) |

**One deliberate gap.** Spec §6 property 4 (`EventualConvergence`, liveness) has no task. The spec permits this — "checked last, and dropped if it costs more than it teaches" — and a temporal property needs fairness constraints that roughly double the modelling work while telling us something the safety properties already imply for the decision at hand. Recorded here so the omission is a decision rather than an oversight; if Task 2 and 3 are cheap and green, adding it is a natural extension.

**Placeholder scan:** none. Task 6 is necessarily outcome-shaped, but every section it must contain is enumerated with its required content, and Step 1 forbids reconstructed traces.

**Type consistency:** `Merged(e)`, `LocalNoLoss`, `Convergence`, `FullySynced(e)`, `RemoteMonotonic`, `everSeen`, `lock`, `captured`, `PerDeviceFiles`, `SealHasSuspensionPoint` are used identically across Tasks 2–5. `vars` is redefined in Tasks 3 and 4 as variables are added — flagged in each task's Interfaces block, since a stale `vars` is the most likely TLC error an implementer will hit.

**One known-fragile point, called out for the reviewer:** Task 5's body extraction keys on the first line equal to `"    }"`. Verified correct against `OpLogStore.swift` as of `db1bea2` (the method spans 177–231; its only 4-space closing brace is 231). Step 1's two landmark assertions exist precisely so that a future reformat makes the test *fail loudly* rather than pass vacuously.
