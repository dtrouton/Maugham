# Inline Emphasis Contract — Combinable Bold/Italic Across All Surfaces

**Date:** 2026-06-03
**Status:** Design approved, pending spec review
**Supersedes/extends:** [cross-surface-contracts](2026-06-03-cross-surface-contracts-design.md) (adds the asterisk-emphasis grammar to the contract registry)

## Problem

`***bold italic***` does not render as bold+italic everywhere, and *nested* emphasis
(`*a **b** a*`) renders inconsistently. The root cause is that the **Markdown
inline-emphasis grammar is implemented twice and has drifted**, while the Fountain
grammar is unified but incomplete for combined traits.

### Current state (the 2×2: grammar × role)

|  | **Editor** (AppKit, live, markers visible-but-faded) | **Reader** (SwiftUI, read-only) |
|---|---|---|
| **Markdown** | Mac prose → `MarkdownTokenizer` (hand-rolled) | Phone reader → Apple `AttributedString(markdown:)` |
| **Fountain** | Mac screenplay → shared `FountainTokenizer` | Phone reader → shared `FountainTokenizer` |

Behavior of `***word***` today:

| Surface | Result | Why |
|---|---|---|
| Phone markdown reader | ✅ bold+italic | Apple parser models emphasis as an `InlinePresentationIntent` **OptionSet** |
| Mac prose editor | ❌ bold + stray `*` | `Token.Kind.emphasis(strong: Bool)` is mutually exclusive; bold regex eats inner `**` |
| Mac screenplay editor | ❌ bold + stray `*` | shared `FountainTokenizer` emits only a bold span; italic regex refuses `*`-adjacent-`*` |
| Phone Fountain reader | ❌ bold + stray `*` | same shared tokenizer |

Behavior of nested `*a **b** a*` today (`b` should be bold+italic):

| Surface | Result |
|---|---|
| Phone markdown reader | ✅ `b` bold+italic (CommonMark nests) |
| Mac screenplay + Phone Fountain | ✅ `b` bold+italic (overlapping spans; renderers compose) |
| Mac prose editor | ❌ `b` italic only (tokenizer **defers** nesting AND `ProseMode` builds fonts from `baseFont`, so it would **clobber** even if it nested) |

The Mac prose editor is the lone outlier on both cases — an **uncontracted divergence**
in the very registry (CLAUDE.md tripwire 19) that is supposed to forbid it.

### Two layers, failing at different places

1. **Renderer capability** — three of four renderers can already *represent* combined
   traits: `ScreenplayMode.applyTrait` inserts into the font's symbolic traits;
   `FountainSemanticRenderer.applyTrait` layers on the existing font; Apple's parser
   uses an OptionSet. Only Mac prose (`emphasis(strong: Bool)` + `baseFont`-derived
   fonts) cannot.
2. **Tokenizer production** — the bottleneck. The Fountain and Mac-markdown tokenizers
   never *emit* the combined/overlapping spans for `***`, and Mac-markdown explicitly
   defers nesting.

The fix lives almost entirely in tokenization plus a small type reshape.

## Goals

- `***x***` renders bold+italic on **all four** surfaces.
- Nested asterisk emphasis (`*a **b** a*`, `**a *b* a**`) renders identically on all four.
- The asterisk-emphasis grammar has a **single source of truth** that cannot silently drift.
- Editors keep their own tokenizers (ranges, faded markers, anchors, wiki-links, tasks) —
  only the *grammar* is shared/contracted.

## Non-goals (YAGNI)

- **Underscore emphasis** (`_x_`/`__x__`). Different grammar per surface: Markdown treats
  `_` as emphasis (CommonMark), Fountain treats `_` as **underline**. Same character,
  opposite meaning. Drawing the shared boundary at *asterisks only* keeps the contract
  clean. There is a latent underscore gap (Mac prose `MarkdownTokenizer` has no `_`
  pattern, so `_x_` is unstyled literal there, while the phone markdown reader italicizes
  it via Apple) — **noted as a separate follow-up ticket, not fixed here.**
- **Pathological/unbalanced markers** (`***x**`, `**x`, etc.). Render as literal. We do not
  chase full CommonMark edge-case compliance — only the well-defined nestings listed in Goals.
- **Underline.** A Fountain-only feature, applied via the `underlineStyle` attribute (a
  different axis from font traits), already composes with bold/italic on both Fountain
  surfaces. Stays as `FountainInlineSpan.Kind.underline`, entirely untouched.
- **The phone strip-vs-fade marker inconsistency** (markdown reader strips emphasis
  markers via Apple's parser; Fountain reader fades them). Out of scope by choice.

## Architecture

One asterisk-emphasis grammar in MaughamCore, two contract tiers:

```
                    ┌─────────────────────────────┐
                    │  MaughamCore                │
                    │  EmphasisTraits  (OptionSet)│  ← bold, italic
                    │  InlineEmphasisScanner      │  ← single source of truth:
                    │    -> EmphasisScan          │     *x* / **x** / ***x*** + nesting
                    │       { runs, markers }     │
                    └─────────────────────────────┘
                       │ calls            │ calls            (SHARED-IMPL tier)
        ┌──────────────┘                  └──────────────┐
   Mac MarkdownTokenizer            Fountain FountainTokenizer
   (prose editor)                   (Mac screenplay + phone reader)
        │                                  │
   ProseMode attrs              ScreenplayMode + FountainSemanticRenderer

   Phone markdown reader (Apple's AttributedString) ──── CONTRACTED-DIVERGENCE tier:
        already handles *** + nesting; a contract test asserts Apple's parser
        agrees with the scanner on the canonical cases.
```

This maps onto the three-tier model from the cross-surface-contracts milestone:
**shared-impl** where we own both sides (the two hand-rolled tokenizers), and
**contracted-divergence** where one side is a black box (Apple's parser).

### The flattened scanner model

The scanner flattens nesting **once, centrally**, rather than emitting overlapping spans
and relying on each renderer to compose them (a subtle, undocumented, load-bearing property
today). Output is non-overlapping content runs (each carrying cumulative traits) plus the
marker ranges to fade:

```swift
public struct EmphasisTraits: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold   = EmphasisTraits(rawValue: 1 << 0)
    public static let italic = EmphasisTraits(rawValue: 1 << 1)
}

public struct EmphasisScan: Sendable, Equatable {
    public struct Run: Sendable, Equatable {
        public let range: NSRange         // content only (markers excluded)
        public let traits: EmphasisTraits // CUMULATIVE traits active here
    }
    public let runs: [Run]                // non-overlapping, covers emphasized content
    public let markers: [NSRange]         // asterisk-marker ranges to fade/hide
}

public enum InlineEmphasisScanner {
    /// Parse asterisk emphasis in `text`. Stack-based (not regex) so proper
    /// nesting/flattening is correct. Unbalanced markers render as literal.
    public static func scan(_ text: NSString) -> EmphasisScan
}
```

Worked examples:

- `***x***` → runs `[("x", [.bold,.italic])]`, markers `[0..<3, 4..<7]`
- `*a **b** a*` → runs `[("a ", [.italic]), ("b", [.italic,.bold]), (" a", [.italic])]`,
  markers `[*, **, **, *]`
- `**a *b* a**` → runs `[("a ", [.bold]), ("b", [.bold,.italic]), (" a", [.bold])]`

Because runs are non-overlapping and pre-flattened, **no surface needs composition logic
or `markerLen` arithmetic.** Each consumer maps run→traits→font and marker→fade.

`★ Why flattened, not overlapping:` it makes the Mac prose editor (flat, non-overlapping
token model) correct *for free*, and it removes the reliance on "renderers happen to
compose overlapping font traits" — turning an emergent accident into a centralized,
tested guarantee.

## Type changes

- **New (MaughamCore):** `EmphasisTraits`, `EmphasisScan`, `InlineEmphasisScanner`.
- **`Token.Kind`** (Mac prose): `case emphasis(strong: Bool)` → `case emphasis(EmphasisTraits)`.
- **`FountainInlineSpan.Kind`** (MaughamCore): `.bold`/`.italic` → `.emphasis(EmphasisTraits)`;
  `.underline` and `.note` unchanged.

Both enums are switched exhaustively in their renderers, so the compiler forces every
surface to handle the new shape (the contracted-divergence guard working as intended).

## Per-surface changes

| Surface | Change |
|---|---|
| **MaughamCore** | Add `EmphasisTraits` + `EmphasisScan` + `InlineEmphasisScanner` (stack-based asterisk parser, flattening) |
| **Mac prose** (`MarkdownTokenizer`) | Replace the two `*`/`**` regex blocks with a call to the scanner; emit `.syntaxPunctuation` for each `markers` range and `.emphasis(traits)` for each `runs` range; `fillGapsWithPlain` for the rest |
| **Mac prose** (`ProseMode.attributes`) | `.emphasis(traits)` → build symbolic traits from the set (`.bold` and/or `.italic`); verify it does NOT reset to `baseFont` in a way that clobbers (it won't need to — runs already carry cumulative traits, so there is nothing to compose) |
| **Fountain tokenizer** (`FountainTokenizer.inlineSpans`) | Replace the bold + italic regex passes with scanner output mapped to `.emphasis(traits)` content spans + faded marker spans; notes + underline passes unchanged |
| **Mac screenplay** (`ScreenplayMode.applyInlineSpan`) | Replace `.bold`/`.italic` cases with one `.emphasis(traits)` case (insert both symbolic traits as the set dictates); drop emphasis `markerLen` math (markers come from the tokenizer); `.underline`/`.note` cases unchanged |
| **Phone Fountain** (`FountainSemanticRenderer`) | Same: one `.emphasis(traits)` case applying `base.bold()`/`.italic()` per the set; drop emphasis `markerLen`; underline/note unchanged |
| **Phone markdown** (`DocumentReaderView`) | **No behavior change.** Apple's parser already handles `***` + nesting. Pinned by a contract test only. |

Note: the Fountain tokenizer must surface marker ranges to the renderers. Since the
renderers currently derive markers from `span.range` + per-kind `markerLen`, emphasis
markers become explicit faded spans (e.g. a marker span kind, or reuse the existing
fade path keyed off the scanner's `markers`). Implementation detail for the plan;
underline/note keep their existing `markerLen`-1 logic.

## Tests

- **Grammar contract test** (the oracle): for `*x*`, `**x**`, `***x***`, `*a **b** a*`,
  `**a *b* a**`, assert `InlineEmphasisScanner.scan` and Apple's
  `AttributedString(markdown:, .inlineOnlyPreservingWhitespace)` agree on which traits
  land on which content. Pins the phone markdown reader to the shared grammar and catches
  future macOS parser drift.
- **Fountain inline emphasis test** (both `MaughamTests` + `MaughamPhoneTests`, mirroring
  `ScreenplayEmphasisContractTests`): `***word***` → run `[.bold,.italic]` with 3 markers
  faded each side; `*a **b** a*` → middle run `[.italic,.bold]`.
- **Prose tokenizer test:** `***word***` → `syntaxPunctuation(3)` + `emphasis([.bold,.italic])`
  + `syntaxPunctuation(3)`; `*a **b** a*` → three emphasis runs with cumulative traits.
- **`InlineEmphasisScanner` unit tests:** the worked examples above plus unbalanced inputs
  (`**x`, `***x**`) → literal, no runs.
- Registry note added to `docs/superpowers/notes/cross-surface-contracts.md` so tripwire 19
  points future work at this contract.

## Risks / watch-items

- **DerivedData stale-symbol link error** after the `Token.Kind` / `FountainInlineSpan.Kind`
  public-enum change — `xcodebuild ... clean` before the first merged test run (CLAUDE.md).
- Both schemes must be tested (MaughamCore change): `Maugham` and `MaughamPhone`.
- The stack-based parser is the only genuinely new algorithm — exhaustive unit tests + the
  Apple-parser oracle keep it honest.
- Do not regress underline/note (separate axes; their passes are untouched but live in the
  same `inlineSpans` method).

## Out-of-scope follow-ups (record, don't do)

1. Underscore emphasis on Mac prose (`_x_`/`__x__`) — latent gap vs the phone reader.
2. Phone markdown strip-vs-fade marker presentation inconsistency.
