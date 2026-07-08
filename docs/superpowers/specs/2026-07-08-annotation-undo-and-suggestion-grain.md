# Annotation undo + suggestion grain — spec

**Date:** 2026-07-08
**Origin:** user-reported bug batch against v0.16.0, root causes confirmed (crash log `Maugham-2026-07-08-184105.ips` + code trace).

## Bugs being fixed

| # | Symptom | Confirmed root cause |
|---|---|---|
| B1 | Suggestion anchored to part of a paragraph but `suggested_text` is the whole paragraph; accepting splices a full paragraph into the middle of itself | `add_suggested_change`'s description says `suggested_text` is "the proposed new paragraph" while also accepting a sub-paragraph `quote`; `SuggestionSplice.apply` replaces only the span; no grain cross-check anywhere |
| B2 | ⌘Z after accepting a suggestion does nothing | `acceptAnnotation` applies text via `displayText` → `applyExternalText` → `textView.string =`, registering nothing with NSUndoManager; no undo-manager code exists in the app |
| B3 | ⌘Z crashes the app (SIGSEGV in `_NSUndoStack popAndInvoke`) | Typing-built undo actions reference text-storage state; an external buffer replace (`applyExternalText`) invalidates them without clearing the stack; next ⌘Z pops a dangling action |
| B4 | Accepted comment "lost" after op-log rollback (rewind) | Rewind derives the manuscript from the log prefix (accepted text correctly reverts) but the `claudeAccept` op survives, so the annotation still derives `.accepted` — hidden by the default filter while its change no longer exists; orphan sweep only touches OPEN annotations on REMOVED paragraphs |

User decisions (2026-07-08): **real undo of accept** (not just crash fix); **fix contract + accept-time mismatch detection** (not whole-paragraph-only).

## Design

### D1 — Native undo stack invalidation (fixes B3)

Whenever `EditorCoordinator.applyExternalText` actually replaces the buffer (past the `textView.string != text` guard), call `textView.undoManager?.removeAllActions()` before setting `.string`. Any external replace makes the native typing-undo history unsound; dropping it is the only safe option. This is independent of D2 and must hold on every `applyExternalText` path (accept, cross-device merge, cloud-conflict), not just accepts.

### D2 — Real undo of accept (fixes B2)

New MaughamCore op kind: `claudeAcceptRevert = "claude_accept_revert"`.

- **Semantics:** the mirror image of `claudeAccept`'s "two effects, one op": carries `changes` with `prior` = post-accept paragraph text, `next` = pre-accept paragraph text, and `provenance.sourceAnnotationId` = the creation op id. On derive: applies to the manuscript (restores the pre-accept text) **and** returns the annotation's derived status to `.open`.
- `Deriver.appliesToManuscript`: `claudeAcceptRevert` applies. `AnnotationDeriver`: latest-lifecycle-op indexing treats it as a lifecycle op mapping to `.open` status (the annotation reappears in the default Open filter, not stale-marked unless span resolution says so).
- **Mac undo wiring:** when `Document.acceptAnnotation` applies a `suggestedChange`, register an undo action with the window's undo manager: undo → `Document.revertAccept(annotationId:)` (appends the `claudeAcceptRevert` op, applies the text in-memory, `recomputeDisplayText()`); redo → re-accept via the existing `acceptAnnotation` path. Registration happens at the UI layer (AnnotationsPane / ReviewCardActions caller side or a thin Document-adjacent helper) — **not** inside MaughamCore, which stays UndoManager-free for the phone.
- Ordering constraint: D1 clears the undo stack on `applyExternalText`. The accept's own external apply must not wipe the just-registered accept-undo action. Resolution: `applyExternalText` skips `removeAllActions` when the replace originates from a document-local mutation that itself registered undo — concretely, clear only stale *typing* actions before the buffer swap, then register the accept-undo *after* the swap (registration order is spec-level; the plan pins the mechanism, guarded by a regression test: accept → ⌘Z restores text and reopens annotation; type → accept → ⌘Z ×2 does not crash).
- Guards: `revertAccept` on an annotation whose current derived status ≠ `.accepted`, or whose paragraph id no longer exists, is a loud no-op (log + return; never crash). Undo actions are per-document; closing the document drops them naturally with the window's undo manager.
- Phone: no undo UI. The phone gains nothing and must not reimplement; it only needs to decode/derive the new op kind, which it gets from shared MaughamCore. Round-trip integration test required (Mac writes revert op → phone deriver shows annotation `.open`).

### D3 — Rewind reopens post-target accepts (fixes B4)

During `Document.restoreToOp`, after computing the target prefix: for every `claudeAccept` (and `claudeAcceptRevert`-less accept chains) op that lies **after** the rewind target and whose creation op lies **at or before** the target, append a `claudeAcceptRevert` op **without paragraph changes** (status-only reopen — the checkpointRestore already reverted the text; a second text-apply would fight it). Deriver rule: `claudeAcceptRevert` is unconditionally classified `appliesToManuscript == true`; the derive loop only folds `op.changes`, so the D3 empty-changes variant is inherently a manuscript no-op. No conditional classification needed.

- Annotations whose creation op is *also* after the rewind target derive from ops that still exist in the log (rewind is append-only); they keep their current lifecycle status — but their paragraph may have vanished. The existing orphan sweep already archives open annotations on removed paragraphs; extend the sweep result (`RewindRestoreResult`) to also report reopened annotation op ids so the UI can surface "N suggestions reopened".
- The rewind sweep must remain within the existing `SweepReason.rewind` / `SynthesisSource.rewind` typed seams (no new stringly values — tripwire 12; **do-not-remove** constraint from the clean-.md milestone respected: only *adding* a case).

### D4 — Suggestion grain contract + mismatch salvage (fixes B1)

1. **Contract fix** (`AddSuggestedChangeTool.description`): rewrite so the two modes are explicit and unambiguous:
   - no `quote` → `suggested_text` is the complete replacement paragraph;
   - with `quote` → `suggested_text` replaces **only** the quoted span; it must not repeat surrounding paragraph text.
2. **Accept-time mismatch detection** (in **MaughamCore**, shared by Mac `acceptAnnotation` and phone `AnnotationWriter` — tripwire 19): extend `SuggestionSplice` so that when a span is present and resolvable, it first checks whether `suggested_text` was actually authored at whole-paragraph grain. Deterministic heuristic (no fuzzy scoring):
   - Let `prefix` = paragraph text before the resolved span, `suffix` = text after it.
   - If (`prefix` is non-empty and `suggested_text.hasPrefix(prefix)`) **or** (`suffix` is non-empty and `suggested_text.hasSuffix(suffix)`), the replacement already contains the surrounding context → treat as whole-paragraph replacement (skip the splice, use `suggested_text` verbatim).
   - Whitespace-trimmed comparison; grapheme-safe.
   - **Length floors (deletion-safety):** a one-sided match counts only when that side is ≥ 12 trimmed chars; a both-sides match counts only when the combined trimmed context is ≥ 12 chars. Rationale (review finding, 2026-07-08): a false positive *deletes* the paragraph's surrounding text — strictly worse than the duplication bug being fixed — and short both-sides coincidences (prefix "She", suffix ".") are common in real prose. When the floor blocks salvage on a genuinely whole-grain short paragraph, the damage is bounded small duplication, the safer failure.
   - Otherwise splice into the span as today.
3. The `SuggestionDisplay` diff preview must use the same decision so what the user previews is exactly what accept applies (one shared function, two call sites — no drift).
4. Add-time behavior unchanged (existing `spanNotFound` validation stays); we do not reject on suspected mismatch at add time because the accept-time salvage makes the suggestion still usable.

## Non-goals

- No op-log schema migration (tripwire 11 / ADR 0015 pattern: additive enum case only; unknown-case decoding already handles old app versions).
- No general op-log-backed undo of typing (native NSTextView undo remains the typing undo; this milestone only adds accept-undo).
- No change to reject/archive lifecycle flows.
- No MCP mutation surface changes beyond the `add_suggested_change` description text.

## Test obligations

- Regression test per bug (B1–B4), per the smoke-finds-seam-bugs discipline:
  - B1: span suggestion whose `suggested_text` embeds the paragraph prefix/suffix → accept yields the whole-paragraph replacement, not a duplicated splice; a correctly-grained span suggestion still splices.
  - B2: accept → undo → paragraph text restored, annotation derived `.open`; redo → re-accepted.
  - B3: harness test — typing-built undo state, `applyExternalText`, then invoking undo does not fault and does not resurrect pre-replace text (stack cleared); plus accept-path ordering test (accept-undo survives the accept's own external apply).
  - B4: op log with create → accept → rewind-to-before-accept → annotation derives `.open`, text reverted, `RewindRestoreResult` reports the reopen.
- Cross-surface: phone deriver round-trip on a log containing `claudeAcceptRevert` (both with and without changes).
- Both schemes (`Maugham`, `MaughamPhone`) must pass; `TripwireGrepTests` / `TripwirePhoneGrepTest` unaffected or extended.
- Paragraph ids in tests crossing the `.md` ↔ op log boundary use `ParagraphID.mint()` or 4-char alphabet-restricted literals (tripwire 8).

## Touched-area constraints (read the AREA.md first)

- `Maugham/Editor/` — tripwires 2, 3, 6, 7 (no new observable state on EditorHost; no 4th `applyExternalText` caller; undo registration must not add heavy work in a binding setter).
- `Maugham/OpLog/` — cleanest area, no structural refactor; echo-guard and `_pendingSweep` patterns untouched.
- `Packages/MaughamCore` — Apple frameworks only; `SuggestionSplice` change is pure-function; new OpKind case is `public`.
