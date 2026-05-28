# Body emitter overhaul — handoff for a new session

**Date:** 2026-05-28
**Branch:** `feat/publishing-pipeline` — `git checkout` directly from the main repo. (Developed in a git worktree through 2026-05-28; folded back to a regular branch at session end.)
**Status:** All scaffolding + small bundle items landed. Body emission is the critical remaining bug, and it's a real architectural reshape.

This is the most significant bug surfaced by external testing during the publishing pipeline milestone, and it's the work that turns "compiles cleanly into unreadable PDF" into "compiles into something a reader can actually read." All prior handoffs in this directory (`2026-05-27-publishing-pipeline-handoff.md`, `2026-05-27-publishing-pipeline-handoff-2.md`) remain valid for everything that isn't body emission.

---

## What the tester saw, exactly

Compiled the project Playlist (three pieces: two prose, one screenplay) into a PDF. Three classes of rendering failure across the pieces, all in the body content (title page and ToC look fine because they're generated outside this stage):

**Tribute (prose):** markdown inline syntax flows through verbatim. `*italic*` renders as the literal three characters `*italic*`. `**bold**` renders as `**bold**`. Blockquote `>` markers and chat-action `:*…*` syntax all leak as literal text.

**Tank Park Salute (prose):** paragraph boundaries collapsed into dense walls of justified text. Maugham's own `## ` section markers leak through as literal `## Day 1/3`, `## Day 2/3` text inline in the prose — what's clearly meant to be a section break is just typed characters mid-paragraph.

**Good Luck Babe (screenplay):** raw paragraph-anchor HTML comments (`<!-- ¶XXXX -->`) leak into the rendered output. These are Maugham's internal op-log join keys; they should never appear in any external artifact.

The tester's synthesis is exactly right: **this is one upstream bug in body emission, not three template bugs.** The PDF compiles with zero errors and zero warnings because LaTeX sees valid (if ugly) input. A CI check on compile success will pass while producing unreadable books.

The downstream-symptom note also matters: their "page-break default is wrong for collections" finding and "ToC says two pieces start on the same physical page" finding both **dissolve as independent bugs** once body emission inserts proper section starts with appropriate `\clearpage` semantics. Don't re-investigate them; fix this first and they go away.

---

## Where the bug lives

`Maugham/Publish/ProjectASTBuilder.swift` is the only file that translates manuscript source → AST. There's no markdown library, no Fountain library; both parsers are inline.

```swift
private static func parseProse(_ text: String) -> [ProjectAST.Node] {
    let stripped = stripAnchors(text)           // ✓ strips <!-- ¶XXXX -->
    let blocks = stripped
        .components(separatedBy: "\n\n")        // ⚠ only blank lines split
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return blocks.map { block in
        if isSceneBreakLine(block) { return .sceneBreak }
        return .paragraph(block)                 // ⚠ entire block is one string
    }
}

private static func parseFountain(_ text: String) -> [ProjectAST.Node] {
    // ⚠ DOES NOT CALL stripAnchors — the embarrassing one-liner
    var nodes: [ProjectAST.FountainNode] = []
    // ... line classification ...
}
```

Three issues stacked here:

1. **`parseFountain` doesn't call `stripAnchors`.** Fountain manuscripts contain inline `<!-- ¶XXXX -->` markers and they pass straight into `action` / `dialogue` text. Trivial fix.
2. **`parseProse` only splits on blank lines (`\n\n`).** A piece written as one long flowing block becomes one giant `.paragraph(String)`. No inline markdown is interpreted — `*`, `**`, `>`, `## ` all survive as literal characters.
3. **`ProseNode.paragraph(String)` doesn't model inline content.** Today's AST has `.emphasis(String)` and `.strong(String)` as SEPARATE top-level nodes at the same level as `.paragraph`. The emitters render each as its own `<p>...</p>` — there's no way for emphasis to live inside a paragraph the way real markdown requires.

---

## The AST restructure

Replace flat `ProseNode.paragraph(String)` with a paragraph that carries a sequence of inline runs. Heading nodes become first-class.

```swift
public enum ProjectAST.ProseNode: Equatable, Sendable {
    case paragraph([Inline])             // was: paragraph(String)
    case heading(level: Int, [Inline])   // NEW — for ## ATX-style headings
    case blockquote([ProseNode])          // NEW — > markdown blockquotes (nested)
    case sceneBreak                       // unchanged
    // .emphasis(String) and .strong(String) DELETED at the top level.
    // Those move into Inline below.
}

public enum ProjectAST.Inline: Equatable, Sendable {
    case text(String)
    case emphasis([Inline])               // nestable: *bold _italic_*
    case strong([Inline])
    case code(String)                     // `inline code` (no nesting)
    case wikiLink(target: String, display: String)
    case lineBreak                        // explicit `  \n` markdown line break
}
```

**Why nestable inline arrays:** `**bold _and italic_**` and `*italic with **bold** inside*` both happen in real prose. A single `String` inside `emphasis(_:)` can't represent them; an `[Inline]` can.

**Why keep `heading` instead of overloading `sceneBreak`:** `##` in Tank Park Salute is "Day 1/3" — it's a section title within a story, not just a typographic ornament. Emitters need the level + text so they can `\section*{Day 1/3}` for LaTeX and `<h2>Day 1/3</h2>` for XHTML, plus `\addcontentsline` for ToC integration. A bare scene break can't carry the text.

`FountainNode` doesn't change. Fountain elements are already structurally typed (`.action`, `.character`, `.dialogue`, etc.) and inline emphasis inside fountain is rare enough to defer.

---

## Implementation order (recommended)

Each phase is independently testable and commits cleanly. Total estimated work: ~6–10 hours of focused implementation including tests.

### Phase 1 — Strip anchors in `parseFountain` (10 min)

One-line fix. Add `let stripped = stripAnchors(text)` at the top of `parseFountain` and operate on `stripped`. Add a test asserting that a fountain piece containing `<!-- ¶abcd -->Aaron pours coffee.` emits `.action("Aaron pours coffee.")` not `.action("<!-- ¶abcd -->Aaron pours coffee.")`.

This unblocks the screenplay-leaked-markers bug immediately and is independently shippable.

### Phase 2 — Add `Inline` type + paragraph parser, KEEP existing cases as deprecated (1–2 hr)

Add `ProjectAST.Inline` enum without yet removing `ProseNode.emphasis(String)` and `ProseNode.strong(String)`. Replace `.paragraph(String)` with `.paragraph([Inline])`. Write a small inline-markdown parser:

```swift
struct InlineParser {
    static func parse(_ text: String) -> [ProjectAST.Inline] {
        // Walk character-by-character. Track open emphasis/strong delimiters.
        // Recognize:
        //   **X**   →  .strong([…])
        //   *X*     →  .emphasis([…])
        //   _X_     →  .emphasis([…])
        //   `X`     →  .code(X) (no nesting)
        //   [[t|d]] →  .wikiLink(target: t, display: d) — matches existing Maugham syntax
        //   "  \n"  →  .lineBreak (two-space then newline)
        // Anything else → accumulating .text(...) run.
    }
}
```

Tests: every inline form individually, nested forms (`**bold _italic_**`), unbalanced delimiters (`*hello` → `.text("*hello")`), code spans don't recurse (`` `**not bold**` `` → `.code("**not bold**")`).

`parseProse` rewires: each block goes through `InlineParser.parse(block)` for the inline pass instead of being shoved into `.paragraph(String)` raw.

### Phase 3 — Block-level parser: headings, blockquotes, paragraph splitting (1–2 hr)

Currently paragraphs are split only on `\n\n`. Need to recognize:

- **ATX headings:** lines starting with `# `, `## `, `### ` etc. Emit `.heading(level: N, InlineParser.parse(rest))`. The Maugham `##` markers Tank Park Salute uses become real heading nodes.
- **Blockquotes:** consecutive lines starting with `> `. Strip the `> ` prefix from each line; the remainder is recursively parsed as `[ProseNode]` and wrapped in `.blockquote([…])`. Matches CommonMark semantics.
- **Scene breaks:** still detected (`***`, `---`, `###` on a line by itself).
- **Paragraphs:** everything else, with single `\n` line breaks within a paragraph treated as soft (joining the lines with a space, OR with explicit `\n` if the writer ends a line with two spaces — that's the markdown `lineBreak` convention).

Refactor `parseProse` into a small state machine over lines instead of a one-shot `\n\n` split.

### Phase 4 — Update emitters (2–3 hr)

**`LaTeXBodyEmitter`:**

```swift
case .heading(let level, let inlines):
    let cmd = ["section", "subsection", "subsubsection"][min(level - 1, 2)]
    out.append("\\\(cmd)*{\(emitInline(inlines))}")
    out.append("\\addcontentsline{toc}{\(cmd)}{\(plainText(inlines))}")
case .paragraph(let inlines):
    out.append(emitInline(inlines))
    out.append("")  // blank line → \par in LaTeX
case .blockquote(let nodes):
    out.append("\\begin{quote}")
    for n in nodes { emit(prose: n, into: &out) }
    out.append("\\end{quote}")

// emitInline walks [Inline]:
//   .text(s)       → LaTeXEscape.escape(s)
//   .emphasis(xs)  → "\\emph{\(emitInline(xs))}"
//   .strong(xs)    → "\\textbf{\(emitInline(xs))}"
//   .code(s)       → "\\texttt{\(LaTeXEscape.escape(s))}"
//   .wikiLink(...) → "\\wikilink{...}{...}"
//   .lineBreak     → "\\\\"
```

Crucially: emit **blank lines** between paragraphs so LaTeX inserts `\par`. Without this, paragraphs join — which is the Tank Park Salute symptom.

**`XHTMLBodyEmitter`:** analogous, but the wrappers are HTML. `.paragraph([…])` → `<p>…</p>` with inline content rendered inside; `.heading(N, …)` → `<hN+1>…</hN+1>` (h2 for `##`, h3 for `###`, etc., reserving h1 for the section title); `.blockquote([…])` → `<blockquote>…</blockquote>`.

### Phase 5 — Delete deprecated cases + sweep callers (30 min)

Once both emitters handle the new inline shape, delete `ProseNode.emphasis(String)` and `ProseNode.strong(String)`. The convenience constructors in `ProjectAST+Node` extension also need updating — most likely simplified to just construct paragraphs with appropriate inline content.

Run the test suite. Anything that broke was relying on the old shape and needs migrating.

### Phase 6 — Update `LaTeXBodyEmitterTests` + `XHTMLBodyEmitterTests` (1–2 hr)

These tests build ASTs directly via the convenience constructors and assert on the emitted output. They need rewriting against the new shape. Test cases worth covering specifically:

- `**bold**` inside a paragraph renders as `\textbf{...}` inside `\par`, not as a separate paragraph
- Nested emphasis: `**bold _italic_**` renders correctly
- `## Heading` produces `\section*{Heading}` + `\addcontentsline`
- Paragraph splitting: two newlines = `\par` boundary; one newline = space (or `\\` if two-space ending)
- Blockquote with nested paragraphs
- Markdown specials escaped properly: `*not emphasis at line start `*hello*` standalone` still works
- Code spans don't recurse: `` `**not bold**` `` emits literal `**not bold**` in `\texttt{}`

### Phase 7 — Re-test against Playlist (out-of-process)

Tester re-runs the exact same compile (same three pieces, same config) and verifies:

- ✓ Visible paragraph breaks within pieces
- ✓ `##` markers become proper section headings + appear in ToC
- ✓ Asterisks render as bold/italic
- ✓ Screenplay markers (`<!-- ¶XXXX -->`) gone from output
- ✓ Pieces start on their own pages without manually setting `start_on`

The page-break-default and ToC-same-page findings should automatically resolve here.

---

## What NOT to do in this overhaul

- **Don't ship `style_preset`-based dispatch for Tribute's chat-transcript rendering yet.** That's a real UX decision with multiple plausible answers (LaTeX dialogue package? custom env? what does Claude Code transcript look like in print?). Ship the standard prose path correctly first; revisit transcript rendering as a separate scoping conversation. Tester explicitly endorsed this sequencing.
- **Don't rebuild the AST to support full CommonMark.** Targeting the subset Maugham writers actually use is enough: ATX headings, paragraphs, blockquotes, inline emphasis/strong/code, hard line breaks. Lists, code blocks, links to URLs, tables — defer until a writer asks. Less surface, less risk.
- **Don't change `FountainNode`.** Fountain elements are already structurally typed and the rendering bugs there are upstream (anchor stripping). The Phase 1 fix alone resolves the screenplay problem.

---

## What's already done (so the next session doesn't redo it)

All landed on `feat/publishing-pipeline` since the last handoff (`a44b8f0`):

| Commit | Subject |
|---|---|
| `d7285c3` | Structured isError results for all tool-handler failures |
| `84ebc0d` | Diagnostic instrumentation on list_publish_files (FOR REMOVAL once D1 root cause confirmed) |
| `8e76883` | Reproduction tests for list-after-delete bug (passing — D1 mystery isolated to running-app state) |
| `0e344a1` | D3: version-collision via init reset (a + b + c) |
| `97fca81` | D2: expand delete-protection to all starter file types |
| `6f14d28` | Tectonic intermediates route to build/ |
| `2bbb4e2` | Filename sanitization strips path-unsafe chars |
| `d263554` | Config encoder preserves explicit nulls |
| `6120168` | mtime touch after starter copy |
| `0dbdb84` | get_publish_config returns source: defaults/persisted |
| _pending_ | Doc strings + unknown_project_id helper (in flight — may already be committed by the time you read this) |

Tests are green at each commit. Full suite includes `xcodebuild test` against real tectonic via the host-bundle locator fallback in test setUp.

---

## Open issues NOT in scope for this overhaul

These remain unresolved but are independent of body emission. Don't conflate them.

- **D1: `list_publish_files` desync bug** — tester observed it returns subsets of disk truth in the running app; unit tests in isolation pass. Diagnostic instrumentation landed at `84ebc0d`; tester still owes us a rebuild + paste of the `_diagnostic` block. Until that lands, root cause is unknown (iCloud was ruled out via `ls -la`; stale DerivedData was ruled out via clean rebuild). Once cause is confirmed and fixed, REMOVE the diagnostic field from `ListPublishFilesTool`.
- **D4: `Publication.checkpointID` empty by design** — manuscript-state pinning was scope-out from v1 spec. Doc strings now reflect this. The actual fix wires `CheckpointStore.append` into `CompileOrchestrator.compile` so the manuscript-state side of reproducibility lands.
- **D5: per-section `config.sections` overrides ignored** — `title_override`, `start_on`, `include_in_toc` are settable but the emitters never read them. The body emitter overhaul SHOULD thread the overrides map through, since the new emitter is touching all the same code paths. Suggested shape: pass `[String: PublishConfig.Section]` (keyed by piece_id) into `ProjectASTBuilder.build` so the AST carries overrides per section. `include_in_toc: false` then skips the `\addcontentsline` emission; `start_on: "recto"` prepends `\cleardoublepage`; `title_override` replaces the binder title in the section header. Easier to fold in here than to add later.
- **Structured compile-level errors (Diagnostic.code/hint)** — `TectonicLogParser.Diagnostic` should grow `code: String?` and `hint: String?` fields. `CompileOrchestrator` should emit `code: "no_config"` and `code: "publish_not_initialized"` when those preconditions fail, alongside the existing `version_collision` (which has a structured message but no code field). Half-landed in `0e344a1` — wire-format extension is pending.

---

## How to start the new session

```
You are picking up the publishing pipeline body-emitter overhaul on
the feat/publishing-pipeline branch of the Maugham repo. Orient there.

Required reading, in order:

1. docs/superpowers/notes/2026-05-28-body-emitter-overhaul-handoff.md
   — the AST restructure plan, what to do and what NOT to do, and the
   success criteria the external tester will re-validate against.

2. docs/superpowers/notes/2026-05-27-publishing-pipeline-handoff.md
   — Maugham conventions for this milestone. Gotchas 1-10 still apply
   (trust xcodebuild over SourceKit noise, ./gen.sh after project.yml
   edits, MaughamTests is flat, skip dual review for trivial tasks).
   The CWD-guard section is obsolete now that work is on a branch, not
   a worktree.

3. docs/superpowers/notes/2026-05-27-publishing-pipeline-handoff-2.md
   — API drift table that downstream tests rely on (MCPError.toolError
   shape, registry.lookup, PublishingStores._resetForTesting pattern).

4. CLAUDE.md — project conventions and hard invariants.

Then execute Phases 1-7 from the body-emitter handoff in order:

- Phase 1 is one line — add stripAnchors(text) at the top of
  parseFountain in Maugham/Publish/ProjectASTBuilder.swift, write a
  test asserting that a <!-- ¶abcd --> anchor doesn't leak into a
  fountain action node, ship it as its own commit. Do this before the
  AST restructure so the screenplay-leaked-markers symptom unblocks.

- Phases 2-5 are the real AST work (Inline type, paragraph carries
  [Inline], heading + blockquote nodes, both emitters updated,
  deprecated cases removed).

- Phase 6 rewrites the emitter tests.

- Phase 7 hands back to the external tester for re-validation against
  the Playlist project.

Don't dispatch subagents in parallel (they conflict on git state).
Test files go at MaughamTests/ root, not in subdirectories.

When the overhaul is done, the external tester re-runs a compile
against Playlist (3 pieces: two prose, one screenplay) and checks the
five success criteria at the end of the body-emitter handoff. Don't
declare victory until that re-validation passes — the bug only shows
up in the rendered PDF, not in unit tests.
```

Files most relevant to the overhaul (no need to read upfront — the
handoff above tells you which when):

- `Maugham/Publish/ProjectASTBuilder.swift` — the parser to overhaul
- `Maugham/Publish/ProjectAST.swift` — the type to restructure
- `Maugham/Publish/LaTeXBodyEmitter.swift` — consumer #1
- `Maugham/Publish/XHTMLBodyEmitter.swift` — consumer #2
- `MaughamTests/LaTeXBodyEmitterTests.swift`
- `MaughamTests/XHTMLBodyEmitterTests.swift`
- `MaughamTests/ProjectASTTests.swift`

---

## Tester contract for re-validation

When body emission is done, the tester will re-run the EXACT same compile (Playlist, three pieces, same config) and use this success criteria. Don't ship the overhaul until all five are visually confirmed in the rendered PDF:

1. **Visible paragraph breaks within pieces.** Tank Park Salute's wall of text becomes properly paragraphed prose.
2. **`##` markers become proper section ornaments.** "Day 1/3", "Day 2/3", "Day 3/3" in Tank Park Salute render as visible section headings (or scene-break ornaments), not as literal `## Day 1/3` typed mid-prose.
3. **Asterisks render as bold/italic.** Tribute's `**bold**` and `*italic*` become rendered formatting, not literal asterisks.
4. **Screenplay paragraph markers stripped.** Good Luck Babe's screenplay has no surviving `<!-- ¶XXXX -->` text in the rendered PDF.
5. **Pieces start on their own pages.** No manual `start_on` configuration required — the heading semantics naturally clear pages.
