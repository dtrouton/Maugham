# Compiler — Area guide

Maugham's **author compiler** (M2): the writer presses ⌘R, a warm `claude -p`
session reads what has changed since the last run, and its notes land in the
Diagnostics pane as ¶-anchored diagnostics. Read this before editing in
`Maugham/Compiler/`. Also read the project root `CLAUDE.md` for cross-cutting
invariants, and the design of record —
`docs/superpowers/specs/2026-08-04-m2-author-compiler-design.md`.

Two sentences hold the whole design:

- **The keystroke is the only trigger.** Nothing here reaches for itself. A run
  on every pause is the background linter the constitution excludes (must-not
  #2), and every timer in this area exists to end a session, never to start one.
- **The compiler reads and never writes.** It reads the manuscript through an
  enumerated read-only MCP allowlist and answers with a structured message. The
  one thing that puts words anywhere is `IntentAppendPerformer`, and its input is
  a sentence the writer typed.

## What this area owns

- The run: delta → prompt → session → parse → store (`CompilerOrchestrator`).
- The subprocess and its lifetime (`ClaudeCLISession`, behind `CompilerRunner`).
- What the compiler may reach (`CompilerAllowlist`).
- The diagnostics themselves: shape, per-device sidecar, staleness
  (`Diagnostic`, `DiagnosticsStore`, `DiagnosticIngest`).
- Where a note goes when the writer keeps it (`DiagnosticPromotion`) or answers
  it (`IntentAppendPerformer`).
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
| `CompilerPrompt.swift` | The message. Asks different questions of new and revised prose; carries intent + delta |
| `CompilerAllowlist.swift` | The enumerated read-only MCP tool list, as `--allowedTools` |
| `CompilerRunner.swift` | The seam: `send(message:systemPreamble:) -> CompilerRunEvent`, plus every way a run can fail |
| `ClaudeCLISession.swift` | The warm subprocess behind that seam |
| `DiagnosticIngest.swift` | The final structured message → `[Diagnostic]`, anchored against the LIVE document |
| `Diagnostic.swift` | `Diagnostic` + `CompilerRun` — the wire and sidecar shapes |
| `DiagnosticsStore.swift` | The per-device, per-document sidecar, and the staleness rule |
| `DiagnosticPromotion.swift` | What a kept note says once it is an op-logged task |
| `IntentAppendPerformer.swift` | An answered note becomes a paragraph of the piece's intent |
| `PinnedReferences.swift` | The pure union: linked research + clustered canvas cards, resolved to renderable pins |
| `PinnedReferenceResolver.swift` | The caller-side assembly against a live project — the four inputs `PinnedReferences.pinned` takes, gathered in one place |

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
  filenames and is never serialised into content.
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

- **Drift** — a diagnostic with no `¶` anchor, pinned at the top of the pane.
  Its action is **Open Intent**; it never offers a reply field, because drift is
  not about a paragraph and the honest answer is to edit the statement whole.
- **Accretion** — an anchored note offers **Answer**, and the writer's sentence
  becomes a new paragraph of the **piece's** intent statement (never the
  project's), minting it if absent. The answered note dismisses. The next run
  reads the enriched intent.

`IntentAppendPerformer` is `PromotionPerformer`'s shape with two deliberate
differences — no autosave flush, no project-scope fallback — both argued at
length in its own doc comment. Read that before adding either back.

**Claude has no route into a statement, and that is enforced rather than
intended.** The compiler reads the intent it is judged against; a model that
could also write it can move the standard until nothing it produced is ever
flagged again. The census above is what keeps that true as the catalogue grows.

## The four fates of a note

A diagnostic ends one of four ways, and only one of them is a button:

1. **Superseded** — the next run's diagnostics wholly replace the previous
   run's for that document. Un-promoted notes are dropped, not merged.
2. **Stale** — its paragraph's text no longer matches the text it was anchored
   to, so `DiagnosticsStore.live` stops returning it. Drift notes never go stale
   this way; they have nothing to track.
3. **Promoted** — kept as an op-logged task, which syncs and survives
   (`DiagnosticPromotion`).
4. **Answered** — became intent (`IntentAppendPerformer`).

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
- `CompilerPromptTests` — the prompt's two questions, and the wire-name
  agreement with `DiagnosticIngest.Field`.
- `ClaudeCLISessionTests` — the process, its arguments, and every path it has to
  die on.
- `DiagnosticIngestTests` — live anchoring, and a bad note never failing a run.
- `DiagnosticsStoreTests` — the sidecar, the staleness rule, the marker.
- `DiagnosticsPaneTests` / `DiagnosticPromoteToTaskTests` — the pane's states
  and the promotion, pressed through the real accessibility tree.
- `IntentAppendPerformerTests` — the answer flow end to end, including the two
  refusals that must write nothing.
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
(`IntentAppendPerformerTests.test_theReplyFieldCommitsOnReturnAndCancelsOnEscape`).
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
  `CompilerContext.pinnedListing`/`paletteListing` read the identical
  projection. Both still ship empty-capable, but the reason changed: the
  prompt omits an empty section by design, and today a document with nothing
  linked or clustered is the only thing that produces one — not an unbuilt
  surface.
- **An Author posture object.** Spec §6.3's finding: answering a diagnostic
  changes nothing structural — the editor stays the editor — so a policy object
  with nothing to produce would be ceremony. **Built as designed, 2026-08-05**:
  Plan 2 shipped Author with none, and nothing since has argued otherwise.
- **Streaming.** `CompilerRunEvent.started` exists for a streaming consumer that
  does not exist yet; `send` resolves with a terminal event.
- **A new MCP tool, in either direction.** The compiler is an MCP *client*. The
  catalogue did not move for M2.
