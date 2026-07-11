# Hardening Milestone — Design

**Date:** 2026-07-11
**Status:** Approved scope; spec pending user review
**Provenance:** `docs/superpowers/notes/2026-07-11-maintainability-review.md` §5 (revised shortlist), §5.1 (merit-drops), §8 (post-v0.20.0 addendum). All findings referenced below are verified there with `file:line` evidence; this spec does not restate evidence.

## Goal

Implement the full revised shortlist from the 2026-07-11 maintainability review as one milestone: eliminate the two verified silent-data-loss classes, harden the palette area (now cross-surface in MaughamCore), close the doc-truth drift with generation tests, climb the enforcement ladder where checks are crisp, and fix the deferred MCP-restart flake. One branch, whole-branch review, paired Mac + phone release.

## Scope decisions (made with user, 2026-07-11)

- **Everything in one milestone** — all shortlist items; ambitious-bundle default confirmed.
- **MCP-restart flake: fix + pin** — diagnose and fix the first-call-after-restart failure, land the cold-restart regression test WITH the fix (test-alone was ruled out).
- **Craft-intent slug collision: retired** — fixed upstream by v0.20.0 role-first identity (§8).
- Binary-triage rule applies throughout (`feedback_no_defer_bucket`): nothing is parked; §5.1 merit-drops are final.

## Phases (one branch, ordered; each phase gates on green tests before the next)

### Phase S — Structural first (mechanical-only; no behavior change)
S1. Split `EditorCoordinator.swift` (2,293 lines) into extensions by existing MARK cluster (`+ReviewRender`, `+TabCycle`, `+Typography`, `+Cursor`, delegate core stays). Byte-identical behavior; full Mac test suite + Release-config build (ProjectWindow tripwire) must pass.
S2. Bundle `EditorSurface.init`'s ~40 parameters into a config/dependencies struct (typed, same call sites, no semantic change). This is the seam guarded by tripwires 2/3/6/7 — the harness tests are the gate.
S3. Extract shared `makeTestProject(prefix:initialMd:)` test helper; migrate the 13 duplicating files.
*Rationale: the behavior work below lands on the improved shape and smoke-tests the refactor for free.*

### Phase 1 — Sync & durability (the Highs)
1a. **E1**: task-op appends become durable — either `await` like the annotation path or a tracked in-flight-append set drained in `Document.close()` (implementer picks after reading both call-site shapes; blast radius favors the drain-set). Regression test: mutate → close → reload asserts the op landed.
1b. **E3(a)**: `handleExternalLogChange` folds/flushes the `pending` buffer before re-deriving — un-bursted typing survives a peer merge. Regression test with a live pending buffer + injected peer op.
1c. **E3(c)**: live-merge derives via the same `deriveWithSequenceFallback` + `reconcile` path as `Document.load`.
1d. **E3(b) conservative slice only**: arm `_undoCoherentApplyPending` for pure-append merges so they stop wiping the ⌘Z stack; any merge that changes existing paragraphs keeps the D1-consistent clear. The caret-aware variant is DECLINED by design (re-opens the v0.16 ⌘Z-crash class).
1e. **A6-Medium**: compound task-archive undo captures the orphan-sweep's archived annotation ids and reopens them (mirror `restoreToOpUndoable`'s pattern).

### Phase 2 — Palette hardening (fixes land in MaughamCore → phone benefits)
2a. **E2**: rename-revert — baseline title captured at `seed()`; draft title is a rename intent only when the user edited it in-editor; external rename reconciles/cancels the pending save. Regression test crossing the .md↔manifest boundary.
2b. **A1-High**: palette card writes (update + template) route through a coordinated write (research-note `performFileSave` precedent) via the store's `documentStore` back-ref; add a write-coordination grep/assertion so the next research-adjacent seam can't diverge silently.
2c. **A6**: inline-image harvest — render strips inline `![]()` from body (or parser harvests only non-body images); remote-URL paths never enter `imagePaths`. Un-removable-thumbnail regression test.
2d. **A6**: body round-trip preserves bytes (indentation, blank runs) — make `parse(render(card)) == card` true for editor-typed bodies; property-style test over adversarial bodies.
2e. Unify inline-image extraction on `MarkdownBlockParser`'s anchored pattern (kill the permissive duplicate).
2f. Palette pane interaction tests (add/edit/reorder) — the wiring layer is 2 tests today.

### Phase 3 — Doc-truth + generation tests
3a. Corrections batch: `MaughamPhone/AREA.md` undo line; CLAUDE.md stale bullet + TW5 wording (CharacterAutocompleter is deleted, not dead code) + TW14 rung wording ("grep-enforced", not "by construction"); roadmap carry-forward; `reference.md` ⌘⌥4/⌘⌥7 rows; `right-pane.md` all-modes intro; `Editor/AREA.md` tripwire line for the binding side-effect contract (points at `EditorBindingSideEffectsTests`); move the `adr-0018-ok` annotation from `CoordinatedFileIO.coordinatedRead` to the `DocumentReaderView` call site + 2-line AREA note; MCP/AREA.md trust-boundary paragraph; delete hand-maintained counts from roadmap prose.
3b. Generation tests: doc tool-count ↔ `MCPToolCatalog.all.count`; keybinding-table ↔ `DetailPaneToggle` shortcut enumeration; right-pane mode list coverage.
3c. CLAUDE.md Default Workflow additions: **whole-branch review before merge** (the 5×-recurred lesson); roadmap •→✓ flip triggers a sibling-doc sweep (checklist line).

### Phase 4 — Enforcement ladder
4a. `ParagraphID.mint()` guard: grep test forbidding bare `mint(` outside the type + tests (or deprecate; implementer picks the less-churn option) + new CLAUDE.md tripwire row.
4b. `DeviceSlug` becomes a wrapper struct with `.make(from:)` as the sole public constructor (compile-error enforcement; bitten twice).
4c. TW7 call-site census: grep-count of `applyExternalText(` production call sites == 1, with planted-offender self-check.
4d. TW15 grep: `ContentUnavailableView(` not followed by `.frame(maxWidth: .infinity` (recurred 4+).
4e. TW8 lint-test: test-file scan for 4-char comment-id literals outside the `[0-9a-hjkmnp-tv-z]` alphabet.
4f. `OpKind` ↔ undo exhaustiveness test: every case has a registered inverse or an explicit non-undoable allow-list entry.
4g. Husk-reload tripwire row (Document-binding surfaces key reload on path, not id).
4h. `InboxConvention` choke-point in MaughamCore (mirror `PaletteConvention`) for `"images"`/`"audio"` subdirs + `sourceFilename` mapping; phone writer + Mac reader consume it; registry row.
4i. Shared `TaskMarkup.lineContainsTaskMarker` in MaughamCore (handles `[X]`); the three duplicates consume it.
4j. Phone `OpLogFilenameContractTests`: shared id-shape helper or golden cross-check so a Mac minter change fails the phone test.

### Phase 5 — MCP robustness
5a. **E4**: byte-budget on text tool responses — structured `payload_too_large` error with a read-by-section hint (shared helper + shared budget test applied across the catalog).
5b. **E6 narrow**: closed-doc `read_document` routes through `DerivedManuscriptCache` / background derive; live-doc branch untouched. Full async Document access DECLINED by design.
5c. One shared docId-keyed resolver for read + annotation tool families (closes the path-vs-docId split).
5d. **MCP-restart flake: diagnose, fix, pin** with a cold-restart test on the real-binary harness (`MCPBinaryIntegrationTests` pattern). The one open-ended-diagnosis task in the milestone — time-box the diagnosis; if the root cause exceeds the box, report back before proceeding.

### Phase 6 — Robustness + release pipeline
6a. Trash restore validates `meta.json` relative paths stay inside the project root.
6b. Shared resolve-inside-root-or-throw helper at the manifest/sidecar `appendingPathComponent(untrustedPath)` sites (`DocumentTools`, `InboxStore`).
6c. `.mzseg` inflate bounded by stored `expected` (+ ceiling) — small robustness fix, no ceremony.
6d. Terminate-path staged-update fallback: on `launchSwapHelper == false`, stash a reveal-on-next-launch flag instead of silently dropping.
6e. Release pinning: explicit Xcode version + pinned xcodegen, **and** `CFBundleVersion` → `git rev-list --count HEAD` in the same task; validated by one dry-run tag (patch ≥90 band).
6f. `cut-release.sh` preflight: resolve every workflow action SHA against its commented tag (deliberately not a per-CI-run lint).
6g. Dead-param removal (`CollectionPiecesPane.onAddPiece`, `HelpClaudeDesktopSheet` v2 leftovers); RELEASING.md documents the `.dmg` path as Gatekeeper-verified-on-launch.

## Testing policy

TDD per task (regression test demonstrating the defect first — several fix-shapes above name their test). Both schemes tested per MaughamCore change. **Whole-branch review before merge is mandatory** — this milestone ships the rule (3c) and must itself obey it; the unified-undo T5×T6 precedent is the reason. User runs the standard smoke plus: task-toggle→quit→relaunch, palette rename→edit, two-device merge-while-typing (or simulated peer-op injection).

## Release

Paired: Mac v0.21.0 + phone-v0.7.0 (MaughamCore palette fixes render on both surfaces). No schema bump expected — parse/render and store-path changes only; verify at cut. 6e's dry-run tag happens before the real cut.

## Out of scope (recorded decisions, not omissions)

- §5.1 merit-drops (socket auth, top-level registration fix, fuzzy tripwire promotions, prose-count assertions, inbound buffer cap).
- E3(b) caret-aware gating and E6 full-async — declined designs, revisit only on evidence the narrow versions are insufficient.
- Typing undo remains native/LWW (ADR 0023 scope boundary gets a sentence in the ADR, nothing more).
- Auditing the v0.20.0 palette-everywhere code (next scheduled sweep's window).
