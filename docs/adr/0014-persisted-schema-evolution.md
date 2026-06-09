# 0014 — Persisted-schema evolution: schemaVersion gate + graceful enum/field decoding

**Status:** Accepted
**Date:** 2026-06-08

## Context

The phone and the Mac ship on independent release trains, and auto-update means a project folder is routinely touched by two app versions at once. So **cross-version reads of on-disk data are the normal case, not an edge case** (audit Sweep 6). Two latent failures had drifted in because no v2 of any persisted type had shipped yet, so nobody had felt the break:

- An unknown enum value or a future field made a whole `project.maugham.json` **undecodable → project unopenable** on the older build (high severity — on the phone the project silently vanished from the list). The synthesized `Codable` for a `RawRepresentable` enum *throws* on an unknown raw value; for a single JSON object there is no per-line quarantine, so one bad value sinks the whole manifest.
- An unknown `OpKind`/`SynthesisSource` raw value threw at the `Op` level, which `JSONLAppendStore.parseDiagnosed` quarantines — keeping the log loading, but **silently dropping** the edits that op carried on the older reader.
- `ProjectManifest.schemaVersion` was declared but **never checked** — purely documentary. By contrast `UIState`/`SessionLog` already guard their `schemaVersion` correctly and are the in-codebase template.

The naive fix — "add an `unknown` fallback to every enum" — has a trap. If an OLD app decodes a NEW value as a safe default and later **re-saves**, it overwrites the newer value it couldn't represent → silent forward-data-loss, *worse* than the original crash.

## Decision

Layered defence. The `schemaVersion` gate is primary; per-enum/-field tolerance is the within-version safety net.

1. **`schemaVersion` gate is the PRIMARY defence.** `ProjectManifest.decodeGuardingSchema(_:)` refuses any manifest whose on-disk `schemaVersion` is GREATER than the build's `currentSchemaVersion`, throwing `SchemaTooNewError`. Both manifest-load surfaces route through it (`ProjectStore.load` → `manifestSchemaTooNew` → "This project was created by a newer version of Maugham. Update Maugham to open it."; the phone's `ProjectsBrowser` → per-project failure). This mirrors the `UIState`/`SessionLog` guards. Refusing a genuinely-newer-schema project up front is what makes the degrade-and-resave hazard safe: we never silently down-convert a newer project.

2. **Op-log enums get an `unknown` *case* + a compile-forcing switch.** `OpKind` and `SynthesisSource` decode an unrecognised raw value to `.unknown` (via custom `init(from:)`) instead of throwing, so the op line is **kept, inert**, not quarantined/dropped. `Deriver.appliesToManuscript` (the exhaustive `OpKind` switch) treats `.unknown` as non-manuscript, so an unknown op never mutates derived text. Crucially, that switch is **exhaustive**: when a *future real* kind is added as a named case, the switch — and the parallel HistoryPane/RewindWindow switches — **fail to compile**, forcing the dev to classify the new kind rather than silently inheriting `.unknown`'s inert behaviour. The compile-forcing is the main value. The app never *creates* an `.unknown` op (it only arises on decode), so the round-trip can't manufacture one.

3. **Manifest enums get a safe-default *decoder* (no new case).** `ProjectType` → `.unknown` (excluded from `allCases` so it never appears in a picker); `StructureItem.ItemType` → `.document`; `ResearchItem.ItemType` → `.asset`; `ResearchItem.AssetKind` → `.document`; `PieceKind` → `.loose`. A safe default (rather than a third `.unknown` state threaded through ~15 view switches and the tree-walk) keeps the binary group/document & group/asset invariants intact while making ONE unknown value degrade gracefully instead of bricking the whole manifest. Paired with the schemaVersion gate, this only fires for a *same-schemaVersion* file carrying an unexpected value.

4. **Struct decoders use `decodeIfPresent` + defaults.** `TypographySettings` (8 non-optional fields — a landmine for the next field add) gets a custom `init(from:)` that falls back to `.defaults` per missing field, so adding a ninth field later doesn't break decode of older data. (`UIState` and `PublishConfig.Section` already do this; this extends the pattern to the one struct that didn't.)

5. **Lower-stakes enums get safe-default decoders too.** `InboxEntry.Kind` → `.text`, `TranscriptionState` → `.failed` (NOT `.none`, to avoid a cross-version re-transcription loop against a state a newer build owns), `Status` → `.new` (stays visible/triageable rather than silently hidden), `Checkpoint.LabelSource` → `.auto`, `PublishConfig.Format` → `.pdf`, `PublishConfig.StartOn` → `.any`. These are single-row (JSONL) or whole-config blast radius; the safe default avoids quarantining a row / sinking `config.json`.

**Template:** `UIState` / `SessionLog` (the schemaVersion guard) and `PublishConfig.Section.init(from:)` (the `decodeIfPresent` shape) are the in-codebase models for all of the above.

## Consequences

- A planted *future* enum case fails to **compile** in `Deriver.appliesToManuscript` (and the HistoryPane/RewindWindow OpKind switches) — the bug surfaces at build time, before the next schema change ships, not after a user's project won't open.
- A newer-schema `project.maugham.json` is **refused with an explicit message**, never silently misparsed or degrade-and-resaved.
- A same-schemaVersion file carrying an unexpected enum value **degrades one item** (an unknown project type / item type / asset kind / piece kind / inbox kind reads as its safe default). This is the accepted residual risk: graceful degradation of one item instead of an unopenable project. The schemaVersion bump is the mechanism that prevents this from masking a *real* new schema.
- The new tolerance is enforced by `SchemaEvolutionToleranceTests` (MaughamCore) — unknown op kind is inert-not-crashing; unknown project/item type degrades and the whole manifest still decodes; `schemaVersion` greater than current is refused; `TypographySettings` missing a field decodes with defaults. The old throw-on-unknown assertions (`ProjectTypeTests`, `PublishConfigValidatorTests`) were updated to assert the new degrade-not-throw contract.
- `Op.Provenance.synthesisSource == .unknown` is possible on decode; existing HistoryPane switches already had `default:` arms, so no display path breaks.
