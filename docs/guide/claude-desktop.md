# Writing with Claude

Maugham ships a local MCP server. Once configured, Claude Desktop can read your projects and create research notes for you.

### One-time setup

1. Install Claude Desktop (claude.ai/download).
2. Open Maugham. **Help → Set up Claude Desktop…**
3. Click **Configure**. Maugham writes a small entry into Claude Desktop's config.
4. Restart Claude Desktop.

That's it. You can test by asking Claude: *"What Maugham projects are open?"*

### What Claude can do

Read:

- List open projects, outlines, and chapters
- Read documents (live in-memory — Claude sees text you haven't saved yet)
- Search across manuscript
- Discover research items by enumeration or title
- List the reference graph (wiki links + linked research backrefs, including a collection piece's own research)
- Read your session stats ("how much have I written this week?")
- Filter chapters by tag

Write:

- Create research notes ("Claude, write me a character sheet for Sarah based on what you see in Chapter 1")
- Link research notes to chapters
- Unlink as needed
- Promote a capture-inbox entry into research — unscoped, or scoped to a chapter/piece
- Add text notes and suggested changes to the Annotations pane (non-destructive proposals you review, accept, reject, or undo with ⌘Z)

Claude doesn't modify your manuscript text directly — proposals appear as annotations you control. See [Annotations & Suggestions](annotations-and-suggestions.md) for how to accept, reject, or undo changes.

For an intent-first revision audit of sensory groundedness, see [The Sense Pass](sense-pass.md).

### When Claude adds a research note

A small banner appears at the top of the editor pane: *"Claude added 'Sarah Voice' to research."* Click **Show** to jump to the note. The banner auto-dismisses after 8 seconds.

### Turning it off

Settings → General → **Allow Claude to connect (MCP)**. Toggle off; Claude gets a polite "MCP is turned off in Settings" error and you can re-enable any time. The MCP server also stops when Maugham isn't running (it's not a background process).
