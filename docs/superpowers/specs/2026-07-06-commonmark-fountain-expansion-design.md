# CommonMark + Fountain expansion — design

**Date:** 2026-07-06
**Input:** `docs/superpowers/notes/2026-07-06-commonmark-fountain-compliance-audit.md`
**Status:** approved design, pending implementation plan

## Motivation

The 2026-07-06 compliance audit cataloged every divergence from CommonMark
0.31.2 and Fountain 1.1. This milestone actions it: fix the real bugs, reopen
every previously-excluded spec feature and make a fresh call under an agreed
philosophy, and consolidate the parser duplication that caused the worst
findings. Two features were requested directly: **strikethrough in prose** and
**proper Fountain lyric support**.

## Inclusion philosophy (decided)

**Writer-first, per-surface.** Manuscripts get everything that serves creative
writing; programmer-ish constructs are supported only where their corpus needs
them (Help window, research notes). The manuscript grammar stays small and
intentional.

## Decision ledger

Every row below is a deliberate decision made 2026-07-06; the next audit
should treat these as intentional.

### CommonMark — IN

| Feature | Where | Notes |
|---|---|---|
| Strikethrough `~~x~~` | Editor, publish, phone reader | GFM syntax. Editor styles it; LaTeX emits strikeout (`ulem`/`soul` — verify package availability in bundled tectonic before choosing the macro); XHTML emits `<s>`; phone comes via swift-cmark natively. Prose only — not Fountain (no spec basis; `~` is lyric). |
| Backslash escapes (`\*`, `\~`, `\_`, `` \` ``, `\\`) | All inline parsers (prose + Fountain, editor + publish) | Escaped delimiter renders literal, backslash consumed. Resolves the audit's B1 inconsistency (today: italic in editor, literal in published screenplay). |
| Paragraph-scoped (multi-line) emphasis | Editor + publish prose | An emphasis span may open/close anywhere within one blank-line-delimited paragraph; never crosses a blank line. User hit the stanza case in practice. Fountain keeps line scope (elements are line-based; dialogue behavior unchanged). Inverts `testEmphasisDoesNotSpanLineBreak` into a stanza test + a no-crossing-blank-line guard. Perf-gated (see Risks). |
| List semantics | Publish | Ordered + unordered, basic nesting, tight rendering. Kills the silent-mangle path (list lines currently coalesce into one paragraph). |
| Fence mangle-guard | Publish | A ``` fence becomes a verbatim block (no inline parsing, no monospace pretension) instead of emphasis soup. Explicitly NOT full code-block support. |
| Hard line break, backslash form | Publish | Trivial once escapes exist. Two-space form already works. |
| Scene-break parity `---` / `***` / `###` | Editor | Publish already accepts all three; editor currently styles only `---`. Align editor styling to the same set. |
| Ordered lists + pipe tables | Help renderer (`GuideMarkdownView`) only | The shipped guide corpus already uses both (audit A3). |
| Blank-line paragraph grouping | Research preview | Audit A4: stop rendering each source line as its own block. |

### CommonMark — OUT (confirmed intentional)

| Feature | Rationale |
|---|---|
| Underscore emphasis `_x_` in prose | Asterisk-only stays (documented mental model; `_` belongs to Fountain underline). **Alignment fix:** prose publish currently italicizes `_x_` incl. intraword (`snake_case`); remove `_` handling from prose publish so it matches the editor. |
| Setext headings | `---` is the scene-break idiom; precedence conflict is permanent. Document. |
| Indented (4-space) code blocks | Footgun for writers who indent. Document. |
| Code blocks / tables in manuscripts + publish | Not writer content (philosophy). Fence guard above is a degradation fix, not support. |
| Link publishing, reference links, autolinks, link titles, inline images in manuscripts | Research owns images; links degrade visibly (acceptable). Editor keeps its existing inline-link styling. |
| Entities, multi-backtick code spans | Edge machinery, no writer payoff. |
| Punctuation-flanking + rule-of-3 emphasis | Whitespace flanking is correct for prose; unbalanced-runs-degrade-to-literal is a safe failure mode. Documented divergence from reference parsers. |

### Fountain — IN

| Feature | Notes |
|---|---|
| Publish via the real `FountainTokenizer` (audit A1) | Replaces `parseFountain`. Boneyard `/* */`, notes `[[ ]]`, synopses omitted from output; sections omitted (organizational, not printed); page breaks honored; forced `.` `@` `!` `>` handled; centered text centered. **Dual-dialogue side-by-side publishing comes free** — both emitters already exist, currently unreachable. Duplicate title-page parser deleted. |
| Lyrics `~` | Core already parses. This milestone: publish emits them (italic, own block — convention), Mac/phone styling made deliberate (italic), doc'd. |
| Scene numbers `#1A#` | Reopened: production drafts need them. Core parses + strips into `FountainLine` metadata; Mac/phone display subtly (faded, like syntax markers); publish right-aligns them on the slugline. |
| Dot-less scene stems (`INT ROOM - DAY`, `INT/EXT`, `I/E`, `EXT/INT` …) | Spec-valid stems accepted with dot OR space; blank-line gate keeps false positives low. |
| Two-space "held" blank line in dialogue | A line of exactly two spaces continues the dialogue block per spec. |
| Emphasis escaping `\*` `\_` in Fountain | Same escapes decision as prose, applied in the shared scanner. |

### Fountain — OUT (confirmed intentional)

| Feature | Rationale |
|---|---|
| Mid-line boneyard `/* … */` | Rare; span-level complexity; line-level boneyard covers the use case. Document. |
| `FADE OUT:` auto-detection | Spec auto-detects only `TO:` endings; `> FADE OUT.` forcing works. Fix the doc (audit C3). |
| MORE / (CONT'D) page-break wrapping, revision marks, FDX import/export | Production-pipeline features, out of scope for Maugham's publish. |
| Editor affordance for dual dialogue `^` | Typing `^` works; Tab-cycle stays 5 elements. |
| Side-by-side dual dialogue on editor/phone | Stacked display stays (contracted nil-rows); publish gets true columns via A1 fix. |

### Bundled fixes (no decision needed)

All remaining audit items: `***bold italic***` prose publish fix (A2 — falls
out of scanner adoption), editor image-tail styling (A5), all seven doc-drift
items (C1–C7), stale code comments (`ProjectASTBuilder` "bridges through",
`FountainTokenizer` post-pass, `MarkdownTokenizer` nested-emphasis header).

## Architecture (approach A: consolidation-first)

New features are implemented **once** in MaughamCore and flow to all surfaces:

- `InlineEmphasisScanner` becomes the single inline engine: gains backslash
  escapes, `~~` strikethrough (prose-gated via caller option), and
  paragraph scope for prose (line scope retained for Fountain callers).
- Publish `InlineParser` and `FountainInline` become thin adapters over the
  scanner. Wiki links, code spans, and hard breaks stay local to `InlineParser`
  (publish-only concerns). `FountainInline`'s existing escape handling is
  superseded by the scanner's.
- Publish `parseFountain` is replaced by a `FountainTokenizer` →
  `ProjectAST.FountainNode` mapper.
- The five display block-splitters are NOT unified in this milestone
  (approach C). **Decision point: review C as a follow-on milestone at the end
  of phase 6**, using the audit's cross-surface inconsistency table as its
  test corpus. Phase-5 renderer fixes are written as thin patches whose tests
  transfer to a future shared block parser.
- The editor tokenizer stays a separate styling layer (ranges over live text),
  consuming the shared scanner as today.

## Phases

1. **Substrate** — scanner: escapes, strikethrough, paragraph scope (prose) /
   line scope (Fountain). Publish inline parsers become scanner adapters
   (fixes `***` A2 and the `_` intraword divergence as by-products).
   Typing-perf harness gate at 120pp before merge.
2. **Publish Fountain rewrite** — tokenizer-backed mapper; leak class killed;
   lyrics/centered/forced/page-breaks correct; dual dialogue wired to the
   existing emitters; duplicate title-page parser deleted. EMISSION.md gains
   golden examples for every new behavior (boneyard omitted, note omitted,
   lyric, dual dialogue, scene number, `***both***`, strikethrough, escapes,
   lists, fence guard).
3. **Prose features through the surfaces** — strikethrough editor token +
   styling + LaTeX/XHTML emission + phone verification; publish lists + fence
   guard + backslash hard break; editor `***`/`###` scene-break styling.
4. **Fountain core expansion** — scene numbers, dot-less stems, two-space held
   blank line. `FountainTokenizerReference` (frozen differential oracle) is
   updated in lockstep as part of the phase — a deliberate oracle revision,
   with the diff reviewed, not a test-appeasing edit.
5. **Renderer fixes** — Help ordered lists + pipe tables; research preview
   paragraph grouping; editor image-tail fix.
6. **Docs + contracts sweep** — `markdown-syntax.md` / `fountain-syntax.md`
   rewritten to match reality (all seven drift items); guide corpus checked
   against the upgraded Help renderer; cross-surface-contracts registry gains
   rows for strikethrough + scene numbers + the publish pipeline (bringing
   publish inside the registry for the first time); new ADR records this
   ledger; stale comments fixed. **Then: A-vs-C review checkpoint.**

## Testing

- TDD per task; every ledger row that changes behavior gets a pinning test.
- Emission-contract golden examples for all new publish behavior (the audit
  showed the `***` bug survived precisely because no example existed).
- Round-trip Mac↔phone integration test for strikethrough (tripwire 19's
  "real safety net").
- Differential/fuzz suite re-run after oracle revision (phase 4).
- Typing-perf harness at 120pp gates phase 1 (paragraph-scope scanning touches
  the seam scarred in the typing-perf milestone).
- Release-configuration build before tag (standing rule; publish + views
  touched).
- Manual smoke (user): screenplay with scene numbers + dual dialogue + lyrics
  + boneyard/notes → publish PDF+EPUB and verify leaks gone; prose doc with
  stanza-spanning italic + strikethrough + a list → editor, phone, PDF, EPUB.

## Risks / pre-verifications

- **LaTeX strikethrough package**: verify `ulem` (or `soul`) ships in the
  bundled tectonic before choosing the macro; fallback is a raw
  `\rule`-based strikeout or preamble inclusion. Do this verification FIRST in
  phase 3 (it shapes the emitter).
- **Paragraph-scoped scanning perf**: bounded by paragraph length, not doc
  length; still gated by the harness because the tokenizer seam has regressed
  under "obviously cheap" changes before.
- **Oracle revision discipline**: phase 4 changes tokenizer classification on
  purpose; each oracle diff must be traceable to a ledger row.
- **Scanner API change ripples**: scanner callers exist in MaughamCore, Mac
  editor, and via `FountainTokenizer` on phone — clean DerivedData after the
  public-signature change (standing tripwire).

## Non-goals

- Approach C (unified display block parser) — reviewed at end of phase 6.
- Full CommonMark conformance; GFM beyond strikethrough (+ tables in Help).
- Fountain scene-number *editing* affordances beyond typing them.
- FDX, revision marks, MORE/CONT'D.
- Any manuscript file-format change (op log remains source of truth; all
  parsing changes are read/display/emit-side).
