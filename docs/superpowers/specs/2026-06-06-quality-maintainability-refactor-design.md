# Quality & Maintainability Refactor — Design

**Date:** 2026-06-06
**Status:** Approved (design), pending implementation plan
**Origin:** Four parallel codebase audits (editor/oplog, stores/models, views/MCP/publish, core/phone/tests) commissioned to find quality and maintainability improvements. Supersedes the open items from `docs/superpowers/notes/2026-05-19-state-of-the-code.md` (whose headline findings — Bootstrap wiring, JSONLAppendStore extraction, ProjectStore split, editor integration tests — are all now shipped).

## Goal

Pay down maintainability debt accreted across the Publishing, iPhone-companion, Tasks, and auto-update milestones, and fix two genuine correctness footguns surfaced by the audit. Bundle into one milestone, executed in five risk-ordered phases (safest first), each landing the full test suite green before the next begins.

## Hard constraints

- **No tripwire violations.** In particular: tripwire 5 (don't *revive* CharacterAutocompleter — we are deleting it), tripwire 7/14 (manuscript writes coordinated + close-before-FS), tripwire 8 (4-char paragraph IDs at the .md↔oplog boundary), tripwire 15 (ContentUnavailableView frames), tripwire 19 (no third implementation of a cross-surface contract).
- **Op log is the source of truth.** Every manuscript-text mutation produces ops; the `.md` is derived. This is what drives the Phase 2 Find-Replace rewrite.
- **Behavior-preserving where claimed.** File splits and the tree-walk consolidation must not change observable behavior; they ride on the existing test suite plus targeted new unit tests for any newly-extracted pure function.

## Phases

### Phase 1 — Deletions & fixture hygiene (zero behavior risk)

1. **Delete dead `CharacterAutocompleter`.** Remove `Maugham/Editor/Fountain/CharacterAutocompleter.swift`, the `autocompleter` property on `EditorCoordinator`, `EditorCoordinator.updateAutocomplete(in:)` (~68 lines), and `CharacterAutocompleterDataTests`. Confirmed dead: zero callers of `updateAutocomplete` outside its own definition; only `rankSuggestions` is referenced, and only from the test. Do **not** preserve `rankSuggestions` — if inline-ghost-text is ever designed, it gets a fresh purpose-built utility (tripwire 5: don't wire the old UX back).
2. **Delete dead `ProjectWindow.handleMCPNoteAdded(researchId:title:)`** (`ProjectWindow.swift:999`). Zero callers; stale duplicate of the banner logic inlined in `SessionAndNavigationModifier`.
3. **Replace `print()` straggler-warning** (`DocumentStore.swift:130`) with `os_log`/`Logger` at `.warning`.
4. **Fix fabricated doc-id test fixtures.** Replace `d_01HQ…`/`d_x` literals with real `doc-`/`scene-` shapes in `MaughamPhoneTests/PhoneAnnotationIntegrationTests.swift:22`, `AnnotationWriterTests.swift:17`, `AnnotationLoadingTests.swift:63,72,81`. These pass today only because `OpLogStore.docId` is format-agnostic, so they give false confidence against the phone-v0.1.1 "No open annotations" footgun.
5. **Fix stale doc-comments** describing the wrong `d_<ULID>` id shape: `MaughamPhone/Annotations/AnnotationWriter.swift:19,25,65,67` and `Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift:36`. Real shape is `doc-<hex>`/`scene-<hex>` (ADR 0008). The OpLogStore code is correct (it parses on "no dot," not length); only the prose lies.

**Exit:** both schemes green; no `grep` hits for `CharacterAutocompleter` / `handleMCPNoteAdded` outside history; phone test doc-ids match the corrected sibling tests.

### Phase 2 — Correctness fixes

1. **(A) Delete dead manuscript-write path.** Remove `ProjectStore.manuscriptText` (public var, `ProjectStore.swift:30`), `ProjectStore.save()` (`+Metadata.swift:80`), and `readManuscript` (`ProjectStore.swift:224`) from the load path. These write manuscript bytes straight to disk (`atomically: true`), bypassing the op log, `Document`, and NSFileCoordinator — a direct contradiction of the op-log-is-truth invariant, kept alive only by `ProjectStoreTests`. Prune/rewrite those 3 tests. Verify no other reference (the load-time text was only stored in the dead field; `populateWordCountCache` does its own per-doc reads).
2. **(B) Find-Replace through the op log.** Rewrite `ProjectStore.replaceMatch` and `replaceAll` (`+Search.swift:48-88`) so replacements become op-log paragraph changes instead of raw `.write(to:)`:
   - **Open docs** (present in `DocumentStore` registry): apply the replacement through the live `Document`'s op-log path; no file race, editor stays open and updates.
   - **Closed docs:** `Document.load` (mints anchors, replays log) → apply the replacement as paragraph-change op(s) → persist → the `.md` re-renders from the op log.
   - The char-range→paragraph mapping reuses `Document.paragraphId(at:)`-style offset walking. `replaceAll` still applies right-to-left per document to keep earlier offsets stable. Keep the stale-match out-of-bounds guard (re-run search on mismatch).
   - This is the only Phase 2 item needing new integration coverage: assert (i) replace on an open doc doesn't race autosave and produces an op, (ii) replace on a closed doc round-trips through the op log and survives reopen, (iii) `.md` and op log never diverge.
3. **Dedupe the task-anchor LCS.** `RenderFilter.restoreTaskAnchors`/`restoreLineByLine` are tested-but-unused; `TaskAnchorAlignment` Pass 1 ships a copy of the same algorithm. Wire `TaskAnchorAlignment` to call `RenderFilter.restoreLineByLine` so the property-tested code is the production code. (If a clean call boundary proves awkward, the fallback is to delete the unused public helper and move its tests onto the aligner — but the call-through is preferred because it makes the round-trip test guard production.)
4. **Surface silent failures.** The debounced research-note autosave (`DocumentStore.swift:121`, `try? performFileSave`) drops the user's note silently on a coordinated-write throw; the project-id backfill (`ProjectStore.swift:167-171`, `try?`) silently leaves a project id-less (the class of footgun behind the phone doc-id bug). At minimum `os_log` both; for the autosave, set a UI-readable error flag; make the one-time id backfill non-`try?` (log on failure).
5. **Reconcile dual slug implementations.** `researchSlugify`/`researchDedupedFilename` (`+Research.swift`) and `Slugifier.slug` (MaughamCore, used by `+Structure`/`+CollectionPieces`) differ (empty → `"untitled"` vs not), so the same title can slugify two ways. Fold the research helpers into the shared `Slugifier`/file-naming utility in MaughamCore, reconciling the empty rule.
6. **Route `Publish/ProjectASTBuilder.stripAnchors`** (`:149-165`) through `MarkdownDisplayFilter` — the named single source of truth for anchor stripping. This is the target-local-stripper class that leaked anchors on the phone twice. (The duplicate inline Fountain *classifier* in the same file is acknowledged tech-debt and is **out of scope** here — parser unification is a separate, larger effort.)

**Exit:** both schemes green; new Find-Replace integration tests pass; `grep` shows no raw `.write(to:` for manuscript paths in `+Search.swift`; one slug implementation; `stripAnchors` calls `MarkdownDisplayFilter`.

### Phase 3 — Tree-walk consolidation

The single largest cross-cutting duplication: `StructureItem` and `ResearchItem` are both `id + children: [Self]?` trees, and `find`/`mutate`/`remove`/`contains`/`collect`/`rewritePaths`/`idsByPath` are hand-reimplemented ~21× in the stores layer (the `research`-prefixed family exists only to dodge Swift overload limits) and ~15× more across views/MCP — including two duplicate defs inside `ProjectWindow.swift` alone (`findStructureItemByPath` at 415 & 939, `findResearchItemByPath` at 428 & 952).

1. **Add a `TreeNode` protocol in MaughamCore** (`var id: String`, `var children: [Self]?`) plus generic free functions for find / mutate (return-new-tree) / remove / contains / collect / rewritePaths / idsByPath. Foundation-only, value-semantic.
2. **Conform `StructureItem` + `ResearchItem`.** Delete the ~21 store copies and ~15 view/MCP copies. ProjectStore's existing `findItemStatic`/`findItem`/`containsId`/`collectDocuments` become thin forwarders or are replaced at call sites.
3. **Reconcile the path-prefix divergence.** `rewriteChildPaths` uses `dropFirst(oldPrefix.count)`; `researchRewriteChildPaths` uses `dropFirst(oldPrefix.count + 1)`. Determine the correct semantics, encode it once, and cover with tests for both manuscript-tree and research-tree path rewrites (rename a group with children, assert child paths).
4. **Cross-surface registry.** Because this lands in MaughamCore and is phone-reachable, add it to `docs/superpowers/notes/cross-surface-contracts.md` so the phone shares (not re-implements) it (tripwire 19).

**Exit:** both schemes green; the path-prefix tests pass for both trees; `grep` for the prefixed `research*` tree-walk family and the per-file `findItem`/`collectDocIds` copies returns only the canonical MaughamCore definitions (plus forwarders).

### Phase 4 — File splits & boilerplate

1. **Split `Document.swift` (2111 lines)** into `extension Document` peer files — `Document+Load.swift`, `Document+Tasks.swift`, `Document+Annotations.swift`, `Document+Rewind.swift`, `Document+ExternalChange.swift` — following the `ProjectStore+*` precedent. Pure file move, no logic change (honors the OpLog AREA.md "don't refactor structurally" note: file-only split is not structural). Also fix the misplaced doc-comment on `paragraph(id:)` (`Document.swift:455`, currently describes `paragraphId(at:)`).
2. **Extract the load-time recovery into a testable pure function.** The four reconstruction branches in `load()` (`Document.swift:268-380`) decide what the writer sees on open — the highest-risk correctness surface — but are untestable, inlined in an async factory. Lift them into a pure `reconcile(parsed:derived:) -> DerivedState` (or similarly named) free function with the four branches as named cases; unit-test directly. No logic change.
3. **`ProjectWindow.swift`:** extract an `@Observable MCPBannerModel` (owns the 4 banner fields + dismiss task + 8s timer, currently threaded through a ViewModifier purely to dodge the type-checker); move `ResearchNoteEditor` (lines 1277-1367) and `WindowAccessor` to their own files.
4. **Merge `ProsePieceInspector`/`ScreenplayPieceInspector`** (~90% identical; `synopsisSection`/`statusSection` byte-identical) into one `PieceInspector` parameterized by a small kind enum (word-target vs page-target + label + symbol).
5. **MCP tool boilerplate:** add shared helpers — `decodeParams(_:from:)` and `resolveProject(_:in:) -> (params, entry)` throwing the canonical `MCPError.unknownProjectID` — and standardize the three current spellings of "unknown project" (`projectNotOpen`, `invalidArgument("unknown project_id")`, `unknownProjectID`) on `unknownProjectID`. Keep per-tool logic in the tools; only the decode+lookup+encode envelope is shared. `AnnotationCreationTools` is the in-repo model for this.

**Exit:** both schemes green; `Document.swift` and its new peers each comprehensible in one sitting; `reconcile` has direct unit tests; one piece inspector; MCP "unknown project" error is uniform.

### Phase 5 — CollectionPieces internal seams (lowest priority, opportunistic)

1. Extract `private func resolveLoosePiece(_ pieceId:) throws -> (StructureItem, pieceFolder: String, researchFolder: String)` to collapse the three verbatim preambles in `addPieceResearchNote`/`addPieceResearchAsset`/`addPieceResearchLink`.
2. Break `promotePieceToProject` (`+CollectionPieces.swift:179-331`, ~150 lines, 8-step staging dance) into named helpers, preserving the single rollback semantics.
3. Fold the ~6 "dedup slug against a Set with numeric suffix" loops (here and in `+Structure`/`+Research`) into one shared helper (composes with the Phase 2 slug reconciliation).

**Exit:** both schemes green; no functional change.

## Execution model

- **Subagent-driven** (CLAUDE.md default). Model selection: **opus** for the substantive items — Phase 2 (B) Find-Replace op-log rewrite, Phase 3 TreeNode generics + path-prefix reconciliation, Phase 4 Document split + `reconcile` extraction; **haiku/sonnet** for mechanical items — deletions, fixtures, comments, `print`→Logger, inspector merge, MCP envelope helpers.
- **Per-phase gate:** run `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` and the MaughamPhone scheme test; both green before starting the next phase. Run `./gen.sh` if any file is added/removed (it is, in several phases) before building.
- **Commit cadence:** one commit per numbered item (or tight group), conventional-commit style, so the history is bisectable and any single change is revertable.
- **No version bump** (tag-derived). This is internal refactor; no release notes unless the user wants a milestone tag at the end.

## Testing strategy

- Phases 1, 4, 5 are behavior-preserving → existing suite is the net, plus new unit tests for the one new pure function (`reconcile`).
- Phase 2 (B) and Phase 3 are behavior-changing/risk-bearing → new tests required: Find-Replace op-log integration (open + closed doc, no divergence); TreeNode path-prefix rewrite for both trees.
- Manual smoke after the milestone (user-run, per the smoke-test contract): launch → open a project → Find-Replace across an open and a closed doc → confirm text replaced and survives quit/relaunch; open the binder, rename a group with children, confirm child paths intact; confirm Tasks/Annotations panes still populate.

## Out of scope (explicitly deferred)

- Unifying the duplicate inline Fountain **classifier** in `Publish/ProjectASTBuilder` with `FountainParser` (large; acknowledged tech-debt with its own "Task 31" bridging note).
- The deferred "first MCP call after restart" flake (`JSONRPCBridge.swift`) — needs stderr logging first, per its tripwire; not bundled here.
- Moving closed-doc Tasks aggregation off the main actor (`ProjectStore+Tasks.swift`) — a watch-item, not a current defect.
- Any revival of character autocomplete UX.
