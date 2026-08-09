# Publish-edition durability — every record owns its artifact and identity from mint time

**Date:** 2026-08-09
**Source:** Issue #25 (sweep findings P1 [Medium] + P2/P3/P4 [Low], `docs/superpowers/notes/2026-07-26-sweep.md`)
**Decided with Denver:** all four findings in one branch; P1 fixed as version-everywhere; P2 as a per-project mint reservation (fail-fast at guard time).
**Post-partitioning context (2026-08-09, merge `5aa873af`):** `PublicationStore` appends to a per-device `publications.<slug>.jsonl`; `load()` glob-merges siblings plus the read-only legacy file. Cross-device append contention is gone by construction — P2's remaining race is same-process only.

## 1. Problem

1. **P1** — `Republisher.republish` renders through `snap.config`, whose `nextVersion` is pinned to the ORIGINAL edition's version, so the staged output filename equals the original's; the move (`Republisher.swift:167-170`) does `removeItem` + `moveItem` → the original `Exports/` artifact is deleted and replaced. The distinguishing `-r<suffix>` version is minted only AFTER the move and only for the catalog. Both records then resolve `outputPath` to one file, and because `astSource` reads the live store, the original `vX` publication silently serves drifted bytes. Repeated republishes clobber the same path.
2. **P2** — `CompileOrchestrator.compile` does load → triple-guard → …compile… → append with nothing serializing two same-process calls: both pass the guard, both append (and source compiles both grab the same `next_version`).
3. **P3** — nothing validates that `filename_template` contains `{version}`; a template without it maps distinct versions to one path (the catalog stays honest while the disk collides).
4. **P4** — `ProjectStoreASTSource.allowStale` is dead: its doc comment claims the gate reads it; the substitution ignores it and both gate callers read their own values. A future reader trusting the comment would be misled.

## 2. Design

### 2.1 P1 — mint first, stamp everywhere

At the top of `Republisher.republish` (after loading `prior`), mint `newVersion = priorVersion.map { "\($0)-r\(suffix)" } ?? "republish-\(suffix)"` — the same spelling the append site uses today, moved before compile. Build `var effective = snap.config; effective.nextVersion = newVersion` and pass `effective` (not `snap.config`) to `PDFCompiler`/`EPUBCompiler`. Consequences, all deliberate:

- `{version}` in the filename expands to the republish version → no collision with the original artifact or with other republishes, ever.
- `\MaughamVersion` (PDF) and the EPUB metadata stamp the republish version — the artifact says which catalog row it is. This is `CompileOrchestrator:214-220`'s existing invariant (artifact stamp = catalog row) extended to the republish path; byte-fidelity to the original is NOT a regression because republish already re-renders live manuscript content (its own Task 9 F1 comment).
- The snapshot on disk is untouched — `effective` is a local value; `snapshotStore.save(snap)` keeps persisting the ORIGINAL config. A later republish of the same snapshot mints its own fresh suffix from the same base.
- Config validation stays on `snap.config` (identical fields except `nextVersion`, which the validator does not constrain — confirm in the plan; if it does, validate `effective` instead).
- The `fileExists → removeItem` guard at the move site STAYS as defense-in-depth for a re-run after a crashed prior move of the SAME republish, with a comment stating it can no longer fire against a sibling edition's file.
- The catalog append reuses the pre-minted `newVersion` — no second mint. `CompileOrchestrator`'s triple-guard comment ("republished records always carry a distinct `-r…` version") becomes enforced-by-construction.

### 2.2 P2 — per-project mint reservation

New small actor `PublishMintGate` (in `Maugham/Publish/`), one instance per project (owned beside the stores in `PublishingStores`, following however that type wires per-project singletons — the plan pins the exact seam):

```swift
actor PublishMintGate {
    struct Key: Hashable { let version: String; let language: String?; let format: PublishConfig.Format }
    private var inFlight: Set<Key> = []
    /// Reserve or refuse. Refusal = a compile of this triple is already in flight.
    func reserve(_ key: Key) -> Bool
    func release(_ key: Key)
}
```

- `CompileOrchestrator.compile`: after computing `effectiveVersion` and passing the existing catalog triple-guard, `reserve` the triple; a refusal fails the job fast with a "already compiling this edition" diagnostic (same `TectonicLogParser.Diagnostic` shape as the existing collision refusal). `release` in every exit path (defer).
- Source compiles: the reservation also closes the `next_version` double-grab — two concurrent source compiles reserve the same effective version and the second refuses.
- `Republisher.republish`: reserves its freshly-minted `newVersion` triple the same way. (Collisions are near-impossible with unique suffixes; the reservation is for uniformity and for the `republish-<suffix>` fallback family.)
- Different triples still compile in parallel. Deliberately in-memory and per-process: the partitioned store already isolates devices; a second *process* on one Mac is not a supported shape (single app instance).
- The existing `:355` TODO (config-save vs append two-phase commit) stays out of scope — different failure, non-corrupting, recorded here so the next sweep doesn't fold it into this.

### 2.3 P3 — `{version}` is mandatory in the template

`PublishConfigValidator` gains a rule: `outputs.filename_template` must contain the literal token `{version}` — a validation ERROR, joining the existing traversal rules, so `set_publish_config` refuses it at write time and `Republisher`'s snapshot re-validation (`Republisher.swift:59-64`) refuses a legacy snapshot carrying one at replay time (loud, not a silent collision). The sweep's optional `{language}` warning is dropped: `OutputFilenameBuilder` already auto-suffixes `-<lang>` when the template lacks the token, so the collision it would warn about cannot occur.

**Correction (2026-08-09, plan Task 3):** the validator has required `{version}`
(with `{title}`/`{ext}`) since its creation (`28b6fed9`) — sweep finding P3 was
wrong when filed. What was missing was the TEST pin; this task adds it. The
snapshot-replay refusal described below already worked via `Republisher`'s
re-validation.

### 2.4 P4 — delete the dead field

Remove `ProjectStoreASTSource.allowStale` (property, init parameter, doc comment). The compiler surfaces the one construction site (`PublicationTools.swift:243`); both gate callers already read the right value from their own context. No behavior change — that is the point.

## 3. Testing

- **P1:** republish after manuscript drift → the ORIGINAL artifact's bytes are unchanged (content assertion, not existence); catalog holds two records → two distinct `outputPath`s; a second republish → a third distinct file. The internal stamp is asserted at the LaTeX emission layer (the `\renewcommand{\MaughamVersion}` line carries the `-r` version), not by parsing a PDF.
- **P2:** two concurrent `compile` calls, same triple → exactly one Publication appended, one fast refusal (and the refusal's diagnostic names the in-flight edition); different triples → both succeed; a failed compile releases its reservation (a retry succeeds).
- **P3:** validator refuses a template without `{version}`; accepts the default; the republish snapshot-revalidation path surfaces the same refusal for a legacy snapshot.
- **P4:** the build and the existing gate tests prove it — no new test.
- **Claims pin (with intent-to-spec's register):** the P1 regression test doubles as the register's first publish claim — id family `M7-PB-nnn`, pair files `<experiment|register>/reconciliation/Publications.{claims,filings}.json` per `reconciliation/PROTOCOL.md`, pin resident in `MaughamTests/Claims/`, module added to `27-generate-state.py`'s `APP_MODULES` (or carried by the graduation if it lands first). The claim states: *a republish never rewrites another publication's artifact; every catalog record's `outputPath` is distinct.* Path (`experiment/` vs `register/`) resolved at landing time per the graduation merge's state.

## 4. Out of scope

- The `:355` two-phase-commit TODO (config-save/append ordering) — recorded, distinct.
- Multi-process single-device compile serialization (unsupported shape).
- Any change to snapshot contents, `read_publication_page`, or the drift window itself (Task 9 F1's documented live-read behavior stands; P1 makes the ORIGINAL artifact immune to it, which is what the finding was about).
