# Screenplay Syntax Docs & Dual Dialogue — Design

**Date:** 2026-05-26
**Status:** Spec
**Predecessors:** milestone-3a / 3b / 3c (Fountain foundation, editing UX, screenplay parity)

## Summary

This milestone has two cleanly separable bundles:

**Bundle A (docs-only)** closes five gaps in the in-app Fountain syntax help (`Maugham/Resources/fountain-syntax.md`): title page, character extensions, inline emphasis, inline task anchors, and dual dialogue. Single-file edit, no Swift changes, no tests.

**Bundle B (feature)** ships dual-dialogue support in the screenplay editor and page-count model. The Fountain `^` syntax (trailing caret on a character cue) is parsed, the second block is rendered with deeper paragraph indents to visually offset it, the trailing `^` fades like other forced-syntax markers, and the page-count heuristic treats each dual pair as the height of the longer block (Final Draft semantics) rather than the sum.

The bundles can ship as one PR or two; docs land in their own commit so review is trivial.

## Background

Dual dialogue is currently listed in `fountain-syntax.md:206` under "Not supported (deliberately)":

> **Dual dialogue** (two speakers side-by-side via `^`) — rare in practice, complicates layout, and discourages clean drafting.

This stance is being reversed. The complication ("two speakers side-by-side") is true for **print-fidelity** rendering, but a simpler asymmetric-offset approach ships cleanly inside the existing single-`NSTextStorage` paragraph-indent model — without touching `NSLayoutManager` or `NSTextContainer`, which is the territory that killed Phase 3d (multi-file screenplay).

A code audit during brainstorming also surfaced four other shipped-but-undocumented features (title page, character extensions, inline emphasis, inline task anchors). Bundling them into the same milestone closes the help-doc completeness gap in one pass.

## Hard invariants honored

- **Plain text on disk.** Dual dialogue uses pure Fountain syntax (trailing `^`); the `.fountain` file remains readable by Highland, Slugline, FountainJS, and any other Fountain-aware tool.
- **Single-file screenplays.** Dual dialogue is intra-file. No multi-file changes.
- **Editor tripwire discipline.** No `NSTextStorage` subclassing, no multi-container layout, no flag-based bidirectional sync, no new caller of `EditorSurface.applyExternalText`.
- **No data migration.** Existing `.fountain` files now render `^` correctly without any conversion.

## Out of scope (explicit)

- True side-by-side column layout (multi-`NSTextContainer` / TextKit 2). Revisit when print/PDF export ships.
- Tab-cycle / keyboard affordance for toggling `^`. Writers type it themselves.
- Symmetric half-width columns (Approach B from brainstorm). Higher risk in the parser tripwire zone.
- Chains of three+ paired cues. Greedy two-at-a-time pairing is documented + tested.
- MCP `read_document` schema changes. No element-classification change is required.
- Backfill of `docs/superpowers/specs/2026-05-07-maugham-master-design.md`. Per CLAUDE.md, ADRs supersede the master spec.

## Architecture

### Tokenizer (Bundle B)

`Maugham/Editor/Fountain/FountainTokenizer.swift` and `FountainLine.swift`:

- Add `isDualSecond: Bool` field to `FountainLine`, defaulting to `false`. Same shape as the existing `isForced: Bool` flag. The public `init(...)` gets a defaulted `isDualSecond: Bool = false` parameter so the 9 existing call sites in `FountainTokenizer.swift` (and any tests that construct `FountainLine` directly) stay compilable without touching every site — only the cue-emit sites that should set `isDualSecond = true` are updated.
- In the line-by-line walk, when a candidate character cue is parsed (either via the all-caps detection at `FountainTokenizer.swift:275-285` or the forced-character path at line 249-258), check whether the trimmed line ends with `^` (optionally with trailing whitespace before the newline). If so, set `isDualSecond = true` on the emitted line.
- Propagation: track a `prevWasDualSecond` flag alongside the existing `prevElement` / `prevBlank` walk state. Every dialogue and parenthetical line that classifies as part of the current block (per the existing dialogue-detection rules at lines 286-300) inherits `isDualSecond = true` until a blank line closes the block.
- Marker recognition: extend `markerRanges(in:storage:)` (`ScreenplayMode.swift:496-615`) `.character` branch: when `isDualSecond && trimmed.hasSuffix("^")`, return the trailing `^` range (and any single space immediately before it) in the fade list. The existing fade-pass at `ScreenplayMode.swift:167-175` then applies `palette.syntaxPunctuation` color automatically.

**No new `ScreenplayElement` case.** Consumers that don't care about dual-pair semantics (scene navigator, MCP element classification, prose-side prose-vs-screenplay routing) stay untouched.

### Parser edge cases

- **`MARLOWE ^^`** (double caret, writer mistake): single trailing `^` is consumed as the marker; the second `^` remains part of the cue text. The line still classifies as character (`^` is non-letter, ignored by `isAllCapsCueCandidate` at line 306-315) and `isDualSecond = true`. Forgiving.
- **`^STEVE`** (leading caret): NOT recognized as the dual marker. The Fountain spec defines the marker as trailing only. The line may or may not classify as a character cue per the existing all-caps rule; either way `isDualSecond = false`.
- **`The cursor ^^ blinks.`** (caret in action text): no change. Dual-marker detection only runs on lines that have already classified as character cues.
- **Dangling dual-second** (a `^`-marked cue with no preceding cue, e.g., document opens with `STEVE ^`): parser sets `isDualSecond = true` and the renderer applies offset indents. No pair is formed for page-count purposes, so no adjustment is recorded. The parser stays permissive; pairing is a page-count concern.

### Renderer (Bundle B)

`Maugham/Editor/ScreenplayMode.swift`:

Extend `attributes(for:palette:baseFont:charWidth:typography:)` (`ScreenplayMode.swift:294-380`) with an `isDualSecond: Bool` parameter. Three element branches gain dual-second variants:

| Element | Normal (head ch / tail ch) | Dual-second (head / tail) |
|---|---|---|
| `.character` | 22 / 60 | 42 / 60 |
| `.dialogue` | 10 / 45 | 32 / 58 |
| `.parenthetical` | 15 / 35 | 37 / 53 |

The canonical screenplay page is 60 characters wide. Dual-second character has 18ch of name space, dialogue has 26ch wrap width, parenthetical has 16ch — tight but legible for most names.

In the token-walk inside `applyTypography` (`ScreenplayMode.swift:120-149`), look up the matching `FountainLine` from the already-parsed `script` (line 114) by token range to retrieve `isDualSecond`. This avoids polluting `Token.Kind.fountainElement` with a flag that prose mode doesn't need.

The `^` marker fade requires no new code — the data added by `markerRanges` flows through the existing third-pass fade (`ScreenplayMode.swift:167-175`).

### Page count (Bundle B)

`Maugham/Editor/Fountain/FountainScript.swift`:

`lineCount(for:)` (`FountainScript.swift:45-72`) stays line-local and unchanged.

Add two private helpers:

```swift
/// Groups consecutive character + dialogue/parenthetical lines into blocks,
/// preserving each block's isDualSecond flag (derived from its character cue).
private static func dialogueBlocks(
    in lines: [FountainLine]
) -> [(linesInBlock: [FountainLine], isDualSecond: Bool)]

/// Sum of lines saved by treating each (firstBlock, dualSecondBlock) pair
/// as max(first, second) instead of first+second. Walks blocks in order;
/// when block i+1 is isDualSecond, blocks i and i+1 form a pair.
/// Greedy two-at-a-time pairing; chain-of-three pairs (1,2), leaves 3 solo.
private static func dualPairAdjustment(lines: [FountainLine]) -> Int
```

Three call-site changes:

- `estimatedPageCount` (`FountainScript.swift:19-26`): `(rawTotal - adjustment) / linesPerPage`.
- `pageNumber(at:)` (`FountainScript.swift:31-41`): adjustment accumulated for any dual pair whose second block closed strictly before the target line.
- `sceneLength(startingAt:)` (`FountainScript.swift:87-105`): adjustment computed within the scene's line range only.

### Help-doc updates (Bundle A)

`Maugham/Resources/fountain-syntax.md`, single-file edit:

1. **New `## Title page` section** between "The basics" (ends ~line 25) and "## Elements" (line 26). Documents the recognized keys (Title, Credit, Author/Authors, Source, Notes, Draft date, Contact, Copyright), first-line-must-be-recognized-key gate, blank-line termination, and 3+ space / tab indented-continuation rule. Includes a `Contact:` multi-line example.
2. **Extension to existing `### Character` section** (lines 56-74): adds a paragraph + code block documenting `(V.O.)` / `(O.S.)` / `(CONT'D)` and the rule that extensions are pure convention (any all-caps-letters line with parenthesized non-letter content passes the cue detector).
3. **New `### Inline emphasis` section** under "## Elements", positioned after the existing "### Notes" subsection (after line 188), before "## Page count" (line 189). Documents `*italic*` / `**bold**` / `_underline_` with a brief three-example code block. Notes that markers fade to dim while inner text retains parent-element styling.
4. **New `### Inline task anchors` section** adjacent to inline emphasis. Documents `[[todo: text]]` and `[[done: text]]`, click-to-toggle behavior, the invisible `<!--t-XXXXXX-->` anchor that's appended on first save, and the round-trip safety through other Fountain tools.
5. **New `### Dual dialogue` section** under "## Elements", positioned after `### Parenthetical` (after line 97) and before `### Transition` (line 98) — matches the natural reading order of a writer learning dialogue mechanics. Documents the trailing `^` syntax, includes a code-block preview showing the asymmetric stacked rendering, notes the Final-Draft-semantic page count (height of the longer block), and explicitly caveats that print/PDF export *may* upgrade to true side-by-side in a future milestone.

**Removal from "Not supported (deliberately)" block** (lines 201-212):

- Delete the dual-dialogue line (line 206). It now ships.

**Two clarifying line edits to existing prose:**

- Line 5 ("Layout follows the Cole & Haag standard..."): append a brief mention that dual-dialogue blocks use deeper indents to mark the second speaker.
- Line 191 ("Page count..."): append a sentence noting dual pairs count as the height of the longer block, not the sum.

## Components & data flow

```
.fountain file on disk
        │
        ▼
FountainTokenizer.parse()        ── sets FountainLine.isDualSecond per line
        │
        ▼
FountainScript (lines + titlePage)
        │
        ├──▶ ScreenplayMode.applyTypography  ── paragraph indents per isDualSecond
        │           │
        │           └──▶ NSTextStorage attributes
        │
        ├──▶ FountainScript.estimatedPageCount   ── adjustment subtracts min(pair)
        ├──▶ FountainScript.pageNumber(at:)      ── adjustment for closed pairs
        └──▶ FountainScript.sceneLength(...)     ── adjustment within scene range
```

No new boundary, no new actor, no new persistence. Pure data-flow extension of the existing parser → renderer → metrics pipeline.

## Error handling

- **Parser:** permissive. Dangling dual-second cues, double carets, carets in action text — all handled without errors or warnings. The `.fountain` file is the writer's source; refusing to parse is never the answer.
- **Renderer:** total-wrap-width must remain positive (`tail > head`). The chosen dual-second indents satisfy this for the canonical 60ch container. Compile-time constants; not user-tunable.
- **Page count:** `max(0, rawTotal - adjustment)` clamp ensures the adjustment can never produce a negative page count even if the algorithm were ever to over-subtract. Defensive but cheap.

## Testing

### Tokenizer tests — `MaughamTests/FountainTokenizerTests.swift`

- `test_characterCue_trailingCaret_marksIsDualSecond`
- `test_dualSecond_propagatesToFollowingDialogueAndParenthetical`
- `test_dualSecond_doesNotPropagatePastBlankLine`
- `test_doubleCaret_treatedAsSingleMarker`
- `test_leadingCaret_notRecognizedAsDualMarker`
- `test_forcedCharacter_withCaret_setsBothFlags`
- `test_danglingDualSecond_noPriorCue_stillFlagsCue`
- `test_caretInActionLine_isNotDualMarker`

### Page-count tests

- `MaughamTests/FountainScriptPageCountTests.swift`:
  - `test_dualPair_countsAsMaxNotSum`
  - `test_multipleDualPairs_accumulate`
  - `test_soloDialogue_unchanged`
  - `test_danglingDualSecond_noAdjustment`
  - `test_chainOfThreeCues_greedyPairing` (cue, cue^, cue^ → pairs (1,2), leaves cue 3 solo)
- `MaughamTests/FountainScriptPageNumberTests.swift`:
  - `test_pageNumber_beforePair_unaffected`
  - `test_pageNumber_afterPair_appliesAdjustment`
- `MaughamTests/Fountain/FountainScriptSceneLengthTests.swift`:
  - `test_sceneLength_includesDualPairAdjustment`

### Rendering tests — `MaughamTests/Editor/ScreenplayMode*Tests.swift`

(If no test file exists for `attributes(for:isDualSecond:...)` yet, add `MaughamTests/Editor/ScreenplayModeDualDialogueTests.swift`.)

- `test_dualSecondCharacter_paragraphStyle_hasOffsetHead` (head=42ch)
- `test_dualSecondDialogue_paragraphStyle_hasNarrowerColumn` (head=32ch, tail=58ch)
- `test_dualSecondParenthetical_paragraphStyle_hasNarrowerColumn` (head=37ch, tail=53ch)
- `test_dualSecondCharacter_trailingCaretFadedToSyntaxPunctuation`
- `test_normalDialogue_afterDualPair_paragraphStyleUnchanged` (regression)

### Integration test — `MaughamTests/Editor/EditorIntegrationHarnessTests.swift`

- `test_typingCaretIntoCharacterCue_doesNotFireApplyExternalText` (binding-contract regression net per Editor AREA.md)

### Fixture — `MaughamTests/Fixtures/dual-dialogue.fountain`

Small fixture with three scenes: one solo, one with a dual pair, one with a chain-of-three. Used by page-count and rendering tests.

### Not tested

- Help-doc content. No test surface for markdown resources; the file is pure docs.
- True side-by-side layout. Out of scope.
- Print/PDF export interaction. No print/PDF export ships yet.

### Manual smoke test (added to release notes)

1. Launch → New screenplay project.
2. Type two character cues, second with trailing `^`, each with a dialogue line.
3. Confirm visual offset: second cue/dialogue sit visibly further right than first.
4. Confirm `^` renders faded (not bold black like cue text).
5. Check Inspector page count is sensible (not inflated by the second block).
6. ⌘Q, relaunch, reopen from Recents — still rendered correctly.

## Files touched

**Bundle A (docs):**

- `Maugham/Resources/fountain-syntax.md` — five new sections + "Not supported" edit + two prose touch-ups.

**Bundle B (feature):**

- `Maugham/Editor/Fountain/FountainLine.swift` — new `isDualSecond: Bool` field.
- `Maugham/Editor/Fountain/FountainTokenizer.swift` — detection + propagation in the line walk.
- `Maugham/Editor/ScreenplayMode.swift` — `attributes(...)` extension, token-walk lookup, `markerRanges` extension.
- `Maugham/Editor/Fountain/FountainScript.swift` — `dialogueBlocks` + `dualPairAdjustment` helpers + three call-site updates.
- `MaughamTests/FountainTokenizerTests.swift` — new test methods.
- `MaughamTests/FountainScriptPageCountTests.swift` — new test methods.
- `MaughamTests/FountainScriptPageNumberTests.swift` — new test methods.
- `MaughamTests/Fountain/FountainScriptSceneLengthTests.swift` — new test methods.
- `MaughamTests/Editor/ScreenplayModeDualDialogueTests.swift` — new file (or extend existing if present).
- `MaughamTests/Editor/EditorIntegrationHarnessTests.swift` — new test method.
- `MaughamTests/Fixtures/dual-dialogue.fountain` — new fixture.
- `project.yml` — only if new files require manifest updates; verify via `./gen.sh` after.

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| `attributes(...)` signature change breaks callers outside `ScreenplayMode` | Low | Method is private; signature change is contained. Verified by grep before plan execution. |
| Token-walk lookup-by-range adds visible latency on large scripts | Low | `script.lines` is a flat array; lookup is O(n) per token, but tokenization is already O(n). Net is O(n²) on tokens that are screenplay elements, but the constant factors are tiny (range-comparison only). Re-evaluate if visible. |
| Page-count adjustment introduces an off-by-one in `pageNumber(at:)` | Medium | Encoded in tests: `test_pageNumber_beforePair_unaffected` and `test_pageNumber_afterPair_appliesAdjustment`. Spec calls out "strictly before the target". |
| Help-doc edits break the existing markdown block parser (`SyntaxHelpSheet.swift:80-156`) | Low | The parser handles headings, code blocks, bullets, paragraphs. All new content uses those constructs. Manual smoke (open ⌘/ Fountain tab) catches rendering regressions. |
| Marker fade on `^` interacts with smart-typography substitution | Low | Smart typography is disabled in screenplay mode per `fountain-syntax.md:199`. No interaction. |
| Approach A asymmetric offset reads as "wrong" to experienced screenwriters | Medium | Documented in help doc explicitly, with the print/PDF caveat. If real complaints surface, revisit with Approach B or true columns. |

## Open questions

None. Brainstorm covered fidelity, page count, doc scope, audit gaps, and approach. Approach A locked.

## Next step

Hand off to `writing-plans` for an implementation plan with build-sequence, model-selection per task (haiku/sonnet/opus), and review checkpoints per the Maugham milestone cadence.
