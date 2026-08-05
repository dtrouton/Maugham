# M2 — the Author persona and the compiler — design

*Brainstormed 2026-08-04 with Denver. This is the design for the umbrella's M2
(`2026-07-25-mode-based-ux-redesign-design.md` §4.1, §5, §8): the tight feedback
loop. The umbrella's decisions stand except where a section here amends them on
the record. The persona-shell spec (`2026-08-01-persona-shell-workflow-design.md`)
is in force; §6 of this document records one finding against its §2.*

*Operating note: Denver has authorized an autonomous end-to-end run of this
milestone — judgment calls are made and recorded rather than asked. Decisions
made under that authority are marked **[judgment]**.*

---

## 1. The goal, in the writer's words

> "As near as live editor quality feedback on my writing while I'm still in the
> mode, still writing."

And the intent is the centre of it:

> "I really want the compiler to help keep on line with my intent — or force me
> to update my intent if it's out of date."

Two constraints frame everything below:

- **Tightness comes from speed, never from auto-triggering.** The keystroke is
  the only trigger. A run on every pause is the background linter the
  constitution excludes (must #2, must-not #2). The design makes a run cheap
  enough that reaching for it constantly feels free; it never reaches for
  itself.
- **Elegant, understated, delightful.** Nothing bounces, badges loudly, or
  interrupts the sentence being written. The failure mode of "IDE for prose" is
  a busy, chirping surface; every surface below is designed against it.

**Latency budget, as a design constraint rather than an aspiration:** first
diagnostic visible ~2–4 s after the run keystroke on a warm session; a full run
in seconds. This is what the warm session (§3.4) exists to buy.

## 2. What M2 covers

The whole umbrella M2 bundle, confirmed 2026-08-04:

- The compiler: one-key run, structured op-log delta, warm `claude -p` session,
  streamed results.
- The Diagnostics pane (`DetailSegment.diagnostics`, ⌘⌥D) with ¶-anchored
  self-dismissal and four fates: fix, ignore, promote to task, **answer**.
- The intent loop in both directions: drift diagnostics ("your intent may be
  stale") and answer-accretion (your explanation becomes intent).
- The intent strip.
- The References pane (`DetailSegment.references`, ⌘⌥E) and the assistant
  column.
- Two ADRs: the must-not #2 refinement, and Maugham-goes-outbound.

Out of scope: §11.

## 3. The run

### 3.1 Trigger

One key in the Author persona, plus a real menu item — every keystroke gets a
modeled delivery-path test (the slice-3 lesson: 22 green undo tests on a ⌘Z
that could not reach the stack). Candidate key **⌘R**, to be verified against
the live keymap (`MaughamApp`'s bindings) at plan time; deliberately not ⌘⌥D,
which only reveals the pane. While a run is in flight for the active document
the key is a quiet no-op; the pane header shows the running state. No dialog,
no selection, no ceremony.

The run key gets a brief acknowledgment flash in the ⌘S register —
muscle-memory-grade, sub-second — then nothing until notes stream into the
pane.

### 3.2 The delta

Per-document, per-device last-run marker = the newest `opId` the run saw,
stored in the diagnostics sidecar (§4.2). A run filters ops newer than the
marker — ULID order is canonical (`Deriver.opOrder`,
`Packages/MaughamCore/Sources/MaughamCore/Deriver.swift:30-41`); `Op.at` is
display-only and never consulted.

Every op already carries per-paragraph prior text
(`Op.ParagraphChange { paragraphId, prior, next }`,
`Packages/MaughamCore/Sources/MaughamCore/Op.swift:17-30`), and a burst's
coalesced `prior` is the pre-burst text
(`Maugham/OpLog/PendingBuffer.swift:93-95`). So the delta is a **pure function
over `[Op]`** — `DeltaBuilder` — with no replay:

- first-seen `prior` per ¶ since the marker = the text as of the last run;
  `nil` = the paragraph is new;
- the live `Document` (walked by `sequence`) = current text;
- **new and revised paragraphs are labeled differently in the prompt, with
  prior text attached to revisions** — a revision carries an implied goal, new
  prose answers only to intent (umbrella §4.1);
- paragraphs deleted since the marker are omitted — no prose to check;
- first run ever: the whole piece, all-new.

### 3.3 Context assembly

The prompt **embeds** the delta and the resolved intent — piece first, project
fallback, via the shipped `ProjectStore.statementText(of:)` (the single
spelling of ADR 0018's two branches). The pinned set (§7.2's union) and the
palette are **listed by id and title only**; the run pulls full contents
through the enumerated read tools (§3.5) when it judges them relevant. Cheap by
default, deep on demand.

On a warm session, context that changed between runs is **diffed in**: each
run's message carries intent-only-if-changed (hash compare), and the pinned/
palette listing only when it moved. Run N costs the new paragraphs, not the
world — and the session's accumulated context makes its feedback progressively
less generic.

### 3.4 The warm session

**Decision: a long-lived `claude -p` session, spawned lazily on the first run,
one message down stdin per subsequent run** (`--input-format stream-json`,
`--output-format stream-json`), so results stream into the pane as each
diagnostic is produced.

Lifetime rules (these are the outbound ADR's substance, §9.2):

- Entering Author never starts it; only the first run does.
- It dies immediately on: the AI toggle turning off, project close, app quit.
- It dies quietly after an idle timeout (~10 min without a run).
- Session death mid-run fails that run visibly once; the next run keystroke
  starts a fresh session. Self-healing, no state to repair.

**Fallback, pre-authorized:** if the warm process proves brittle in the spike
(§10 Task 0), per-run `claude -p --resume <session-id>` gives the same
context-reuse semantics (and prompt-cache hits) with simpler process
management. The runner lives behind a seam (§10) so the fallback is a swap, not
a rewrite.

### 3.5 The subprocess and its confinement

- `ClaudeCLIRunner` mirrors `TectonicInvoker`
  (`Maugham/Publish/TectonicInvoker.swift:40` — pipes, continuation,
  cancellation), locating `claude` by PATH probe (the
  `UpdateInstaller.swift:226-229` precedent — not bundled).
- Model from the per-project setting (§4.4), default Sonnet.
- `--mcp-config` scoped to Maugham's own server via the same bridge binary the
  setup sheet already installs.
- **An enumerated, read-only tool allowlist.** The membrane has write tools
  (`add_note`, `add_canvas_scraps`, `promote_inbox_entry`,
  `move_research_item`, `write_translation`, the publish writes); the compiler
  gets none of them, and nothing outside MCP (no Bash, no file access). The
  allowlist is a named constant beside the runner, and a test asserts every
  entry resolves to a catalog tool that is not a write.
- The run's output is its **final structured message** — the diagnostics list —
  which Maugham validates (¶ids against the live doc) and stores. No new MCP
  tool in either direction; the catalog stays at 55.
- `mcpEnabled == false` (`Maugham/Preferences/UserPreferences.swift:55-56`,
  enforced per-request at `Maugham/MCP/MCPServer.swift:233-241`) refuses the
  **spawn itself**, so the one toggle governs outbound as well as inbound.

## 4. Diagnostics

### 4.1 The model

A `Diagnostic`: ULID id, docId, anchor (¶id + the paragraph text as the run
saw it), body, an optional short free-form category tag from the model
("rhythm", "continuity", "intent" — display-only, for scanning the pane), and
its runId. **No severity levels** — a compiler with taste doesn't rank its
opinions; the writer does.

A **drift diagnostic** (§5.1) has no ¶ anchor.

Alongside them, a small run record: runId, date, model, delta summary, and a
**snapshot of the intent text the run checked against** — the one thing
unrecoverable later, and what promote-to-task carries.

### 4.2 The store

`DiagnosticsStore`, sidecar at
**`.maugham/diagnostics/<docId>.<deviceSlug>.json`** — per-device, because
`.maugham/` syncs across Macs and a single shared file written by two devices
is exactly tripwire 17's iCloud conflict-twin shape. Diagnostics are per-device
by nature (your run, on your machine); each device reads only its own file; the
last-run marker lives there too ("delta since *my* last run"). The filename
builder takes `DeviceSlug` (tripwire 24). Losing the file costs nothing
durable — promoted tasks and accreted intent are op-logged elsewhere.

Never the op log: no schema bump, no forced paired release, and an op log is a
permanent record of notes designed to evaporate. Persists across relaunch.

`@Observable` with an `annotationsVersion`-style monotonic counter — the pane
reads the counter and re-derives (`Maugham/OpLog/Document.swift:71`,
`Maugham/Views/AnnotationsPane.swift:80-82`); no NotificationCenter. Arrival
writes touch the store and the pane only — never the editor binding (tripwires
3, 6).

### 4.3 Lifecycle

**Dismissal is derived, not evented.** A diagnostic is live while its
paragraph's current text still matches its anchor text; the store filters
stale ones on read — the `Annotation.isStale` shape
(`Maugham/OpLog/AnnotationDeriver.swift:87`). A note arriving from a run
mid-typing lands already-stale if the writer has moved past it: uniform rule,
no race.

**Exact match is deliberately hair-trigger.** Fixing a typo dismisses the
paragraph's rhythm note too. Fuzzy matching is **rejected**: notes are cheap to
regenerate on the next run, and a note that survives edits is drifting toward
an annotation — the durable queue lives in the other loop (umbrella §4.3).

**A new run replaces the previous run's un-promoted diagnostics** for that doc.
"Ignore it" is literally doing nothing.

### 4.4 The pane

`DetailSegment.diagnostics`, **⌘⌥D**, Author's primary pane (registry:
`Persona.swift:216` gains it first; the enum's two exhaustive switches;
`DetailPaneToggle.segmentContent`'s no-default switch; the View-menu binding in
`MaughamApp.swift:218-241`; `PersonaPaneRegistryTests` matrix + canonical
order).

Rows: category tag, body, paragraph excerpt, click-to-jump to the ¶
(annotations precedent). A drift diagnostic pins at the top. Header: run state
(idle / running with notes streaming in / last-run line), Cancel while running,
and a quiet gear menu holding the per-project model setting (Haiku for speed,
Sonnet default, Opus for depth) — no per-run picker; a choice before every run
is the ceremony being removed.

Empty states say the truth: never run yet; clean run ("nothing to flag");
toggle off; CLI missing. No arrival banner — the pane is where you'd look, and
a banner announces what should merely be available. If the pane is closed when
notes land, the segment picker's existing unread-badge idiom says so, dimly.

### 4.5 Four fates

1. **Fix it** — the note dismisses itself when the prose changes.
2. **Ignore it** — gone on the next run.
3. **Promote to task** — `Document.createPaneTask`
   (`Maugham/OpLog/Document+Tasks.swift:247-249`) gains a `paragraphId`
   threaded through the `.taskCreate` provenance and `TaskDeriver`'s pane arm
   (`Maugham/OpLog/TaskDeriver.swift:337,360`), so the task is ¶-anchored like
   an inline task. Body = the note's text + a compact provenance line (run
   date, model, ¶id, the intent excerpt it was judged against). Adding a
   provenance *field* is additive; **the plan must verify no manifest schema
   bump is forced** — if one is, the field rides the next paired release and
   promote-to-task ships doc-scoped in the interim. **[judgment]**
4. **Answer it** — §5.2.

## 5. The intent loop — both directions

### 5.1 Drift: the compiler can say the intent is behind

Beyond the per-paragraph check, the prompt asks one standing question: *does
this delta suggest the declared intent is stale?* A drift finding is a
diagnostic with no ¶ anchor, pinned at the top of the pane, whose action opens
the Intent pane at the checked scope. It does not ¶-dismiss; it clears when
the intent statement changes or when the next run doesn't re-raise it.

### 5.2 Accretion: answering a diagnostic writes intent

Any diagnostic row can be answered — "that's deliberate, because…" — in a
reply field on the row. Committing the answer **appends the writer's words as
a new paragraph to the piece's intent statement**, minting the statement if
absent (consistent with the shipped absence-mints-nothing rule: an affirmative
act creates the file, no nag ever does). The append is an ordinary op-logged
edit performed by Maugham on the writer's action, routed the
`PromotionPerformer` way (validate-first, flush autosave, write through the
op log; the statement may not be open in any pane). **Claude never touches
it.** The answered diagnostic dismisses; the next run reads the intent the
writer just enriched.

**Scope rule [judgment]:** answers land in the **piece** statement (the scope
of the paragraph's document), not the project's — an explanation of "what I
was going for here" is piece-shaped, and the project statement stays a
deliberate, pane-edited artifact.

## 6. The Author surfaces

### 6.1 The intent strip

A single line above the prose, set in the editor's own face at footnote size,
dimmed to about the status footer's strength — a running head in a book, not
chrome. It shows the first line of the piece's intent (project's if the piece
has none), **skipping markdown headings** so `# Intent` never becomes the
signature; truncated with an ellipsis. Click opens the Intent pane at that
scope; the affordance appears only on hover. **No intent → no strip** —
absence is valid, and an empty strip is a nag wearing typography. Hidden in
⌘\ with the rest of the chrome. Implementation mirrors `EditorStatusFooter`:
`safeAreaInset(edge: .top)` on the content column, Author persona only.

### 6.2 References and the assistant column

`DetailSegment.references`, **⌘⌥E** — the pinned union (§7.2) as small
thumbnails and titles: a shelf, not a browser. Clicking a pin promotes that
one item into the **assistant column** between binder and editor at a width
you can study; clicking again, or promoting another, sends it back — **one at
a time**, because two studied references is a research session, not writing.
The column squeezes the centred writing column only while it exists; its width
persists per project.

This is `ProjectWindow` surgery near the type-checker ceiling: extracted
`ViewModifier`s, and a local **Release** build before any report (CLAUDE.md).

### 6.3 Author posture: none ships, on the record

The shell spec's §2 reserved an Author posture at M2 ("writing and answering
diagnostics both happen over the same paragraph"). **Finding: Author needs no
posture object.** Review's posture exists because its two jobs need different
*columns*; in Author, answering a diagnostic changes nothing structural — the
editor stays the editor, editable; adjudication lives in the pane; clicking a
note jumps to the ¶. A policy object with nothing to produce is ceremony.
Recorded here as an amendment-shaped finding against the shell spec's
expectation, reversible if M3's passes prove otherwise.

**Built as designed, 2026-08-05.** Plan 2 shipped the intent strip, References
and the assistant column with no posture object anywhere in the diff — the
finding held through implementation rather than only through design. Reversible
still stands as written, for M3.

## 7. The pinned set

### 7.1 What feeds it

The union, deduped:

- research↔manuscript links (the shipped `link_research` layer — a document's
  `links`);
- the canvas bridge: `RegionBinding.references(forPiece:in:)` residents;
- **[judgment, a widening]** cards whose *own* `boundPieceID` names the piece.
  A card explicitly associated with a piece is clustered-by-intent as much as
  a region resident. The widening happens **in the one shipped projection**,
  so the References pane, the compiler's context, and `list_canvas`'s
  `piece_references` move together — the app must not grow a second rule
  beside the projection (`RegionBindingTests` pins the caller; extend the
  projection's own tests).

### 7.2 Resolution

Residents are canvas nodes, not research items. They resolve: *referenced*
item nodes → the real research/palette item; *owned* photos → the photograph;
scraps → the scrap's own text as a pin. The same resolution feeds the
compiler's context listing.

## 8. Failure states

All honest, all in the pane, never a dialog:

- `claude` not on PATH → says so, points at setup.
- Not logged in / auth expired → the essence of stderr, not a spinner.
- Malformed / unparseable output → "the run produced nothing usable", logged,
  no retry theater.
- Timeout (~2 min budget; real runs are seconds on a warm session) → cancel
  and say so.
- `mcpEnabled` off → refused before spawn; the menu item stays enabled so the
  explanation is reachable rather than the command greyed into silence.
- Session death mid-run → fails once visibly; next run starts fresh.

**Neither the pane nor any message claims more than happened** — the
`add_canvas_scraps` write-reached-disk lesson applied.

## 9. The two ADRs

### 9.1 The compiler and must-not #2

Output location is the *identity* invariant: nothing AI-produced ever renders
in the editor or its chrome — the strip shows the writer's own words; the
diagnostics live in a pane. Invocation locality is a *position*: one keystroke
while writing is the constitution's own "permitted form of this pressure",
now with the trigger in the writing context. Amends the constitution's
boundary note so the line is never re-derived.

### 9.2 Maugham goes outbound

The one toggle governs spawn **and** session lifetime (§3.4's rules verbatim);
the spawned Claude runs under the enumerated read-only allowlist (§3.5) — the
membrane holds from the inside of the subprocess too. Records the warm-session
decision, its `--resume` fallback, and that runs bill the writer's own Claude
login.

## 10. Sequencing — one milestone, one release, ordered implementation

Denver, 2026-08-04: recent slices have been annoyingly small; this runs as
**one continuous milestone** on one branch. Order of construction (not gated
slices):

- **Task 0 — the spike, before any plan.** Verify empirically:
  (a) `--input-format stream-json` multi-turn + `--output-format stream-json`
  + `--mcp-config` + tool allowlist + model flag **compose** in one long-lived
  process; (b) **MCP socket concurrency** — whether `MCPServer` accepts a
  second simultaneous client (the compiler's Claude beside Claude Desktop), by
  reading the accept path and probing the dev socket if live. A spike failure
  re-routes to `--resume` (pre-authorized, §3.4) rather than re-litigating.
- **The loop**: `DeltaBuilder`, runner + session, store, pane, four fates,
  drift, intent-append. Smokeable alone; proves the milestone.
- **The surfaces**: strip, References pane, assistant column, projection
  widening.
- **The ADRs and doc sweep** (guide topics, AREA.md files, roadmap) ride the
  branch, not a follow-up.

Whole-branch review at the end — it has found a Critical in every one of the
last eleven slices. Merge to local main; **no push, no tag** until Denver's
smoke.

**2026-08-05:** the surfaces landed as this section anticipated — on the same
branch as the loop, `feat/m2-compiler-2026-08-04`, as Plan 2
(`docs/superpowers/plans/2026-08-05-m2-author-surfaces.md`), after Plan 1's own
whole-branch review closed. Both plans' ledgers live under
`.superpowers/sdd/2026-08-04-m2-compiler-loop/` and
`.superpowers/sdd/2026-08-05-m2-author-surfaces/`.

## 11. Out of scope

- Continuous/background runs — constitutionally excluded, not deferred.
- Review passes, readiness, annotation provenance fields — M3.
- Phone surfaces.
- The full-duplex bridge and `claude/channel` — separate hardening work.
- Diagnostics over research docs or statements — manuscript documents only.
- Multi-reference assistant layouts.

## 12. Testing

- `CompilerRunner` seam (the `Transcriber` pattern); integration tests drive a
  fake CLI script emitting canned stream-json — real pipes, no network.
- `DeltaBuilder` golden tests: coalesced bursts keep earliest prior; first run
  all-new; deletions omitted; marker advance.
- Prompt assembly: intent hash-diffing; new-vs-revised labeling.
- Parse/validation fixtures: malformed output; dangling ¶ids dropped.
- Staleness-derived dismissal against live text; replace-on-new-run.
- Promote-to-task round-trips through the real `TaskDeriver` (¶id survives).
- Intent-append: op-logged, correct scope, mints when absent; a planted
  offender proving Claude has no write path to statements.
- The run key: a real-delivery-path test (menu → command → runner).
- Registry censuses: pane matrix, canonical order, View-menu dispatch,
  `DocSyncTests`; allowlist-is-read-only census.
- Toggle-off refusal asserted at the runner, not the UI.
