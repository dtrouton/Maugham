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

---

# Addendum — Pattern investigation (three exhaustive sweeps)

After the initial audit we asked: are these findings *tells* of a systemic
pattern? Three read-only sweeps were run to size the blast radius of the three
patterns the audit implied. The result **revises** the initial "systemic rot"
read in a specific, useful way (see the synthesis at the end).

## Sweep 1 — every raw filesystem write/move on a user-content path

Exhaustively classified ~35 `write(to:)`/`moveItem`/`copyItem`/`removeItem`
sites against the two required disciplines (manuscript → must route through
`Document.setFullText`/op log; research note → raw atomic write but
flush-before-move per tripwire 14; `.maugham/`/derived → free).

**Verdict: the discipline is honored almost everywhere.**
- **Exactly ONE manuscript-corruption bug, no siblings:** `ProjectStore+Structure.swift:394` (`propagateWikiLinkRename`) raw-writes manuscript bytes (finding 0.1). Every other manuscript-touching site (Search replace, rename/move/delete of docs, piece-folder moves, the materialize render) correctly closes the Document or routes through the op log.
- **ONE phantom-file ⚠️ (not corruption):** `movePiece`/`renamePiece` (`ProjectStore+CollectionPieces.swift:634/640/720`) move the whole piece folder (manuscript + `research/`) but close only the manuscript `Document` — they don't `flushPendingSave()` the piece's research-note debounce, so a pending research save can land at the old path post-move (finding 1.3). `promotePieceToProject` does it correctly (`flushPendingSave()` at line ~200); these two omit it.
- Everything else (MCP add_note/publish/piece-style, trash, inbox, manifest, Exports, update staging, project creation) is correctly confined or guarded.

→ Pattern 1 is **real but isolated**, not systemic. The wiki-rename bug is a single lapse from an otherwise-honored convention.

## Sweep 2 — every presenter-watched file's write-side echo guard

The project-root `NSFilePresenter` → `DocumentStore.presenterDidChangeSubitem`
→ `MaughamSidecarPath.classify` routes 21 path-classes; **only 4 react**.

| Watched class | Write-stamp? | Compare basis | Guard | Verdict |
|---|---|---|---|---|
| Manuscript `.md` | yes (`Document.swift:176`) | content bytes | typed, unbypassable (`EchoState`) | ✅ gold standard |
| Op-log JSONL (Document writes) | yes (`_opLogMirror`) | opId-set | ad-hoc | ⚠️ |
| Op-log JSONL (**CheckpointCapture ⌘S**) | **no** (separate `OpLogStore` instance) | opId-set (read side) | none | ⚠️ one wasted re-derive per ⌘S; self-heals; `.checkpoint` is a derivation no-op so no data loss |
| Manifest `project.maugham.json` | **no** (`writeManifest` never stamps `lastObservedManifestModified`) | **timestamp, whole-second-truncated** | ad-hoc bare `Date?` | ❌ spurious `.maugham/conflicts/manifest-*.json` on every structural edit (finding 1.2) |
| 17 other classes | n/a | none | n/a (explicit no-op or idempotent refresh) | ✅ safe by construction |

**Verdict: contained.** One real bug (manifest), one minor ⚠️ (CheckpointCapture
mirror gap), 17 safe. A *generalized* `EchoState`-for-all-sidecars would be
**overkill** — the right fix is narrow: give the manifest a content-hash + a
write-side stamp (a small typed guard justified *here* because the reaction is
destructive), and have CheckpointCapture append through the live Document (or
pre-seed its mirror). Leave the rest.

Secondary note: the op-log read-side guard (`Document+ExternalChange.swift:66-68`)
filters by opId-set membership only — a *content* change to an already-seen opId
is invisible (the read-side mirror of finding 0.4). Sound today only because
ULIDs are unique; the same dedup is what silently drops a divergent-content
opId collision.

## Sweep 3 — data-integrity tests: correctness vs. pinned current behavior

Audited the integrity-critical suites for tests that pass while the behavior is
wrong. **This is the sweep that found the systemic thing.**

| Test | Anti-pattern | Severity |
|---|---|---|
| `CrossMacMergeTests.swift:30-39` | **Asserts the bug** — two ops, same opId, different text; asserts `"A-1"` survives "purely because it loaded first" (`// LWW: 01HZK02 wins`). Certifies silent cross-Mac data loss as intended (matches 0.4). | **Critical** |
| `OpLogStorePartitioningTests.swift:63` | Round-trip-can't-fail — duplicates `op-a` with **byte-identical** payload through the real loader, so the dangerous divergent-content merge is never exercised. | High |
| `ReconcilerTests.swift` (whole file) | **Untested path** — echo/edit/strip cases only; **no external-deletion test.** `Reconciler.classify:29-37` iterates disk paragraphs only, so a paragraph deleted on disk classifies as `.echo` and **survives in derived state**. Silent deletion-drop. | High |
| `DeriverTests.swift:51-60` | Asserts-a-convention-as-correctness — blesses "deriver applies in argument order, ignores opId"; cements the unenforced "caller must sort" precondition that 0.4's determinism rests on. | Medium |
| `DocumentReconcileTests.swift:49-58` | Indistinguishable assertion — branch-3 ".md↔op-log precedence" test uses the same text (`"old"`) on both sides, so it passes regardless of which source wins. | Medium |
| `RenderFilterTests.swift:19-30` | Adversarial gap — only the easy minor-edit id-reattach; no drastic-rewrite case where the char-bigram tier mis-pairs (id-swap = identity corruption). | Medium |
| `AddNoteToolTests.swift` | Happy-path only on a membrane invariant — no negative test that an escaping title/path is rejected (contrast `PublishFileToolsTests`, which does test `..`/null/leading-slash). | Medium |
| `AnnotationKindContractTests` (both targets) | Tautology-adjacent — two hand-synced literal copies; either can drift to a wrong value without failing. | Low-Med |
| `IntegrityChecksTests.swift:73` | Weak-net-as-coverage — confirms the integrity scan does NOT enforce the canonical paragraph-id alphabet (correct per tripwire 8), but the suite reads as if it guards the `.md`↔op-log join key; it doesn't. | Low-Med (design gap) |

**Genuinely strong (catch real regressions):** backup/restore + bisect,
Merkle tamper/missing, conflict-twin + dangling-pointer, `PresenterRoutingTests`
(asserts *absence* of the over-archive/re-ingest bugs), annotation lifecycle,
accept-contract, crash-recovery, `ParagraphID` alphabet gate, the
`PublishFileTools` path-validation negatives.

**Coverage estimate:** ~2/3 of integrity-critical seams have tests that would
catch a regression; the weak ~1/3 is concentrated **precisely at the
cross-device op-log merge / reconcile boundary** — the highest-stakes surface.
The single most load-bearing seam (opId-collision resolution) is guarded by one
test that *certifies the data loss as correct.*

## Synthesis — the actual tell

The two FS/state sweeps came back **reassuring** (one isolated bug each, not
systemic); the test sweep came back **concerning** (the net has holes exactly
where the stakes are highest). Reconciled, they reveal the real pattern:

**The bug distribution is a photographic negative of the feedback the code
gets.** Every confirmed silent-divergence bug lives in a spot that is
simultaneously (a) invisible to a solo writer on one Mac smoke-testing by feel,
and (b) covered by a test that is absent, happy-path-only, or *pins the bug*:
- 0.2 / 0.4 cross-device LWW & opId-collision → no multi-device feel; the one test certifies the loss.
- 0.1 wiki-rename to a *closed* doc → silent until reopened; membrane tests are happy-path.
- 1.2 manifest self-archive → just litters a hidden dir; the test only covers the external case.
- Reconciler external-deletion → no test at all.

Conversely, everything with daily smoke exposure (editing, rename, ⌘S) **or** a
real adversarial test (backup, Merkle, presenter-routing) is correct. The
disciplines (op-routing, close-before-FS, echo guards) are honored almost
everywhere — because those paths get exercised. **The bugs aren't scattered;
they cluster where feedback is absent.** This rhymes exactly with the
2026-05-19 audit's lesson ("suite always green, user found the bugs by typing")
— a month later, same shape, moved from the editor seam to the merge seam.

Two consequences that change the plan:
1. **A test that asserts the bug is worse than no test** — it blocks the fix.
   `CrossMacMergeTests`, `OpLogStorePartitioningTests`, and `DeriverTests`
   are load-bearing in the *wrong direction*: you can't correct
   `JSONLAppendStore`'s blind first-wins without "breaking" them, which reads
   as a regression. **Rewriting these three tests is a prerequisite to fixing
   0.2/0.4, not a follow-up.**
2. **The highest-leverage single move is to build the cross-device merge /
   reconcile integration harness and make it adversarial** (skewed clocks,
   divergent-content opId collision, external deletion, drastic-rewrite
   id-reattach). It simultaneously (a) closes the worst coverage gap, (b)
   forces the 0.2/0.4/Reconciler-deletion fixes to be correct, and (c)
   installs the feedback loop whose absence generated these bugs. Pair it with
   the `ci.yml` gate so the loop actually runs.

Net: the codebase is **better-disciplined than the bug list suggests** — but its
safety net has a hole shaped exactly like its riskiest feature (multi-device
sync), and one corner of the net is sewn to the bug. Fix the net at that seam
first; the data-correctness fixes follow naturally and land verified.

---

# Addendum 2 — Round-2 sweeps (concurrency, updater, cross-version schema, silent `try?`)

Four more blind spots checked after the first addendum. Two came back clean
(reassuring negative results), two found real items. Same thesis holds: the
bugs live where there's no feedback.

## Sweep 4 — MCP-thread vs main-actor concurrency: CLEAN ✅
The headline worry — an MCP handler racing the user's typing on the op
log/manifest — **does not exist.** The socket transport runs off-main
(`MCPServer.swift:91,132` `Task.detached`/`DispatchQueue.global`, blocking POSIX
wrapped in continuations — correct), but `await router.dispatch` (`MCPServer.swift:207`)
re-isolates onto `@MainActor`, and every store (`ProjectStore`, `DocumentStore`,
`Document`, `InboxStore`, the op-log `JSONLAppendStore`) is `@MainActor @Observable`.
A Claude annotation append and a typing-burst flush are mutually exclusive by
main-actor serialization. Two concurrent MCP connections both collapse to main
at the dispatch hop. This is the textbook-correct shape; an `actor` redesign
would be a regression (it'd lose the free serialize-with-UI). `SWIFT_STRICT_CONCURRENCY=complete`
would be quiet on this seam — its noise (the audit's "lurking warnings") is in
the editor's AppKit-delegate / `Sendable`-closure code, not the store writes.

## Sweep 5 — Auto-updater: security CLEAN ✅, one brick-risk should-fix ⚠️
Verification chain is **sound and correctly ordered**: `codesign --deep --strict`
+ `spctl` notarization + Team-ID matched against the **running app's own**
signature (`UpdateInstaller.swift:78-89`, not an attacker-controllable constant),
all on the **same staged bytes** that get installed — **no TOCTOU window**
(verified path at `:160` == returned path at `:164` == helper's `ditto` source).
No downgrade (strict `>` `UpdateChecker.swift:57`) or dry-run/prerelease install
(`/releases/latest` excludes prereleases + CI marks patch≥90 prerelease).
Detached helper: random-named per-user `$TMPDIR` path, no elevation, no
privilege-escalation hijack. Verification failures throw, never fall through.

**The one ⚠️ (medium, brick not security):** the final swap is
`rm -rf "<installed>"` then `mv` (`UpdateInstaller.swift:53-54`), **not** the
atomic rename the spec promised. New bundle is safely pre-staged as a same-volume
`.inflight` sibling (crash mid-copy is harmless), but a crash/power-loss in the
narrow `rm`→`mv` gap (or a cross-volume `mv`) leaves `/Applications/Maugham.app`
**missing** → unlaunchable until manual reinstall. Same-volume sibling means a
one-line fix to an atomic exchange (`FileManager.replaceItemAt` / `renameatx_np(RENAME_SWAP)`).

## Sweep 6 — Cross-version Codable tolerance: real, ranked ❌/⚠️
Phone and Mac ship on independent release trains and auto-update means a project
is routinely touched by two app versions, so cross-version reads are normal, not
edge. Findings:

| Type | Unknown enum case | Blast radius | Severity |
|---|---|---|---|
| `ProjectType`, `StructureItem.ItemType`, `ResearchItem.AssetKind`, `PieceKind` (in `project.maugham.json`) | **throws** (even the `Optional` ones — synthesized Optional decoder still calls `init(from:)` when the key is present) | **whole manifest undecodable → project unopenable** on older build (no per-line quarantine for a single JSON file); on phone the project silently disappears from the list | **High** |
| `OpKind`, `SynthesisSource` (op-log JSONL) | throws at the `Op` level | **single line quarantined** by `JSONLAppendStore.parseDiagnosed` — op log keeps loading. **But** a skipped `.typingBurst` → those manuscript edits are silently invisible on the older reader (stale text, mis-marked annotation staleness) | Med |
| `InboxEntry.Kind`/`TranscriptionState`/`Status`, `Checkpoint.LabelSource`, `PublishConfig.Format`/`StartOn` | throws | single JSONL row skipped (inbox/checkpoint) or whole config unloadable (publish, Mac-only, mostly `?? PublishConfig()` fallback) | Low-Med |
| `BinderSegment`/`DetailSegment`/`OutlineLayout` (`ui-state.json`) | **tolerant** `(try? decode) ?? .default` | falls back to default | ✅ (the template) |

Two structural gaps behind these:
- **`schemaVersion` on the manifest is declared but never checked** (`ProjectManifest.swift:12`; no caller compares it) — purely documentary. `UIState`/`SessionLog` *do* guard it correctly and are the in-codebase template.
- **`IntegrityQuarantine` is not wired to the normal op-log load path** — it's only invoked from `ProjectIntegrity.check`, which only runs from the backup gate (`BackupCoordinator.swift:43`). So in everyday operation, quarantined (unknown/torn) op lines are **silently dropped with no forensic record**; the v0.8.0 quarantine safety net isn't engaged on the hot path. Swapping the load call to `loadDiagnosed()` + `IntegrityQuarantine.record(...)` at the one `Document+Load` site closes it.

Cheapest high-leverage fixes (ranked): (1) add an `unknown` fallback case to
`OpKind` + `SynthesisSource` — `Deriver.appliesToManuscript`'s exhaustive switch
then turns a silent-quarantine-data-loss into a **compile error** forcing the
dev to handle the new case; (2) same for the four manifest enums (or custom
`init(from:)` returning a safe default) — converts project-unopenable into
graceful degradation; (3) custom `init(from:)` with `decodeIfPresent`+defaults
for `TypographySettings` (8 non-optional fields, a landmine for the next add);
(4) `schemaVersion` guard on `ProjectManifest` load (explicit "requires a newer
Maugham" instead of silent misparse); (5) wire `IntegrityQuarantine` into the
load path.

## Sweep 7 — silent `try?` on op-log writes (cross-cutting)
~255 production `try?`; the large majority are legitimate cleanup/rollback
(`removeItem` on staging, idempotent `createDirectory`, scratch teardown,
partial-file cleanup — you don't care if those fail). The dangerous subset is
`try?` on **source-of-truth writes**:

- **`Document.close():593` — `try? await flushBurstNow()` (Tier-0-class).** `close()`
  runs on app quit **and** every FS-surgery path (rename/move/delete). If the
  final burst-flush to the op log fails, **the last burst of edits before the
  close is silently lost** — no signal, no retry. The edits you most want to
  survive are exactly the ones this drops on a write error.
- **`PartialRestorePicker.swift:92` — `try? await opStore.append(restoreOp)`** —
  a partial restore looks done in the UI but the op silently isn't persisted on
  a write failure.
- **`Document+Tasks.swift:199`, `ProjectStore+Tasks.swift:83`, `InboxStore.swift:107`** —
  task/inbox ops appended with the error swallowed → action looks done, isn't durable.
- **`DocumentStore.swift:649` — `try? data.write(conflictBackupURL)`** — the
  conflict backup (the *loser* of a cloud conflict — the safety net) silently
  vanishes if the write fails.

Encouraging contrast: the **core manuscript burst-flush** (`Document.flushBurstNow:553`)
and the **annotation appends** (`Document+Annotations:120/216`) correctly use
`try await` and propagate. So the discipline exists — only the secondary
op-log paths and the close-time flush regressed to `try?`. Fix: propagate (or at
minimum log/retry/quarantine) on every op-log append and on the close flush;
`close()` swallowing the flush is the one to treat as Tier-0.

## Round-2 synthesis
The two security/concurrency worries (MCP race, updater verification) came back
**clean** — the security-sensitive subsystems are well-built. The two that found
items are both **"the failure that hasn't happened yet"**: cross-version schema
breakage needs a *future* enum case to bite, and the silent-`try?` op losses need
a *write to fail*. Both are, by definition, zero-feedback today — which is
exactly why they drifted, and exactly why `UIState` (a frequently-exercised,
user-visible type) got the defensive decoder while `Op`/`ProjectManifest` (no
v2 has shipped, so no one's felt the break) did not. Same photographic-negative
pattern, one more time. The fixes are cheap and mostly compile-time-enforcing
(`unknown` cases that make `Deriver`/manifest switches refuse to build until the
new case is handled), so they're high-leverage to land *before* the next schema
change rather than after a user's project won't open.
