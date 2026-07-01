# Op-log spine hardening — implementation plan

Spec: `docs/superpowers/specs/2026-07-01-oplog-spine-hardening.md` (read it first — it carries the verified failure analyses and decisions).
Branch: `fix/oplog-spine-hardening`. Phases run sequentially (they share files). Every phase: TDD where a behavior is being fixed (failing test first), build + run the focused test classes, keep the whole suite compiling. Commit per phase with a `fix(oplog):`-style message referencing the finding.

Standing rules for implementers:
- Verify every cited file:line against the working tree before editing — the review cited main at `7ded46d`; the branch may have moved by the time your phase runs.
- Read `Maugham/OpLog/AREA.md` before touching anything under `Maugham/OpLog/` (echo guard = `Document.lastDiskEcho: EchoState`; sweep gated on `_pendingSweep: SweepReason?`; don't add parallel state).
- Test paragraph ids crossing the `.md` ↔ op log boundary must be `ParagraphID.mint()`/`mintUnique` or 4-char literals from `[0-9a-hjkmnp-tv-z]` (CLAUDE.md tripwire 8).
- MaughamCore is Apple-frameworks-only; cross-module symbols need `public`.
- Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/<Class> CODE_SIGNING_ALLOWED=NO` for focused runs. `./gen.sh` only if `project.yml` or package sources change.

## Phase 1 — F1: ordering-only edits persist (Task #1)

Files: `Maugham/OpLog/Document.swift` (`flushBurstNow` ~:667, `setFullText` ~:461), `Maugham/OpLog/Document+Load.swift` (recovery fold ~:229), tests in `MaughamTests/OpLog/`.

1. Failing tests first, in a new `OrderingOnlyPersistenceTests` (seed via `OpLogSeedTestHelper`):
   - `test_deleteParagraph_thenCloseAndReload_staysDeleted`: bootstrap A,B,C → `setFullText` without B (no other text change) → `close()` → fresh `Document.load` → paragraphs are A,C.
   - `test_deleteParagraph_crashBeforeBurst_recoversFromPendingSequence`: same but simulate crash (no `flushBurstNow`/`close`; drive `performAutosave` so the pending file holds `{sequence:[a,c], changes:[]}`) → fresh load → A,C, and exactly one recovery op appended.
   - `test_cleanQuit_pendingSequenceMatchesDerived_noJunkRecoveryOp`: normal edit → close → reload → op count unchanged by the load (the difference-check guard).
   - `test_emptyChangesTypingBurst_sequenceHonoredByDeriver` (MaughamCore `DeriverTests` if more natural there).
2. `flushBurstNow`: restructure so `_orderingDirty && !hadPending` emits an op with `changes: []`, `sequence: sequence`. Shared post-append bookkeeping (`_opLogMirror`, `_orderingDirty=false`, keyframe counters, `pending.clear()`, `invalidateTasksCache()`) applies to both arms; annotation cache invalidation stays gated on `hadPending`, sweep stays on `_pendingSweep`.
3. Load fold: extend the `!pending.isEmpty()` gate — also fold when `pending.isEmpty() && !pending.sequence.isEmpty && pending.sequence != derived-sequence-so-far`. You need the derived sequence before the fold: derive once from `ops` to compare (cheap relative to load), or compare against the last explicit sequence walked from `ops` — implementer's choice, but the junk-op guard must hold (see test 3). Legacy pending files load `seq == []` → skip (existing behavior).
4. Confirm `Deriver.deriveWithSequenceFallback` treats an empty-changes typingBurst with a sequence as an ordering-only op (the 2b926fc skip is `.bootstrap`-only — leave it that way; add the pin test).
5. Update the `PendingBuffer` doc comment (`Maugham/OpLog/PendingBuffer.swift:25-30`) and the `flushBurstNow` comment block to describe sequence-only bursts.

## Phase 2 — F2: anchored file + empty log bootstraps with identity preserved (Task #2)

Files: `Packages/MaughamCore/Sources/MaughamCore/Bootstrap.swift`, `Maugham/OpLog/Document+Load.swift` (`reconcile` branches, `parsed: []` comment), `MaughamCore` tests + `MaughamTests/OpLog/LoadFromOpLogNotMdTests.swift`.

1. Failing tests: anchored `.md` (all paragraphs carry ids) + NO op-log files → `Document.load` → content present, paragraph ids == the file's anchor ids, exactly one bootstrap op + initial checkpoint appended. Second load appends nothing (idempotency, now meaning "op log non-empty → Bootstrap not even called"). Also the crash-mid-import shape: run `Bootstrap.run` on an un-anchored file, delete the op log it wrote (keeping the anchored `.md` it produced), re-run load → content survives with the same ids.
2. `Bootstrap.run` `allHaveIds` branch: check the doc's op log via `OpLogStore.opLogFileURLs(forDocId:in:)`; when non-empty keep today's no-op return; when empty, build `changes`/`sequence` from the parsed anchored paragraphs (existing ids, mint nothing), emit the bootstrap op + initial checkpoint (reuse the existing tail of `run`), do NOT rewrite the `.md`, return `bootstrapped: true`.
3. Re-check `BootstrapTests.test_bootstrap_isIdempotent*` — retarget to the new contract rather than deleting.
4. Delete `Document.reconcile` branches 1–3 (`Document+Load.swift:12-104`) and the `parsed:` parameter if nothing else uses it (branch 4's orphan-drop stays; simplify signature to `reconcile(derived:)` and fix call sites/tests). Fix the stale "still ANCHORED … Task 3" comment (~:249-251) while in the file.

## Phase 3 — F4 + F8: load-time divergence snapshot; backup root via resolveProjectURL (Task #3)

Files: `Maugham/OpLog/Document+ExternalChange.swift` (`writeConflictBackup` ~:90-106), `Maugham/OpLog/Document+Load.swift`, `MaughamTests/OpLog/` + a Collection-layout test.

1. Failing tests: (a) edit the `.md` on disk while no Document is live, then `Document.load` → a snapshot of the external bytes exists under `<project>/.maugham/conflicts/` and the loaded content is op-log truth; (b) load the same divergent file twice → one snapshot (dedup); (c) unmigrated anchored file with content EQUAL to op-log truth → no snapshot (display-form comparison); (d) Collection piece at `pieces/<NN>-<slug>/<file>.md` → snapshot lands under the PROJECT's `.maugham/conflicts/`, not `pieces/.maugham/`.
2. `writeConflictBackup`: use `resolveProjectURL(for: url)` (already in `Document+Load.swift`) for the root. Extract it somewhere both files reach if needed.
3. `Document.load`: after `initial` is computed and only when `logExists` was true, compare `MarkdownDisplayFilter.stripAnchors(storedBytes)` with the derived display render; on mismatch write the snapshot (reuse the backup writer; never abort the load on backup failure — log via `documentLog.error`). Dedup: byte-equal to the newest existing snapshot for this doc → skip.
4. `performAutosave` (`Document.swift:225`): replace `try? await pending.flushToDisk()` with a do/catch that logs (`documentLog.error`) — matches `close()`'s catch.

## Phase 4 — F6: live-Document branches close the staleness window (Task #4)

Files: `Maugham/Publish/ProjectStoreASTSource.swift` (~:40), `Maugham/Stores/ProjectSearchEngine.swift` (~:36), `Maugham/MCP/ListAllLinksTool.swift` (~:69), `Maugham/MCP/ReferenceTools.swift` (FindReferencesTool ~:166), `Maugham/MCP/DocumentTools.swift` (word_count ~:83), tests beside the existing `*OpLogSourceTests`.

1. Establish how each site can reach the open-doc registry — `DocumentTools.swift:77-81` (`ds.document(for:)` → `doc.materialize()`) is the canonical pattern; `ProjectStoreASTSource` and `ProjectSearchEngine` may need the `DocumentStore` handed in (check what they already hold; `ProjectStore+Search.swift:176-190` already resolves live docs for replace).
2. Failing tests: open a doc, mutate via `setFullText` WITHOUT flushing the burst, then (a) build the AST, (b) run project search, (c) call list_all_links / find_references — each sees the unflushed text. Closed-doc behavior unchanged (existing tests).
3. Implement: doc open → use live `materialize()`/`displayText`/`paragraphs`; closed → `DerivedManuscript` as today. Delete/replace the misleading pre-search `flushPendingSave` comment (`ProjectStore+Search.swift:9-10`) — keep the research-note flush, it's still correct for research.
4. `read_document` word_count: compute over `MarkdownDisplayFilter.stripAnchors(...)` of the body it returns. Pin with a test (anchored doc: count excludes anchor tokens).
5. Close the roadmap follow-up from 33bf684 (edit in Phase 8, note it here).

## Phase 5 — F5: DerivedManuscriptCache + off-main sweeps + perf guards (Task #5)

Files: new `Packages/MaughamCore/Sources/MaughamCore/DerivedManuscriptCache.swift` (or Mac-side if MainActor coupling demands — prefer Core, Foundation-only), adopters: `ProjectSearchEngine`, `ProjectStore.populateWordCountCache` (~:222), `ProjectStore+Structure.swift` wiki-rename pre-check (~:421), `ListAllLinksTool`/`ReferenceTools`; template: `ProjectStore+Tasks.swift:127-148`. Tests: new `DerivedManuscriptCacheTests` (Core) + adoption tests (Mac).

1. Cache contract: key = docId; validity token = sorted (url, mtime, size) of `OpLogStore.opLogFileURLs(forDocId:in:)`; value = derived state + materialized text. `get(docId:)` returns cached when the token matches, else derives and stores. Instance per project (owned by `ProjectStore` or `DocumentStore` — pick the owner the adopters can all reach; document the choice in the Stores AREA.md in Phase 8).
2. Adoption: all four sites route closed-doc derivation through the cache (open-doc live branches from Phase 4 bypass it). Wiki-rename's double-derive (pre-check + `Document.load` of matches) — have the pre-check reuse the cache; the `Document.load` cost stays (it's the real editing path).
3. Off-main: `populateWordCountCache` leaves the blocking path of `ProjectStore.load` — populate asynchronously after load returns (post-window), per-doc `Task.yield()`, publishing counts as they land (check what observes the cache; keep SwiftUI updates on main). Search: with the cache + live branches, keystroke-repeat cost collapses; additionally `Task.yield()` between docs stays, and add a cancellation check before each doc's derive.
4. Perf guards (derive-count, not wall-clock): instrument the cache with a test-visible derive counter; assert (a) second identical search performs 0 derives, (b) project-open + first search performs ≤1 derive per doc, (c) editing one doc invalidates only that doc.
5. `ProjectStatisticsWindow.swift:45` runs a fresh `ProjectStore.load` per open — verify with the async population this no longer re-blocks; if it still full-sweeps, reuse the owning project's store/cache instead.

## Phase 6 — F3 + F7: first-bootstrap-wins, discard damping, conflicts retention (Task #6)

Files: `Packages/MaughamCore/Sources/MaughamCore/Deriver.swift`, `Maugham/OpLog/Document+ExternalChange.swift`, Core `DeriverTests` + Mac external-change tests.

1. Deriver: during fold, honor only the FIRST `.bootstrap` op (ULID order); skip later ones entirely (changes + sequence) and surface a diagnostic (a returned note or `Logger` — match existing Deriver error-reporting style). Tests: re-mint bootstrap after a real history is inert; single-bootstrap behavior unchanged; two bootstraps where the SECOND is the legitimate one is impossible by construction (first-wins is the rule — document).
2. Damping in `handleExternalDiskChange`: per-Document counter of discards-with-distinct-bytes; after 3 within a session, snapshot-only (no rewrite) + `documentLog.error` once; reset on any local edit (`setFullText`/`setParagraph`). Test with three synthetic distinct external changes.
3. Retention: after a successful snapshot, prune `<project>/.maugham/conflicts/` to the newest 20 files per docId (filename already carries docId + stamp — verify format first). Test.

## Phase 7 — F9: tripwire broadening + phone contract (Task #7)

Files: `MaughamTests/TripwireGrepTests.swift` (~:406-492), `MaughamPhoneTests/TripwirePhoneGrepTest.swift`, `docs/superpowers/notes/cross-surface-contracts.md`, annotations across production files.

1. Rewrite `test_noManuscriptFileReadsOutsideReconciler`: scan all `.swift` under `Maugham/` AND `Packages/MaughamCore/Sources/`; widened patterns per spec decision 8; every non-comment hit requires `// adr-0018-ok: <reason>` on the line. Share the pattern list + exclusion logic as constants with the planted-offender self-test (fix the current duplication). Annotate every legitimate hit (research, manifests, sessions, UI state, publish files, help, inbox, checksum reads, the two sanctioned manuscript sites, Bootstrap's import read) — each annotation's reason must say what the read is, e.g. `// adr-0018-ok: research note, not a manuscript`.
2. Phone twin in `TripwirePhoneGrepTest`: same patterns over `MaughamPhone/`; annotate `CoordinatedFileIO.swift:68` / `DocumentReaderView` display read as `// adr-0018-ok: contracted display read — see cross-surface-contracts.md`.
3. `cross-surface-contracts.md`: add a contracted-divergence row for "phone Read tab renders the on-disk `.md` (display only; anchors/sequence still derive from the op log via AnnotationLoading)".
4. Both tripwire suites green on both schemes.

## Phase 8 — docs, comments, context files (Task #8)

All prose; use haiku-grade mechanical passes but review the ADR addenda carefully.

1. ADR 0019 addendum #2: F1/F2 fixes (sequence-only bursts; allHaveIds seeding), load-time divergence snapshot completing the backup-on-discard net, discard damping + retention, first-bootstrap-wins + residual partial-sync risk, correct line 17's "removed every reader" (phone display read, now contracted).
2. ADR 0018 addendum: open-doc rule now ENFORCED at the four converted sites (live branches); staleness for any remaining always-derive consumer is the burst window (30s/90s), not 750ms; tripwire is now annotation-based across Mac+Core+Phone; DerivedManuscriptCache noted.
3. `docs/roadmap.md`: close/correct the 33bf684 follow-up (list_all_links/find_references freshness — fixed; fix its "~750ms"); check for other items this branch closes (e.g. audit item phrasing about conflicts backups).
4. `Maugham/OpLog/AREA.md`: sequence-only bursts, load fold rule, divergence snapshot, damping, first-bootstrap-wins. `Maugham/Stores/AREA.md`: DerivedManuscriptCache owner + word-count async population. `Maugham/MCP/AREA.md`: live-branch freshness note if it documents read staleness.
5. CLAUDE.md: "Outstanding correctness concerns" — remove anything this branch fixes; add none unless real. Check the hard-invariants bullet for the op log still reads true (it does; no edit unless phrasing now wrong).
6. Stale comments not already fixed in earlier phases: `CrossDeviceIntegrationTests.swift:10,156-157`, `LoadFromOpLogNotMdTests.swift:10-13` header, anything `git grep -n "Reconciler.classify"` still finds.
7. Dead code: delete `Reconciler.classify` + its tests (verify only `ReconcilerTests` references it; keep any parts of `Reconciler` still used — check first), delete `EchoState.afterIngest`.

## Phase 9 — verification (Task #9)

1. Full Mac suite; full phone suite (`-scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17'`). Simulator "Busy" = flake, re-run.
2. `git diff main` review pass by a fresh reviewer subagent against the spec (every finding F1–F9 + minors addressed or explicitly deferred; no `project.pbxproj` in the diff; no stray hardcodes per tripwire 13).
3. Hand the user a manual smoke checklist: delete-paragraph-then-quit-then-relaunch; delete `.maugham/` on a test project → open → content intact; edit `.md` in TextEdit while app closed → open → conflicts snapshot exists; type → compile immediately → newest sentence in the PDF; big-project open feels instant; search while typing.
