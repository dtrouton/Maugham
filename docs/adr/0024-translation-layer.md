# ADR 0024 — Translation layer: a second Claude-parallel data plane

**Date:** 2026-07-22 · **Status:** Accepted · **Milestone:** translation-layer (branch `feat/translation-layer`)

## Context

Maugham's founding membrane — "the manuscript is yours, full stop; Claude operates in a
parallel annotation layer" — was built for one relationship: Claude proposing changes to
a single-language manuscript, the writer disposing of each proposal. Producing a
translated edition doesn't fit that shape at all: a translation isn't a proposed *change*
to the source text (there is nothing to accept or reject sentence-by-sentence — the
whole point is that the source stays exactly as written), and it isn't research either
(it's derived from, and must track, the live manuscript). It needed its own membrane, not
a stretch of the annotation one.

The constitutional constraint this had to satisfy: "MCP never mutates manuscript text
directly" (CLAUDE.md hard invariant; `docs/constitution.md`'s *identity* principle) and
"plain text on disk, full stop" for anything that IS the manuscript. A translation is
neither the manuscript nor an edit to it — it needed a plane where that distinction is
structural, not a convention Claude is trusted to honor.

## Decision

### 1. A second parallel data plane, structurally identical to the annotation layer's
   membrane, keyed to paragraph identity instead of proposal identity.

`TranslationRecord` (MaughamCore) is a per-paragraph, per-language wire record —
`paragraph_id`, `language`, `text` (or `verbatim: true`, meaning "copy the current source
unchanged"), and a `source_hash` stamped by the server at write time. Storage mirrors the
annotation layer's own precedent: per-device JSONL under `.maugham/translations/`
(`<docId>.<language>.<deviceSlug>.jsonl`), newest-`opId`-wins merge, tripwire 17's
partitioning discipline applied verbatim (never a single shared file across devices).
`write_translation` is MCP's only writer into this plane; it is exactly as far from
manuscript mutation as `add_note` writing under `research/` — a new plane, not a loosened
rule.

### 2. Freshness is derived, never stored — with server-stamped hashes as the join key.

A translation record does not carry a `fresh`/`stale` flag. `TranslationDeriver.derive`
computes it on every read by comparing the record's `source_hash` (stamped by the server
at `write_translation` time, from the CURRENT source paragraph, resolved the tripwire-20
way — open doc → live `Document`, closed doc → `DerivedManuscriptCache`, never the
on-disk `.md`) against `TranslationHash.hash` of the paragraph's live text. An edit to the
source paragraph after translation flips it `stale` by construction — no explicit
invalidation step exists to forget.

`TranslationHash.normalize` strips anchors, trims per-line trailing whitespace, and trims
outer whitespace before hashing. **Accepted caveat:** an edit that changes ONLY trailing
whitespace — including a Markdown two-space hard break — does not flip staleness. This
was a deliberate choice (a hard-break-only edit is not something a translator needs to
re-see) over the alternative of false-positive staleness on every incidental
trailing-space fix.

### 3. `write_translation` is all-or-nothing, and Claude never invents a hash.

A batch either writes every entry or none (an unknown paragraph id — the client sent a
stale set — rejects the whole batch); duplicate paragraph ids within one batch are
rejected as a client bug, not silently last-write-wins. `verbatim: true` entries copy the
CURRENT source text server-side rather than trusting the caller's copy, so verbatim chrome
(sluglines, scene numbers, standalone numerals a translator leaves as-is) can never drift
from the source by a stale round-trip. Non-verbatim entries are checked for structural
drift against the source (`ConstructSkeleton` — a dropped `**bold**` run, a changed block
shape) and returned as warnings; this is a tripwire for the caller to heed, not an error,
because some drift (a shortened idiom, a restructured sentence) is legitimate translation.

### 4. A blocking coverage gate stands between "some paragraphs are translated" and
   "this is a published edition."

`compile(language:)` and `republish` both run `TranslationCoverage.check` — walking the
same pieces `ProjectStoreASTSource.orderedPieces()` compiles — and refuse (structured
`translation_stale`/`no_translation_layer` errors, itemized per piece) when any
non-blank paragraph is `stale` or `missing`, UNLESS `allow_stale: true` demotes the gaps to
warnings and falls back to source text for the untranslated paragraphs. A zero-layer guard
additionally refuses unconditionally (even under `allow_stale`) when a language has NO
translation records at all anywhere in the project — the alternative would let a plain
relabel of the source book pass as a translated "edition," which is a labeling deception
the gate exists specifically to prevent. Both callers share ONE `TranslationCoverage
.applyGate` switch (Task 9 round 5 fixed a real drift between two independent
reimplementations) — this is not a suggestion; a THIRD reimplementation is the same class
of bug recurring.

Fountain pieces additionally get an element-drift warning: if the translated text
tokenizes to a different screenplay-element sequence than the source at the same position
(a slugline translated into plain action, say), `compile` surfaces it — this is checked
only on fully-covered pieces, where the two texts differ by nothing but translation.

### 5. `Publication` carries `language`/`allowStale` as provenance; `republish` reproduces
   the ORIGINAL edition, gate mode included.

A compiled edition's `Publication` record stores the language it was compiled for and
whether `allow_stale` was in effect, alongside the frozen `PublicationSnapshot` (template +
config + styles bytes) every compile already captures. `republish` reads `prior.language`
and `prior.allowStale` and re-runs the SAME gate mode against CURRENT translation state —
it does not silently relax to blocking-with-no-allow_stale, and it does not silently carry
forward `allow_stale` into a republish where the writer never asked for it. Reproducing an
edition means reproducing its provenance, not just its bytes.

### 6. Language-suffixed templates are Maugham's resolution rule; template CONTENT is the
   writer's job, and the gate does not cover it.

`LanguageSuffixedFile.resolve("template.tex", language: "es", …)` returns
`template.es.tex` if that file exists beside the base, else falls back to the base file —
applied to the PDF template, EPUB `styles.css`, and each piece's `style_file` (rewritten on
the orchestrator's EDITION-EFFECTIVE config, before snapshot + emit, so the shared on-disk
config's base filenames are untouched). This is a resolution convention, not a template
generator: Maugham does not write a translated template for the writer, and — stated as an
honest boundary, not a gap to be quietly filled later — `\input` partials referenced
*inside* a `template.es.tex` (e.g. a `frontmatter.es` the translated template itself
`\input`s) are the per-edition template's OWN responsibility; nothing here chases those.
The coverage gate in §4 governs paragraph text only; a language-coupled template that
needs different front matter or typographic conventions is out of the gate's scope by
design, and Claude (per the `translation-pass` skill) is expected to ask the writer before
assuming a template variant is warranted.

### 7. Editor review is read-only, and the read-only posture is a membrane flip, not a
   view mode.

`EditorControl.translationLanguage` drives `EditorCoordinator.setTranslationReview` — a
`shouldChangeTextIn` gate that rejects keystrokes while non-nil, mirroring `setLockEditing`
(same shape, new posture). This is deliberate: reviewing a translation shows DERIVED text
(the translated substitution, badge-annotated fresh/stale/missing per paragraph via
`TranslationBadgeLayout`) that isn't a text the writer can edit in place — there is no
"correct" edit target inside a read-only translated render, only "go retranslate the
paragraph and re-derive." The picker (View → Translation Review…) and the ⌘⌥8 Translation
pane (source text + freshness chip + open translator queries, reply folds into
`acceptAnnotation` same as any other query reply) are the writer's surfaces onto this
plane; nothing here is Claude-facing.

**Tripwire, closed during this milestone (Task 11):** `EditorSurface.reconcileTextBuffer`
must flip the membrane (`coordinator.setTranslationReview`) BEFORE checking whether the
text buffer needs replacing, not after. The two are coupled by more than sequencing — a
translation entry/exit is itself a buffer-identity change (source text ↔ translated
render), so getting the order backwards let a stale membrane state see the NEW buffer for
one pass, and separately let an in-mode translated-content refresh retain a stale
`preserveUndoStack` decision across a buffer swap that must always drop the native undo
stack (carrying the source manuscript's undo actions across a translation-render swap
reopens the same ⌘Z corruption class ADR 0023's D1 rule exists to prevent). The general
lesson, worth stating for future control flags: **any control flag whose flip changes
which text buffer the editor is showing must flip synchronously, before the swap
decision is made** — an async or reordered flip is a race, not an implementation detail.
See `Maugham/Editor/AREA.md`'s tripwire list for the pinned version of this rule.

## Consequences

- Claude gets a genuine translation workflow (`translation_status` →
  `read_translation` filtered → batched `write_translation` → gated `compile`) without a
  single new manuscript-mutation surface — the membrane held by adding a parallel plane,
  not by carving an exception into the existing one.
- The writer gets a coverage gate that makes "half-translated book labeled as an edition"
  structurally hard to ship, with an explicit, provenance-tracked escape hatch
  (`allow_stale`) for when a partial preview is exactly what's wanted.
- A translated edition's template/style differences are a convention (language-suffixed
  filename resolution), not automation — an honest scope boundary rather than a promise
  the milestone doesn't keep.
- The read-only review posture reuses the `setLockEditing` shape rather than inventing a
  new one, and closes a real buffer-identity race in the process — the fix generalizes to
  any future control flag that swaps which buffer the editor shows.

## References

- Spec: `docs/superpowers/specs/2026-07-22-translation-layer-design.md`
- Progress ledger (per-task decisions): `.superpowers/sdd/progress.md`
- ADR 0004 (MCP foundation scope — the manuscript-is-yours membrane this layer sits
  parallel to), ADR 0010 (typed cross-area seams — `TranslationStatus`/`SynthesisSource`-
  style enums), ADR 0012 (per-device JSONL partitioning — the storage precedent this
  layer's `.maugham/translations/` files follow), ADR 0013 (per-piece `style_file` scoping
  — the convention `LanguageSuffixedFile` extends), ADR 0017 (editor control plane —
  `EditorControl.translationLanguage` is one more property on the existing seam), ADR
  0018/0019 (manuscript reads derive from the op log, clean `.md` on disk — the precedent
  `currentParagraphState` follows for translation reads), ADR 0023 (unified undo — the D1
  rule the buffer-identity tripwire in §7 protects).
