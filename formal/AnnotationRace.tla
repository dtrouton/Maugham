--------------------------- MODULE AnnotationRace ---------------------------
(***************************************************************************)
(* Maugham's annotation lifecycle against the manuscript text it splices.   *)
(*                                                                         *)
(* ONE annotation of kind `suggestedChange`. Distinct annotations do not    *)
(* interact -- both derivations key on sourceAnnotationId -- so one is the  *)
(* whole problem.                                                          *)
(*                                                                         *)
(* THE SHAPE OF THE HAZARD. Two INDEPENDENT derivations run over one log:  *)
(*                                                                         *)
(*   status  = AnnotationDeriver.swift:11  -- the single latest LIFECYCLE   *)
(*             op by opId wins                                              *)
(*   text    = Deriver.swift:63,74         -- a fold of EVERY op's changes  *)
(*             in opId order; "claude_accept ... DOES KEEP its changes"     *)
(*                                                                         *)
(* The text fold never consults the lifecycle. Nothing makes them agree.    *)
(*                                                                         *)
(* WHICH OPS CARRY CHANGES (Document+Annotations.swift:377, "two effects,   *)
(* one op"): claudeAccept carries the spliced paragraph; claudeAcceptRevert *)
(* carries the inverse. reject / archive / reopen carry NONE -- so they can *)
(* move the status without being able to move the text.                     *)
(*                                                                         *)
(* The op log is abstracted to a totally-ordered set of ops. That is sound  *)
(* and is the op-log spike's own established contract: ops converge to a    *)
(* set, ULID gives a total order, and both derivations are functions of     *)
(* that ordered set. Ids are consecutive integers and ANY device may take   *)
(* the next one, which makes every interleaving reachable -- the adversarial*)
(* reading of ULID order, including clock skew.                             *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS Devices, MaxTotalOps, RejectCarriesInverse

ASSUME MaxTotalOps \in Nat
ASSUME RejectCarriesInverse \in BOOLEAN

\* Lifecycle kinds, exactly AnnotationDeriver.isLifecycleKind:160.
Kinds == {"accept", "reject", "archive", "revert", "reopen"}

(***************************************************************************)
(* THE FIX, as a constant rather than a second spec (BackupRetention's      *)
(* IntactAwarePrune/IntactAwareSkip precedent). RULING-33: "the STATUS      *)
(* WINNER ALSO DECIDES THE TEXT: a reject that beats an accept carries the  *)
(* inverse". Modelled by admitting "reject" to the change-carrying kinds,   *)
(* so the fold's latest-payload-wins rule puts the text back whenever a     *)
(* reject is the newest thing to speak.                                    *)
(*                                                                         *)
(* FIDELITY NOTE. The implementation does not give the ORIGINAL reject a    *)
(* payload -- it cannot: the device that rejects has not seen the accept.   *)
(* `Document.repairRejectedButSplicedAnnotations` appends a FRESH reject    *)
(* carrying the inverse after the merge, which is both the newest lifecycle *)
(* op and the newest changes-carrying op. This spec checks the CONVERGED    *)
(* state, where those two arrangements are the same state, so the constant  *)
(* is faithful at the level the model works. The repair's own idempotence   *)
(* (it fires only while the newest payload is an accept) is a Swift         *)
(* concern, pinned by AnnotationConvergenceTests, not a temporal property   *)
(* here.                                                                   *)
(***************************************************************************)
ChangeKinds == IF RejectCarriesInverse
               THEN {"accept", "revert", "reject"}
               ELSE {"accept", "revert"}

VARIABLES
    log,        \* set of [id, dev, kind]
    nextId,     \* next op id to mint
    view        \* view[d] : set of op ids device d has received

vars == << log, nextId, view >>

Ids(S)     == { o.id : o \in S }
OpsWithIds(S) == { o \in log : o.id \in S }

\* Deterministic: ids are unique by construction.
LatestIn(T) == CHOOSE o \in T : \A p \in T : p.id <= o.id

Lifecycle(S) == { o \in S : o.kind \in Kinds }
Changes(S)   == { o \in S : o.kind \in ChangeKinds }

(***************************************************************************)
(* AnnotationDeriver.resolution:169, transcribed. Note that BOTH revert and *)
(* reopen resolve to "open" (:175), and that reopen carries no changes.     *)
(***************************************************************************)
StatusOf(S) ==
    IF Lifecycle(S) = {} THEN "open"
    ELSE LET l == LatestIn(Lifecycle(S)) IN
         IF l.kind \in {"revert", "reopen"} THEN "open"
         ELSE IF l.kind = "accept"  THEN "accepted"
         ELSE IF l.kind = "reject"  THEN "rejected"
         ELSE "archived"

\* The manuscript fold: the paragraph ends as whatever the HIGHEST-opId op
\* carrying changes wrote. An accept splices the suggestion in; a revert
\* writes the original back.
TextSpliced(S) ==
    IF Changes(S) = {} THEN FALSE
    ELSE LatestIn(Changes(S)).kind = "accept"

TypeOK ==
    /\ nextId \in 0..MaxTotalOps
    /\ view   \in [Devices -> SUBSET (0..MaxTotalOps)]

Init ==
    /\ log    = {}
    /\ nextId = 0
    /\ view   = [d \in Devices |-> {}]

\* A device acts on what IT can currently see -- a writer does not reject an
\* annotation their screen shows as accepted. This guard is what makes the
\* race require genuine concurrency rather than a nonsensical single-device
\* sequence, and it is why a violation is a real user story.
LocalStatus(d) == StatusOf(OpsWithIds(view[d]))

Issue(d, k) ==
    /\ nextId < MaxTotalOps
    /\ LET o == [id |-> nextId, dev |-> d, kind |-> k] IN
        /\ log'  = log \union {o}
        /\ view' = [view EXCEPT ![d] = @ \union {nextId}]
    /\ nextId' = nextId + 1

Accept(d)  == LocalStatus(d) = "open"      /\ Issue(d, "accept")
Reject(d)  == LocalStatus(d) = "open"      /\ Issue(d, "reject")
Archive(d) == LocalStatus(d) \in {"open", "accepted", "rejected"}
                                           /\ Issue(d, "archive")
Revert(d)  == LocalStatus(d) = "accepted"  /\ Issue(d, "revert")
\* `annotationReopen` is the UNDO-compensation for a reject or a withdraw
\* (Document+Annotations.swift:579, ":297"). Undoing an ACCEPT emits
\* claudeAcceptRevert instead, which carries the inverse changes. So reopen
\* is enabled only against a locally-rejected annotation.
\*
\* This guard was initially written as {"accepted","rejected","archived"} and
\* TLC promptly returned a two-op SINGLE-DEVICE counterexample through the
\* "accepted" arm -- a transition the app cannot perform. Second instance of
\* the same trap (findings note §5.3): the shortest counterexample rides the
\* most permissive transition, so an over-permissive guard yields a violation
\* that looks like a finding and is an artifact.
Reopen(d)  == LocalStatus(d) = "rejected"  /\ Issue(d, "reopen")

\* Propagation. Any device may receive any op it has not yet seen, in any
\* order -- the same adversarial filesystem as OpLogSync.tla.
Deliver(e) ==
    /\ \E o \in log :
        /\ o.id \notin view[e]
        /\ view' = [view EXCEPT ![e] = @ \union {o.id}]
    /\ UNCHANGED << log, nextId >>

Next ==
    \/ \E d \in Devices : Accept(d)
    \/ \E d \in Devices : Reject(d)
    \/ \E d \in Devices : Archive(d)
    \/ \E d \in Devices : Revert(d)
    \/ \E d \in Devices : Reopen(d)
    \/ \E e \in Devices : Deliver(e)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* PROPERTIES — evaluated on the WHOLE log, i.e. the settled state every    *)
(* device eventually reaches. A transient disagreement mid-propagation is   *)
(* expected and uninteresting; the claim under test is that the CONVERGED   *)
(* state disagrees, which no amount of syncing then repairs.                *)
(***************************************************************************)

Status == StatusOf(log)
Spliced == TextSpliced(log)

\* P1 — THE HEADLINE. VIOLATED with RejectCarriesInverse = FALSE (the shipped
\* behaviour, 137 states to the counterexample); HOLDS with it TRUE, which is
\* the acceptance test for the RULING-33 fix.
\* The annotation is resolved `rejected` while the manuscript holds the
\* suggested text: the writer rejected a change and has it anyway.
NoRejectedButSpliced == ~(Status = "rejected" /\ Spliced)

\* Expected to HOLD. `accept` is BOTH a lifecycle op and a change op, so if
\* it is the latest lifecycle op it is also the latest change op. A
\* violation here would contradict that reasoning and would be discovery.
AcceptedImpliesSpliced == (Status = "accepted") => Spliced

\* NOT predicted either way — added because `reopen` resolves to "open"
\* (:175) while carrying NO changes, so it can move the status off `accepted`
\* without moving the text back. If this is violated, an annotation reads as
\* unresolved while its change sits in the manuscript.
\*
\* VIOLATED IN BOTH MODES, deliberately. RULING-33 rules on a reject that beats
\* an accept and says nothing about a reopen that does, and its revisit clause
\* parks the rest at the collaboration milestone. The fix is scoped to what was
\* ruled: the divergence-B trace (accept a / reject b / reopen b) survives with
\* RejectCarriesInverse = TRUE through a DIFFERENT ordering — reject first, then
\* a foreign accept, then the reopen — where no reject is the newest payload.
\* This config staying red is the evidence that the fix did not overreach.
NoOpenButSpliced == ~(Status = "open" /\ Spliced)

\* NOT predicted either way. Archiving an ACCEPTED annotation legitimately
\* leaves the text spliced, so this is deliberately NOT asserted as a bug —
\* it is here to make the archive arm's behaviour visible in a counterexample
\* rather than to claim it is wrong.
NoArchivedButSpliced == ~(Status = "archived" /\ Spliced)
=============================================================================
