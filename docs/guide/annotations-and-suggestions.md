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

**Archive** — Moves the suggestion out of the active list without accepting or rejecting it. Status changes to **Archived**.

**Undo an accepted suggestion** — Press **⌘Z** (or use **Edit → Undo Accept Suggestion**). The suggestion returns to **Open** status and the text reverts. Redo with **⌘⇧Z** to re-apply it (the redo re-arms another ⌘Z, so you can cycle back and forth).

Accepted suggestions can also be reverted from the **Annotations pane** at any time — turn on the show-resolved filter (the tray icon) and click **Revert** on the accepted suggestion. Accepting a *second* suggestion clears ⌘Z's reach back to the first one — that's specific to accept (each accept starts a fresh typing-undo baseline), so the pane's Revert is the way to reach an older accepted suggestion once a newer accept has happened. No other undoable action in Maugham has this one-deep limit — see below.

### Undoing reject, archive, and your own notes

Reject, archive, and the other non-text-mutating annotation actions are undoable the same way as anywhere else in Maugham: **⌘Z** reverses the most recent one, and each ⌘Z you press walks one step further back, exactly like undoing typed edits. **⌘⇧Z** redoes forward again, and redoing re-arms the action so you can keep cycling ⌘Z ⟷ ⌘⇧Z.

- **Edit → Undo Reject Annotation** — reopens a rejected suggestion.
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
