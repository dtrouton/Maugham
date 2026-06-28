# 0018 — Manuscript reads always derive from the op log (never the `.md`)

- **Status:** Accepted
- **Date:** 2026-06-28
- **Design detail:** `docs/superpowers/specs/2026-06-28-oplog-source-of-truth-reads-design.md`

## Context

The hard invariant (CLAUDE.md, `Maugham/OpLog/AREA.md`) is that the **op log is
the sole source of truth for manuscript documents; the `.md`/`.fountain` file is
a derived OUTPUT, re-materialised from the op log.** But the invariant was never
*enforced* on the read side. A 2026-06-28 audit found **9 places** that read a
manuscript file off disk and treated its content / paragraph `sequence` / inline
`<!-- ¶id -->` anchors as truth — including `read_document`, cross-document
search, the wiki-link / reference graph, task derivation, project-open word
counts, and (most consequentially) the **publish pipeline**.

This is a recurring category error (an output read back as an input), and it
produced a real bug: `read_document` returned a paragraph anchor that
`add_comment` then rejected as `paragraph_not_found`, because `read_document`
read a stale `.md` while `add_comment` derived the sequence fresh from the op log.
The `.md` lags the op log whenever an op lands out of band (another device — ADR
0012; an MCP write), autosave is mid-debounce, or a recovery state is pending.

## Decision

**Manuscript content, sequence, and anchors are read ONLY from the op log.**
A single read-only primitive is the sanctioned way to materialise a *closed*
manuscript document, fully synchronous, no `Document` actor:

```swift
DerivedManuscript.materialize(forDocId:in:)   // anchored text
DerivedManuscript.derivedState(forDocId:in:)  // paragraphs + sequence
// = OpLogStore.loadSyncMerged → Deriver.deriveWithSequenceFallback → Materializer.materialize
```

The standing rule for this seam:

> **Reading a manuscript's content means deriving it from the op log.** Open doc →
> the live in-memory `Document` (`materialize()` / `displayText` / `paragraphs`).
> Closed doc → `DerivedManuscript`. Never `String(contentsOf:)` on a manuscript
> `.md`/`.fountain` as a source of truth.

Legacy logs (no explicit `sequence`) use `deriveWithSequenceFallback`, which
synthesises order from the ops' insertion order — **op-log-only, never the
`.md`**; ancient post-burst reorderings are approximate, accepted (the same
limitation History Rewind documents).

The only sanctioned `.md` reads that remain are in `Document+Load.swift`'s
reconciler / echo-guard, which read the file as a **comparison reference** while
the op log stays authoritative (crash recovery, orphan repair, suppressing our
own write callback).

## Consequences

- **A tripwire test enforces it.** `TripwireGrepTests` fails if a manuscript doc's
  file content is read off disk outside the sanctioned sites, with a planted-
  offender test proving the guard fires. The category error can't silently return.
- **`read_document` and `add_comment` agree by construction** for any non-legacy
  log: both derive fresh from the op log, so a paragraph anchor `read_document`
  returns is one `add_comment` accepts.
- **Publishing is correct.** PDF/EPUB build from the op-log-derived manuscript,
  not a possibly-stale file.
- **`Document.load` / the write path is unchanged** — its `.md` reconciler is the
  legacy-recovery exception, not a content source.
- **Behaviour changes on a stale `.md`:** consumers may now reflect content the
  file doesn't yet show — that *is* the fix; no manuscript data changes.
- **Perf:** bulk consumers derive from the op log instead of one file read
  (synchronous `loadSyncMerged` + derive, already used by tasks/rewind); cache by
  docId within a single operation if a hot loop ever regresses.
- Relationship: this is the read-side enforcement of the op-log-source-of-truth
  invariant (ADRs 6–8, 0012, 0016); it reuses the existing
  `loadSyncMerged`/`Deriver`/`Materializer` primitives rather than adding new
  derivation logic.
