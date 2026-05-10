# Maugham — Phase 3c: Scene Navigator + Title Page + Inline Emphasis + ⌘? Help

**Date:** 2026-05-10
**Status:** Spec approved; writing plan next.
**Scope:** Third sub-milestone of Phase 3 (Screenplay parity). Lands four screenplay-tool features that materially complete Maugham's screenwriting environment: scene navigator pane, title page block parsing + rendering, inline emphasis (italic/bold/underline), and the `⌘?` syntax help overlay.

**Builds on:** milestone-3a (Fountain parser + per-element styling) and milestone-3b (Tab cycling + element gutter + marker fade pattern). All 3c work plugs into the existing `FountainTokenizer` ↔ `FountainScript` ↔ `ScreenplayMode` pipeline plus the binder/inspector SwiftUI structure.

**Two-phase execution:** Implementation has an explicit smoke gate after Phase 1 (scene navigator + title page) before continuing to Phase 2 (⌘? help + inline emphasis). One brainstorm/spec/plan, two smoke checkpoints, one `milestone-3c` tag at the end.

---

## 1. Goals & non-goals

### Goals

- **Scene navigator pane** in the binder for screenplay projects. Lists `.sceneHeading` lines from `lastParsedScript.lines` with their slug text and computed page numbers. Click-to-jump.
- **Title page block** parsing + inline rendering. Fountain title page (key/value pairs at document head, blank-line-separated from body) parses as a separate `titlePage: [TitlePageField]?` collection on `FountainScript`. Renders inline at the editor's document head with distinctive styling per field key (Title big + centered + bold; Author/Credit smaller centered; Draft date / Contact small + secondaryText).
- **Inline emphasis** (`*italic*`, `**bold**`, `_underline_`) inside dialogue and action. Extends `FountainInlineSpan.Kind` with `.italic` / `.bold` / `.underline`. Markers fade to `palette.syntaxPunctuation`; inner content gets the corresponding font/underline trait.
- **⌘? syntax help overlay**. SwiftUI sheet rendering the bundled `docs/markdown-syntax.md` (in prose mode) or `docs/fountain-syntax.md` (in screenplay mode) via `AttributedString(markdown:)`. Triggered by `⌘ Shift /` (the standard macOS "?" shortcut). Mirrors the existing `HelpClaudeDesktopSheet` pattern from 1d.

### Non-goals (deferred)

| Item | Scheduled milestone | Notes |
|---|---|---|
| Multi-file screenplay (one .fountain per scene) | **3d** | Architectural change; revisits binder shape. |
| Character autocomplete re-engineering | **post-3c** | Carry-forward from 3b option-A fallback. Needs a custom NSWindow popup, not NSPopover. |
| Scene-by-scene word/page summary in Statistics window | **post-3c** | Optional polish per handoff; defer until smoke shows demand. |
| Bold-italic combined form `***foo***` | **conditional** | If composition (italic + bold passes overlapping) works naturally, ships free. If broken, defer. |
| FDX import/export, scene numbers, dual dialogue, MORE/CONT'D, revisions | **Phase 4** | Master spec assigns to Phase 4. |

---

## 2. Architecture overview

```
              +----------------------------------+
              |       FountainTokenizer          |
              |   (extended for title page +     |
              |    inline emphasis spans)        |
              +-----+---------+------------------+
                    |         |
        FountainScript.titlePage    FountainScript.lines
        + .lines[i].element              + .lines[i].inlineSpans
                    |                            |
                    v                            v
         +------------------+      +-----------------------+
         |  ScreenplayMode  |      |  SceneNavigatorPane   |
         |  applyTypography |      |  (filters             |
         |  (extends with   |      |   .sceneHeading lines |
         |   title page +   |      |   + page numbers)     |
         |   emphasis spans)|      +------+----------------+
         +--------+---------+             |
                  v                       v
         editor renders inline       BinderView segmented:
         title page + emphasis       Manuscript|Research → Scenes|Research
                                     for screenplay
                                            |
              +-----------------------------+
              |
              v
       Click → notification → EditorCoordinator
       scrolls + sets cursor at scene heading line


              +----------------------------------+
              |      SyntaxHelpSheet (new)       |
              |  Mode-aware: prose docs vs       |
              |  fountain docs                   |
              |  Markdown content rendered via   |
              |  AttributedString or WKWebView   |
              +----------------------------------+
                          ↑
               ⌘ Shift / menu command
```

`FountainTokenizer` extends in two places:
- **Title page block** at document head: lines like `Title: My Screenplay` parse as `.titlePage` element, until first blank line. Multi-line values via continuation indent (Fountain spec).
- **Inline emphasis**: per-line scan for `*italic*`, `**bold**`, `_underline_` patterns. Each match adds a `FountainInlineSpan` with new kind cases.

`FountainScript.titlePage: [TitlePageField]?` — separate from `lines`. Each field has key, value, and source range.

`FountainScript.pageNumber(at:)` — computed page-number helper for the scene navigator. Walks lines from start, accumulating `estimatedPageCount`-style line counts up to the target line.

`ScreenplayMode.applyTypography` extends:
- New element styling for `.titlePage` lines (per-key visual treatment).
- New inline-span styling: italic, bold, underline applied to span content; markers fade per the milestone-3b marker-fade pattern.

`SceneNavigatorPane` — new SwiftUI view in `Maugham/Views/`. Reads scene list from `EditorCoordinator.lastParsedScript`. Click → posts `NotificationCenter` message → `EditorCoordinator` handles cursor placement.

`BinderPaneToggle` — extends from 2b's pattern. For screenplay project type, shows segments `Scenes / Research`. For other types, shows existing `Manuscript / Research`.

`SyntaxHelpSheet` — new SwiftUI view, mirrors `HelpClaudeDesktopSheet` pattern. Reads bundled `markdown-syntax.md` / `fountain-syntax.md` resources.

---

## 3. Scene navigator details

### 3.1 Pane location

For Screenplay projects, `BinderPaneToggle` shows two segments: `Scenes` and `Research`. The Manuscript segment is omitted for single-file screenplays — it would only show one document and adds redundancy. Multi-file screenplays in 3d will revisit (likely re-introducing Manuscript as a third segment showing scene files).

For Novel / Short Story / Collection projects, the binder shape is unchanged: `Manuscript` / `Research` segments.

The toggle's segment shape is computed from `manifest.type`. The existing `BinderSegment` enum (from 2b) gains a third case `.scenes` alongside `.manuscript` and `.research`. `BinderPaneToggle` chooses which segments to render based on project type.

### 3.2 Scene row format

Each scene row shows:
- **Slug text** — the full content of the `FountainLine.content` for the `.sceneHeading` line (e.g., `INT. KITCHEN - DAY`). Forced sluglines like `.barbershop` show as `barbershop` (content has the `.` stripped per `FountainLine.content` semantics).
- **Page number** — `p.5` (computed via `FountainScript.pageNumber(at:)`).
- **Selected highlight** — the row containing the editor's current cursor highlights via the system selection background.

Click → posts `MaughamNotifications.maughamNavigateToScene` with the line's `range.location`. EditorCoordinator subscribes, scrolls the line into view, sets cursor at `range.location`.

If `lastParsedScript` has zero scene headings, the pane shows a quiet placeholder: "No scenes yet — type INT. or EXT. to add one." Many scenes (50+) scroll within the pane.

### 3.3 Page-number computation

`FountainScript.pageNumber(at:)` returns 1-indexed page number for a given line. Implementation walks `lines` from start, accumulating per-line line counts via the same heuristic as `estimatedPageCount`:

```swift
public extension FountainScript {
    public func pageNumber(at line: FountainLine) -> Int {
        let linesPerPage = 55
        var totalLines = 0
        for candidate in lines {
            if candidate.range.location == line.range.location {
                return (totalLines / linesPerPage) + 1
            }
            totalLines += Self.lineCount(for: candidate)
        }
        return 1
    }

    fileprivate static func lineCount(for line: FountainLine) -> Int {
        // Same heuristic as estimatedPageCount's switch:
        let charsPerActionLine = 60
        let charsPerDialogueLine = 35
        let charsPerParenthetical = 20
        let sceneHeadingExtraBlankLines = 1
        switch line.element {
        case .action:
            let len = line.content.count
            guard len > 0 else { return 0 }   // skip blank action (per T7 implementer)
            let wraps = (len + charsPerActionLine - 1) / charsPerActionLine
            return max(wraps, 1)
        case .dialogue:
            let len = line.content.count
            let wraps = (len + charsPerDialogueLine - 1) / charsPerDialogueLine
            return max(wraps, 1)
        case .parenthetical:
            let len = line.content.count
            let wraps = (len + charsPerParenthetical - 1) / charsPerParenthetical
            return max(wraps, 1)
        case .sceneHeading:
            return 1 + sceneHeadingExtraBlankLines
        case .character, .transition, .centered, .lyric:
            return 1
        case .section, .synopsis, .boneyard, .note, .pageBreak, .titlePage:
            return 0
        }
    }
}
```

The existing `estimatedPageCount` is refactored to use this same helper for consistency. Title page lines don't count toward body page numbers (they conceptually live "before page 1").

### 3.4 Click-to-jump flow

```
User click row → SceneNavigatorPane.onTapGesture
  → NotificationCenter.post(.maughamNavigateToScene, [lineLocation: Int])
EditorCoordinator observer receives notification
  → setSelectedRange(NSRange(location: lineLocation, length: 0))
  → scrollRangeToVisible(...)
```

The notification name `maughamNavigateToScene` joins the existing `MaughamNotifications` enum. EditorCoordinator subscribes in its init (or attach()), unsubscribes in deinit.

---

## 4. Title page rendering details

### 4.1 Parsing

Fountain title page is at the document head, separated from body by a blank line. Each line is `Key: Value` with optional multi-line continuation (subsequent lines indented). Standard keys: `Title`, `Credit`, `Author` (or `Authors`), `Source`, `Notes`, `Draft date`, `Contact`, `Copyright`.

`FountainTokenizer` recognizes the title-page block ONLY at document head. The trigger condition: the first non-empty line matches `Key: Value` shape AND `Key` is one of the recognized title-page keys (case-insensitive). The title page block closes on the first line matching ANY of:

- a blank line
- a non-blank line that does NOT match `Key: Value` shape (per Fountain spec)
- a non-blank line that is NOT indented continuation of a prior multi-line value (continuation = leading 3+ spaces or a tab)

After the close, the parser switches to body mode and never returns to title page parsing.

`FountainScript.titlePage: [TitlePageField]?` — array of fields preserving order. Empty/absent = no title page.

```swift
public struct TitlePageField: Equatable, Sendable {
    public let key: String          // canonical case: "Title", "Author", "Credit", etc.
    public let value: String        // raw value (may span multiple source lines, joined with newlines)
    public let range: NSRange       // covers the entire field in source (key + colon + value + continuation)
}
```

Recognized keys (case-insensitive on parse, normalized to canonical case in storage):
- `Title`
- `Credit`
- `Author` / `Authors` (both accepted; canonical: `Author`)
- `Source`
- `Notes`
- `Draft date`
- `Contact`
- `Copyright`

Unknown keys are still parsed (preserve user's custom title page fields). Their styling falls into the "default title page line" bucket (small, left-aligned, secondaryText color).

### 4.2 Per-line element classification

Title page lines also classify in `FountainScript.lines` for completeness — they get a new `ScreenplayElement.titlePage` case. This lets the existing token pipeline route them through `applyTypography` for styling. The `titlePage` array on FountainScript is the structured view; the `lines` array preserves source-position ordering for both title page and body.

### 4.3 Rendering

In `ScreenplayMode.applyTypography`, after the existing element-styling passes, walk `script.titlePage`. For each field, apply paragraph attributes based on the key:

| Key | Style |
|---|---|
| `Title` | Centered, bold, 1.5× body font size |
| `Credit` | Centered, italic, body size |
| `Author` / `Authors` | Centered, body size |
| `Source` | Centered, italic, smaller (0.9× body size) |
| `Draft date`, `Contact`, `Notes`, `Copyright`, unknown keys | Left-aligned, smaller (0.85× body size), `palette.syntaxPunctuation` color |

The `Key:` text itself fades to `palette.syntaxPunctuation` color (consistent with the 3b marker-fade pattern). Value text gets the styled treatment.

After the title page, the FIRST body line gets extra paragraph spacing — `paragraphSpacingBefore = bodyFont.pointSize * 2.0` — to visually separate the title block from the script body. If there's no title page, this spacing isn't applied.

### 4.4 Edge cases

- **No title page**: document starts directly with body content. `titlePage = nil`. No styling pass.
- **Empty title page block**: `Title: ` (no value). Renders the key faded with empty value space. Allowed.
- **Title page with body lines mixed in**: not allowed per Fountain spec. Parser closes title page at first non-title-page line.
- **Document with title page only, no body**: renders just the title page; no extra body spacing.
- **Multi-line title page values**: Fountain spec allows continuation via indent (subsequent lines start with 3+ spaces). Parser joins continuation lines into the value with newlines. The styler renders the value as-is, preserving line breaks.

---

## 5. Inline emphasis details

### 5.1 Tokenizer extension

`FountainTokenizer`'s `inlineNoteSpans` (renamed to `inlineSpans` since it now handles more than notes) extends to detect:

- `*italic*` — `*` followed by non-`*`/non-newline content followed by `*`. Greedy minimal match within a line.
- `**bold**` — `**` ... `**`. Detected before `*italic*` to avoid bold being mis-captured as nested italics.
- `_underline_` — `_` ... `_`. Fountain-spec underline marker.

Per Fountain spec: emphasis spans don't cross newlines. Each line scanned independently.

Detection order within a line:
1. `[[ ... ]]` notes (existing)
2. `**bold**` (NEW)
3. `*italic*` (NEW; skips ranges already classified as bold)
4. `_underline_` (NEW)

Bold is detected BEFORE italic to prevent `**foo**` being parsed as `*foo*` × 2 (italic empty + italic empty). The italic pass then skips ranges that are already inside bold-recognized ranges.

`FountainInlineSpan.Kind` extends:

```swift
public enum Kind: Equatable, Sendable {
    case note          // existing
    case italic        // new
    case bold          // new
    case underline     // new
}
```

Each span's `range` covers the FULL `*text*` (including markers). The styler computes inner-content range and marker ranges from the span.

### 5.2 Styling

In `ScreenplayMode.applyTypography`'s inline-span pass:

- For `.italic`: apply italic font trait to inner content range; fade `*` markers to `palette.syntaxPunctuation`.
- For `.bold`: apply bold font trait to inner content range; fade `**` markers to `palette.syntaxPunctuation`.
- For `.underline`: apply `NSUnderlineStyle.single` to inner content range; fade `_` markers.

Inner content range for `*italic*` = span.range with leading and trailing `*` removed (offset +1 location, length -2). Similarly for `**bold**` (offset +2, length -4) and `_underline_` (offset +1, length -2).

### 5.3 Composition

If a `*foo **bar** baz*` is present:
- Outer italic span covers `*foo **bar** baz*`
- Inner bold span covers `**bar**`
- Both passes apply: italic font trait to outer inner-content (`foo **bar** baz`); bold font trait to inner inner-content (`bar`)
- Where the ranges overlap (`bar`), both bold AND italic apply → bold-italic font

NSAttributedString's font trait composition handles this: applying `.italic` then `.bold` to the same range yields a font with both traits (most fonts have a bold-italic variant). The marker ranges (`*` for outer, `**` for inner) all fade.

### 5.4 Edge cases

- **Unclosed marker** (`*foo` with no closing `*`): parser doesn't add a span. Renders as plain text.
- **Escaped marker** (`\*foo*`): not supported in 3c. The `\*` is treated as a marker. Future enhancement.
- **Cross-line marker** (`*foo\nbar*`): parser doesn't add a span (per-line scan). Renders as plain text.
- **Empty content** (`**`): edge case where `*` and `*` are adjacent. Parser detects 0-length italic content. Skip (don't add span; just plain text).

---

## 6. ⌘? help overlay details

### 6.1 Sheet view

`Maugham/Views/SyntaxHelpSheet.swift` — new SwiftUI view. Pattern mirrors `HelpClaudeDesktopSheet`:

```swift
struct SyntaxHelpSheet: View {
    let mode: SyntaxHelpMode  // .prose or .screenplay
    @Environment(\.dismiss) private var dismiss

    @State private var content: AttributedString = AttributedString("")

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .navigationTitle(navigationTitle)
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { content = loadContent() }
    }
    ...
}

public enum SyntaxHelpMode {
    case prose
    case screenplay
}
```

### 6.2 Markdown rendering

Use `AttributedString(markdown: data)` (macOS 12+ API). Renders headings, emphasis, code, links, lists. Returns an `AttributedString` that `Text` displays.

```swift
private func loadContent() -> AttributedString {
    let resourceName: String
    switch mode {
    case .prose:        resourceName = "markdown-syntax"
    case .screenplay:   resourceName = "fountain-syntax"
    }
    guard let url = Bundle.main.url(
        forResource: resourceName, withExtension: "md"),
        let data = try? Data(contentsOf: url),
        let attributed = try? AttributedString(
            markdown: data,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))
    else { return AttributedString("Help content unavailable.") }
    return attributed
}
```

The `interpretedSyntax: .inlineOnlyPreservingWhitespace` option preserves the document's structure (headings, paragraphs, lists) when possible. Tables in `fountain-syntax.md` may render imperfectly — see §10 risks.

### 6.3 Bundling

`docs/markdown-syntax.md` and `docs/fountain-syntax.md` are bundled with the main `Maugham` app target as resources. Update `project.yml`:

```yaml
  Maugham:
    type: application
    sources:
      - path: Maugham
    resources:
      - path: docs/markdown-syntax.md
      - path: docs/fountain-syntax.md
```

The files are ALSO accessible from the project root (not duplicated). xcodegen handles both source-tree and bundle-resource relationships.

### 6.4 Menu command + keyboard shortcut

`MaughamApp.swift` adds a Help-menu command:

```swift
.commands {
    ...
    CommandMenu("Help") {
        Button("Syntax Reference") {
            NotificationCenter.default.post(
                name: .maughamShowSyntaxHelp, object: nil)
        }
        .keyboardShortcut("?", modifiers: [.command, .shift])
    }
    ...
}
```

`⌘ Shift /` is the standard macOS "?" shortcut. The button posts a notification; `ProjectWindow.swift` (or `EditorHost.swift`) subscribes and toggles a state for the sheet:

```swift
.sheet(isPresented: $showingSyntaxHelp) {
    SyntaxHelpSheet(mode: currentSyntaxHelpMode)
}
```

The `currentSyntaxHelpMode` derives from the active document's mode: if `WritingModeFactory.mode(for: activeDocumentPath) is ScreenplayMode`, mode is `.screenplay`; else `.prose`. If no document is open, default to `.prose`.

### 6.5 No-window edge case

If the user invokes `⌘?` while no project window is open (just the Welcome window), the menu command still fires. `WelcomeView` can subscribe and show a default-prose-mode sheet, or the menu item can be disabled when no project is active. We disable the item when no project — keeps the help contextual.

---

## 7. EditorCoordinator changes

- Subscribes to `MaughamNotifications.maughamNavigateToScene` (new). Handler: read line location from notification userInfo, call `setSelectedRange(NSRange(location: lineLocation, length: 0))` and `scrollRangeToVisible(...)`.
- Subscription added in `init` (or at first attach), removed in `deinit`.
- No other changes — title page rendering happens entirely in `ScreenplayMode.applyTypography`; inline emphasis happens in the existing inline-span pass.

---

## 8. Testing strategy

### 8.1 Pure-logic unit tests

**FountainTokenizer extensions (~12 tests):**
- Title page block parses with various keys
- Multi-line title page values via continuation indent
- No title page → titlePage is nil
- First blank line after title page closes the block
- Body lines after title page parse normally as Fountain
- Title page recognition guard: line starts with `Key: Value` AND key is recognized
- Unknown title page keys still parse (preserved)
- Document starting with non-title-page line (`INT. KITCHEN`): no title page
- Inline emphasis: `*italic*` detected
- Inline emphasis: `**bold**` detected (before italic, doesn't double-classify)
- Inline emphasis: `_underline_` detected
- Inline emphasis: composition `*foo **bar** baz*`
- Edge cases: unclosed `*foo`, cross-line `*foo\nbar*` (no span)

**FountainScript.pageNumber (~4 tests):**
- First scene returns page 1
- Mid-document scene returns reasonable page number
- Page number monotonically increases by line position
- Empty script returns 1 for any input (or doesn't crash)

**Scene navigator filter logic (~3 tests):**
- Filters `lastParsedScript.lines` to scene headings only
- Preserves source order
- Includes both forced (`.barbershop`) and context-classified (`INT. ROOM`) scene headings

### 8.2 Integration tests

**ScreenplayMode title page styling (~4 tests):**
- Title field renders bold + centered + larger size
- Author field smaller centered
- Body line below title page has extra paragraph spacing
- Title page key text uses syntaxPunctuation color (faded)

**Inline emphasis styling (~5 tests):**
- Italic span applies italic font trait
- Bold span applies bold font trait
- Underline span applies underline attribute
- Markers fade to syntaxPunctuation
- Composition: `*foo **bar** baz*` produces bold-italic on overlap

**SyntaxHelpSheet bundle loading (~3 tests):**
- Loads markdown-syntax.md content
- Loads fountain-syntax.md content
- AttributedString markdown parse doesn't throw (returns non-empty)

**Notification flow (~2 tests):**
- Posting `maughamNavigateToScene` triggers EditorCoordinator handler
- Handler sets selection at the right location

### 8.3 Smoke checklists

#### Phase 1 smoke (after scene navigator + title page)

1. Open the reference fountain fixture → binder shows "Scenes / Research" segments
2. Click "Scenes" → list shows scene headings with page numbers
3. Click a scene → editor scrolls to that line, cursor lands at start of slug
4. Type a new scene heading in the editor → scene list updates live
5. Add a title page block at document head:
   ```
   Title: My Screenplay
   Author: Test Writer
   Draft date: 2026-05-10
   ```
   → title renders centered + bold, author smaller centered, draft-date small/dim, body has visual gap below
6. Switch to a Novel/Story project → binder back to Manuscript / Research, no Scenes segment
7. Toggle "Show element gutter" off in Project Settings → gutter hides; scenes pane still works
8. Theme switch (Light/Dark/Sepia) → title page colors re-render
9. Long screenplay (50+ scenes) → scene list scrolls; clicking still jumps correctly

#### Phase 2 smoke (after ⌘? + inline emphasis)

10. `⌘ Shift /` in a screenplay → sheet opens, shows fountain-syntax.md content
11. `⌘ Shift /` in a prose document → sheet shows markdown-syntax.md content
12. Escape → sheet dismisses
13. Type `*italic*` in dialogue → inner text renders italic, asterisks fade
14. Type `**bold**` in action → inner text bold, `**` faded
15. Type `_underline_` in dialogue → underlined
16. Compose `*foo **bar** baz*` → bar is bold-italic, foo/baz italic
17. Theme switch → emphasis colors update
18. Open syntax help sheet, scroll through content, dismiss → editor still works

---

## 9. Implementation sequencing (preview for the plan)

### Phase 1 — scene navigator + title page (~10 tasks)

1. `TitlePageField` struct + `FountainScript.titlePage` property (pure data)
2. Extend `FountainTokenizer` to parse title page block (state machine)
3. Add `ScreenplayElement.titlePage` case + Token.Kind support
4. Add `FountainScript.pageNumber(at:)` helper (refactor estimatedPageCount to share lineCount logic)
5. ScreenplayMode renders title page lines (per-key styling)
6. Title-page-to-body paragraph spacing
7. `BinderSegment.scenes` enum case + `BinderPaneToggle` extension for screenplay
8. `SceneNavigatorPane` view (slug list + page numbers)
9. Click-to-jump notification + EditorCoordinator handler
10. **Phase 1 smoke checkpoint** (manual smoke; commit fixes)

### Phase 2 — ⌘? help + inline emphasis (~7 tasks)

11. Inline emphasis tokenizer (italic + bold + underline patterns); extend `FountainInlineSpan.Kind`
12. ScreenplayMode inline-span pass styles emphasis with marker fade
13. `SyntaxHelpSheet` view + `SyntaxHelpMode` enum + AttributedString markdown rendering
14. Bundle `docs/markdown-syntax.md` and `docs/fountain-syntax.md` as resources via `project.yml`
15. Help menu command `Syntax Reference` with `⌘ Shift /` shortcut + ProjectWindow sheet wiring
16. **Phase 2 smoke checkpoint** (final smoke)
17. Tag `milestone-3c`; push.

Total: ~17 tasks. Two intermediate smoke checkpoints prevent late-stage iteration cost.

Model selection: tokenizer extensions = sonnet (substantive pure logic + tests). SwiftUI views (sheet, navigator pane) = haiku (mechanical SwiftUI). Page-number helper = sonnet. Title-page styling = sonnet (multi-pipeline-point change). Menu command = haiku.

---

## 10. Risks & mitigations

- **`AttributedString(markdown:)` may not handle the table in `docs/fountain-syntax.md`**. Markdown tables aren't in the `inlineOnlyPreservingWhitespace` interpretation path. Mitigation: if tables render as raw pipe-separated text, either (a) remove the table from `fountain-syntax.md` and rewrite as a definition list, or (b) use `interpretedSyntax: .full` (which renders more but may misformat headings), or (c) fall back to embedded `WKWebView` with full markdown support. Decision deferred to implementation; spike during the SyntaxHelpSheet task.
- **Title page parse regression risk**. The new state-machine state for title-page parsing must not affect documents without a title page. Mitigation: title page only triggers if the FIRST non-empty line matches `Key: Value` with a recognized key. A document starting with `INT. KITCHEN` parses as today.
- **Page-number drift on long screenplays**. The cumulative line-count math may diverge from Final Draft beyond the reference fixture's tolerance. Mitigation: existing page-count fixture stays as the regression baseline; new scene-by-scene page numbers should agree within ±1 page on reference content. If drift is larger, revisit lineCount constants in a follow-up.
- **Inline emphasis composition edge cases**. `*foo **bar** baz*` should render bar as bold-italic. If NSAttributedString's font-trait composition doesn't produce a bold-italic variant for the configured screenplay font, the composition may render as italic-only or bold-only. Mitigation: test composition explicitly with the JetBrains Mono / SF Mono fonts that the screenplay default uses; if missing, document the limitation and ship.
- **Menu shortcut collision**. `⌘ Shift /` is sometimes pre-bound by macOS to "Show Help Menu" or by Xcode's menu interception. Mitigation: test in the running app; if conflict, fall back to `⌘ Shift ?` (which is the same physical keystroke on US keyboards).
- **Notification deinit hazard**. `EditorCoordinator` subscribes to `maughamNavigateToScene` in init/attach. Forgetting to unsubscribe in deinit leaks observer references. Mitigation: use `NotificationCenter.default.removeObserver(self)` in deinit, OR subscribe via the modern `addObserver(forName:object:queue:using:)` API and store the resulting `NSObjectProtocol` token (which auto-removes on dealloc with the right pattern).
- **`BinderPaneToggle` per-project-type segment shape**. The toggle currently has 2 segments (Manuscript / Research from 2b). For Screenplay, we replace Manuscript with Scenes. SwiftUI's `Picker` with `pickerStyle(.segmented)` requires the same number of children for stable rendering; conditionally including different `Text` views may cause flicker. Mitigation: the `BinderSegment` enum has 3 cases; the picker shows the 2 cases that apply for the current project type. Re-rendering happens once per project switch — should be visually stable.

---

## 11. Decisions banked during brainstorm

- **Scope**: all 4 features with intermediate smoke gate after navigator + title page.
- **Scene navigator placement**: option B (Scenes / Research segments for screenplay; replaces Manuscript).
- **Title page rendering**: option A (inline at document head with distinctive styling).
- **⌘? help overlay**: option A (SwiftUI sheet, mode-aware content).
- **Inline emphasis**: option B (italic + bold + underline).
