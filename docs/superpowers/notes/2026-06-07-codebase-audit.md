# Codebase Audit — Correctness, Maintainability, Data-Integrity — 2026-06-07

Author: Claude. Full-codebase audit run at v0.8.0 (backup & integrity shipped),
~636 Swift files / ~75k LOC / ~301 test files. Method: five parallel deep-read
agents over disjoint scopes (data-integrity core; editor; stores/filesystem;
MCP + publish; cross-surface / MaughamCore / phone / tests), plus a CI/infra
pass. Every "confirmed" item below was read at the cited `file:line`; items
marked "risk" are plausible-but-unproven and want a closer look before a fix.

This supersedes nothing — it's an observations document in the lineage of
`2026-05-19-state-of-the-code.md`. The 2026-05-19 headline (Bootstrap never
called) is **fixed**; ProjectStore has been split into peer files (finding #6
done); CharacterAutocompleter is **deleted**. This audit is a fresh pass on the
code as it stands today.

The headline: **the op-log / integrity / backup substrate is genuinely
well-engineered and honestly commented, and the cross-surface contract program
is sound.** The risk is concentrated in a handful of places where manuscript
bytes can diverge silently — the one outcome the whole architecture exists to
prevent. Those are listed first.

---

## Tier 0 — Silent manuscript divergence / data-loss (fix before trusting multi-device or wiki-rename)

| # | Finding | Status | File |
|---|---|---|---|
| 0.1 | **Wiki-link rename writes raw bytes to op-log-backed manuscripts** — bypasses the op log, no op emitted, no close-before-FS, no coordination. Renaming doc A silently rewrites every other doc's `.md` referencing `[[A]]`; if the target is open, the live `Document` re-materializes and the edit is clobbered; if closed, the `.md` diverges from its op log. Violates the #1 hard invariant ("op log is source of truth") **and** tripwire 14 **and** tripwire 7. | **Confirmed** | `ProjectStore+Structure.swift:394` |
| 0.2 | **Cross-device LWW resolves by `opId` order = ULID millisecond prefix = each device's wall clock.** No skew correction; `Op.at` is decoded but never consulted for manuscript resolution. Mac B's clock 5 min behind → an edit made *later* on B gets a *lower* ULID and loses to A's older text on merge. No conflict surfaced (log-merge re-derives silently; the conflict sheet only fires for `.md` orphans via Reconciler). | **Confirmed (design)** | `Deriver.swift:29-57`; `AnnotationDeriver.swift:53` |
| 0.3 | **PendingBuffer crash-recovery file is not device-partitioned** — `.maugham/ops/<docId>.pending.jsonl`, no device slug. Violates tripwire 17 / ADR 0012. Two Macs (or a crash mid-iCloud-sync) write the same path; iCloud silently drops a conflict-twin, so on crash-recovery the wrong device's uncommitted keystrokes can be folded into a real `typing_burst` op, or the right device's lost. | **Confirmed** | `PendingBuffer.swift:69` |
| 0.4 | **Same-opId dedupe keeps first-seen content and silently drops the other op's `changes`** — and a test *encodes this as intended*. Non-deterministic across devices (URL enumeration order decides the survivor). True ULID collision is astronomically unlikely, but this is also the only guard against a duplicated/replayed/hand-recovered op, and it makes two devices derive different text from the same logs with no signal. | **Confirmed** | `OpLogStore.swift:150-155`; `JSONLAppendStore.swift:104`; `CrossMacMergeTests.swift:30-39` |
| 0.5 | **`resolveDocId` fallback uses `String.hashValue`** — seed-randomized per process (the codebase knows this; `DeviceSlug.fnv1a32Hex` exists for exactly this reason). The reachable branch (manifest found but path-mismatch/decode-fail) yields a different docId every launch → the op-log filename changes → the entire prior op log is orphaned and the manuscript reverts to bootstrap/empty. | **Confirmed (reachable)** | `Document+Load.swift:291` (and `:300`, tests-only) |
| 0.6 | **Non-atomic op-log append** — `FileHandle.seekToEnd` + `write` + `close`; a crash/power-loss mid-write leaves a torn final line. The read path quarantines un-decodable lines (good), but a truncated line that's still *valid-looking* JSON with a severed `changes` decodes into a wrong op undetected. No test plants a torn line. | **Confirmed** | `JSONLAppendStore.swift:63-72` |

**Why these are the spine:** 0.1 is a live bug any wiki-rename triggers today.
0.2/0.3/0.4 are the multi-device sync correctness foundation — the iPhone
companion already writes the shared folder, and the roadmap's biggest open bet
(human-collaborator layer) multiplies concurrent writers. 0.5/0.6 are
lower-probability but each can strand or corrupt a manuscript irrecoverably.

---

## Tier 1 — Confirmed correctness bugs (not multi-device-gated)

| # | Finding | Status | File |
|---|---|---|---|
| 1.1 | **Smart-typography eats a selection.** `SmartTypography.transform` never inspects `replacementRange.length`; the coordinator expands the range by 1 (em-dash) / 2 (ellipsis) assuming a caret insert. Type `-` over a selection sitting just after a `-`, or `.` over a selection after `..`, and the selected text is silently consumed into the `—`/`…`. Invisible text corruption. | **Confirmed** | `SmartTypography.swift:11-49`; `EditorCoordinator.swift:447-453` |
| 1.2 | **Manifest self-save spuriously archives a conflict on every structural edit.** No echo guard on manifest writes: after the Mac's own save the presenter re-reads, sees `disk.modified > lastObserved` (true — last set to the *previous* value), and writes a `.maugham/conflicts/manifest-<stamp>.json` for our own write. Compounded by whole-second ISO8601 truncation. Not data loss, but it buries the *real* conflict signal in self-noise and churns disk. | **Confirmed** | `DocumentStore.swift:226-244, 624-637` |
| 1.3 | **Two FS-surgery sites miss the flush-before-move guard (tripwire 14) → phantom files.** `moveResearchItem` cross-group move calls `executeRenamePlan` (which only closes `Document`s, not path-keyed research-note `scheduleFileSave`s); `movePiece`/`renamePiece` move the whole piece folder incl. `research/` without flushing piece-scoped note saves. A pending debounced save lands at the old path after the coordinated move. | **Confirmed** | `ProjectStore+Research.swift:308-326`; `ProjectStore+CollectionPieces.swift:604-641, 707-721` |
| 1.4 | **LaTeX injection via `styleFile` filename.** `\input{pieces/\(styleFile)}` interpolates the filename unescaped. `set_piece_style` validates the *path* (no `..`/leading-`/`/null) but not for TeX-argument safety, so `}…\input{/etc/passwd}%` survives and injects arbitrary TeX into the compile. Tectonic is sandboxed (limits blast radius) but it's malformed output / DoS / a membrane smell. | **Confirmed (emit site)** | `LaTeXBodyEmitter.swift:33` |
| 1.5 | **`config.outputs.directory` / `filenameTemplate` not traversal-checked.** Validator only checks non-empty. `"../../outside"` (directory) or a `/` embedded in the template literal escapes the project root on PDF/EPUB write and on `republish` (which trusts the *snapshot's* config). Outputs aren't manuscripts, but it violates "nothing outside research/ + .maugham/publish/ + Exports/." | **Confirmed** | `PublishConfigValidator.validate`; `PDFCompiler.swift:109`; `EPUBCompiler.swift:100`; `Republisher.swift:88-89` |
| 1.6 | **`add_note` body write races the empty-file autosave.** `addResearchTextNote` creates an empty `.md` + schedules an autosave, then `AddNoteTool` writes the body directly — no `flushPendingSave` between. The queued autosave can overwrite the body with empty content. Exactly the tripwire-14 research-note pattern, missing. | **Confirmed** | `AddNoteTool.swift:49-51` |
| 1.7 | **MCP server `send()` ignores partial writes.** Only checks `sent < 0`; a short write truncates the JSON-RPC response (the bridge's `writeLine` loops correctly — the server doesn't). Unlikely on a local Unix socket but possible under pressure → client hangs/parse-error. | **Confirmed** | `MCPServer.swift:171` |
| 1.8 | **Trash restore appends to root, ignoring recorded `originalParentId`/`originalIndex`**, and restores a full subtree snapshot whose descendant paths may no longer exist on disk → dangling binder rows / silent relocation out of the parent group. Structural corruption, not file loss (files recover). Self-documented as a follow-up. | **Confirmed** | `ProjectStore+Trash.swift:19-31`; `TrashStore.swift:133-138` |

---

## Tier 2 — Risks worth a closer look (not yet proven bugs)

- **RenderFilter bigram tier (≥0.6) runs on the live typing path with no margin/uniqueness check** → for short similar paragraphs (dialogue "Yes." / "Yes?" / "Yes!"), an edit can steal a *different* paragraph's id and record the `prior`/`next` against the wrong paragraph. AREA.md itself calls tier-2/3 mis-pairing "silent corruption" and admits the disagreement test is missing. `RenderFilter.swift:82-89`, hot path via `Document.setFullText`.
- **`Deriver.derive` never removes deleted paragraphs from its accumulator** (deletion is `next:""`, key lingers); correctness depends on every consumer intersecting with `sequence`. Five scattered defensive trims exist; it has bitten repeatedly (phantom tasks). Deletion isn't a first-class op, so a pure log replay isn't a faithful manuscript — `reconcile` heuristics + the parsed `.md` are load-bearing for recovery, inverting the stated invariant. `Deriver.swift:32-36`; `Document+Load.swift:106-128`.
- **Tab-cycle async cursor reapply** (`DispatchQueue.main.async` re-asserting `targetCursor`) is the exact shape tripwire 3 warns against; guarded by a `!= targetCursor` check but can stomp a keystroke typed immediately after Tab. `EditorCoordinator.swift:619-624, 708-713`.
- **Integrity gate is skipped when the integrity check itself throws** (`try? await ProjectIntegrity.check` → nil report → guard bypassed → backup proceeds on unknown-health project). A throwing check is arguably the strongest corruption signal. `BackupCoordinator.swift:42-47`.
- **Manifest conflict at equal whole-second timestamps silently accepts the external side without archiving the loser** — narrow LWW silent-loss window for the manifest. `DocumentStore.swift:633`.
- **Permissive op-log filename parser** returns a docId for any non-`__project__` `.jsonl`; an iCloud conflict-twin `d_x 2.jsonl` parses to docId `d_x` and could surface as a phantom doc / be prefetched. `OpLogStore.swift:92`.
- **`canonicalPath` symlink resolution in publication snapshot** silently drops (not escapes) files whose symlink resolves outside the project → incomplete snapshot. `PublicationSnapshotStore.swift:140`.
- **Backup reads the live tree without file coordination** (plain `copyItem`); mitigated because ⌘S flushes the active doc first and the per-generation Merkle verify aborts a torn generation — fails safe, but relies on that verify. Worth a comment + a torn-read test. `BackupWriter`.

---

## Performance findings (large-document responsiveness)

- **Screenplay typing parses the whole document THREE times per keystroke** + a full-storage `setAttributes` over all text. `textDidChange` → `retokenizeAndStyle` calls `mode.tokenize` (parses) **and** `FountainTokenizer().parse` again, then `ScreenplayMode.applyTypography` parses a third time. O(N) per keystroke → O(N²) to type an N-length doc. This is the single highest-value perf change; a 100k-word screenplay would feel it. Fix: thread one parsed `FountainScript` through all three. `EditorCoordinator.swift:384-398`; `ScreenplayMode.swift:114`.
- **Focus-dim re-enumerates the entire storage on every cursor move** when focus mode is on. O(N) per arrow key. `EditorCoordinator.swift:841-849`.
- **`restoreComments` shingle-matching is O(P²)** in paragraph count per save (off the keystroke path, debounced; a 5000-paragraph novel save is quadratic). `RenderFilter.swift:64-92`.
- **`.maughamScriptDidUpdate` broadcast on every keystroke** re-renders the scene navigator per keystroke. `EditorCoordinator.swift:394-398`.

---

## Architecture & maintainability

- **Tripwire 14 (close-before-FS-surgery) should be enforceable by construction, not remembered.** It's already been missed at 1.3 (and arguably 1.1) because the centralized mover (`executeRenamePlan`) bakes in the Document-close but the bespoke `fm.moveItem` movers in `+CollectionPieces`/`+Research` don't, and `executeRenamePlan` doesn't flush research-note saves. **Highest-leverage refactor: one typed entry point** (`DocumentStore.relocate(plan:)` / `.trash(relativePath:)`) that, for every affected path, runs `document(for:)?.close()+unregister()` **and** `flushPendingSave()` before any FS call — and is the *only* legal way to move/delete a user-editable path (tripwire-grep forbidding `FileManager.moveItem`/`.write(to:` on `manuscript/`/`pieces/*/` outside `Document`). This dissolves 0.1, 1.3, and prevents the next bespoke mover from re-introducing the class.
- **The op log is the source of truth, but recovery secretly depends on the parsed `.md` + `reconcile` heuristics** (Tier 2, Deriver bullet). Long-term fix is to retire legacy logs (tripwire 11: delete, don't migrate) and make `Deriver.derive` itself return a `sequence`-projected `paragraphs` so no consumer can walk orphan keys.
- **`Op.at` is dead weight for correctness** — wire it into LWW (0.2) or document that opId order is authoritative and `at` is display-only.
- **The grep tripwires (`TripwireGrepTests`, `TripwirePhoneGrepTest`) catch *spellings*, not *semantics*.** The Mac one forbids exactly one literal (`hasPrefix("d_")`); any other hand-rolled docId parse passes clean. They're recurrence-trippers, not fences — which is fine, **but the docs (CLAUDE.md tripwire 19) oversell them as "fail the build on hand-rolled copies."** The real safety net is the integration tests that round-trip through the Mac's own readers. Neither tripwire has a meta-test proving it actually fires on a planted offender.
- **Largest files today:** `ProjectWindow.swift` (1137), `EditorCoordinator.swift` (851), `ProjectStore+Structure`/`+CollectionPieces`/`+Research` (~760 each), `ScreenplayMode` (738), `DocumentStore` (651). EditorCoordinator's decomposition is mostly right (pure logic already extracted); the one extraction worth doing is the Tab-cycle range arithmetic (untested glue where an off-by-one corrupts a line). DocumentStore conflates document coordination with the inbox/transcription worker lifecycle — extract the worker.
- **EditorHost binding contract is genuinely safe-by-construction** (single binding + `applyExternalTextCallCount` assertion), not merely not-crashing. The one watch-item: the read-only `.onChange(of: displayText)` metrics mirror at `EditorHost.swift:136` — mark it read-only-by-contract so a future edit can't reopen the triad race.
- **Smart-typography knowledge is split** across the pure transform (decides *whether*) and the coordinator (decides *how much to consume*) — the split is what makes 1.1 possible. Have `transform` return the full replacement range (or consume-count) so the two can't drift.
- **Membrane (MCP never writes manuscript) is convention, not type.** A `set_piece_style`-style `LaTeXSafeFilename` wrapper + a typed `WritableResearchPath`/`WritablePublishPath` (analogous to `MaughamSidecarPath`) would make 1.4 and a future stray write compile errors.
- **`CompileOrchestrator` two-phase commit gap** (self-documented TODO): if `publicationStore.append` succeeds then `configStore.save` throws, the version counter desyncs and the next compile is blocked until manual `set_publish_config`. `CompileOrchestrator.swift:138`.
- **Stray identity literals** outside `BuildVariant` (tripwire 13 spirit): `ProjectFolderPresenter.swift:28` (`"com.maugham.…"`), `Publish/TectonicCache.swift:16`, `Updates/GitHubReleasesAPI.swift:61`.
- **`ScreenplayLayoutManager` is possibly dead** — no installation site found in the active surface (display-uppercase is the option-A fallback). Confirm alive-or-delete, same category as the removed CharacterAutocompleter.

---

## CI / build infrastructure

- **There is no CI that runs tests on push or pull request.** Both workflows
  (`release.yml`, `phone-release.yml`) are **tag-triggered** — the suite runs
  *only* when cutting a release. A regression can sit green-looking on `main`
  or a feature branch until release time. For a "trust me with your novel" app
  this is the biggest single process gap. **Fix: a `ci.yml` running both schemes'
  tests on push/PR to `main` + feature branches** (the `session-start-hook`
  skill exists for exactly this on web sessions).
- `SWIFT_TREAT_WARNINGS_AS_ERRORS: NO` + Swift 5.10 language mode means warnings
  and latent Swift-6 strict-concurrency issues accumulate silently with nothing
  to catch them. A periodic `SWIFT_STRICT_CONCURRENCY=complete` build surfaces
  the latter incrementally.

---

## Test gaps (ranked, cross-cutting)

1. **Skewed-clock cross-device same-paragraph LWW** (0.2) — the single highest-value missing test. `CrossMacMergeTests` today only proves dedupe/sort and *bakes in* first-wins-on-collision (0.4).
2. **Torn/truncated final op-log line → quarantine, never silently into the op stream** (0.6).
3. **Wiki-rename against an OPEN target doc** (0.1) — assert the rewrite survives via the op log (it currently can't).
4. **Manifest self-save echo** (1.2) — assert the Mac's own save does NOT produce a `manifest-*.json` conflict.
5. **PendingBuffer device-partitioning / concurrent multi-device crash recovery** (0.3).
6. **Smart-typography over a selection** (1.1) — the verified-bug path; zero coverage of `replacementRange.length > 0`.
7. **RenderFilter tier-2-vs-tier-3 short-paragraph mis-pairing** (Tier 2) — AREA.md admits it's missing.
8. **End-to-end external edit → presenter → Reconciler → ingest** on near-duplicate paragraphs — the most under-tested core seam (classifier is unit-only).
9. **Tab-cycle end-states through the live coordinator** (last line / empty doc / Tab-then-type race) — the coordinator's range math is untested glue.
10. **`set_piece_style` LaTeX-injection + `outputs.directory`/`filenameTemplate` traversal** (1.4/1.5) — validator tests likely only cover empty-string.
11. **Backup torn-read fail-safe** and **integrity-check-throws blocks backup** (Tier 2).
12. **Cross-device rewind merge** (`RewindFlowTests` is single-device); **Mac↔phone inbox merge** integration (only per-side units exist).
13. **CommonMark / `InlineEmphasisScanner` parity edge cases** — only 6 canonical asterisk cases; missing unclosed/spaced/intraword/`****`/escaped/mixed, exactly where a hand-rolled scanner diverges from CommonMark and the two surfaces fade different spans.
14. **Grep-tripwire meta-test** — plant a synthetic offender, assert the tripwire fires (guards against a silently-never-matching tripwire).

---

## Consolidated tripwire → fix-class assessment

For each CLAUDE.md / AREA.md known-problem in scope: is it better addressed by
**Architecture** (make the bad state unrepresentable), **Test** (lock in the
behavior), or **Contract** (a typed seam that makes drift a compile error)?

| Known problem | Today | Best lever | Shape |
|---|---|---|---|
| Op log is source of truth for manuscripts | convention; 0.1 writes raw bytes | **Contract + Architecture** | `writeManuscript` accepts only ops; tripwire-grep forbids `.write(to:`/`moveItem` on manuscript paths outside `Document`. `+Search` already proves the op-routed replace path. |
| Close-before-FS-surgery (T14) | convention, already missed (1.3) | **Architecture** | one typed `relocate(plan:)`/`trash(...)` that closes+flushes internally and is the only legal mover. |
| Cross-device LWW by timestamp | opId order, skew-blind (0.2) | **Architecture** | resolve by `(at, opId)`; detect concurrent same-paragraph writes from different `device`s via the `prior` snapshots and surface a conflict. |
| Same-opId dedupe | first-wins, tested as intended (0.4) | **Contract** | non-byte-equal opId collision = corruption → quarantine + deterministic survivor. |
| Per-device JSONL partition (T17) | enforced for op log/inbox; **missed for `.pending.jsonl`** (0.3) | **Architecture** | slug-partition the pending file or move it outside `.maugham/ops/`. |
| Manifest LWW conflict (1.2) | timestamp compare, no echo guard, whole-second | **Contract** | mirror `Document.lastDiskEcho` for the manifest; compare a content hash, not a truncated timestamp. |
| RenderFilter 3rd (bigram) tier | threshold-only, hot path | **Test + Contract** | margin-over-second-best before id reuse; add the missing disagreement test. |
| Orphan paragraph keys linger | ~5 convention trims | **Contract** | `Deriver.derive` returns sequence-projected `paragraphs`; no raw `paragraphs` walk downstream. |
| Non-atomic op append (0.6) | `try?`→quarantine on read | **Architecture + Test** | length/checksum-framed lines; plant a torn line in a test. |
| EditorHost binding triad race | single binding + call-count assertion | **Keep (safe-by-construction)** | add the read-only comment at `:136`. |
| Smart-typography char-eating (1.1) | none | **Contract + Test** | `transform` returns the full replacement range; gate on `length==0`; test the selection case. |
| `applyExternalText` 4th caller | call-count test | **Keep (contract)** | sound. |
| MCP research-only membrane | convention (`addResearchTextNote` hardcodes `research/`) | **Contract** | typed `WritableResearchPath`; manuscript paths excluded by type. |
| `styleFile` → LaTeX `\input` (1.4) | path-validated, not TeX-validated | **Contract** | `LaTeXSafeFilename` allowlist value-type at write + emit. |
| Grep tripwires (T13/T19) | catch spellings only; oversold in docs | **Test + Docs** | add a fires-on-planted-offender meta-test; reword CLAUDE.md to "recurrence-tripper, not a fence — the real net is the round-trip integration tests." |
| CharacterAutocompleter dead code | **deleted** | Done | `ScreenplayLayoutManager` is the new alive-or-delete candidate. |

---

## Recommended sequencing

Three tracks, roughly a milestone each, interleaved with feature work — not
"stop everything and refactor."

**Track A — Data-integrity hardening (do first; highest stakes).**
0.1 wiki-rename → route through op log. 0.3 pending-buffer partition. 0.5
hashValue → deterministic hash. 0.6 torn-append framing + test. 0.4
opId-collision contract. Then the design-significant one — 0.2 skew-aware /
conflict-surfacing LWW — as its own brainstorm→spec (it changes resolution
semantics; needs care + the cross-device test harness). Each lands with the
matching Tier-0/Test-gap test.

**Track B — The two enforce-by-construction refactors that prevent recurrence.**
(1) one typed close-and-flush mover for all user-path FS surgery (dissolves
0.1's close-gap + 1.3 + future movers); (2) manifest `EchoState` (fixes 1.2 +
1.5-adjacent equal-timestamp). Plus the CI gate (`ci.yml`) — cheap, high-leverage,
catches the next regression in all of the above.

**Track C — Bounded correctness + perf + docs cleanups (opportunistic).**
1.1 smart-typography, 1.4/1.5 publish path/TeX validation, 1.6 add_note flush,
1.7 socket loop, 1.8 trash restore; the screenplay triple-parse perf collapse;
the CommonMark parity + grep-meta tests; and the doc corrections (tripwire-19
wording, `Op.at` semantics, the recovery-depends-on-`.md` honesty note).
