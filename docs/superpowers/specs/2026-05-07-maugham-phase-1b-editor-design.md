# Maugham Phase 1b — Editor Design

**Date:** 2026-05-07
**Status:** Approved by author; ready for implementation plan
**Anchor:** This spec extends `docs/superpowers/specs/2026-05-07-maugham-master-design.md`. Foundations locked there are not re-derived here.

---

## Goal

Replace milestone 1a's `PlaceholderEditor` (a thin SwiftUI `TextEditor` wrapper) with a real Maugham editing surface: an NSTextView-backed `EditorSurface` driven by a `WritingMode` protocol, with `ProseMode` (Markdown) as the first concrete mode, configurable typography, three themes (Light / Dark / Sepia), and an in-app Settings window. After 1b, writing in Maugham should feel deliberate — proper typography, calm syntax highlighting, smart punctuation — and the typography settings UI should let a writer dial in their preferred page.

Out of scope (defer to 1c+): focus mode, sentence/paragraph focus, typewriter scroll, three-pane window, binder, inspector, status bar, find/replace, multi-document switching, per-project typography overrides.

---

## Locked-in foundations (carried from master spec)

| Area | Decision |
|---|---|
| Editor surface | NSTextView wrapped via SwiftUI `NSViewRepresentable`, TextKit 2 stack |
| Mode protocol | `WritingMode` — `tokenize`, `applyTypography`, `smartTypographyTransform`, `metrics` |
| Default prose font | Iowan Old Style |
| Themes | Light, Dark, Sepia (plus "Follow System" → Light/Dark by `NSApp.effectiveAppearance`) |
| Smart typography | em dash, ellipsis, smart quotes; per-toggle in Settings |
| Files-as-truth | The on-disk `.md` is plain Markdown; nothing about syntax highlighting touches the file |

---

## Component layout

```
+-------------------------------------------------------------+
|                    EditorSurface (SwiftUI)                   |
|  Wraps NSTextView via NSViewRepresentable                    |
|  Inputs:  Binding<String>, Theme, TypographySettings, Mode   |
|  Outputs: cursor position (for status bar in 1c)             |
+----------------+--------------------------------------------+
                 | delegates to
                 v
+-------------------------------------------------------------+
|              EditorCoordinator (NSObject)                    |
|  Conforms to NSTextViewDelegate                              |
|  Mediates SwiftUI binding <-> NSTextView events              |
|  Tracks "is this update from user typing or external?"       |
|  Triggers re-tokenize on textDidChange                       |
+----------------+--------------------------------------------+
                 | uses
                 v
+-------------------------------------------------------------+
|                   WritingMode (protocol)                     |
|  tokenize(_ text: String) -> [Token]                         |
|  applyTypography(in: NSTextStorage, theme:, typography:,     |
|                  tokens:)                                    |
|  smartTypographyTransform(replacement:) -> String?           |
|  metrics(_ text: String) -> EditorMetrics                    |
+----------------+--------------------------------------------+
                 | implemented by
                 v
+-------------------------------------------------------------+
|                       ProseMode                              |
|  Custom regex tokenizer (Token kinds: heading, emphasis,     |
|    code, link, list, quote, hr, syntaxPunctuation, plain)    |
|  Smart typography: -- -> em dash, ... -> ellipsis,           |
|    straight -> curly quotes                                  |
|  Metrics: word count, character count, reading minutes       |
+-------------------------------------------------------------+
```

---

## 1b-specific decisions

### Markdown tokenizer

Custom regex-based tokenizer, ~150 lines of Swift. Zero dependencies. Covers what we need: headings (`#`–`######`), emphasis (`*` and `**`), inline code (backticks), links (`[text](href)`), list markers (`-`, `*`, `+`, ordered), blockquotes (`>`), horizontal rules (`---`). Does not handle: tables, footnotes, HTML embeds — defer to a future milestone if a writer demands them.

The tokenizer's job is to **classify ranges**, not to render. It returns `[Token]` where each token has an `NSRange` and a `Kind`. We never convert Markdown to HTML or to a separate AttributedString — the editor displays the source text and we apply attributes to its ranges in place.

### Live-format strategy

On every `textDidChange` from NSTextView, the coordinator re-tokenizes the **whole document string** and applies attributes via `textStorage.setAttributes(_:range:)` in a single `beginEditing/endEditing` pass.

Whole-document re-tokenize is comfortably below 1ms per keystroke for documents up to ~100k characters (a chapter, a short story, a novella in a single file). Maugham opens one document at a time, never the entire novel concatenated — phase 2's binder navigates between chapter files.

If profiling on a future milestone shows 100k+ files becoming common, paragraph-scoped incremental tokenization is the right next step. Designed for, not built for, in 1b: the `WritingMode.tokenize` signature is `(String) -> [Token]`, which we can later extend to `(String, edits: [NSRange]) -> [Token]` without breaking callers.

### NSTextView wrapping pattern

```
EditorSurface (SwiftUI)
  @Binding var text: String
  let theme: Theme
  let typography: TypographySettings
  let mode: any WritingMode

  func makeNSView(context):
    create NSTextView (TextKit 2 layout manager + content storage)
    configure scroll view, ruler, smart-substitution settings
    apply theme + typography
    set delegate = context.coordinator
    return scroll view

  func updateNSView(nsView, context):
    if textView.string != text:
      coordinator.applyExternalText(text)
    if context.coordinator.theme != theme || context.coordinator.typography != typography:
      coordinator.applyAppearance(theme, typography)

  func makeCoordinator():
    EditorCoordinator(text: $text, mode: mode)
```

`EditorCoordinator` is the NSObject that conforms to `NSTextViewDelegate`. Two crucial guards:

1. **`isApplyingExternalUpdate` flag** — set to true while `applyExternalText` runs, suppressing the binding write inside `textDidChange`. Without this, external state updates would clobber the user's editing context (cursor, undo).
2. **Tokenize-and-attribute happens after the binding write**, on the same run loop tick, so the on-screen attributes are always consistent with the current text.

### Token model

```swift
public struct Token: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)         // 1–6
        case emphasis(strong: Bool)      // *italic* vs **bold**
        case code                        // `inline`
        case link(href: String)          // [text](href)
        case listMarker                  // - * + or 1.
        case blockquote                  // >
        case horizontalRule              // ---
        case syntaxPunctuation           // the ** or # or [] dimmed parts
        case plain
    }
    public let range: NSRange
    public let kind: Kind
}
```

The `syntaxPunctuation` token is the one that earns its keep: it's what gets the dim-color attribute so that `**bold**` displays with quiet asterisks and a brighter inner span, iA-Writer style.

### Smart typography transforms

Three independent transforms, each toggleable in Settings:

| Transform | Trigger | Result |
|---|---|---|
| Em dash | `--` followed by anything | `—` |
| Ellipsis | `...` followed by anything that isn't a digit | `…` |
| Smart quotes | `"` or `'` typed in normal context | curly `"`/`'` opening or closing per surrounding text |

Implemented via `WritingMode.smartTypographyTransform(replacement:)` which the coordinator calls in `textView(_:shouldChangeTextIn:replacementString:)`. Returning a non-nil string replaces the user's input transparently; the user's undo step still rolls back to the previous state.

NSTextView's built-in smart quotes / dashes settings are **disabled** because they don't expose per-substitution toggles. We want them granular.

### Settings UI

Standard macOS Settings scene (`Settings { ... }` in the App body), opened by ⌘,. Five tabs:

| Tab | Controls |
|---|---|
| **Editor** | Font picker (curated), Size slider 12–24pt, Line height slider 1.4–2.0, Page width slider 60–90 chars, Paragraph spacing slider 0–2×line-height |
| **Theme** | Picker: Light / Dark / Sepia / Follow System (default: Follow System) |
| **Typography** | Smart quotes toggle, em-dash auto-replace toggle, ellipsis auto-replace toggle |
| **General** | Placeholder for 1d (default project location, default author name) |
| **About** | Version, license, GitHub link |

Settings persist via `@AppStorage` to `~/Library/Preferences/com.maugham.Maugham.plist`. Per-project overrides arrive in 1c.

### Theme palette

| Element | Light | Dark | Sepia |
|---|---|---|---|
| Background | `#FFFFFF` | `#1E1E1E` | `#FBF0D9` |
| Body text | `#1A1A1A` | `#E0E0E0` | `#3C2E1F` |
| Syntax punctuation (dim) | `#A0A0A0` | `#6E6E6E` | `#A6916D` |
| Heading | `#0A0A0A` | `#FFFFFF` | `#2D1F0F` |
| Code | `#5A4A20` | `#D5C18A` | `#5A4520` |
| Link | `#0066CC` | `#5AA8FF` | `#704528` |
| Blockquote bar | `#D0D0D0` | `#404040` | `#D8C2A0` |
| Caret | `#0A0A0A` | `#E0E0E0` | `#3C2E1F` |
| Selection | `#B5D5FF` | `#264F78` | `#E2C9A8` |

These values are starting points to be dialed in by trying the running app. The implementation plan should treat them as defaults that may be tuned during phase-1b iteration without spec amendment.

"Follow System" maps to Light or Dark by inspecting `NSApp.effectiveAppearance` and observing changes via the `NSAppearanceCustomization` notification path.

### Typography defaults

| Setting | First-launch default | Range |
|---|---|---|
| Prose font | Iowan Old Style | curated list: Iowan Old Style, New York, Charter; system-serif fallback if user removes Iowan |
| Size | 17pt | 12–24pt, integer steps |
| Line height multiplier | 1.7 | 1.4–2.0, 0.05 steps |
| Page width (max line length) | 70 chars | 60–90 chars |
| Paragraph spacing | 0.6 × line-height | 0–2 × line-height, 0.1 steps |
| Smart quotes | on | toggle |
| Em-dash auto-replace | on | toggle |
| Ellipsis auto-replace | on | toggle |

The "page width" measurement is in *characters at the current font's average glyph width*, which TextKit can compute. Implementation note: store as character count in settings, render as a max textContainer width in points.

---

## Component file structure

```
Maugham/Editor/
  EditorSurface.swift           # SwiftUI NSViewRepresentable
  EditorCoordinator.swift       # NSTextViewDelegate, mediates binding/delegate
  WritingMode.swift             # protocol
  ProseMode.swift               # implementation
  Token.swift                   # Token + Kind
  Tokenizer/
    MarkdownTokenizer.swift     # regex-based ~150 lines
    SmartTypography.swift       # quote/dash/ellipsis transforms
Maugham/Theme/
  Theme.swift                   # enum + palettes
  TypographySettings.swift      # struct, Codable for per-project later
  ThemeManager.swift            # @Observable, reads/writes UserDefaults
Maugham/Views/
  ProjectWindow.swift           # MODIFIED — uses EditorSurface
  SettingsView.swift            # ⌘, root
  SettingsView+Editor.swift
  SettingsView+Theme.swift
  SettingsView+Typography.swift
  SettingsView+General.swift    # placeholder
  SettingsView+About.swift
Maugham/MaughamApp.swift        # MODIFIED — adds Settings scene
MaughamTests/
  MarkdownTokenizerTests.swift  # token-by-token corpus tests
  SmartTypographyTests.swift    # per-transform tests
  ProseModeTests.swift          # mode integration
  ThemeTests.swift
  TypographySettingsTests.swift
```

~13 new Swift files, ~3 modified. Estimated 18–22 implementation tasks in the plan.

---

## Testing strategy

| Layer | Strategy |
|---|---|
| `MarkdownTokenizer` | Pure-function tests over a corpus of representative Markdown snippets. Each test asserts the produced `[Token]` array exactly. |
| `SmartTypography` | Pure-function tests for each transform: input string + cursor → expected replacement. |
| `ProseMode` | Integration tests calling tokenize + smartTypographyTransform end-to-end. |
| `Theme` / `TypographySettings` | Codable round-trip + hex-color decoding tests. |
| `EditorSurface` / `EditorCoordinator` | Smoke-build only. NSViewRepresentable testing is brittle and gives weak signal; manual smoke test is the right tool. |
| `SettingsView*` | Smoke-build only. SwiftUI views with `@AppStorage` are not unit-testable without significant ceremony. |

The 1a pattern holds: model + non-UI logic is exhaustively unit-tested; SwiftUI views are smoke-tested by build success and the milestone smoke test.

---

## Phase smoke test (manual, after implementation)

1. Launch Maugham, open the milestone-1a Smoke Test project.
2. Editor uses Iowan Old Style at 17pt, line height ~1.7. Background follows system.
3. Type `**bold** and *italic* and `code`.` — see asterisks dim, the inner spans display in their respective styles, the backticks dim.
4. Open Settings (⌘,) → Theme tab. Switch to Sepia. Background turns paper-yellow.
5. Type `--` — see it become `—`. Type `...` — see it become `…`. Type `"hello"` — see curly quotes.
6. Open Settings → Typography. Disable smart quotes. Type `"world"` — straight quotes remain.
7. Open Settings → Editor. Drag size slider to 22pt. Editor reflows.
8. Quit and relaunch. Settings persist (still 22pt, Sepia, smart quotes still off).

If all eight pass, milestone 1b is healthy.

---

## Out of scope (deferred to 1c+)

| Feature | Lands in |
|---|---|
| Three-pane window (binder + editor + inspector) | 1c |
| Focus mode (⌘\), full-screen focus | 1c |
| Sentence / paragraph focus | 1c |
| Typewriter scroll | 1c |
| Status bar (live word count) | 1c |
| Find / Replace UI | 1c |
| Per-project typography overrides | 1c |
| Multi-document switching within project | 1c |
| Word count goal indicators | 1c |
| Project-type variants (Novel, Screenplay, Collection) | 1d |
| NSFileCoordinator integration | 1e |
| Autosave debounce + ⌘S dummy + conflict UI | 1e |

---

## Open architectural decisions deferred

These are intentionally not resolved by 1b's spec:

- **Custom themes (user-authored).** Only the three built-ins ship in 1b. User-authored themes need a file format and an editor; deferred.
- **Per-project typography overrides.** The data model in 1a's manifest will support these (any field added is forward-compatible). Wiring lands in 1c when per-project preferences become a thing.
- **Multi-line code blocks.** The tokenizer in 1b handles inline code only. Fenced code blocks (```...```) are common in research notes; defer to 1c when notes/research views land.
- **Spell-check management UI.** NSTextView ships spell-check on by default; we leave it on, no UI to manage it in 1b.

---

## Appendix — what the implementation plan should produce

The 1b implementation plan (next session) should produce ~18–22 bite-sized tasks following the 1a pattern: failing test → run → minimal implementation → passing test → commit. SwiftUI view tasks use smoke-build verification rather than unit tests, with a final manual smoke test against the eight-step checklist above.

The plan is expected to land in `docs/superpowers/plans/2026-05-07-maugham-phase-1b-editor.md`.
