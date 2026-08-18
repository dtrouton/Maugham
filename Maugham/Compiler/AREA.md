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

**The run speaks the v2 contract** (spec §5), and M3-P3 added a fifth line to
it: four line-delimited note sections — conformance against the writer's
derived clauses, continuity questions, a reader's report, and fact-candidates
that land silently in the bible — plus `intent_drift`, a verdict on the reading
as a whole rather than a thing found in it.
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
`.effectiveEditorName` rather than the raw fields — `CompilerEnvironment
+Project.swift`'s `activePass` closure is the one production call site, and its
own comment names why reading `pass.editorName` directly would sign a Copyedit
round's notes with nothing at all. The resolved name goes three places: the
**annotation author** on every note that pass mints (`CompilerMintContext.
editorName`, so the queue's author filter becomes "everything Gould flagged"
and a passless run signs "Claude" — M2's identity, unchanged), the round
briefing's **role frame** (`CompilerPrompt`, "You are Gould, this manuscript's
copyeditor"), and the pass's own brief, embedded in the same briefing so
attention follows the register the writer chose. A custom pass with no brief
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
stops two OPEN notes sharing a fingerprint, but nothing stops an open note
sharing one with a note settled earlier and since re-raised — briefing both
would tell the model to confirm a finding in one line and forget it two lines
later. The live note wins: `dispositionsSection` drops a settled entry whose
fingerprint is also standing. A note with no fingerprint (the anchorless
kind — a doc-scoped craft note, which has no discriminator to make one from)
is listed on its own rather than folded into anything, since a nil
fingerprint is the absence of identity, not an identity shared with anything
else. **A sibling residual, same class:** a continuity note's fingerprint
leans on the model re-quoting `cites` byte-identically (`RoundFingerprint`'s
"clause quote" for that kind), so a re-punctuated quote on a Fresh Eyes
reread — same question, one comma moved — can mint a duplicate the dedupe
can't see. Neither residual gets machinery; the writer disposes the
duplicate the way they dispose any other settled note.

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
  — the union of research the writer linked and cards they clustered on the
  canvas, one pure function with two production callers: the run's own context
  and the Author surfaces below. Neither may re-derive it.

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
| `CompilerEnvironment+Project.swift` | The production wiring — the window's stores, as the closures the orchestrator runs on. Every capture is weak |
| `DeltaBuilder.swift` | What changed since the last run's marker, in the writer's order (`sequence`, never raw `paragraphs`) |
| `CompilerPrompt.swift` | The message. Asks different questions of new and revised prose; v2 carries the essay + derived clauses + the bible slice + the delta, diffed in as ONE unit (`briefingHash`). M4 P1 adds two more sections between the listings and the delta, neither folded into `briefingHash` (each changes with the writer, not with what they declared): the active pass's **role frame + brief** (`passSection`, "You are Gould, this manuscript's copyeditor") and the **dispositions** section (`dispositionsSection`/`CompilerAnnotationDisposition.gather` — standing notes uncapped, settled notes capped at 12 and sorted by `resolvedAt` descending; see the dispositions paragraph above) |
| `CompilerAllowlist.swift` | The enumerated read-only MCP tool list, as `--allowedTools` |
| `CompilerRunner.swift` | The seam: `send(message:systemPreamble:) -> CompilerRunEvent`, plus every way a run can fail |
| `ClaudeCLISession.swift` | The warm subprocess behind that seam |
| `DiagnosticIngest.swift` | The structured message → notes, clause statuses and fact-candidates, anchored against the LIVE document. One section is one unit, so arrival can become incremental without the fold changing. `SectionedOutcome.sidecarDiagnostics` keeps conformance strains only; `.mintable` is the other half, built from the same accepted diagnostics rather than re-parsed |
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
| `PinnedReferences.swift` | The pure union: linked research + clustered canvas cards, resolved to renderable pins |
| `PinnedReferenceResolver.swift` | The caller-side assembly against a live project — the four inputs `PinnedReferences.pinned` takes, gathered in one place |

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
| It dies quietly after ~10 min idle | `ClaudeCLISession.idleTimeout` (600 s; `runTimeout` is 120 s) |
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
  files into the same ring, so five finished checks in Line push a Structural
  round out of it exactly as five more Structural checks would. It is written
  only by `replace`, and only for the run being SUPERSEDED — `RoundRecord(run:)`
  is built from `finishedContent(docId:)`, which reads the
  in-memory `byDoc` entry directly except while a preview is standing in for
  it, when it reads the shadow `finishedBeforePreview` captured the moment the
  preview began (keyed on the `previewing` Set, never on the shadow's
  nil-ness — a cold document's first preview captures nothing, and a `??`
  fallthrough there would read the run's own half-report as the previous
  round). `latestRound(forPass:docId:)` — the one reader both `beginRun`'s
  minting and the pane's `sinceLastRoundLine` go through — checks the standing
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
immediately rather than at the next statement edit.

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
- `PinnedReferencesTests` — the union and its resolution, including the
  dedup/dangling/sort rules; its census keeps `linkedResearchIds` (not
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
