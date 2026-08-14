# M3 — Review earns its keep: named passes, the board, and rounds

*Brainstormed with Denver 2026-08-14. Supersedes the M3 sketch in
`2026-08-01-persona-shell-workflow-design.md`'s slice-6 closure where they
disagree; inherits its three recorded warnings (§7 below). Denver's answers
of record are inlined at each decision.*

## 1. The problem

Review is the one persona still borrowing everything it shows. Denver's
actual loop — a batch of review feedback per piece, his own notes joining a
queue, working it in batches, re-reviewing mid-way to check the changes
landed — is close to professional editorial practice, but Maugham holds
none of its structure: no notion of which *kind* of pass a piece is in, no
triage before work, no memory of rounds, and the project row in Review
still shows Author's corkboard (stage 3a's recorded degrade, "M3's queue
later").

Professional practice, adopted deliberately (Denver: *"I'm sure I'm missing
better approaches"*): ordered passes at one altitude of attention each
(structural → line → copyedit → proof), triage-before-work
(do / decline / discuss), three-valued answers (accept / reject / **stet**),
named rounds compared against the previous, and a fresh reader when
familiarity blinds.

## 2. Passes

- **Presets + custom** (Denver's choice): every project starts with
  Structural, Line, Copyedit, Proof — ordered — and can rename, add,
  delete, or reorder passes per project.
- `ReviewPass` is a typed value in MaughamCore: stable `id`, `name`,
  position by array order. The project manifest carries `reviewPasses:
  [ReviewPass]`; an ABSENT array decodes to the four presets (tolerant
  decode, tripwire 11 — no migration, old manifests just mean "the
  defaults").
- **Order advises, never blocks** (Denver's choice; constitution: lenses,
  not gates). Every pass is always available on every piece. When a later
  pass is worked while an earlier one is open on that piece, the queue
  shows a quiet note ("structure still open on this piece") — a visible
  nudge, zero enforcement, no confirm dialogs.

## 3. Per-piece state, and the old status string

- `StructureItem` gains `passStates: [String: PassState]` keyed by pass id.
  `PassState` is a typed enum — `.inProgress`, `.done`, `.skipped` — with
  the ADR 0015 unknown-case discipline. Absent means untouched.
  `.skipped` is the pass-level stet: "deliberately not doing this pass for
  this piece."
- **The free-string `status` stops being written** (Denver's choice:
  derive). The outline swatch and the inspector show a projection:
  nothing started → *draft*; anything open → *revising*; every pass done
  or skipped → *final*. A stored legacy string is the tolerant fallback
  when `passStates` is empty — read, never rewritten (tripwire 11), and
  the projection wins the moment any pass state exists. Tripwire 12
  applies: the projection is a typed enum with a rendering, not a second
  free string.

## 4. The board — Review's project altitude

Selecting the project row, a group, or nothing in Review fills the centre
with `ReviewBoardPane` — the same overlay-inside-`manuscriptEditor`'s-ZStack
discipline as the corkboard and Publish's book (never a new ViewBuilder
arm; the mount censuses grow by exactly one name). Author and Publish are
untouched.

- **Rows**: manuscript pieces in tree order, group headers preserved — the
  slice-6 inheritance's flattening objection answered by not flattening.
  Collection **reference** pieces render as thin chip-less rows (their
  status is cleared on convert; they do not participate).
- **Columns**: the project's passes, in order. **Chips**: per-(piece, pass)
  state — untouched / in progress / done / skipped. A trailing open-notes
  count per row (per-pass counts where annotations carry a pass stamp).
- **Chip click navigates** — that piece opens with that pass active and its
  queue filtered to it. **Chip context menu sets** — in progress / done /
  skip — satisfying the "a queue must ship with a way to SET status"
  inheritance without colliding with drag (drag still means reorder, and
  the board refuses drops).
- The active pass per piece is window state derived from the last chip
  interaction, persisted per project in ui-state; it stamps new
  annotations and compiler rounds (§6).
- **The ejection trap** (inheritance #1): nothing on the board or its
  click-throughs writes the persona. All navigation stays inside Review.

## 5. The queue — triage, stet, bulk, cross-document

Review's annotations pane grows into the working queue:

- **Triage** (Denver's choice): a per-annotation mark — *do* / *decline* /
  *discuss* — settable one-by-one or in bulk BEFORE working; absent =
  untriaged. The queue sorts triaged-*do* first, then document order.
  *Discuss* is the set you take to Claude.
- **Stet** joins Accept / Reject / Archive as a fourth resolution: "it
  stands, deliberately" — distinct from Reject ("wrong note"). Both triage
  and stet are **annotation ops** in the op log: history, undo (ADR 0023's
  conventions), and cross-device merge come from the machinery annotations
  already ride.
- **Bulk operations**: multiselect in the pane; accept-all / stet-all /
  triage-all over the current filtered set.
- **Cross-document view**: a scope toggle widens the pane from this-piece
  to all-pieces, grouped by piece — the board's open-notes counts click
  through into it.
- New annotations are stamped with the piece's active pass (optional field,
  additive; legacy annotations simply have none and appear in every pass's
  queue).
- Claude's half: `list_annotations` reports triage and pass; **Claude never
  sets triage or stet** — they are writer verbs, and MCP's write surface
  does not grow (§8).

## 6. Rounds, fresh eyes, and drift — the compiler's half

- **A round is a ⌘R** (Denver's choice) while a pass is active on the
  piece: the run records (pass id, round N) in the compiler's existing
  per-(document, device) diagnostics sidecar — durability contract
  unchanged: losing it costs continuity, never words.
- **Since last round**: the next report leads with resolved / persisting /
  new relative to the previous round — computed app-side from the sidecar
  and handed to the model in the briefing (the model confirms; it does not
  reconstruct). This is Denver's batch-then-re-review loop, formalized
  with no new ceremony: ⌘R stays the only trigger (M2's rule holds).
- **Fresh eyes** (Denver's addition): a run variant beside ⌘R — ends the
  warm session, starts cold, reads the piece whole, briefed on intent and
  rulings (the standard) but deliberately NOT on prior findings or rounds.
  Tagged as a fresh-eyes round in the sidecar and the report header. The
  professional fresh-reader, on demand.
- **Strip freshness = drift, judged** (Denver's choice, closing the
  M2-era held decision): each round's briefing asks one more question —
  has the draft drifted from the declared intent? A drift verdict lands in
  the sidecar and the intent strip carries a quiet "intent may trail the
  draft" mark until a run clears it or the statement is edited. No
  timers, no edit-distance heuristics, no nags. The compiler remains
  read-only; the mark is app-rendered.

## 7. Inherited warnings (from the 2026-08-01 spec's slice-6 closure)

1. **The ejection trap**: a reviewer clicking an annotation, history, or
   task row must never land in Author. The guard's spelling has changed
   since (persona-writer censuses, `showsManuscriptDocuments`), but the
   trap is behavioural: M3's board and queue write subjects, never
   personas, and the mounted tests must drive the real click paths.
2. **A queue ships with a way to set status** — §4's chip context menu.
3. **A new view, not a filter over the tree** — §4's board is its own
   pane; the tree is untouched. The reference-piece question is answered
   (thin rows, no chips).

## 8. MCP surface

Two widenings, zero new tools, zero new writes: `get_outline` gains
per-piece pass states and the derived status; `list_annotations` gains
triage and pass fields. Rounds and fresh eyes are keystroke-only. The
write catalogue stays at its current census (count `MCPToolCatalog.all`,
never this sentence).

## 9. The assistant column widens

Author-only becomes **Author + Review** (Denver's choice, closing the other
M2-era held decision): adjudication needs the pinned sources as much as
drafting does. One predicate spelling on `Persona`, the
`editsResearchInTheCentre` discipline; Plan and Publish stay without it.
The one-width rule is untouched.

## 10. Constitution check

- **Lenses, not gates**: order advises (§2); no pass is ever unavailable;
  no confirm dialogs.
- **The words are safe**: nothing here writes manuscript text; triage and
  stet are annotation ops; pass states are manifest metadata.
- **The compiler reads and never writes** (ADR 0028): rounds, fresh eyes,
  and drift are briefing and sidecar changes only.
- **Muscle memory**: ⌘R keeps its meaning (a round is what it always was,
  now remembered); no shortcut moves.
- **Nothing pushed**: the board renders state the writer set; the drift
  mark is quiet and clears on the writer's own action.

## 11. Sequencing — three plans

Rule 11/12 discipline: each plan under the task cap; **P1 is built before
P2/P3 are written**; whole-branch review per slice; merged unpushed;
Denver's smoke closes the milestone.

- **P1 — the spine and the board**: `ReviewPass`/`PassState` model +
  manifest/StructureItem fields + status projection + `ReviewBoardPane`
  with chip navigation and chip set-state + routing + inspector/outline
  projection reads.
- **P2 — the queue**: triage + stet ops and undo, pane sort, bulk
  operations, cross-document scope, pass stamping of new annotations.
- **P3 — the loop**: rounds + since-last-round briefing, fresh eyes,
  drift + the strip mark, assistant column in Review, MCP widenings,
  docs/guide sweep (incl. retiring the stale sub-paragraph-anchors
  roadmap row — spans shipped with WF1; verified against
  `AnnotationCreationTools.swift`).

## 12. Out of scope

- Inline gutter marks in the editor (stays on the roadmap).
- Collaborator roles / the author lock (WF2's).
- Per-pass readiness gates or any hard ordering enforcement.
- Any phone surface.
- Compiler-initiated runs of any kind (the keystroke rule stands).
