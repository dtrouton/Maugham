# Canvas keyboard flow, on-canvas region names, chapter-aware scraps, Finder image drops — design

**Status:** draft for Denver's approval · 2026-10-24
**Area:** `Maugham/Canvas/` (read `Maugham/Canvas/AREA.md` first; tripwires 25–33 and 57 apply)

## Why

Denver mind-maps on the Plan canvas. Today the canvas is mouse-only: the one canvas key is Delete. Inside a scrap, Return and Shift+Return both insert a newline and Escape does nothing. With no scrap open, Return, Tab and the arrows beep. Getting out of a scrap means clicking away, making the next one means double-clicking, and drawing a line means dragging. Every new thought costs a trip to the mouse, and the flow breaks.

Three more annoyances get in the way of the same work:
- **Chapter scraps don't belong to the chapter.** With a chapter selected in the binder, a new scrap belongs to nothing until the writer draws a region. Since the board dims everything not bound to the selected chapter, the writer's own new scrap appears dimmed.
- **Regions can only be named from the inspector.** A new region reads "Untitled region" until the writer goes to the right-hand column.
- **Dropping a PNG from Finder onto the canvas fails.** The file slides back to Finder. Dropping it onto Research works, and so does dragging it from Research to the canvas.

**What success looks like:**
- Denver picks the book or a chapter in the binder.
- Then he can create, chain and connect scraps from the keyboard without touching the mouse.
- Everything he makes belongs where he expects.

## Goals

### 1. Keyboard flow (Denver's decisions)

**While typing in a scrap:**

| Key | Does |
|---|---|
| Return | Finishes the scrap and leaves it selected. |
| Shift+Return | New line inside the scrap. |
| Tab | Finishes, then makes a new scrap beside it **joined by a line**, and starts typing in it. |
| ⌘Return | Finishes, then makes a new scrap **below** it, with no line, and starts typing in it. |
| Escape | Finishes the scrap. It never discards typed text. |

**With a scrap selected but not being edited:**

| Key | Does |
|---|---|
| Return | Starts typing in it. |
| Tab, ⌘Return | Same as above: a new joined scrap, or a new scrap below. |
| Arrow keys | Move the selection to the nearest card in that direction. |
| Delete | Unchanged. |

**On an empty canvas, or with nothing selected:** Return makes a new scrap at the centre of the visible view and starts typing in it.

**Placement:** new scraps place themselves clear of existing cards, and never on top of one.

**Undo (Claude's call):** making a key-created scrap is one undo step, and for Tab that step includes the joining line. Typing into it is its own step afterwards, as with double-click today. So after Tab-and-type, the first ⌘Z removes the text and the second removes the scrap and its line.

**With a region, line or item card selected (Claude's call):**
- **Region:** Return renames it in place (§3).
- **Item card:** Return does nothing. Tab and ⌘Return work as for a scrap.
- **Region or line:** Tab and ⌘Return do nothing.
- **Arrows:** they work from any selection, measuring from its centre.

**Getting to the canvas from the binder (Denver's decision):**
- In the Plan persona, **Tab in the binder moves keyboard focus to the canvas**, and **Shift+Tab** on the canvas moves it back. This is macOS's key-view loop.
- The binder keeps its own Return (inline rename) and arrows.
- Canvas keys act only while the canvas holds first responder, and go through `CanvasEventNSView.keyDown`. Escape keeps its `WindowEscapeArbiter` path.
- Today the canvas takes first responder only on `mouseDown`, so this hand-off is new work.

The flow is: arrow to a chapter, then Tab, then Return, then type.

### 2. Chapter-aware scraps (Denver's decisions)

The binder selection is the context. Denver selects the book or a chapter first, then creates freely.

**With a single chapter selected** (`CanvasSubject.piece`), every **scrap** the writer creates (by double-click or any key above) is bound to that chapter on creation (`CanvasNode.boundPieceID`). Such a scrap:
- appears in that chapter's references;
- promotes into that chapter's research;
- is not dimmed.

**With the book selected** (`.wholeProject`), scraps stay unbound, as today.

**Regions:** unchanged. A region swept while a chapter is selected still binds to it.

**Dropped items with a chapter selected (Denver's decision):** only regions and scrap nodes carry a chapter; the rule that "an owned item node inherits and never carries" (`Promotion.piece(for:in:)`) stands.
- **On empty canvas:** an image, research item or inbox capture dropped there is wrapped in a **new region bound to that chapter**, sized around it. The region's title opens for typing exactly as after a sweep (§3).
- **Several items in one drop:** they share one new region.
- **Onto an existing region:** the item joins that region, as today.
- **With the book selected:** dropped items land loose, as today.

**Precedence (Claude's calls):**
- **Unbound region:** a scrap created inside it while a chapter is selected gets its own binding to that chapter.
- **Region bound to the same chapter:** the scrap is not bound redundantly; it follows the region.
- **Region bound to a different chapter:** the scrap is left unbound itself, and keeps following its region, as today.
- A scrap's own binding is kept when the binder selection later changes.
- The writer can change the binding in the inspector, as now.

### 3. Region names on the canvas (Denver's decisions)

- **On creation:** when a sweep creates a region, its title is immediately editable on the canvas, like a new Finder folder. The writer types, then:
  - **Return** commits the name.
  - **Escape** leaves the region untitled.
  - **Clicking elsewhere** commits whatever was typed.
- **Rename:** double-clicking a region's title on the canvas edits it in place.
- **Inspector:** keeps its Name field.

### 4. Finder image drop (bug)

Dragging a PNG from Finder onto the canvas must add it, exactly as dragging it in via Research does today. With a chapter selected, it then gets wrapped in a region as in §2.

**Root cause first, with a failing regression test before any fix.** Claude's leading hypothesis is that the innermost `.dropDestination(for: String.self)` in `CanvasView.body` claims a Finder file drag through its string representation, then rejects it as an unknown item id, so the outer `.onDrop(of: [.fileURL, .image])` never runs. The comments at `CanvasView.swift` ~546–580 record why that order was chosen (browser drags). Any fix must keep browser, research-item and capture drops working.

## Non-goals

- Keyboard creation or resizing of regions, and keyboard drawing of lines between existing cards. The only line the keyboard makes is Tab's.
- Changes to Claude's canvas tools (MCP), or to how Claude places cards.
- The phone.
- Restyling cards, regions or lines.

## Anti-goals (a failure even if it technically works)

- **Losing typed text** to any key: Escape, Return, Tab or ⌘Return.
- **Stealing keys meant for something else:** the binder's inline rename, the find bar, the assistant column, or the inspector's text fields. Canvas keys act only when the canvas holds the keyboard.
- **A new scrap landing on top of another card.**
- **A scrap made while a chapter is selected appearing dimmed.**
- **Breaking the Escape arbitration** (dimmed board → project row) for the case with no scrap open.

## Constraints

- **Tripwires:**
  - 27: the mounted editor stays frontmost, focus is requested, and it mounts on the click.
  - 28: text folds in on `textDidChange`.
  - 31: membership never changes on a move or resize; creation absorbs by centre.
  - 32: no mid-gesture mutation. A key pressed mid-drag is refused like Delete is.
  - 33: no press-then-wait tests outside the allow-lists. Test the handlers windowlessly.
  - 57.
- **Escape stays delivered by `WindowEscapeArbiter`** (Canvas AREA rule). The mounted scrap editor currently passes Escape through. The new "Escape finishes the scrap" behaviour belongs in the scrap editor itself (e.g. `cancelOperation:` / `doCommand(by:)` on the `ScrapEditorContainer`'s text view), not in a second monitor.
- **The new handlers follow the CanvasView split's pattern:** plain per-call structs built in a `CanvasView` computed property, with the surface census kept green (`docs/superpowers/plans/2026-10-20-canvasview-split.md`).
- **Read-only canvases** (`CanvasEditGate`) refuse every creating or renaming key.
- **Shortcut list and guide:** the help's shortcut list (`Maugham/Resources/KeyboardShortcuts.swift`) and `docs/guide/getting-started.md`'s canvas sections describe what ships (CLAUDE.md rule 7). The Canvas AREA guide is near its 8,000-word cap.

## Left to the builder (Claude's calls; change if wrong)

- **Exact placement offsets** for Tab (to the right) and ⌘Return (below). Step down or right until clear. The new card joins a region by its centre, as any creation does.
- **"Nearest card in that direction":** any card (scrap or item) whose centre lies in a 90° cone in the arrow's direction, nearest first. If there is none, do nothing (no beep).
- **The chapter binding offer** (`CanvasBindingOffer`, "draw a region to bind"): keep it while nothing is bound to the chapter. Reword it so it also says a new scrap will belong to the chapter, e.g. *"Double-click or press Return to add a scrap to Chapter Three, or draw a region."*
- **Empty scraps:** whatever happens today to a scrap finished empty applies to Return, Escape, Tab and ⌘Return too. Don't invent a new rule.
- **Tab from an item card** (an image or research item) works the same: a new scrap joined to it.
- **Escape while naming a region on creation** leaves the region untitled. It does not undo the region.
