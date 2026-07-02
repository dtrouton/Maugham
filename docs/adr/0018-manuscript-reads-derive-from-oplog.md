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

The only sanctioned manuscript `.md` reads that remain are (1) the reconciler /
echo-guard in `Document+Load.swift` and (2) the external-change detector in
`DocumentStore.swift` (~line 750), which reads the file via `Data(contentsOf:)`
only to feed `doc.handleExternalDiskChange(diskMd:)`. Both keep the op log
authoritative — they are comparison references, not content sources; external
edits are discarded on re-materialize.

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

## Addendum (2026-07-01) — open-doc rule enforced at the freshness sites; annotation-based tripwire; derive cache

The op-log-spine-hardening review (spec
`docs/superpowers/specs/2026-07-01-oplog-spine-hardening.md`) found the standing
rule — *open doc → live `Document`; closed doc → derive* — was only followed by
`read_document` / `list_scenes`. Several always-derive consumers therefore lagged
an OPEN doc.

- **The open-doc branch is now enforced at four more sites (F6):**
  `ProjectStoreASTSource` (compile / `preview_compile`), `ProjectSearchEngine`
  (in-app + MCP `search_text`), `ListAllLinksTool`, and `FindReferencesTool` all
  take the live `Document`'s in-memory state when the doc is open, deriving only
  for closed docs — the same pattern `read_document` uses. `read_document`'s
  word_count is now computed over the *stripped* text.

- **The staleness figure is the burst window, not 750ms.** For any remaining
  always-derive consumer, an open doc's newest text lags by the **burst window
  (30s idle / 90s cap / force-flush)** — because the 750ms autosave writes the
  `.md` + pending mirror but appends **no ops**; ops land at burst close. Earlier
  docs/roadmap notes that said "~750ms" understated it. With the four sites
  converted, an open doc is now read from live memory (zero lag) rather than
  derived at all.

- **The tripwire is now an invariant guard, not a site guard (F9).**
  `TripwireGrepTests` no longer scans a fixed 8-file allowlist for 3 patterns; it
  scans **all production `.swift`** under `Maugham/`,
  `Packages/MaughamCore/Sources/`, and `MaughamPhone/` for a widened pattern set
  (`String(contentsOf`, `Data(contentsOf`, `contentsOfFile`,
  `FileManager.contents(atPath`, `FileHandle(forReadingFrom`, `.resourceBytes`,
  `url.lines`). Every hit must carry a `// adr-0018-ok: <reason>` annotation; a
  planted-offender self-test proves the guard fires. Note the nuance:
  **op-log / inbox / pending JSONL reads are annotated `ok`** — the op log *is*
  the truth, so the guard is about the derived `.md`, not all file I/O. Known
  limitation: `url.lines` is detected only by its async shape. A phone twin
  covers `MaughamPhone`, and the phone Read tab's on-disk `.md` display read is
  registered as a contracted divergence (Tier 2) in
  `docs/superpowers/notes/cross-surface-contracts.md`.

- **Closed-doc derivation is cached (F5).** The perf note above ("cache by docId
  if a hot loop regresses") is realized as `DerivedManuscriptCache` (MaughamCore),
  keyed on the doc's op-log file set + mtimes + sizes, fronting `DerivedManuscript`
  for closed docs. Adopted by search / compile / the link+reference+scenes tools /
  wiki-rename pre-check / word counts; open docs bypass it (they read live). See
  `Maugham/Stores/AREA.md` for the owner and rationale.
