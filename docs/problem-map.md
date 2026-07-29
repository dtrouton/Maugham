# Maugham — Problem Map

*The demand side. [`constitution.md`](constitution.md) holds the opinions, [`product.md`](product.md) the facts; this maps the **jobs** — the things a writer is trying to get done that Maugham exists to serve. One job per line, in the jobs-to-be-done frame: the job is stated tool-agnostically (a writer had this problem before Maugham existed), then mapped to what serves it today.*

*Legend: ✓ served · ~ served, but awkwardly (it works; it isn't what it should be) · • known and unserved. A feature that doesn't trace to a job here is a feature in search of a problem; a • line is an invitation.*

## Getting the words down

- ✓ **Disappear into the writing** — everything but the current sentence recedes; the tool makes no demands mid-flow. *(focus mode ⌘\, sentence/paragraph dimming, typewriter scroll, centered column)*
- ✓ **Type at the speed of thought in screenplay form** — formatting keeps up without ever being asked. *(Fountain, per-element styling, Tab/Shift-Tab cycling, dual dialogue, scene numbers)*
- ✓ **Get typography right without thinking about it** — quotes curl, dashes join, ellipses form, unprompted. *(smart typography)*
- ✓ **Know where the session stands without breaking flow** — words, position, progress visible at a glance, never announced. *(status footer, word/page targets)*
- • **Stop retyping the names I've already invented** — characters, places, and sluglines complete from the writer's own material. *(unserved — screenplay intelligence / prose autocomplete are roadmap-only)*
- • **Meet the industry's format when it's demanded** — Final Draft files, MORE/CONT'D, colored revision drafts. *(unserved — FDX and production polish are open)*

## Capturing away from the desk

- ✓ **Catch the idea before it evaporates** — a line arrives in the supermarket queue; it's in the right project before it's gone. *(phone Capture → per-project inbox)*
- ✓ **Talk when I can't type** — a voice memo on a walk becomes text by the time I'm home. *(phone voice capture → WhisperKit transcription on the Mac)*
- ~ **Get handwritten pages into the project** — notebook pages become text without retyping. *(works and is used: phone photo → Claude via MCP transcribes to a research note — but it's a conversation, not a flow; page ordering, accept/edit review, and manuscript placement are the open improvement)*
- ✓ **File the capture where it actually belongs** — a capture lands as research, a palette note, or an image in the right card, not in a junk drawer. *(inbox promote, palette aiming with sense tags)*
- ✓ **Read the draft wherever I am** — the manuscript on the phone, formatted properly, without edit anxiety. *(phone Read tab, deliberately read-only)*
- ✓ **Deal with feedback from the sofa** — triage the AI's notes away from the desk. *(phone Annotations tab, accept/reject/archive)*

## Holding the work in your head

- ✓ **See the whole shape at a glance** — the book as a structure, not a scroll. *(binder, outline table, corkboard)*
- ~ **Think before it's a book** — spread half-formed pieces out somewhere with no schema and no commitment, and shove them around until the shape appears. *(planning canvas in the Plan persona: scraps typed straight onto a spatial surface, moved, resized, zoomed, deleted; regions drawn around what belongs together, moved as a unit, collapsed when the canvas gets crowded, and associated with the piece they are material for; a card lives in one region and can be cited in any number of others, so nothing has to be filed anywhere before it is understood; lines drawn between two cards that have something to do with each other, named or left unsaid, and untyped by design; and **promotion**, the step that makes the scratch pay off — one explicit command (⌘⇧↩) that turns a card into a research note, a palette card or a craft intent, a region into a research note or a palette card, and a line into a `[[wiki-link]]` once both its cards have been promoted, always previewed before anything is written and always a copy, so the card keeps its words. A card carries the same piece association as a region, and **where a promotion lands follows it** — the card's own piece, else the region it lives in, else the project's research — but dragging research in is still to come)*
- ✓ **Reorganize without fear** — move, rename, regroup, duplicate, and take it all back. *(binder drag-reorder, trash & undo)*
- ✓ **Keep the research beside the draft, not in another app** — sources, images, and notes one pane away. *(research browser, research↔manuscript linking)*
- ✓ **Follow the threads between people, places, and pieces** — connections are recorded where they occur and traversable later. *([[wiki-links]], backlinks, rename propagation)*
- ✓ **Remember what every piece is for** — each chapter carries its own intent, state, and size. *(inspector: synopsis, status, tags, word target)*
- ✓ **Keep the story's sensory world consistent** — what this place smells like, what this character wears, held somewhere better than memory. *(sensory palette cards, craft intent doc, Claude sense pass)*
- ✓ **Track the loose ends inside the draft itself** — "fix this later" lives at the paragraph it belongs to and is findable when later comes. *(tasks layer: inline checkboxes, Fountain todos, tasks pane)*
- ✓ **Find that line I wrote somewhere** — one search across the whole project, replace with care. *(cross-document find/replace ⌘⌥F)*
- ✓ **Jump around a screenplay by scene** — sluglines as a map, not a scroll target. *(scene navigator)*

## Getting feedback without losing the pen

- ✓ **Get a careful, whole-manuscript read on demand** — someone who has actually read all eighty thousand words, available at midnight. *(Claude via MCP: full project read access)*
- ✓ **Receive suggestions I can adjudicate, not absorb** — every proposal is explicit, anchored, and mine to accept or reject; nothing slips into the text. *(annotation membrane: comments, queries, suggested changes; Annotations pane)*
- ✓ **Ask craft questions of my own book** — "where did I drop this thread," "does the timeline hold." *(claude queries, craft notes, sense pass over palette + intent)*
- ~ **Keep the lessons from feedback, not just the fixes** — accepted craft principles persist and inform future passes. *(accepted craft notes are queryable via MCP, but a writer-readable, curatable digest is still open)*
- ~ **See what's flagged while I'm in the text** — know a paragraph carries an open note without leaving the editor. *(the pane shows all annotations; inline marks in the editor margin are open)*
- • **Point feedback at a clause, not a paragraph** — tight suggestions on exactly the words in question. *(unserved — sub-paragraph range anchors are open)*
- • **Get the same quality of feedback from humans** — a trusted reader annotates through the same membrane, with the same writer-disposes control. *(unserved — collaborator layer is a design, not a feature)*

## Keeping the words safe

- ✓ **Never lose a word — not to a crash, a conflict, or my own mistake** — every keystroke durably captured, every device append-safe. *(op log, 750ms autosave, per-device JSONL sync)*
- ✓ **Undo anything, not just typing** — rejecting an annotation, archiving tasks, even a rewind, all take-backable. *(unified op-log-backed ⌘Z)*
- ✓ **Return to any moment in the document's life** — scrub back through every edit ever made and recover any of it. *(History Rewind, checkpoint timeline)*
- ✓ **Mark the moment before the big rewrite** — a deliberate, named "before" to come back to. *(⌘S labeled checkpoint; named snapshot curation still open as refinement)*
- ✓ **Survive the disaster I didn't see coming** — disk failure, file corruption, a bad sync: the novel comes back. *(integrity-checked backups, restore-beside, manifest self-heal)*
- ✓ **Own the words in a form that outlives the tool** — plain standard Markdown/Fountain on disk, readable by anything, forever. *(clean derived .md/.fountain, ADR 0019)*
- ✓ **Keep the work private by default** — nothing leaves the machine without intent; the AI door has a switch. *(local-only MCP socket, offline core, no accounts)*
- • **Pull one document back from a backup without rewinding the world** — restore a single chapter from last Tuesday into the live project. *(unserved — single-document restore is deferred)*

## Delivering to readers

- ✓ **Hand someone a book, not a printout** — the draft becomes a beautifully typeset PDF that looks like it came from a publisher. *(Claude-authored LaTeX template + bundled tectonic)*
- ✓ **Ship a real ebook** — standard EPUB with cover, styles, and structure intact. *(EPUB pipeline)*
- ✓ **Assemble the pieces into a collection** — stories written separately become one deliverable book. *(collection project type, mixed content)*
- ✓ **Reach readers in another language** — a translated edition, produced without ever touching the original words, reviewable read-only before it ships. *(parallel translation layer via Claude MCP tools, editor Translation Review mode + ⌘⌥L pane, blocking coverage gate on compile)*
- • **Submit in the format the market demands** — Shunn standard manuscript, Word output. *(unserved — both open)*
- • **Know where every story stands in the submission cycle** — what's out, where, since when. *(unserved — submission tracker is speculative)*

## Sustaining the practice

- ✓ **Start writing the moment the app opens** — no setup, no configuration, no method to learn first. *(defaults, welcome tour, sample projects)*
- ✓ **Get unstuck without leaving the work** — help where the writer already is, in the writer's own terms. *(in-app guide ⌘?, same guide served to Claude via get_help)*
- ~ **Know whether the practice is on track** — sessions, streaks of work, project trajectory. *(session tracking, statistics, activity views exist — honestly interesting-more-than-useful so far; screenplay stats still render novel-shaped)*
