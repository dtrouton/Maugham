# ADR 0029 — The compiler's report is materialized

**Date:** 2026-08-17 · **Status:** Accepted · **Milestone:** m4-p1-the-wire-and-the-briefing (branch `feat/m4-p1-the-wire-2026-08-17`)

## Context

[ADR 0028](0028-maugham-goes-outbound.md) §3 recorded, correctly, that the compiler's
spawned `claude -p` "cannot write anything" — no tool in its allowlist mutates a
manuscript, and no statement-writing tool exists in the allowlist or the catalogue at
all. Through M2 and M3-P3 that sentence and *"nothing the compiler produces is
durable"* were the same fact, because every finding a run raised was a `Diagnostic`
in a per-device sidecar the next run wholly superseded. "Reads and never writes" read
naturally as "produces nothing that outlives the check."

`docs/superpowers/specs/2026-08-17-one-loop-two-tempos-design.md` (§2–§3), written
after Denver's first real smoke on *Playlist* under M3, breaks that identity on
purpose. His correction: a finding that is a note *on the prose* — a continuity
question, a reader's report — is not report material. It is an annotation: durable,
op-logged, synced, disposed of with the same do/decline/discuss/accept/reject/stet
vocabulary as every other margin note, exactly because a reader who disagrees with a
reader's report has no button for that today and a declined-in-spirit finding
recurs forever with no memory of the writer's answer. Spec §2's table is explicit:
*"A finding that is a note on the prose is an annotation… nothing is ever mirrored
across the two."*

M4 P1 Task 3 (`859aacb6`) built the wire: `Environment.mintAnnotations`
(`CompilerOrchestrator.swift`, wired in `CompilerEnvironment+Project.swift`) writes a
continuity question or a reader's report as a pass-stamped, op-logged `Annotation` —
`Document.addAnnotation`, called by Maugham's own code, after the turn has finished
and the whole message has been parsed (`DiagnosticIngest.parseAll` →
`SectionedOutcome.mintable` → `[CompilerNote]`). That is a durable write reachable
from a compiler run. Read next to ADR 0028 §3's sentence in isolation, the two look
like they disagree. They do not — the write is Maugham's act, not the model's, and it
happens after the model's turn is over — but that distinction is exactly the kind
this project's ADR discipline exists to put on the record rather than leave to be
re-derived by the next reader who greps for "the compiler reads and never writes"
and stops there. This ADR is that record. It amends 0028 §3's *framing*; it changes
nothing 0028 §2's confinement table or §3's censuses decided.

## Decision

### 1. The compiler reads and never writes. Maugham does the writing — at ingest, after the parse, from the finished report.

The spawned Claude's tools remain exactly what ADR 0028 §2 described: an enumerated
`--allowedTools` list that pre-approves reads, `--tools ""` emptying the built-in
set, `--strict-mcp-config` plus a per-session `--mcp-config` naming only Maugham's
own catalogue. No entry in that list, and no tool in the catalogue it draws from,
appends an op, mutates a paragraph, or writes an annotation. What changed is what
happens to the model's answer *after* it is fully returned: `CompilerOrchestrator`
parses the whole turn (`DiagnosticIngest.parseAll`, never a partial stream —
`DiagnosticsStore.preview` is explicitly weaker than `replace` for this reason) into
typed values with no further agency of their own — a `Diagnostic`, a `CompilerNote`,
a `BibleFact` — and Maugham's own code decides where each one goes. The model never
calls `add_comment`, never calls `add_note`, never touches the annotation layer
directly; it returns a structured message over stdout, and the write happens on this
side of the process boundary, in ordinary Swift, driven by what section the finding
arrived in.

**The amended sentence, stated once so it can be cited rather than re-derived:**
*the compiler reads and never writes; its parsed report is materialized by Maugham
into the layers the writer already governs.*

### 2. Annotations are the third materialization, not the first — the report was always parsed and placed, never handed to the writer raw.

M2 already did this for two of the three finding shapes, and nobody argued about it
at the time because neither destination is prose the writer could mistake for their
own voice appearing unbidden:

- **Bible facts** (`BibleFact`/`BibleStore`, spec §3.3, ADR 0027's amendment) — a
  fact-candidate a run reads off the manuscript lands silently in a per-device
  ledger, and only the writer's own bless/correct/dismiss in the Intent pane's
  Bible stratum promotes or discards it. Never truth on arrival.
- **Promoted tasks** (`DiagnosticPromotion`) — a kept conformance-strain note becomes
  an op-logged task carrying the note's words plus one line of provenance. The
  *writer* presses Promote; Maugham does the writing the button asks for.

Continuity questions and reader reports (M4 P1) are the third: a note-natured
finding, parsed out of the model's structured answer, written by Maugham as a
pass-stamped `Annotation` the instant the run finishes
(`CompilerMintContext`/`mintAnnotations`, `Maugham/Compiler/CompilerNote.swift`).
It is authored `sourceKind: .claude` — the same `isClaude` label every existing
Claude-sourced annotation already carries from Desktop's `add_comment` — with a
`displayName` naming the pass's editor (Perkins/Lish/Gould/Argus, or "Claude" for a
passless run), and it carries run provenance (`compilerRunId`, `compilerRound`,
`compilerFreshEyes`, `compilerFingerprint`) so a later round can recognise it without
re-reading its prose. It is otherwise an ordinary annotation from the moment it
lands: the writer accepts it, rejects it, stets it, discusses it, or bulk-disposes it
exactly as they would a note Claude Desktop wrote through `add_comment` — because
that tool call, not the compiler, is the annotation layer's designated inbound
channel, and materializing a compiler finding into the same layer is reusing that
channel rather than opening a second one.

**What still admits only a writer-typed sentence, unchanged.** The one route from a
finding into a *statement* — the yardstick the compiler is judged against — is
`RulingPerformer.rule`, and its input is a `String` the writer typed, whether that
string answers a conformance strain in the Diagnostics pane
(`DiagnosticsPane.commitAnswer`) or blesses a bible fact
(`BibleStratum.graduate`). Neither call site changed with this milestone.
Materialization reaches the annotation layer and the bible; it has never reached,
and still cannot reach, the statement.

### 3. Nothing ADR 0028 §2 or §3 decided moved.

- **The two-flag confinement table is unchanged** — `--allowedTools` pre-approves,
  `--tools ""` empties the built-in set, `--strict-mcp-config` plus a per-session
  `--mcp-config` scope the MCP surface to Maugham's own catalogue alone.
  `ClaudeCLISessionTests.test_spawnArgumentsMatchTheSpike` still asserts both flags
  by parsing argv, not `split`, because the empty-string value only survives
  `components`.
- **The allowlist censuses are unchanged and still guard the annotation layer
  specifically.** `CompilerAllowlistTests.test_noWriteToolIsAllowed` and
  `test_theCensusWouldCatchAWrite` assert that no entry in the allowlist resolves to
  a catalogue write — `add_comment`, `add_query`, `add_note`, `add_canvas_scraps`,
  `promote_inbox_entry`, `move_research_item`, `write_translation`, the publish
  writes, none of it — each with a planted-offender companion so the assertion
  cannot go quietly unfalsifiable. M4 P1 added no tool to the allowlist and touched
  none of these tests to pass.
- **The statement prohibition is unchanged.** `CompilerAllowlistTests.
  test_noStatementWritingToolExistsAnywhereClaudeCanReach` and
  `test_theStatementCensusWouldCatchAWriteToIntent` still hold: no
  statement-writing tool exists in the allowlist *or* the catalogue the spawned
  model can reach, so a model that could move the standard it is judged against
  remains impossible by construction, not by convention.

### 4. The falsifiable clause.

**If the spawned model ever gains a tool that writes an annotation — directly, from
inside its own turn, rather than through Maugham parsing its finished answer and
deciding the write — this decision is violated.** The test today is the same shape
as ADR 0028 §2's: prove the *removal*, not the documentation. The writes this ADR
describes are the app's, made after the process has exited its turn, from typed
values with no tool-calling capability of their own (`Diagnostic`, `CompilerNote`,
`BibleFact`); an `add_comment`/`add_query`/`add_note` entry appearing in
`CompilerAllowlist` — or the model reaching any of them through a widened MCP
surface not enumerated there — would mean the model itself is authoring what lands
in the writer's queue, which is exactly what §3's censuses exist to make impossible
and what this decision says must never become possible.

## Consequences

- `Maugham/Compiler/AREA.md`'s "four fates" section, written when every finding was
  a `Diagnostic`, is amended in the same commit as this ADR: a conformance strain
  still has the four fates as described (superseded / stale / promoted / answered);
  a continuity question and a reader's report no longer reach the sidecar at all,
  and their fate is the annotation layer's own lifecycle from the moment they mint.
- `CLAUDE.md`'s Compiler cell is corrected in the same commit: it previously said
  continuity questions and reader reports land in the Diagnostics pane (no longer
  true) and that answering either becomes a ruling (only a conformance strain does,
  as of M4 P1 — a continuity question is disposed of in the queue like any other
  annotation, never through `RulingPerformer`).
- A future materialization — a fourth finding shape, or a new destination for an
  existing one — inherits this ADR's test at design time: does Maugham write it
  after parsing a finished turn, from a typed value the model cannot itself hand a
  tool to mutate? Yes is this pattern continuing. A tool call from inside the
  model's own turn that writes anything durable is a different feature and this ADR
  says so on the record.

## References

- `docs/superpowers/specs/2026-08-17-one-loop-two-tempos-design.md` §2 (findings
  routed by nature), §3 (the constitutional accounting this ADR formalizes)
- `docs/superpowers/plans/2026-08-17-m4-p1-the-wire-and-the-briefing.md` — Task 3
  (the mint), Task 7 (this ADR)
- [ADR 0028](0028-maugham-goes-outbound.md) §2 (the two-flag confinement table,
  unchanged), §3 (the framing this ADR amends)
- [ADR 0027](0027-the-compiler-and-the-editor-boundary.md) — the Bible/derived-world
  amendment this ADR's §2 cites as the first materialization precedent
- `Maugham/Compiler/CompilerNote.swift` — the value that crosses the seam
- `Maugham/Compiler/CompilerOrchestrator.swift` — `Environment.mintAnnotations`,
  `Environment.recordFacts`
- `MaughamTests/CompilerAllowlistTests.swift` — the censuses cited in §3
