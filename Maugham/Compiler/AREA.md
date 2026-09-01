# Compiler — Area guide

Maugham's **author compiler** (M2, rewired to the review queue in M4 P1): the
writer presses ⌘R, a warm `claude -p` session reads what has changed since the
last run, and each finding lands where its NATURE says it belongs (ADR 0029;
spec `2026-08-17-one-loop-two-tempos-design.md` §2) — a conformance strain
stays report-side as a ¶-anchored diagnostic in the Diagnostics pane; a
continuity question or a reader's report mints as a pass-stamped annotation
instead, a margin card in Author and a queue row in Review, with the full
disposition vocabulary every other note already has. Read this before editing
in `Maugham/Compiler/`. Also read the project root `CLAUDE.md` for
cross-cutting invariants, the design of record —
`docs/superpowers/specs/2026-08-04-m2-author-compiler-design.md` — its
supersession —
`docs/superpowers/specs/2026-08-07-compiler-second-draft-design.md`, which
keeps the run's mechanism unchanged (§5's opening line) but replaces the
workflow half: notes, fates, the answer flow and the pane's organization — and
`docs/superpowers/specs/2026-08-17-one-loop-two-tempos-design.md`, which routes
findings by nature and personifies each pass as a named editor.

**The run speaks the v2 contract** (spec §5), M3-P3 added a fifth line to it
and the editorial letter (P1 Task 2) a sixth: four line-delimited note sections
— conformance against the writer's derived clauses, continuity questions, a
reader's report, and fact-candidates that land silently in the bible — plus
`intent_drift`, a verdict on the reading as a whole rather than a thing found
in it, plus `letter`, an editorial letter about the manuscript as a whole
(`Letter`, on `CompilerRun.letter`). **The letter is asked LAST**, so the
writer reads line-level results while it is still being written, and it is the
one section whose parts are prose rather than findings — with one exception:
each of its questions that resolves a ref also mints a `.letterQuestion`
diagnostic, which reaches the queue as a `.query` and never the sidecar. Two
rules are the letter's alone (spec §3.1, global constraint 8): a dangling ref
costs a letter entry its jump links and not its prose (`letterRefs`, beside
`resolveRefs`, which drops such an entry for every other section), and neither
a dangling ref nor a cap moves `droppedDangling` — the letter is not a note.
The two scrubs are asked of different things (`letterProseLeaksAnId`): EVERY
prose field is scrubbed for a leaked paragraph id and the entry dropped
(`about`/`one_thing` are fields rather than entries, so they empty instead),
while the fix-shape scrub stops at `questions`, the one part that leaves the
letter and becomes a `.query` the writer must be able to answer — `exercise` is
exempt because a Le Guin feed-forward is a directive by nature. Neither scrub
moves `droppedDangling` either.
**The letter's scene table has a position, and the run decides it** (spec
§3.4, P1 Task 3). `ScenePosition.derive` reads three things the writer owns —
the project's type, their intent statement and the active pass's brief — and
answers `none` (no table at all), `weak` (rows, charge always null, no conflict
field, a blank `changes` read as an observation) or one of the two strong
forms; `CompilerPrompt.scenePositionSection` states it in one sentence per run,
so the model is TOLD its position and never asked to infer one. **The
`strongDeclared`/`strongDefault` split is the doctrine**: a turn-less scene is
a conformance strain ONLY where the writer's own words carry the clause it
strains against, because conformance is keyed on a `clause_quote` from the
intent statement and nothing here may synthesize one on their behalf. Reached
any other way — a screenplay whose intent is silent, a prose piece opted in by
a pass brief — it stays an observation and the gap belongs to the
Add-to-intent offer (Task 9). Two rules are easy to get wrong: the derivation
reads the **WHOLE** statement rather than `StatementEssay.half(of:)`, because
that offer files its clause under `## Rulings`
(`CompilerRunCommandTests.test_theDerivationReadsTheRulingsHalfAndNotJustTheEssay`
is the call site's own guard), and the writer's explicit **opt-out beats
everything**, including a clause elsewhere in the same statement. The position
is derived at the keystroke, carried on `StreamingRun`, and stamped onto
`Letter.scenePosition` in the one `record(...)` spelling, so a preview and the
answer that supersedes it cannot disagree — its raw values are a disk format.

`CompilerPrompt.sectionSchemaDescription` is what is asked for and
`DiagnosticIngest.parseSection`/`parseAll` is what reads it. **The v1 contract
is gone**: `runMessage`, `CompilerContext` and `DiagnosticIngest.parse` were
retired in Stage 2's own docs task once the atomic switch (below) proved they
had no production caller — a grep for `runMessage(` today finds nothing at
all, not even a test.

One thing v1 had that v2 still does not: a free-form category tag (the section
a note came from is its whole classification).

**The word "drift" now names two separate things, and they must never be
merged.** `DriftDetector`/`DriftFinding` are M2's clause-strain PATTERN across
run records — the same clause straining for `consecutiveRunsThreshold` runs,
surfaced as `DiagnosticsPane.driftNote`. `intent_drift` is M3-P3's per-round
JUDGEMENT, a `holds`/`drifted` verdict the model returns in the fifth section
and the run record carries on `CompilerRun.intentDriftVerdict`. They have
different inputs, different lifetimes and different surfaces; the wire word is
`intent_drift` and the app word for the pattern is `drift`.

Two sentences hold the whole design:

- **The keystroke is the only trigger.** Nothing here reaches for itself. A run
  on every pause is the background linter the constitution excludes (must-not
  #2), and every timer in this area exists to end a session, never to start one.
- **The compiler reads and never writes.** It reads the manuscript through an
  enumerated read-only MCP allowlist and answers with a structured message; the
  spawned model never calls a tool that mutates anything. **What puts words
  anywhere is Maugham itself, after the turn is over, materializing the parsed
  report into the layers the writer already governs** ([ADR
  0029](../../docs/adr/0029-the-compilers-report-is-materialized.md), amending
  [ADR 0028](../../docs/adr/0028-maugham-goes-outbound.md) §3's framing): a
  continuity question or a reader's report becomes a pass-stamped annotation
  (`Environment.mintAnnotations`, M4 P1 Task 3), a fact-candidate a bible entry,
  and a kept conformance strain a promoted task. The one route into a
  *statement* — the yardstick the compiler is judged against — is still only
  `RulingPerformer`, and its input is still a sentence the writer typed. (The M2
  answer shim that routed into it, `IntentAppendPerformer`, is gone: the pane's
  reply field calls the verb.)

**Each pass is a named editor, and the resolution has one spelling** (M4 P1
Task 1, `ReviewPass.swift`). The four presets ship as **Perkins** (Structural),
**Lish** (Line), **Gould** (Copyedit) and **Argus** (Proof), each carrying a
seeded `brief` — what its rounds attend to, and as sharply what they leave
alone — and an `editorName`. A pass's own `brief`/`editorName` field wins when
set; a customized manifest can store a preset-id pass that predates both
fields, so every reader resolves through `ReviewPass.effectiveBrief`/
`.effectiveEditorName` rather than the raw fields — `PieceReader`
(`Maugham/Models/PieceReader.swift`) is the one production call site, and its
own comment names why reading `pass.editorName` directly would sign a Copyedit
round's notes with nothing at all. The resolved name goes three places: the
**annotation author** on every note that pass mints (`CompilerMintContext.
editorName`, so the queue's author filter becomes "everything Gould flagged"),
the round briefing's **role frame** (`CompilerPrompt.passSection`, "You are
Gould, this manuscript's Copyedit editor"), and the pass's own brief, embedded
in the same briefing so attention follows the register the writer chose.

**Who reads a piece has ONE resolution** (editorial letter P1 Task 5, spec
§4.1): `ProjectManifest.reader(forPiece:memory:)` answers a `PieceReader` —
*stage* / *coach* / *nobody* — and `CompilerEnvironment+Project.swift`'s
`activePass` closure asks it rather than re-deriving the rule. A stored active
pass that still names a stage wins; else the coach, unless the writer vacated
her seat; else nobody. So an **unassigned piece is Le Guin's**, files rounds in
her `workshop` lane and mints notes signed "Le Guin" — with no orchestrator
change, because she is an `ActivePass` like any pass. A **retired** pass id
reads as unassigned (`validatedActivePass`) and therefore falls to the coach:
deleting a pass gives its pieces back to her. `ActivePass.isCoach` is the one
thing that differs downstream, and `CompilerPrompt.passSection` is the only
reader of it — a coach is framed as a teacher ("You are Le Guin, this writer's
workshop teacher.") where a stage is framed as an editor. `nil` — no
`ActivePass` at all — is now reached ONLY by a vacated seat: that is the
passless lane, which mints no round, stamps nothing and signs "Claude", M2's
identity, unchanged. `CompilerOrchestrator.passlessEditorName` has exactly one
production use, in `PieceReader`'s *nobody* arm, and
`TripwireGrepTests.test_thePasslessEditorNameHasExactlyOneProductionUse` keeps
it that way. A custom pass with no brief
of its own and no matching preset gets the honest fallback: attend at the
altitude the pass's name suggests.

**The dispositions section is the warm path's duplicate guard, and its two
halves are asymmetric on purpose** (`CompilerPrompt.dispositionsSection`,
`CompilerAnnotationDisposition.gather`, M4 P1 Task 4). It briefs the model on
what the writer has already done about this piece's compiler-authored notes,
split into two headed lists:

- **Standing** — notes still open, in the writer's queue as the round begins.
  **Uncapped and unsorted, by design**: truncating this half is what would
  mint duplicates, since a standing note left out of the budget is a finding
  the model has no way to know is already raised. Its order is
  `gather`'s own — the deriver's order, not a sort applied here.
- **Settled** — the writer's answer (accepted, rejected with a reason,
  stetted). **Capped at `settledDispositionLimit` (12)**, with the elided
  count spelled out ("…and N more the writer has already settled") rather
  than pretending the history is shorter than it is — settled notes
  accumulate for the life of the piece and would eventually dominate the
  prompt, while what is actually this section's job is telling the model
  about the writer's *live* queue. **Sorted by `resolvedAt` DESCENDING**, not
  by when the model originally raised the finding (`Document.annotations`'
  own order, `createdAt` descending) — a question raised in round 1 and
  answered this morning is the one the writer is still near, and under the
  cap it is the one worth the words; sorting on arrival order would brief the
  twelve most recently RAISED, which after a catch-up session is close to the
  twelve LEAST recently thought about. **Ties, and the undated, fall back to
  arrival order** (`gather`'s `enumerated()` index) rather than to nothing —
  `sorted(by:)` is not stable, and an unstable order here would reshuffle the
  briefing between two runs where nothing changed. A `.declined` note has no
  `resolvedAt` (a triage mark is not a resolution), so declines sort after
  every dated verdict.

**A standing fingerprint silences its settled twin.** The mint's own dedupe
stops it WRITING a second open note while one already stands. That is not a
guarantee that only one ever stands: a note settled, re-raised in another lane
and then reopened leaves two open under one fingerprint, which the cross-lane
paragraph below owns. And nothing stops an open note sharing a fingerprint
with a note settled earlier and since re-raised — briefing both would tell the
model to confirm a finding in one line and forget it two lines later. The
live note wins: `dispositionsSection` drops a settled entry whose
fingerprint is also standing. A note with no fingerprint (the anchorless
kind — a doc-scoped craft note, which has no discriminator to make one from)
is listed on its own rather than folded into anything, since a nil
fingerprint is the absence of identity, not an identity shared with anything
else — **and being fingerprintless it is neither deduped nor counted
cross-lane**: the dedupe branch it never enters is the same branch the
cross-lane count is taken in. **A sibling residual, same class:** a continuity
note's fingerprint leans on the model re-quoting `cites` byte-identically
(`RoundFingerprint`'s "clause quote" for that kind), so a re-punctuated quote
on a Fresh Eyes
reread — same question, one comma moved — can mint a duplicate the dedupe
can't see. Neither residual gets machinery; the writer disposes the
duplicate the way they dispose any other settled note.

**A refusal in ANOTHER lane is counted and said aloud** (#42 F-H). The mint
refuses a finding already open whichever pass raised it — one finding is one
note, and the lane it was first raised in does not make it two — but the
since-line's three counts are lane-local by construction
(`SinceLastRound.compute` filters on `reviewPassId == passId`), so a Line
round that re-raised a question standing in the Structural lane used to read
"0 resolved · 0 persisting · 0 new": a check that engaged the piece, reported
as one that found nothing in it. The mint now answers a
`CompilerOrchestrator.MintOutcome` — `minted` beside `openInOtherLanes`, the
count of DISTINCT findings the dedupe refused where **no lane holding them is
the round's own** (own-lane presence wins; the paragraph below is why that is a
set of lanes and not one) — and **three surfaces say it**:
`RoundNarrative.sinceLastRoundLine` appends "· 1 was already open in another
lane" / "· N were already open in other lanes"; `RoundNarrative.freshEyesHeader`
appends the same clause, because a cold read is one of the states the since-line
is silent in; and the Diagnostics pane's header and empty state say "Nothing new
to flag." rather than sealing over a round that raised something the writer is
holding out of sight. The wording lives in ONE place —
`RoundNarrative.openInOtherLanes(_:)`, which hands back the bare clause and the
pane's whole sentence together, so the three cannot drift about when one becomes
many — and it is deliberately **past** tense: the three counts beside it are
recomputed off the writer's live queue every time the line is drawn, while this
one is a snapshot taken at the mint and stored, so present tense would go false
the moment the writer settled the other lane's note. **The residual, since the
count is recorded whether or not anything draws it:** a passless run that also
raised a conformance strain draws a report rather than an empty state, so its
count is stored and shown nowhere. **A match in the round's
OWN lane is deliberately not counted**: that is the *persisting* case, already
on the line, and counting it twice would tell the writer one finding is two.
The number is produced at the one place fingerprints are already compared
(`CompilerEnvironment+Project`'s mint loop, whose `taken` set became a
fingerprint→**set of lanes** map for exactly this) rather than by a second scan
that could disagree with the mint about what it refused; it rides `CompilerRun`
additive-optional, so an older sidecar decodes to nil and the sentence is
byte-for-byte what it was.

**A set of lanes and not one lane, because ONE FINGERPRINT CAN BE HELD BY TWO
OPEN NOTES**, and the shape is reachable through nothing but the writer's own
verbs: only open notes block, so a Structural note that is rejected stops
blocking, a Line round re-raises the finding and mints a second note under the
same fingerprint, and Reopen on the first leaves both open in different lanes.
`reopenAnnotation` has no fingerprint-collision guard and should not grow one —
reopening is the writer taking a note back, not a claim about any other note.
A single-valued map keeps whichever of the two the annotation order happened to
leave last, so the round in the OTHER lane reads a foreign lane back and reports
its own persisting note as "was already open in another lane" — the same finding
counted twice in one sentence ("1 persisting · 1 was already open in another lane"),
which is the exact string the review fix's test produces when falsified.
**Own-lane presence wins**: cross-lane means NO note holding the fingerprint is
in this round's lane. And the count stays per FINDING, not per matched note —
two notes holding one fingerprint are one thing the writer is holding, which is
what the sentence says. **Scope, stated honestly: this counts NOTES.** The
mint only ever sees `SectionedOutcome.mintable` — continuity questions, reader
reports and, since the editorial letter, the letter's own questions — so a
conformance strain re-raised across lanes stays report-side and takes no part
in the number.

**Fresh Eyes briefs NO dispositions at all**
(`CompilerOrchestrator.beginRun`, the private continuation `runRequested`
hands off to after the burst-flush hop: `let dispositions = freshEyes ? [] :
environment.annotationContext(docId)`) — cold means cold, deliberately, so a
reread is not steered by what a warm round already said. That is what makes
the ingest-side fingerprint dedupe (`Environment.mintAnnotations`, described
above) the cold path's ONLY guard against re-minting an open finding: on a
warm round this section is the primary defence and the dedupe is a backstop;
on ⌘⇧R the dedupe is the whole of it.

## What this area owns

- The run: delta → prompt → session → parse → mint → store (`CompilerOrchestrator`) — the mint (M4 P1 Task 3) writes note-natured findings into the annotation layer between the parse and the sidecar write, and `finish` waits on it (see "The turn coming back" doc comment on `CompilerOrchestrator.finish`).
- The subprocess and its lifetime (`ClaudeCLISession`, behind `CompilerRunner`).
- What the compiler may reach (`CompilerAllowlist`).
- The diagnostics themselves: shape, per-device sidecar, staleness
  (`Diagnostic`, `DiagnosticsStore`, `DiagnosticIngest`).
- Where a note goes when the writer keeps it (`DiagnosticPromotion`) or answers
  it (`RulingPerformer.rule`, called by `DiagnosticsPane.commitAnswer`).
- **The one door into the writer-owned layer** (`RulingPerformer`) — count the
  verbs in the census rather than reading a number here; today they are rule,
  revoke, edit and `restore`, each taking the writer's words as a `String` or a
  `Ruling` those verbs produced, and never a reading. Spec §3.4's membrane;
  `RulingPerformerTests.test_nothingDerivedCanWriteItself` is its census.
  **Two destinations since the publish department's Task 6**: every verb takes
  a `kind: Statement.Kind` before its scope, undefaulted for the reason `world`
  is, so a ruling lands either in the piece's **intent** statement or in an
  **edition brief** (`editions/<lang>.md`) — one performer, two addresses,
  because both are the writer's own declared prose carrying a `## Rulings`
  stratum. Visual language still has none: nothing mints one for a kind no
  caller names. Every call site in the app passes `.intent` today; a default
  would be how an edition's decision landed in the book's intent in silence,
  and `RulingPerformerTests.test_everyVerbTakesTheDestinationKindExplicitly`
  is the census.
  **`restore` exists for ⌘Z alone**: the Intent pane's rows register the
  opposite verb on the window's `UndoManager`, and `rule` could not have served
  as revoke's inverse — it stamps today's date and appends at the end, so
  undoing the revocation of a March decision would hand it back re-dated. An
  undo that rewrites the record is worse than no undo.
- **The declared world** (spec §3.1/§3.4): Claude's disposable reading of a
  statement into checkable `DerivedClause`/`DerivedRule` values
  (`DeclaredWorld.swift`), the one-shot `claude -p` that produces one
  (`DeclaredWorldDeriver.swift`), and the per-device cache keyed on the exact
  source text's hash (`DeclaredWorldStore`, same file). Never truth, never
  drawn — see "The derivation trigger" below.
- **The bible** (spec §3.3): facts Claude reads off the manuscript while
  checking it, each carrying its establishing ¶ when one exists
  (`BibleFact`), and the per-device, project-scoped ledger of them
  (`BibleStore.swift`). Nothing here is truth either — the writer's three
  actions on a fact (bless / correct / dismiss, `Maugham/Views/BibleStratum.swift`)
  are what promote or discard a reading, never this store.
- **What a document is pinned to** (`PinnedReferences`, `PinnedReferenceResolver`)
  — the research the writer linked, the research their project type derives for
  the piece, and the cards they clustered on the canvas, grouped into a
  `PinnedShelf`: one pure function with two production callers, the run's own
  context and the Author surfaces below. Neither may re-derive it.

The pane is not here — `Maugham/Views/DiagnosticsPane.swift` — and neither is
the run key's delivery, `Maugham/Views/CompilerRunModifier.swift`, nor the
Author surfaces that read the pinned set (`Maugham/Views/IntentStrip.swift`,
`ReferencesPane.swift`, `AssistantColumn.swift`). All are across the seam on
purpose: this area holds no view state and no editor binding (tripwires 3, 6).

## The seam map

One run walks left to right. Each arrow is a value, never a shared object.

| File | What it is |
|---|---|
| `CompilerRunModifier.swift` (in Views) | The run keys' delivery path (⌘R's delta, ⌘⇧R's cold read), and three of the four ways the session dies |
| `CompilerOrchestrator.swift` | **The run.** Owned by `ProjectWindow`; one orchestrator per window, one session per orchestrator |
| `CompilerEnvironment+Project.swift` | The production wiring — the window's stores, as the closures the orchestrator runs on. Every capture is weak. `pinnedListing` carries the resolved `PinnedShelf`'s own grouping into the briefing through `pinnedListingLines`: one `pinnedListingLine` per pin, with a `## <title>` line ahead of each TITLED section and no header over an untitled one, so a run reads the same arrangement the References pane draws |
| `DeltaBuilder.swift` | What changed since the last run's marker, in the writer's order (`sequence`, never raw `paragraphs`) |
| `ScenePosition.swift` | What form the letter's scene table takes, derived app-side from the project type, the writer's whole intent statement and the pass brief (spec §3.4). Two closed phrase lists — the opt-out and the turn clause — and one rule about which wins. Its raw values reach disk through `Letter.scenePosition` |
| `CompilerPrompt.swift` | The message. Asks different questions of new and revised prose; v2 carries the essay + derived clauses + the bible slice + the delta, diffed in as ONE unit (`briefingHash`). M4 P1 and the editorial letter add per-run sections between the listings and the delta, and **none of them is folded into `briefingHash`** (each changes with the writer, not with what they declared) — count the appends in `runMessageV2`, not a number here: the active pass's **role frame + brief** (`passSection`, "You are Gould, this manuscript's copyeditor"), the **scene position** (`scenePositionSection`, the letter's own; see the scene-position paragraph above) and the **dispositions** section (`dispositionsSection`/`CompilerAnnotationDisposition.gather` — standing notes uncapped, settled notes capped at 12 and sorted by `resolvedAt` descending; see the dispositions paragraph above) |
| `CompilerAllowlist.swift` | The enumerated read-only MCP tool list, as `--allowedTools` |
| `CompilerRunner.swift` | The seam: `send(message:systemPreamble:) -> CompilerRunEvent`, plus every way a run can fail |
| `ClaudeCLISession.swift` | The warm subprocess behind that seam |
| `DiagnosticIngest.swift` | The structured message → notes, clause statuses, fact-candidates and the letter, anchored against the LIVE document. One section is one unit, so arrival can become incremental without the fold changing. `SectionedOutcome.sidecarDiagnostics` keeps conformance strains only; `.mintable` is the other half, built from the same accepted diagnostics rather than re-parsed. `parseLetter` is the sixth section and carries the two exemptions described above |
| `CompilerNote.swift` | **The value that crosses from parse to mint** (M4 P1 Task 3) — what `Environment.mintAnnotations` writes as a pass-stamped `Annotation`. Neither a `Diagnostic` (no run id, no staleness anchor, no sidecar identity) nor an `Annotation` (derived from ops, not caller-constructed); `CompilerMintContext` is what one mint needs off the run that produced it (lane, round, editor name, cold-or-warm), minted once at the keystroke and carried rather than re-asked at mint time |
| `DeclaredWorldDeriver.swift` | Also the one-shot's pipe discipline: stdout is drained WHILE the process runs. Reading it from `terminationHandler` deadlocked on any answer past ~64 KB — the child blocks on its own write, so it never exits, so the handler never fires. **120s deadline** (Stage 3), four times the spike's measured 30s sonnet cost: an overrunning process is `terminate()`d and the derivation returns its ordinary honest `nil` — ordinarily through the SAME EOF-and-exit resolution every other unreadable answer already goes through, and by force (`OneShotOutput.deadlineExpired`, after a 2s `terminationGrace`) when a group member escapes the group SIGTERM and withholds EOF by holding the inherited pipe: CI run 31595012981 hit exactly that (the killpg/fork race), and a real CLI grandchild that setsids has the same shape. Both doors are the deadline's own; `derive` never hangs on a stranger's file descriptor |
| `Diagnostic.swift` | `Diagnostic` + `CompilerRun` — the wire and sidecar shapes |
| `DiagnosticsStore.swift` | The per-device, per-document sidecar, and the staleness rule |
| `RoundHistory.swift` | `RoundFingerprint` (the one join-key for round-over-round identity — section + clause quote + anchor + the reader's category, never prose; its `stringValue` is the mint's dedupe key, a persisted synced format) + `RoundRecord` (that a round finished: its lane, its number and **when** — `fingerprints` is legacy and written empty since M4 P1 Task 5) + `SinceLastRound` (the pure resolved/persisting/new count, taken off the writer's QUEUE, on `DriftDetector`'s mould — no store, no I/O) |
| `DiagnosticPromotion.swift` | What a kept note says once it is an op-logged task |
| `RulingPerformer.swift` | rule / revoke / edit / restore — the only writes into a statement's `## Rulings` stratum |
| `StatementEssay.swift` | Where the essay ends and the strata begin — the byte-exact split the Intent pane's editor binds through |
| `DeclaredWorld.swift` | `DerivedClause`/`DerivedRule`/`DerivedWorld` (the reading) + `DeclaredWorldStore` (its per-device, hash-gated cache) |
| `DeclaredWorldDeriver.swift` | `ClaudeWorldDeriver` — the one-shot, no-MCP `claude -p` that turns a statement's prose into a `DerivedWorld` |
| `BibleStore.swift` | `BibleFact` (a reading with its establishing ¶) + `BibleStore` (per-device, project-scoped ledger) |
| `PinnedReferences.swift` | The pure projection: linked research + the research the project type derives + clustered canvas cards, resolved to renderable pins and grouped into a `PinnedShelf` — one untitled run of research, a titled section per bound region (a promoted region contributing the note it became), then `Cards` |
| `PinnedReferenceResolver.swift` | The caller-side assembly against a live project — the five inputs `PinnedReferences.pinned` takes, gathered in one place |

**A run's first act is to close the writer's burst, and only then read.**
`Environment.prepareForRun` is awaited at the top of `runRequested`, before
`reading` is asked for anything — because freshly typed prose lives in the
`PendingBuffer` until a pause closes the burst, so a snapshot taken at the
keystroke is a document that predates the ⌘R asking about it. Smoke-found and
measured: a 14-paragraph chunk reported as "0 new, 1 revised", the burst
closing two seconds after the delta was built. ⌘S's checkpoint path does the
same thing for the same reason (`ProjectWindow`), and this is the one place in
the area that is not a pure read of a value. It cannot throw: the pending
buffer survives a failed append intact, so a flush that fails costs this run
its newest paragraphs and costs the writer's words nothing — the run proceeds
on the snapshot as it stands rather than refusing. The hop it introduces is
covered by `isRunning` (so a double ⌘R is still one run) and abandoned by
`shutdown()` by generation, so a run acknowledged a moment before the AI toggle
went off does not spawn the session that toggle was meant to prevent.

**The `Environment` struct is the reason this area is testable.** The
orchestrator names no store: it takes closures, so a run is driven end to end
with no project on disk. A factory that reached for `ProjectStore` from inside
`CompilerOrchestrator.swift` would quietly re-couple the two — which is why
the production wiring is a peer file.

## The session's lifetime — the rules, and who enforces each

Spec §3.4, verbatim, with the enforcing site beside it:

| Rule | Enforced by |
|---|---|
| Entering Author never starts it; only the first run does | `CompilerOrchestrator.ensureRunner`, called from `runRequested` and nowhere else |
| It dies on the AI toggle going off | `CompilerRunModifier`'s `.onChange(of: mcpEnabled)` — **and** `ClaudeCLISession` re-reads the toggle before every spawn, so a session already warm cannot answer one more run |
| It dies on app quit | `CompilerRunModifier`'s `.maughamAppWillTerminate` |
| It dies on window/project close | `ProjectWindow`'s own `.onDisappear` → `detach()`, because that path must also drop the orchestrator's hold on the window's stores |
| It dies quietly after ~10 min idle | `ClaudeCLISession.idleTimeout` (600 s; the per-turn budget is `ClaudeCLISession.defaultRunTimeout` — **300 s since 2026-08-18**, raised from 120 by Denver's ruling after two whole-piece first rounds died at the old one, read the number off the constant) |
| Death mid-run fails that run once; the next keystroke starts fresh | `CompilerOrchestrator.finish`'s `.failed` arm — the marker and the intent hash are both left where they were |
| **It dies on ⌘⇧R, and is replaced in the same act** | `CompilerOrchestrator.beginRun`'s `if freshEyes { retireSession() }` — the one teardown that is a *run* rather than an ending, so it is the orchestrator's rather than a fourth arm of `CompilerRunModifier`. Placed below the in-flight refusal, the generation check and the empty-delta guard: a fresh-eyes press that is refused or abandoned must not cost the writer their warm session |

**The shutdown contract is the sharp edge of this area, and the type cannot
defend itself.** `ClaudeCLISession.deinit` is nonisolated and cannot touch
main-actor state, and deallocating a `Process` neither signals nor reaps its
child — so a session merely *released* leaves a live, billing, API-calling
`claude` running for as long as it survives its closed stdin. Every teardown
path has to reach `shutdown()` explicitly. If you add a fifth way for a window
or persona to go away, it owns a call.

`shutdown()` and `detach()` are not interchangeable: `shutdown()` ends the
session and leaves the orchestrator usable, because a writer who turns Claude
off and on again must still have a working ⌘R; `detach()` additionally drops
the environment and the store references.

**Generations, not booleans.** Every teardown bumps `ClaudeCLISession`'s
`generation`, and a callback from a retired process carries the generation it
was installed with. Without it, a kill-and-respawn lets the dead process's EOF
resolve the new run's continuation — the shape tripwire 2 warns about
(flag-based loop guards leak) arriving in a subprocess.

**The death verdict is a JOIN of two independent deliveries.** stdout's EOF
(the anchor — every byte read) and the process's exit (the status, and the
proof the stderr drain cannot block) must both arrive, bounded by
`defaultDeathReapGrace` (2s, injectable), with timeout falling back to the
honest "the CLI closed its output". Either event can precede the other: EOF
leads a clean close, but an inherited pipe held by a spawned grandchild
outlives SIGTERM, so the process exits first and `waitpid` proves it is gone.
Before this join, an EOF-only verdict collapsed the writer's diagnostic to a
sentence with no body and no essence (issue #36). The generation guard is what
makes the wait safe: a verdict returned to a retired generation is ignored, so
a send inside the grace spawns fresh rather than reusing the process that is
dying.

## The `--resume` fallback — pre-authorized, and NOT built

Spec §3.4 pre-authorizes a swap: if the warm process proves brittle in the
field, per-run `claude -p --resume <session-id>` gives the same context-reuse
semantics with simpler process management. **It is not implemented** — nothing
in this directory passes `--resume`, and `ClaudeCLISession.arguments` is the one
place to check rather than this sentence.

What makes it a swap rather than a rewrite is the `CompilerRunner` seam: the
orchestrator holds a protocol, mints its runner through
`Environment.makeRunner`, and reads only `send(...)` and `sessionEpoch`. A
`--resume` runner is a second conformer plus one line in
`CompilerEnvironment+Project`. Note what would have to move with it:
`sessionEpoch` is what lets an unchanged intent be elided from a message
(`CompilerOrchestrator.previousHash`), so a per-run process must still answer
"is this the same context that read the intent last time" — for `--resume` that
is the resumed session id, not the process.

## The translator — the area's second orchestrator

Publish department P2 (2026-08-20) gave this area a second run, for a
different job: not reading the manuscript and reporting on it, but producing
words the writer will publish. `TranslatorOrchestrator.swift` /
`TranslatorBriefing.swift` / `TranslatorReport.swift` /
`TranslatorEnvironment+Project.swift` are its files, alongside the compiler's
rather than in a directory of their own — the design is explicitly "every
piece follows a verified precedent" from this area's own machinery, and
splitting it out would have made that harder to see, not easier.

**The rails are `CompilerOrchestrator`'s, reused rather than re-derived.**
Same closure-`Environment` shape (a run drives end to end with no project on
disk, `TranslatorEnvironmentTests` proves it the way `CompilerOrchestrator`'s
own tests do), the same warm-session-with-lazy-spawn shape over
`CompilerRunner`/`ClaudeCLISession`, the same generation discipline across
every suspension (a teardown between the click and the send *abandons* the
run rather than letting it spawn a session the writer has just closed the
window on — `TranslatorOrchestrator.runGeneration`, `ClaudeCLISession
.generation`'s own reasoning in a second currency), and the same vocabulary
for what a run can be (`RunState`, deliberately shaped like `CompilerOrchestrator
.RunState` with `nothingToTranslate` playing `nothingNew`'s part). What
differs is what a run is FOR, and two things follow from that:

- **Warm per `(docId, language)`, not per window.** A compiler session reads
  many documents and re-briefs each under a hash that says what it has
  already been told; a translator session holds one edition's voice in its
  context with no such discipline, so crossing documents or languages inside
  one process would carry another edition's register into a round that never
  asked for it. `TranslatorOrchestrator.ensureRunner` retires the session on
  a pair change exactly as it does on a model change.
- **A failure writes nothing at all, and atomicity is structural rather than
  careful.** `Environment.ingest` is reachable from exactly one place in
  `TranslatorOrchestrator.finish` — the arm holding a `TranslatorReport` a
  successful parse produced — so a session that died, timed out, was
  cancelled or answered gibberish has no path to the writer's words
  (`TranslatorOrchestratorTests.test_aFailedRunIngestsNothing`). The
  compiler's own version of this rule is the "compiler reads and never
  writes" sentence at the top of this file; the translator's is the same
  shape wearing the fact that it DOES write, just never from inside the
  spawned session.

**The report is one JSON object, not a sectioned stream.** `DiagnosticIngest`
reads six line-delimited sections because six different kinds of answer
can arrive independently; a translator turn answers one question — "here is
this round's work" — so `TranslatorReport.parse` reads a single fenced
object naming `entries` (a `¶id` plus exactly one of `text` or
`verbatim: true`) and `queries` (a question, optionally paragraph-scoped).
**All-or-nothing starts at parse, not at ingest**: an entry supplying both
forms or neither is a model that has lost the contract, and there is no way
to know which of its OTHER entries to trust either, so the whole report is
refused rather than salvaged around the bad entry — the compiler's
per-section tolerance does not carry over. **An empty `text` counts as
neither form** (P2's final wave): entry text and query text both run through
`nonEmptyString`, the discipline the paragraph id always had, so `"text": ""`
reads as absent and lands in that same refusal. Taken at face value it would
have blanked the paragraph in the published edition through a path that never
touches the manuscript, and the record would have carried the CURRENT
source's hash — reading fresh, so no later derivation would ever raise it.
Text is stored trimmed, deliberately: whitespace around an answer is an
artifact of how the model wrote its JSON, not of the prose. **`delete` is deliberately absent
from this contract**: a translation disappearing is the writer's own act (or
an orphan-purge outside any run), never something a run decides on its own.

**The briefing is a pure function, `CompilerPrompt`'s own discipline.**
`TranslatorBriefing.compose(inputs:)` takes no I/O, no clock, no store lookup
— `TranslatorOrchestrator` is the one production caller and owns gathering
`Inputs` from the store, the deriver and the annotation layer; the briefing
type does not know any of those exist. Section order: role frame ("You are
Cortázar, translating this manuscript into es" plus the role's own `brief`
when the writer or a preset has set one — no briefless fallback sentence,
because an unbriefed translator genuinely has no doctrine of their own),
declared intent, the edition brief (embedded whole, `## Rulings` included,
with an explicit instruction to honor a standing ruling exactly as it reads
rather than treat it as a suggestion), **the established facts about this
round's people** (`BibleStore.slice(matching:)` over the work-list's prose —
the same ledger and the same subject-occurrence rule the compiler slices its
delta with, extracted onto the store in P2's final wave so the two runs
cannot disagree about which facts a run is entitled to; the heading says what
a TRANSLATOR does with a fact, which is not what the compiler does with the
same list: honor it in grammatical choices the source language never had to
make — a doctor's gender is `la doctora` or an edition-wide error — and raise
a query rather than pick a side where a fact and the source disagree; an
empty ledger composes as silence, not as an announced absence), this round's
work-list (`TranslationDeriver`'s
stale-and-missing set — **no rounds ring**, freshness IS the memory, so an
empty work-list is `nothingToTranslate` and spends no session at all, the
compiler's empty-delta mistake avoided in a second currency), neighbour
context (the paragraph immediately before/after a work item, deduped against
the work-list itself, for continuity only), queries (open ones uncapped and
never re-asked, answered ones capped at `answeredQueryLimit` (12) and sorted
most-recently-settled-first — `CompilerPrompt.settledDispositionLimit`'s
asymmetry, borrowed shape rather than shared constant), and last,
`TranslatorReport.schemaDescription` — the output-shape instruction, always
last, `CompilerPrompt`'s own ordering rule.

**Ingest writes through the writer's own doors, and through exactly one of
each.** `TranslatorEnvironment+Project.swift` is `CompilerEnvironment
+Project.swift`'s peer in every respect that matters — a `production(...)`
factory building `TranslatorOrchestrator.Environment` from one window's
stores, **every capture weak**, because SwiftUI never dismantles a closed
window's view graph and an orchestrator holding a `ProjectStore` strongly
would keep the whole project in memory with nothing on screen. What the
closures do is different from the compiler's, because this loop writes:

- **The words** go through `TranslationWritePipeline.perform` (`Maugham/MCP
  /Tools/TranslationWritePipeline.swift`) — the SAME door `write_translation`
  uses (see `Maugham/MCP/AREA.md`'s `write_translation` entry), so the tool
  and the ingest path cannot drift about which batches are legal or which
  source hash is trustworthy. It re-validates every `¶id` against the state
  resolved at ingest time, never against the sequence the round was briefed
  on, so a paragraph the writer deleted mid-round rejects the whole batch
  loudly, naming the ids — the words are still there to be re-run. **And a
  paragraph the writer EDITED mid-round rejects the same way** (P2's final
  wave), which the pipeline cannot see for itself: the id still resolves and
  every one of its checks passes, so the record would be appended carrying
  `TranslationHash.hash(CURRENT source)` against a translation of text the
  model was never shown — an entry that reads fresh forever and is silently
  wrong. The round therefore carries what it was BRIEFED with: `briefRound`
  answers a `BriefedRound` (the pure `Inputs` plus a paragraphId→hash map read
  off the RAW source, the same string the pipeline stamps from — not the
  anchor-stripped display text, or the comparison would be between two
  normalizations and fire on nothing), and `IngestContext.briefedSourceHashes`
  carries it to `midRunEdits`, the one place it can be spent. Undefaulted on
  the initializer, so a new call site cannot arrive at an unguarded run
  quietly. Compared BEFORE the pipeline call, which is also what makes a
  rejection mint no queries.
- **The questions** go through `Document.addAnnotation`, signed with the
  translator's own name (`AnnotationAuthor(sourceKind: .claude, displayName:
  translatorName)`) and language-tagged via `toolArgs`, so a query is a note
  the writer disposes of in the queue exactly like any other. A query whose
  paragraph anchor vanished mid-run, or one that asks about the whole
  document, mints doc-scoped as a `.craftNote` rather than being dropped —
  `Document.addAnnotation` refuses a `.query` with no anchor, the same call
  `CompilerNote`'s own anchorless arm makes. **That note is re-briefed and
  counted like any other question** (P2's final wave): `AnnotationDeriver`
  projects the translation language tag for `.craftNote` as well as `.query`,
  off the same `toolArgs` the mint writes, and both readers widened the same
  one way — the briefing's query-history gather here and
  `translation_status.open_queries`. While the tag stopped at `.query`, "tú or
  usted throughout?" — the question a translator is most likely to ask and
  least able to guess at — was invisible to every later round, so a fresh
  session asked it again forever with the writer's answer sitting unread in
  the queue. The tag is the discriminator, not the kind: `add_craft_note`'s
  Params carry no `language` and the compiler's mint writes no `toolArgs` at
  all, so an ordinary craft note stays untagged. The body keeps its
  `Translation query (<lang>) — ` prefix as well, because a craft note wears
  no language chip in the queue. **A rejected word batch mints no
  queries either**: the order in `TranslatorEnvironment+Project.ingest` is
  words first, and a pipeline refusal ends the ingest there, because a
  translator query has no fingerprint to dedupe on the way the compiler's
  notes do — minting the questions of a round the writer will simply run
  again would double-ask every one of them.
- **The translator** is `ProjectStore.translatorRole(for:)`, find-or-create —
  this loop is that verb's first production caller, and a run is the write
  act that makes the mint legitimate (`ProjectStore+ProductionRoles`'s own
  rule: read paths never mint a role). **The identity is resolved before the
  briefing, and that order is load-bearing**: the briefing's role frame reads
  the stored row back rather than resolving a name of its own, so the first
  run for a language does not brief a translator who does not exist yet
  while the queries it produces are signed by one who does.

**The confined session can read what it is briefed on, not only trust it.**
`CompilerAllowlist.tools` gained `mcp__maugham__read_edition_brief` (publish
department P2 Task 6): the briefing already embeds the edition brief's text
verbatim, but the translator is also a compiler-rails spawned session with
its own MCP bridge, and it should be able to read its own doctrine through
that bridge the same way it reads craft intent — through the enumerated
read-only allowlist, not only what one briefing happened to carry.
`CompilerAllowlistTests.test_theCompilerCanReachItsDeclaredContext`'s pinned
minimum-required set names it alongside `read_craft_intent` and
`read_visual_language`; the no-write census and its planted offenders are
untouched, because a read joining the allowlist is not the shape either
census exists to catch.

**The shutdown contract gained a second owner, and every teardown arm now
carries a paired call.** `TranslatorOrchestrator` inherits `ClaudeCLISession`'s
contract whole — `deinit` is nonisolated and cannot touch main-actor state,
and deallocating a `Process` neither signals nor reaps its child, so an
orchestrator merely released leaves a real, billing, API-calling `claude`
running for as long as it survives its closed stdin. `CompilerRunModifier`'s
own doc comment now says it plainly: "there are TWO session owners now."
Every arm that used to call `orchestrator.shutdown()` alone now calls
`translator.shutdown()` beside it — the `.maughamAppWillTerminate` handler
and the `mcpEnabled` toggle's `.onChange` — and `ProjectWindow`'s own
`.onDisappear` calls `translator.detach()` beside `compiler.detach()` before
dropping the window's stores. `TranslatorEnvironmentTests`' teardown census
pairs the two COUNTS (`orchestrator.shutdown()` occurrences ==
`translator.shutdown()` occurrences) rather than asserting a fixed number, so
a third compiler-shaped teardown arm cannot land without its translator
sibling — the same shape tripwire 32's census takes for the canvas undo
bracket. The translator has no run keys of its own (⌘R and ⌘⇧R are still the
compiler's alone) and no fourth teardown arm: entering a persona never starts
it, and nothing here reaches for itself.

**The loop shipped headless through P2 and P3; P4 (2026-08-20) wired the
click.** `TranslatorOrchestrator.runTranslation` had no caller in production
through P3 — proven by the environment wiring's own test suite and by the
teardown census, not by a keystroke. The spec's trigger, "a 'Run translation'
act per language, from the department desk"
(`docs/superpowers/specs/2026-08-19-publish-department-design.md` §2, §5), is
now `DepartmentPaneHost.run(language:)` (`Maugham/Views/Publish/`) — the
department desk's per-language Run, ⌘⌥K — which pre-flights against
`TranslationWritePipeline.validate` (the SAME gate the briefing itself calls,
so the desk was not widened to answer a question it can already ask) and then
calls this orchestrator. **Global Constraint 1 survives structurally, not by
a new refusal**: Run resolves against the OPEN document only
(`DepartmentRunTarget.resolve`), because `currentParagraphState` — the read
the briefing gather already goes through — answers an open document straight
off the registry and has no way to refuse one; the desk's own test names that
closure `test_theBriefingAbandonIsClosedByTheOpenDocumentGate` rather than
asserting it as a comment, so a future change to that registry read would
turn it red first. Only one translation round runs at a time, across every
language — one warm `TranslatorOrchestrator` session, `DepartmentRunSession
.busy` naming the edition already holding it. An unlisted language's first
Run opens the cast sheet (`DepartmentCastSheet.swift`, **Name & Run**) rather
than silently minting a translator with no chosen name. That sheet asks the
same question at three moments as of cast-management (2026-08-21) — name the
translator a Run is waiting on, **Add Language…**, and **Rename …** on any
row of the desk — so one composition (`translatorRole(for:)` +
`renameProductionRole`) is the only way anybody on this book is named.

## The designer — the area's third orchestrator

Publish department P3 (2026-08-20) gave this area a third run, for a third
job: not reporting on the manuscript and not translating it, but proposing
the BYTES the book is typeset from — a spec plus template/style/partial
files — and a compiled spread of sample pages so the writer can judge the
proposal without reading LaTeX. `ElementCensus.swift`, `SamplePageSelection
.swift` and `SampleCompiler.swift` live in `Maugham/Publish/` rather than
here (there is no `Maugham/Publish/AREA.md` — this section is where all four
of the designer's files are documented, wherever they physically sit);
`DesignerReport.swift`, `DesignerBriefing.swift`, `DesignerOrchestrator.swift`
and `DesignerEnvironment+Project.swift` are peers of the compiler's and the
translator's own files, same reasoning as the translator section above.
`ProposalPromotion.swift` is also in `Maugham/Publish/` — the one thing in
this whole loop that writes the LIVE publish tree, and its own file rather
than a `DesignerOrchestrator` verb because approval and revert are things the
writer does to a STAGED proposal, reachable independently of any run.

**The rails are `CompilerOrchestrator`'s and `TranslatorOrchestrator`'s, a
third conformer over the same shape.** Same closure-`Environment` discipline
(a run drives end to end with no project on disk —
`DesignerOrchestratorTests`/`DesignerEnvironmentTests` prove it the way the
other two orchestrators' suites do), the same warm-session-with-lazy-spawn
shape over `CompilerRunner`/`ClaudeCLISession`, the same generation discipline
across every suspension, and the same `RunState` vocabulary shape
(`.idle`/`.running(round:language:)`/`.failed(failure:at:)`). What differs,
same as the translator, is what a run is FOR — and here that difference cuts
deeper than the translator's did:

- **Warm per PROJECT, not per document-and-language.** A design proposal is
  never about one document; it is about the whole book's typesetting, so
  there is nothing narrower to key a session on than the project itself. This
  is also why `requestChanges` (a follow-up send on the SAME warm session,
  the gate's "iterate" arm) is safe here in a way it could not be for a
  process keyed more narrowly: the session that made round N's proposal is
  the only process that can sensibly be asked to revise it, and nothing about
  a design round narrows further than "the book" the way a translator's
  register narrows to one edition. Retired only by a model change or
  `shutdown()`.
- **A round stays OPEN after it ends**, the same shape the translator never
  needed and the compiler doesn't have — `hasOpenProposalRound` answers
  whether `requestChanges` has anywhere to land. It closes three ways, all in
  `DesignerOrchestrator`'s own doc comment: a fresh `runDesign` send (closed
  unconditionally, before the answer is known — a second `runDesign` that
  comes back unparseable must not leave `requestChanges` talking to the
  session about the FIRST proposal, the fix round 1 finding), `retireSession`,
  and the epoch moving under it (`sessionEpoch`, `ClaudeCLISession`'s own
  silent-respawn guard — a `requestChanges` sent to a respawned process would
  be asking a process that never saw the proposal to revise it).
- **`stage` does two things behind one closure, and both are awaited.** A
  parsed `DesignerReport` becomes a `DesignProposalStore.Proposal`
  (`Maugham/Stores/DesignProposalStore.swift`, staging) **and** a compiled
  sample (`SampleCompiler`, `Maugham/Publish/`), handed back together as one
  `StageOutcome`. A disk refusal during staging is `StageOutcome.rejection`
  and ends the run as `.failed(.stagingRejected(_))`; a tectonic failure
  during the sample is `StageOutcome.sample = .failed(...)` and ends the run
  **clean** — spec §6's rule, that a sample compile failing is advisory
  information ON the proposal, never a reason to fail the round that made it.
- **No `nothingToTranslate` analogue.** There is always a book to design, so a
  round that starts always has something to propose; success returns to
  `.idle` and the pending-proposal badge P4's desk will show is the store's
  own state, not the orchestrator's.

**The census is recomputed at staging, never carried from the briefing.** A
whole model turn separates `briefRound` from `stage`, and the writer keeps
writing through it — `SamplePageSelection.choose` is re-run against a fresh
`ProjectStoreASTSource` build at staging time, against the book as it stands
NOW, so a page selection computed against the older AST never demonstrates
text that has since moved. Both derivations are pure over the same source, so
an unchanged book still answers identically.

**One AST, one edition — a language round samples in that language, against
base templates.** The census, the selection and the sample all come from
`ProjectStoreASTSource` at the round's own `language`, so a Spanish round's
sample pages carry Spanish prose (`SamplePageSelection`'s own text, not a
translated afterthought) with the ordinary per-paragraph stale-source
fallback a preview that mutates nothing is allowed to make. **What does NOT
follow the language is the TEMPLATE**: `SampleCompiler` takes no `language:`
parameter, so `LanguageSuffixedFile` resolution never runs and a proposal
staging `template.es.tex` is sampled through the base `template.tex` — the
prose is the edition's, the typesetting is not. **P4's gate says so rather
than fixing it**: the caveat sentence and `Proposal.language` are plumbed
through to the gate view (`Maugham/Views/AREA.md`'s "The department desk"),
but `SampleCompiler`'s signature was deliberately not widened — Denver's
ruling keeps a design round scoped to the whole book (`runDesign(language:
nil)`, no per-edition picker on the desk), so no proposal a writer can create
today actually carries a language, and the caveat arm is real but
unreachable from the shipping UI until a per-edition design round exists.

**`config.json` is refused twice, at two different layers, for two different
reasons.** `DesignerReport.parse` (parse time) refuses it so a hand-crafted
report can never propose rewriting what "the trim" or "the format" mean — the
one file this whole loop is structurally forbidden to touch. Everything else
that touches config only READS it: `DesignerBriefing` embeds a *summary* of
the trim/format facts a design needs (never the whole JSON), and
`SampleCompiler` constructs its own `PublishConfigStore(projectURL: scratch)`
rather than accepting a caller-supplied store, precisely because a
caller-supplied store could only ever be pointed at the live directory — the
one thing a sample compile exists to avoid reading. **`EMISSION.md` is the
one honest gap in that discipline**: it is briefed to the designer as an
ordinary template file (genuinely the most useful file in the tree for
understanding what a LaTeX template must satisfy) even though it is
GENERATED, from `EmissionContract.swift` — and nothing at parse time stops a
proposal from rewriting it. Harm is small and self-healing today (the test
suite regenerates it, so a stale proposal only costs a confusing diff), but
if a future promotion-side refusal is wanted, that is a parse-time guard on
`DesignerReport`, not a briefing-time one.

**`ProposalPromotion` reads the live tree and never writes it except on the
writer's own three verbs — `SampleCompiler`'s mirror image.** `approve`
refuses while a compile is running, refuses with no live `.maugham/publish`
tree, and (the guard the brief did not name, added because a retry needs it)
refuses over a STANDING backup — without that third guard a second `approve`
(a retry after a mid-write failure, or a double-click on whatever P4's button
turns out to be) would rebuild the backup from the tree its own first attempt
just promoted, capturing the proposal's own bytes as "the originals" and
destroying the only way back to what the writer actually had. **That third
guard is project-wide, not per-proposal** (`proposalHoldingTheBackupSlot`,
widened in P3's final review): there is ONE set of original templates, so
there is one backup slot, and layering two promotions loses those originals
just as surely by a longer route — approve(A) → approve(B) makes B's backup a
copy of A's promoted bytes, so revert(A) → revert(B) walks the tree back to
A's design and stops there, with every step reporting success and the
writer's own templates in no file, no backup and no proposal. The refusal
names who holds the slot and both ways out. Order inside
`approve`: resolve every staged path to completion first (an escape check
behind `DesignerReport`'s own parse-time guard, defence in depth — a
`proposal.json` is a file on disk and a hand-edited one is the one path by
which a staged file could still name `../../../../publish/…`); back up every
live file a staged path replaces, whole, before any live write; write; mark
`approved` LAST, so a proposal is never `approved` over a promotion that did
not finish. `revert` reads the BACKUP MANIFEST, not the proposal's status —
which is what makes it double as the recovery path for a promotion that died
halfway, not only the writer's "take this back": it restores every replaced
file byte-for-byte, deletes every file the proposal introduced (pruning only
the directories the round itself created, never one holding anything else),
marks the proposal `rejected` with a note, then discards the spent backup.
**This is a stored reversal the writer asks for by name, never an
`NSUndoManager` registration** — the ruling stated on `ProposalPromotion`'s
own doc comment, because a ⌘Z aimed at a sentence must never, at any depth of
an undo stack it happens to share, un-ship a book's templates. `approve` does
not gate on the proposal's own status beyond those three guards — a
`superseded` proposal can still be promoted, which reads as legitimate ("the
writer preferred round 2 to round 3") but is a product call a later milestone
may want to narrow.

**`finalize` is the third verb and the other way out of the slot**: accept
this promotion permanently — discard its backup, keep its `approved` status,
free the slot for the next round. It is deliberately separate from `approve`
rather than something `approve` does for itself when it wants the slot, because
it is the destructive half: after it, the templates that round replaced exist
nowhere, and that must be a thing the writer asks for by name rather than a
side effect of clicking "approve" on a later round. It refuses with no backup
to discard, and refuses over a proposal that is not `approved` — a backup
standing over a `pending` proposal is the signature of a promotion that died
mid-write, and its backup is the only way out of the half-swapped tree, so
the answer there is `revert`. It reads the STORE's status rather than the
caller's copy (`approve` marks `approved` last, so a caller holding the value
it passed in still reads `.pending`), and it is NOT gated on a running
compile: it removes a directory under `.maugham/design/` and moves no live
byte. `DesignProposalStore.delete(id:)` guards the same window from the other
side — see `Maugham/Stores/AREA.md`.

**The loop shipped headless through P3; P4 (2026-08-20) wired every verb.**
`DesignerOrchestrator.runDesign`/`.requestChanges` and
`ProposalPromotion.approve`/`.revert`/`.finalize` had no caller in production
through P3 — proven by `DesignerEnvironmentTests` and by the teardown census,
not by a keystroke. All five are now reachable: `runDesign`/`requestChanges`
from `DepartmentPaneHost` (the Design row's Run and its direction field,
`runDesign(direction:language:)` called with `language: nil` always — no
picker, no per-edition round, Denver's ruling spelled once at that call
site), and `approve`/`revert`/`finalize` from `DesignGatePromotion.perform`
(`Maugham/Views/Publish/DesignGateVerbs.swift`) behind the gate's own four
verb buttons — see `Maugham/Views/AREA.md`'s "The department desk" for the
surface. **The verb's result is written back into the caller's proposal, not
carried from the request**: `approve` marks the store `approved` as its LAST
step, so `DesignGatePromotion` re-reads the proposal after every verb and
hands the CALLER that, never the value it was given — `onProposalChanged`
then rewrites the window's `publishSelectedProposal`, which is what makes the
footer that drew Approve draw Revert/Finalize on the very next frame with no
stale snapshot in between. A successful verb also posts
`.maughamDesignProposalsChanged` (ADR 0021, no payload) so the OTHER column —
the desk, whose `ReloadKey` watches only the designer's RUN state and would
not otherwise notice a promotion — re-derives too; a refused verb posts
nothing, because nothing on disk moved. `ProjectWindow.designRunRecord(_:)` —
`static`, pure, built in P3 ahead of having anywhere to render it — is now
that render site, the log line beside the desk's row. **Every window-ending
path owes `designer
.shutdown()`/`.detach()` beside the compiler's and the translator's** — three
session owners now, `CompilerRunModifier`'s teardown arms and `ProjectWindow`
's `.onDisappear` each carrying all three, weak captures throughout so a
closure cannot keep a closed window's stores alive.

**Where a proposal lives, for the reader who only wants the filesystem
answer.** `.maugham/design/proposals/<proposalId>/` holds `spec.md`, `files/
<relative path>` per proposed file, `proposal.json` (id, designer name,
round, created stamp, status, the recorded sample outcome), and — once a
sample has compiled — `scratch/`, the assembled copy-plus-overlay the compile
ran against, kept under the proposal's own folder rather than a temp dir so
the pages outlive the session that made them and a promotion's own backup
lands at `backup/` beside it. Every byte under `.maugham/design/` is derived
and safely deletable — `DesignProposalStore`'s own contract test proves
deleting the whole directory costs nothing else on disk — and a `stage` call
supersedes every still-`pending` proposal project-wide rather than by
language or by document, because the spec gives Design exactly one desk row
and one pending-proposal badge per project, never one per language the way
the translator's rows are. See `Maugham/Stores/AREA.md`'s own
`DesignProposalStore` entry for the store's shape.

## Tripwires this area sits on

- **17 / 24 — the sidecar.** `.maugham/diagnostics/<docId>.<slug>.json` is
  per-`(document, device)`: two Macs running the compiler against one document
  must not race each other's file. `DeviceSlug.raw` is interpolated in
  `DiagnosticsStore.sidecarURL` and in `DiagnosticsStore.refusedColdStartURL`
  — the cold-start offer's refusal memory, `.maugham/diagnostics/
  cold-start-refused.<slug>.json`, ONE small per-device file for the whole
  project rather than per-document (a refusal is a single bit with no run
  beside it, and can be recorded before a document has ever been run at all,
  before its own `FileContent` exists) — and nowhere else in this file: the
  slug lives only in filenames and is never serialised into content. Two more
  per-device sidecars joined Stage 2, both on the same discipline:
  `.maugham/derived/<scopeKey>.<slug>.json` (`DeclaredWorldStore.sidecarURL`,
  one per statement scope) and `.maugham/bible.<slug>.json`
  (`BibleStore.sidecarURL`, one per project). `.raw` is interpolated only at
  each of those two call sites.
- **The round ring is the DOCUMENT's, not any one pass's.** `FileContent.rounds`
  is one array per `docId`, capped at `roundHistoryDepth` (5) — every pass
  files into the same ring. The document actually remembers six finished
  checks — the ring plus the standing run, which is filed into the ring only
  when superseded — so a Structural round is pushed out once six later checks
  (in any lane) stack up behind it. It is written
  only by `replace`, and only for the run being SUPERSEDED — `RoundRecord(run:)`
  is built from `finishedContent(docId:)`, which reads the
  in-memory `byDoc` entry directly except while a preview is standing in for
  it, when it reads the shadow `finishedBeforePreview` captured the moment the
  preview began (keyed on the `previewing` Set, never on the shadow's
  nil-ness — a cold document's first preview captures nothing, and a `??`
  fallthrough there would read the run's own half-report as the previous
  round). `latestRound(forPass:docId:)` reads `byDoc` directly, never that
  shadow (R1, #42) — its two readers are `beginRun`'s round mint, reached only
  when `runRequested` finds `!isRunning`, and the Review cockpit strip
  (`AnnotationsPane.cockpitRound`), both of which need "which round is this
  lane on, the one in flight included" rather than the round before it —
  `sinceLastRoundLine` (`RoundNarrative.swift`) never calls it; it reads the
  run's own `round` and the ring directly. It checks the standing
  run first (newest of all, and not yet in the ring) and only then walks the
  ring newest-first for a record matching that `passId`; a lane
  whose records have all aged out of the shared ring answers `nil`, same as a
  lane that has never run, so the next check in it mints round 1. **The round
  number, and which pass it belongs to, are minted in `beginRun`'s synchronous
  prefix — before the request is sent, before a single byte of preview
  arrives.** They cannot wait: from the first closed section onward the
  standing content IS this run's own preview, so a mint at record time would
  read the run's half-report back and file the answer as the round after
  itself. Minted once, the pair rides `StreamingRun` and threads through the
  one `record(...)` spelling, so the preview and the final answer describe one
  round rather than two checks that happen to disagree.
- **The round line's PLACEMENT in the pane is hoisted above the
  report/no-report fork, and a future `content` refactor could silently undo
  it** (M4 P1 Task 5 review, Important). It used to render only inside the
  report arm, which put it out of reach in the state that needs it most: a
  round in a pass over a piece with no declared intent raises no clauses and
  no strains, so `DiagnosticsPane.hasReport` is `false` — and since Task 3
  that round's WHOLE output is in the writer's queue, with nothing at all on
  this pane. `DiagnosticsPane.content` now renders `freshEyesLine`/`roundLine`
  in a `VStack` that wraps the empty state rather than living inside the
  `else` branch that only fires when there IS a report, so the since-last-round
  sentence (and the Fresh Eyes label) survive exactly the case that used to
  swallow them. If a later change moves the round lines back inside the
  report arm — reads as a harmless dedup of two nearly-identical branches —
  a pass round over an intentless piece goes back to showing nothing at all
  about what the round found. **`DiagnosticsPane.thisCheckSection` (M4 P2
  Task 1, spec §7.0) is the second resident of both arms and is there for the
  same case**: Author's live view of the notes the latest run minted, filtered
  out of the annotation layer by `lastRun.id`, whose whole point is the
  intentless round whose entire output is queued notes. Anything that dedups
  the fork has to keep both arms drawing it.
- **3 / 6 — the arrival.** Nothing here holds an editor binding or a
  `Document`. What a run needs off the live document arrives as a
  `DocumentReading` value captured at the keystroke, and paragraph text is
  re-read at ingest through a closure. An orchestrator that held the `Document`
  across a subprocess turn is exactly the shape those two tripwires are about.
- **20 — derive, never read the `.md`.** The delta is built from ops and the
  live paragraphs; the intent is read through `ProjectStore.statementText(of:)`,
  the one spelling of ADR 0018's two branches. Every raw read in this directory
  carries an `// adr-0018-ok:` annotation naming why it is not manuscript.
- **21 — events.** `MaughamEvent` only; the pane's Open Intent posts a scoped
  detail-segment event rather than a bare notification.
- **The allowlist census** (`MaughamTests/CompilerAllowlistTests.swift`) is the
  membrane in test form: every entry resolves to a catalog tool, no entry is a
  write, no statement-writing tool exists in the allowlist **or the catalog**,
  and each of those has a planted-offender companion so none of them can be
  quietly unfalsifiable.
- **The membrane is TWO flags, and the census guards only the stronger half.**
  `--allowedTools` removes nothing — it pre-approves what it names so those
  tools skip the permission prompt. Under `-p` that does leave Bash/Edit/Write
  unreachable, because they would prompt, but the built-in Read/Glob/Grep never
  prompt inside the working directory, so an enumerated list on its own leaves
  the spawned model free to read any file it can reach. `--tools ""` is what
  empties the built-in set; `currentDirectoryURL` is set to the session's own
  config directory behind it so an inherited cwd is not the writer's project
  either. The whole-branch review proved the gap live before the flag landed —
  a perfect allowlist and a model reading an arbitrary file off disk in the
  same invocation. `ClaudeCLISessionTests.test_spawnArgumentsMatchTheSpike`
  asserts both, and it parses argv with `components` rather than `split`
  because the flag's value is the empty string.

## The intent loop, both directions

This is what the milestone exists for, and the two halves are asymmetric:

- **Drift — never a note again, and now two readings of the same worry.** v1
  raised it as an anchorless diagnostic from an `intent_drift` field. What
  replaced that is the PATTERN: read back from the run records the sidecar
  already keeps — a clause straining the same way across
  `DriftDetector.consecutiveRunsThreshold` (3) consecutive runs (spec §3.4) —
  and surfaced as one line above the pane's conformance summary
  (`DiagnosticsPane.driftNote`), not a `Diagnostic`: no id, no dismissal, no
  reply field. Pressing it opens Intent; the pattern breaking on the next run
  is what takes the line away, not a tap. **M3-P3 then asked the question
  directly again**, as a fifth schema section and a per-round verdict
  (`DiagnosticIngest.parseIntentDrift` → `SectionedOutcome.intentDriftVerdict`
  → `CompilerRun.intentDriftVerdict`) — and it is still not a `Diagnostic`, for
  the same reason: a judgement about the whole reading has nothing to anchor to
  and nothing to answer. Two rules keep it honest. `holds`/`drifted` and
  nothing else, with an unrecognised word reading as no verdict rather than an
  `unknown` case, because the verdict is a projection this build never
  re-encodes. And the one sentence the schema asks for alongside it is read at
  ingest and **dropped** (ADR 0027: nothing model-produced renders in the
  editor's chrome) — the mark the verdict raises is app-authored.
- **Accretion** — an anchored note offers **Answer**, and the writer's sentence
  becomes a **ruling** on the **piece's** intent statement (never the
  project's), minting it if absent: an itemized, dated line under `## Rulings`
  carrying where it came from. Spec §3.4 names the old shape — a chat reply
  appended verbatim to the essay — as the membrane's loosest point, and this is
  the tightening. The answered note dismisses. The next run reads the enriched
  intent.

`RulingPerformer` is `PromotionPerformer`'s shape with two deliberate
differences — no autosave flush, no project-scope fallback — both argued at
length in its own doc comment. Read that before adding either back.

**Claude has no route into a statement, and that is enforced rather than
intended.** The compiler reads the intent it is judged against; a model that
could also write it can move the standard until nothing it produced is ever
flagged again. The census above is what keeps that true as the catalogue grows.

## The derivation trigger — decided here, because Stage 2 needs the answer

**Lazy, on-demand only: the first consumer that finds
`DeclaredWorldStore.cached(forScopeKey:sourceHash:) == nil` for the current
statement's hash is the one that calls `WorldDeriver.derive(statementText:)`
and stores the result.** No background derivation, no derive-on-save — the
same constitutional rule ADR 0027 §3 states for the run itself ("on demand,
never continuous") applies to the reading a run is checked against. A
statement mints or edits for reasons that have nothing to do with a check
being imminent; deriving on every keystroke would spawn a subprocess for
prose nobody is about to compile against.

**The run is that consumer, and it is the only one.**
`CompilerOrchestrator.resolveWorld` is the single production call site of
`WorldDeriver.derive` — it asks `Environment.cachedWorld` first and reaches
for `deriveWorld` only on a miss, both of them closures the production wiring
points at `DeclaredWorldStore` (`CompilerEnvironment+Project`). A derivation
that succeeds is cached by the closure that made it, or the next keystroke
pays for it again
(`CompilerRunCommandTests.test_productionCachesWhatItDerives`); a derivation
that fails caches nothing, because there is no such thing as a cached "could
not read this".

The other consumer the spec names — **the pane's own conformance preview** —
is still not built, and deliberately: the Rulings and Bible strata
(`RulingsStratum.swift`, `BibleStratum.swift`) read `RulingsSection.parse`
and `BibleStore.allFacts()` only; neither reads `DeclaredWorldStore.cached`
or draws a clause or a rule. That is the "never shown as mechanics" rule
(spec §3.1) held all the way to "never even asked for", and
`StatementPaneStrataTests`'s "no derivation is ever drawn" census is what
keeps it true.

Two things the trigger's shape buys, both worth keeping when you touch it:

- **A derivation is the run's second suspension**, after the burst flush and
  before the send, and it is the long one — a whole subprocess. It carries
  `CompilerOrchestrator.runGeneration`, so the AI toggle going off while a
  derivation runs abandons the run instead of spawning the session the toggle
  was meant to prevent.
- **The statement is derived WHOLE and briefed by halves.** `derive` reads
  essay + rulings (the rulings are half of what there is to derive); the
  message carries the essay as prose and everything below it as clauses. See
  "the atomic switch" below.

`RulingPerformer` invalidates the cache on every write (`rule`/`revoke`/
`edit`, each taking `world` as an explicit, undefaulted parameter — see that
file's own doc), which is what makes a revoked ruling stop being checked
immediately rather than at the next statement edit. **The cache key stays the
scope alone** even now that a verb can be aimed at an edition brief: nothing
derives a world from a brief, every brief-side caller passes `world: nil`, and
a second key shape would be the two-spellings defect `scopeKey` exists to
prevent — the day a brief is derived, `DeclaredWorldStore` grows the kind once,
for both readers.

## The atomic switch — why the essay and the clauses landed together

Until Stage 2 the run briefed the statement WHOLE, and that was correct:
rulings are declarations, and a contract with no notion of a derived clause
had to see them as prose. The moment the run consumes clauses, briefing the
prose as well puts the same declaration in front of the model twice — and a
model told a clause twice weights it over the rest of the writer's intent,
which quietly stops the run being about the essay. So the two halves had to
ship in one commit, and they did.

The guard is `CompilerRunCommandTests.test_rulingsAreBriefedAsClausesNotProse`
— the essay present, the derived reading present, the `## Rulings` heading and
the row's date/provenance absent, and the writer's ruled sentence appearing
**exactly once**. Count the occurrence, not the presence: presence alone
passes on a message that carries the sentence twice.
`test_aRulingBetweenRunsReachesTheNextBriefing` is the same guard over the
whole chain — a real `RulingPerformer.rule` between two real runs — and it is
the one that says the ruling *arrives*, not merely that the prose does not.

**The door this does NOT close, and the shape of the risk if you change the
contract.** `ClaudeWorldDeriver.derivationSchemaDescription` asks for a
`quote` copied verbatim from **the statement**, essay included — not only from
the Rulings stratum. So a real derivation can return a clause whose quote is a
sentence of the essay, and that sentence is then in the message twice: once as
the essay's own prose, once as the clause's citation. It is the identical
over-weighting the switch above exists to prevent, arriving through a
different door, and nothing today measures it — the guard counts the RULED
sentence, and the fixture's essay-sourced clause is deliberately not counted.

Left open rather than closed, on purpose: the honest fixes are all contract
changes (quote essay clauses by reference, or drop the essay's prose once every
sentence of it is a clause), each of which trades one kind of loss for another
and belongs to a milestone that can measure the result. **What must not happen
is closing it by accident** — if you widen the derivation schema, or make the
briefing embed clause quotes some other way, this is the paragraph to re-read
first. A watch item for Stage 3, recorded here because a reader of
`worldSection` cannot see it.

## The third door: bless converges, and graduated is not dismissed

**Closed in Stage 3.** `BibleStore` remembers the `(subject, fact)` keys the
writer has GRADUATED — blessed or corrected into a ruling — and `record` drops
a candidate whose key is one of them. `BibleStratum.graduate` marks the key
after `RulingPerformer.rule` succeeds and before `bible.dismiss`, so a refused
ruling leaves both the fact and the door exactly as it found them. The keys ride
in the per-device sidecar beside the ledger (one envelope, because a graduated
key that outlived its facts would put the blessed reading back on the pane the
launch after somebody deleted the wrong half; a bare-array sidecar from a
previous build still loads and simply has nothing graduated).

It is deliberately NOT a memory of **dismissal** — spec §3.3 is unchanged, a
plain dismiss keeps no memory, and a manuscript that re-establishes a dismissed
fact is a reading returning rather than a record surviving
(`BibleStoreTests.test_dismissedFactCanReturn_thisIsIntended` sits adjacent to
`test_aBlessedFactDoesNotComeBack`, each naming the other).

**A correction marks two keys, and the second one is the half that reopened the
door.** It rules "Kelly is a paramedic" over a reading of "Kelly is a nurse",
and the manuscript can establish either afterwards — the reading, because the
prose that produced it is still there, and the ruling, because the writer has
since written toward what they decided. Marking only Claude's reading left the
writer's own sentence free to come back as a fresh candidate, which is door 3's
step 4 (a duplicate ruling row) reached through correction instead of bless;
measured against the shipped code in fix round 1's review. Both are declared or
superseded now, so a candidate matching either is not news. A bless has one
sentence in both roles and marks one key.
`StatementPaneStrataTests.test_correctingGraduatesClaudesReading` and
`test_correctingAlsoGraduatesTheWritersOwnRuling` are adjacent, each naming the
other, because neither is the whole rule.

**Revoking the ruling does not reopen the door**, by decision rather than
oversight — a revoke is the writer unmaking a decision, not asking to be
re-offered the reading days later about prose they have since rewritten, and
resurrection would have to guess which of a correction's two sentences was ever
a fact. The reasoning lives on `BibleStore.markGraduated`; if a smoke says
otherwise the fix is one `graduatedKeys.remove` at the revoke site.

The walk below is what the design answers, kept because it is the rationale and
because every step of it is what the tests assert against:

1. Run N reads a fact; the writer blesses it. `BibleStratum.graduate` mints a
   ruling through `RulingPerformer.rule` and then calls `bible.dismiss` —
   correct so far, the fact leaves the ledger as the clause enters the world.
2. The writer later revises the establishing scene. Run N+1's delta contains
   that prose again, the model re-emits the same fact, and `record` re-adds it:
   **the blessed fact is back in the stratum, indistinguishable from new**.
3. From then on the same declaration is briefed **twice** — as a bible fact and
   as the ruling's derived clause. That is the over-weighting the atomic switch
   above exists to prevent, arriving through a **third door** (door 2 is the
   essay-sourced clause quote, the section above).
4. A writer who blesses the returned fact again mints a **duplicate ruling
   row**: `RulingsSection.appending` does not dedupe, and the duplicate then
   renders as duplicate conformance rows, which `conformanceRows` embraces by
   design.

Of the two candidate fixes, the shipped one is the tombstone: it is
derived-state-shaped and does not touch the membrane. String-matching `record`
against ruling texts was rejected — it is fragile, and it misses corrections
entirely, where the ruled sentence and the re-emitted reading are different
strings by construction.

**The loop is walked end to end by one test.**
`CompilerRunCommandTests.test_theBibleLoopConvergesAcrossRunsWithABlessInTheMiddle`
drives three runs over a real project with a real mounted `StatementPane`: run 1
reads the fact and the stratum shows it, the writer presses the real `Bless`
button through the accessibility tree, run 2 re-emits the identical candidate,
and run 3 is where a returned fact would have been briefed. Three runs and not
two because **the ledger is read at the start of a run (`bibleSlice`) and
written at its end (`recordFacts`)** — the run that re-emits a blessed fact is
never the run that would brief it. Falsified by deleting `record`'s graduated
guard: the fact returns to the register and to the pane, and run 3's message
carries the same declaration twice, once as a bible fact and once as the
ruling's derived clause.

## The four fates of a note — narrowed to the sidecar's own kind, M4 P1

**As of M4 P1, a `Diagnostic` in the sidecar is a conformance strain, and
nothing else** (`SectionedOutcome.sidecarDiagnostics` filters to
`.conformanceStrain`; the paragraph below the numbered list is where a
continuity question and a reader's report actually go instead — they never
reach this section's four fates at all). What follows described every kind of
finding through M3-P3; it now
describes a strain's own lifecycle, and a strain ends one of four ways, only
one of which is a button:

1. **Superseded** — the next run's diagnostics wholly replace the previous
   run's for that document, and its `clauseStatuses` replace the previous
   summary in the same act. Un-promoted strains are dropped, not merged.
2. **Stale** — its paragraph's text no longer matches the text it was anchored
   to, so `DiagnosticsStore.live` stops returning it. A strain that names no
   paragraph at all never goes stale this way; it has nothing to track. A v2
   note's anchor is its FIRST resolving ref, so the staleness rule needs no
   per-kind variant and `refs` stay display-only.
3. **Promoted** — kept as an op-logged task, which syncs and survives
   (`DiagnosticPromotion`, whose doc comment now names its own narrowed
   scope: a strain, never a continuity question or a reader's report, which
   are already op-logged the moment they mint and would gain nothing from a
   second copy in the task list. The promotion function's `sectionLabel` still
   answers "continuity"/"the reader" for a task promoted *before* this
   milestone — an old record's provenance line must not lose its section
   just because the pane stopped drawing it).
4. **Answered** — became a ruling on the piece's intent (`RulingPerformer`),
   and (M4 P1 Task 6) the ruling now carries the answered strain's own
   `clauseQuote`, sanitized and trimmed to `driftQuoteMaxLength` (60,
   `DiagnosticsPane.answeredNoteProvenance`), so a later reader of the Intent
   pane sees what was ruled *on* rather than a bare "answered a compiler
   note" with nothing beside it.

**A continuity question and a reader's report have no fates here at all —
they leave the sidecar for the annotation layer the instant a run finishes**
(`Environment.mintAnnotations`, described in the seam map's `CompilerNote.swift`
row above). From that moment they are ordinary
`Annotation`s and follow that layer's own lifecycle: open in the queue and the
margin, then accept/reject/stet/discussed/promoted-to-a-task through the same
verbs and the same undo conventions (ADR 0023) as any note Claude Desktop
wrote by hand. `RulingPerformer` never sees one — a continuity question is
disposed of in the queue, not answered into a ruling, which is the one place
this milestone actually narrowed what `RulingPerformer` reaches rather than
widening it.

The sidecar is derived state: a missing or corrupt file reads as empty rather
than throwing, and losing it costs nothing because the next run repopulates it.
There is no repair path, only "start from nothing" — `CanvasStore.load`'s
contract, one directory over.

## Streaming — the report arrives in sections, and a preview is not a run

Built third stage (Task 4). Stage 2 named it a follow-on and left the ingest
ready for it: `parseAll` is `parseSection` folded over the turn and nothing
else, so sections could always be read one at a time. Four things carry it, and
three of them are about what a half-arrived report may NOT do.

- **The stream is asked for, and only one delta kind is the answer.**
  `ClaudeCLISession.arguments` adds `--include-partial-messages`; `classify`
  gained `.partialText`, keyed on `stream_event → event.content_block_delta →
  delta.text_delta`. **All three delta kinds arrive as `content_block_delta`**
  — `thinking_delta` carries the model's private reasoning, `signature_delta`
  an opaque blob — so a classifier keyed one level too high feeds the
  orchestrator a report made of the model thinking out loud, and nothing
  downstream can tell. Captured from a real turn rather than guessed;
  `ClaudeCLISessionTests`' `captured…` constants are that turn's lines
  verbatim, and the falsification (accept `thinking` too) fails two tests.
- **Deltas ride `receive`, behind the SAME two guards as the result** — live
  generation, turn in flight. A retired process's enqueued deltas would
  otherwise be spliced into the run that replaced it, and that run would still
  resolve normally, so nothing would look wrong
  (`test_aRetiredProcessesDeltasNeverReachTheHandler`, planted).
- **A chunk is not a line.** `CompilerOrchestrator.receivePartial` accumulates
  and reads only what a newline closed. The transport cuts wherever it likes,
  and a truncated object can look complete.
- **The result REPLACES the preview; it never folds into it.** `finish` runs
  `parseAll` over the whole turn and calls `replace`. Accumulating instead
  shows a model's restated section twice, persisted
  (`test_theFinalResultReconcilesTheStream`, falsified).

`DiagnosticsStore.preview` is the storage verb and is deliberately weaker than
`replace` in three ways, each a defect if a preview did it: **no persistence**
(a half-report on disk reads back as the standing answer), **no drift ring**
(`DriftDetector` counts consecutive RUNS — one check's sections, folded in one
at a time, would fabricate a pattern), **no unread badge** (a badge for notes
the cancel removed is a badge nothing can clear). `discardPreview` is a re-read of the
untouched sidecar, which is why a cancelled preview puts the previous *finished*
run back rather than clearing the document. Every path where a run ends without
an answer discards: `finish`'s failure arm, the unusable-output arm, `cancel()`
(also directly — the continuation resumes a tick later, and the writer watches
the half-report until it does) and `shutdown()`.

The pane needed no new state to DRAW a preview. The version counter already
draws whatever is stored, and `headerState` prefers the run state for this
document, so the wait copy keeps saying "Checking…" while the report grows
under it.

**A preview's rows carry no fates, and that took two guards** (the whole-branch
Critical, fixed in the fix wave). `preview` weakened three of `replace`'s
verbs, but `dismiss` — this store's third writer, and the only one older than
streaming — still persisted, and BOTH fates end in it: `DiagnosticsPane.promote`
and `commitAnswer` each call `dismiss` last. So answering a streamed note wrote
the half-report to the sidecar as the standing answer, **with the marker
`beginRun` mints before the send on it**, and a cancel then read it back — the
prose the aborted run stopped reading would never be checked again. A run that
completed instead resurrected the answered note through `parseAll`-replace (the
turn's own text still contains it, with a fresh id) and a second answer minted a
duplicate ruling. Neither task's suite composed the two: the streaming tests
only ever *watch* a preview, and the fates' tests never stream.

The fix is one bit and one precondition, no new run-state reading:

- `DiagnosticsPane.offersDurableActions(state:)` — pure, taking `HeaderState`
  so it inherits `headerState`'s per-document scoping. Only `.running`
  withholds Answer and Promote; a run on ANOTHER document reaches it as
  `.idle`/`.clean` and that pane keeps its fates. `.failed`/`.nothingNew`
  describe runs that are over and their rows are the last finished report's.
- `DiagnosticsStore.dismiss` refuses outright while `previewing.contains(docId)`
  — in memory as well as on disk, so the door is shut rather than the handle
  hidden, and any future per-note mutator inherits the rule.

Falsified both ways: force the gate true and the mounted preview test goes red;
drop the precondition and the byte-identical sidecar test does
(`test_aDismissalCannotReachAPreview_soTheSidecarSurvivesACancelByteIdentical`,
which asserts the file did not change *at all* — the only assertion a write
that merely round-trips cannot satisfy).

**`CompilerRun.mintedNotes: Int?` exists so the pane can never claim a clean
check over a run that queued notes** (M4 P1 Task 3 review, Important). A run
raising three continuity questions and no conformance strain leaves the
sidecar empty — before this field, every surface keyed on "were there
diagnostics?" answered yes to "nothing to flag," including the header, the
empty state's seal, and the unread badge, which cleared itself on the one run
it exists to announce. `finish` mints BEFORE it records
(`CompilerOrchestrator.record`'s `mintedNotes:` parameter), so the count
exists to be written down. `DiagnosticsPane.headerCopy`'s `.clean` arm opens
with `queuedNotesSentence(run.mintedNotes)`, falling back to "Nothing to
flag" when that is `nil` — **as it stood before M4 P2's Task 1 added
`WetInk`**. Now that opening is gated on `wetInk == .none`: when `wetInk` is
`.showing` or `.settled`, This check is drawing those same notes directly
below this line, so the header says "Nothing to flag" regardless of
`mintedNotes` rather than pointing the writer at a queue the notes are
already visible under — `wetInk`'s own doc comment on `headerCopy` carries
the current rule. `emptyState` gets its own **"Notes in your
queue"** arm (reached only when `wetInk == .none` too), ordered ABOVE the
discarded-notes arm because it is the stronger claim — a run can both queue
notes and lose some, and the queued ones are the news the writer needs
first. **The legacy trap, named so the
next empty-state simplifier does not re-open it:** before this fix the pane's
note count came from `rows.count`; since the M4 P1 slimming, `rows` can hold
notes this pane refuses to draw (a sidecar written by an older build, still
carrying continuity/reader-kind `Diagnostic`s), so a legacy sidecar of stale
continuity rows reached the `.idle` header state and called itself clean —
the header cannot be simplified back to counting `rows` without resurrecting
that false "Nothing to flag." `headerState` is fed `strains.count` instead,
which is what makes `.idle` genuinely unreachable from `emptyState` rather
than merely re-commented as such.

**A Cancel mid-mint can leave notes stamped with a run id the diagnostics store
never records, and that is honest rather than a bug** (M4 P1 Task 3). `finish`
awaits `mintAnnotations` before checking `runGeneration == generation`
(`CompilerOrchestrator`'s own doc comment on `finish` names the ordering); a
Cancel arriving inside that await bumps the generation and returns early,
so `Self.record(...)`/`diagnostics?.replace(...)` never run for this `runId` —
the sidecar simply has no `CompilerRun` by that id. The op-log appends
`mintAnnotations` already made are not rolled back (the mint cannot throw and
was never asked to be transactional — spec §3.2 calls the compiler a
background convenience, not a source of truth to keep consistent at the cost
of the writer's words), so a handful of annotations can carry a
`compilerRunId` the pane can never look up. The dedupe backstop is unaffected
either way — it keys on `compilerFingerprint`, not on whether the run that
minted a note is still resolvable — and the writer sees the notes in their
queue regardless of which side of the race the cancel landed on. Nothing
reads a minted annotation's `compilerRunId` back against the sidecar today, so
the gap is inert; it is recorded here because the type cannot defend itself
and a future reader that DOES join the two should know the join can miss.

## The cold-start offer — refusable once, per document, forever

Built Stage 3. Spec §4's "one refusable offer... never re-asked as a nag" for
a document this build has never run. Almost all of it is `DiagnosticsPane`'s
(the pure decision `showsColdStartOffer(state:liveParagraphCount:hasRefused:)`
and the two-button view) and therefore across the seam like the rest of the
pane — this area's only piece is the memory the "Not now" side writes into.

`DiagnosticsStore.refuseColdStart`/`hasRefusedColdStart` are a fourth,
deliberately different sidecar shape: every other record in this store is
keyed by `docId` and requires a `CompilerRun` to exist first (`FileContent`'s
`run` field is non-optional), but a refusal can happen before a document has
ever been checked at all — before `FileContent` for it exists. Rather than
fabricate a run to hang a boolean off, the refusal set lives in its own tiny
per-device file, `.maugham/diagnostics/cold-start-refused.<slug>.json`, on the
same derived-state contract as everything else here: a missing or corrupt
file reads as empty, and losing it costs nothing worse than the offer asking
once more. **Reading is not a new run kind** — the offer's `Read` button
calls `CompilerOrchestrator.runRequested` exactly as ⌘R does, which already
treats a document with no marker as "everything is new"; nothing in this area
special-cases a first run reached through the offer versus the keystroke.

## Tests worth knowing about

**Count the tests, not this file.** The list below says what each suite is
*for*; the suites themselves are the specification, and a claim here that has
drifted from them is a defect in this file.

- `CompilerAllowlistTests` — the membrane census and its planted offenders.
- `DeltaBuilderTests` — what "changed since the marker" means, in the writer's
  order.
- `CompilerPromptTests` — the section schema's fixed order and register
  enforcement (no severity, no suggestion field), the v2 briefing (essay +
  derived world + bible facts diffed in as one unit), and the session
  preamble.
- `ClaudeCLISessionTests` — the process, its arguments, and every path it has to
  die on.
- `DiagnosticIngestTests` — live anchoring, a bad note never failing a run, and
  the `intent_drift` verdict: its two recognised words, an unrecognised one
  reading as none, a four-section answer still ingesting whole, the fold
  keeping the latest non-nil, and the model's sentence reaching nothing the
  writer reads.
- `DiagnosticsStoreTests` — the sidecar, the staleness rule, the marker.
- `DiagnosticsPaneTests` / `DiagnosticPromoteToTaskTests` — the pane's states
  and the promotion, pressed through the real accessibility tree.
- `RulingPerformerTests` — the verbs, their four refusals that must write
  nothing, the one-op edit, the derivation invalidation, and the membrane census
  with its planted offender.
- `StatementPaneStrataTests` — the essay/rulings split (including the identity
  property `render` cannot promise), the ruling that lands mid-edit, the rows'
  two verbs and their one ⌘Z each, the bible's three actions, and the census
  that no derivation is ever drawn.
- `DeclaredWorldStoreTests` — the hash-gated cache: a reading served only
  against the exact text it was made from, invalidation on write, the one
  `scopeKey` spelling, and the missing-or-corrupt-sidecar-reads-empty contract.
- `DeclaredWorldDeriverTests` — the one-shot subprocess: its stricter
  confinement than `ClaudeCLISession` (no `--mcp-config` at all, `--tools ""`),
  the prompt/parser wire-shape agreement, honest `nil` on every failure mode,
  and (Stage 3) the 120s deadline against a fixture that never answers and
  never exits on its own, with an injected short deadline so the test does
  not wait the real budget out. One live probe against the real CLI is
  recorded in the task-3 report, not run here.
- `BibleStoreTests` — the ledger: `(subject, fact)` dedupe (and that a
  dismissed fact can return), the per-device sidecar, and the subject-slice
  `facts(subjects:)` the run calls.
- `DiagnosticsPaneTests` — the report the pane draws (the conformance summary
  first, the excerpt chips, the legible wait) and the answer flow end to end,
  including that it lands as a ruling and drops the derivation it outdated;
  also the drift line above the summary — its register, that it names no
  count beyond "three runs", and that it is not a `Diagnostic`; and (Stage 3)
  the cold-start offer's pure decision (`showsColdStartOffer`) plus its
  refusal — the offer for a never-run, non-stub document, gone once refused,
  gone for good once any run happens.
- `CompilerRunCommandTests` — ⌘R's real delivery path.
- `PinnedReferencesTests` — the projection, its sections and its resolution,
  including the dedup/dangling/order rules; its census keeps `linkedResearchIds` (not
  `StructureItem.links`) the only field a caller may name. `ReferencesPaneTests`
  and `AssistantColumnTests`, across the seam in `Maugham/Views/`, are the
  shelf's and the column's own suites, and pin that both surfaces and the run's
  `pinnedListing` share this one projection.

**One known gap, on the record:** SwiftUI exposes no way to deliver a Return
keystroke into a hosted `TextField`'s editor, so the reply field's *commit on
return* and *escape cancels* are asserted at the source rather than pressed
(`DiagnosticsPaneTests.test_theReplyFieldCommitsOnReturnAndCancelsOnEscape`).
Everything the commit then does is driven for real against live stores through
`DiagnosticsPane.commitAnswer`, which is why that function is a `static` taking
everything it touches.

## What's intentionally NOT here

- **The Author surfaces' views.** The intent strip above the prose
  (`IntentStrip.swift`) and the references shelf / assistant column
  (`ReferencesPane.swift`, `AssistantColumn.swift`, spec §6) shipped in Plan 2
  — but they live in `Maugham/Views/`, not here, on the same principle as the
  pane: this directory holds no view state. What lives here is what feeds them
  — `PinnedReferences`/`PinnedReferenceResolver` — and the run's own
  `Environment.pinnedListing`/`paletteListing` closures
  (`CompilerOrchestrator.runRequested`, wired to `runMessageV2`'s
  `pinnedListing`/`paletteListing` parameters) read the identical projection.
  Both still ship empty-capable, but the reason changed: the
  prompt omits an empty section by design, and today a document with nothing
  linked or clustered is the only thing that produces one — not an unbuilt
  surface.
- **An Author posture object.** Spec §6.3's finding: answering a diagnostic
  changes nothing structural — the editor stays the editor — so a policy object
  with nothing to produce would be ceremony. **Built as designed, 2026-08-05**:
  Plan 2 shipped Author with none, and nothing since has argued otherwise.
- **A new MCP tool, in either direction.** The compiler is an MCP *client*. The
  catalogue did not move for M2.
