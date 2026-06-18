# Collaboration WF1 — Phase 2: "Review Your Own Draft" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. This plan touches the editor seam — the most fragile area; obey `Maugham/Editor/AREA.md` tripwires (2,3,5,6,7) and CLAUDE.md.

**Goal:** Let a writer flip a project into a local **Review posture** on their own Mac (no iCloud, no second account) and annotate their own manuscript like Claude does — select text → comment / query / suggest (scoped inline edit) — rendered in the crafted margin rail (leader lines, pencil marks, Qy?/stet), with the author disposing in the existing `AnnotationsPane`.

**Architecture:** Review posture is `@State` on `ProjectWindow` (sibling to `isNoChromeOn`), threaded *down* as a parameter to `EditorSurface` — never parallel observable state on `EditorHost` (tripwire 6), one-way flow only (tripwire 2). Read-only enforcement is a guard in `EditorCoordinator.textView(_:shouldChangeTextIn:)`. The selection toolbar and margin rail are custom `NSView`s positioned via `NSLayoutManager.boundingRect(forGlyphRange:in:)` + `textContainerInset.height` (the `ElementGutterView` pattern) — **never `NSPopover`** (tripwire 5). Annotation creation reuses the `Document.addAnnotation(…, span:, author:)` path (built in Phase 1) via a UI-facing wrapper, mirroring the checkbox-toggle handler. Provenance/marks consume the `Annotation.author`/`span`/`resolvedSpanRange` fields Phase 1 added.

**Tech Stack:** Swift, SwiftUI + AppKit, Mac target (`Maugham/`), MaughamCore (already has the engine). Tests: XCTest (`MaughamTests`). Build: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`. Run `./gen.sh` after adding any new file (xcodegen). After any `ProjectWindow.body` change, do a Release build before considering done (CLAUDE.md).

Spec: [`2026-06-17-wf1-human-reviewers-design.md`](../specs/2026-06-17-wf1-human-reviewers-design.md) (Components B, D, F, G — local-toggle subset; identity/transport A/H deferred to a later increment). Architecture map: this plan's tasks cite exact seams from the 2026-06-18 editor-architecture survey.

---

## A note on testing this phase

Much of this is AppKit interaction + drawing, which the codebase smoke-tests **manually** (CLAUDE.md). So: unit-test the *logic* (read-only predicate, posture state, annotation-creation-through-Document emitting the right op, the marks/provenance view-model data), and **manual-smoke** the *visual/interaction* surfaces. Each AppKit task names its manual-smoke check. The final task is the end-to-end smoke you (the user) run.

---

## Task 1 — SPIKE: prove the two novel editor-seam mechanisms

**Goal:** establish the real approach for (a) a floating selection toolbar that isn't `NSPopover`, and (b) read-only/annotate-only text. Throwaway-quality is fine; commit behind a scratch flag. The later tasks depend on the chosen approach.

**Files (scratch, may be refactored later):**
- Modify: `Maugham/Editor/EditorCoordinator.swift` (read-only guard + a selection-rect helper)
- Modify: `Maugham/Editor/EditorSurface.swift` (install a trivial overlay view)

- [ ] **Step 1: Read-only guard.** In `EditorCoordinator.textView(_:shouldChangeTextIn:replacementString:)` (~L637), add at the top: `if isAnnotateOnly { return false }` where `isAnnotateOnly` is a new `var isAnnotateOnly = false` on the coordinator (plain stored property for the spike). Build, run, set it true via a temporary hard-code, confirm typing is rejected but selection/scroll/copy still work. **Manual smoke:** type → nothing changes; select + ⌘C → copies.

- [ ] **Step 2: Selection→view-rect helper.** Add `func selectionViewRect(in textView: NSTextView) -> NSRect?` using `layoutManager.glyphRange(forCharacterRange: textView.selectedRange(), …)` → `boundingRect(forGlyphRange:in:)` → add `textView.textContainerInset.height` to `.origin.y` (mirror `scrollSelectionToVerticalCenter` at ~L988). Return nil for empty selection.

- [ ] **Step 3: Floating toolbar overlay (NOT NSPopover).** In `EditorSurface`, add a small `NSView` (3 `NSButton`s) as a subview of the scroll view's *superview* (so it floats above the text, unclipped). On `textViewDidChangeSelection`, if selection is non-empty, position it just above `selectionViewRect` (convert text-view coords → overlay-parent coords via `convert(_:to:)`); hide it on empty selection. Buttons just `print()`. **Manual smoke:** select text → toolbar appears above it; move selection → it follows; deselect → it hides; scroll → it hides or repositions (note which).

- [ ] **Step 4: Assess inline-editable-span feasibility.** Spend ≤30 min: can a single paragraph's selected range be made temporarily editable while the rest stays read-only (e.g. relax the `isAnnotateOnly` guard for a specific "suggesting range", capture the diff on commit)? Don't fully build it — write findings: chosen approach + risks. If it looks hard, recommend the explicit-replacement-field fallback (spec's Component D fallback) for the first cut.

- [ ] **Step 5: Report (no commit gate on the spike's polish).** Commit the scratch with `spike(review): prove selection toolbar overlay + annotate-only guard`. Report back: where the overlay view lives + how positioned, how the read-only guard is toggled, scroll behavior, and the inline-edit recommendation. **STOP and report — the controller will fold the findings into Tasks 2+ before continuing.**

---

## Task 2 — Review posture state + read-only membrane (wired, not scratch)

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift` — add `@State private var isReviewModeOn: Bool = false`, a `.maughamToggleReviewMode` notification receiver (mirror `isNoChromeOn` at L164–170, persist via `documentStore?.updateUIState`), and a menu/toolbar affordance + keyboard shortcut (propose ⌘⌥R).
- Modify: `Maugham/Editor/EditorSurface.swift` — accept `isReviewMode: Bool` as a param; pass into the coordinator.
- Modify: `Maugham/Editor/EditorCoordinator.swift` — promote the spike's `isAnnotateOnly` to be driven by `isReviewMode`; turn focus-dim/typewriter OFF when review is on (review posture per spec F).
- Modify: `Maugham/Views/EditorHost.swift` — thread `isReviewMode` through as a plain parameter (NOT `@State` on EditorHost — tripwire 6).
- Test: `MaughamTests/Editor/ReviewModeMembraneTests.swift`

- [ ] **Step 1: Failing test** — a unit test on the read-only predicate. Extract the decision into a tiny pure function `EditorEditPolicy.allowsTextMutation(isReviewMode: Bool) -> Bool` (new small file `Maugham/Editor/EditorEditPolicy.swift`) and test `allowsTextMutation(isReviewMode: true) == false` and `… false) == true`. (Keeps the membrane decision unit-testable without driving AppKit.)
```swift
func test_reviewMode_disallowsTextMutation() {
    XCTAssertFalse(EditorEditPolicy.allowsTextMutation(isReviewMode: true))
    XCTAssertTrue(EditorEditPolicy.allowsTextMutation(isReviewMode: false))
}
```
- [ ] **Step 2:** Run, confirm fail (no `EditorEditPolicy`).
- [ ] **Step 3:** Add `enum EditorEditPolicy { static func allowsTextMutation(isReviewMode: Bool) -> Bool { !isReviewMode } }`; in `shouldChangeTextIn`, `guard EditorEditPolicy.allowsTextMutation(isReviewMode: isReviewMode) else { return false }`. Wire the posture state + param threading + focus-off-in-review.
- [ ] **Step 4:** Run test (PASS) + build Mac scheme. **Manual smoke:** ⌘⌥R toggles review; in review, typing does nothing, focus-dim/typewriter are off; toggling back restores normal editing.
- [ ] **Step 5:** `./gen.sh` if you added `EditorEditPolicy.swift`. Commit `feat(review): review posture state + annotate-only membrane`.

**Membrane scope note:** also disable binder structural ops + ⌘S checkpoint while review is on — but for THIS local-toggle phase those are lower priority (you're reviewing your *own* project). Gate the editor text mutation now; add binder/⌘S gating as a follow-up step only if the smoke shows it matters. (Full membrane lands with the iCloud identity increment.)

---

## Task 3 — Create annotations from the UI (comment + query)

**Files:**
- Modify: `Maugham/OpLog/Document+Annotations.swift` — add a UI-facing wrapper `func addReviewerAnnotation(kind: AnnotationKind, paragraphId: String, span: SpanAnchor?, body: String) async throws -> String` that calls `addAnnotation(kind:paragraphId:body:span:author:)` stamping `author: AnnotationAuthor(sourceKind: .human, displayName: <local reviewer name>)`. Local reviewer name = `UserPreferences.collaboratorDisplayName` (add this pref; default e.g. the system full name `NSFullUserName()`).
- Modify: `Maugham/Editor/EditorSurface.swift` + `EditorCoordinator.swift` — wire the spike's toolbar buttons (Comment/Query) to: capture the span via `SpanAnchorResolver.capture(in: displayText, range: selectedGraphemeRange)`, resolve the paragraph id for the selection, then call the wrapper. Use `MarkdownDisplayFilter`-stripped display text as the capture surface (Phase 1 contract).
- Test: `MaughamTests/OpLog/ReviewerAnnotationCreationTests.swift`

- [ ] **Step 1: Failing test** — drive `Document.addReviewerAnnotation` directly (no AppKit): create a doc, bootstrap a paragraph, call the wrapper with a span, then `document.annotations(...)` and assert one annotation with `author?.sourceKind == .human`, `author?.displayName == <expected>`, `span?.quote == <quote>`. (Mirror existing Document annotation tests for setup — find them under `MaughamTests/`.)
- [ ] **Step 2:** Run, confirm fail (no `addReviewerAnnotation`).
- [ ] **Step 3:** Implement the wrapper + the pref. Wire the toolbar Comment/Query buttons (Suggest comes in Task 4). The selection→paragraphId mapping: the selected range falls within one rendered paragraph; map it to the `¶id` via the same path the editor uses for cursor→paragraph (see `Document.paragraphId(at:)` — confirm exact name). The span's grapheme range is the selection relative to that paragraph's display text.
- [ ] **Step 4:** Run test (PASS) + build. **Manual smoke:** review mode → select phrase → Comment → type in the slip (Task 5 renders the slip; for now a temporary text prompt is fine) → annotation appears in `AnnotationsPane` (⌘⌥A) attributed to your name.
- [ ] **Step 5:** `./gen.sh` if new files. Commit `feat(review): create human-authored comment/query annotations from the editor`.

---

## Task 4 — Suggested change via explicit replacement composer

**DECIDED by the Task-1 spike: use the explicit replacement-field composer, NOT scoped inline editing.** The spike found a live in-place edit flows binding→`setFullText`→op-log append→autosave before the reviewer commits, so reverting it without mutating the manuscript fights the source-of-truth invariant and the parallel-state tripwires (6/7). The composer keeps the text view fully read-only: original = the selected text, replacement = the composer value → `suggestedChange` annotation. Zero live mutation. (True scoped inline editing / full Suggesting mode is deferred to a later iteration.) The composer is a small `NSTextField`/SwiftUI field hung off the selection toolbar overlay, pre-filled with the selected text.

**Files:** `Maugham/Editor/EditorCoordinator.swift`, `EditorSurface.swift`; the suggested-change emit reuses `addReviewerAnnotation(kind: .suggestedChange, …)` plus the `suggestedText`.

- [ ] **Step 1:** (logic test) a pure helper `SuggestedEditDiff.make(original: String, edited: String) -> (body: String, suggestedText: String)?` returning nil when unchanged; test it. (Keeps the diff capture unit-testable.)
- [ ] **Step 2:** Run, fail.
- [ ] **Step 3:** Implement the helper + wire the toolbar "Suggest" button to the chosen mechanism: capture original span text → obtain edited text (inline-editable region OR fallback composer) → `SuggestedEditDiff.make` → `addReviewerAnnotation(kind: .suggestedChange, …, suggestedText:)`.
- [ ] **Step 4:** Test PASS + build. **Manual smoke:** select phrase → Suggest → change the words → the suggestion appears in the pane as prior→suggested, attributed to you.
- [ ] **Step 5:** `./gen.sh` if needed. Commit `feat(review): suggested-change authoring (scoped inline edit / fallback)`.

---

## Task 5 — The crafted review render: margin rail + leaders + marks

This is the visual heart (spec F). Mostly manual-smoke; unit-test only the data prep.

**Files:**
- Create: `Maugham/Editor/ReviewMarginRailView.swift` — a custom `NSView` installed in the right-side inset (mirror `ElementGutterView` install at `EditorSurface` makeNSView + frame update in `updateColumnInset`). Draws, per visible annotated line: the slip card (pencil-colour border + small-caps name + body), and a leader line from the span's view-rect to the card. Reuse `boundingRect(forGlyphRange:in:)` + `textContainerInset.height` geometry; bound work to the visible range (ElementGutterView pattern, tripwire 4 — cache per-annotation layout).
- Create: `Maugham/Editor/AnnotationMarkRenderer.swift` (or extend the typography path) — draws the inline marks: pencil **underline** for comments, **strike-and-caret** for suggested changes, the **Qy?** marker for queries; pencil colour per author; Claude on fixed terracotta. Operates over `document.annotations` whose `resolvedSpanRange` is non-nil, mapping display-coord ranges to glyph rects.
- Create: `Maugham/Editor/ReviewPalette.swift` — the capped muted pencil-colour palette + stable assignment by author id (Claude = fixed terracotta). Pure, unit-testable.
- Test: `MaughamTests/Editor/ReviewPaletteTests.swift`

- [ ] **Step 1: Failing test** for `ReviewPalette`: stable colour per collaborator id (same id → same colour across calls), Claude id → the fixed terracotta, palette capped (N distinct ids cycle within the muted set). 
- [ ] **Step 2:** Run, fail.
- [ ] **Step 3:** Implement `ReviewPalette`, the rail view, and the mark renderer. Marks render from cached derived annotation state; rail geometry recomputes on layout/scroll, not continuously (perf contract). Render only when `isReviewMode`.
- [ ] **Step 4:** Test PASS + build. **Manual smoke:** in review, existing annotations show as pencil underlines / strike-caret / Qy? in the text, with leader lines to margin slips coloured by author; Claude's are terracotta; it stays legible with several at once. Scroll → rail tracks lines.
- [ ] **Step 5:** `./gen.sh`. Commit `feat(review): margin rail, leader lines, pencil marks (Qy?), palette`.

---

## Task 6 — Pane provenance + stet-on-reject + filter-by-author

**Files:**
- Modify: `Maugham/Views/AnnotationsPane.swift` — show `annotation.author` (colour dot + name; Claude tint) in `AnnotationRow` (~L194); add a **filter-by-author** control; on **reject** of a suggested change, show the brief **"stet"** treatment (the struck text resolving with a dotted underline + tiny "stet"). Accept already applies to the re-found window via existing stale-confirm; confirm a stale suggestion still blocks accept (Phase 1 behavior).
- Test: `MaughamTests/Views/AnnotationProvenanceRowTests.swift` (view-model-level: the row's author label/colour derivation, and the filter predicate).

- [ ] **Step 1: Failing test** for the filter predicate + author-label derivation (pure functions; extract from the view if needed).
- [ ] **Step 2:** Run, fail.
- [ ] **Step 3:** Implement provenance display, filter-by-author, stet-on-reject.
- [ ] **Step 4:** Test PASS + build. **Manual smoke:** pane shows who authored each annotation (you vs Claude), filter-by-author works, rejecting a suggestion shows the "stet" flourish.
- [ ] **Step 5:** Commit `feat(review): pane provenance, filter-by-author, stet-on-reject`.

---

## Task 7 — Verification + the end-to-end smoke (USER)

- [ ] **Step 1:** Full Mac suite green: `xcodebuild … -scheme Maugham test CODE_SIGNING_ALLOWED=NO`.
- [ ] **Step 2:** Phone suite green (shared types unaffected, but confirm): `xcodebuild … -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test …`.
- [ ] **Step 3:** **Release build** (CLAUDE.md, after ProjectWindow.body changes): `xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO`.
- [ ] **Step 4:** Final independent code review of the whole phase (dispatch a reviewer; focus the editor-seam tasks against the AREA.md tripwires).
- [ ] **Step 5 — USER SMOKE:** open a project → ⌘⌥R into Review → select a phrase → Comment / Query / Suggest → see them bloom in the margin rail with leaders + pencil marks → ⌘⌥A pane shows them attributed to you → reject a suggestion (see "stet") → ⌘⌥R back → confirm normal editing restored and the manuscript text was never mutated by your review actions.

---

## Self-Review Notes

- **Spec coverage:** Component B (membrane) → Task 2; D (authoring) → Tasks 3–4; F (render) → Task 5; G (pane) → Task 6. Components A/H (iCloud identity/transport) + the phone read surface (I) are explicitly deferred to the next increment — this is the *local-toggle* subset, per the user's chosen scope.
- **Tripwire compliance:** posture state on ProjectWindow threaded down (not parallel EditorHost state — 6); one-way flow (2); no NSPopover (5 — custom overlay); cached per-line layout in the rail (4); no new `applyExternalText` caller (7); read-only via the existing `shouldChangeTextIn` hook.
- **Spike-gated:** Tasks 4–5's exact AppKit wiring depends on Task 1's findings; the controller updates those tasks' specifics after the spike reports. This is deliberate (the two mechanisms are novel for this codebase), not a placeholder.
- **Deferred:** full membrane (binder/⌘S gating) beyond editor text; underscore emphasis; full Suggesting mode; cross-paragraph manual reattach UI (the resolver primitive exists; the UI is a later polish). Logged, not silently dropped.
