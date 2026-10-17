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

- **Op log is the source of truth for manuscripts.** `.md` files on disk are derived. Editing means appending to the per-doc JSONL op log under `.maugham/ops/` and re-rendering. Inline `<!-- ¶id -->` HTML-comment anchors are the join key **in the op log and the in-memory representation** — the on-disk `.md` is a clean derived render (standard Markdown/Fountain, no `¶id`/`t-` anchors), ADR 0019. `sequence` is authoritative — walk by `sequence`, never raw `paragraphs`. **External `.md` edits are not honored**: editing is through Maugham; cross-device sync flows through the op-log merge (ADR 0012); an outside `.md` mutation is discarded on re-materialize. (2026-06-09: "blow away changes to the .md outside of Maugham" is intended.) **Every line this device writes is chained to the one before it and every span it wrote is sealed** (signed op log P1, [ADR 0032](docs/adr/0032-the-signed-op-log.md)): a line something else appended is classified, set aside as a `.lines` record and never applied, and a load never refuses a manuscript over it. **And a device is four writers, each with a key of its own** (P1b, ADR 0032's Actors addendum): `DeviceActor`'s `author` (the writer's hand and its automations), `assistant` (anything through MCP), `translator` (the pipeline and `write_translation`) and `maugham` (the task rebalance) each sign their own file, so a production `Document.load` names an ACTOR and never a device string (tripwire 38). See `Maugham/OpLog/` and ADRs 6–8.
- **Plain text on disk, full stop.** Manuscripts live as human-readable `.md` / `.fountain` at the writer's chosen paths. Anything derived (op log, checkpoints, sessions, conflict backups, UI state, trash) goes under `.maugham/`. Don't propose sidecar formats for manuscript content.
- **MCP never mutates manuscript text directly.** Claude operates in a parallel annotation layer (`add_note`, annotations against paragraph IDs), or writes into `research/` — never the manuscript itself.
- **Single-file screenplays.** One `.fountain` per screenplay project. Multi-file compound screenplay is dead (Phase 3d abandonment). The Scenes segment is a slugline navigator within that one file.
- **⌘S is a labeled checkpoint, not a save.** Saving is autosave (750ms debounce via `DocumentStore`). ⌘S writes a project-scope checkpoint. Keep the muscle-memory flash.
- **`Bootstrap.run` must be called from any new manuscript load path *that may write the piece*.** It mints the inline `¶id` anchors the op log joins on. The contract surface is `Document.load`. Both production callers (`EditorHost.loadDocumentIfNeeded` and `AnnotationToolHelpers.withAnnotationDocument`) funnel through it. `BootstrapWiringTests` enforces this. Route new load paths through `Document.load`; don't construct `Document` any other way. **The qualifier is P3a Task 8's** (spec §4.6), **narrowed by P3c plan 2's Option A**: in a book where somebody is narrowed, the load mints only where `LocalWritePermit.mayMintOpening` says — a piece whose manifest records who started it (`StructureItem.startedBy`, written by every creation site through `ProjectStore.thisMacAsAStarter`, census `TripwireGrepTests.test_everyStructureItemAProductionFileConstructsRecordsItsStarter`, and never rewritten) is minted by THAT Mac alone, the root's included; a creation that yields a piece WITH content mints its opening at creation (`ProjectStore.mintOpenings`, through this same load); and a piece with no recorded starter, or one whose starter the register shows REVOKED or RETIRED (`TrustTable.starterStanding` → `.gone`; every other starter — unknown, a stranger, another root's member — waits), keeps the older rule (whoever may write its text mints it). Everywhere else the load mints NOTHING and refuses with `DocumentLoadError.waitingForPiece` — naming the starter where this Mac did not start the piece — because *no op log* on such a device means *its ops have not synced yet* rather than *a new file whose `.md` is the seed*, and a `bootstrap` the partition sets aside derives the document EMPTY. The read side follows the same fact (P3 closing smoke F1, Denver's ruling *refuse, don't ask*): a scoped author's line in a piece whose recorded starter the register has PLACED as somebody else — the root included — is refused for scope on every Mac, hers included, and asks nobody; §4.5's question is put only for a piece one of her devices started or one with no recorded starter, and a starter the register cannot place yet (`TrustTable.starterStanding` → `.unknown`, a device named only by its own record included) keeps her line waiting. **And everything the load emits on its own account is the AUTHOR actor's, whoever opened the file** — the bootstrap, the pending-recovery fold, the task anchors and their `taskCreate` breadcrumbs are the writer's own words arriving through whichever door was first, so an MCP or translator load signs them `.author` (`Document.authorEmissionDevice(loadedAs:)`); only what the CALLER then writes stays the loading actor's.

## Build flow

```
./gen.sh                    # xcodegen → Maugham.xcodeproj (run after every clone, after project.yml edits, AND after ADDING any source/test file)
./scripts/test.sh           # fast loop (~65s): core package tests + Mac scheme minus the CanvasViewMounting* family
./scripts/test.sh full      # pre-merge/tag gate (~70-90s): core + full Mac scheme, NO skips; keeps an xcresult per run
./scripts/test.sh phone     # iOS simulator run
```

Raw invocations, when you need them:

```
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO   # Mac app tests ONLY — MaughamCore is NOT in this scheme
./scripts/test.sh core                                                               # MaughamCore's package tests alone, behind the gate lock (~6s); no scheme hosts them
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
```

- **Run `./scripts/test.sh core` after touching `Packages/MaughamCore`**, and prefer `test.sh` over raw `xcodebuild`: its gates queue behind a machine-global lock, and a bare `swift test` or a raw `xcodebuild test` bypasses it. MaughamCore's package tests belong to no scheme.
- **Test a MaughamCore change against BOTH schemes** (plus Core's own tests). A simulator "Busy / failed preflight checks" is a flake: re-run; don't `simctl shutdown all`.
- **Check for other sessions' builds with `pgrep -x xcodebuild`, never `pgrep -f`** — `-f` matches the harness's own shell wrapper and every other waiter.
- **No wait loop may carry `xcodebuild` in its own command line**: put a loop that must invoke it in a script FILE and run the file.
- **Run `./gen.sh` after adding any source or test file**, or after editing `project.yml` or `Package.swift`. A stale project runs 0 tests for a new test file with no error.
- **`Maugham.xcodeproj/` is generated, not tracked.** `project.yml` is the source of truth. Never hand-edit `project.pbxproj`; never commit anything under `Maugham.xcodeproj/`.
- **`Packages/MaughamCore` is a local SPM package** (Apple system frameworks only; no third-party deps). **WhisperKit** is a remote dep on the Maugham Mac target only.
- **A new suite that styles text through production typography calls `FontWarmup.ensure()`** in `override class func setUp()`.
- **A new suite that performs a real tectonic compile calls `try await TectonicProbe.requireReady()`**; never give its canary a dependency.
- **`TestWindow` is the one place a test window is constructed** (`TestWindow.make`/`.mount`); a test that must build one by hand gets an allow-list entry in `TripwireGrepTests`, not an exemption comment. A test asks for activation only through `TestWindow.activate(_:)`.
- **`TestTemp` is the one temp root in a test target**: `TestTemp.root` per test, `TestTemp.workerRoot` for a class fixture. Bind a Unix socket by name from inside the directory, never by absolute path.
- **A test pinning an `NSOpenPanel`/`NSSavePanel` configuration asserts a plain value struct**, never a panel the test allocates.
- **Skip the three `CanvasViewMounting*` classes while iterating** (`./scripts/test.sh` does) by their CONCRETE class names; run `./scripts/test.sh full` before merge or tag.
- **A mounted test reads its premise off the window it actually got** (CI's display is narrower), and CI's macOS and Xcode match the dev machine's. Don't qualify `Document` in test files.
- **Clean DerivedData after merging public-init / protocol-signature changes.**
- **Trust `xcodebuild` over SourceKit**, except two diagnostics that are real: *unable to type-check this expression in reasonable time*, and a `Sendable`/concurrency diagnostic on a file you just wrote.
- **`touch` a file (or clean) before believing a warning census** over an incremental build.
- **After any `ProjectWindow.body` change, run a local Release build before tagging** (`xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO`).
- **Smoke test format:** launch → New project → Novel → "Smoke" → type a sentence → ⌘Q → relaunch → open from Recents → sentence intact. User runs smoke tests manually.

When a gate is red and the failure doesn't name your change, read docs/testing/TROUBLESHOOTING.md before touching code.

## Releases

See `docs/RELEASING.md` for the full recipe (cut-release.sh, signing/notarization, auto-update-in-place, phone pipeline, the capital-M bundle-id history). One-line summary: `./scripts/cut-release.sh 0.X.Y` then `git push origin v0.X.Y` (the one tag by name — never `--tags`, which fires no workflow past three tags); write release notes first. Version is tag-derived — don't bump `project.yml`. **The Mac release needs the `MAC_PROVISIONING_PROFILE` secret** (a Developer ID profile for `com.maugham.Maugham` granting the person-key keychain group): with the group in the entitlements a signed Release build fails without it, and `release.yml` stops at its install step naming the secret (`docs/release-notes/SETUP-mac-signing.md` §4).

## Architectural tripwires

One line each; the why, the history and the full enforcement are in docs/tripwires.md. If your change rhymes with a row, read that row there first.

| # | Rule | Enforced by |
|---|---|---|
| 1 | No `NSTextStorage` subclass fronting several files | prose only |
| 2 | No SwiftUI ↔ AppKit two-way sync guarded by flags | prose only |
| 3 | No heavy work inside a synchronous SwiftUI binding setter | `EditorIntegrationHarnessTests` |
| 4 | No uncached per-row computation in SwiftUI list rows | prose only |
| 5 | No `NSPopover` for editor autocomplete | prose only |
| 6 | No parallel observable state on `EditorHost`; one `Binding` writes `displayText` exactly once | `EditorIntegrationHarnessTests` |
| 7 | No 4th caller of `EditorSurface.applyExternalText` | `TripwireGrepTests.test_applyExternalTextHasExactlyOneProductionCallSite` |
| 8 | Tests crossing the `.md` ↔ op log boundary use 4-char paragraph ids from the valid alphabet | `TripwireGrepTests.test_paragraphIdLiteralsInTestsUseValidAlphabet` |
| 9 | No `.onTapGesture` for clickable rows inside `List(.sidebar)`; use `Button(.plain)` | prose only |
| 10 | No MCP tool response over 1 MB; images crop on demand | prose only (ADR 0004) |
| 11 | No test data migration — delete and recreate | prose only |
| 12 | No stringly-typed `synthesisSource`; it is the typed `SynthesisSource` enum | the compiler (typed enum) |
| 13 | No hardcoded `"maugham"` / `"Maugham"` / socket paths outside `BuildVariant.swift` | `TripwireGrepTests` +1 |
| 14 | Move or delete user-editable content only through the typed `DocumentStore` mover | `TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover` |
| 15 | `ContentUnavailableView` chains a full-size `.frame`, and the pane's outer `VStack` takes `alignment: .top` | `TripwireGrepTests.test_contentUnavailableViewAlwaysChainsFullFrame` |
| 16 | Inline rename focus defers `Task.sleep(30ms)` and fires from both `.onAppear` and `.onChange(of: renamingItemId)` | prose only |
| 17 | No single JSONL file shared across devices through iCloud Drive; never seal the legacy file or another device's | `OpLogStoreSegmentTests.test_legacyFile_neverSealed` |
| 18 | On iOS: don't assume eviction; `startAccessing==false` is not a denial; don't `d_`-prefix a docId twice | prose only |
| 19 | Anything both Mac and phone touch goes through one shared MaughamCore implementation | `TripwirePhoneGrepTest` +1 |
| 20 | No raw manuscript `.md`/`.fountain` read as truth; derive from the op log | `TripwireGrepTests` +1 |
| 21 | No raw `maugham.*` NotificationCenter traffic outside `MaughamEvent`; every post declares its scope | `TripwireGrepTests` |
| 22 | Key a Document-binding reload on the doc's PATH, not its id | prose only |
| 23 | No bare `ParagraphID.mint()` in production; use `mintUnique(excluding:)` | `TripwireGrepTests.test_noBareParagraphIDMintInProduction` |
| 24 | No hand-built device slug; filename builders take `DeviceSlug`, and the slug lives only in filenames | the compiler; `OpLogFilenameContractTests` +2 |
| 25 | No `NSScrollView.magnification` under SwiftUI content, and no `.scaleEffect` for canvas zoom | `CanvasCameraTests` +1 |
| 26 | `NSTextContentStorage.textStorage = NSTextStorage(...)`, never `.attributedString =` | `ScrapLayoutTests.test_mountedEditorActuallyEditsTheSharedStack` |
| 27 | The canvas's mounted editor stays frontmost, its focus is requested, it mounts on the click and shows once the card is level | `CanvasCompositionTests` +2 |
| 28 | Text in a shared `NSTextStorage` folds into the model on `textDidChange`, not only at a focus boundary | `ScrapEditorHostTests.test_typingReportsItselfSoTheCanvasCanFoldItIntoTheModel` +1 |
| 29 | A clock's "settled" predicate compares each value to its own target, never to a constant | `CanvasRendererTests.test_blurSettlesTheCardBackToItsSeededAngle` |
| 30 | Nothing scene-proportional keys off a per-frame redraw counter; use `sceneRevision` | `CanvasAccessibilityTests.test_theTreeIsNotKeyedOnTheRedrawCounter` +1 |
| 31 | Canvas membership never changes on a move or resize; creation absorbs by centre, and removal is its own act | `CanvasMembershipTests` +2 |
| 32 | A mid-gesture mutation inside `CanvasView` is refused; from another column use `CanvasModel.mutateFromInspector` | `TripwireGrepTests.test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly` |
| 33 | No test presses a mounted control then waits for its effect, or synthesises a click, outside the named allow-lists | `TripwireGrepTests.test_noNewTestPressesAControlAndThenWaitsForItsEffect` +2 |
| 34 | No run resolves its reader from the other loop's memory: `AuthorReader` never reads `ActivePassMemory`, `RoundEditor` never the roster | `TripwireGrepTests.test_theCheckReaderNeverReadsTheBoardsMemory` +4 |
| 35 | No identity from the host name and no hand-built device id; `DeviceIdentity` / `LocalIdentities` is the one answer | `TripwireGrepTests.test_noHostnameIdentity` +3 |
| 36 | No software private key in production; the person key (`PersonKey.swift`) is the one named exception | `TripwireGrepTests.test_noSoftwarePrivateKeyInProduction` |
| 37 | A seal line is recognised in `OpLogChain` only (`isSealLine`, whose one caller is `JSONLAppendStore.parse`) | `TripwireGrepTests.test_sealLinesAreRecognisedInOpLogChainOnly` +2 |
| 38 | No `device:` string at a production `Document.load`; pass a `DeviceActor`, and the load's own emissions are the author's | `TripwireGrepTests.test_noDeviceStringAtAProductionDocumentLoad` +1 |
| 39 | Every trust closure is built from a `TrustTable` and takes a `TrustVerdict`, never a Bool | `TripwireGrepTests.test_everyTrustClosureIsBuiltFromTheTrustTable` +3 |
| 40 | Registry records are written through `RegistryWriter` only, and each registry directory is spelled in one function | `TripwireGrepTests.test_registryRecordsAreWrittenThroughRegistryWriterOnly` |
| 41 | The registry's writers are three files (`RegistryPresence`, `RegistryAdmission`, `RegistryCache`); the phone writes none | `TripwireGrepTests.test_theRegistrysWritersAreThreeFiles` +2 |
| 42 | `RegistryCanonical` alone decides what a signature covers | `RegistryCanonicalCensusTests` |
| 43 | The role check reads the permit timeline, never `PersonRecord.role`/`.scope`/`.pieces` | `TripwireGrepTests.test_theRoleCheckReadsTheTimelineAndNotTheRecordsField` +1 |
| 44 | `Permit.allows` is the one permission table and `Deriver.appliesToManuscript` the one manuscript classifier, with named callers | `TripwireGrepTests.test_thePermissionTableIsSpelledInThePermitLayerOnly` +1 |
| 45 | `PermitPartition.partition`'s production call sites are a named array with a count per file | `TripwireGrepTests.test_thePartitionsCallSitesAreExactlyTheNamedList` |
| 46 | `OpLogStore.localWritePermit(as:documentClass:)` is the one write-permit question; no production file builds a `LocalWritePermit` | `TripwireGrepTests.test_theWriteSidePermitQuestionHasOneFunction` |
| 47 | A permit rung is compared only inside the permit layer; ask `Permit.allows` what may be written | `TripwireGrepTests.test_aPermitRungIsComparedOnlyInThePermitLayer` |
| 48 | Which lines the load emitted is decided once, in `Permit.swift` (`isALoadEmission`, `actorJudging`) | `TripwireGrepTests.test_theLoadEmissionRuleIsSpelledInThePermitLayerOnly` +1 |
| 49 | Each unsigned-door decision (narrowing, snapshot, unattributable, holders, held-key standing, permit offering) has one home | `TripwireGrepTests.test_theNarrowingPredicateAndTheSnapshotAreInThePermitLayerOnly` +6 |
| 50 | The held-line and schema call-site lists are named arrays with a count per file (`TripwireGrepTests.countedLists`) | `TripwireGrepTests.test_theP3bCountedListsAreExactlyTheNamedArrays` |
| 51 | What a Mac may offer is asked of `Posture` through one door; no other file builds a posture or asks the permit | `TripwireGrepTests.test_postureIsAskedOfThePermitInOnePlace` +1 |
| 52 | Every manuscript writer outside the editor asks its posture first; the writer population is derived from the code and counted | `TripwireGrepTests.test_everyGuardedDocumentMutatorIsClassified` +5 |
| 53 | The person key's doors (store, verifier, recogniser, link/forget, find, sign, store choice) are counted per file | `PersonKeyCensusTests` +2 |

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

Before editing a path, read the area guide its row names. If a path matches several rows, read the most specific.

| Path | Area guide | The one rule to remember |
|---|---|---|
| `Packages/MaughamCore/**` | `Packages/MaughamCore/Sources/MaughamCore/AREA.md` | Both apps share it: implement once here, never twice (tripwire 19). |
| `Maugham/OpLog/**` | `Maugham/OpLog/AREA.md` | The op log is the source of truth; every load goes through `Document.load`. |
| `Maugham/Stores/**` | `Maugham/Stores/AREA.md` | Move or delete user content only through `DocumentStore`'s typed mover (tripwire 14). |
| `Maugham/Views/**` | `Maugham/Views/AREA.md` | Ask `Posture` what to offer; never compare a permit rung (tripwires 47, 51). |
| `Maugham/Editor/**` | `Maugham/Editor/AREA.md` | The `EditorHost` binding is fragile (tripwires 2, 3, 6, 7). |
| `Maugham/Canvas/**` | `Maugham/Canvas/AREA.md` | Membership never changes on a move or resize (tripwire 31). |
| `Maugham/Compiler/**` | `Maugham/Compiler/AREA.md` | The compiler reads and never writes; Maugham writes at ingest. |
| `Maugham/MCP/**` | `Maugham/MCP/AREA.md` | One catalogue, `MCPToolCatalog.all`; MCP never writes manuscript text. |
| `Maugham/Publish/**` | `Maugham/Publish/AREA.md`; the emission contract is `Maugham/Resources/PublishStarter/EMISSION.md` (generated) | Edit `EmissionContract.swift`, never `EMISSION.md`; keep `style_file` inside its `\begingroup`. |
| `Maugham/Updates/**` | `Maugham/Updates/AREA.md` | — |
| `Maugham/Models/**` | `Packages/MaughamCore/Sources/MaughamCore/AREA.md` (Project model) | Schema evolution follows ADR 0015. |
| `MaughamPhone/**` | `MaughamPhone/AREA.md` | AppKit never; WhisperKit is Mac-only. |

## Inbox + transcription (`Maugham/Stores/` — iPhone-companion Mac side)

`InboxStore`, `InboxPane` and the transcription worker are described in `Maugham/Stores/AREA.md`.
MCP's scope over the inbox is **read + promote only** (no add/trash from MCP).

## Behavioural claims + rulings (`register/`)

Claims (verified facts, each pinned by a test) and rulings (Denver's product decisions) live under `register/`; start at `register/START-HERE.md`.
- **Before changing behaviour in a module that has a claims file, read its filings**, and fixing a filed defect closes the loop in the same branch: fix, pinned production test, claim updated, filing flipped `VIOLATES→COMPLIES`.

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
