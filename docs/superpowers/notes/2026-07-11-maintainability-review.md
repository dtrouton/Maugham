# Maintainability Review — 2026-07-11

Full fresh-eyes audit per `docs/superpowers/specs/2026-07-11-maintainability-review-design.md` (plan: `docs/superpowers/plans/2026-07-11-maintainability-review.md`). Method: mechanical git pre-pass → 9 parallel map+find agents (6 dimensions + 3 end-to-end tracers) → coordinator synthesis over territory maps → 3 targeted hypothesis probes → coordinator re-verification of every High/Critical against source. Raw maps preserved in the session scratchpad (`maps/*.md`).

**Headline:** the op-log core, tripwire-grep system, updater trust chain, and CI pipeline are in genuinely strong shape — several enforcement patterns here (planted-offender self-checks, choke-point types, the contracts registry) are better than industry norm. The real risk concentrates in three places: (1) the **external-merge door** (`Document+ExternalChange.swift`) and the **fire-and-forget task-op append**, where cross-device sync and quit-timing interact with newer features; (2) the **palette area** (newest, least-soaked — five independent defects); (3) **doc-truth drift**, including a 50-day-stale claim in CLAUDE.md itself.

---

## 1. Trend metrics (longitudinal baseline — compare at next audit)

| Metric | 2026-07-11 |
|---|---|
| Source Swift files / LOC | 406 / 60,374 |
| Test Swift files / LOC | 448 / 56,273 (ratio 0.93) |
| Source files >800 LOC | 11 |
| ADRs | 23 |
| CLAUDE.md tripwires | 21 |
| Memory files | 58 |
| MCP tools | 47 (doc claim verified against `MCPToolCatalog.all`) |
| Commits since last full audit (2026-05-19) | 1,122 |

**Hotspots (churn×LOC since 2026-05-19, top 6):** `EditorCoordinator.swift` (56 commits, 2,293 LOC), `ProjectWindow.swift` (86, 1,387), `Document.swift` (74, 1,030), `DocumentStore.swift` (34, 846), `MaughamApp.swift` (49, 548), `EditorSurface.swift` (33, 549).

**Temporal coupling:** all 7 cross-area co-change pairs adjudicated — 6 explained by declared typed seams; `EditorCoordinator↔AnnotationsPane` (8×) is implicit shared-dependency coupling through `Document` (no direct seam; correct today by discipline). The `EditorSurface↔EditorHost` 21× pair is explained by a typed-but-40-parameter `EditorSurface.init` — the width *is* the coupling.

---

## 2. Emergent / cross-cutting findings

These are the "didn't look like a problem until connected" items — no single area contains them. All Highs coordinator-verified against source.

### E1 [High] Task ops and their ⌘Z undos can be silently lost on quit — state reverts on relaunch
`appendTaskOpInternal` updates the in-memory mirror synchronously, then disk-appends in a detached fire-and-forget `Task` (`Maugham/OpLog/Document+Tasks.swift:192-212`). Task ops never enter the `pending` buffer, so crash-recovery mirrors don't cover them (`Document.swift:347-358`, `:948-953` persist `pending` only); `Document.close()` drains burst + autosave but never the detached appends; app terminate is itself fire-and-forget with ~100ms budget (`ProjectWindow.swift:214-219`). Toggle a task (or ⌘Z one) → quit promptly → relaunch shows the pre-toggle state, silently. The annotation path does this right (`await opStore.append` before returning, `Document+Annotations.swift:133-134`). The in-code comment claims "a re-derive on reload reconciles" — false here: reload derives from disk, which never got the op. — fix-shape: await like the annotation path, or a tracked in-flight-append set drained in `close()` — effort M.

### E2 [High] Editing a palette card after renaming it from the research tree silently reverts the rename and recreates the file at the old path
`PaletteCardEditor` seeds only on `.task(id: cardId)` — a rename changes title/path, not id, so the mounted editor's draft goes stale (`PaletteCardEditor.swift:411-413`). Any subsequent edit persists the stale title; `updatePaletteCard` sees `card.title != oldItem.title` and renames the file BACK (`ProjectStore+Palette.swift:74-75`), then writes at the reverted path (`:96-99`). The empty-title fallback (`PaletteCardEditor.swift:444-446`) doesn't fire; the generation guard protects only the imagePaths re-pull. Tripwire-14-class outcome reached without any raw `moveItem`. — fix-shape: baseline title captured at seed; treat draft title as rename intent only when the *user* changed it; reconcile/cancel pending save on external rename — effort M (+ regression test crossing .md↔manifest).

### E3 [High] The external-merge door discards live work — three defects, one function
`Document+ExternalChange.handleExternalLogChange` (verified):
- **(a)** Re-derives `paragraphs` purely from disk ops, never folding the un-bursted `pending` buffer — a peer op syncing in mid-draft (phone Accept, second Mac) visibly discards up to 30s of typing from the editor and autosaves the wrong text (recoverable only on reload) — `Document+ExternalChange.swift:53-78,114`.
- **(b)** Publishes via `recomputeDisplayText()` without arming `_undoCoherentApplyPending` → `applyExternalText(preserveUndoStack:false)` → `removeAllActions()`: a *remote* event wipes the writer's entire ⌘Z stack, even for ops on unrelated paragraphs (found independently by both the lifecycle tracer and the bug hunt) — `:114` + `EditorSurface.swift:289-293` + `EditorCoordinator.swift:647-649`.
- **(c)** Uses `Deriver.derive` without the sequence fallback and skips `reconcile`, diverging from `Document.load` — legacy peer logs can order differently live vs after reload, and orphan paragraphs aren't trimmed live (phantom task rows until reopen) — `:76-86` vs `Document+Load.swift:217-218`.
— fix-shape: flush-or-fold pending before merge; arm the coherent-apply flag (or gate the undo clear on caret-paragraph impact); route live-merge through the same derive+reconcile as load — effort M+M+S.

### E4 [Medium] The "1MB MCP response cap" is documentation, not code, for 46 of 47 tools
Three independent confirmations: only images enforce a byte budget (`ImageResponseBuilder`, real 720KB stepping); `read_document` on a novel emits the full text unbounded (`DocumentTools.swift:90-100`); the only size-cap test in the suite covers the palette image tool (`PaletteToolsTests.swift:150`). ADR 0004 / tripwire 10 read as settled invariants. — fix-shape: byte-budget check on text tools returning structured `payload_too_large` + read-by-section hint; shared budget test helper — effort M.

### E5 [Medium] The phone-v0.1.1 contract-drift class is alive in two places the registry doesn't cover
(a) Inbox asset subdir literals `"images"`/`"audio"` + the `sourceFilename`→subdir mapping hardcoded independently in `MaughamPhone/Capture/InboxCaptureWriter.swift:50,54` vs `Maugham/Stores/InboxStore.swift:246-248` — no shared helper, no registry row. (b) The phone's `OpLogFilenameContractTests` hand-reproduces the doc-id shape as a literal while the Mac test calls the production minter — a Mac-side format change wouldn't fail the phone test (`MaughamPhoneTests/OpLogFilenameContractTests.swift:9-14`) — *inside the very test that fixed the original bug*. The registry governs filenames and Codable shapes but not path values inside sidecars or directory layout. — fix-shape: MaughamCore choke-point `InboxManifest.assetURL(kind:filename:in:)` + registry row; shared id-shape helper or golden cross-check — effort S+M.

### E6 [Medium] MCP tool work runs on the UI main actor, and the closed-doc read path is synchronous + uncoordinated
Tool handlers and `Document` are `@MainActor`; `read_document` runs `materialize()` / `DerivedManuscript.materialize` → `OpLogStore.loadSyncMerged` (synchronous disk JSONL read+derive, which also bypasses `NSFileCoordinator`) on the main thread — a large read while the writer types stalls the editor (`DocumentTools.swift:78-80`, `DerivedManuscript.swift:16-26`, `OpLogStore.swift:331`). The socket-syscall offloading stops one hop short of where the cost is. — fix-shape: background-executor hop or route through `DerivedManuscriptCache` (currently bypassed by `read_document`) — effort M.

### E7 [Low] Tripwire-20's phone exemption is broader than intended
The phone Read tab's `.md` display read is a *contracted, registry-documented* deviation (ADR 0018:111-113, `cross-surface-contracts.md:40`) — working as designed. But the `// adr-0018-ok:` annotation sits on the generic `CoordinatedFileIO.coordinatedRead` primitive (`MaughamPhone/Storage/CoordinatedFileIO.swift:68`), blanket-exempting every caller (inbox, manifest, checksum…), and `MaughamPhone/AREA.md` never restates the divergence. — fix-shape: move the annotation to the `DocumentReaderView:276` call site; 2 lines in AREA.md — effort S.

---

## 3. Per-dimension findings

### 3.1 Architecture & code health (A1)
- [High→§2 E-adjacent] **Palette writes bypass `NSFileCoordinator`** — `ProjectStore+Palette.swift:98-99` (+ `:35`) raw `write(to:atomically:)` on a cloud-synced file; the research-note precedent coordinates via `DocumentStore.performFileSave:264-278`. Can conflict-twin under iCloud. Not caught by the raw-move grep (guards moves, not writes). — route through a coordinated write + add write-coordination assertion — S. *(Verified.)*
- [Medium] **Task-marker predicate duplicated ×3 and already drifted**: `Document+Tasks.swift:24-25` ≡ `TaskAnchorAlignment.swift:366-367` (lowercase-only) vs `TasksPane.swift:734` (handles `[X]`) — a writer's `- [X]` flips in the pane but skips cache invalidation. — shared `TaskMarkup` predicate in MaughamCore — S.
- [Medium] **`EditorCoordinator.swift` = 2,293-line single class** (48 stored properties, 63 methods, no extension split) — the repo's #1 hotspot and its worst LLM-context hazard; MARK clusters are already disjoint. — mechanical split by MARK cluster — M.
- [Medium] **`EditorSurface.init` ~40-parameter closure wall** — the direct cause of the 21× co-change pair; a bundled config struct would collapse it — M.
- [Low] `createCraftIntent` not idempotent under slug collision (hardcoded `research/craft-intent.md` lookup vs deduping creation → duplicate intents minted) — `ProjectStore+CraftIntent.swift:38-44` — S.
- [Low] Dead params: `CollectionPiecesPane.onAddPiece`; `HelpClaudeDesktopSheet.projectURL/projectTitle` — S.
- Notes: ADR 0016–0023 compliance verified; palette/craft follow the research precedent ~90% (rename/move/trash typed) — the divergences are the write path and round-trip above. `ProseMode` "[dead code]" comments on intentional exhaustive-switch arms invite wrongful deletion.

### 3.2 Test suite (A2)
- [High] **Tripwires 6/7 enforced by symptom tests only** — call-count assertions in specific harness scenarios; a 4th `applyExternalText` caller outside those paths passes silently. *(Verified: single production caller today, `EditorSurface.swift:291`; no call-site census exists.)* — add structural census (grep-count) — M.
- [Medium] "first-MCP-call-after-restart" flake (deferred 2026-05-17) has **zero regression test** — cold-restart test on the real-binary harness — M.
- [Medium] No exhaustiveness test tying `OpKind` cases to undo inverse coverage — completeness is discipline; a new OpKind can ship without an inverse — S.
- [Low] 13 files hand-roll `makeProject(initialMd:)` (~250 dup lines) — extract next to `OpLogSeedTestHelper` — S.
- [Low] E2E publish/MCP-binary tests skip-gate on pre-built artifacts — CI config silently determines whether that coverage runs at all.
- [Low] `PalettePaneTests` has 2 tests (thin UI wiring over a well-tested store); `RewindUndoTests:305` reaches into `_opLogMirror` internal.
- Positive: cross-surface round-trips now use production-shaped on-disk data (the phone-v0.1.1 lesson absorbed); `MarkdownBlockParityCorpusTests` row-labeled regression corpus; planted-offender self-checks on grep tripwires.

### 3.3 Docs & context files (A3; all staleness claims verified)
- [Critical] **`MaughamPhone/AREA.md:61` claims phone annotation undo/reopen is "deferred"** — it shipped in phone-v0.5.0 (2026-07-10). A fresh session gets a false model of a load-bearing area — S.
- [High] **CLAUDE.md "Outstanding correctness concerns" bullet is false** (Annotations/History tooltips shipped 2026-05-22, `DetailPaneToggle.swift:103,114`) — ~7 weeks stale in the mandated first-read file; found independently by two agents. Same stale claim duplicated at `docs/roadmap.md:65-66` — S.
- [Medium] `docs/guide/reference.md` keybinding table omits ⌘⌥4 History and ⌘⌥7 Palette; `right-pane.md` says "three modes" and never mentions History/Palette — S.
- [Medium] The recordWordCount silent-unwiring class is still doc-invisible: `Editor/AREA.md`'s binding contract never mentions the side-effect obligations; the excellent `EditorBindingSideEffectsTests` doc-comment is somewhere the documented workflow never routes a reader — add an AREA.md tripwire line — S.
- **Onboarding test (4 historical failures):** phone doc-id parser YES; raw-.md-as-truth YES; unscoped NotificationCenter YES; recordWordCount **NO** (above).
- **Generation candidates** (EMISSION.md pattern): "47 tools" prose ↔ `MCPToolCatalog.all.count` assertion; keybinding table ↔ enumerate `.keyboardShortcut` in Views (would have caught both omissions); right-pane mode list ↔ `DetailPaneToggle` cases; roadmap's "39 surviving maugham.* names" count; AREA.md-says-deferred vs roadmap-says-✓ contradiction heuristic (would have caught the Critical).
- Structural: right-pane facts asserted in **five** places, 2 of 5 stale; no "close the loop" step propagates a roadmap •→✓ flip into sibling docs.

### 3.4 Tripwire & memory promotion (A4) — see table, §4
Top gaps: `ParagraphID.mint()` and `DeviceSlug` are confirmed-bitten footguns at prose-rung when rung 4–5 is cheap; the **whole-branch-review lesson has recurred five times without ever being written as a rule**; TW7 narrower than the table implies; TW14's "enforce-by-construction" overstates (it's grep-level); TW5's `CharacterAutocompleter` wording stale (already deleted).

### 3.5 Security (A5) — nothing Critical/High under the single-user local threat model; CI/updater clean
- [Low] `.mzseg` decoder inflates before checking `expected` length — decompression bomb → OOM (`OpLogSegment.swift:117-122`) — M.
- [Low] Trash restore trusts `meta.json` relative paths verbatim — `../` escapes project root (`TrashStore.swift:87,:132`) — S.
- [Low] Manifest/sidecar-derived paths appended without `..` validation (`DocumentTools.swift:116,:160`; `InboxStore.swift:251`) — shared resolve-inside-root helper — M.
- [Low] MCP socket: no auth beyond fs perms; unbounded per-connection read buffer (`MCPServer.swift:54-69,156-163`) — chmod 0600 + cap — S.
- Verified live: **all six CI action SHAs dereference to their claimed tags** (no fabricated SHA this pass). Secrets never echoed; `persist-credentials:false`; JSONL malformation handling is the strongest area (contained per-record, quarantine diagnostics).

### 3.6 Bug hunt (A6)
- [Medium] **Palette: a markdown image typed in the body is harvested into `imagePaths`, becomes an un-removable bouncing thumbnail** (remote URLs → permanent broken tile) — parser harvests body-wide, renderer never strips (`PaletteCard.swift:188-191,224-225,256-268`) — M.
- [Medium] **Undoing an inline-task archive that collapsed its paragraph leaves the paragraph's annotation archived** — the compound undo's `flushBurstNow()` fires the orphan sweep as a side effect and never reopens what it archived; the rewind path does this correctly (`Document+Tasks.swift:541,:598` vs `Document+RewindUndo.swift:172-177`) — M.
- [Low] `MarkdownBlockParser` mishandles CRLF (blank lines unrecognized → paragraph merge, `---\r` fails) (`MarkdownBlockParser.swift:24,:28,:148`) — S.
- [Low] Palette body silently normalized on reopen (indentation stripped, blank runs collapsed) — violates the type's own stated `parse(render(card)) == card` invariant (`PaletteCard.swift:4-5,:134,:196-209`) — M.
- Map note: inline-image regex exists twice with different strictness (permissive palette copy is the root of the harvest bug).

### 3.7 Tracers (T-A/T-B/T-C) — findings folded into §2/E-items above; additional:
- [Low] Typing undo is native LWW, not op-log-backed — ADR 0023 doesn't cover typing; one text-touching op-undo (D1 clear) erases all prior typing-undo history. Scope boundary worth stating in ADR 0023 — S.
- [Low] `read_document` resolves open docs by **path** while annotation tools resolve by **docId** (`DocumentTools.swift:77` vs `AnnotationToolHelpers.swift:34`) — a rename-timing gap could reintroduce the exact ADR-0018 id disagreement; also enables a transient second `Document` writing the same JSONL — one shared docId-keyed resolver — S.
- [Low] Tool methods are callable as top-level JSON-RPC, bypassing the `tools/call` error envelope (`MaughamApp.swift:301`, `MCPServer.swift:243`) — M.
- [Medium] Dismissed-then-quit staged update silently dropped when install location unwritable/python3 absent — terminate path ignores `launchSwapHelper`'s `false` (unlike `installNow`) (`MaughamApp.swift:50-53`) — S.
- [Medium] Release toolchain floats (`xcode-version: latest-stable`, unpinned `brew install xcodegen`) while everything else is SHA-pinned — the two moving parts most affecting signing/codegen (`release.yml:29,38`) — S.
- [Low] `.dmg` update path skips all in-app verification (safe only because dmg is never swapped in-place; contradicts RELEASING.md's description) (`UpdateChecker.swift:105-108`) — document — S.
- [Low] Mac `CFBundleVersion` = `run_number` (resets on workflow rename) vs phone's monotonic `rev-list --count` — S. Unauthenticated GitHub API rate limit on shared IPs — S.
- Positive: updater trust chain is genuinely strong (team-anchored, notarization-gated, fail-closed on nil TeamID, atomic swap); annotation MCP writes are durable-before-return; `Slugifier` makes research-note paths traversal-safe by construction.

---

## 4. Tripwire & memory promotion table (A4, enforcement verified against test source)

Ladder: 1 prose → 2 checklist → 3 grep/CI test → 4 type constraint → 5 impossible-by-construction.

| Item | Now | Achievable | Action |
|---|---|---|---|
| TW3, TW6 (binding races) | 3 | 3 | keep (but see A2-High: symptom-only for 6/7) |
| TW7 (no 4th applyExternalText caller) | 3-narrow | 4 | **promote**: call-site census grep |
| TW12 (SynthesisSource enum) | 4 | 4 | keep |
| TW13, TW20, TW21 (grep + self-checks) | 3 | 3–4 | keep — model implementations |
| TW14 (typed mover) | 3 | 4 | keep; **correct the "by construction" wording** (it's grep-level) |
| TW17 (per-device JSONL) / Bootstrap invariant | 4–5 | 4–5 | keep |
| TW2, TW4, TW9, TW15 | 1 | 2–3 | promote-to-test (TW15 recurred 4+ times — cheapest win) |
| TW5 (NSPopover) | 1 | — | **fix stale wording** (CharacterAutocompleter already deleted) |
| TW8 (test paragraph-id alphabet) | 1 | 3 | promote: lint-test over test literals |
| TW10 (1MB cap) | 3-images-only | 3 | **close the text-tool gap** (§2 E4) |
| TW1, TW11, TW16, TW18, TW19 | 1–3 | — | keep as-is (fences hold / policy / structural fix shipped) |
| **NEW: `ParagraphID.mint()` guard** | 1 | 4 | promote: forbid bare `mint(` outside type+tests, or deprecate (bitten at scale once) |
| **NEW: `DeviceSlug` wrapper** | 1 | 4 | promote: struct with `.make(from:)` sole constructor (bitten twice) |
| **NEW: husk-reload keyed on path not id** | 1 | 2 | new tripwire row (fixed at 2 sites; a 3rd surface would repeat it — E2 is literally this class in palette form) |
| **NEW: whole-branch review before merge** | 0 | 2 | **add to CLAUDE.md Default Workflow** — most-repeated lesson in the memory corpus (5 recurrences incl. one positive control), never written down |

Memory hygiene: no memory contradicts current code except via the stale-claims found above; "smoke finds seam bugs" is re-narrated in 8+ milestone memories instead of linking the canonical feedback memory (drift surface).

---

## 5. Hardening-milestone shortlist (revised after user adjudication 2026-07-11)

Principle applied (user decision): no "defer until touching the area anyway" bucket — an item is either worth doing (scheduled as a real task) or not (dropped, with the reason recorded in §5.1). Churn-avoidance is not a reason to skip a good change; regression risk is managed by method (mechanical steps, tests, smoke, sequencing), not deferral.

1. **Sync-and-durability correctness** — opens with the two structural tasks so the behavior work lands on the improved shape and exercises it: (a) EditorCoordinator MARK-cluster split + `EditorSurface.init` config struct (mechanical-only, tests green + smoke before anything stacks on top); then (b) E1 task-op durability (await or tracked-drain); (c) E3(a) fold pending into the external merge; (d) E3(c) live-merge derives+reconciles like load; (e) E3(b) **conservative slice only**: arm coherent-apply for pure-append merges, keep the D1-consistent clear otherwise — the caret-aware gating variant is a design decision declined (re-opens the v0.16 ⌘Z-crash class), not a descope.
2. **Palette hardening**: E2 rename-revert; A1 coordinated writes; A6 inline-image harvest + body normalization; unify the inline-image regex on `MarkdownBlockParser`'s; pane tests. Plus the A6-Medium task-archive-undo annotation reopen (same undo family).
3. **Doc-truth batch**: phone AREA.md undo line; CLAUDE.md stale bullet + TW5 wording + TW14 rung wording; roadmap carry-forward; reference.md/right-pane.md modes; Editor/AREA.md side-effect tripwire line; adr-0018-ok annotation relocation + AREA note; MCP/AREA.md trust-boundary paragraph (socket = same-user, filesystem-enforced); delete hand-maintained counts from roadmap prose. Then the **crisp generation tests**: tool-count ↔ `MCPToolCatalog.all.count`; keybinding-table ↔ `DetailPaneToggle` enumeration; right-pane mode list. Plus a workflow line: roadmap •→✓ flip triggers a sibling-doc sweep (checklist, not a fuzzy test).
4. **Enforcement-ladder batch**: ParagraphID.mint guard; DeviceSlug wrapper; TW7 call-site census; TW15 grep; TW8 test-literal lint; OpKind↔undo exhaustiveness test; whole-branch-review line in CLAUDE.md Default Workflow; husk-reload tripwire row; inbox-subdir choke-point + registry row; shared TaskMarkup predicate.
5. **MCP robustness**: text byte-budget (E4); E6 **narrow version**: closed-doc `read_document` routed through `DerivedManuscriptCache` / background-derived (full async Document access declined — re-opens the binding-race class); docId-keyed resolver unification.
6. **Robustness + release batch**: trash meta path validation; shared resolve-inside-root helper; mzseg inflate bound (small robustness fix, no security ceremony); terminate-path update fallback; release toolchain pinning **+ CFBundleVersion → `rev-list --count` in the same task** (one dry-run validates both); pinned-SHA↔tag verification as a `cut-release.sh` preflight (deterministic moment — deliberately NOT a per-CI-run lint).
7. **Test hygiene**: shared `makeTestProject` helper (kills the ×13 duplication); craft-intent slug-collision fix; dead-param removal.
8. **Decision item for scoping (user call)**: first-MCP-call-after-restart — either fix the bug AND pin it with a regression test in this milestone, or explicitly re-defer the bug. A test alone against the unfixed nondeterministic behavior is declined (flaky by construction).

### 5.1 Dropped on merit (recorded so the next audit doesn't re-litigate)
- **MCP socket auth / chmod**: threat model is same-user processes, which can already read the files directly; defends nothing the filesystem doesn't. Documented instead (item 3).
- **Top-level tool-method registration fix**: closes a path no real client can reach; M effort for a code-comment's worth of value.
- **TW2 / TW4 promotions + AREA↔roadmap contradiction heuristic**: the proposed checks are fuzzy; false-positiving tripwires teach sessions to ignore tripwires — negative value on the enforcement ladder. Rules stay as prose.
- **Roadmap prose-count assertions**: deleting the counts beats testing them.
- **Inbound socket buffer cap**: same-user threat model; fold in only if `MCPServer.swift` is open for another reason.
- **E3(b) caret-aware undo gating / E6 full async re-architecture**: declined as designs, not descoped — each re-opens a historically-bitten bug class for marginal benefit over the narrow version shipped in items 1/5.

---

## 6. Resolved / refuted suspicions (so the next audit doesn't re-chase)

- **Phone reader reads raw `.md` (suspected TW20 violation/grep hole):** RESOLVED — contracted Tier-2 divergence, annotated and registry-documented; reader-vs-annotations disagreement while the `.md` lags is *designed* behavior. (Residual: E7 annotation-placement + AREA note.)
- **Palette rename × 500ms debounce racing typed mover:** the narrow race framing was wrong; the real defect is worse (stale-draft revert, no race needed) — see E2.
- **CI action SHAs fabricated (recurrence of PR-#1 class):** REFUTED — all six pins verified live against their tags.
- **"47 tools" doc count drift:** REFUTED — count verified exact; the gap is the missing assertion, not the fact.
- **EditorCoordinator↔AnnotationsPane hidden coupling:** benign — shared-dependency via `Document`, consistently routed.

## 7. Review-process notes

- All 9 dimension/tracer agents passed the two-part output contract on first delivery; the maps' "surprises & tensions" sections produced the raw material for every emergent finding — the design worked as intended (E1, E2 came from map-fact collisions, not from any agent's findings list).
- Every High/Critical (7 items) was coordinator-re-verified against source; **zero were dropped or downgraded** — agent precision was high this pass.
- Independent double-confirmation occurred naturally three times (CLAUDE.md stale bullet: A3+A4; merge-wipes-undo: TA+A6; 1MB gap: A2+A4+TB) — worth keeping overlapping briefs.
- Background agents consistently went idle without delivering; every report required one SendMessage nudge. Next time: include "send your report to main via SendMessage before finishing" in the brief.

---

## 8. Post-merge addendum (v0.20.0 / phone-v0.6.0 "palette everywhere", merged 2026-07-11)

Re-verified the affected findings against the merged milestone:
- **Craft-intent slug collision (A1-Low): FIXED upstream** — role-first identity + lazy healing (`ProjectStore+CraftIntent.swift`, `ResearchRole`/`PaletteLookup` in MaughamCore). Removed from shortlist item 7.
- **E2 rename-revert + A1-High uncoordinated write: still live** — editor changed by an import only; `updatePaletteCard` unchanged in behavior (raw write now ~`ProjectStore+Palette.swift:120`, template write `:57`).
- **A6 parse/render bugs: still live, now cross-surface** — `PaletteCard.swift` moved verbatim to `Packages/MaughamCore/`; the phone Read tab (`MaughamPhone/Read/PaletteCardView.swift` + `PaletteLoading.swift`) parses through the same code, so the inline-image harvest and body-normalization defects now surface on both platforms. Shortlist item 2 file refs updated accordingly; fixes land once, benefit both.
- **E5 inbox subdir literals: still live** — `PaletteConvention` proves the choke-point pattern but inbox `"images"`/`"audio"` remain duplicated (`InboxCaptureWriter.swift:50,54` vs `InboxStore.swift:324-325`). Shortlist item 4's fix should mirror `PaletteConvention` (an `InboxConvention` in MaughamCore + registry row).
- Tool count remains 47 (promote_inbox_entry gained palette params, no new tool). The milestone's ~2.5k new lines postdate this audit's agent pass — covered by the next scheduled sweep.

---

## 9. Execution status — hardening milestone (branch `feat/hardening-2026-07`, 2026-07-12)

All 8 shortlist groups (§5) implemented as 31 tasks + 1 scheduled follow-up (22b), subagent-driven, each with a two-stage review; then a whole-branch review (the rule this milestone ships) that found one genuine emergent bug. Final gate: Mac 2262 tests + phone 220 + Release build green. Decision item §8: fixed + pinned (root cause = asymmetric bridge reconnect budgets, not the stale-fd hypothesis).

**Shipped (all ✓):** structural split (EditorCoordinator +4 extensions, EditorSurfaceConfiguration); E1 task-op durability; E3(a) merge folds pending typing + un-bursted reorder; E3(c) live-merge derive+reconcile parity (Tank-Park regression pinned on the merge path); E3(b) conservative pure-append undo-preservation via `hasPrefix` range-safety predicate (the plan's paragraph-map predicate was corrected during review — it admitted reorder/mid-insert stale-range holes); task-archive-undo annotation reopen; all 5 palette fixes (rename-revert, coordinated writes, inline-image harvest, body byte-preservation, regex unification) — cross-surface via MaughamCore; doc-truth batch + 3 generation tests (which immediately caught the undocumented ⌘⌥6 Inbox mode); enforcement ladder (mint guard, DeviceSlug construction-safe type, TW7/15/8 greps, OpKind↔undo exhaustiveness, InboxConvention, TaskMarkup + scanner uppercase-[X], DocIdShape shared contract); MCP byte-budget + closed-doc cache routing (freshness audited airtight) + docId-keyed resolver; robustness (SafeRelativePath 5 sites, mzseg inflate bound, terminate-path update reveal, download progress streaming — the user-reported bar bug); release pinning (Xcode + pinned-binary xcodegen + monotonic CFBundleVersion + SHA↔tag preflight).

**Whole-branch review — the emergent catch (validates the process):** Task 4's close-drain (durability) did not cover Task 8's compound-undo appends (they hop via `OpUndoRegistrar._lastUndoWorkTask`, not `inFlightTaskAppends`), and `appendTaskOpInternal`/`reopenAnnotation` lacked the `rejectMutationIfClosed` guard their siblings have — an archive→⌘Z→⌘Q race could persist a torn/inconsistent op log. Invisible to both tasks' own reviews (every undo test awaits undo work before close). Fixed (`await _lastUndoWorkTask` before husk + atomic-decline guards + a close-during-undo regression test) and independently re-reviewed on the concurrency seam. The two highest-risk convergence zones (merge-door trio, read_document's 4 layers) had **no active bugs** — safety invariants verified concretely.

### 9.1 Scheduled follow-ups (no-defer rule — real work, not dropped)
- **F-A: palette `## Images`-in-body mid-heading hardening** — a body line spelling a known section heading is claimed by section detection and drops following body text (editor-reachable, pre-existing, converges from 2nd render). Fix: promote `## <known>` to a section only once `seenSectionHeading || kindCaptured` + blank-delimited; own TDD + parity-corpus check (like 22b). Contract doc-comments corrected now to stop overselling `parse∘render==id`.
- **F-B: external-merge sweep reentrancy** — a prior local delete leaves `_pendingSweep` set; a subsequent pure-append merge still runs `sweepOrphanedAnnotations`'s `await`, and a keystroke racing that op-append I/O suspension can mutate paragraphs/sequence mid-merge (data-correctness window; pre-existing, undo-safety prefix still holds). Own task: reason about the sweep-await reentrancy.

### 9.2 Accepted residuals (documented, not fixed — record for next audit)
- Whole-branch fix ⚠️: a hop spawned *after* close reads `_lastUndoWorkTask` but during a later pre-husk await → durability gap (not torn log); unreachable in practice (⌘Z sets the task synchronously before ⌘Q's close reads it); narrowed-not-introduced by the fix.
- `read_document` text budget is a pre-wrap 900KB check; backslash/quote density ~11–15% at 900KB can still exceed the 1MB line (compile-log/code content); documented in MCP/AREA.md; realistic prose is <1% density.
- MCP central budget backstop covers only the `tools/call` path (top-level method invocation bypasses it — the merit-dropped registration issue); per-tool `enforce` calls on the big readers hold on both paths.
- WB5 mirror-overwrite of an in-flight task op during concurrent sync: transient, self-healing (opId dedup + detached append), no durable loss.
