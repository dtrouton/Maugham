# Op log is the only manuscript source — eliminate `.md`-as-input reads

**Date:** 2026-06-28
**Status:** Proposed
**Area:** `Maugham/MCP/`, `Maugham/Stores/`, `Maugham/Publish/`, `Packages/MaughamCore/`

## Summary

Maugham's hard invariant is that the **op log is the sole source of truth for
manuscript documents; the `.md`/`.fountain` file on disk is a derived OUTPUT,
never an INPUT.** An audit (2026-06-28) found **9 places that violate this** —
they read a manuscript file off disk and treat its content/sequence/anchors as
truth. This caused a real bug: `read_document` returned a paragraph anchor that
`add_comment` then rejected as `paragraph_not_found`, because `read_document`
read a (stale) `.md` while `add_comment` derived the sequence fresh from the op
log.

This milestone routes every manuscript read through a single op-log-derived
primitive, and adds a tripwire test so the category error can't recur.

## Problem

The `.md` is re-materialized from the op log on autosave/open, so for an
open, idle doc it usually matches the op log. But it can lag:

- ops appended out of band (another device — ADR 0012; a future MCP write) that
  haven't been re-materialized,
- autosave debounce (750 ms) not yet flushed,
- crash-recovery / legacy states.

Any code that reads the `.md` as truth then sees stale content, a stale
paragraph **sequence**, or stale `<!-- ¶id -->` anchors. The most dangerous is
publishing (the PDF/EPUB is built from the file, not the op log).

### The 8 violations (from the audit)

| # | Site | What it reads as truth |
|---|---|---|
| 1 | `Maugham/Publish/ProjectStoreASTSource.swift:38` | **Publish pipeline** — feeds raw `.md` into the PDF/EPUB AST |
| 2 | `Maugham/MCP/Tools/DocumentTools.swift:80` | `read_document` closed-doc body + sequence (the reported bug) |
| 3 | `Maugham/Stores/ProjectSearchEngine.swift:30` | Cross-document full-text search (manuscript pass) |
| 4 | `Maugham/MCP/Tools/ListAllLinksTool.swift:71` | `[[wiki-link]]` graph extraction |
| 5 | `Maugham/MCP/Tools/ReferenceTools.swift:165` | `find_references` back-reference scan |
| 6 | `Maugham/MCP/Tools/ReferenceTools.swift:48` | `list_scenes` closed-doc Fountain parse |
| 7 | `Maugham/Stores/ProjectStore+Tasks.swift:197` | Paragraph text for closed-doc task derivation (ops already loaded!) |
| 8 | `Maugham/Stores/ProjectStore.swift:229` | Word counts at project open |
| 9 | `Maugham/Stores/ProjectStore+Structure.swift:417` | Wiki-rename pre-check (reads `.md` to decide whether to load) |

(9 lines; #9 is the lower-severity pre-check. All are in scope.)

**Not violations** (confirmed by the audit, left untouched): research-file reads;
manifest/UI-state/trash/publish-config/CSS reads; and the two `Document+Load.swift`
reads (172, 241), which read the `.md` only as a **comparison reference** for the
reconciler / echo-guard — the op log stays authoritative. These are the
*sanctioned* `.md` reads.

## Design

### The shared primitive (MaughamCore)

A single read-only way to get a **closed** manuscript doc's content from the op
log, fully synchronous, no `Document` actor:

```swift
public enum DerivedManuscript {
    /// Anchored (materialized) text for a closed manuscript doc, derived from
    /// the op log — never the `.md`. Uses the sequence-fallback so legacy logs
    /// (no explicit `sequence`) still yield ordered text, synthesised from the
    /// ops' insertion order — NOT from the `.md`. Empty string if no ops.
    public static func materialize(forDocId docId: String, in projectURL: URL) -> String

    /// Derived state (`paragraphs` + `sequence`) for callers that need the map /
    /// order directly (tasks, word count) without re-deriving or re-anchoring.
    public static func derivedState(forDocId docId: String, in projectURL: URL) -> Deriver.DerivedState
}
```

Implementation (composes existing, confirmed primitives):

```swift
let ops   = OpLogStore.loadSyncMerged(forDocId: docId, in: projectURL)   // ADR 0012 partition-aware merge
let state = Deriver.deriveWithSequenceFallback(ops: ops)                  // op-log-only; legacy order synthesised, never .md
return Materializer.materialize(paragraphs: state.paragraphs, sequence: state.sequence)  // anchored text
```

`docId == StructureItem.id` for manuscript docs (confirmed: the existing closed-doc
task path already calls `loadSyncMerged(forDocId: item.id, …)`).

**Legacy-log decision (approved):** `deriveWithSequenceFallback` synthesises the
sequence from the ops when no op carried an explicit `sequence` (pre-"always
capture sequence" logs). This is **op-log-only** — it never reads the `.md`.
Trade-off accepted: for ancient logs whose paragraphs were reordered/deleted
post-burst, the synthesised order is approximate (the same limitation History
Rewind already documents). We do **not** reintroduce a `.md` read to recover it.

### Routing the violations

The pattern everywhere: **open doc → use the live in-memory `Document`** (already
correct — `doc.materialize()` / `doc.displayText` / `doc.paragraphs`); **closed
doc → `DerivedManuscript`** instead of reading the file.

- **#2 `read_document`** — closed-doc branch becomes
  `DerivedManuscript.materialize(forDocId: item.id, in: projectURL)`. This makes
  it derive from the op log exactly like `add_comment` does, eliminating the
  reported skew for any non-legacy log (both derive fresh — no stale `.md`).
- **#7 tasks** — drop the `.md` parse; use
  `DerivedManuscript.derivedState(...).paragraphs` (the ops are already loaded —
  reuse them; don't double-load).
- **#8 word count** — `DerivedManuscript.derivedState(...)`, count over
  `state.paragraphs.values` (no `Materializer` needed).
- **#1 publish, #3 search, #4 links, #5 find-refs, #6 list_scenes** — closed-doc
  read becomes `DerivedManuscript.materialize(...)`, then the existing
  anchor-strip / parse runs on the derived text.
- **#9 wiki-rename pre-check** — run the pre-check against
  `DerivedManuscript.materialize(...)` (or drop the pre-check and always load);
  the actual mutation already goes through `Document.load`.

`add_comment` / `withAnnotationDocument` are **unchanged**: they need a full
`Document` to write the op, and their closed-doc `Document.load` (with its
`.md` reconciler for legacy recovery) is the sanctioned write path.

### The tripwire (recurrence guard)

A new `TripwireGrepTests` case fails if a manuscript document's file content is
read off disk outside the two sanctioned sites. Concretely: forbid
`String(contentsOf:` / `Data(contentsOf:` reads of a doc `path` in the violator
files (MCP tools, search engine, publish AST source, the relevant `ProjectStore`
extensions), with a small explicit allowlist for the sanctioned reconciler reads
(`Document+Load.swift`) and the new primitive's `loadSyncMerged` (which reads op-log
*files*, not the `.md`). Includes a planted-offender test (mirrors the existing
tripwire pattern) proving the guard actually fires.

## Invariants

- **Manuscript content/sequence/anchors always derive from the op log.** The only
  code that reads a manuscript `.md` is (a) `Document+Load`'s reconciler/echo-guard
  (comparison reference, op log authoritative) and (b) nothing else — enforced by
  the tripwire.
- **Open doc uses the live `Document`; closed doc uses `DerivedManuscript`.** Same
  derivation either way.
- **No `.md` read for legacy recovery in the read-only path** — op-log-only
  synthesis; approximate ancient ordering accepted.
- Research-file reads, manifest/config reads, and the `Document.load` write path
  are unchanged.

## Testing strategy

- **`DerivedManuscriptTests` (MaughamCore):** parity — for a doc built from a
  known op stream, `DerivedManuscript.materialize` equals what `Materializer`
  produces from `Deriver`; legacy (no-sequence) ops still yield ordered text;
  empty log → "".
- **The staleness regression (the key one):** build a closed doc, append an op to
  its op log WITHOUT re-materialising the `.md` (write a deliberately stale `.md`),
  then assert each routed consumer (`read_document`, search, links, tasks, word
  count, publish AST source) reflects the **op-log** content, not the stale file.
- **`read_document` ≡ `add_comment` parity:** the original bug — `read_document`
  returns a paragraph id that `add_comment` then accepts (no `paragraph_not_found`)
  for a closed doc with a stale `.md`.
- **Tripwire:** the new grep test + its planted-offender test.
- Full Mac suite green; publish + search + tasks existing tests stay green.

## Migration / sequencing

Incremental — primitive first, then one consumer per task (each independently
testable against the staleness regression), tripwire last (it can only go green
once every violation is routed). Order by risk/value: primitive → `read_document`
(the reported bug) → publish (highest-impact) → search → links/refs/scenes →
tasks → word count → wiki-rename pre-check → tripwire + AREA.md note.

## Non-goals (YAGNI)

- **Not** changing `Document.load` / its `.md` reconciler (the sanctioned write
  path + legacy recovery).
- **Not** changing research-file or manifest/config reads.
- **Not** improving legacy-log ordering accuracy (op-log-only synthesis is the
  accepted behaviour).
- **Not** making bulk consumers spin up `Document` actors — the synchronous
  primitive is the point.

## Risks

- **Perf:** bulk consumers now derive from the op log instead of one file read.
  `loadSyncMerged` + `deriveWithSequenceFallback` is synchronous and already used
  on hot-ish paths (tasks, rewind); for a publish/search over a whole project it's
  N derivations. Acceptable (correctness > a file read); if a hot loop regresses,
  cache by docId within the single operation.
- **Behaviour change on a stale `.md`:** consumers may now show content the file
  doesn't — that is the fix (the file was wrong). No manuscript data changes.
- Refactoring across 9 sites — mitigated by the per-consumer staleness test and
  the existing suites.
