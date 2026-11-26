# Notes & Suggestions

A note is something raised about your text: a comment, a question, a craft note, or a suggested change to a span of words. Claude leaves them; so do the editors who run your rounds, a reviewer you let into the book, and you. All of them wait in [To resolve](right-column.md#to-resolve-1) (⌘1), grouped under the paragraph they are about. Nothing Claude writes is drawn on your page. To see where people's notes sit, turn on [the margin](editor-and-focus.md#the-margin).

### Leaving a note yourself

Select some words, then choose **Edit ▸ Comment…** (⌘⇧K), or right-click the selection and choose **Comment…**. A one-line composer opens above the words; type and press Return. Your note is signed with **Your name (for review comments)** from Settings (⌘,) → General, or your macOS account name if that is blank.

Where you may not change the words — someone else's chapter, or one of yours in read-through — the right-click, and a small toolbar over the selection, also offer **Suggest…** (it starts with the words you selected, for you to edit into the replacement you'd want), **Query…** and **Translator's Note…**. Where you may change the words, you'd change them yourself, so Comment… is the one offer.

### Read-through

Sometimes you want to read a chapter as a reviewer would: leave notes for yourself, and not touch the text yet. **View ▸ Start Read-through** (⌘⌥⇧R), or the padlock in the toolbar, does that for the chapter open in the centre.

- **Typing is off; decisions are on.** You can't type, paste, drag text or Replace in it. You can comment, suggest, answer a note, accept, reject and resolve, including the answers that change the text.
- **It starts with a checkpoint**, named with the chapter — *Read-through, 22 Nov — Chapter Three* — so the version you are reading is kept. History can compare with it and go back to it.
- **It is the chapter's, and this Mac remembers it.** Click another chapter and it opens as it was. Quit and reopen, and the chapter is still in read-through. Your phone and your other Macs don't know about it.
- **Its research is held still too**, against your own accidents: see [Research → Moving research](research.md#moving-research). Claude can still write to it, and renaming another chapter still updates the links to it inside this one.
- **People's notes show as cards in the margin** beside their words. Claude's stay in To resolve.
- A line over the text says *In read-through · typing is off*, with **Resume writing**. Press it, the padlock, or ⌘⌥⇧R again (**View ▸ Resume Writing**) to type again.

You can't start a read-through while reading a translation: *Read Source to start a read-through.*

**In somebody else's book, the text may not be yours to type in.** If the book's owner let you in as a *reviewer* — or you write some chapters and this isn't one of them — the text is locked, and a line above it says why. Notes are the whole of what a reviewer adds to another writer's text, by design (see [People & Devices](people-and-devices.md#what-their-mac-shows-them)). A folder shared with you **read-only** through iCloud locks the text too, because the file can't be saved.

### Suggestions

A suggestion proposes new words for a span or a whole paragraph. It waits in To resolve with its replacement shown.

**Accept** — Applies the suggestion to your manuscript. The status changes to **Accepted** and the row dims.

**Reject…** — Dismisses the suggestion without changing your text, after asking you why. Status changes to **Rejected** and it moves to **Settled**.

**Stet** — The proofreader's mark, and the fourth answer. You read it, you considered it, and the words stand. Nothing is applied and nothing is refused; the note is answered, and the status changes to **Stetted**. Use it where **Reject** would overstate the case — the suggestion wasn't wrong, you just aren't taking it. The row flashes a **STET** badge for a couple of seconds before it leaves the open list.

**Archive** — Moves the suggestion out of the active list without accepting or rejecting it. Status changes to **Archived**.

Stet is offered on comments, queries and craft notes too, wherever Archive is.

**Undo an accepted suggestion** — Press **⌘Z** (or use **Edit → Undo Accept Suggestion**). The suggestion returns to **Open** status and the text reverts. Redo with **⌘⇧Z** to re-apply it (the redo re-arms another ⌘Z, so you can cycle back and forth).

Accepted suggestions can also be reverted at any time: open **Settled** at the foot of To resolve and press **Revert** on the suggestion. Accepting a *second* suggestion clears ⌘Z's reach back to the first one — that's specific to accept (each accept starts a fresh typing-undo baseline), so Revert is the way to reach an older accepted suggestion once a newer accept has happened. No other undoable action in Maugham has this one-deep limit — see below.

If Maugham has already applied a suggestion's change and it is still in the text when you press **Accept**, Maugham marks the suggestion **Accepted** and leaves the text alone: a change it has already applied is not applied again.

This happens when another device archived or stetted the suggestion just after you accepted it and you then reopened it, and, almost always, when restoring a checkpoint with **Revert here…** or rewinding the document brought the change back. The same goes for a suggestion that replaces a whole paragraph when you had already typed the paragraph the way the suggestion reads.

A suggestion for part of a paragraph that you typed in yourself, and never accepted, is different: Accept applies it as written, on top of what you typed. ⌘Z on such an Accept reopens the suggestion and leaves the text as it is; **Revert** still puts back the words from before the accept, and on an accept you made by typing it reopens the suggestion and leaves your text.

### Notes on tables and pictures

Claude can leave the same kinds of note on a figure: a comment, a question or a craft note on the whole figure (a picture too), and a comment or question on one cell or a range of cells in a table. It can also suggest a new number or formula for one table cell. The note anchors to the cell's row and column, not to a position, so it follows the cell when rows or columns are inserted. If the cell's row or column is deleted the note is marked orphaned, and it comes back if you undo the delete.

These notes appear in To resolve like any other, and the figure's details list each one with its address (*C3*, *C3:E3*). From To resolve each answers as its kind does: **Got it** on a comment, **Reply…** on a question, **Accept** or **Reject…** on a craft note, **Reject…** on a suggested value; and **Stet** or **Archive** on any of them. A settled one comes back with **Reopen**. A suggested value to a cell shows its proposed value.

There, **Accept** opens the table and selects the cell (a table already open selects it there); accept it there in the suggestion strip, which writes the value into the cell as you, with the suggestion's attribution recorded. A table kept in Research shows Accept greyed out with "In Research — bring it back to accept", and a deleted cell greys it with its reason. Clicking a figure note's row, or its line in the figure's details, opens the table and selects the cell the same way.

A cell with an open note shows a small dot in the assistant-note colour, on the card and in the grid; a note on a range puts its dot on the range's top-left cell, and a note whose cell has been deleted stays in To resolve with no dot.

**The strip.** Selecting a marked cell in the grid shows a strip above it, with the cell's note and its answers. The strip's room appears only while the table has an open note on a cell. It answers to the mouse only.

- **A suggestion** offers **Accept** and **Reject**; **a comment or query** offers **Got it** and **Reject**. When several notes cover the cell, the strip pages through them (*1 of 2*).
- **Accept** asks first if the cell has changed since the suggestion was made. If the cell already holds the suggested value, Accept marks the note accepted and writes nothing to the cell, and ⌘Z reopens it and leaves the cell.
- **Reject** asks for a reason.
- **To take the value by hand**, type it into the table, then **Archive** the note: typing the value leaves the note open.

**When the table can't be changed:**

- **In read-through** the strip keeps all its answers: an Accept is a decision, and it writes the value into the cell though typing is off.
- **Parked in Research, a view-only share, or someone else's table:** the strip shows its notes with no buttons and says why. For someone else's table it says *This table isn't yours to change — you can read it.*
- **Where this Mac may not answer the figure's notes**, the buttons are greyed: *This Mac may not answer notes on this figure.*

**Taking an answer back.** While the table is open in this window, ⌘Z in the grid undoes a strip answer, and the note returns to how it was. After the grid has been folded away, ⌘Z in the window takes an Accept back along with the visit. A Reject or Got it made after folding is reversed with **Reopen** in Settled.

**Elsewhere.** A note on a figure that belongs to a chapter counts toward that chapter in the Book's Status, and sits with its notes in To resolve. On the iPhone, a figure note shows its anchor and the suggested cell and offers Reject and Archive. A cell with an open note shows its dot on the phone's card (the phone has no strip). Promoting a Collection piece to its own project does not carry its figures' notes.

### Marking a pile — triage

A long list is easier to answer once it's sorted. Each note's flag menu marks it **Do**, **Discuss** or **Decline**, or **Clear**s the mark. A mark is a plan, not an answer: a marked note is as open as it was. Notes marked **Do** lead their group. Once any note carries a mark, a control at the top of To resolve filters by it — **All**, **Do**, **Discuss**, **Decline** or **Untriaged** — alongside the source chips.

**Answer as ruling…** appears on some notes beside the ordinary reply, and where it files depends on who raised the note. A translator's question about one edition files into that edition's brief; a note from [your own first reader](compiler.md#your-own-first-reader) files as a standing instruction in hers, under **Instructions**. Either way your answer lands twice — there and as your reply — and the note leaves the list.

### Working a batch

Press the checklist button at the top of To resolve (*Select notes*). Each note gets a tick box, and a bar appears with three verbs:

- **Triage** — the same marks as a row's flag menu (*"Mark what you plan to do about all of these"*).
- **Accept** — answers the notes at once.
- **Stet** — *"Read, considered — and the words stand. Resolves these without applying or refusing anything."*

Tick the notes you mean. If you tick none, the verbs act on everything the list is showing, so your filters choose the batch. **Select All** ticks every row, and becomes **Deselect All** once something is ticked. Press the checklist button again (*Done selecting*) to leave.

**Each button says how many notes it will reach** before you press it: *Accept all 6*, *Accept 4 selected*, or *Accept 4 of 6* when some are out of its reach. A bulk verb reaches exactly the notes the same button on each row would reach:

- **Accept** reaches open notes only. It never answers a question, because a question wants your words. It never applies a suggestion whose passage you've changed since, because that row would ask you first. Those notes stay open for you to answer one by one.
- **Stet** reaches open notes.
- **Triage** reaches every note that doesn't already carry that mark.

If anything in the batch can't be done, one notice says so — *Not everything in the batch could be done* — counting what landed (*"3 of 4 accepted."*) and saying why the rest didn't.

**One ⌘Z reverses the whole batch**, each note back to how it was. Suggestions are the exception (see [Suggestions](#suggestions)): ⌘Z reaches only the last suggestion a batch accepted, and **Revert** reaches the others.

A batch works on the chapter open in the centre. In a Part's or the Book's list it reaches only that chapter's notes; open another chapter to work its pile. Where this Mac may answer none of the notes, there's no bar at all.

### Undoing reject, archive, and your own notes

Reject, archive, and the other non-text-mutating annotation actions are undoable the same way as anywhere else in Maugham: **⌘Z** reverses the most recent one, and each ⌘Z you press walks one step further back, exactly like undoing typed edits. **⌘⇧Z** redoes forward again, and redoing re-arms the action so you can keep cycling ⌘Z ⟷ ⌘⇧Z.

- **Edit → Undo Reject Note** — reopens a rejected suggestion.
- **Edit → Undo Accept Note** — reopens a comment, query, or craft note you accepted (the **Got it** button, or **Reply…** with your answer). Nothing was applied to your words, so nothing has to be put back — the note simply returns to **Open**. Accepting a *suggestion* is the different case, with its own **Undo Accept Suggestion**, above.
- **Edit → Undo Stet Note** — reopens a note you let stand — and if you had already accepted, rejected or archived it before, puts that back.
- **Edit → Undo Triage Note** — puts back the mark the note carried *before* the one you just applied, rather than clearing it. Marking a note **Do**, changing your mind to **Discuss** and pressing ⌘Z leaves **Do** standing.
- **Edit → Undo Archive Note** — reopens an archived comment, query, craft note, or suggestion.
- **Edit → Undo Withdraw Note** — if you withdrew your own note or suggestion, ⌘Z brings it back.
- **Edit → Undo Edit Note** — if you edited the body (or, for a suggestion, the proposed replacement) of a note you authored, ⌘Z restores the prior wording.

Every one of these appends a **compensating** entry to the document's history rather than erasing the original action — open the chapter's **History** (⌃⌘H) and you'll see both the original resolution and its undo listed as separate events. Undo never rewrites history; it only adds to it.

#### When an undo can't be done

Now and then ⌘Z declines rather than guess. That happens when a note has changed somewhere else since you acted on it — answered or edited on your iPhone or another Mac — or when this Mac may no longer write that kind of thing in this piece. In a batch, whatever can be undone is undone, and the rest is left as it is. A message at the foot of the window says what couldn't be undone and why, in one sentence however many notes it covers, for example:

- *"Couldn't undo stetting 2 notes — they changed on another device."*
- *"Couldn't change 2 notes — this Mac can no longer answer notes here."*

The same goes for to-dos, a History restore and an accepted suggestion: if this Mac may no longer change that piece, the undo says so instead of quietly doing nothing. Whatever was declined is still in To resolve, and you can answer it from there.

### Rewinding with suggestions

If you open **History** and rewind to a point *before* you accepted a suggestion, that suggestion reopens in the **Open** status. The manuscript reverts to what it was before the accept.

If the rewind also removed the paragraph the suggestion was attached to, the suggestion is archived instead — there's nothing left for it to apply to. If it was accepted, **⌘Z** on that rewind brings it back as **Accepted**, not Open.

It works the other way too. Say you accepted a suggestion, later pressed **Revert** on it, and then rewind (or **Revert here…** to a checkpoint) to a point after the accept. The accepted text comes back, and the suggestion is marked **Accepted** again rather than offering you an Accept you've already made. A Stet, reject or archive you gave it after that point stays as you left it.

If you rewind to before a suggestion was added, it disappears from To resolve entirely.

**Undoing a Rewind restore** — a History Rewind is itself undoable. Press **⌘Z** right after restoring to an earlier point and Maugham reverses the *whole* rewind in one grouped action: the manuscript text returns to where it was before you rewound, and any suggestions the rewind reopened or archived along the way go back to how they were. **⌘⇧Z** re-runs the same rewind from scratch, so redoing a rewind can never disagree with a fresh one.

### Comments

Comments are notes that propose no change — questions, observations, context. Click one to read all of it.

Notes can be archived via their context menu (•••) and restored from the Trash if needed, or reopened with ⌘Z right after archiving (see above).

### Reopening from iPhone

The Maugham Companion iPhone app can't run Claude, but it can review and resolve the annotations Claude has already left, and re-open ones you resolved by mistake:

- **Reject or Archive → Reopen** — tap **Reopen** on a resolved note or suggestion in the detail view. It returns to **Open**, exactly as if you had pressed ⌘Z on the Mac.
- **Accept → Reopen & Revert** — an accepted suggestion has no plain reopen; tapping **Reopen & Revert** restores the pre-accept text *and* reopens it. If the paragraph has changed since the accept (edited on another device, say), the phone asks you to confirm before overwriting the current text.

Either way, the phone's reopen is written to the same history the Mac reads — open the project on your Mac afterward and the note shows **Open** there too, with the reopen visible as its own entry in History.

**If the phone's notes aren't showing up on the Mac, the Mac hasn't been told who the phone is yet.** Open the project there and it asks you, once; see [People & Devices](people-and-devices.md). The phone's own **Settings → This device** section shows where it stands in each book it has been in — *on Alex's MacBook's chain since 9 Sep*, or *Not yet admitted — the Mac will ask* — plus the four-character code you check against the Mac's panel. Nothing is lost while you're waiting: the phone's work is held, not discarded, and admitting the phone brings all of it in at once.

### Claude's `add_suggested_change` tool — two grains

When Claude uses the `add_suggested_change` tool, the grain of the suggestion depends on whether you provide a quote:

- **No `quote`** — The `suggested_text` is the complete replacement for the entire paragraph. Use this for wholesale rewrites.
- **With `quote`** — The `quote` field must contain a span of text from the target paragraph. The `suggested_text` then replaces *only that span*, preserving the rest of the paragraph. The suggestion shows the change against just that span.

Pair the grain to the job: a tiny typo fix uses a quote; a full-paragraph revision omits it.
