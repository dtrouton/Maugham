# Annotations & Suggestions

Claude can add two kinds of annotations to your manuscript: text notes (comments) and suggested changes (edit proposals). Both appear in the **Annotations pane** (⌘⌥A).

### Suggestions

A suggestion is Claude's proposal to change a span of text or an entire paragraph. When Claude adds a suggestion, it lands in the **Open** status and appears as a margin card in the editor. Click to review the proposed change.

**Accept** — Applies the suggestion to your manuscript. The status changes to **Accepted** and the card dims.

**Reject** — Dismisses the suggestion without changing your text. Status changes to **Rejected** and it moves to the resolved filter.

**Undo an accepted suggestion** — Press **⌘Z** (or use **Edit → Undo Accept Suggestion**). The suggestion returns to **Open** status and the text reverts. Redo with **⌘Y** to re-apply it.

### Rewinding with suggestions

If you open the **History pane** and rewind to a point *before* you accepted a suggestion, that suggestion reopens in the **Open** status. The manuscript reverts to what it was before the accept.

If you rewind to before a suggestion was added, it disappears from the annotations list entirely.

### Text notes

Text notes are Claude's comments on your work — questions, observations, or context. They don't propose text changes. Click a note to expand the full body.

Notes can be archived via their context menu (•••) and restored from the Trash if needed.

### Claude's `add_suggested_change` tool — two grains

When Claude uses the `add_suggested_change` tool, the grain of the suggestion depends on whether you provide a quote:

- **No `quote`** — The `suggested_text` is the complete replacement for the entire paragraph. Use this for wholesale rewrites.
- **With `quote`** — The `quote` field must contain a span of text from the target paragraph. The `suggested_text` then replaces *only that span*, preserving the rest of the paragraph. The suggestion will show as a highlighted diff in the margin card.

Pair the grain to the task: a tiny typo fix uses a quote; a full-paragraph revision omits it.
