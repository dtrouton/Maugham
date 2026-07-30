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
- **Select a card with a single click**, and press **⌫** to delete it. ⌘Z brings it back, with its words.

Your scraps are saved as you type, into a plain `canvas.md` file at the top of the project — readable in any text editor, like everything else Maugham writes. Where the cards sit is kept separately, as scratch layout; deleting that never costs you a word.

**⌘Z on the canvas.** Outside a scrap, ⌘Z undoes a whole action — a move comes back to where it started, not frame by frame. *Inside* a scrap, ⌘Z takes back roughly **a sentence at a time**, or the run of typing since you last paused, rather than a single word. Press it again for the sentence before that.

#### Regions

A **region** is an area you draw around cards that belong together — an act, a strand, a chapter's worth of material.

- **Drag on empty canvas** to draw one. A dashed outline follows your pointer, and on release it becomes a washed rectangle with a label bar along the top. **Any card whose middle is inside the area you swept joins the new region** — drawing a box around five cards is how you say those five belong together. A card you only clipped the edge of stays out, and a card that already lived in another region **moves to the new one**: a card lives in one place, and drawing a box around it is you saying where.
- **A new scrap made inside a region joins it too.** Double-click on empty space within a region and the card it makes is a member.
- **Drag a card so its middle lands inside** to put it in. Drag it out and drop it somewhere else and it moves to that region instead; drop it on bare canvas and it stays where it is *and stays a member*. Leaving is its own decision, not a side effect of where you parked something. If a card ends up sitting outside the region that holds it, a faint line is drawn between the two so you can see the relationship you actually have.
- **Drag the label bar** to move the region, and the cards that live in it travel with it. One ⌘Z puts the whole thing back. Drag the bottom-right corner to resize it. **Moving and resizing never change who belongs**: a region dragged over a card does not swallow it, and one resized past a card does not drop it. Drawing is where you say what belongs together; after that, membership only changes when you say so.
- **Click the label bar** to select the region. The Inspector (⌘⌥I) is where you name it, and where the rest of this lives.

**Living in a region and appearing in one are different things**, and the Inspector lists them separately. A card **lives** in exactly one region — that's the region it travels with, and the one that counts it as its own. A card can also **appear** in another: a reference to the card, not a second copy of it, drawn on the canvas as a small chip hairlined back to the real one so there's never a question about which is the actual card. **To cite a card here, use "Cite a Card" under "Appears here"** and pick it from the list — it stays exactly where it is, and keeps the region it lives in. The minus button on a row takes a card out of a region; the card itself stays on the canvas.

**Collapse** a region (the toggle in the Inspector) and the cards that live in it are put away — the label says how many, and the space they occupied is yours again. Expand it and they come back exactly as they were.

**Associate a region with a piece** using the **Piece** picker, and you're saying: this material is for that chapter. The association follows the piece through a rename, and it does two things — the cards that live here become the pinned references beside the piece when you write it, and **a note promoted from this region, or from a card that lives in it, lands in that piece's research** rather than in the project's. See [Promoting](#promoting) for the second half.

**Deleting a region never deletes cards.** ⌫ with a region selected, or the Delete Region button in the Inspector, removes the region and leaves every card on the canvas. ⌘Z brings the region back with its membership intact.

#### Lines

A **line** joins two cards that have something to do with each other. What that is, is yours to say — or to leave unsaid.

- **Click a card, and a small mark appears on its right edge.** Drag from that mark to another card to draw a line between them. Once you know the gesture is there, **⇧-drag from any card** does the same thing without selecting it first.
- **Click a line to select it.** The Inspector (⌘⌥I) is where you name it, and the name is drawn on the line itself. Clear the field and the name comes off again.
- **⌫ removes a line and leaves both cards where they are.** Deleting a *card*, on the other hand, takes its lines with it — one ⌘Z brings back the card, its words and its lines together.
- **Where a line crosses a region's label bar, the click goes to the line**, because the line is the thing drawn on top. Click the same bar a little to one side and you get the region.

Lines are scratch, like everything else on the canvas: they live here, they cost nothing to be wrong about, and they are not the durable relationship layer. [[Wiki-links]] are — and promoting is how you get from one to the other.

#### Promoting

Everything above is scratch. **Promoting** is the one step that turns a piece of it into something durable — a real note, a palette card, a line in your craft intent — and it is always something you ask for. Nothing on the canvas promotes itself because it sat there long enough or looked like something.

- **Select a card, a region or a line and press ⌘⇧↩** — or use the **Promote…** button in the Inspector (⌘⌥I), or **File → Promote…**. All three are the same command.
- **A card** can become a **research note**, a **palette card**, or part of the **craft intent** — the craft intent is one document per project (or per piece, in a Collection), and each card you promote to it is added to the end of what is already there.
- **A region** can become a **research note** made from the cards that live in it — joined in the order they sit on the canvas, top card first — or a **palette card** the same way.
- **A line** can become a **[[wiki-link]]**, written into the note the first card produced.
- **A sheet opens first, and nothing is written until you say so.** It names what will be produced, where it will go, and what will not come across — promoting a region does not carry its lines or its layout. Where the thing you are making has a name of its own — a research note, a palette card — you can edit that name before committing. A wiki-link and a craft intent don't ask, because neither is named by you.
- **When it's done, a line at the top of the window says what it produced**, and how many notes were linked if you accepted the offer. It fades on its own.

**Where a note goes is what the Piece picker decides.** A region has one, and so does a card — both in the Inspector. Promote something associated with a piece and the note lands in that piece's research. A card with no piece of its own **follows the region it lives in** — not one it merely appears in — and a card in no region goes to the project's research, which is the ordinary case and not a fallback. **Setting a region's piece never reaches inside it**: if you've given a card its own piece, that one wins. The card's Inspector always says which you're getting, and marks the answer *(from its region)* when it's inherited.

What that means on disk depends on the project, and **the sheet says which before you commit**. In a **Collection**, a piece keeps its own research folder, so the note is filed there and travels with the piece. In a **novel**, research is shared across the book: the note goes to the project's research and is **linked** to that chapter. In a **short story or a screenplay** there's only one document, so everything in research already belongs to it — the note goes there and needs no link. A **palette card** is never filed under a piece, because the palette belongs to the whole project; where a link would be written, the card gets one.

**If the piece has gone** — deleted, or turned into a reference to another project — the sheet refuses instead of quietly filing the note somewhere else. If the association came from the region rather than the card, it says so, because that's the picker you'd have to fix it in.

**Promoting takes a copy.** The card stays on the canvas with its words, and the two go their own ways from there: edit the card afterwards and the note doesn't change, edit the note and the card doesn't. That is deliberate. Promoting a region joins six cards into one note while all six stay where they are, and a card had to work the same way for the word *promote* to mean one thing.

A promoted card wears a **thin stripe down its left edge**, and a promoted region wears one along its label bar, so you can see at a glance what has already produced something. Select it and the Inspector says what it became, with an **Open** button that takes you there.

**When you promote a region, every card whose words went into the note says so too.** Select one and its Inspector reads *Its words are in “Act II fog”*, with its own **Open** button — a different sentence from *Became*, because that card didn't produce the note, it's part of it. A card you left empty had nothing to contribute and says nothing. If you'd already promoted that card on its own, the Inspector says **both**: what it became, and what it is part of. They're two different facts and neither hides the other.

**Promoting a card that is part of a region's note always makes something new.** It never offers to rewrite that note — one card's words are not the six cards' note, and quietly replacing it with them would be the worst thing this could do. The Inspector says so under the line, before you reach for **Promote…**.

**Promote the same thing again** and the sheet says what it made last time and asks: **rewrite that one**, or **make a new one**? Neither is picked for you. Rewriting quietly would eat edits you made in the note; always making a new one leaves you with *The falls at night 2*, *… 3*, and two orphans you didn't ask for.

**Rewriting a region's note follows whoever is in the region now.** Drag a card out, drop another in, promote again with **rewrite that one**: the note is written from the cards that are there, so the card that left stops claiming it and the one that arrived starts. And if you delete the note afterwards, the cards say what they went into is no longer in the project rather than pointing at nothing.

**A line only promotes once both of its cards have.** If they haven't, the sheet says so and tells you why rather than offering an empty list: a `[[wiki-link]]` has to point at something that exists outside the canvas, and a canvas line is scratch. Wiki-links are the durable layer; lines are the thinking. That is the order, and promoting is the step between them.

**⌘Z after a promotion takes back the mark, not the note.** The stripe comes off the card and the note stays in your research tree — the canvas's undo is about the canvas, and the note is a real file with a life of its own now. Delete it the way you delete any other note. **One ⌘Z after promoting a region takes back the region's stripe and every one of its cards' *Its words are in…* lines together**, because they were all written by the one act.

**A promoted line is the exception, and it is worth knowing before you press ⌘Z.** A line leaves no stripe — what it produced is a `[[wiki-link]]` inside somebody else's note, and a flag on the line could disagree with the file — so there is nothing on the canvas to take back and **the promotion puts nothing on the undo stack at all**. Press ⌘Z after promoting a line and you will undo whatever you did on the canvas *before* it. To remove the link, open the note and delete the line of text.

#### What Claude can put on the canvas

If you have Claude connected (see [Writing with Claude](claude-desktop.md)), it can **read your canvas** and **add cards to it**. This is the one place Claude puts words on a surface of yours — and it is a scratch surface, on the far side of promoting, so nothing it adds is in your manuscript and nothing gets there without you asking.

The case it is built for: you write on actual paper, photograph it with your phone, and Claude reads the page and puts what is on it onto the canvas as cards.

- **Claude cannot choose where a card goes.** There is no way for it to name a position, a card or a region — the canvas decides. Everything it adds in one go lands together in **one labelled region**, so a batch never arrives scattered across your work, and the region is placed clear of everything you have already put down.
- **When the words came off a page you photographed, that page goes in the region too**, at the top, above what was read off it. So you can see what Claude read and what it made of it in one place. *For now the page shows as a placeholder card carrying its reference — the picture itself arrives with the rest of the image work.*
- **Claude's cards are visibly Claude's, three ways.** Your cards sit at a slight angle; **Claude's are perfectly straight**, so a card that leans is one of yours. They also take a slightly cooler paper, and lines Claude drew a slightly cooler stroke. VoiceOver says *from Claude* on the card, on the region and on the page. **The page you photographed is the one card that reads across the two signals**: it is straight, because Claude put it there, and it keeps your own paper, because the words on it are yours.
- **Claude can draw lines between the cards it just added**, but never names one — a line's name is yours to write, or to leave off. And it cannot draw a line to a card of yours.
- **You are told when a batch arrives**, by a line at the top of the window naming the count and the region. **Show** takes you to Plan, opens the Inspector and brings the region on screen; it fades on its own if you'd rather carry on.
- **One ⌘Z takes back a whole batch** — the region, the page, every card and every word of it, in one keystroke. It is one arrival, so it is one undo.
- **From there it is yours, exactly like anything else on the canvas.** Move it, rewrite it, delete it, or **promote** it. There is no queue to approve and nothing to accept: the canvas is scratch, and the marking is what makes leaving it there a real choice rather than a default. A card stays marked as Claude's even after you have rewritten every word of it — the mark says who put it there, which is a fact about what happened.
- **Promoting is still the only way any of it becomes durable**, on the same terms as your own cards: a note, a palette card, a line in your craft intent, and never without the sheet.

Dragging research onto the canvas is still to come.
