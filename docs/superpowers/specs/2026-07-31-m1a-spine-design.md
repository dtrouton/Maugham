# M1A — the spine: intent and visual language as one op-logged primitive

*Design, 2026-07-31. The last slice of M1. Supersedes nothing; implements §3 of
`2026-07-25-mode-based-ux-redesign-design.md` (referred to below as **the
umbrella spec**).*

---

## 1. What this milestone owes

The umbrella spec's §3 makes one structural claim: **intent and visual language
are the same kind of object**, and that object is new to Maugham.

> Freeform prose the writer produces naturally · op-log backed so it has history
> · with Claude deriving the checkable structure.

Three things follow, and all three are commitments of this slice:

1. **Intent becomes an op-logged artifact**, at project scope and per manuscript
   document. Freeform prose, never a form — §3.1 records why the named-slots
   alternative was rejected: *precise and measurable but nobody fills them in*.
2. **Visual language is the same object**, at project scope only. The book has
   one look.
3. **Visual language gets a consumer in this milestone.** This is M1's second
   named protection (§10) and it is currently unmet. Without it, visual language
   is an artifact that does nothing for three milestones. The cheap half is
   Claude *reading* visual language when authoring a template: an MCP read tool
   and a line in a skill.

**Why intent needs history, in the spec's own words:** review's job is to compare
a draft against *the intent you started with*. Craft intent today is a markdown
doc under `research/`, and research mutations are not op-log backed — so there is
no "as of when I wrote this chapter". Making it op-logged gives that baseline for
free, forever, **with no freezing ceremony**. History Rewind already renders this
UI.

---

## 2. The artifact

### 2.1 One type, two kinds

```
Statement
  id     — stable, minted once, never derived from a path
  kind   — .intent | .visualLanguage
  scope  — .project | .document(id)
  path   — project-relative, may change
```

It lives in a new `ProjectManifest.statements` section, alongside `structure` and
`research`.

`kind` and `scope` are not independent in practice — visual language is
project-scope only — but they are separate fields rather than a fused enum,
because §3.3 is explicit that these are *different objects that happen to look
alike*, and a fused `case projectIntent / documentIntent / visualLanguage` would
have to be reopened the moment a second project-scope kind arrives.

**Enum evolution follows ADR 0015**: `kind` and `scope` both decode
forward-tolerantly. A statement whose `kind` this build does not recognise is
retained and ignored, never dropped — the lossless shape `ResearchRole.unknown`
uses, not the lossy `Persona` shape, because a statement is the writer's prose
and there is something to preserve on behalf of the newer build.

### 2.2 Storage

Content lives in the open at the project root, following `canvas.md`'s precedent
(`CanvasStore.swift:11`); only derived state goes under `.maugham/`. This is the
plain-text hard invariant, not a preference.

| Path | Statement |
|---|---|
| `intent.md` | project intent |
| `intent/<slug>.md` | one per manuscript document |
| `visual-language.md` | project visual language |

`<slug>` is derived from the document's title at creation and never re-derived —
identity is the manifest `id`, and the path is free to drift from the title after
a rename. A statement's `path` moves through the typed `DocumentStore` mover
(tripwire 14) like any other user-editable content; nothing may `moveItem` it
directly.

### 2.3 It is a `Document`

Not "like" a document — the same `Document` actor, the same
`.maugham/ops/<id>.jsonl`, the same `Bootstrap.run`, the same `typingBurst` ops,
loaded through `Document.load` like every other manuscript load path (hard
invariant). What that buys, at no cost:

- **History.** `RewindCursor` / `RewindWindow` operate on any doc id. The
  baseline §3.1 asks for is the existing rewind UI pointed at a statement.
- **Undo.** ⌘Z reaches statement edits through the existing typing-burst path;
  `OpUndoRegistrar` needs no new inverse.
- **Cross-device merge.** Paragraph-keyed LWW by opId, per-device partitioned
  files, sealing — all of it, unchanged.
- **Conflict handling.** An external `.md` edit to `intent.md` is discarded and
  snapshotted under `.maugham/conflicts/`, exactly as for a manuscript.

**The one change the op log needs**: `resolveDocId` (`Document+Load.swift:307`)
resolves a doc id by matching the URL's relative path against
`manifest.structure`. A statement is not in the structure, so today it would fall
through to the path-hashed fallback `doc-<fnv1a64hex(relativePath)>` — and a
path-keyed id means a rename orphans the statement's entire history (tripwire
22). `resolveDocId` gains a `statements` lookup after `structure`.

That is the whole of this milestone's contact with `Maugham/OpLog/`, which the
area guide says is the cleanest in the codebase and must not be refactored
structurally. One lookup, in one function.

### 2.4 No new `OpKind` — the claim, and how to falsify it

The 1A handoff note asserts that a new `OpKind` bumps the schema and forces a
paired release. **We believe that is wrong**, and the belief is load-bearing
enough to state so it can be attacked:

> Carried as a `Document`, an intent edit **is** a typing burst. There is no new
> operation. `Deriver.appliesToManuscript`'s exhaustive switch gains no case,
> `OpUndoRegistrar` gains no inverse, `RewindCursor` learns nothing.

**How an implementer falsifies this**: add a statement, type into it, and assert
that the op appended to `.maugham/ops/<statementId>.jsonl` has
`kind == .typingBurst`, and that ⌘Z reverts it through the ordinary registrar. If
either needs a new kind, the claim is dead and the schema story in §2.5 changes
shape (though not conclusion — the manifest bump forces the paired release
independently).

**Authorship costs nothing either.** `Op.Provenance` already carries `sessionId`,
`prompt` and `toolArgs` (`Op.swift:34-36`), so a Claude-authored op is already
distinguishable from a writer's. M2's accretion path — *"you explain what you
were going for, and that telling becomes intent"* — is a new tool against an
unchanged shape, not a schema change to a shipped artifact.

### 2.5 Schema, and why the release is paired

`ProjectManifest.currentSchemaVersion` goes **3 → 4**
(`ProjectManifest.swift:29`).

The bump is not ceremony. `statements` decodes as an optional section, so an
older build would *read* the project happily — and then re-save the manifest
**without the section**, silently destroying the registry that points at the
writer's intent files. `decodeGuardingSchema` (`ProjectManifest.swift:112`) is
what prevents that: at schema 4 an older build refuses the project outright.

**Two independent reasons the Mac and phone ship together**, either of which
would suffice:

1. The schema bump. An older phone build refuses the project — refuses, not
   degrades.
2. **The phone reads intent today.** `MaughamPhone/Read/BinderView.swift:27`
   locates it via `PaletteLookup.craftIntentItem(in:researchPrefix:)`. When the
   artifact leaves the research tree that lookup returns nil and the Read tab
   quietly loses its intent section.

---

## 3. Scope resolution, and the death of a live defect

**Scope is project + any manuscript document.** A novel chapter, a collection
piece, a short story. A screenplay is a single `.fountain`, so it holds the
project statement only.

This is what M2's compiler needs — it type-checks the chapter you are writing,
and a novel-wide intent cannot say what chapter 9 owes. It is also what makes the
following defect unreachable rather than fixed.

**The defect (verified in source today).**
`ProjectStore.craftIntentItem(forPieceId:)` locates an existing intent doc by the
piece's research **path prefix** (`ProjectStore+CraftIntent.swift:56-62`), and
that prefix comes from `ResearchScope.pieceResearchPrefix`, which opens
`guard piece.pieceKind == .loose` (`ResearchScope.swift:139`). So for a novel
chapter the lookup returns nil — while `createCraftIntent` goes on to create,
routing through `.sharedPlusLink` into shared `research/`, where the lookup never
looks. The next promotion finds nothing and mints a second. The writer's
accumulated intent ends up silently in two files.

`PromotionPerformer.performCraftIntent` already carries a comment block
describing this from the inside (`PromotionPerformer.swift:498-512`) — it is a
known, documented, live defect that promotion works around rather than triggers.

**A statement is found by `scope`, in the manifest.** There is no prefix, so
there is nothing to be nil. `craftIntentResearchPrefix` and the
`ProjectStore+CraftIntent.swift` seam are deleted, along with the comment block
that explains the defect.

---

## 4. Surfaces

### 4.1 Two panes, through the registry

Two `DetailSegment` cases — `.intent` and `.visualLanguage` — and two entries in
`Persona.panes`. The registry already reserves exactly this shape
(`Persona.swift:79-82`): `.intent` → plan, author, review, publish;
`.visualLanguage` → plan, review, publish. Adding a right-pane surface is one
enum case plus one registry entry; it touches neither `DetailPaneToggle`, the
shortcut table, nor `ProjectWindow` — that is what the extension point is for.

`PersonaPaneRegistryTests.test_everyPersona_matchesTheDesignMatrix` checks the
whole matrix rather than a row, and the reserved comment block in `Persona.swift`
is edited down as these two land.

Each pane needs its `⌘⌥`-letter, joining the existing `⌘⌥I/R/O/A/H/T/B/P/L`
space, and a line in `docs/guide/reference.md` (guarded by `DocSyncTests`).

### 4.2 The mounted editor

**The pane mounts `EditorSurface`, not `EditorHost`.** `EditorSurface` is already
a clean seam — `@Binding var text: String` plus one grouped `configuration`
(`EditorSurface.swift:142-147`). A small `StatementEditorHost` owns the
`Document` and supplies exactly the sanctioned binding shape:

```
Binding(get: { doc.displayText }, set: { doc.setFullText($0) })
```

…and nothing else. That is what keeps tripwire 6 intact: a second host with a
single binding is not parallel observable state on the first one. There is
exactly one `EditorHost(` call site today (`ProjectWindow.swift:912`) and this
does not become the second — the pane's needs are a strict subset.

Configured for prose, with:

- **wiki links on.** `[[Chapter 9]]` in your intent resolves, and
  `list_all_links` / `find_references` already scan non-manuscript bodies as of
  1C-c2.
- **no element gutter, no focus dim, no typewriter scroll.** A pane is not the
  writing surface.
- **prose mode always.** A screenplay's intent is prose about a screenplay;
  Fountain tokenization never applies to a statement.

**This is the milestone's only genuinely new ground, and it is adjacent to the
codebase's most fragile seam** (tripwires 2, 3, 6, 7). It gets the treatment
tripwire 3's history earned: a test that drives the **real delivery path** — a
keystroke into the mounted surface producing an op on disk — not one that
hand-calls `setFullText`. A test that cannot fail when the mount is removed is
not a test of the mount.

### 4.3 Scope follows selection

The Intent pane shows the selected document's intent, or the project's when no
document is selected, with the other reachable in one click — a chapter's intent
and the book's are never further apart than that. Visual language is
project-scope, so it simply shows.

**Absence is valid and stays valid.** A scope with no statement shows an empty
editor that mints the file on first keystroke, not a "create intent" button and
not a nag. `read_craft_intent`'s existing description already tells Claude that
absence is *"a valid, deliberate state — do not invent a standard on their
behalf"*, and the UI must not contradict its own MCP surface.

---

## 5. Adoption of existing craft-intent notes

Once per project, on open: an existing craft-intent research note's markdown
becomes the statement's **bootstrap op**, and the note leaves the research tree.

This is the op log's sanctioned import read — the path `Document.load` already
takes for a brand-new or imported plain file with an empty op log
(`Document+Load.swift`, the `needsBootstrap` branch). It is the only migration
shape this codebase already trusts, and it means adopted intent arrives with
history that starts at adoption rather than with no history at all.

**Duplicates are concatenated, oldest first**, separated by a blank line — the
defect in §3 has been minting second copies, and picking a winner would discard
the writer's prose. Concatenating is recoverable; choosing is not.

Detection is role-first (`ResearchRole.craftIntent`) with the legacy filename as
fallback, mirroring `craftIntentItem`'s existing two-tier lookup, so a note the
writer renamed is still found.

Adoption is **idempotent and once**, and the gate is the on-disk schema version:
it runs when the manifest reads `schemaVersion < 4`, and the post-adoption save
writes 4. A project last written by a schema-4 build is never re-scanned. Gating
on "has a `statements` section" instead would be ambiguous for a project that
legitimately has none — a writer who has never declared an intent — and would
re-scan it on every open.

---

## 6. Consumers

Every existing consumer of craft intent moves in this slice. Leaving one behind
means intent written in one place and read in another. **Count them at the call
sites rather than trusting this list.**

### 6.1 Promotion

`PromotionTarget.intentStatement` keeps its name, its precedence rules
(`Promotion.piece`) and its behaviour. Only the destination resolves differently:
`performCraftIntent` (`PromotionPerformer.swift:498`) finds the statement by
scope and appends through the op log rather than reading, joining and rewriting
the file.

Appending through the op log **removes the flush dance** — the current
implementation must `flushPendingSave()` before reading the body so that what it
appends to is what is on disk. An op-log append has no such hazard.

The intent arm's `plan.contributors` handling is unchanged.

### 6.2 The phone

The phone's Read tab reads project-scope intent
(`MaughamPhone/Read/BinderView.swift:27`, `Read/PaletteLoading.swift:32`). It
moves to the statements section through a **shared `MaughamCore`
implementation** — tripwire 19: the phone must not reimplement what the Mac
implements, and the reach-around grep tripwires catch the known bad spellings.
The lookup is `MaughamCore`'s; both surfaces call it.

The phone reads statements; it does not edit them in this milestone.

### 6.3 MCP

- **`read_craft_intent` widens.** It already takes an `item_id`; it simply cannot
  answer for a novel chapter today. Widening an existing read leaves the tool
  count at **54**, as `list_all_links` did in 1C-c2. Its description gains the
  new scope and keeps its absence-is-valid sentence verbatim.
- **`read_visual_language` is new.** 54 → **55**. Project scope, returns the
  prose plus the referenced image paths. Derive the count from
  `MCPToolCatalog.all`; a new tool breaks at least three tools-list tests, which
  is expected and is the catalogue doing its job.
- **A section in `docs/skills/maugham-bootstrap/SKILL.md`** telling Claude to
  read visual language before authoring a LaTeX or CSS template. That skill is
  already the router and already carries task sections. **No new skill**: there
  is no publishing skill today, and M4 owns the real publish surface. The section
  is intent-first, not procedural — a deliverable and what matters, not a
  numbered recipe (see `feedback_skill_authoring_intent`).

**Claude cannot write intent in this milestone.** Writes stay `add_note` and
`add_canvas_scraps`. The manuscript half of the MCP membrane never softens, and
this slice does not soften the planning half either.

### 6.4 `list_canvas` learns the reference projection

`RegionBinding.references(forPiece:)` (`RegionBinding.swift:35`) has **zero
production callers**, verified today. Its two rules are not obvious and neither
is stated anywhere a reader would find it:

- **Residents only** — a card merely visiting a region's rectangle is cited, not
  owned; otherwise two overlapping regions each claim the same card as their
  piece's context.
- **Unioned across regions** — more than one region may bind to the same piece.

Meanwhile `list_canvas` already reports `bound_piece_id` on both nodes and
regions (`CanvasTools.swift:73, 96`), shipped in 1C-c3. So the **data** is live
and the **rule** is dormant — which is worse than an unused function: a reader
deriving a piece's references from raw `bound_piece_id` will include visitors,
because nothing tells it not to.

`list_canvas` therefore reports a piece's references **as the projection defines
them**. This is a widening of a shipped tool, not a new one; the count does not
move.

**The References pane stays in M2.** The umbrella spec's §10 assigns *"the intent
strip, pinned references and the assistant column"* to M2 explicitly. The claim
that the rail is 1A's work comes from `RegionBinding.swift:7` — *"Produced here,
consumed in 1A"* — written in 1C-b, and it is corrected in this slice. The
`.references` segment reserved in `Persona.swift` stays reserved.

> **Correction, Task 10.** This paragraph also said the comment *"cites §4.4,
> which does not exist: §4 stops at 4.3 and the sentence it quotes is §8's."*
> **That is false and was not implemented.** §4 stops at 4.3 in the *umbrella*
> design; the § belongs to the **planning-canvas** design, whose §4.4 is
> *"Regions bind to pieces — this is the bridge"* — the section the comment
> paraphrases, and the one that quotes the sentence from umbrella §8 and
> attributes it. Every bare § in `Maugham/Canvas/` is the canvas spec's, by that
> area's long-standing convention. The citation was right; only the milestone
> claim was wrong. `RegionBinding.swift`'s comment now names the spec explicitly
> so the check is not repeated.

---

## 7. Images in visual language, and the saver

§3.2 says visual language is **mixed — images, references and prose**. A mood
board you cannot paste an image into is the wrong shape for the one artifact
whose subject is how the book looks. So visual language ingests images.

That makes this slice a **new caller of
`ImagePasteHandler.saveAndReferenceFile`, which validates nothing** — recorded in
the 1C-d handoff, and confirmed here: `ProjectStore.ingestCanvasAsset(fileURL:)`
is itself one of its callers (`ProjectStore+CanvasAssets.swift:55`), so there is
no already-validated ingest to reuse. The canvas's own check sits upstream in
`DropClassification`; the palette card and research note have none, so a `.txt`
dropped on either very likely still ingests.

**The saver is fixed here, at the saver**, and every caller is re-checked
together in one pass — enumerate them from the call sites, not from this
sentence. Then it is decided whether the canvas's upstream check is redundant or
defence in depth. Becoming a new caller is what makes this ours rather than a
ticket; a fourth unvalidated caller is how it stops being fixable in one pass.

---

## 8. Out of scope

Named so they are not silently absorbed:

- **The References pane and the assistant column** (§8 of the umbrella spec) —
  M2, per §10.
- **The intent strip** above the prose in Author — M2, per §10.
- **The authoring compiler** reading intent — M2. This slice produces the type
  signature; nothing type-checks against it yet.
- **Readiness** (§9's *"two pieces have no intent recorded"*) — a later
  milestone's consumer of intent's existence.
- **Claude writing intent** — designed for (§2.4), not built.
- **Recorded derived design decisions** — visual language's second half, which
  §10 keeps in M4. This slice ships the read; M4 ships the write-back.
- **Inline task derivation on a statement.** A `Document` derives `- [ ]`
  checkboxes into tasks, but the Tasks pane enumerates structure documents, so a
  checkbox in an intent produces anchors nothing displays. Harmless; pin it with
  a test rather than building a feature.

---

## 9. Risks, and what catches each

| Risk | Catch |
|---|---|
| The mounted `EditorSurface` binds wrongly and loses keystrokes (the tripwire 3 / 6 / 7 family) | A test driving the **real delivery path** — keystroke into the mounted surface → op on disk. Paired with a disable experiment that **asserts its patch applied**. |
| A statement's history is orphaned by a rename | `resolveDocId` resolves through the manifest `id`; a rename-then-reopen round trip is asserted (tripwire 22). |
| Adoption runs twice, or concatenates a note into a statement that already has content | Idempotency asserted on second open; adoption gated on the on-disk `schemaVersion < 4`, so a writer with no intent at all is not re-scanned forever. |
| The phone and Mac disagree about where intent lives | One `MaughamCore` implementation, called by both; round-trip integration test is the real net, the reach-around greps catch the known bad spellings. |
| An older build silently drops `statements` on re-save | Schema 4 + `decodeGuardingSchema`; asserted by a refuse-to-open test against a schema-4 fixture. |
| The saver fix breaks an existing ingest path | All callers re-checked in one pass, each with its own assertion; the canvas drop path gets a smoke. |
| Tool count drift | Derived from `MCPToolCatalog.all`, never a literal — the lesson from the publish-pipeline milestone. |

---

## 10. What was verified in the tree on 2026-07-31

Everything below was read out of the working tree the day this spec was written.
Anything not on this list is a claim to be checked, not a fact.

- `ProjectManifest.currentSchemaVersion = 3` — `ProjectManifest.swift:29`;
  `decodeGuardingSchema` at `:112`.
- `resolveDocId` matches against `manifest.structure` only, with a path-hash
  fallback — `Document+Load.swift:307-339`.
- `OpKind` is a closed set with an `.unknown` decode fallback, and adding a case
  requires a manifest bump — `OpKind.swift`.
- `Op.Provenance` carries `sessionId`, `prompt`, `toolArgs` — `Op.swift:34-36`.
- `craftIntentItem(forPieceId:)` resolves via a research path prefix —
  `ProjectStore+CraftIntent.swift:56-62`; `pieceResearchPrefix` is
  `guard piece.pieceKind == .loose` — `ResearchScope.swift:139`.
- `performCraftIntent` documents the resulting split-intent defect —
  `PromotionPerformer.swift:498-512`.
- `RegionBinding.references(forPiece:)` has zero production callers —
  `RegionBinding.swift:35`; its doc comment claims 1A consumes it — `:3-11`.
  **Corrected 2026-08-01 (Task 10):** this entry also said the comment "cites a
  non-existent §4.4". That was wrong, and wrong in the way this list exists to
  prevent — it was checked against the umbrella spec, but a bare `§` in
  `Maugham/Canvas/` refers to the **planning-canvas** design, whose §4.4 is real,
  is titled for this bridge, and quotes the umbrella §8 sentence while saying so.
  The milestone half of the claim stands and was corrected in the code: umbrella
  §10 assigns pinned references to M2, and what 1A gave the projection is a
  *reader*, not a rail. The disambiguation now lives in `RegionBinding.swift`
  itself, because two readers made the same mistake three weeks apart.
- `list_canvas` reports `bound_piece_id` on nodes and regions —
  `CanvasTools.swift:73, 96`.
- `Persona.panes` reserves `.intent` and `.visualLanguage` —
  `Persona.swift:79-82`; `.references` at `:80`.
- `EditorSurface` takes `@Binding var text: String` plus one configuration —
  `EditorSurface.swift:142-147`; one `EditorHost(` call site —
  `ProjectWindow.swift:912`.
- `canvas.md` is at the project root — `CanvasStore.swift:11`.
- `ingestCanvasAsset(fileURL:)` calls `ImagePasteHandler.saveAndReferenceFile` —
  `ProjectStore+CanvasAssets.swift:55`.
- The phone reads craft intent through `PaletteLookup.craftIntentItem` —
  `MaughamPhone/Read/BinderView.swift:27`, `Read/PaletteLoading.swift:32`.
- `docs/skills/` holds `editing-pass`, `maugham-bootstrap`,
  `transcribing-notebooks`, `translation-pass` — no publishing skill exists.
- Umbrella spec §4 ends at §4.3; §10 assigns pinned references and the assistant
  column to M2.

---

## 11. How the slice is run

Carried forward from 1C-d, where each of these cost a task:

- **Build the first half of the plan, then re-derive the second against the built
  code**, as a task in the plan rather than a split milestone. Measured on 1C-d:
  the re-derived half's ~90 signature citations were checked and zero were wrong;
  the pre-written half was corrected four times.
- **Cap the plan at ~10 tasks.** Past that, split it.
- **A plan carries contracts, symptoms and verified signatures — never function
  bodies.** Quote a signature only if you read it out of the tree that day, and
  cite `file:line`.
- **Refusing a stated ruling you can falsify is the standard**, and dispatch
  prompts say so. §2.4 exists to be attacked.
- **Reviewers write their verdict to a file before replying.**
- `./gen.sh` before any count you quote. `-only-testing` with a folder-shaped
  path runs zero tests and exits 0.
- **A disable experiment must assert its patch applied.**
- **Whole-branch review before merge**, after the per-task reviews. It has found
  a Critical no per-task review could see in every slice of this milestone.

**M1 is complete when 1A is in** — then the whole-milestone smoke, then M1C's
roadmap `~` flips to ✓, then the paired Mac + phone release. Not before.
