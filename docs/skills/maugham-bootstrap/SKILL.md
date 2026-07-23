---
name: maugham
description: Working with the Maugham writing app (manuscripts, research, transcription, editing passes, publishing) via its MCP tools. Use whenever the Maugham MCP server's tools are in play or the user mentions Maugham.
---

# Maugham

Maugham serves its own task skills over MCP — always fetch the current
procedure instead of improvising:

1. Call `get_help` with topic `skills` to list the available Maugham
   skills with descriptions.
2. Call `get_help` with the relevant skill's name (e.g.
   `transcribing-notebooks`, `editing-pass`) to load the full procedure.
3. Follow the loaded procedure. It is authoritative for how to use
   Maugham's tools for that task and reflects the installed app version.

Hard rules that apply regardless of task: Claude never edits manuscript
text directly (annotations and research only), and `get_help` without a
topic lists Maugham's user documentation.

<!-- maugham:managed — installed by Maugham. Hand edits are replaced when you click Update in Maugham's Claude setup sheet. -->
