# Maugham 0.X.Y — draft (not a release)

_Draft for the release of the shell branch (`claude/shell-without-personas`). Not cut, not tagged. When the release is cut this becomes `v0.X.Y.md` (`docs/RELEASING.md`). This draft holds plan 4's part only (Status, editions and translation, [ADR 0038](../adr/0038-status-editions-and-translation.md)); plans 1–3 and 5 add theirs before the cut. The guide pages that describe the old Department desk and translation review are rewritten in plan 5, and the release waits for them._

## What's new

- **The tree shows what needs you.** A chapter, scene, Part or the Book with open notes, to-dos or a check's findings carries a small blue dot. A chapter Maugham couldn't read shows a hollow ring instead of looking quiet. An edition with something waiting carries the dot too, and one with a proposed brief reads "Proposed".
- **Status for the whole book.** Choose Status in the toolbar (or View ▸ View as Status, ⌃⌘3) to see every chapter's stage, each review pass, open notes and open to-dos side by side. Click a to-do count to open that chapter's to-dos.
- **Each edition is its own place.** Select an edition under Editions in the tree:
  - Its centre shows its own compiled book (only books in its language). Click a chapter in the tree and the book scrolls to where that chapter starts.
  - Compile… and the imprint picker sit in the book's header. If a compile fails, its problems cover the book until you deal with them.
  - Status for an edition shows, per chapter, how much is translated, the latest round, open questions, changes to look at, the trend and the publishing settings.
  - To resolve lists the edition's questions, the translator's changes, glossary proposals, design proposals and compile problems, with the translator's latest letter and Run Whole Book at the top. Run Whole Book says what it will run and roughly what it costs before you press it.
  - The edition's Brief holds its brief and its cast. Rename the translator, reader or collator there (Cast ▸ Change…); the designer is on the Source edition's Brief.
- **Add a language from the tree.** The `+` beside Editions, the Source edition's menu, or File ▸ Add Language…. The Department desk is gone; everything it did lives on the edition.
- **Read a chapter in any language it has.** On a translated chapter, the toolbar's language switch (or View ▸ Read In, or ⌃⌘L) shows the chapter in that language with your original in grey under each paragraph. Paragraphs out of date are marked amber; ones not yet translated show your text, lighter. The translation is read-only. To change it, write in Source; the next round carries it over. Turn the grey lines off with View ▸ Show Source Under Translation. Moving to the next chapter keeps the language when that chapter has it.
- **A chapter in a language has its own To resolve.** It lists that language's questions and the round's changes, headed by that chapter's own latest letter, with Run for just this chapter, the paragraphs out of date as links, and translations left over from deleted paragraphs, which you can clear. Separate translation review is gone.
- **Earlier letters.** When more than one editor has written to a chapter, the head of To resolve offers their earlier letters.
- **The toolbar says what's running.** While a translation round or an editor's round runs, the toolbar names it in every window on the book. Click it to go to that chapter.
- **Keyboard and dragging in the tree.** Arrow keys move through a chapter's cards, pictures, regions and research. Pause on one and it replaces what's pulled up, if something is. Return pulls it up now. ⌘↓ opens it in the centre. While you drag, the tree shows where the drop will land: a line between rows, or a dashed outline on the row it goes into. Drag a capture, note or picture onto the Canvas row to put it on the canvas.
- **A script in a Collection shows its scenes** at the top of its fold.

## Fixes

- Promoting a piece of a Collection to its own project no longer leaves the Collection window unusable, whether the promotion succeeds or fails. While a piece is being promoted, Replace All, renames and the assistant leave it alone. If a promotion can't put everything back, the message names the folder and offers Reveal in Finder.
- A whole-book translation run no longer loses every chapter's letter but the last ten.
- Two windows on one book can no longer start two whole-book runs at once.
- Closing a window while the canvas was dimmed left its Escape handling behind. It now goes with the window.

## Known issues

- While you read a chapter in a translation, Undo does nothing in that window. Switch back to Source to undo.
- An edition can't be removed once added.
- A change made only in a translation dots the edition in the tree, not the chapter.
- A book compiled before Maugham 0.33 has no paragraph anchors, so its edition can't scroll to chapters: compile it again.
- Clicking a chapter that's already selected in the tree doesn't scroll the edition's book back to it; use the "starts on page N" link in the book's header.

## Technical notes

- **No op-log schema change.** `ProjectManifest.currentSchemaVersion` is still 10, and plan 4 changed no MaughamCore source file, so this part needs no paired phone release.
- **The translation rounds ledger** (`.maugham/translations/rounds/<lang>.json`, synced) gained optional fields: `latestByPiece` (each chapter's latest finished round), and on each round `translatorName` and, on a change, `ruled`. An older build on a second Mac that rewrites the ledger drops them; the newer build's next round restores each chapter's letter. Chapters whose letter has aged out of the ring of ten show no letter until then.
- **The diagnostics sidecar** (per device) gained `latestRoundByPass`: each review pass's latest superseded round, letter included.
- **MCP:** `translation_status`'s `last_round` is now the latest *finished* round for that chapter and language; a cancelled round is no longer reported (a failed one still is, with `stopped_at`). The `translation-pass` and `edition-brief` skills and the `propose_edition_brief` response no longer mention the desk; they point at the edition's To resolve and Brief.
- **Chapter jumps need paragraph anchors**, emitted since v0.33.0 (2026-08-28): an older PDF says "Compile again to jump to chapters"; anything compiled since jumps without a recompile. Anchor names are not unique across chapters, so a chapter whose anchors are all shared with another chapter says it can't be placed rather than jumping to the wrong page (register `M7-PB-012`).
