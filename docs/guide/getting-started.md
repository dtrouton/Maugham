# Getting Started

When you launch Maugham, you'll see the Welcome window with two options: **New Project…** and **Open Recent**. Click **New Project…**.

You'll be asked to pick a project type:

- **Short Story** — a single `.md` file. Simplest shape; best for one-sitting drafts.
- **Novel** — multi-file: parts → chapters → scenes. The binder navigates the structure.
- **Screenplay** — `.fountain` files. Maugham parses Fountain syntax (slug lines, character names, dialogue, parentheticals) and shows them in the scene navigator.
- **Collection** — a project that references other projects. Useful for short-fiction collections.

Pick a type, give the project a name, choose a folder (iCloud Drive is the default — sync just works), and click **Create**.

The project opens in a three-pane window:

- **Binder** (left) — the project structure (manuscript / research / find / trash). Drag-reorder items, right-click for menus.
- **Editor** (center) — the prose surface.
- **Inspector** (right) — metadata for the selected item (synopsis, status, tags, word target, linked research).

Type a sentence. Quit Maugham (⌘Q). Relaunch. Your project is in Open Recent, and your sentence is still there. That's the autosave-and-iCloud loop you'll rely on every day.

### Personas

A persona bar sits in the window's toolbar, beside the title: **Plan** (⌘1), **Author** (⌘2), **Review** (⌘3), **Publish** (⌘4). Each reconfigures all three columns around one stage of the work — Plan opens the planning canvas in the middle with your research tree beside it, Author is the default writing layout above, Review leads with Annotations, Publish leads with Translation. Nothing is required or gated: every persona is one keystroke away at any time, on any project, and switching never disables or hides your manuscript — it just changes which companion panes are offered. The bar hides along with the rest of the window chrome in focus mode (⌘\\). Each persona remembers where you left it — which binder segment and which right-pane mode — so switching away and back puts both columns exactly where they were. Each window remembers its own persona per project, so two windows on the same project can sit in different personas at once. See [Inspector, Research & Outline](right-pane.md) for which right-pane modes each persona offers.

### The planning canvas

Plan (⌘1) puts a **canvas** where the editor usually sits — a place to think before anything has firmed up. It is deliberately scratch: most of what lands on it will never become anything, and that's the point.

- **Double-click empty space** to drop a new scrap, and type straight into it. There's no title, no schema, nothing to fill in.
- **Drag a scrap** to move it. Let go with some speed and it carries a little before coming to rest, the way a card put down on a desk does.
- **Drag the bottom-right corner** to make a scrap wider or narrower. The text rewraps; the card grows and shrinks to fit what you've written.
- **Scroll to pan, pinch to zoom.** Zoom stays crisp all the way in and out. Cards sit at a slight angle — the one you're editing straightens itself while you write in it, and leans back when you leave.

Your scraps are saved as you type, into a plain `canvas.md` file at the top of the project — readable in any text editor, like everything else Maugham writes. Where the cards sit is kept separately, as scratch layout; deleting that never costs you a word.

**⌘Z on the canvas.** Outside a scrap, ⌘Z undoes a whole action — a move comes back to where it started, not frame by frame. *Inside* a scrap, ⌘Z takes back roughly **a sentence at a time**, or the run of typing since you last paused, rather than a single word. Press it again for the sentence before that.

Regions, connecting lines, dragging research onto the canvas, and turning a scrap into a real chapter or note are all still to come.
