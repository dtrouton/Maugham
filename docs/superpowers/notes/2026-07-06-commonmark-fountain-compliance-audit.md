# CommonMark + Fountain compliance audit — 2026-07-06

Purpose: catalog every place Maugham diverges from, or does not implement, the
CommonMark spec (0.31.2) and the Fountain spec (fountain.io, 1.1), so each
divergence can be confirmed intentional. Five parallel audit passes covered:
the core Fountain tokenizer, downstream Fountain surfaces (Mac editor, publish,
phone reader), the Markdown editor path, the Markdown publish pipeline, and the
Markdown display renderers. All file:line evidence was read from clean `main`
this session; the two most severe findings were independently re-verified by
hand-tracing the resolved source.

Framing: Maugham deliberately implements a **subset** of both specs. Most gaps
are intentional narrowing. The audit's job was to separate four buckets:
**(A) real bugs**, **(B) semantic divergences needing an intentional/not call**,
**(C) doc drift** (behavior fine, docs wrong), and **(D) documented-intentional**
(recorded here so nobody re-litigates them).

---

## A. Real bugs (output-affecting, apparently unintentional)

### A1. Publish runs a third, independent Fountain parser that leaks author-only content into PDFs/EPUBs — HIGHEST SEVERITY
`ProjectASTBuilder.parseFountain` (`Maugham/Publish/ProjectASTBuilder.swift:157`)
is a hand-rolled line classifier, NOT the shared `FountainTokenizer`. Its header
comment claims production "bridges through" the real parser (Task 31) — **no
bridge exists**; `ProjectStoreASTSource → build → buildSection → parseFountain`
is the production path, and `grep FountainTokenizer Maugham/Publish/` finds only
that stale comment.

Consequences (all verified against the classifier at
`ProjectASTBuilder.swift:157-340`):
- **Boneyard `/* … */` is published.** No handling; worse, `/* CUT */` is
  all-caps-no-period so `isCharacter` claims it as a character cue and swallows
  following lines as its dialogue. Omitted material appears in compiled output.
- **Notes `[[ … ]]` are published verbatim** as action text.
- **Synopses (`= …`) and sections (`# Act One`) are published** with markers
  intact (synopsis/section lines fall through to action).
- **Page break `===` prints as literal text** (`isSceneBreakLine` is only
  called on the prose path).
- **Lyrics `~`, forced action `!`, forced scene heading `.`, forced character
  `@`** — markers not stripped; `!ALL CAPS` mis-reads as a character cue;
  `@McClane` becomes action.
- **Centered text `>THE END<` becomes a spurious character cue**
  (`transitionText` rejects `…<`, then `isCharacter` claims it).
- **Dual dialogue is unreachable dead code**: `ProjectAST.FountainNode
  .dualDialogue` exists and BOTH emitters render side-by-side columns
  (`LaTeXBodyEmitter.swift:144`, `XHTMLBodyEmitter.swift:93`), but the parser
  never emits it — `NAME ^` publishes with the caret leaking.
- Classification ignores blank-line context (over-claims characters; `MRS.
  SMITH` is action because `isCharacter` rejects any `.`), and its scene-prefix
  set (`INT ` space-form accepted) differs from core (dot required).

Fix-shape: make the stale comment true — parse via `FountainTokenizer` and map
elements to `FountainNode`s (also unlocking dual dialogue). This is squarely
tripwire 19/20 territory: a downstream surface reimplementing what MaughamCore
owns.

### A2. Prose publish mangles `***bold italic***`
`InlineParser` (`Maugham/Publish/InlineParser.swift:62-83`) has `**` and `*`
branches but no `***` branch. Verified trace of `***x***`: the `**` branch
matches the first two of the three closing stars → `strong("*x")` + stray
literal `*` → `\textbf{*x}*` / `<strong>*x</strong>*`. This contradicts the
inline-emphasis-contract milestone's "unified across all 4 surfaces" claim:
**the publish `InlineParser` never adopted `InlineEmphasisScanner`.**
`FountainInline.swift:34-43` handles `***` correctly, so screenplay action is
fine but prose is broken. No test or `EmissionContract.proseExamples` entry
covers `***` — which is why the golden test never caught it. Fix + add a
`***both***` emission example to lock it.

### A3. In-app Help window mis-renders shipped guide content
`GuideMarkdownView` supports headings/bullets/fenced-code/blockquote-strip only
(`Maugham/Views/GuideMarkdownView.swift:9-65`), but the shipped corpus uses
more:
- `docs/guide/reference.md:9+` — the entire keyboard-shortcut **pipe table**
  renders as literal `| ⌘N | New project |` paragraphs.
- `docs/guide/claude-desktop.md:7-10` — **ordered-list steps** fall into the
  paragraph accumulator and reflow onto one line ("1. Install… 2. Open… 3. …").
Same files render correctly on GitHub and via `get_help` (Claude renders the
markdown), so the in-app HelpWindow is the outlier. Either teach the renderer
ordered lists + tables, or rewrite the guide to the renderer's subset.

### A4. Research preview fragments paragraphs
`ResearchNotePreviewPane.parse` (`Maugham/Views/ResearchNotePreviewPane.swift:41-81`)
makes **every non-empty source line its own paragraph block** (no blank-line
grouping, no reflow) — hard-wrapped prose renders as N stacked blocks with 8pt
gaps. Guide reflows correctly; the phone reader groups by blank lines. Likely a
bug, not a choice.

### A5. Incidental image-tail styling in the editor
The editor has no image support (intentional), but in `![alt](url)` the
`[alt](url)` tail still matches the inline-link regex, so the tail styles as a
link while `!` stays plain — contradicting `markdown-syntax.md:119` ("images
render as plain text"). Side effect of independent regex passes.

---

## B. Semantic divergences — confirm intentional or fix

### B1. Backslash escapes — inconsistent across surfaces (top confirm item)
No backslash-escape handling exists in `InlineEmphasisScanner`, the editor
tokenizer, or the prose `InlineParser` — `\*not emphasis\*` still styles/emits
as emphasis, and a writer **cannot** produce a literal asterisk in prose.
Meanwhile `FountainInline.swift:30` (publish, screenplay) DOES handle `\*` `\_`
`\\`. So `\*x\*` renders literal in a published screenplay but italic in the
editor. Both specs support escaping. Pick one behavior and align.

### B2. Emphasis engine simplifications (shared `InlineEmphasisScanner`)
- **Whitespace-only flanking** — CommonMark's punctuation-class flanking rules
  and rule-of-3 absent (documented out-of-scope in the scanner header).
- **Per-line scanning** — emphasis can't span a soft line break within a
  paragraph (spec allows it). Pinned by `testEmphasisDoesNotSpanLineBreak`.
- **Asterisk-only** — underscore emphasis deferred (documented; `_` is Fountain
  underline). But the prose publish `InlineParser` DOES treat `_x_` as emphasis
  with no intraword guard — `snake_case_word` italicizes in PDF/EPUB while the
  editor shows it plain. Publish/editor disagree; resolve with B4.
- Fountain core underline regex `_([^_\n]+)_` (`FountainTokenizer.swift:833`)
  is more permissive than spec flanking (`_ text _` matches); `FountainInline`
  additionally nests inside underline while core is flat.

### B3. Fountain core narrowing choices (`FountainTokenizer`)
- **Scene headings require the literal dot** — `INT ROOM - DAY` (spec-valid:
  stem + dot OR space) is action. Missing dot-less stems `INT/EXT`, `I/E`,
  `EXT./INT`, `EXT/INT`. (Publish's copy accepts `INT ` — another core↔publish
  mismatch.)
- **Two-space "held" blank line inside dialogue not implemented** — a `  ` line
  is blank (`isBlank`, line 159) and ends the dialogue block.
- **Mid-line boneyard not recognized** — `/*` must open at line start
  (line 316); `Action /* cut */ more` keeps `/* */` literally.
- **Character cue "followed by non-blank" not enforced** — deliberate for live
  editing per `test_allCapsLine_alone_classifiesAsCharacter`, but the code
  comment at line 575-584 references a post-pass that **does not exist**, and
  the shipped doc says the opposite (see C2).
- Auto scene-heading/transition don't check for a following blank line; forced
  `.` heading ignores the prev-blank gate. Minor.
- Title-page recognition gated on the **first** line's key being one of 9
  canonical keys; scene numbers `#1A#` unimplemented (documented).

### B4. Three-to-five-way parser duplication (the structural root cause)
- **Fountain parsers: 3** — `FountainTokenizer` (core), `parseFountain`
  (publish, A1), plus `ScreenplayLineMutator`'s private re-declared prefix set
  + predicates (`ScreenplayLineMutator.swift:177-192` — generation not parsing,
  but nothing pins its output to tokenizer classification).
- **Asterisk-emphasis grammars: 3** — `InlineEmphasisScanner` (core, the
  designated single source), `InlineParser` (prose publish), `FountainInline`
  (screenplay publish).
- **Markdown block splitters: 5** — phone `MarkdownBlocks`, `GuideMarkdownView`,
  `ResearchNotePreviewPane`, `SyntaxHelpSheet`, plus the editor's block regexes.
- The publish pipeline sits entirely **outside** the cross-surface-contract
  registry; Mac↔phone are contracted and consistent, publish is where the gaps
  concentrate. Candidates for registry rows or MaughamCore consolidation
  (a shared block-splitter would collapse most of section E's inconsistencies).

### B5. Editor block-level divergences (styling layer)
- `---` under text always styles as thematic break — **setext H2 precedence
  inverted** (setext unimplemented everywhere).
- Thematic break: only `-`-form, exactly-at-column-0; `***`/`___`/spaced forms
  unrecognized.
- ATX headings: no up-to-3-space indent tolerance (publish is the opposite —
  over-tolerant, treats 4+-space-indented `#` as heading); closing `##`
  sequence not stripped (editor + publish + phone all keep it as text).
- Blockquote `>` requires a following space (spec doesn't); one level only.
- Ordered-list `)` delimiter unsupported.
- Code spans single-backtick only (no N-backtick runs) on every surface.
- Entities (`&amp;`) never decoded; publish re-escapes them (→ `&amp;amp;`
  in XHTML). Fine for a writing tool, but it's a divergence.

### B6. Publish prose block gaps that mangle silently (vs degrade visibly)
Visible-literal degradation (links, images, autolinks, raw HTML — acceptable)
vs **silent mangling** (the risk class): fenced code blocks, indented code
blocks, and lists all flow into paragraphs with stray markers re-interpreted
(backticks become spurious code spans, `* item` can trigger emphasis, list
lines coalesce into one paragraph). None of these are in EMISSION.md's
negative-space list. Decide: implement, or document as negative space.
- Also: scene-break detection accepts only exactly-3 `***`/`###`/`---`
  (spaces removed) — `----` or `_____` mangles inline instead.
- Blockquote lazy continuation absent (every line needs `>`); nesting works.
- Hard break: two-space form works; backslash form doesn't (no `\` handling).

### B7. ParagraphParser ≠ CommonMark blocks (by design — record it)
`ParagraphParser` is a blank-line splitter for op-log paragraph identity, not a
block parser: a tight list collapses to ONE ¶-paragraph, a loose list splits
per item, a fence with an internal blank line splits mid-block. Deliberate
different model; noted so nobody mistakes op-log "paragraphs" for CommonMark
block structure.

---

## C. Doc drift (behavior fine or deliberate; docs/comments wrong)

1. **`markdown-syntax.md:117`** claims task checkboxes are "Not supported
   (deliberately)… renders as plain text" — **stale**: checkboxes are fully
   implemented (tokenizer `:113-150`, click-toggle, strikethrough).
2. **`fountain-syntax.md:102`** says an all-caps line followed by a blank is
   action — code deliberately classifies it as character (live-editing choice);
   also the stale "post-pass" comment at `FountainTokenizer.swift:575-584`.
3. **`fountain-syntax.md:165-171`** lists `FADE OUT:` as an auto-detected
   transition — neither Maugham nor the spec auto-detect it (needs `TO:`
   suffix); it classifies as a character cue. Doc error.
4. **`markdown-syntax.md:82`** calls link support "Standard CommonMark" —
   titles, angle-bracket destinations, and balanced parens are absent.
5. **`ProjectASTBuilder.swift:158-161`** — the "bridges through FountainParser
   in production (Task 31)" comment is false (see A1).
6. `MarkdownTokenizer.swift:4-6` header still says "does not handle nested
   emphasis" — stale since the shared scanner landed.
7. Undocumented not-supported gaps missing from `markdown-syntax.md`'s
   deliberate-omission list: setext headings, indented code, autolinks, hard
   line breaks, `1)` lists, `>`-without-space quotes, `***`/`___` breaks.

---

## D. Documented-intentional (confirmed consistent; no action)

- **Editor is a source-styling surface** — markers stay visible; "compliance"
  = correct recognition. Requires-space-after-`#`, 6-level cap, no fenced code
  / tables / footnotes / strikethrough / HTML / reference links: all listed in
  `markdown-syntax.md`.
- **Asterisk-only emphasis + underscore-deferred** (scanner header + milestone
  record); `***both***` + nesting work in editor/phone/Fountain surfaces.
- **Smart typography** mutates source as you type — an input feature, not
  Markdown; off for screenplay; version-dot guard present.
- **Wiki links `[[…]]`, `[[todo:…]]`/`[[done:…]]` tasks, `- [ ]` checkboxes,
  `<!-- ¶id -->`/`<!--t- -->` anchors** — Maugham extensions; anchors stripped
  cleanly on every publish/display path checked (`MarkdownDisplayFilter` runs
  first in both `parseProse` and `parseFountain`; no leaks found). One residual
  collision: a legit Fountain note starting `todo:`/`done:` becomes a clickable
  task.
- **Fountain core deliberate omissions** (all in `fountain-syntax.md:294-304`):
  scene numbers `#…#`, MORE/CONT'D, revision marks, FDX, visual-uppercase for
  forced characters. Multi-file screenplay dead (ADR 0001).
- **Mac editor & phone reader consume the shared tokenizer faithfully** — all
  14 elements exhaustively switched; phone display-uppercase via
  `ScreenplayUppercase` contract; Mac deliberately skips it (option-A cursor
  fallback); `.character`/`.pageBreak`/`.titlePage` layout divergences are
  contracted nil-rows in `ScreenplayEmphasis`. Marker-fade mechanism differs
  (opacity vs palette) — explicitly out of contract scope.
- **Tab-cycle covers 5 of 14 elements** (Highland order, documented); others
  reachable by typed forced markers; no UI affordance creates dual dialogue.
- **No surface renders side-by-side dual dialogue** — Mac/phone stack with
  indent; the only real column layout is the (unreachable, A1) publish emitter.
- **Emitter escaping is correct**: LaTeX all-10-specials with
  backslash-first placeholder ordering (`LaTeXEscape.swift`); XHTML `& < > "
  '` everywhere including attributes. Minor cosmetic: `< > |` unescaped in
  LaTeX text (wrong glyphs under OT1), straight→curly quotes.
- **Annotation note bodies are plain `Text` on both Mac and phone** —
  consistent with each other, divergent from every markdown surface; quoted
  manuscript text gets the task-anchor strip, bodies don't (deliberate).
- Unmatched/unbalanced delimiters degrade to literal text on every surface
  (good property, test-pinned).

---

## E. Cross-surface inconsistency table (same input, different output)

| Construct | Editor | Publish (prose) | Phone reader | Guide/Help | Research preview |
|---|---|---|---|---|---|
| Soft line break in paragraph | shown as-is | space-join | **hard break** | space-join | **separate blocks** (A4) |
| `#foo` (no space) | not heading ✓ | not heading ✓ | not heading ✓ | **heading** ✗ | not heading ✓ |
| `***x***` | bold-italic ✓ | **`strong("*x")+"*"`** (A2) | bold-italic ✓ | bold-italic ✓ | bold-italic ✓ |
| `_x_` | plain (deferred) | **emphasis, intraword too** | emphasis (swift-cmark) | emphasis | emphasis |
| `\*x\*` | emphasis (no escapes) | emphasis + literal `\` | literal ✓ (swift-cmark) | literal ✓ | literal ✓ |
| Fenced code | styled-through (documented) | **silent mangle** | silent mangle | monospace ✓ | mangle |
| Ordered list | marker styled | **coalesced into paragraph** | literal text | **reflowed onto one line** (A3) | per-line paragraphs |
| Pipe table | n/a (unsupported) | literal | literal | **literal pipes** (A3) | literal |
| Blockquote `>` | marker styled (space req.) | rendered quote ✓ | literal `>` | marker stripped, unstyled | literal `>` |
| Images | tail styles as link (A5) | literal text | parsed, renders nothing | parsed, renders nothing | **renders** (`./`-relative solo-line only) |

(Fountain: editor and phone agree via shared tokenizer; publish diverges per A1.)

---

## Suggested disposition order

1. **A1** publish-Fountain: route through `FountainTokenizer` (fixes the leak
   class + unlocks dual dialogue; delete the duplicated title-page parser).
2. **A2** prose `***`: adopt `InlineEmphasisScanner` in `InlineParser` (or add
   the `***` branch) + emission-contract example; decide `_` intraword while
   in there (B2).
3. **B1** escapes: pick literal-everywhere or emphasis-everywhere; align the
   four inline parsers.
4. **A3/A4** Help table+ordered lists; research-preview paragraph grouping.
5. **B6** decide the silent-mangle set (fenced/indented code, lists) → EMISSION.md.
6. **C** doc-drift sweep: `markdown-syntax.md`, `fountain-syntax.md`, the two
   stale code comments.
7. Consider registry rows / a shared MaughamCore block-splitter for the five
   display parsers (B4).
