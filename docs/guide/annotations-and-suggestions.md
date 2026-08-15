# Annotations & Suggestions

Claude can add two kinds of annotations to your manuscript: text notes (comments) and suggested changes (edit proposals). Both appear in the **Annotations pane** (⌘⌥A). You can leave annotations yourself too — that's Review Mode, below.

### Review Mode — reading your own draft cold

**View → Toggle Review Mode (⌘⌥⇧R)** puts the editor into an annotate-only posture. Your manuscript goes **read-only**: you can select, scroll and copy, but you can't type into it. A **REVIEWING · your name** pill appears at the top of the text column, and it stays visible even in focus mode (⌘\\) — with the rest of the chrome gone, the pill *is* the chrome telling you which posture you're in.

The point is to stop you fixing things. Select a span and a small toolbar appears above it with three buttons — **Comment**, **Suggest**, **Query** — each opening a one-line composer right there. Comment and Query start empty. Suggest starts pre-filled with the text you selected, and you edit it into the replacement you'd want; what lands is a suggestion against that exact span, the same shape Claude's `add_suggested_change` produces, and you accept or reject it later the same way. Everything you write this way goes into the Annotations pane alongside Claude's, attributed to **Your name (for review comments)** from Settings (⌘,) → General — your macOS account name if you've left it blank.

Press ⌘⌥⇧R again to leave. Nothing is lost either way — the annotations are ordinary annotations.

**On a manuscript shared for review, this isn't yours to choose.** If Maugham resolves you as a *reviewer* on someone else's shared project rather than an author, Review Mode is forced on and the read-only lock is a floor, not a posture: ⌘⌥⇧R still flips the review chrome, but it can never unlock the text. Annotating is the whole of what a reviewer can do to another writer's manuscript, by design. The same holds for the moment before Maugham has worked out who you are — it starts locked and opens up once your role resolves, rather than offering you editing affordances and snatching them back.

**Not to be confused with the Review persona (⌘3)**, which is a window layout — it leads with the Annotations pane, and it does *not* turn Review Mode on. The two are independent; ⌘⌥⇧R works in any persona.

### Suggestions

A suggestion is Claude's proposal to change a span of text or an entire paragraph. When Claude adds a suggestion, it lands in the **Open** status and appears as a margin card in the editor. Click to review the proposed change.

**Accept** — Applies the suggestion to your manuscript. The status changes to **Accepted** and the card dims.

**Reject** — Dismisses the suggestion without changing your text. Status changes to **Rejected** and it moves to the resolved filter.

**Stet** — The proofreader's mark, and the fourth answer. You read it, you considered it, and the words stand. Nothing is applied and nothing is refused; the note is answered, and the status changes to **Stetted**. Use it where **Reject** would overstate the case — the suggestion wasn't wrong, you just aren't taking it. The row flashes a **STET** badge for a couple of seconds before it leaves the open list.

**Archive** — Moves the suggestion out of the active list without accepting or rejecting it. Status changes to **Archived**.

Stet is offered on comments, queries and craft notes too, wherever Archive is — from the Annotations pane and from the margin card in the editor.

**Undo an accepted suggestion** — Press **⌘Z** (or use **Edit → Undo Accept Suggestion**). The suggestion returns to **Open** status and the text reverts. Redo with **⌘⇧Z** to re-apply it (the redo re-arms another ⌘Z, so you can cycle back and forth).

Accepted suggestions can also be reverted from the **Annotations pane** at any time — turn on the show-resolved filter (the tray icon) and click **Revert** on the accepted suggestion. Accepting a *second* suggestion clears ⌘Z's reach back to the first one — that's specific to accept (each accept starts a fresh typing-undo baseline), so the pane's Revert is the way to reach an older accepted suggestion once a newer accept has happened. No other undoable action in Maugham has this one-deep limit — see below.

### Working the queue — triage and order

A pile of notes is easier to answer once it's sorted, so every row in the Annotations pane carries a small flag menu: **Do**, **Decline**, **Discuss**, and **Clear**. That's a *mark*, not an answer — a triaged note is exactly as open as it was, and marking one settles nothing. What it changes is where the note sits.

Everything you've marked **Do** leads the list. Behind it comes everything else, in the order the notes appear in your manuscript, so working down the pane is one pass down the text rather than a scatter of jumps. Notes that aren't anchored to a paragraph (craft notes are about the whole document) sit at the end of their own group, as do notes whose paragraph you've since deleted.

The toolbar's flag menu filters by mark — **All**, **Do**, **Decline**, **Discuss**, or **Untriaged** — so you can take one band at a time, or find what you haven't looked at yet. It stacks with the kind, author and show-resolved filters beside it.

Triage lives in the pane only. The margin cards in the editor answer one note beside the sentence it's about; there's no pile there to sort.

### One piece, or the whole project

The pane's scope menu switches between **This Piece** and **All Pieces**. Widened, it shows every piece's notes at once, grouped by piece and in the order your binder holds them — parts and chapters where you put them, so the queue reads like the book. Every filter above still applies across the whole set, so "every unanswered suggestion in the manuscript" is two clicks.

Notes belonging to a piece that's **open** can be answered where they sit. A closed piece's notes are readable but its buttons are off, with *Open this piece to act* on the tooltip: clicking the note takes you to that piece, and once it's open the buttons come alive. Nothing moves you out of Review while you do it.

Multiselect and the bulk bar stay in **This Piece** — a batch runs against one piece at a time, and a count that quietly skipped every closed chapter would be worse than no count. Widen to find the work; travel to the piece to do it in bulk.

If a piece's history can't be read, the queue says so in a line at the foot naming the piece, rather than showing you a short list as if it were the whole one.

### Undoing reject, archive, and your own notes

Reject, archive, and the other non-text-mutating annotation actions are undoable the same way as anywhere else in Maugham: **⌘Z** reverses the most recent one, and each ⌘Z you press walks one step further back, exactly like undoing typed edits. **⌘⇧Z** redoes forward again, and redoing re-arms the action so you can keep cycling ⌘Z ⟷ ⌘⇧Z.

- **Edit → Undo Reject Annotation** — reopens a rejected suggestion.
- **Edit → Undo Stet Annotation** — reopens a note you let stand.
- **Edit → Undo Triage Annotation** — puts back the mark the note carried *before* the one you just applied, rather than clearing it. Marking a note **Do**, changing your mind to **Discuss** and pressing ⌘Z leaves **Do** standing.
- **Edit → Undo Archive Annotation** — reopens an archived comment, query, craft note, or suggestion.
- **Edit → Undo Withdraw Annotation** — if you withdrew your own note or suggestion, ⌘Z brings it back.
- **Edit → Undo Edit Annotation** — if you edited the body (or, for a suggestion, the proposed replacement) of a note you authored, ⌘Z restores the prior wording.

Every one of these appends a **compensating** entry to the document's history rather than erasing the original action — open the **History pane** and you'll see both the original resolution and its undo listed as separate events. Undo never rewrites history; it only adds to it.

### Rewinding with suggestions

If you open the **History pane** and rewind to a point *before* you accepted a suggestion, that suggestion reopens in the **Open** status. The manuscript reverts to what it was before the accept.

If the rewind also removed the paragraph the suggestion was attached to, the suggestion is archived instead — there's nothing left for it to apply to.

If you rewind to before a suggestion was added, it disappears from the annotations list entirely.

**Undoing a Rewind restore** — a History Rewind is itself undoable. Press **⌘Z** right after restoring to an earlier point and Maugham reverses the *whole* rewind in one grouped action: the manuscript text returns to where it was before you rewound, and any suggestions the rewind reopened or archived along the way go back to how they were. **⌘⇧Z** re-runs the same rewind from scratch, so redoing a rewind can never disagree with a fresh one.

### Text notes

Text notes are Claude's comments on your work — questions, observations, or context. They don't propose text changes. Click a note to expand the full body.

Notes can be archived via their context menu (•••) and restored from the Trash if needed, or reopened with ⌘Z right after archiving (see above).

### Undoing tasks and checkboxes

Task-pane mutations — creating, checking off, reprioritizing, re-nesting, editing, and archiving a task — and inline checkbox toggles (clicking the `[ ]`/`[x]` bracket, in the editor *or* the Tasks pane) are all undoable with **⌘Z**, redoable with **⌘⇧Z**, same walk-back-and-forward behavior as text edits. See [Tasks & To-Dos](tasks.md) for the task system itself.

### Reopening from iPhone

The Maugham Companion iPhone app can't run Claude, but it can review and resolve the annotations Claude has already left, and re-open ones you resolved by mistake:

- **Reject or Archive → Reopen** — tap **Reopen** on a resolved note or suggestion in the detail view. It returns to **Open**, exactly as if you had pressed ⌘Z on the Mac.
- **Accept → Reopen & Revert** — an accepted suggestion has no plain reopen; tapping **Reopen & Revert** restores the pre-accept text *and* reopens it. If the paragraph has changed since the accept (edited on another device, say), the phone asks you to confirm before overwriting the current text.

Either way, the phone's reopen is written to the same op log the Mac reads — open the project on your Mac afterward and the annotation shows **Open** there too, with the reopen visible as its own entry in the History pane.

### Claude's `add_suggested_change` tool — two grains

When Claude uses the `add_suggested_change` tool, the grain of the suggestion depends on whether you provide a quote:

- **No `quote`** — The `suggested_text` is the complete replacement for the entire paragraph. Use this for wholesale rewrites.
- **With `quote`** — The `quote` field must contain a span of text from the target paragraph. The `suggested_text` then replaces *only that span*, preserving the rest of the paragraph. The suggestion will show as a highlighted diff in the margin card.

Pair the grain to the task: a tiny typo fix uses a quote; a full-paragraph revision omits it.
