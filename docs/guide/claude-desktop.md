# Writing with Claude

Maugham ships a local MCP server. Once configured, Claude Desktop can read your projects and create research notes for you.

### One-time setup

1. Install Claude Desktop (claude.ai/download).
2. Open Maugham. **Help → Set up Claude Desktop…**
3. Click **Configure**. Maugham writes a small entry into Claude Desktop's config.
4. Restart Claude Desktop.

That's it. You can test by asking Claude: *"What Maugham projects are open?"*

### Claude Code

The same setup sheet (**Help → Set up Claude Desktop…**) has a **Claude Code** section:
a copyable `claude mcp add …` command connects Claude Code (the CLI) to the same MCP
tools, and **Install Claude Code Skill** writes a small router skill to
`~/.claude/skills/maugham/SKILL.md` so Claude Code automatically finds and follows
Maugham's own task procedures — notebook transcription, an editing pass — instead of
improvising. If Maugham later ships an updated procedure, the sheet flags the installed
skill as out of date; click **Update**.

### What Claude can do

Read:

- List open projects, outlines, and chapters
- Read documents (live in-memory — Claude sees text you haven't saved yet)
- Search across manuscript
- Discover research items by enumeration or title
- List the reference graph (wiki links + linked research backrefs, including a collection piece's own research)
- Read your planning canvas — every card, region and line, and what each has already produced
- Read your session stats ("how much have I written this week?")
- Filter chapters by tag
- Load Maugham's own task procedures ("skills") for jobs like notebook-photo transcription or an editing pass — automatically in Claude Code once the skill is installed, or in any client by asking Claude to call `get_help` with topic `"skills"`

Write:

- Create research notes ("Claude, write me a character sheet for Sarah based on what you see in Chapter 1")
- Link research notes to chapters
- Unlink as needed
- Promote a capture-inbox entry into research — unscoped, or scoped to a chapter/piece
- Move research items (including whole groups) between shared research, a group, and a collection piece's research folder — link associations update automatically
- Add text notes and suggested changes to the Annotations pane (non-destructive proposals you review, accept, reject, or undo with ⌘Z)
- Add cards to your **planning canvas** — the case it is built for is a page you wrote on paper and photographed. Claude cannot choose where a card goes: everything it adds lands together in one labelled region, placed clear of your own work, with the page it read at the top of it. Its cards are drawn perfectly straight where yours lean, so a straight card is never yours, and one ⌘Z takes back a whole batch. See [the canvas section of Getting Started](getting-started.md#what-claude-can-put-on-the-canvas)

Claude doesn't modify your manuscript text directly — proposals appear as annotations you control. See [Annotations & Suggestions](annotations-and-suggestions.md) for how to accept, reject, or undo changes.

For an intent-first revision audit of sensory groundedness, see [The Sense Pass](sense-pass.md).

### When Claude adds a research note

A small banner appears at the top of the editor pane: *"Claude added 'Sarah Voice' to research."* Click **Show** to jump to the note. The banner auto-dismisses after 8 seconds.

### Turning it off

Settings → General → **Allow Claude to connect (MCP)**. Toggle off; Claude gets a polite "MCP is turned off in Settings" error and you can re-enable any time. The MCP server also stops when Maugham isn't running (it's not a background process).
