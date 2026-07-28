# Maugham — Guidance for Claude

Maugham is a Mac-native focus text editor for serious creative writing (prose, novels, screenplays, mixed collections). Native Swift + SwiftUI + AppKit, designed to live alongside Claude Desktop via a local MCP server. **The user does not write code** — Claude writes all of it. This file is the load-bearing context for that arrangement.

## First five minutes of any session

Read in this order, then start work:

1. `MEMORY.md` at `~/.claude/projects/-Users-denver-src-Maugham/memory/MEMORY.md` — the milestone index. Don't re-derive what's shipped; it's all there.
2. `README.md` and `docs/roadmap.md` — current shipped scope and open work.
3. `docs/constitution.md` — the product constitution: musts / must-nots, each marked *identity* or *position*, with falsification conditions. Test new milestones against it; ADRs cite its principles by name. Companions: `docs/product.md` (honest what-is-built overview) and `docs/problem-map.md` (writer jobs → what serves them; ✓/~/• status).
4. `docs/adr/` — every architectural decision made since the master spec. **ADRs supersede the master spec.** Don't re-read `docs/superpowers/specs/2026-05-07-maugham-master-design.md` except for original-intent questions.
5. This file's "Hard invariants" and "Tripwires" sections.

The most recent codebase audits live at `docs/superpowers/notes/2026-05-19-state-of-the-code.md` and `docs/superpowers/notes/2026-05-19-step-back-audit.md` — load them if you're touching anything they cover.

## Hard invariants

These are non-negotiable. Violating one is a regression even if tests pass.

- **Op log is the source of truth for manuscripts.** `.md` files on disk are derived. Editing means appending to the per-doc JSONL op log under `.maugham/ops/` and re-rendering. Inline `<!-- ¶id -->` HTML-comment anchors are the join key **in the op log and the in-memory representation** — the on-disk `.md` is a clean derived render (standard Markdown/Fountain, no `¶id`/`t-` anchors), ADR 0019. `sequence` is authoritative — walk by `sequence`, never raw `paragraphs`. **External `.md` edits are not honored**: editing is through Maugham; cross-device sync flows through the op-log merge (ADR 0012); an outside `.md` mutation is discarded on re-materialize. (2026-06-09: "blow away changes to the .md outside of Maugham" is intended.) See `Maugham/OpLog/` and ADRs 6–8.
- **Plain text on disk, full stop.** Manuscripts live as human-readable `.md` / `.fountain` at the writer's chosen paths. Anything derived (op log, checkpoints, sessions, conflict backups, UI state, trash) goes under `.maugham/`. Don't propose sidecar formats for manuscript content.
- **MCP never mutates manuscript text directly.** Claude operates in a parallel annotation layer (`add_note`, annotations against paragraph IDs), or writes into `research/` — never the manuscript itself.
- **Single-file screenplays.** One `.fountain` per screenplay project. Multi-file compound screenplay is dead (Phase 3d abandonment). The Scenes segment is a slugline navigator within that one file.
- **⌘S is a labeled checkpoint, not a save.** Saving is autosave (750ms debounce via `DocumentStore`). ⌘S writes a project-scope checkpoint. Keep the muscle-memory flash.
- **`Bootstrap.run` must be called from any new manuscript load path.** It mints the inline `¶id` anchors the op log joins on. The contract surface is `Document.load`. Both production callers (`EditorHost.loadDocumentIfNeeded` and `AnnotationToolHelpers.withAnnotationDocument`) funnel through it. `BootstrapWiringTests` enforces this. Route new load paths through `Document.load`; don't construct `Document` any other way.

## Build flow

```
./gen.sh                                                                       # xcodegen → Maugham.xcodeproj (run after every clone + after project.yml edits)
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO   # Mac app + MaughamCore
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
```

- **The two schemes are independent.** A change to MaughamCore should be tested against BOTH. Transient simulator "Busy / failed preflight checks" is a flake — re-run; don't `simctl shutdown all` before a launch.
- **`Maugham.xcodeproj/` is generated, not tracked.** `project.yml` is the source of truth; `./gen.sh` produces the whole `.xcodeproj/`. Never hand-edit `project.pbxproj`; never commit anything under `Maugham.xcodeproj/`.
- **Triage SourceKit diagnostics by class.** Most are noise (`No such module`, stale index). Trust `xcodebuild`. **Exception: `the compiler is unable to type-check this expression in reasonable time` is REAL** — heed it. Blanket-ignoring is how a Release-only build failure shipped to CI on v0.8.0.
- **Clean DerivedData after merging public-init / protocol-signature changes** to avoid phantom `Undefined symbol` link errors against stale `.o` files.
- **After any `ProjectWindow.body` change, run a local Release build before tagging** (`xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO`). The Release type-check budget is stricter than Debug.
- **Smoke test format:** launch → New project → Novel → "Smoke" → type a sentence → ⌘Q → relaunch → open from Recents → sentence intact. User runs smoke tests manually.
- **`Packages/MaughamCore` is a local SPM package** (Apple system frameworks only; no third-party deps). **WhisperKit** is a remote dep on the Maugham Mac target only. After editing `Package.swift` or adding package sources, run `./gen.sh`.

## Releases

See `docs/RELEASING.md` for the full recipe (cut-release.sh, signing/notarization, auto-update-in-place, phone pipeline, the capital-M bundle-id history). One-line summary: `./scripts/cut-release.sh 0.X.Y` then `git push --tags`; write release notes first. Version is tag-derived — don't bump `project.yml`.

## Architectural tripwires

"Do not do X — here's why it broke before." If your situation rhymes with one of these, slow down.

| # | Rule | Why (1 clause) | Enforced / more |
|---|---|---|---|
| 1 | No `NSTextStorage` subclass to front multiple files | AppKit's layout/undo/selection caches can't be steered from a subclass; killed Phase 3d | `memory/project_milestone_3d_abandoned.md` |
| 2 | No SwiftUI ↔ AppKit bidirectional sync with flag-based loop guards | `.onChange` fires after the synchronous flag-clear, so the guard leaks; killed cursor↔binder sync in 3d | `Maugham/Editor/AREA.md` |
| 3 | No heavy work inside a synchronous SwiftUI binding setter | Caused three separate cursor races in 24 hours (trailing-space autosave, async restore, stale `documentText`) | `EditorIntegrationHarnessTests`; tripwires 6 & 7 |
| 4 | No per-row computation in SwiftUI list rows without caching | Per-row Fountain re-parses became O(N²) on binder click in 3d, producing visible load pauses | — |
| 5 | No `NSPopover` for editor autocomplete | Sizing unreliable, blocked input; abandoned in 3b. `CharacterAutocompleter` was deleted (quality-maintainability v0.7.0) | `Maugham/Editor/AREA.md` |
| 6 | No parallel observable state on `EditorHost` | The `$documentText`/`lastWrittenText`/`priorStoredMarkdown` triad drove three cursor races; current shape is a single `Binding` writing `displayText` exactly once | `EditorIntegrationHarnessTests` |
| 7 | No 4th caller to `EditorSurface.applyExternalText` | Exists only for cloud-conflict resolution; a 4th caller is a binding race | `EditorIntegrationHarnessTests`; `TripwireGrepTests.test_applyExternalTextHasExactlyOneProductionCallSite` (census, not allow/deny) |
| 8 | Use 4-char alphabet-restricted paragraph IDs in tests crossing the `.md` ↔ op log boundary | `ParagraphID.parseComment` rejects ids outside its alphabet; permissive in-memory APIs hide the mismatch until the test hits Bootstrap/RenderFilter | Use `ParagraphID.mint()` or a 4-char literal from `[0-9a-hjkmnp-tv-z]`; `TripwireGrepTests.test_paragraphIdLiteralsInTestsUseValidAlphabet` (scans MaughamTests/MaughamPhoneTests/Packages/MaughamCore/Tests) |
| 9 | No `.onTapGesture` for clickable rows inside `List(.sidebar)` | Hit-testing is unreliable; use `Button(.plain)` | Established SwiftUI workaround |
| 10 | No MCP tool response >1 MB | Transport cap; image responses use crop-on-demand | ADR 0004 |
| 11 | No test data migration — delete and recreate | User: "if I need to just delete all my test files and start again it's ok here" | — |
| 12 | No stringly-typed `synthesisSource` | `SynthesisSource?` is a typed enum; raw disk values are snake_case; adding a cause = adding an enum case; emit-sites are compiler-exhaustive | `SynthesisSource.swift`; ADR 0010 |
| 13 | No hardcoded `"maugham"` / `"Maugham"` / socket paths outside `BuildVariant.swift` | Six values vary by variant; a hardcode is a split-build bug | `TripwireGrepTests` (Mac) + `TripwirePhoneGrepTest` (phone); `BuildVariant.swift` |
| 14 | Move/delete of user-editable content must go through the typed `DocumentStore` mover | 750ms autosave recreates at the old path after `moveItem`/`moveToTrash`, leaving phantom files | **Grep-enforced**: `DocumentStore.relocate`/`relocateUserContent`/`trash` + `TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover`; see `Maugham/Stores/AREA.md` |
| 15 | `ContentUnavailableView` needs `.frame(maxWidth: .infinity, maxHeight: .infinity)` — and the pane's outer `VStack` needs `alignment: .top` too | SwiftUI sizes to intrinsic content and the enclosing VStack collapses; toolbar floats to window center; has recurred 4+ times | Canonical examples: `HistoryPane`, `AnnotationsPane`, `OutlinePane`; `TripwireGrepTests.test_contentUnavailableViewAlwaysChainsFullFrame` |
| 16 | Inline rename `TextField` focus needs `Task.sleep(30ms)` deferral + both `.onAppear` AND `.onChange(of: renamingItemId)` triggers | A single `DispatchQueue.main.async` tick loses races with `List(selection:)`'s focus pass | `BinderRow.claimFocus()` is canonical; `PieceRow`/`ResearchRow` mirror it |
| 17 | No single shared JSONL file across devices via iCloud Drive | iCloud's reconciler can't line-merge concurrent appends; the loser is silently dropped as a conflict-twin the loader never opens; inbox `writtenAt` must be monotonic to survive clock skew; sealing (ADR 0016) is safe *because of* per-device partitioning — never seal the legacy unsuffixed file or another device's file (`OpLogStoreSegmentTests.test_legacyFile_neverSealed` + the `.mzseg` tripwires) | `PendingBuffer` partitioned (M1.3); `OpLogStore.opLogFileURLs`/`loadSyncMerged`; ADR 0012 |
| 18 | On iOS: don't assume a file is evicted; `startAccessing==false` is not a denial; don't `d_`-prefix a docId that already has one | Each assumption broke browsing or annotation loading on the 2026-05-30 smoke | `MaughamPhone/AREA.md` (iOS tripwires section) |
| 19 | Anything touched by BOTH Mac and phone must go through a shared MaughamCore implementation | The phone must not reimplement what the Mac implements; a stricter local doc-id parser shipped phone-v0.1.1 "No open annotations"; the reach-around tripwires catch the known bad spellings so the same mistake can't silently return — the real safety net is the round-trip integration tests | `TripwirePhoneGrepTest`/`TripwireGrepTests`; registry `docs/superpowers/notes/cross-surface-contracts.md` |
| 20 | No raw manuscript `.md`/`.fountain` read as truth — derive from the op log (open doc → live `Document`; closed → `DerivedManuscript`) | An output read back as input; produced a real `read_document`↔`add_comment` id disagreement, and the `.md` lags the op log whenever an op lands out of band | ADR 0018/0019; whole-tree `// adr-0018-ok:` annotation guard across Mac+Core+Phone in `TripwireGrepTests` + `TripwirePhoneGrepTest` |
| 21 | No raw `maugham.*` NotificationCenter post/subscription outside `MaughamEvent` — every post declares scope (.keyWindow/.document/.project/.allWindows); receive helpers own each filter + the closed-window liveness guard | unscoped broadcast shipped the same defect ≥3× (rewind retrofit, script.did.update relayout/clobber, toggleInspector double-toggle); SwiftUI scene storage keeps closed-window zombies subscribed | `Maugham/Events/MaughamEvent.swift`; TripwireGrepTests; ADR 0021 |
| 22 | Key a Document-binding *reload* on the doc's PATH, not its id | An id-keyed reload survives a rename and shows stale content; hit twice — once in the editor husk-reload fix, once in the palette rename-revert instance (E2). NB: distinct from MCP `read_document`, which resolves an OPEN doc by *docId* (registry lookup, rename-stable) — different operation (editor reload-trigger vs registry lookup), both close the rename window | Canonical: `EditorHost.needsReload` |
| 23 | No bare `ParagraphID.mint()` in production | 4 random chars over a ~1.05M space — at manuscript scale collisions are LIKELY, not rare (2026-06-10 paste crash, oplog-growth milestone); use `mintUnique(excluding:)` | `TripwireGrepTests.test_noBareParagraphIDMintInProduction` |
| 24 | No hand-built device slug — `DeviceSlug` has a private init; the only ways in are `DeviceSlug.make(from:)` (production) and the `internal` `unsafeForTesting(_:)` (test-only). Filename builders (`OpLogStore.opLogFileURL`/`segmentFileURL`/`segmentIndex`/`sealTailIfNeeded`, `InboxManifest.inboxManifestURL`, `PendingBuffer`) take `DeviceSlug`; interpolate `.raw` only at the filename point. The slug lives ONLY in filenames — never serialized into JSONL/manifest content — so this is a type-level guard, not a wire-format change | Slug hand-building bit twice (oplog-growth "gotcha rediscovered"); **enforcement = the compiler** — passing a `String` where a `DeviceSlug` is expected won't build; `DeviceSlug.swift` + round-trip contract tests (`OpLogFilenameContractTests`, `OpLogStoreSegmentTests`, `InboxManifestTests`) |
| 25 | No `NSScrollView.magnification` under SwiftUI content, and no `.scaleEffect` for canvas zoom | SwiftUI's coordinate space is unaware of magnification — same `.global` frame at every zoom, and at 2× and above the mistranslated point falls outside the view and clicks stop registering entirely (measured 2026-07-25, macOS 26.5); `.scaleEffect` blurs text, reports unscaled geometry and breaks `NSCursor` tracking | `docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md`; ADR 0026; `CanvasCameraTests` |
| 26 | `NSTextContentStorage.textStorage = NSTextStorage(...)`, never `.attributedString =` | With `attributedString` the scrap renders perfectly and silently swallows every keystroke — `textStorage` nil, `string` empty, `insertText` a no-op | `ScrapLayoutTests.test_mountedEditorActuallyEditsTheSharedStack`; `Maugham/Canvas/AREA.md` |
| 27 | The canvas's mounted editor stays the FRONTMOST layer, its focus is *requested* not taken, and it mounts on the click while its VISIBILITY waits for the card to be level | An event view in front eats click-to-place-caret, drag-select and double-click-word; `makeFirstResponder` in `makeNSView` runs with a nil window and is a silent no-op; showing the editor on the click puts axis-aligned glyphs over a still-tilted card with the drawn text already suppressed, so they snap straight and the card follows, while deferring the *mount* to `isLevel` leaves ~120 ms in which typing reaches no editor at all — none of the four is visible to a subview count | `CanvasCompositionTests`; `ScrapEditorHostTests`; `CanvasRendererTests`; ADR 0026 |
| 28 | Text living in a shared `NSTextStorage` must be folded into the model on `textDidChange`, not only at a focus boundary | The debounced payload is whatever was queued *before* the writer typed, so type-then-quit writes an empty scrap and the drawn card never grows — *the words are safe* (constitution must #1) failing on the first interaction | `ScrapEditorHostTests.test_typingReportsItselfSoTheCanvasCanFoldItIntoTheModel`; `CanvasStoreTests.test_beforeFlushCanReplaceThePayloadOnItsWayOut` |
| 29 | A clock's "settled" predicate compares each value to ITS OWN target, never to a constant | `CanvasFocusStraighten.isSettled` written as `allSatisfy { $0.value >= 1 }` is true the instant focus leaves — the entry is still 1 while its target is now 0 — so `TimelineView` pauses, the settle-back never runs, and the card stays level for the rest of the session | `CanvasRendererTests.test_blurSettlesTheCardBackToItsSeededAngle` |
| 30 | Nothing scene-proportional may key off a per-frame redraw counter | `CanvasView.revision` ticks on every drag frame, straighten frame and momentum frame; the accessibility tree keyed on it sorted the scene and copied every scrap's string at 60–120 Hz. Use the structural counter (`sceneRevision`), and extract camera-reading `ForEach`es into `.equatable()` subviews | `CanvasAccessibilityTests.test_theTreeIsNotKeyedOnTheRedrawCounter`; `CanvasCompositionTests` |
| 31 | Canvas membership is never changed by a TRANSITION — not on move, not on resize. Creation *does* absorb (a swept region takes in every card whose CENTRE is inside it; a scrap made inside a region joins it), and a drop targets by the node's CENTRE (ties on greatest overlap, then the smaller region); removal is always its own act. If you are writing `region.frame.contains(…)` inside a move or resize path, stop | Obsidian, tldraw (#6017) and Scapple each ship a distinct bug from the geometry→membership **transition** rule, and tldraw's persists *despite* explicit storage — so storing membership is not the fix. Creation has no prior relationship to break, which is why 2026-07-28 could hand it back without reopening the bug class | `CanvasMembershipTests` (falsified by introducing tldraw's ejection bug); `CanvasRegionInteractionTests` (`absorbedNodes` over every input); `CanvasViewMountingTests` (move and resize absorb nothing, on the delivery path); ADR 0026 §8; spec §4.2 amendment |
| 32 | The canvas's two undo-bracket verbs are not interchangeable: from inside `CanvasView` a mutation arriving mid-gesture is the writer's own gesture and must be REFUSED (`deleteSelection`'s `isInGesture` guard); from another column there is no gesture of the caller's own to protect, so `CanvasModel.mutateFromInspector` closes, runs and reopens — which is what `CanvasUndo.undo()` already does | Missed **three times in one slice** by independent implementers from both entry points, and it fails silently: nested, the edit registers no undo step and rides into the writer's next one, so a ⌘Z aimed at a sentence takes something else with it. Repro: **double-click a region's own chrome bar** (click 1 selects it, click 2 mints a scrap and opens "Edit Scrap") — *not* a card, since AppKit sends `clickCount: 1` first and that click moves the selection | `TripwireGrepTests.test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly` + its converse + planted-offender companion; ADR 0026 §5; `Maugham/Canvas/AREA.md` |

## Default workflow

Follow this without asking — the user has answered these questions enough times that re-asking is friction.

1. **Brainstorm → spec → plan → subagent-driven implementation → manual smoke → tag.** Specs live in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`.
2. **Use subagent-driven dispatch by default.** Do not ask which execution mode.
3. **Model selection:**
   - `haiku` for mechanical tasks — Codable types, small structs, thin SwiftUI views, smoke-build-only files.
   - `sonnet` *or* `opus` for substantive tasks — async + file I/O with error handling, AppKit/SwiftUI architectural composition, anything touching the Editor/OpLog seam. **The user explicitly prefers paying for `opus` on substantive work over risking rework**, so default to opus when in doubt.
   - Reviewer subagents: `haiku` is sufficient for spec-compliance and code-quality review.
4. **Skip the formal two-stage review for trivial tasks.** Reserve dual-reviewer for tasks with real design judgment.
5. **Bundle related features into one milestone.** The user prefers ambitious scope; don't pre-trim on their behalf. See `memory/feedback_scope_ambition.md`.
6. **Read every bug the user lists in one message — not just the first.** Users batch regressions.
7. **Help/docs surfaces describe what *ships*, not what's planned.**
8. **Every new data type needs a UI surface for inspection/action.** MCP access alone is not enough.
9. **Whole-branch review before merge** — after per-task reviews, one review of the full branch diff; per-task reviews cannot see emergent interactions (T5×T6 precedent).
10. When a roadmap item flips •→✓, sweep sibling docs (CLAUDE.md, AREA.md, guide) for now-false claims in the same commit.
11. **Build the first plan of a multi-plan milestone before writing the rest.** Plans written against an API that does not exist yet drift against imaginary Swift, and no compiler can catch it — M1C's four canvas plans cost four review rounds and five fix rounds, and three separate times one plan would have deleted a day's work from another. Re-derive the remaining plans against the built code; they get shorter. See `memory/feedback_plan_detail_and_sequencing.md`.
12. **Cap a plan at ~10 tasks; past that, split it.** M1C's 15-task plan needed four fix rounds; the three written under the cap needed one each — same authors, same standards, same day. Relatedly: a plan must never restate another plan's API (a copy drifts); point at the defining task instead.

## Per-area pointers

**When an area has an `AREA.md`, read it before editing anything in that directory.**

| Area | One-line callout |
|---|---|
| `Packages/MaughamCore/` | Shared substrate (Apple frameworks only) — inventory: `ls Packages/MaughamCore/Sources/MaughamCore`. `MarkdownDisplayFilter` is the single source of truth for anchor-stripping (don't add a target-local copy). Cross-module = `public`; the build tells you. |
| `MaughamPhone/` | Four-tab iOS app (Capture/Read/Annotations/Settings); shares MaughamCore; AppKit never here; WhisperKit Mac-only. **Read `MaughamPhone/AREA.md`** for build command, seam-injection pattern, iOS tripwires, and release details. |
| `Maugham/Stores/` | `ProjectStore` (small façade + peer extension files); `DocumentStore` (coordinator + registry + typed user-content mover); `MaughamSidecarPath` enum routes presenter callbacks. **Read `Maugham/Stores/AREA.md`** for the typed mover, `.maugham/` layout, and store tripwires. |
| `Maugham/Canvas/` | The Plan persona's centre column: a SwiftUI `Canvas` draws every node and every region, one real `NSTextView` mounts on the focused scrap off the SAME TextKit stack. Camera is a manual CTM — never `.scaleEffect`, never `NSScrollView.magnification` ([ADR 0026](docs/adr/0026-planning-canvas-rendering.md)). Ground is a Metal shader BENEATH the content. State lives on an `@Observable` `CanvasModel` owned by `ProjectWindow`, so the region inspector in the right-hand column reads the same scene the canvas draws — and mutates it through `mutateFromInspector`, never `mutate` (tripwire 32). Region membership is stored and never derived from geometry (tripwire 31). ⌫ deletes the selected scrap, region or line. `canvas.md` is content; `.maugham/canvas.json` is derived, at schema 3. **Read `Maugham/Canvas/AREA.md`**. |
| `Maugham/Editor/` | `EditorCoordinator.swift` is the central nervous system (NSTextViewDelegate, tokenization, cursor, Tab-cycle, smart typography, find, focus-dim). `EditorHost.swift` binding contract is fragile (tripwires 2, 3, 6, 7). `applyFocusDim` intentionally called from three paths — don't dedupe. **Read `Maugham/Editor/AREA.md`**. |
| `Maugham/OpLog/` | Cleanest area — don't refactor structurally. Echo guard = `Document.lastDiskEcho: EchoState` (don't add a parallel "last text" string). Sweep gated on `_pendingSweep: SweepReason?` (don't reintroduce a bool flag). Time-travel via `RewindCursor`/`RewindRestoreResult`/`SynthesisSource`. **Read `Maugham/OpLog/AREA.md`**. |
| `Maugham/MCP/` | Single source of truth: `MCPToolCatalog.all`. Implement `MCPTool`, add to catalog; both `MCPToolsListHandler` and `MaughamApp.registerTools` derive from it. Transport = live-only Unix socket (ADR 0003). **52 tools** (see AREA.md for full list), incl. `get_help`, which serves the bundled `docs/guide/` topic files — the SAME single docs source shown in-app via **Help → Maugham Help** (`HelpWindow`) and rendered on GitHub. `HelpTopicIndex` is the shared loader; edit docs in `docs/guide/`, don't add a second copy. Tools fail loudly on unknown ids. + SEP-2640 skills extension (protocol methods, not tools) serving bundled `docs/skills/` content — see AREA.md. **Read `Maugham/MCP/AREA.md`**. |
| `Maugham/Publish/` | PDF+EPUB via bundled tectonic. Flow: `ProjectStoreASTSource` → `ProjectASTBuilder` → `LaTeXBodyEmitter`/`XHTMLBodyEmitter` → output under `Exports/`. `EMISSION.md` is generated (edit `EmissionContract.swift`, run tests). Per-piece `style_file` must stay inside a scoped `\begingroup…\endgroup` — don't hoist the `\input` out. ADR 0013. |
| `Maugham/Views/` | `ProjectWindow.swift` uses extracted `ViewModifier`s to dodge SwiftUI's body type-checker ceiling — extract more when you hit the limit. BinderSegment conditional cases auto-coerce to `.manuscript` when their condition disappears. Four **personas** (Plan/Author/Review/Publish, ⌘1–4) reconfigure the window via two pure registries on `Persona` — `panes` (right pane) and `binderSegments(for:)` (left column); a new right-pane surface joins by adding a `DetailSegment` case plus one registry entry, no picker/window changes. Right-pane mode-swap survives, now scoped by persona (ADR 0005, amended by [ADR 0025](docs/adr/0025-persona-shell.md)); pane shortcuts are `⌘⌥`-letter (⌘⌥I/R/O/A/H/T/B/P/L), not the old numeric space. |
| `Maugham/Models/` | `ProjectType` is polymorphic; Collection references are Mac-local. Manifest `modified` must round-trip through ISO8601 with whole-second rounding. Schema evolution: add `unknown` enum cases + custom decoder for non-optional fields (ADR 0015). |

## Inbox + transcription (`Maugham/Stores/` — iPhone-companion Mac side)

`InboxStore` owns `.maugham/inbox/` (per-device `inbox.<slug>.jsonl`, monotonic `writtenAt`). `InboxPane` is ⌘⌥B. `InboxTranscriptionWorker` runs an injected `Transcriber`; production is `WhisperKitTranscriber` (Apple-Silicon only). MCP scope is **read + promote only** (no add/trash from MCP).

## Outstanding correctness concerns

- **Watch for stray `project.pbxproj` edits in diffs.** `Maugham.xcodeproj/` is generated and gitignored; a pbxproj in a diff is a red flag.

## Questions you do not need to ask

- "Should we use subagents?" → Yes.
- "Which model?" → Haiku mechanical, sonnet-or-opus substantive (opus preferred when in doubt).
- "Should we migrate test data?" → No. Delete and recreate.
- "Should this annotation be paragraph- or doc-scoped?" → Both should work and both need a UI surface.
- "Should I write a migration for this schema change?" → No, unless the user explicitly asks.
- "Should we ship one feature first or bundle?" → Bundle, default to ambitious.
- "How do I cut a release?" → see `docs/RELEASING.md`.
- "Should I bump version in `project.yml`?" → No. The git tag is the source of truth; CI writes the version into the bundle at build time.
- "Should dev or stable do X?" → see `Maugham/BuildVariant.swift` — one enum, all the seams hang off it.
