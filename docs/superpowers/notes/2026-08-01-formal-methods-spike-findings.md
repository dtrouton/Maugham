# Formal methods spike — findings and verdict

*2026-08-01. Executes [`docs/superpowers/specs/2026-08-01-formal-methods-spike-design.md`](../specs/2026-08-01-formal-methods-spike-design.md) via [`docs/superpowers/plans/2026-08-01-formal-methods-spike.md`](../plans/2026-08-01-formal-methods-spike.md). Artifacts in [`formal/`](../../../formal/).*

*Staging agreed at the outset: **(c) evaluate → if promising, (a) harden the op log → if that works, consider (b) a standing practice.** This is (c).*

---

> **REVISED 2026-08-01, same day.** §1 below was written before (a) ran. (a) then found a **data-loss defect in shipping code** (`.maugham/checkpoints.jsonl` is an unpartitioned shared JSONL) and, more importantly for the verdict, **TLC found a failure path I had not predicted** — invalidating §1's central claim that the model discovered nothing reading did not. §1 is left standing as written, because the point of §3 was honesty about what the method earned and quietly rewriting it would defeat that. **Read §8 for the corrected verdict.**

## 1. Verdict *(superseded by §8)*

**(a): qualified go — but reframed.** The spike did what it was asked to do: one load-bearing assumption surfaced, sharpened, and pinned in Swift on the path where loss is unrecoverable. The cost was small (all four configs check in under a second; the model is ~200 lines). But the honest accounting in §3 shows the model **discovered nothing that reading the code did not**. Every finding was hypothesised by reading and then *confirmed* by TLC. What TLA+ bought was rigour, not discovery: a belief became a checked fact, the environment's adversarial properties had to be enumerated rather than assumed, and the resulting test is defensible because a falsification pair backs it.

That is worth having, and it is not what was advertised to me at the start. So (a) should proceed **on a target where the answer is genuinely unknown** — the §5.2 integrity/quarantine window — rather than on more targets where a hypothesis already exists. That is the real test of whether the method discovers or merely confirms, and it is cheap to run now that the model exists.

**(b): no, not on this evidence.** One spike is not a basis for a standing practice. The drift risk (§6.3) is unaddressed, nothing runs in CI, and the refinement gap (§6.1) means a green spec never licenses a claim about the Swift. Revisit only if (a) produces a finding that reading did not.

---

## 2. Assumptions surfaced

Per spec §5, an assumption appears here only if it was falsified in **both directions** — modelled without it to confirm TLC produces a counterexample, then with it to confirm green. One qualifies.

### 2.1 The seal's atomicity rests on the absence of `await`, not on `@MainActor` isolation

**Assumption.** `OpLogStore.sealTailIfNeeded` reads the tail's bytes in one `NSFileCoordinator` scope (`OpLogStore.swift:194`) and deletes the tail in another (`:224`). Nothing may interleave an `append` between them.

**Status when found.** The hazard **is** documented, at `OpLogStore.swift:167–175`, including the exact failure mode. The spike's spec originally claimed it was undocumented; that claim was wrong and is corrected in place there. **The finding survives in sharper form**, because the documented justification does not support its conclusion:

> *"…the seal runs on the same MainActor as every append, so the interleaving requires two same-variant app instances on one Mac, which the app's single-instance model rules out."*

Same-actor does not make an `async` body atomic. Swift releases actor isolation at **every `await`**, so a suspension point between the read and the delete admits a same-actor `append` with no second app instance involved. Same-actor is sufficient *only given the absence of a suspension point* — a property of those fifty lines, which the note never states.

**Why that is worse than a plain omission.** A future `await` leaves the paragraph still reading as a valid justification. A maintainer checks the stated premise — still single-instance? yes — and concludes the gap is closed while it stands open. An incomplete argument is more dangerous than a missing one, because it terminates the inquiry.

**Falsification, both directions.**

| Config | Constant | Result |
|---|---|---|
| `OpLogSync_suspend.cfg` | `SealHasSuspensionPoint = TRUE` | `LocalNoLoss` violated, exit 12 |
| `OpLogSync.cfg` | `SealHasSuspensionPoint = FALSE` | no violation, exit 0 |

Counterexample (`formal/OpLogSync.tla`, 7 states). Final state, verbatim:

```
State 7: <SealDelete line 181, col 5 to line 188, col 71 of module OpLogSync>
/\ opsUsed = (d1 :> 0 @@ d2 :> 3)
/\ appended = ( d1 :> {} @@
  d2 :>
      { [dev |-> d2, seq |-> 1],
        [dev |-> d2, seq |-> 2],
        [dev |-> d2, seq |-> 3] } )
/\ tail = (d1 :> {} @@ d2 :> {})
/\ sealed = (d1 :> {} @@ d2 :> {[dev |-> d2, seq |-> 1], [dev |-> d2, seq |-> 2]})
```

`SealRead` captures `{op1, op2}` and frees the lock; `Append` lands `op3`; `SealWrite` seals only the captured two; `SealDelete` removes the whole tail. `op3` is in `appended` and in neither `sealed` nor `tail` — a durably-appended op, silently gone. The constitution's *the words are safe*, failing.

**Now pinned.** `TripwireGrepTests.test_sealTailIfNeededHasNoSuspensionPoint` — a grep tripwire, because the property is syntactic and no runtime test can observe the absence of a suspension point. Verified failable by planting `_ = await Task.yield()` in the body (fails with the op-loss diagnostic; passes on revert). The source note at `:167` is amended in place rather than duplicated.

---

## 3. Predicted vs discovered

The spec predicted three findings in advance (§7) so this section could be honest. **Nothing was discovered that was not predicted.**

| Predicted | Outcome |
|---|---|
| §7.1 seal atomicity | **Confirmed**, both directions, pinned. Sharpened during Task 5 — but by *reading `OpLogStore.swift:167`*, not by the model. |
| §7.2 transient invisibility with a durable reaction | **Confirmed** as a real window (§5.2). Not pinned; out of scope to model further. |
| §7.3 clock skew is semantic, not a convergence hazard | **Not model-checked.** It fell out of the abstraction choice (§4.4), was never falsified, and therefore does not qualify under spec §5. It is a documentation observation, recorded in §5.1 below and explicitly *not* claimed as a result. |

Spec §7.4 asked for this to be stated plainly if it happened, so: **a spike that surfaces only its own predictions has demonstrated the method's floor, not its value.** That is what occurred. The one genuinely new thing — that the documented justification is insufficient — came from reading a file, not from a model checker.

The counter-argument, which I think is real but weaker than it looks: the predictions were only *available* because scoping the spike forced a careful read of the seal path, and that read happened because a model was going to be built. Formal methods extracted value here partly as a **forcing function for attention**. That is a genuine benefit and a poor justification for a toolchain — the same attention is available for free.

---

## 4. Practicality

All measurements on this Mac (M-series, JDK 26, TLC from `tla2tools.jar`), bounds of 2 devices / 3 ops per device / 1 seal.

| Stage | States generated | Distinct | Depth | Runtime |
|---|---|---|---|---|
| Task 2 — append + propagate + merge | 521 | 100 | 9 | <1 s |
| Task 3 — + the three-step seal and the actor lock | 35,421 | 5,929 | 17 | <1 s |
| Task 4 — + the `everSeen` history variable | 48,761 | 8,464 | 17 | <1 s |

**The shape of the cost is the finding, not the absolute numbers.** Adding one three-step action multiplied the distinct state count by **59×**. Runtime is still trivial at these bounds, so nothing bit — but the growth rate is what determines whether the method scales to a model worth trusting. Two devices and one seal is a *small* configuration; the spec's own §4.5 anticipated this and made "the bounds had to be too tight to be interesting" an acceptable headline finding. It did not happen here, but it plainly would at 3 devices with 2 seals each, and a model that can only check the two-device case is checking the case least likely to be wrong.

**Human cost was low and front-loaded.** The model is ~200 lines. Writing it was fast; the time went into deciding *what not to model* (spec §4.4) — the abstraction budget is where the thinking is, and it is not transferable to a subagent or a template.

**One toolchain note.** The spec specified the `temurin` cask; it needs `sudo` and would have blocked unattended execution. The `openjdk` formula installs with no password but is keg-only, so `formal/check.sh` resolves the interpreter itself. No repo state depends on it.

---

## 5. Findings recorded but not model-checked

Kept separate from §2 deliberately — these did not meet the falsification bar and are not claimed as results.

### 5.1 Convergence needs a total order, not a real-time-correct one

ULID order being wrong under clock skew is **not** a convergence hazard. Convergence requires only that every device agrees on *some* total order; sorting any op set yields a unique sequence regardless of whether the timestamps reflect real time. What clock skew actually causes is **semantic**: an op folds into the past, which ADR 0012 already lists as a consequence. The two are conflated in the current prose and separating them is a cheap documentation fix, independent of anything TLC reported.

### 5.2 The transient-invisibility window is real (spec §7.2)

`RemoteMonotonic` — *once a device can see an op, it can always see it* — is **false**, and TLC refutes it (`OpLogSync_monotonic.cfg`, exit 12). Trace: `d2` sees `op1` in `d1`'s tail; `d1` seals and deletes; the now-empty tail propagates to `d2` **before** the segment carrying `op1` does; `d2` can no longer see an op it previously could. The seal's two file events have no cross-device ordering guarantee.

Transient invisibility is harmless in itself. It becomes damage when something reacts to it **durably** — and `IntegrityChecks` / `IntegrityQuarantine` sit in exactly that neighbourhood. **This is (a)'s first target**, and it is the right one precisely because I do not currently know the answer.

### 5.3 Methodology: the shortest counterexample is often the least representative

Worth recording because it will recur. `ReconcileSharedFile` as first written let an **empty** file overwrite a full one, and TLC dutifully returned that as the shortest `LocalNoLoss` violation. It is a true instance of whole-file-replace loss and a useless one — iCloud cannot reach that state, because with no divergence there is nothing to reconcile and the device holding more simply propagates. Three guards (both sides non-empty, and different) were needed before the counterexample became the *historical* defect: two concurrent appends, one dropped.

The general form: **a model checker returns the shortest path to a violation, and an over-permissive environment makes that path an artifact.** A trace has to be read as critically as the code was. A spike that had accepted the first red result would have "confirmed" its model on a transition that cannot occur.

### 5.4 Methodology: centralised history variables cost trace readability

`everSeen` is maintained in `Next` rather than in each action, so a newly added action cannot forget it. The price is that TLC then attributes every step to `Next` and the counterexample loses its action labels — the §5.2 trace has to be read from state contents rather than step names. Robustness against a modelling mistake, paid for in the legibility of the thing the model exists to produce. Worth knowing before choosing the same shape.

---

## 6. What formal methods cannot do here

### 6.1 The refinement gap is not addressed

TLC verified `OpLogSync.tla`. It did not verify `OpLogStore.swift`. Nothing links them but my reading, and the spec deliberately did not attempt trace validation. **A green model licenses no claim about the Swift.** The one place a model conclusion is pinned in code, it is pinned by a test that cites the config which produced it — that citation is the whole of the bridge, and it is made of prose.

### 6.2 The environment-modelling limit — the most transferable finding

The op log was chosen over the editor↔disk loop **not** because it had more bugs — the editor has by far the worse history, three cursor races in 24 hours — but because its environment can be bounded **adversarially**. iCloud's real behaviour is undocumented and version-dependent, and it does not matter: the model says *arbitrarily delayed, arbitrarily ordered, per-file*, and every assumption is tested against the worst case.

The editor loop has no such bound. Tripwire 2's defect was a wrong belief about the environment — `.onChange` fires after the synchronous flag-clear, which nobody expected. A model of SwiftUI's callback ordering is a model of *my belief* about it, and would faithfully reproduce the bug rather than catch it. **Where the unknown is the environment, formal methods are worse than useless: they launder a guess into a proof.**

Stated as a selection criterion: *model a subsystem when you can describe its environment's worst legal behaviour without knowing its actual behaviour.* That rule, and not bug density, is what should pick future targets. It is the single most reusable thing this spike produced.

### 6.3 Drift

An unchecked spec rots, and this repo has documented drift — tripwire 32's *"count the array, not this cell."* Not a risk for (c); a spike artifact is allowed to be a snapshot. It is the central risk for (b), and nothing here addresses it. `formal/check.sh` is not wired into CI, and a `.tla` file that no longer describes the code is a confident liar.

---

## 7. If (a) proceeds

Ordered:

1. **`IntegrityChecks` / `IntegrityQuarantine` against the §5.2 window.** Does anything react durably to a transient gap? The right first target because the answer is genuinely unknown — unlike the seal, where the model confirmed a hypothesis. If TLA+ discovers rather than confirms, it will be here.
2. **Widen bounds to 3 devices / 2 seals** and see where the 59× growth bites. Cheap, and it answers the scaling question §4 raised but did not settle.
3. **Wire `formal/check.sh` into CI** if and only if step 1 pays. All four configs run in under a second, so the cost is near zero — but a spec nobody maintains is worse than no spec, so this waits on evidence that the spec earns maintenance.

Explicitly **not** recommended: modelling the editor loop (§6.2), or attempting trace validation to close the refinement gap (§6.1) — the latter is a large project whose payoff depends entirely on step 1's outcome.

---

# 8. (a) executed — checkpoints, integrity and the backup gate

*Added 2026-08-01, same day, after §7 step 1 ran. Supersedes §1.*

§7 named `IntegrityChecks` / `IntegrityQuarantine` against the §5.2 window as (a)'s first target, on the grounds that it was the one place the answer was genuinely unknown. It was, and the answer is **yes, something reacts durably** — plus two findings nobody was looking for.

## 8.1 Corrected verdict

**(a): go, and it already paid.** It found a data-loss defect in shipping code (§8.3) and a routine false positive that stops backups (§8.2).

**(b): revisit — upgraded from "no".** §1 declined a standing practice on the grounds that the method had only ever confirmed what reading found. **That is no longer true.** In §8.2 TLC produced a four-state counterexample by a mechanism I had explicitly predicted otherwise — I expected the seal's transient window, and the actual path involves no seal at all. That is the method doing the thing it is supposed to do, once, on the fifth property written. Not yet a mandate; enough to reopen the question after the fix lands. The concrete next step is unchanged: wire `formal/check.sh` into CI (all eight configs run in ~15s total).

**What changed my mind is narrow and worth stating precisely.** The model did not find §8.3 or §8.4 — reading found those. What the model did was refute `RemoteMonotonic`, which generated the question *"what reacts durably to a transient gap?"*, and following that question found everything else. Then, when the question was formalised as `DanglingMeansLost`, TLC contradicted my stated mechanism. Prioritising the right question and then correcting the answer is a real contribution and a smaller one than "it finds bugs."

## 8.2 A checkpoint routinely outruns the op it pins, and backups stop

**The chain.** `ProjectIntegrity.check` → `IntegrityChecks.danglingCheckpointPointers` → `IntegrityReport.isHealthy` → `BackupCoordinator.backupNow:62` returns `.integrityFailed` and **skips the backup**. ADR 0014 §3 makes that refusal deliberate — *"corruption must never propagate into a destination"* — and the policy is right. The problem is the input.

`danglingCheckpointPointers`' own doc calls a dangling pointer *"evidence the op log lost ops (corruption or a dropped twin)."* Stated as a property — anything flagged is genuinely lost, i.e. its owner cannot see it either — it is **false**:

```
DanglingMeansLost ==
    \A e \in Devices : \A op \in DanglingAt(e) : op \notin Merged(op.dev)
```

`./formal/check.sh OpLogSync OpLogSync_dangling` → violated in **four states**, with `sealsUsed = (d1 :> 0 @@ d2 :> 0)` — **no seal occurs**:

1. `Append(d1)` — `op1` lands in d1's tail
2. `CreateCheckpoint(d1)` — `cpFile[d1] = {op1}`
3. `PropagateCp(d1, d2)` — d2 receives d1's *checkpoint file*
4. d2 has not yet received d1's *op log*: `viewTail[d2][d1] = {}`

d2 now sees a checkpoint pinning `op1` and cannot see `op1`. It reports corruption and refuses to back up a project in perfect health.

**This was predicted wrongly and the correction matters.** §5.2 attributed the false positive to the seal's transient window. The seal is not required. `checkpoints.jsonl` and the op-log files are separate files that iCloud propagates independently, and a checkpoint *by construction* pins an op written moments earlier — so the checkpoint arriving first is the **ordinary** case, not a race. The seal window widens it; it does not cause it. Severity accordingly is not "rare interleaving" but "expected behaviour on a second Mac."

**Not fixed.** The shape of a fix: a dangling pointer whose referenced doc has files not yet fully propagated is *inconclusive*, not corrupt. Distinguishing "op absent because unpropagated" from "op absent because lost" is the real design question and is not obvious — which is why this is written up rather than patched.

## 8.3 `.maugham/checkpoints.jsonl` is an unpartitioned shared JSONL — data loss

Following the checkpoint thread out of §8.2:

```swift
// CheckpointStore.swift:27
fileURL: projectURL.appendingPathComponent(".maugham/checkpoints.jsonl")
```

One path. No device slug, no glob-and-merge; `JSONLAppendStore` does not partition internally. `.maugham/publications.jsonl` (`PublicationStore.swift:33`) has the identical shape.

This is **exactly what CLAUDE.md tripwire 17 forbids** and what ADR 0012 restructured the op log and inbox to fix. ADR 0012's scope statement names only the op log and the inbox manifest; checkpoints were never in scope, and no ADR records a decision to leave them out. Writers are `CheckpointCapture` (⌘S), `RewindWindow`, and `Bootstrap`.

Two Macs, concurrent ⌘S inside a sync window → iCloud whole-file-replace → the loser's checkpoints land in a conflict twin `load()` never opens. ADR 0012 called the Mac↔Mac case *"latent but rarely triggered"* — and then restructured the op log anyway.

**Model-checked against production constants.** `PerDeviceCheckpoints = FALSE` *is* the shipping configuration:

| Config | Result |
|---|---|
| `OpLogSync_cpshared` (production) | `CheckpointNoLoss` **violated**, 7 states |
| `OpLogSync_cppartitioned` (ADR 0012 pattern applied) | no violation, 75,276 states |

Final state of the violation — d1 created a checkpoint pinning `op1`, and reconciliation replaced its whole file with d2's:

```
/\ cpCreated = (d1 :> {[dev |-> d1, seq |-> 1]} @@ d2 :> {[dev |-> d1, seq |-> 2]})
/\ cpFile    = (d1 :> {[dev |-> d1, seq |-> 2]} @@ d2 :> {[dev |-> d1, seq |-> 2]})
```

The pair is the point: same spec, one constant, and the fix is *proven to be the fix* rather than assumed. **Unfixed.**

## 8.4 The loss erases its own evidence

Two reasons §8.3 is silent, the second much worse than the first.

**The blind spot.** `IntegrityChecks.conflictTwins(inOpsDirectoryFilenames:)` scans only `.maugham/ops/` (`ProjectIntegrity.swift:44`). A conflict twin of `checkpoints.jsonl` lives at `.maugham/`. The detector built for this exact class cannot see it here.

**The self-erasure.** Losing a checkpoint removes **the very pointer whose dangling would have signalled the loss**. Stated as *"if a device has lost a checkpoint it created, something is dangling for it"*:

```
CheckpointLossIsDetected ==
    \A d \in Devices :
        (cpCreated[d] \ MergedCp(d)) # {} => DanglingAt(d) # {}
```

`./formal/check.sh OpLogSync OpLogSync_cpdetect` → **violated**. In the counterexample d1 has lost its checkpoint on `op2` while `tail[d1]` holds both ops, so the surviving pointer resolves cleanly and **nothing dangles**. Widening the twin scan to `.maugham/` would help; it would not close this, because the evidence is destroyed by the event it would evidence.

## 8.5 Cost

Eight configs, ~15s total. The model grew from ~200 to ~330 lines. `MaxCps = 0` on the original four disables checkpoints entirely, so they still measure 8,464 / 64 / 515 / 517 distinct states exactly as in §4 — a clean regression signal that the extension did not disturb the earlier results. `OpLogSync_cppartitioned` at 75,276 distinct states is the largest run and still sub-second; the 59× growth noted in §4 has not yet become a wall, though it is still only two devices.

## 8.6 What should happen next

1. **Partition `checkpoints.jsonl` and `publications.jsonl`** per ADR 0012's existing pattern (`DeviceSlug`, glob-and-merge, legacy unsuffixed file stays a merge source). `OpLogSync_cppartitioned` already shows this closes §8.3. Needs its own spec — it touches `BackupSignature`, `MaughamSidecarPath`, presenter routing, and the rewind UI's checkpoint list.
2. **Widen `conflictTwins`** to scan `.maugham/` as well as `.maugham/ops/`. Small, independent, and useful regardless of (1).
3. **Fix §8.2's false positive** — the design question is how to tell "unpropagated" from "lost". Note that (1) does *not* fix this; they are independent defects that happen to share a file.
4. **Then reconsider (b)**, with CI as the concrete first step.

---

# 9. Second target — annotation lifecycle vs spliced text

*Added 2026-08-01. Model: `formal/AnnotationRace.tla`. Predictions pre-registered in `formal/PREDICTIONS-annotation.md`, committed at `6e6d8bd` **before** the model existed, so the discovery accounting below is checkable in git rather than asserted after the fact.*

## 9.1 The structure

Two **independent** derivations run over one op log and nothing makes them agree:

| | Source | Rule |
|---|---|---|
| **status** | `AnnotationDeriver.swift:11` | the single latest *lifecycle* op by opId wins |
| **text** | `Deriver.swift:63,74` | a fold of **every** op's `changes` in opId order — *"claude_accept … DOES KEEP its changes"* |

`Document+Annotations.swift:377` calls this **"two effects, one op"**: the `claudeAccept` op *itself* carries the spliced paragraph. So the text effect is unconditional the moment accept is written. `claudeReject`, `claudeArchive` and `annotationReopen` carry **no** changes — they can move the status without being able to move the text. Only `claudeAcceptRevert` can put the text back.

ADR 0012 names the trigger — *"reject on phone while accept on Mac"* — as a **routine** overlap, and says partitioning does not settle lifecycle semantics: *"the deriver still has to decide which lifecycle state wins."* It decided. **Nobody asked what happens to the text.**

## 9.2 Results

| Property | Predicted | Result | States |
|---|---|---|---|
| `NoRejectedButSpliced` | violated (P1) | **violated** | 137 |
| `AcceptedImpliesSpliced` | holds | **holds** (full space) | 7,709 |
| `NoOpenButSpliced` | *not predicted* | **violated** | 122 |
| `NoArchivedButSpliced` | pre-declared *not a bug* | violated, as expected and benign | 61 |

### Divergence A — rejected, but the change is in the manuscript

```
id 0  accept  device a
id 1  reject  device b
```

Status `rejected`; text spliced. **The writer rejected a change and has it anyway.** Two devices, two ops, no clock skew required. This is P1 exactly.

### Divergence B — unresolved, but the change is in the manuscript

```
id 0  accept  device a
id 1  reject  device b      (b has not seen a's accept; sees it open)
id 2  reopen  device b      (b hits ⌘Z on its own reject)
```

Status `open`; text spliced. Every action is legitimate *on its own device*. The annotation is re-presented to the writer as an **unresolved suggestion whose change is already in their text** — arguably worse than A, because the natural response is to accept it again.

`AcceptedImpliesSpliced` holding over the full 7,709-state space is the useful negative: `accept` is both a lifecycle op and a change op, so whenever it is the latest lifecycle op it is also the latest change op. The mirror failure is impossible. That bounds the defect to exactly the two shapes above.

## 9.3 Neither is transient — P3 confirmed

Every window found in §2–§8 converged once propagation completed. **These do not.** `claudeAcceptRevert` is the only op carrying inverse changes, and neither `reject` nor `reopen` emits one, so the disagreement is the *settled* state. Syncing harder does not repair it.

## 9.4 Discovery accounting — the honest tally

**No.** TLC produced no mechanism I had not already reasoned to.

- **Divergence A** was predicted in full (P1).
- **Divergence B** is outside the committed predictions file — but I spotted it while *transcribing* `AnnotationDeriver.resolution:169` into the model, and wrote it into the spec as "NOT predicted either way" before running anything. Found by reading-in-service-of-modelling; confirmed by TLC.

**This is the third time that pattern has appeared.** §3 named it — formal methods as *a forcing function for attention* — and dismissed it as "a genuine benefit and a poor justification for a toolchain." Three instances make it a pattern rather than an anecdote, and the dismissal now looks too quick: the attention is nominally free, but it demonstrably does not happen without something forcing it. That is worth more than it was given credit for, and it is still not the same thing as a checker finding bugs.

**And a cost got sharper.** TLC's first `NoOpenButSpliced` counterexample was a **two-op single-device** trace through a `Reopen` guard I had written as `{accepted, rejected, archived}`. The app cannot do that: `annotationReopen` is the undo-compensation for a *reject* or *withdraw*, while undoing an accept emits `claudeAcceptRevert`. Tightening the guard to `rejected` produced the real three-op trace above. **Second instance of §5.3** — the shortest counterexample rides the most permissive transition, so an over-permissive guard yields something that looks like a finding and is an artifact. A less careful operator ships both. That cost belongs in the (b) decision beside the benefit.

Running tally across both models: **one genuine discovery (§8.2) in nine properties**, and **two artifacts** that required catching by hand.

## 9.5 What should happen

Not fixed — proving scope before code changes was the agreed mode, and the fix is a real design decision rather than a patch.

1. **Decide the intended semantics first.** Should a `reject` losing the opId race undo an already-spliced accept? That means rejects must carry inverse changes (become revert-like), which is a wire-format and undo-stack change. Or should the *text* be authoritative and the status follow it? Either is defensible; they are different products.
2. **Divergence B may need answering separately** — reopening after a foreign accept is a distinct case from a plain lost race, and the "accept it twice" follow-on (does `SuggestionSplice.apply` double-splice against a paragraph already containing the suggestion?) is **unchecked and worth checking**.
3. **No Swift test yet.** A test asserting today's behaviour would pin the defect in place. The regression test comes with the fix.
