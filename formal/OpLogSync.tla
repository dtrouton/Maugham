----------------------------- MODULE OpLogSync -----------------------------
(***************************************************************************)
(* Maugham's op-log sync protocol (ADR 0012), the seal (ADR 0016), and the  *)
(* checkpoint / integrity / backup chain (ADR 0014).                        *)
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
(*                                                                         *)
(* NOTE ON PRODUCTION FIDELITY. Two constants describe TODAY's code:        *)
(*   PerDeviceFiles       = TRUE   ops are partitioned (ADR 0012)           *)
(*   PerDeviceCheckpoints = TRUE   checkpoints and publications are too,    *)
(*                                 as of FM-1                               *)
(*                                                                         *)
(* PerDeviceCheckpoints = FALSE described the shipping system until FM-1,   *)
(* and CheckpointNoLoss's violation under it was a live defect rather than  *)
(* a hypothetical. It is now an ordinary falsification partner: it must go  *)
(* on failing, because what it describes is the regression.                 *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Devices,                \* symmetry set of device ids
    MaxOps,                 \* per-device append bound
    MaxSeals,               \* per-device seal bound
    MaxCps,                 \* per-device checkpoint bound
    PerDeviceFiles,         \* TRUE  = ADR 0012 partitioning (production)
                            \* FALSE = pre-0012 single shared op-log file
    PerDeviceCheckpoints,   \* FALSE = pre-FM-1: one shared
                            \*         .maugham/checkpoints.jsonl
                            \* TRUE  = ADR 0012's pattern applied
                            \*         (production since FM-1)
    SealHasSuspensionPoint  \* TRUE  = an `await` splits the seal's read
                            \*         from its delete

ASSUME MaxOps \in Nat /\ MaxSeals \in Nat /\ MaxCps \in Nat
ASSUME PerDeviceFiles \in BOOLEAN
ASSUME PerDeviceCheckpoints \in BOOLEAN
ASSUME SealHasSuspensionPoint \in BOOLEAN

VARIABLES
    tail,       \* tail[d]        : set of ops in d's live tail file
    sealed,     \* sealed[d]      : set of ops in d's sealed segments
    viewTail,   \* viewTail[e][d] : e's currently-visible version of d's tail
    viewSealed, \* viewSealed[e][d]
    appended,   \* appended[d]    : history var -- ops d durably appended
    opsUsed,    \* opsUsed[d]     : bound counter
    sealsUsed,  \* sealsUsed[d]   : bound counter
    lock,       \* lock[d]        : "free", or the role holding d's MainActor
    captured,   \* captured[d]    : the seal's step-1 read buffer
    cpFile,     \* cpFile[d]      : ops pinned by checkpoints in d's cp file
    viewCp,     \* viewCp[e][d]   : e's visible version of d's cp file
    cpCreated,  \* cpCreated[d]   : history var -- checkpoints d durably made
    cpsUsed,    \* cpsUsed[d]     : bound counter
    everSeen    \* everSeen[e]    : every op e ever had visible. Grows only.
                \*                  Maintained by Next, not by the individual
                \*                  actions -- no UNCHANGED may mention it.

opVars == << tail, sealed, viewTail, viewSealed, appended, opsUsed,
              sealsUsed, lock, captured >>
cpVars == << cpFile, viewCp, cpCreated, cpsUsed >>
vars   == << tail, sealed, viewTail, viewSealed, appended, opsUsed,
              sealsUsed, lock, captured, cpFile, viewCp, cpCreated,
              cpsUsed, everSeen >>

\* An op is identified by its origin device and a per-device counter. This
\* stands in for the ULID: globally unique, and that is all merge needs.
Ops == [dev : Devices, seq : 1..MaxOps]

\* A checkpoint is modelled AS the op it pins (Checkpoint.docPointers maps a
\* doc to an opId). Collapsing the record to its pointer keeps the state
\* space tractable and loses nothing: the dangling-pointer check reads only
\* the pointer.
Merged(e)   == UNION { viewTail[e][d] \union viewSealed[e][d] : d \in Devices }
MergedCp(e) == UNION { viewCp[e][d] : d \in Devices }

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
    /\ cpFile     \in [Devices -> SUBSET Ops]
    /\ viewCp     \in [Devices -> [Devices -> SUBSET Ops]]
    /\ cpCreated  \in [Devices -> SUBSET Ops]
    /\ cpsUsed    \in [Devices -> 0..MaxCps]
    /\ everSeen   \in [Devices -> SUBSET Ops]

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
    /\ cpFile     = [d \in Devices |-> {}]
    /\ viewCp     = [e \in Devices |-> [d \in Devices |-> {}]]
    /\ cpCreated  = [d \in Devices |-> {}]
    /\ cpsUsed    = [d \in Devices |-> 0]
    /\ everSeen   = [e \in Devices |-> {}]

(***************************************************************************)
(* OP LOG                                                                  *)
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
    /\ UNCHANGED cpVars

(***************************************************************************)
(* Propagation. Whole-file replace, per file, in any order, at any time --  *)
(* which is what iCloud Drive actually does and the reason ADR 0012 exists. *)
(* The tail and segment actions are INDEPENDENT: this is what lets an       *)
(* observer see a tail deletion before the segment carrying those ops.      *)
(***************************************************************************)
PropagateTail(d, e) ==
    /\ d # e
    /\ viewTail' = [viewTail EXCEPT ![e][d] = tail[d]]
    /\ UNCHANGED << tail, sealed, viewSealed, appended, opsUsed, sealsUsed,
                    lock, captured >>
    /\ UNCHANGED cpVars

PropagateSealed(d, e) ==
    /\ d # e
    /\ viewSealed' = [viewSealed EXCEPT ![e][d] = sealed[d]]
    /\ UNCHANGED << tail, sealed, viewTail, appended, opsUsed, sealsUsed,
                    lock, captured >>
    /\ UNCHANGED cpVars

(***************************************************************************)
(* The pre-ADR-0012 world for the OP LOG, enabled only when                *)
(* PerDeviceFiles = FALSE. Every device appends to ONE shared file. iCloud  *)
(* reconciles divergence by whole-file replace: one version wins, the       *)
(* loser's copy lands as a conflict twin the loader never opens.            *)
(*                                                                         *)
(* The guards matter. Without them the action fires when e's file is empty  *)
(* -- "an empty file overwrites a full one" -- which is a real instance of  *)
(* whole-file-replace loss but NOT a state iCloud can reach: with no        *)
(* divergence there is nothing to reconcile, and the device holding more    *)
(* simply propagates. Requiring both sides non-empty AND different forces   *)
(* the counterexample to be the historical defect rather than an artifact.  *)
(***************************************************************************)
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
    /\ UNCHANGED cpVars

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
    /\ UNCHANGED cpVars

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
    /\ UNCHANGED cpVars

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
    /\ UNCHANGED cpVars

(***************************************************************************)
(* CHECKPOINTS (ADR 0014; CheckpointStore.swift:27)                        *)
(*                                                                         *)
(* A checkpoint pins an op the creating device can currently see -- that is *)
(* what CheckpointCapture does on Cmd-S. The file is                        *)
(* `.maugham/checkpoints.jsonl`: ONE PATH, no device slug, no glob. So      *)
(* ReconcileSharedCpFile is enabled in the PRODUCTION configuration, unlike *)
(* its op-log twin above.                                                   *)
(***************************************************************************)
CreateCheckpoint(d) ==
    /\ cpsUsed[d] < MaxCps
    /\ \E op \in Merged(d) :
        /\ cpFile'    = [cpFile    EXCEPT ![d] = @ \union {op}]
        /\ cpCreated' = [cpCreated EXCEPT ![d] = @ \union {op}]
        /\ viewCp'    = [viewCp    EXCEPT ![d][d] = @ \union {op}]
    /\ cpsUsed' = [cpsUsed EXCEPT ![d] = @ + 1]
    /\ UNCHANGED opVars

PropagateCp(d, e) ==
    /\ d # e
    /\ viewCp' = [viewCp EXCEPT ![e][d] = cpFile[d]]
    /\ UNCHANGED << cpFile, cpCreated, cpsUsed >>
    /\ UNCHANGED opVars

\* The checkpoint file's whole-file reconciliation. Same mechanism and same
\* guards as ReconcileSharedFile -- but gated on PerDeviceCheckpoints, which
\* is FALSE in production.
ReconcileSharedCpFile(d, e) ==
    /\ ~PerDeviceCheckpoints
    /\ d # e
    /\ cpFile[d] # {}
    /\ cpFile[e] # {}
    /\ cpFile[d] # cpFile[e]
    /\ cpFile' = [cpFile EXCEPT ![e] = cpFile[d]]
    /\ viewCp' = [viewCp EXCEPT ![e][e] = cpFile[d], ![d][d] = cpFile[d]]
    /\ UNCHANGED << cpCreated, cpsUsed >>
    /\ UNCHANGED opVars

BaseNext ==
    \/ \E d \in Devices : Append(d)
    \/ \E d, e \in Devices : PropagateTail(d, e)
    \/ \E d, e \in Devices : PropagateSealed(d, e)
    \/ \E d, e \in Devices : ReconcileSharedFile(d, e)
    \/ \E d \in Devices : SealRead(d)
    \/ \E d \in Devices : SealWrite(d)
    \/ \E d \in Devices : SealDelete(d)
    \/ \E d \in Devices : CreateCheckpoint(d)
    \/ \E d, e \in Devices : PropagateCp(d, e)
    \/ \E d, e \in Devices : ReconcileSharedCpFile(d, e)

\* `everSeen` is maintained here rather than in each action, so that adding a
\* new action cannot forget it.
Next ==
    /\ BaseNext
    /\ everSeen' = [e \in Devices |-> everSeen[e] \union Merged(e)']

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

FullySynced(e) ==
    \A d \in Devices :
        /\ viewTail[e][d]   = tail[d]
        /\ viewSealed[e][d] = sealed[d]

Convergence ==
    \A e, f \in Devices :
        (FullySynced(e) /\ FullySynced(f)) => (Merged(e) = Merged(f))

(***************************************************************************)
(* PLAUSIBLE AND FALSE (spec section 7.2).                                 *)
(*                                                                         *)
(* "Once a device can see an op, it can always see it." A reasonable reader *)
(* of ADR 0016 would assume this. It is false, and the counterexample is a  *)
(* FINDING, not a defect in the model: the seal's segment-write and         *)
(* tail-delete propagate as TWO INDEPENDENT file events with no ordering    *)
(* guarantee, so a remote observer can receive the deletion first.          *)
(***************************************************************************)
RemoteMonotonic ==
    \A e \in Devices : everSeen[e] \subseteq Merged(e)

(***************************************************************************)
(* FINDING 2 -- checkpoint durability.                                     *)
(*                                                                         *)
(* A checkpoint a device durably created is in that device's own view       *)
(* forever. Exactly LocalNoLoss, for the checkpoint file.                   *)
(*                                                                         *)
(* VIOLATED with PerDeviceCheckpoints = FALSE, which is what shipped until  *)
(* FM-1. Green with TRUE, which is ADR 0012's pattern applied to            *)
(* .maugham/checkpoints.jsonl and .maugham/publications.jsonl, and is now   *)
(* production. The pair is the proof that partitioning is the fix and not   *)
(* merely a tidy-up. Swift-side pins: CheckpointPartitioningTests.          *)
(***************************************************************************)
CheckpointNoLoss ==
    \A d \in Devices : cpCreated[d] \subseteq MergedCp(d)

(***************************************************************************)
(* FINDING 1 -- the integrity check's false positive.                      *)
(*                                                                         *)
(* `IntegrityChecks.danglingCheckpointPointers` flags any checkpoint        *)
(* pointer whose op is not in the reader's merged op set, and               *)
(* BackupCoordinator turns a non-empty result into `.integrityFailed` and   *)
(* SKIPS THE BACKUP (ADR 0014 section 3). Its doc comment calls a dangling  *)
(* pointer "evidence the op log lost ops."                                  *)
(*                                                                         *)
(* This states that claim as a property: anything flagged as dangling is    *)
(* genuinely lost -- not merely unpropagated. Its owner cannot see it       *)
(* either. Expected VIOLATED: a mid-seal remote reader flags a perfectly    *)
(* healthy op, and a real project is refused a backup.                      *)
(***************************************************************************)
DanglingAt(e) == { op \in MergedCp(e) : op \notin Merged(e) }

DanglingMeansLost ==
    \A e \in Devices :
        \A op \in DanglingAt(e) : op \notin Merged(op.dev)

(***************************************************************************)
(* FINDING 3 -- the loss is undetectable, and worse than a blind spot.     *)
(*                                                                         *)
(* `IntegrityChecks.conflictTwins` scans ONLY `.maugham/ops/`, so a         *)
(* conflict twin of `checkpoints.jsonl` (which lives at `.maugham/`) is     *)
(* invisible to it. But the sharper problem is self-erasure: losing a       *)
(* checkpoint removes the very POINTER whose dangling would have signalled  *)
(* the loss. The evidence is destroyed by the event it would evidence.      *)
(*                                                                         *)
(* Stated as: if a device has lost a checkpoint it created, SOMETHING is    *)
(* dangling for it. Expected VIOLATED -- nothing is.                        *)
(***************************************************************************)
CheckpointLossIsDetected ==
    \A d \in Devices :
        (cpCreated[d] \ MergedCp(d)) # {} => DanglingAt(d) # {}
=============================================================================
