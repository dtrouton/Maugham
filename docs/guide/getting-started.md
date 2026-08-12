# Getting Started

When you launch Maugham, you'll see the Welcome window with two options: **New Project…** and **Open Recent**. Click **New Project…**.

You'll be asked to pick a project type:

- **Short Story** — a single `.md` file. Simplest shape; best for one-sitting drafts.
- **Novel** — multi-file: parts → chapters → scenes. The binder navigates the structure.
- **Screenplay** — `.fountain` files. Maugham parses Fountain syntax (slug lines, character names, dialogue, parentheticals) and shows them in the scene navigator.
- **Collection** — a project that references other projects. Useful for short-fiction collections.

Pick a type, give the project a name, choose a folder (iCloud Drive is the default — sync just works), and click **Create**.

The project opens in a three-pane window:

- **Binder** (left) — one tree: your manuscript structure, with a Research section and a Palette section at its foot, and a fold under any document that has research of its own. Drag-reorder items, right-click for menus. Trash appears as a disclosure at the very bottom once there's something in it. ⌘⌥F turns the whole column into a project-wide search; Escape brings the tree back. The tree is the same in every persona — see below.
- **Editor** (center) — the prose surface.
- **Inspector** (right) — metadata for the selected item (synopsis, status, tags, word target, linked research).

Type a sentence. Quit Maugham (⌘Q). Relaunch. Your project is in Open Recent, and your sentence is still there. That's the autosave-and-iCloud loop you'll rely on every day.

### Personas

A persona bar sits in the window's toolbar, beside the title: **Plan** (⌘1), **Author** (⌘2), **Review** (⌘3), **Publish** (⌘4). Each reconfigures all three columns around one stage of the work — Plan opens the planning canvas in the middle with your research tree beside it and the Inbox on the right, Author is the writing layout above and leads with Diagnostics, Review leads with Annotations, Publish leads with Visual Language. Nothing is required or gated: every persona is one keystroke away at any time, on any project, and switching never disables or hides your manuscript — it just changes which companion panes are offered. The bar hides along with the rest of the window chrome in focus mode (⌘\\). Each persona remembers where you left it — which right-pane mode — so switching away and back puts the right column exactly where it was, as long as the mode is one that persona offers. Modes no persona leads with behave slightly differently: ⌘⌥N / ⌘⌥V for Intent and Visual Language in Plan open and stay open — and are still there when you quit and reopen — but a persona switch lands you back on that persona's own modes. Each window remembers its own persona per project, so two windows on the same project can sit in different personas at once. See [The Right Column](right-pane.md) for which right-pane modes each persona offers.

**The left column is the same tree in every persona**, and it has no picker of its own — there's nothing to choose. Only the right column has modes to switch between; every one of those has a shortcut, so a persona that doesn't *lead* with a mode still opens it on demand — ⌘⌥E for References, ⌘⌥D for Diagnostics, and so on. Plan's own centre column is the planning canvas rather than the editor, but its left column is the very same tree Author, Review, and Publish show — the same Research section, the same Palette section, the same folds. Selecting the project row does something different depending on where you are, though: in Author, Review, and Publish it zooms the centre column out to a corkboard/table of every chapter (⌘⌥O gets you there from anywhere); in Plan it leaves the canvas exactly as it is. [Structure & the Binder](structure-and-binder.md) covers what you can do from the tree.

**Research and Palette live in the tree, in every persona** — right-click the tree, or either section's own header, to write a note or build a card wherever you are; there's no persona you have to visit first. ⌘⌥R and ⌘⌥P jump straight to those sections and expand them, from any persona — they open the tree to where you'd edit from, not a reading pane. What Author and Review give you instead is **References** (⌘⌥E): a shelf of what the open chapter is pinned to — research you've linked to it, cards you've clustered for it on the canvas — and clicking one opens it beside your prose in Author, for consulting something while you make something else. **Plan's own right column doesn't carry References for the same reason** — you don't glance at the thing you're in the middle of making. The Palette section's header also opens a door onto the palette wall — a full-window grid of every card — in Author, Review, and Publish; it's disabled in Plan, since Plan's centre column is the canvas.

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
- **A card** can become a **research note**, a **palette card**, or part of the **craft intent** — your intent lives in the Intent pane (⌘⌥N), one for the project and one for each document that wants its own, and each card you promote to it is added to the end of what is already there.
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

#### Getting things onto the canvas

Typing a scrap is the quickest way to put something on the canvas, and it is not the only one. Three other things can be dropped straight onto it, and each lands exactly where you let go of it.

- **A research note, image or folder from the binder.** Drag a row out of the research tree onto the canvas and it becomes a card showing that item's real title and kind — a *reference*, not a copy: the file stays where it is, and the canvas holds only its position. Drag the same item in twice and the second drop takes you to the card you already have rather than making another. Deleting the card never deletes the item.
- **A photograph from the Finder, or an image dragged out of a web page.** It is copied into the project — into a `canvas_assets` folder beside `canvas.md` — so the card keeps working after you have tidied up wherever you dragged it from. Drop several at once and they cascade rather than stacking, so you can see there are four.
- **A capture from your Inbox** — see below.

Anything that is not a picture is refused with a line saying so, rather than landing as a card that can never draw.

**A card that stands for something shows what it is, not a code.** Its real title, a small glyph for what kind of thing it is, and — when it is a picture — the picture. Drag its corner and it grows the way any card does; a photograph keeps its shape as it goes, so nothing is ever squashed to fit. Select one and the Inspector (⌘⌥I) names it and offers **Open in Research**, which takes you to the thing itself.

A photograph the canvas owns is the one that has no research item behind it, so there is nothing to open — the Inspector says so rather than offering a button that would take you to a folder you never chose. What you can do with it is **promote** it, which is the next section.

#### Promoting a picture

A photograph the canvas owns can become durable in either of two ways, and both are the ordinary **Promote…** (⌘⇧↩):

- **A research asset** — the picture is copied into your research, and the card wears the usual stripe to say what it became.
- **An image on a palette card you already have** — appended to that card's images, alongside whatever is already there. This one leaves no stripe on purpose: the card didn't *become* the palette card, its picture is *in* it, and the Inspector says so in those words. Promote it again and you get a second copy rather than an offer to rewrite somebody's palette card with one photograph.

**A card that stands for research you already have is not promoted at all** — it is already the durable thing, and the sheet says so rather than offering an empty list.

**Promoting a region carries the pictures in it onto the palette card**, and the sheet tells you how many before you commit. A research note is prose, so a region promoted to one is told the pictures are not coming. Re-promoting with **rewrite that one** replaces the words and leaves the card's images alone — otherwise every re-promotion would stack another copy of every photograph onto it. Each picture that went in says *This picture is in “…”* in its own Inspector, exactly as a card whose words went in says *Its words are in “…”* — including a picture that stands for research you already had, which the region copied onto the card and left where it was.

#### Giving the canvas the whole window

**⌘\\** on the canvas folds both side columns away — the binder on the left and the Inspector on the right — and leaves you the surface. Press it again and the binder comes back and the right-hand pane returns to whatever you had it at before. It is the same **⌘\\** that hides the title bar and toolbar everywhere else, and **⌘⇧F** (full-screen focus) turns it on too.

It is never automatic: you want the binder open while you are dragging research and captures onto the canvas, and out of the way once you are thinking. Switch to another mode with the canvas collapsed and the columns come straight back.

#### Sending a capture from the Inbox to the canvas

A note, voice memo or photograph captured on your phone lands in the **Inbox** (⌘⌥B). Until now the only way out of it was promoting it into research, which makes the durable thing *before* you have decided what it is. There is now a shorter road: **Inbox → canvas → research**, with promoting as the second step whenever you are ready for it.

Two ways, and they do the same thing:

- **Drag the row onto the canvas.** In Plan (⌘1) the Inbox can sit in the right-hand column with the canvas in the middle, so the two are on screen together. The capture lands where you drop it — inside a region if you drop it in one.
- **Right-click the row → Send to Canvas**, which works from the keyboard, with VoiceOver, and from any persona with the canvas nowhere in sight. It has no drop point, so the card is placed **loose, clear of everything you already have** — and never inside a region: you have already decided what the capture is, and a box you did not ask for is one more thing to delete. The pane tells you it went, and the canvas remembers to bring you to the card the next time you open Plan.

A typed note and a voice memo become an ordinary **scrap** carrying their words — the transcript, for a memo — so you can rewrite them, join them to a region, or promote them like anything else. A photograph becomes a **picture card**, copied into the project the same way a Finder drop is.

**The capture leaves the Inbox.** It is one move rather than a copy, and the row is gone from triage afterwards. A voice memo with no transcript yet is refused and stays put: transcribe it first (Edit Transcript…, or Transcribe Again) and send it then. If anything goes wrong part-way, the capture stays in the Inbox and nothing is lost.

**One ⌘Z takes the send back** — the card and its words together — but only while the canvas is the thing you are looking at. Send from another persona and there is no canvas on screen to undo on; the card is simply there when you next open Plan. Either way the Inbox row does not come back: delete the card and the capture is gone.

#### What Claude can put on the canvas

If you have Claude connected (see [Writing with Claude](claude-desktop.md)), it can **read your canvas** and **add cards to it**. This is the one place Claude puts words on a surface of yours — and it is a scratch surface, on the far side of promoting, so nothing it adds is in your manuscript and nothing gets there without you asking.

The case it is built for: you write on actual paper, photograph it with your phone, and Claude reads the page and puts what is on it onto the canvas as cards.

- **Claude cannot choose where a card goes.** There is no way for it to name a position, a card or a region — the canvas decides. Everything it adds in one go lands together in **one labelled region**, so a batch never arrives scattered across your work, and the region is placed clear of everything you have already put down.
- **When the words came off a page you photographed, that page goes in the region too**, at the top, above what was read off it — **showing the photograph itself**, so you can check what Claude read against what it made of it by looking rather than by clicking through.
- **Claude's cards are visibly Claude's, three ways.** Your cards sit at a slight angle; **Claude's are perfectly straight**, so a card that leans is one of yours. They also take a slightly cooler paper, and lines Claude drew a slightly cooler stroke. VoiceOver says *from Claude* on the card, on the region and on the page. **The page you photographed is the one card that reads across the two signals**: it is straight, because Claude put it there, and it keeps your own paper, because the words on it are yours.
- **Claude can draw lines between the cards it just added**, but never names one — a line's name is yours to write, or to leave off. And it cannot draw a line to a card of yours.
- **You are told when a batch arrives**, by a line at the top of the window naming the count and the region. **Show** takes you to Plan, opens the Inspector and brings the region on screen; it fades on its own if you'd rather carry on.
- **One ⌘Z takes back a whole batch** — the region, the page, every card and every word of it, in one keystroke. It is one arrival, so it is one undo.
- **From there it is yours, exactly like anything else on the canvas.** Move it, rewrite it, delete it, or **promote** it. There is no queue to approve and nothing to accept: the canvas is scratch, and the marking is what makes leaving it there a real choice rather than a default. A card stays marked as Claude's even after you have rewritten every word of it — the mark says who put it there, which is a fact about what happened.
- **Promoting is still the only way any of it becomes durable**, on the same terms as your own cards: a note, a palette card, a line in your craft intent, and never without the sheet.

### Troubleshooting: a document that won't open

Manuscripts are stored as a history — an append-only log under `.maugham/ops/` — and the `.md` you see is rendered from it (see [The Editor & Focus](editor-and-focus.md)). If a piece of that history can't be read — a permissions problem, something else in the way of the file, an iCloud file that hasn't finished downloading — Maugham never shows you an empty document or an endless "Loading…". It refuses to open, names exactly what's wrong, and offers a way forward:

- **iCloud hasn't downloaded it yet.** This is the common case on a machine you've just switched to. Maugham asks iCloud to download the file and waits — there's nothing for you to do — and the moment it's readable, the document opens normally, editable, with no extra step.
- **A file is unreadable for another reason** — a permissions break, or something else got in the way. The pane names the file and says why. Three things are offered: **Open Read-Only**, which shows you everything the rest of the history can reconstruct — read it, copy from it, confirm nothing important is missing — while typing is refused and a banner reminds you the view can't be saved from; **Set the File Aside and Keep Writing**, described below; and **Restore from Backup…**, which opens the usual restore window. Fix the underlying problem — repair the permissions, or move whatever is in the way out of the folder — and a banner across the top of the read-only view offers to reopen the document editable, with everything intact — it never reopens on its own out from under you.
- **Set the File Aside and Keep Writing.** If you'd rather not wait — you want to write now, and you can sort out the broken file later — this moves the unreadable piece of history somewhere safe (never deleted, just kept out of the way) and opens the document fully editable from the rest. You can reach the same offer from the read-only view above: try to type, and the banner offers to set the file aside right there, so you don't have to back out first. Once it's set aside, the History pane shows a standing note that part of this document's history is kept aside, with a **Retry** button whenever you want Maugham to check again. Retrying happens automatically too, every time you open the document — you don't have to remember. When the file reads cleanly again, Maugham merges it back in: anything you wrote after setting it aside wins wherever the two versions touch the same passage, and anything the recovered history had that your draft doesn't is reported to you — a count in the History pane, with a **View** button to see it and an **Append to End** to add it back as ordinary new text (undo-able like anything else you type). If nothing was missing, the History pane just says so — and if the file still can't be read, it says that too, with the reason, so a Retry never leaves you wondering whether the button worked.
- **The history folder itself can't be listed.** Rarer, and more serious — there's nothing to read even partially, and nothing can be set aside either, because there's no single file to move — the folder itself is the problem. Restore from a backup is the way forward here.

In every case: your words are not gone. The refusal is Maugham declining to guess at a manuscript it can't fully read, not a sign anything has been lost.

