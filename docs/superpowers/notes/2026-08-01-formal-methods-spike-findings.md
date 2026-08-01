# Formal methods spike — findings and verdict

*2026-08-01. Executes [`docs/superpowers/specs/2026-08-01-formal-methods-spike-design.md`](../specs/2026-08-01-formal-methods-spike-design.md) via [`docs/superpowers/plans/2026-08-01-formal-methods-spike.md`](../plans/2026-08-01-formal-methods-spike.md). Artifacts in [`formal/`](../../../formal/).*

*Staging agreed at the outset: **(c) evaluate → if promising, (a) harden the op log → if that works, consider (b) a standing practice.** This is (c).*

---

## 1. Verdict

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
