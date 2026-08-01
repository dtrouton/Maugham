# Formal methods evaluation spike — op-log sync + seal

*Brainstormed 2026-08-01. A bounded evaluation spike, not a feature. The deliverable is a **decision** about whether TLA+ earns a standing place in Maugham, plus whatever durable guards fall out of reaching it.*

*Staging, agreed at the outset: **(c) evaluate → if promising, (a) harden the op log → if that works, consider (b) a standing practice.** This document specifies (c) only. It does not commit to (a) or (b), and a "no" is a legitimate and useful outcome.*

---

## 1. What this spike is for

Maugham's robustness rests on prose invariants. ADR 0012 states one outright — *"the logical op log remains the merged, opId-sorted, opId-deduped set of all ops"* — and 4,067 tests defend the parts of it that a single-process test can reach. What no test reaches is the **interleaving**: two devices appending, an iCloud reconciler propagating files in an order nobody chose, and a seal rewriting a device's own tail while another device is mid-glob.

The question is whether a model checker earns its keep against that.

### 1.1 The bar, stated precisely

Success is **not** "TLC finds a bug." A protocol that turns out to be sound would make that bar produce a weak, ambiguous no.

Success is: **a written list of the load-bearing assumptions in the sync/seal protocol that are currently unwritten and unpinned**, each demonstrated load-bearing by falsification (§5), with Swift guards landed for the sharp ones — plus a go/no-go on (a).

This bar was chosen because it pays out regardless of the verdict. An assumption that turns out to be true and unwritten is still a latent defect: it will be violated by a future edit that nobody recognises as dangerous.

### 1.2 The motivating finding

The spike has a falsifiable target, found while scoping it. `OpLogStore.sealTailIfNeeded` (`Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift:177`) reads the tail's bytes inside one `NSFileCoordinator` scope (line 194) and deletes the tail inside a **different** one (line 224). An append landing between those two points is captured in the segment by neither, and is then deleted with the tail. That is op loss — the constitution's *the words are safe* failing silently.

It does not happen today. The reason is subtle and undocumented: `OpLogStore` is `@MainActor`, and although `sealTailIfNeeded` is `async`, its body contains **no `await`** — so it runs to completion without a suspension point and `append` cannot interleave.

**The safety of the seal rests on the incidental absence of an `await` in a fifty-line body.** Nothing documents it, no test pins it, and the obvious future edit — making compression or coordination async — reopens the window with no diagnostic. This is the archetype of what the spike is looking for, and its existence is why the spike is worth running at all.

Note what the finding is *not*: it is not a claim that the code is wrong. The seal's step ordering is in fact correct — writing the segment before deleting the tail means a mid-seal reader sees both and dedup-by-opId absorbs the duplicates. Reversing those two steps would be the bug. The code is right; the reason it is right is unwritten.

---

## 2. Scope

**In:** the op-log sync and seal protocol — multi-device append, ULID-ordered merge, dedup, and the two-step seal, against an adversarial filesystem model (ADR 0012, ADR 0016).

**Out, and deliberately so:**

- **The editor↔disk echo loop** (`EchoState`, tripwires 2/3/6/7), despite the worst bug history in the repo — three cursor races in 24 hours. Tripwire 2's defect was *a wrong belief about the environment*: `.onChange` fires after the synchronous flag-clear, which nobody expected. A model of SwiftUI's callback ordering is a model of my belief about it, and would faithfully reproduce the bug rather than catch it. **Formal methods cannot help where the unknown is the environment.** This belongs to deterministic simulation against real AppKit, if anywhere.
- **Rewind / undo / checkpoint** (ADR 0023). Algebraic more than concurrent — "does inverse-compose-to-identity hold across a rewind cursor" is a property test in Swift, more cheaply and with no refinement gap.
- **Integrity / quarantine interaction.** A real hazard (§7.2) and the most likely live bug of the three, but it widens the model past what a decision needs. Recorded as the first candidate for (a).

The op log was chosen because its environment can be modelled **adversarially** — see §4.1. That property, not bug-likelihood, is what makes a subsystem a good formal-methods target, and it is the single most transferable finding this spike can produce.

---

## 3. Tooling

**PlusCal → TLA+, checked with TLC**, run from the CLI against `tla2tools.jar`.

The reason is specific rather than conventional: the seal is an imperative algorithm, and **in PlusCal, labels are atomicity boundaries**. "Can an append interleave between the tail read and the tail delete?" becomes literally "are these two statements under the same label?" The hazard of §1.2 is the question PlusCal is shaped to ask, and expressing it costs one label.

Rejected: **Quint** — more readable, but its exhaustive checkers (TLC, Apalache) are JVM-based too, so it buys nothing on setup while adding a layer between me and the error messages. **Alloy** — relational and structural; weak on temporal properties over an evolving log, which is the whole problem. **FizzBee** — no JVM needed, but a much smaller ecosystem and materially less reliable output from me, which costs more iterations than the JDK costs to install.

**Dependency:** one JDK, `brew install --cask temurin`. Nothing from it enters the repo; removable with `brew uninstall --cask temurin`.

---

## 4. The model

*N* devices, each owning a partition file and a set of sealed segments, over a filesystem that propagates changes between them.

### 4.1 The environment is adversarial

Propagation is **per-file, arbitrarily delayed, arbitrarily ordered, and observable mid-flight**. Device B may see A's new `.mzseg` before A's tail deletion, or after, or may observe the deletion while the segment is still in flight.

This is the crux of the tool choice. I do not need to know how iCloud actually behaves — a fact that is undocumented, version-dependent, and has already burned this project once (ADR 0012's whole existence). I model the environment **as bad as it is allowed to be**, and every assumption the code makes is tested against the worst case. Where the environment can be bounded adversarially, a model checker is strong; where the environment is an opaque framework whose behaviour is the actual unknown, it is worse than useless because it launders a guess into a proof.

### 4.2 Actions

| Action | Meaning |
|---|---|
| `Append(d)` | device *d* appends one op to its own tail |
| `Seal(d)` | *d* seals its tail — **decomposed into constituent steps, never one atomic block**, because the decomposition is the hypothesis under test |
| `Propagate(d, e, f)` | one of *d*'s files becomes visible to *e* |
| `Read(d)` | glob, merge, dedup by opId, sort by opId, derive |

### 4.3 `@MainActor` as a lock

Swift's actor semantics are modelled explicitly: the MainActor is a lock, and an `async` function is *acquire → run to the next `await` → release → reacquire*. This is a faithful model of actor reentrancy, and it is what converts §1.2's hazard from a careful-reading question into a mechanical one. A variant of the spec in which `sealTailIfNeeded` has a suspension point between its read and its delete should produce a `NoLoss` counterexample; that variant is the falsification (§5) that proves the assumption load-bearing.

### 4.4 Abstraction budget

Deliberately **not** modelled, with the soundness argument for each:

- **Op content** (paragraph text, `sequence` arrays). Irrelevant to whether an op survives.
- **The deriver's internals** — an uninterpreted function of the ordered op set. Sound precisely because `Deriver.derive` is a pure fold over opId order; if two devices agree on the ordered set, they agree on the output by construction.
- **Compression and checksums** — identity, plus a `corrupt` boolean. `OpLogSegment`'s framing is well-tested in Swift already and is not where interleaving lives.
- **ULIDs are not 128-bit values.** TLC cannot explore 2⁸⁰ of randomness and does not need to. An op is `[dev, seq]` under a total order, with clock skew modelled as bounded cross-device reordering.

That last abstraction already yields a finding worth recording: **convergence requires only a total order that every device agrees on — it does not require that order to match real time.** Clock skew therefore is not a convergence hazard at all; it is a *semantic* hazard (an op folds into the past, which ADR 0012 lists as a consequence). The current prose conflates the two, and separating them is a documentation fix independent of anything TLC reports.

### 4.5 Bounds

2 devices, 3 ops, 1 seal for the first cycle; widen to 3 devices / 2 seals only if the first cycle is green and cheap. Symmetry sets over devices.

**If the bounds must be so tight that the model stops being interesting, that is itself the headline finding on practicality** and goes in the note as such. It is the honest answer to the question that prompted the spike.

---

## 5. Method — falsify first

This is what makes the spike assumption-surfacing rather than box-ticking.

Every time the model needs a fact about the real system that cannot be read off the code, that is a candidate assumption. Two kinds arise:

- **Chosen** — a fact I write into the model to make it match reality (e.g. "the seal's read and delete are atomic with respect to local append").
- **Discovered** — TLC produces a counterexample, and the resolution is not a code change but the realisation that the trace cannot occur *because of* some unstated fact. Those are the valuable ones.

For each candidate, both directions are run:

1. Model **without** the assumption. Confirm TLC produces a counterexample trace.
2. Add the assumption. Confirm the property goes green.

**An assumption that cannot be falsified was decorative and does not go on the list.** Only assumptions that survive both directions are reported, and each is reported *with its counterexample trace*, which is what makes the finding checkable by someone who did not write the model.

This is the discipline the repo already uses on its sharpest tests — `CanvasMembershipTests` is documented as "falsified by introducing tldraw's ejection bug" (tripwire 31). Same method, applied to a spec instead of a test.

---

## 6. Properties

| # | Name | Statement |
|---|---|---|
| 1 | **NoLoss** | An op durably appended on device *d* is present in *d*'s own merged view at every subsequent state. |
| 2 | **Convergence** | Two devices observing the same file set at the same versions derive identical state. |
| 3 | **SealPreservesOps** | The observable op set is unchanged across a seal, *from every observer's vantage point*. |
| 4 | **EventualConvergence** | Under fair propagation, all devices converge. (Liveness — checked last, and dropped if it costs more than it teaches.) |

Property 3's trailing clause is the load-bearing part: the seal is trivially op-preserving from the sealing device's own vantage, and the two-step non-atomicity bites only for a remote observer. A property stated without that clause would pass vacuously — worth noting as a hazard of the method itself.

---

## 7. Expected findings

Recorded in advance so the note can be honest about what was predicted versus discovered.

### 7.1 Seal atomicity (§1.2) — predicted, high confidence

Expected to confirm. Guard specified in §8.

### 7.2 Transient invisibility with a durable reaction — predicted, medium confidence

Segment-write and tail-delete propagate as two independent events. A remote observer can see the deletion before the segment arrives, opening a window in which ops are transiently invisible. Transient inconsistency is harmless **unless something reacts to it durably** — and `IntegrityChecks` and `IntegrityQuarantine` live in exactly that neighbourhood. Transient gap plus a durable reaction to gaps equals permanent damage from a protocol that is otherwise correct.

Out of scope to model (§2), but the model will show the window exists, which is enough to justify it as (a)'s first target.

### 7.3 Clock skew is semantic, not a convergence hazard — §4.4

A documentation fix regardless of the TLC verdict.

### 7.4 Unknown

If §5 works, the discovered assumptions are the ones not listed here. A spike that surfaces only its three predictions has demonstrated the method's *floor*, not its value, and the note should say so plainly.

---

## 8. Guards landed in Swift

Each surfaced assumption that is load-bearing and unpinned gets the cheapest durable guard in the repo's existing idiom.

**Specified now (§1.2):** a `TripwireGrepTests` entry failing if `sealTailIfNeeded`'s body gains an `await`, plus a comment at the site stating why the absence is load-bearing rather than incidental. This is deliberately a grep tripwire and not a runtime test — the property is *syntactic* ("no suspension point exists here"), and the repo already uses grep tripwires for exactly this class (tripwires 13, 14, 23, 32).

Others follow from what surfaces. Guards are landed **in the same pass** as the findings, so that a "no" on (a) does not decay the spike's value to zero.

---

## 9. Stopping rule

**If the first spec-and-check cycle produces no findings, stop and write the no.**

An unbounded spike is how (c) becomes (b) without anyone deciding to. The stopping rule exists to make the negative outcome cheap and therefore genuinely available.

**"No findings" is not the same as "green."** A green run at §4.5's bounds means no property was violated; it says nothing about how many assumptions §5 surfaced along the way, and the assumptions are the deliverable. The two combine as:

| Cycle 1 outcome | Action |
|---|---|
| Assumptions surfaced (green or not) | continue — widen bounds per §4.5, keep going while yield holds |
| Green, and no assumption survived falsification | **stop.** Write the no; the method's floor is its ceiling here |
| Bounds too tight to run meaningfully | **stop.** §4.5's headline practicality finding; write it as the verdict |

---

## 10. Artifacts

| Path | Contents |
|---|---|
| `formal/OpLogSync.tla`, `formal/OpLogSync.cfg` | the spec and its model config — repo root, not under `docs/`, because it is runnable source that needs its config beside it |
| `formal/README.md` | how to run TLC, and the bounds each config uses |
| `docs/superpowers/notes/2026-08-01-formal-methods-spike-findings.md` | the assumption list with traces, and the verdict |
| `MaughamTests/` | guards per §8 |

Nothing under `Maugham/` or `Packages/` changes except comments and tests. The spike does not modify production behaviour; if it finds a live defect, that is reported and scheduled, not fixed inline.

---

## 11. Risks

- **State-space explosion.** Mitigated by §4.5's bounds. Escalates to a finding rather than a failure.
- **Refinement gap.** TLA+ verifies the model, not `OpLogStore.swift`. This spike does **not** attempt trace validation; the gap is real, is stated in the note, and is a first-class input to the (a)/(b) decision rather than something to paper over.
- **Spec drift.** A spec that is not checked in CI rots, and this repo has documented drift (tripwire 32's "count the array, not this cell"). Not a risk for (c) — a spike artifact is allowed to be a snapshot — but it is the central risk for (b), and the note should size it.
- **Modelling the wrong thing.** A model built on a mistaken reading of the code produces confident nonsense. Mitigated by §5's falsification requirement: an assumption that cannot be falsified is discarded, which catches the case where the model has drifted from the code it claims to describe.
