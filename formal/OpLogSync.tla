----------------------------- MODULE OpLogSync -----------------------------
(***************************************************************************)
(* Maugham's op-log sync protocol (ADR 0012) and seal (ADR 0016).          *)
(*                                                                         *)
(* Ops are an unordered SET. Sound because ULID order is total, so the      *)
(* sorted sequence is a function of the set, so derived state is too        *)
(* (spec section 4.4). The deriver is not modelled: it is a pure fold, so   *)
(* equal op sets imply equal derived state by construction.                 *)
(*                                                                         *)
(* The filesystem is ADVERSARIAL (spec section 4.1): propagation is         *)
(* per-file, arbitrarily delayed and arbitrarily ordered between any two    *)
(* devices. We do not need to know how iCloud actually behaves -- we model  *)
(* it as bad as it is allowed to be.                                        *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Devices,                \* symmetry set of device ids
    MaxOps,                 \* per-device append bound
    MaxSeals,               \* per-device seal bound
    PerDeviceFiles,         \* TRUE  = ADR 0012 partitioning (production)
                            \* FALSE = pre-0012 single shared file
    SealHasSuspensionPoint  \* TRUE  = an `await` splits the seal's read
                            \*         from its delete

ASSUME MaxOps \in Nat /\ MaxSeals \in Nat
ASSUME PerDeviceFiles \in BOOLEAN
ASSUME SealHasSuspensionPoint \in BOOLEAN

VARIABLES
    tail,       \* tail[d]        : set of ops in d's live tail file
    sealed,     \* sealed[d]      : set of ops in d's sealed segments
    viewTail,   \* viewTail[e][d] : e's currently-visible version of d's tail
    viewSealed, \* viewSealed[e][d]
    appended,   \* appended[d]    : history variable -- every op d ever
                \*                  durably appended. Never shrinks.
    opsUsed,    \* opsUsed[d]     : bound counter
    sealsUsed,  \* sealsUsed[d]   : bound counter
    lock,       \* lock[d]        : "free", or the role holding d's MainActor
    captured    \* captured[d]    : the seal's step-1 read buffer

vars == << tail, sealed, viewTail, viewSealed, appended, opsUsed,
           sealsUsed, lock, captured >>

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
    /\ lock       \in [Devices -> {"free", "appender", "sealer"}]
    /\ captured   \in [Devices -> SUBSET Ops]

Init ==
    /\ tail       = [d \in Devices |-> {}]
    /\ sealed     = [d \in Devices |-> {}]
    /\ viewTail   = [e \in Devices |-> [d \in Devices |-> {}]]
    /\ viewSealed = [e \in Devices |-> [d \in Devices |-> {}]]
    /\ appended   = [d \in Devices |-> {}]
    /\ opsUsed    = [d \in Devices |-> 0]
    /\ sealsUsed  = [d \in Devices |-> 0]
    /\ lock       = [d \in Devices |-> "free"]
    /\ captured   = [d \in Devices |-> {}]

(***************************************************************************)
(* Append. A device writes to its own tail, and sees its own write          *)
(* immediately -- local writes do not propagate, they simply are.           *)
(***************************************************************************)
\* The `lock[d] = "free"` guard is the whole point: `append` is a @MainActor
\* method and cannot run while another @MainActor method holds isolation.
Append(d) ==
    /\ lock[d] = "free"
    /\ opsUsed[d] < MaxOps
    /\ LET op == [dev |-> d, seq |-> opsUsed[d] + 1] IN
        /\ tail'     = [tail     EXCEPT ![d] = @ \union {op}]
        /\ appended' = [appended EXCEPT ![d] = @ \union {op}]
        /\ viewTail' = [viewTail EXCEPT ![d][d] = @ \union {op}]
    /\ opsUsed' = [opsUsed EXCEPT ![d] = @ + 1]
    /\ UNCHANGED << sealed, viewSealed, sealsUsed, lock, captured >>

(***************************************************************************)
(* Propagation. Whole-file replace, per file, in any order, at any time --  *)
(* which is what iCloud Drive actually does and the reason ADR 0012 exists. *)
(* The two actions are INDEPENDENT: this is what lets an observer see a     *)
(* tail deletion before the segment carrying those ops arrives.             *)
(***************************************************************************)
PropagateTail(d, e) ==
    /\ d # e
    /\ viewTail' = [viewTail EXCEPT ![e][d] = tail[d]]
    /\ UNCHANGED << tail, sealed, viewSealed, appended, opsUsed, sealsUsed,
                    lock, captured >>

PropagateSealed(d, e) ==
    /\ d # e
    /\ viewSealed' = [viewSealed EXCEPT ![e][d] = sealed[d]]
    /\ UNCHANGED << tail, sealed, viewTail, appended, opsUsed, sealsUsed,
                    lock, captured >>

(***************************************************************************)
(* The pre-ADR-0012 world, enabled only when PerDeviceFiles = FALSE.        *)
(*                                                                         *)
(* Every device appends to ONE shared file. iCloud reconciles divergence by *)
(* whole-file replace: one version wins, the loser's copy lands as a        *)
(* conflict twin that the loader never opens, and those ops are gone.       *)
(*                                                                         *)
(* Modelled as d's file overwriting e's, destroying whatever e had not yet  *)
(* propagated. The per-device view structure is retained rather than        *)
(* collapsed to a single variable: it captures the essential failure with   *)
(* no restructuring, and keeps the two configs running the same actions.    *)
(***************************************************************************)
\* The guards matter. Without them the action fires when e's file is empty --
\* "an empty file overwrites a full one" -- which is a real instance of
\* whole-file-replace loss but NOT a state iCloud can reach: with no
\* divergence there is nothing to reconcile, and the device holding more
\* simply propagates. Requiring that the loser has content AND that the two
\* versions actually differ forces the counterexample to be the historical
\* defect (two concurrent appends, one dropped) rather than an artifact of an
\* over-permissive environment.
ReconcileSharedFile(d, e) ==
    /\ ~PerDeviceFiles
    /\ d # e
    /\ tail[d] # {}
    /\ tail[e] # {}
    /\ tail[d] # tail[e]
    /\ tail'     = [tail     EXCEPT ![e] = tail[d]]
    /\ viewTail' = [viewTail EXCEPT ![e][e] = tail[d], ![d][d] = tail[d]]
    /\ UNCHANGED << sealed, viewSealed, appended, opsUsed, sealsUsed,
                    lock, captured >>

(***************************************************************************)
(* The seal (ADR 0016, OpLogStore.sealTailIfNeeded:177).                   *)
(*                                                                         *)
(* Three steps, deliberately NOT one atomic action -- the decomposition IS  *)
(* the hypothesis under test (spec section 1.2):                            *)
(*                                                                         *)
(*   SealRead    line 194 -- coordinated read of the tail's bytes           *)
(*   SealWrite   line 217 -- atomic rename of the .mzseg into place         *)
(*   SealDelete  line 224 -- coordinated delete, a SEPARATE coordination    *)
(*                           scope from the read                            *)
(*                                                                         *)
(* OpLogStore is @MainActor, so these run under the device's lock. But an   *)
(* `async` function releases actor isolation at EVERY `await`.              *)
(* SealHasSuspensionPoint = TRUE frees the lock between the read and the    *)
(* delete, exactly as one `await` in that body would.                       *)
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

\* Segment-before-delete. This ordering is CORRECT and must not be swapped:
\* a mid-seal reader sees both files and dedup-by-opId absorbs the duplicate.
\* Reversing these two actions is the bug this ordering already avoids.
SealWrite(d) ==
    /\ captured[d] # {}
    /\ lock[d] \in {"free", "sealer"}
    /\ sealed'     = [sealed     EXCEPT ![d] = @ \union captured[d]]
    /\ viewSealed' = [viewSealed EXCEPT ![d][d] = @ \union captured[d]]
    /\ UNCHANGED << tail, viewTail, appended, opsUsed, sealsUsed, lock,
                    captured >>

\* Deletes the WHOLE tail -- not `tail \ captured`. This mirrors the code:
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

Next ==
    \/ \E d \in Devices : Append(d)
    \/ \E d, e \in Devices : PropagateTail(d, e)
    \/ \E d, e \in Devices : PropagateSealed(d, e)
    \/ \E d, e \in Devices : ReconcileSharedFile(d, e)
    \/ \E d \in Devices : SealRead(d)
    \/ \E d \in Devices : SealWrite(d)
    \/ \E d \in Devices : SealDelete(d)

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
