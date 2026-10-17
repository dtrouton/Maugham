# Foundations Audit — 2026-10-17 (agent maintainability and extensibility)

*A deliberate audit, not a bug sweep. Denver asked whether the foundations are solid before Maugham takes on non-fiction or corporate writing. "Maintainability" here means agent maintainability: how much a fresh subagent must read before it can change something safely, how easily it finds the one right place, and how likely it is to break an invariant it cannot see.*

Method: five read-only opus reviewers. Each returned findings plus a territory map, following the maintenance-audit contract. Their territories:

- **A** — the view-layer monoliths;
- **B** — the engine and hub types;
- **C** — extensibility to new writing forms;
- **D** — agent-facing docs;
- **E** — tests, guardrails and the module graph.

The coordinator verified the claims marked VERIFIED against source. This note continues the 2026-09-20 full audit's §3.3 ("context-window economics", a carried and worsening Medium) and the 2026-10-04 and 2026-10-11 sweeps' F6.

## 1. Trend metrics

| Metric | 2026-09-20 (full) | **2026-10-17** |
|---|---|---|
| Source Swift files / LOC | 694 / 174,733 | **735 / 206,022** |
| Test Swift files / LOC | 851 / 264,328 | **936 / 315,860** |
| Source files >800 LOC / >1,500 LOC | 40 / — | **54 / 17** |
| Largest file | ProjectWindow 5,399 | **ProjectWindow 5,577** |
| CLAUDE.md words | — | **23,030** (2,306 on 07-01 → 5,242 → 11,141 → 22,716 on 10-01: it doubles each month) |
| Largest AREA.md (words) | — | **Canvas 48,005; OpLog 29,586; Views 27,098; Compiler 23,303** |
| Tripwires / ADRs | 42 / 32 | **53 / 33** |
| Comment share, Mac + Core sources | — | **45%** (84,560 of 186,092 non-blank lines) |

## 2. Synthesis: what the maps say together

These conclusions come from collisions between territories. No single reviewer could see them.

**S1. The guardrails freeze the file layout, and some of them would fail silently when it moves.** *(A × B × E)*
- About 100 tests read `Views/ProjectWindow.swift` by path (34 test files). 67 of 87 census sections in `TripwireGrepTests` name a real production file. So every split has to hand-edit censuses, and this is the structural reason the ProjectWindow split has been scheduled at four audits without landing.
- Worse, the censuses scoped to one file pass when that file is renamed or split: `grepSwift(in:files:)` skips names it does not find (`MaughamTests/TripwireGrepTests.swift:62`) and the callers assert `isEmpty`. **VERIFIED**: `test_theSilentAdmissionNarrowsNobody` (`:9462`, tripwire 49, a security census) scans `onlyFiles: ["RegistryPresence.swift"]`. Moving that code to another file turns the census green for ever.
- Each census also hand-lists its own scan roots (`sourceDir` 89 times, the Core path built ad hoc 16 times). A new SPM package would therefore drop out of most censuses without anything going red.

Conclusion: **fix how censuses find code before splitting anything.**

**S2. Context cost is mostly prose, so splitting files alone will not cut it.** *(A × B × D)*
- CLAUDE.md (≈31–41k tokens) loads into every session and every subagent: about 50× a task brief, and about 1M tokens per 10-task plan before any work starts.
- Required AREA reads can fill most of a window. For example, *change how OpLogStore seals* costs CLAUDE.md + OpLog AREA + `OpLogStore.swift` ≈ 115–135k tokens, before ADR 0032 (≈50k).
- Inside the monoliths, comments are 50–67% of lines (`CompilerOrchestrator` 1,948 lines → 562 code; `CanvasView` 2,314 → 548 code), much of it dated history ("Task N", "fix round 2", "Ruling U").
- Extension-file splits do not shrink what an agent loads either: `ProjectWindow` is one struct with 62 `@State`, and an extension still sees all of it.

Conclusion: **the docs diet and the comment-to-contract pass are worth as much as the splits.**

**S3. There is no composition root for a project session.** *(A × B × E)* Three reviewers independently recommended the same `ProjectSession` object:
- `ProjectWindow` holds five long-lived `claude` services, the stores and the services' lifecycle across `load()`, `onDisappear` and `CompilerRunModifier` (A).
- `DocumentStore.open` has side effects (presenter, registry declaration and admission, seal sweep, transcription), and `Document` doubles as a static service locator for identities and registry (109 references) (B).
- The Mac app's directories form one strongly connected dependency component (E).

**VERIFIED symptom:** `ProjectStatisticsWindow.load` (`Maugham/Views/ProjectStatisticsWindow.swift:72-80`) calls `DocumentStore.open` a second time and holds it only through `ProjectStore.documentStore`, which is `weak` (`Maugham/Stores/ProjectStore.swift:182`). The store is released at once, so `reloadSessionLog`'s guard always fails. Opening Statistics also performs registry acts. A presenter leak is inferred, not measured.

**S4. Format and kind are not first-class types.** *(A × B × C)* All three found the same scatter:
- The Markdown/Fountain decision is a string match on the extension in about 14 files, plus six local two-case enums (one on the phone, against tripwire 19).
- `ProjectType` mixes three axes: format, structure and genre. It is tested by `==` at 31 defaulted sites, 11 of them in ProjectWindow.
- A new kind or dialect silently becomes "novel" or "prose".

This is the first foundation non-fiction needs.

**S5. The four agent orchestrators are copy-paste over one transport protocol.** *(B × C)*
- `ensureRunner`, `retireSession`, `shutdown`, `detach` and `RunState` are copied three times.
- The teardown census counts by name, so a fifth role missing from every site passes, and the cost of that miss is a live billing process.
- A fact-checker or style-guide department would cost 2–3k source lines today.

**S6. Non-fiction is a widening job. Corporate is a product decision first.** *(C)*
- Block structure lives only in text, so footnotes, citations, tables and figures cost the op log, sync, signing, permits and translation alignment nothing. The cost lands in the parser, the publish AST and the emitters, which are the cleanest, most exhaustive code in the tree.
- The real blockers are ADR 0022 (manuscripts deliberately admit no tables, footnotes or reference links) and a publish AST that flattens the binder and degrades tables and images to text.
- Corporate collaboration hits identity-level "Not for" clauses in the constitution (*Teams*, :26; *Mac-native by conviction*, :27), the import corollary (:96), and unsigned structure (approvals would be a manifest field anyone can rewrite; `Permit.swift:429-435`).

## 3. Findings

### Guardrails (S1)
- **G1 [High] File-scoped censuses pass vacuously when their file moves.** VERIFIED (`TripwireGrepTests.swift:62`, `:9462`). Also affected: `:331`, `:4240`, `:6344`, and the `ProjectStore+*` mover census at `:199-211`.
  - Fix-shape: every scoped census asserts that its scope exists and is non-empty, then re-scopes by owning type or by marker comment.
  - Effort: S.
- **G2 [High] No single production-root definition.** A new package silently escapes most censuses.
  - Fix-shape: one `SourceTree.roots` (Maugham, MaughamPhone, every `Packages/*/Sources`), plus a check that every non-test `.swift` file is covered by a root.
  - Effort: M.
- **G3 [High] About 100 path-pinned source reads of `ProjectWindow.swift`** in 34 test files; 90 test files pin 231 production files by name.
  - Fix-shape: a shared `SourceTree.declaration(named:under:)`, with tests migrated to symbols.
  - Effort: M.
- **G4 [Medium] Source-text censuses are hosted in the app's test bundle.** They import only XCTest, yet need a full app build and 7 hosted processes.
  - Fix-shape: a standalone SwiftPM census package (precedent: `register/ExperimentTests`) and a `test.sh census` mode.
  - Effort: S–M.
- **G5 [Medium] `test.sh` has no targeted mode and no stale-project guard,** so agents bypass the lock with raw `xcodebuild -only-testing`, and a new test file runs 0 times without `./gen.sh`.
  - Fix-shape: `test.sh only <Class…>` under the lock, and regenerate when `project.yml` or the file set is newer than the project.
  - Effort: S.
- **G6 [Medium] Test fixtures are copied per file:** 73 `makeProject` builders, about 30 source readers, 5 `SpyRunner`s, and 18 hand-rolled AX walks beside `AXReading`.
  - Fix-shape: a `TestSupport` fixture layer with an index.
  - Effort: M.

### Agent docs (S2)
- **D1 [High] CLAUDE.md is 23k words and doubles each month.** About 48% of it is the per-area table, which repeats 78–96% of each AREA's identifiers.
  - Fix-shape: a kernel of at most ~4k words (rules, build commands, workflow, one line per area, one line per tripwire naming its test); move troubleshooting to `docs/testing/TROUBLESHOOTING.md`.
  - Effort: M.
- **D2 [High] The required AREA reads are unaffordable.** Canvas is 48k words, with single lines of 15k characters.
  - Fix-shape: a template per AREA (Map / Rules / Recipes / Pointers), history moved to `docs/history/<area>.md`, at most 8k words each.
  - Effort: L, about M per area.
- **D3 [High] MaughamCore (278 files, about 40% of source) has no AREA.md.** The "read the AREA for your directory" rule never fires there. 42 of the files OpLog AREA documents live in Core.
  - Fix-shape: AREA files per Core subsystem, plus a glob → AREA table.
  - Effort: M.
- **D4 [Medium] 10 of 19 sampled doc claims are stale.** Examples: `BuildVariant.swift`'s path, test counts, "most recent audits" pointing at May, OpLog Layout paths, OpLog AREA's "don't refactor structurally" banner (which now argues against three audits), register coverage.
  - Fix-shape: fix them, plus a path-resolution census in DocSyncTests.
  - Effort: S.
- **D5 [Medium] No doc budget, so trims don't hold.** CLAUDE.md was cut 4.7k → 2.4k words in June and regrew tenfold.
  - Fix-shape: word, line-length and milestone-tag budgets in DocSyncTests.
  - Effort: S.
- **D6 [Medium] Tripwire numbers collide across lists.** There are 822 unnamespaced code citations; e.g. `ReviewRenderViews.swift:283` says NSPopover is "tripwire 7", but in CLAUDE.md that is tripwire 5.
  - Fix-shape: global IDs plus a resolving census.
  - Effort: M.
- **D7 [Medium] No recipes for extension points.** Adding a `Statement.Kind` touches about 13 files, documented as narrative across four AREAs, with non-exhaustive `if case` sites.
  - Fix-shape: recipes of at most 300 words, plus exhaustive switches.
  - Effort: M.
- **D8 [Low] Hygiene.**
  - 2.1 GB of merged-branch worktrees under `.claude/worktrees`, and 1.5 GB under `.superpowers/sdd`, both full of AREA copies that `find`/`grep` return.
  - 29 tracked files in `.superpowers/brainstorm` despite the ignore rule.
  - `AGENTS.md` is an untracked hand copy of CLAUDE.md that has already drifted.
  - ADR 0032 is 35k words against the README's two-page rule.
  - Effort: S.

### Structure (S2–S5)
- **A1 [High] `ProjectWindow` is one struct of 4,233 lines with 62 `@State`.**
  - Fix-shape: child views and models rather than extension files:
    - `CentreColumn` + `CentreRoute` enum + `PublishCentreModel`;
    - `RightColumn`;
    - `ProjectSession` for the services;
    - about 1,700 lines of free-standing types moved out with zero state change.
  - Effort: L.
- **A2 [High] `DetailPaneToggle` is a 32-input funnel,** with 13 production-unreachable `if let ds … else` arms.
  - Fix-shape: an injected `ProjectSession` with a non-optional store.
  - Effort: M.
- **B1 [High] Trust invalidation is a hand-written fan-out** (`DocumentStore.swift:1820-1856`), with 34 independent `TrustResolution.resolve*` sites and a trust cache per `OpLogStore` instance.
  - Fix-shape: `ProjectTrust` in Core (table + epoch + subscribers), keeping a synchronous path for `Document.load`.
  - Effort: L.
- **B2 [High] `OpLogStore` holds 7 concerns in 3,180 lines,** with two-thirds of its functions `nonisolated static`, so the split is cheaper than it looks.
  - Fix-shape: the target types `OpLogFiles`, `OpLogClassifier`, `StreamPositions`, `StreamCensus`, `LocalWritePermitBuilder`, `OpLogWriter`, `SegmentSealer`. Update the census allow-lists for tripwires 39, 45, 46, 49 and 50, and PersonKeyCensus, in the same commits.
  - Effort: L.
- **B3 [High] There is no project-session composition root.** VERIFIED symptom: the Statistics window's double `DocumentStore.open`.
  - Fix-shape: `ProjectSession` (ref-counted per URL) owning ProjectStore, DocumentStore, a `ManifestStore` (one raise-only write door, ending the legacy `saveManifest` path), identities and `ProjectTrust`; split `open` into observe and attach.
  - Effort: M–L.
- **B4 [Medium] The four orchestrators are copy-paste** (S5).
  - Fix-shape: `AgentSessionHolder` + `AgentRoster` + a population census.
  - Effort: S–M.
- **B5 [Medium] Store "extension splits" are one type across files.** State is widened to `internal var _x`, and `admit` re-spells `settle`.
  - Fix-shape: owned collaborators on the `PostureBook` template (`RegistryVerbs`, `ClosedHeldLinesBook`, `ProjectTaskStream`, `StatementDocumentRegistry`).
  - Effort: M each.
- **B6 [Medium] Manifest state is split across two stores, joined by weak back-references;** there are about 13 decode sites.
  - Fix-shape: `ManifestStore` (inside B3).
  - Effort: M.
- **A3 [Medium] Four surfaces run annotation dispositions with different error policies;** the `try?` sites swallow `Document.PostureRefusal`.
  - Fix-shape: one `AnnotationDispositionPerformer` with a typed outcome.
  - Effort: M.
- **A4 [Medium] Controllers sit in hosts.**
  - `ProjectSettingsSheet` holds 12 People & Devices `@State`.
  - `HistoryPane` (24 `@State`, grew 1,647 → 2,274) mixes the op timeline, notices and the trust log.
  - Fix-shape: `PeopleAndDevicesHost`, `ProjectTrustLogSection`.
  - Effort: M.
- **E1 [High] The Mac app is one strongly connected dependency component.** OpLog → Editor/Stores/MCP; Stores → Views/Compiler; Compiler → Views; Models → Stores/Compiler.
  - Fix-shape: cut the back-edges (move the pure models out of Views, `ProjectIdentifier`/`TranslationWritePipeline` out of MCP, `Document`'s own error type), then add a layering census. Publish is the cheapest first package (its outbound coupling is thin).
  - Effort: M, then M–L.
- **X1 [Medium] Comment share is 45% overall and 50–67% in the monoliths,** much of it dated history.
  - Fix-shape: contract-only doc comments, with history moved to the ADR or note the comment already cites. Do it per file inside each split plan, never as a standalone sweep.
  - Effort: M.

### Extensibility (S4–S6)
- **C1 [High] No `DocumentFormat` type** (S4).
  - Fix-shape: a Core `DocumentFormat` that decides parser, AST mode, held-blank rule, extension and help resource. Retire the six local enums and census the `"fountain"` literal.
  - Effort: S–M.
- **C2 [High] `ProjectType` mixes structure × format × genre.**
  - Fix-shape:
    - (A) exhaustive capability predicates in Core, plus a census banning `manifest.type ==` in Views;
    - (B) an optional, additive `profile` on the manifest (no schema bump under ADR 0015) that chooses presets and the grammar ledger.
  - Effort: M + S.
- **C3 [High] The publish AST flattens the binder and degrades tables and images to text;** it has no link node.
  - Fix-shape: a hierarchical AST (divisions with depth, numbering config) plus `.table`, `.figure`, `.link`, footnote and citation nodes; `ElementCensus` forces the emitter arms.
  - Effort: M.
- **C4 [High] ADR 0022 keeps tables, footnotes and reference links out of manuscripts by decision.**
  - Fix-shape: a new ADR that scopes the ledger by profile.
  - Effort: S, once Denver rules.
- **C5 [Medium] Format dispatch is copied three times** (`CompileOrchestrator.swift:717`, `Republisher.swift:377`, `PreviewCompiler.swift:317`), with a TeX diagnostic type (64 references) threaded through Publish.
  - Fix-shape: an `OutputRenderer` protocol and a neutral `RenderDiagnostic`.
  - Effort: M.
- **C6 [Medium] `PublishConfig.Format` decodes an unknown value to `.pdf`** (`PublishConfig.swift:144-147`), so a newer build's `docx` silently becomes a second PDF on an older one.
  - Fix-shape: `.unknown(String)` with a named refusal.
  - Effort: S.
- **C7 [Medium] `Op.Provenance` is a flat bag of about 31 optional fields;** every new object type widens every op.
  - Fix-shape: a kind-discriminated payload with an `.unknown` passthrough, before any footnote, citation or figure op kind.
  - Effort: L.
- **C8 [Medium] Inline anchor families cost about 24 files each** (task anchors are the precedent).
  - Fix-shape: a Core `InlineMarker` registry, with tasks moved onto it first.
  - Effort: M–L.
- **C9 [Medium] Annotations have no reply thread,** and a suggestion covers one paragraph.
  - Fix-shape: an `annotation_reply` op and multi-paragraph suggestions (schema bump).
  - Effort: M. Only if corporate is admitted.
- **C10 [Low] `effectiveReviewPasses` falls back to fiction presets for every project type.**
  - Fix-shape: choose presets by profile (with C2).
  - Effort: S.

## 4. Binary triage

Every finding is either **scheduled** into one of the plans below or **dropped** with its reason. Plans are capped at about 10 tasks (workflow rule 12). Plans 1–3 are the foundations; 4–6 are the extensibility groundwork; 7 waits on Denver.

| Plan | Contents | Findings |
|---|---|---|
| **1. Docs diet** (no code risk) | CLAUDE.md kernel; doc budgets + path census in DocSyncTests; Core AREA + glob table; fix the 10 stale claims; hygiene (worktrees, sdd scratch, brainstorm, AGENTS.md generated) | D1, D3, D4, D5, D8 |
| **2. Guardrails that survive a move** | `SourceTree` scanner (roots, repo-relative keys, scope-exists assertion); re-key file-pinned censuses to symbols or markers; migrate the ProjectWindow path reads; census package + `test.sh census` / `only` / stale-project guard | G1–G5 |
| **3. Project session** | `ProjectSession` (services, stores, `ManifestStore`, identities) fixing the Statistics window; `AgentSessionHolder` + roster | B3, B6, B4, A2 (half) |
| **4. ProjectWindow split** | Free-standing types out; `CentreColumn`/`CentreRoute`/`PublishCentreModel`; `RightColumn`; comment-to-contract per file | A1, A2, X1 (per file) |
| **5. OpLogStore split** | Seven Core types behind a façade; one walk helper; counted tripwire-39 allow-list; AREA banner rewritten | B2, X1 (per file) |
| **6. Format and kind** | `DocumentFormat`; `ProjectType` capability predicates + census; `PublishConfig.Format.unknown` | C1, C2(A), C6 |
| **7. Later, after Denver's rulings** | `ProjectTrust`; store collaborators; disposition performer; host extractions; hierarchical AST + `OutputRenderer`; cycle cuts → Publish package; Provenance payload; `InlineMarker`; profile; AREA re-templates (D2) and tripwire IDs (D6) and recipes (D7) | B1, B5, A3, A4, C3, C5, E1, C7, C8, C2(B), C10, D2, D6, D7, G6 |

**Dropped on merit:**
- *The extension-file split of ProjectWindow and CompilerOrchestrator proposed by the last four audits.* A shared `@State` bag means it shortens files without shrinking what an agent loads (A). Replaced by Plan 4.
- *CanvasView and CanvasRenderer as structural monoliths.* 548 and 598 lines of code with good collaborators; their size is comments (A). Covered by X1 only.
- *RegistryAdmission split.* Already a stateless enum of verbs, 40% code (B).
- *C9 threads and multi-paragraph suggestions, and signed structure for approvals.* They exist only for corporate collaboration, which the constitution currently excludes. Revisit only if Denver's rulings admit it.

**Needs Denver** (product rulings before Plan 7's extensibility half):
1. Do *Not for: Teams* (constitution.md:26) and *Mac-native by conviction* (:27) stand?
2. Does the import corollary (:96) cover the writer's own DOCX draft?
3. Should ADR 0022's manuscript grammar become profile-scoped (non-fiction admits footnotes, citations, tables and figures)?
4. Should a fact-check department be allowed network tools, which would be a first exception to ADR 0028's confinement?

## 5. Refuted / verified-clean (do not re-chase)
- *The op log needs changing for footnotes, citations, tables or figures.* REFUTED: block structure lives in paragraph text; the cost is parser, AST and emitters (C).
- *RegistryAdmission, OpLogChain and PeopleAndDevicesModel are structural problems.* REFUTED: pure, well-shaped types whose size is commentary (A, B).
- *Splitting files into extensions reduces agent context.* REFUTED for SwiftUI views over shared `@State` and `@Observable` stores whose storage must sit in the main file (A, B).
- *The Apple dependency is in the sync model.* REFUTED: per-device partitioned files work on any folder-sync service (ADR 0012). The coupling is identity (Secure Enclave, iCloud Keychain), the share sheet, and phone downloads (C).

## 6. Process notes
- Reviewer A's and E's census counts differ (about 100 path reads vs 34 files and 231 pinned files). Both are right: one counts reads, the other files.
- Three reviewers converged on `ProjectSession` and on `DocumentFormat` without seeing each other's maps; that convergence is the strongest signal in this audit.
- The maugham-issues session was running gates during the audit. All reviewers were read-only and ran no builds.
