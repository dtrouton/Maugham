# Tasks & To-Dos

Maugham has a lightweight task system built into your writing: inline checkboxes in any document, plus a pane that aggregates them project-wide.

### Inline checkboxes

Start a line with `- [ ]` to create an open task, or `- [x]` to create one already checked off. Any paragraph in any manuscript document can hold a checkbox — put them anywhere it makes sense: a to-do at the top of a chapter draft, a reminder in a research note, a list of scenes still to write.

Click the bracket to toggle between open and done. The underlying text flips between `- [ ]` and `- [x]`.

Screenplays support a second syntax: `[[todo: ...]]` boneyards inside Fountain notes.

### The Tasks pane (⌘⌥T)

Press **⌘⌥T** to open the Tasks pane in the right column (or click the checklist icon in the pane picker).

The pane has two scopes, toggled by the **Doc / Project** picker at the top:

- **Doc** — tasks derived from the currently open manuscript document only.
- **Project** — every task across the project, including closed documents and standalone project tasks.

Filter by status using the **Open / Done / Archive** chips. The default view shows open tasks.

### Standalone project tasks

Click the **+** button in the Tasks pane toolbar to add a task that isn't tied to any paragraph. A small sheet appears; type the task body and choose **Document** or **Project** scope, then press **Add**. Project-scope tasks live in `.maugham/ops/__project__.jsonl` rather than in a manuscript file.

### Nesting and reorder

Drag a task row to reorder it. Drop onto the **middle** of another top-level task to nest it one level deep — Maugham supports a single level of nesting. Drop onto the **top or bottom third** of a row to reorder as a sibling.

### Archiving

Completed tasks can be archived via the row's context menu. The **⋯** menu in the toolbar offers **Archive all done** to sweep the current scope in one action.

### Undo

Every task and checkbox action — create, toggle, reprioritize, re-nest, edit, archive — is undoable with **⌘Z** and redoable with **⌘⇧Z**. See [Annotations & Suggestions → Undoing tasks and checkboxes](annotations-and-suggestions.md#undoing-tasks-and-checkboxes) for the full behavior.

### Claude reads your tasks

If you use Claude Desktop with the Maugham integration, Claude can read your task list via the `list_tasks` and `get_task` tools — across the whole project or for a single document, filtered by status. Task management stays with you: Claude can read and reference your tasks, but only you can create, check off, or archive them.
