# Compiler — Area guide

Maugham's **author compiler** (M2): the writer presses ⌘R, a warm `claude -p`
session reads what has changed since the last run, and its notes land in the
Diagnostics pane as ¶-anchored diagnostics. Read this before editing in
`Maugham/Compiler/`. Also read the project root `CLAUDE.md` for cross-cutting
invariants, the design of record —
`docs/superpowers/specs/2026-08-04-m2-author-compiler-design.md` — and its
supersession —
`docs/superpowers/specs/2026-08-07-compiler-second-draft-design.md`, which
keeps the run's mechanism unchanged (§5's opening line) but replaces the
workflow half: notes, fates, the answer flow and the pane's organization.

**The run speaks the v2 contract** (spec §5): four line-delimited sections —
conformance against the writer's derived clauses, continuity questions, a
reader's report, and fact-candidates that land silently in the bible.
`CompilerPrompt.sectionSchemaDescription` is what is asked for and
`DiagnosticIngest.parseSection`/`parseAll` is what reads it. **The v1 contract
is gone**: `runMessage`, `CompilerContext` and `DiagnosticIngest.parse` were
retired in Stage 2's own docs task once the atomic switch (below) proved they
had no production caller — a grep for `runMessage(` today finds nothing at
all, not even a test.

Two things v1 had that v2 does not: a free-form category tag (the section a
note came from is its whole classification), and the drift diagnostic — drift
becomes a PATTERN computed across run records in Stage 3, and nothing
replaces it here.

Two sentences hold the whole design:

- **The keystroke is the only trigger.** Nothing here reaches for itself. A run
  on every pause is the background linter the constitution excludes (must-not
  #2), and every timer in this area exists to end a session, never to start one.
- **The compiler reads and never writes.** It reads the manuscript through an
  enumerated read-only MCP allowlist and answers with a structured message. The
  one thing that puts words anywhere is `RulingPerformer`, and its input is a
  sentence the writer typed. (The M2 answer shim that routed into it,
  `IntentAppendPerformer`, is gone: the pane's reply field calls the verb.)

## What this area owns

- The run: delta → prompt → session → parse → store (`CompilerOrchestrator`).
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
| `CompilerRunModifier.swift` (in Views) | ⌘R's delivery path, and three of the four ways the session dies |
| `CompilerOrchestrator.swift` | **The run.** Owned by `ProjectWindow`; one orchestrator per window, one session per orchestrator |
| `CompilerEnvironment+Project.swift` | The production wiring — the window's stores, as the closures the orchestrator runs on. Every capture is weak |
| `DeltaBuilder.swift` | What changed since the last run's marker, in the writer's order (`sequence`, never raw `paragraphs`) |
| `CompilerPrompt.swift` | The message. Asks different questions of new and revised prose; v2 carries the essay + derived clauses + the bible slice + the delta, diffed in as ONE unit (`briefingHash`) |
| `CompilerAllowlist.swift` | The enumerated read-only MCP tool list, as `--allowedTools` |
| `CompilerRunner.swift` | The seam: `send(message:systemPreamble:) -> CompilerRunEvent`, plus every way a run can fail |
| `ClaudeCLISession.swift` | The warm subprocess behind that seam |
| `DiagnosticIngest.swift` | The structured message → notes, clause statuses and fact-candidates, anchored against the LIVE document. One section is one unit, so arrival can become incremental without the fold changing |
| `DeclaredWorldDeriver.swift` | Also the one-shot's pipe discipline: stdout is drained WHILE the process runs. Reading it from `terminationHandler` deadlocked on any answer past ~64 KB — the child blocks on its own write, so it never exits, so the handler never fires |
| `Diagnostic.swift` | `Diagnostic` + `CompilerRun` — the wire and sidecar shapes |
| `DiagnosticsStore.swift` | The per-device, per-document sidecar, and the staleness rule |
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
  `DiagnosticsStore.sidecarURL` and **nowhere else** — the slug lives only in
  filenames and is never serialised into content. Two more per-device sidecars
  joined this stage, both on the same discipline: `.maugham/derived/
  <scopeKey>.<slug>.json` (`DeclaredWorldStore.sidecarURL`, one per statement
  scope) and `.maugham/bible.<slug>.json` (`BibleStore.sidecarURL`, one per
  project). `.raw` is interpolated only at each of those two call sites.
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

- **Drift — no longer a note, and now a pattern.** v1 raised it as an
  anchorless diagnostic from an `intent_drift` field; the v2 contract has no
  such field and the run carries nothing in its place. Stage 3 reads it back
  from the run records the sidecar already keeps — a clause straining the same
  way across `DriftDetector.consecutiveRunsThreshold` (3) consecutive runs
  (spec §3.4) — and surfaces it as one line above the pane's conformance
  summary (`DiagnosticsPane.driftNote`), not a `Diagnostic`: no id, no
  dismissal, no reply field. Pressing it opens Intent; the pattern breaking on
  the next run is what takes the line away, not a tap.
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

Two things the rule is deliberately NOT. It is not a memory of **dismissal** —
spec §3.3 is unchanged, a plain dismiss keeps no memory, and a manuscript that
re-establishes a dismissed fact is a reading returning rather than a record
surviving (`BibleStoreTests.test_dismissedFactCanReturn_thisIsIntended` sits
adjacent to `test_aBlessedFactDoesNotComeBack`, each naming the other). And it
is not keyed on the writer's words: a **correction** rules "Kelly is a
paramedic" and graduates *"Kelly is a nurse"*, because what a later run
re-emits is what it reads off the prose.

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

## The four fates of a note

A diagnostic ends one of four ways, and only one of them is a button:

1. **Superseded** — the next run's diagnostics wholly replace the previous
   run's for that document, and its `clauseStatuses` replace the previous
   summary in the same act. Un-promoted notes are dropped, not merged.
2. **Stale** — its paragraph's text no longer matches the text it was anchored
   to, so `DiagnosticsStore.live` stops returning it. A note that names no
   paragraph at all never goes stale this way; it has nothing to track. A v2
   note's anchor is its FIRST resolving ref, so the one staleness rule serves
   all three kinds and `refs` stay display-only.
3. **Promoted** — kept as an op-logged task, which syncs and survives
   (`DiagnosticPromotion`).
4. **Answered** — became a ruling on the piece's intent (`RulingPerformer`).

The sidecar is derived state: a missing or corrupt file reads as empty rather
than throwing, and losing it costs nothing because the next run repopulates it.
There is no repair path, only "start from nothing" — `CanvasStore.load`'s
contract, one directory over.

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
- `DiagnosticIngestTests` — live anchoring, and a bad note never failing a run.
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
  the prompt/parser wire-shape agreement, and honest `nil` on every failure
  mode. One live probe against the real CLI is recorded in the task-3 report,
  not run here.
- `BibleStoreTests` — the ledger: `(subject, fact)` dedupe (and that a
  dismissed fact can return), the per-device sidecar, and the subject-slice
  `facts(subjects:)` Stage 2 will call.
- `DiagnosticsPaneTests` — the report the pane draws (the conformance summary
  first, the excerpt chips, the legible wait) and the answer flow end to end,
  including that it lands as a ruling and drops the derivation it outdated;
  also the drift line above the summary — its register, that it names no
  count beyond "three runs", and that it is not a `Diagnostic`.
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
- **Streaming — and it is now a NAMED follow-on rather than an absence.**
  `CompilerRunEvent.started` still exists for a consumer that does not exist,
  and `send` still resolves with a terminal event: `ClaudeCLISession.receive`
  classifies every stream line and forwards only `type == "result"`, so
  partial assistant text never reaches the orchestrator at all. Stage 2's
  ingest was built section-at-a-time for this — `parseAll` is `parseSection`
  folded over the turn and nothing else — so the upgrade is a session that
  surfaces partial assistant events plus an orchestrator that folds them as
  they land, and NOT a change to what a section means. **Stage 2 landed the
  whole-turn shape deliberately** (the session was not rebuilt for it); the
  writer-facing half of that requirement — a wait that says what it is
  reading — is the pane's, and does not depend on this.
- **A new MCP tool, in either direction.** The compiler is an MCP *client*. The
  catalogue did not move for M2.
