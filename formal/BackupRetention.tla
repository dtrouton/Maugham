-------------------------- MODULE BackupRetention --------------------------
(***************************************************************************)
(* Maugham's backup retention against its auto-bisect recovery path         *)
(* (ADR 0014). Deliberately OFF the op log — a test of whether the method   *)
(* generalises to ground ADR 0012 had not already prepared.                 *)
(*                                                                         *)
(* THE SHAPE. Two orderings run over one set of generations:                *)
(*                                                                         *)
(*   retention  BackupWriter.prune:109      keeps the highest-sorting N     *)
(*                                          ids. NEVER calls verify.        *)
(*   recovery   BackupRestore.newestIntact  newest-first, first that        *)
(*                                          VERIFIES.                       *)
(*                                                                         *)
(* Recency and intactness are different orders. Nothing reconciles them.    *)
(*                                                                         *)
(* One destination. Multiple destinations are independent (prune is         *)
(* per-destination) and only ever add redundancy, so one is the worst case  *)
(* and the interesting one.                                                 *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Retention,     \* BackupDestination.retention
    MaxGens,       \* bound on generations ever written
    MaxCorrupt,    \* bound on environment corruption events
    MaxEdits,      \* bound on source edits (srcSig is otherwise unbounded
                   \* and the state space infinite — found the hard way)
    IntactAwarePrune,  \* FALSE = BackupWriter.prune as it shipped (recency only)
    IntactAwareSkip    \* FALSE = BackupRunner.latestSignature as it shipped

ASSUME Retention \in Nat /\ MaxGens \in Nat /\ MaxCorrupt \in Nat
ASSUME MaxEdits \in Nat
ASSUME IntactAwarePrune \in BOOLEAN /\ IntactAwareSkip \in BOOLEAN

VARIABLES
    gens,       \* set of [id, intact, sigOK] — generations present on disk
                \*   intact : content verifies against its manifest
                \*   sigOK  : the .signature marker is readable AND still
                \*            equals the signature it was written with
    nextId,     \* next generation id (integers; ULIDs sort chronologically)
    srcSig,     \* the source project's current content signature
    corrupted,  \* count of environment corruption events (bound)
    everIntact, \* history var: TRUE once any intact generation existed
    prunedBad   \* history var: TRUE once a prune deleted an INTACT
                \* generation while KEEPING a non-intact one

vars == << gens, nextId, srcSig, corrupted, everIntact, prunedBad >>

Ids == { g.id : g \in gens }
Max(S) == CHOOSE x \in S : \A y \in S : y <= x

\* BackupWriter.generationIds(...).last — newest by id, intactness ignored.
Newest == IF gens = {} THEN {} ELSE { g \in gens : g.id = Max(Ids) }

\* BackupRunner.latestSignature: the newest generation's marker, or nil if
\* unreadable. Modelled as: the run skips iff the newest generation's marker
\* is readable and matches the source. With IntactAwareSkip = FALSE it is NOT
\* conditioned on intact — which is the shipped defect (§10.2 finding 6).
\*
\* IntactAwareSkip = TRUE is the FIX: the marker counts only when the
\* generation carrying it verifies. Deliberately STRICTER than findings §10.5
\* item 2, which said "read the newest INTACT generation's marker". Walking
\* back past a corrupt newest to an older intact marker still admits a skip
\* while the newest is corrupt — the property below forbids exactly that — and
\* the walk-back is reachable in reality (the writer reverts an edit, so an
\* older marker matches again) even though this model's monotonic srcSig
\* cannot express it. Refusing to skip at all while the newest is corrupt is
\* both simpler and what NoWedgedOnCorruptNewest actually asks for.
SkipsWrite ==
    /\ gens # {}
    /\ \E g \in Newest : g.sigOK /\ g.sig = srcSig
                         /\ (IntactAwareSkip => g.intact)

\* BackupRestore.newestIntact — nil when nothing verifies.
IntactGens == { g \in gens : g.intact }
HasIntact  == IntactGens # {}

TypeOK ==
    /\ nextId    \in 0..MaxGens
    /\ srcSig    \in 0..MaxEdits
    /\ corrupted \in 0..MaxCorrupt
    /\ everIntact \in BOOLEAN
    /\ prunedBad  \in BOOLEAN

Init ==
    /\ gens       = {}
    /\ nextId     = 0
    /\ srcSig     = 0
    /\ corrupted  = 0
    /\ everIntact = FALSE
    /\ prunedBad  = FALSE

(***************************************************************************)
(* prune: keep the highest-sorting `Retention` ids, delete the rest.        *)
(* Transcribed from BackupWriter.prune:109 — the ONLY criterion is the id.  *)
(***************************************************************************)

\* The `n` highest-sorting members of S (all of S when it has n or fewer).
NewestN(S, n) == { g \in S : Cardinality({ h \in S : h.id > g.id }) < n }

KeepByRecency(S) ==
    IF Cardinality(S) <= Retention THEN S ELSE NewestN(S, Retention)

(***************************************************************************)
(* The FIX. Fill the retained slots with the newest generations that        *)
(* VERIFY, and only top up with corrupt ones once the intact ones run out.  *)
(* An intact generation is therefore never deleted to make room for a       *)
(* corrupt one: if any intact generation is dropped there were more than    *)
(* `Retention` of them, so every slot is already taken by an intact one.    *)
(***************************************************************************)
KeepIntactFirst(S) ==
    IF Cardinality(S) <= Retention THEN S
    ELSE LET keptGood == NewestN({ g \in S : g.intact }, Retention)
             slots    == Retention - Cardinality(keptGood)
         IN keptGood \union NewestN({ g \in S : ~g.intact }, slots)

Keep(S) == IF IntactAwarePrune THEN KeepIntactFirst(S) ELSE KeepByRecency(S)

(***************************************************************************)
(* BackupRunner.run for one destination. Skip-unchanged is checked FIRST    *)
(* and short-circuits before any write or prune (BackupRunner.swift:73).    *)
(***************************************************************************)
Run ==
    /\ nextId < MaxGens
    /\ ~SkipsWrite
    /\ LET fresh   == [id |-> nextId, intact |-> TRUE, sigOK |-> TRUE,
                       sig |-> srcSig]
           all     == gens \union {fresh}
           kept    == Keep(all)
           dropped == all \ kept
       IN /\ gens' = kept
          /\ prunedBad' = \/ prunedBad
                          \/ /\ \E d \in dropped : d.intact
                             /\ \E k \in kept    : ~k.intact
    /\ nextId'     = nextId + 1
    /\ everIntact' = TRUE
    /\ UNCHANGED << srcSig, corrupted >>

\* A run that skips: nothing is written and — critically — prune does not run.
RunSkipped ==
    /\ SkipsWrite
    /\ UNCHANGED vars

\* The writer edits the project, so the source signature moves on.
EditSource ==
    /\ srcSig < MaxEdits
    /\ srcSig' = srcSig + 1
    /\ UNCHANGED << gens, nextId, corrupted, everIntact, prunedBad >>

(***************************************************************************)
(* ENVIRONMENT — bit rot, partial sync, a truncated copy. ADR 0014 exists   *)
(* BECAUSE this happens; verify and auto-bisect are its answer.             *)
(*                                                                         *)
(* Two flavours, because the signature marker lives INSIDE the generation   *)
(* directory it describes and can share its fate — or not.                  *)
(***************************************************************************)

\* Content corrupts; the marker survives. This is the case that matters:
\* the generation no longer verifies but still answers skip-detection.
CorruptContentOnly ==
    /\ corrupted < MaxCorrupt
    /\ \E g \in gens :
        /\ g.intact
        /\ gens' = (gens \ {g}) \union
                   {[id |-> g.id, intact |-> FALSE, sigOK |-> g.sigOK,
                     sig |-> g.sig]}
    /\ corrupted' = corrupted + 1
    /\ UNCHANGED << nextId, srcSig, everIntact, prunedBad >>

\* Content and marker both corrupt.
CorruptWhole ==
    /\ corrupted < MaxCorrupt
    /\ \E g \in gens :
        /\ g.intact
        /\ gens' = (gens \ {g}) \union
                   {[id |-> g.id, intact |-> FALSE, sigOK |-> FALSE,
                     sig |-> g.sig]}
    /\ corrupted' = corrupted + 1
    /\ UNCHANGED << nextId, srcSig, everIntact, prunedBad >>

Next ==
    \/ Run
    \/ RunSkipped
    \/ EditSource
    \/ CorruptContentOnly
    \/ CorruptWhole

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* PROPERTIES                                                              *)
(***************************************************************************)

\* P1 — expected VIOLATED (confirmation). A prune deleted an INTACT
\* generation while KEEPING a non-intact one: recency beat recoverability.
\*
\* NB this replaces a first attempt that was VACUOUS — it disjoined
\* `Cardinality(gens) <= Retention`, which is always true after a prune, so
\* the property could not fail. TLC reported it green over the whole space
\* and the greenness meant nothing. A property that cannot fail is the
\* modelling equivalent of a test that cannot fail (repo commit 3167365).
NoCorruptRetainedOverIntact == ~prunedBad

\* P2 — expected VIOLATED. A corrupt NEWEST generation whose marker survives
\* wedges skip-detection: every run returns .skippedUnchanged, so the corrupt
\* newest backup is never replaced while the source is unchanged.
NoWedgedOnCorruptNewest ==
    ~(SkipsWrite /\ \E g \in Newest : ~g.intact)

\* P3 — expected to HOLD. Fewer corruptions than the retention count should
\* always leave something to recover from. A violation means the two
\* orderings interact in a way I did not model, and is DISCOVERY.
FewerCorruptionsThanRetentionKeepsAnIntact ==
    (corrupted < Retention /\ everIntact) => HasIntact

\* P3, RESTATED. The first attempt omitted the "retention is actually full"
\* antecedent, so TLC violated it with one generation and one corruption —
\* true, trivial, and nothing to do with the system. My error, not a finding.
\* This is the claim I meant: with the retained set FULL, strictly fewer
\* corruptions than the retention count always leaves something to recover.
FullRetentionSurvivesFewerCorruptions ==
    (Cardinality(gens) >= Retention /\ corrupted < Retention /\ everIntact)
        => HasIntact

\* P4 — expected to HOLD. A run that writes cannot destroy its own output.
RunLeavesAnIntact ==
    (everIntact /\ corrupted = 0) => HasIntact
=============================================================================
