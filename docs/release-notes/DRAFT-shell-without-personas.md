# Maugham 0.X.Y — draft (not a release)

_Draft for the release of the shell branch (`claude/shell-without-personas`). Not cut, not tagged. When the release is cut this becomes `v0.X.Y.md` (`docs/RELEASING.md`). The decisions behind it are [ADR 0035](../adr/0035-the-subject-not-the-persona.md) to [ADR 0040](../adr/0040-the-words-and-the-menus.md)._

Maugham's window no longer has modes. You don't choose Plan, Author, Review or Publish before you can get at something: you click what you want in the binder, and the window turns to it. Beside your draft sit two places — what's waiting on you, and what this chapter is for — and anything you pull up to look at. Every menu has been reread, every word that named an old surface is gone, and the Help, the tour and the sample projects describe the window you actually have.

## What's new

### The binder picks, the window follows

- **The mode bar is gone.** ⌘1–⌘4 no longer switch the whole window between Plan, Author, Review and Publish. Click a chapter in the binder and it opens in the middle; click the Book and you see your whole book as Cards, Outline or Status (View ▸ View as Cards, Outline, Status, ⌃⌘1/2/3).
- **The binder holds everything**, top to bottom: the Book, the Inbox (with a dot when captures are waiting), the Canvas, your chapters and Parts, Figures, Research, the Palette, your Editions, and the Trash.
- **On the canvas, a click on a chapter doesn't take the canvas away.** Its region lights up and the right-hand column turns to that chapter, so you can plan and look at the chapter's notes side by side. Double-click to open it.
- **⌘R checks your writing wherever you are.** File ▸ Check Writing (⌘R) and Reread (⇧⌘R) are always a check; an editor's round is asked for by name — File ▸ Run Gould's Round (⌃⌘R), titled for the chapter's pass — and never guessed from where you stand.

### Beside your draft: To resolve, Brief, and what you pull up

- **To resolve (⌘1) is one list of everything waiting on you** for what you're looking at: your notes and your readers', what a check found, your to-dos, and a translator's questions. It follows your cursor through a chapter, grouped by paragraph ("Whole chapter" first); on the Book or a Part it groups by chapter. The chips at the top narrow it (Checks ⌘⌥D, Rounds ⌘⌥A, Mine ⌘⌥T, Questions ⌘⌥L), and once the list is long they work one at a time so it stays readable. Settled items fold away at the bottom. When more than one editor has written to a chapter, the head offers their earlier letters.
- **You act on the chapter you're looking at.** Rows for another chapter can be read; click one and that chapter opens on that paragraph, ready for you to answer. To resolve shows everything without opening a chapter you didn't ask for.
- **Brief (⌘2) is what a chapter is held to, in your own words**: its one line (which also shows on its card, in the outline and above the prose), **Going for** (what it's trying to do), and **Decided** (what you've settled about it, dated). After a check, Going for is marked where the draft strains against it (a solid underline) or is silent on it (a dotted one); click a solid mark to see the finding. View ▸ Write the Line (⌘⌥I) and Write Going For (⌘⌥N) put your cursor straight there. The Book's Brief gathers every decision in the book.
- **Answering moves it across.** When you answer a finding, To resolve says "Filed in Brief", and the answer is there.
- **Pull something up (⌘3)** — a research note, a canvas card, a region, a figure — and it sits beside your chapter while you move from chapter to chapter. Click it again to put it away; View ▸ Back (⌘[) returns to what was up before; Open in Centre gives it the middle of the window. What I've Learned (⌘⌥G), First Reader (⌘⌥Y), Visual Language (⌘⌥V) and History (⌃⌘H) pull up the same way. History works for a chapter that isn't open, and offers to open it when you want to rewind.

### A chapter's things live under it

- **Each chapter has a fold in the binder** — its research, the canvas cards and regions bound to it, its palette cards, its figures, and its links both ways (a chapter that links here carries a return arrow). Pictures show as thumbnails. Clicking a chapter opens its fold when there's something in it, and closes it again when you move on, unless you opened it yourself or worked inside it. View ▸ Show the Chapter's Fold (⌘⌥E) opens it from the keyboard.
- **Research is the book's or a chapter's, never both.** Research you linked to a chapter now lives in that chapter's fold; the Research section tells you how many ("12 research items are with their chapters — open a chapter’s fold to see them."). The binder's Research section holds the whole book's research; a chapter's research shows only in its fold. Give a note to a chapter with **Move to Chapter ▸** or by dragging it onto the chapter; give it back with **Make Whole-Book** or by dragging it onto Research. Wherever you put a note is whose it is. If a move would take a note away from another chapter that also uses it, Maugham asks first and names the chapter.
- **A figure whose table changed tells you.** If the research cells a table figure was made from change, the chapter that places it lists "Table 2's source data changed" in To resolve, with Compare… and Open the Table.

### The book, its editions and its languages

- **Status for the whole book.** Status (⌃⌘3) shows every chapter's stage, each review pass, open notes and open to-dos side by side. Click a to-do count to open that chapter's to-dos.
- **The binder shows what needs you.** A chapter, scene, Part or the Book with anything waiting carries a small blue dot. A chapter Maugham couldn't read shows a hollow ring instead of looking quiet. An edition with something waiting carries the dot too, and one with a proposed brief reads "Proposed".
- **Each edition is its own place.** Select an edition under Editions:
  - Its middle shows its own compiled book. Click a chapter in the binder and the book scrolls to where that chapter starts.
  - Compile… and the imprint picker sit in the book's header. If a compile fails, its problems cover the book until you deal with them.
  - Its Status shows, per chapter, how much is translated, the latest round, open questions, what the last round left to look at, the trend and the publishing settings.
  - Its To resolve lists its questions, what the round left to look at, glossary and design proposals and compile problems, with the translator's latest letter and **Translate Whole Book** at the top, which says what it will translate and roughly what it costs before you press it.
  - Its Brief holds the edition's brief and who's working on it: rename the translator, reader or collator there. The designer is on the Source edition's Brief, with **Run Design** in its To resolve.
- **Add or remove a language from the binder**: the `+` beside Editions, or File ▸ Add Language…. Remove one with File ▸ Remove Spanish Edition… (or the edition's right-click). Maugham asks first, hides the edition everywhere, and keeps every word of it: add the language again and it all comes back. Claude can't write into a removed edition, and is told why.
- **Read a chapter in any language it has.** The toolbar's language switch, View ▸ Read In, or ⌃⌘L shows the chapter in that language with your original in grey under each paragraph (turn the grey lines off with View ▸ Show Source Under Translation, ⌃⇧⌘L). Out-of-date paragraphs are marked amber, untranslated ones show your text, lighter. The translation is read-only: write in your own language and the next round carries it over. A screenplay read in another language groups its To resolve by scene, as the original does.
- **A chapter in a language has its own To resolve**, headed by that chapter's own latest letter and **Translate This Chapter** (or This Story, This Script — your project's own word).
- **The toolbar says what's running.** While a translation or an editor's round runs, the toolbar names it in every window on the book; click it to go to that chapter.

### Reading your own draft as a reader would

- **Read-through replaces the Lock and Review Mode.** View ▸ Start Read-through (⌘⌥⇧R), or the padlock in the toolbar, puts the chapter in front of you into read-through: you can't type into it, but you can comment, suggest, answer and accept, and its research and figures are kept still too. Maugham saves a checkpoint as you start ("Read-through, 22 Nov — Chapter Three"), so the version you were reviewing is always there in History. It stays on until you choose Resume Writing, even across quitting.

### The margin

- **View ▸ Margin** draws quiet marks beside your text. **People's Notes** puts a small dot, in each person's colour, beside every paragraph that you or a reader has left a note on, and tints the words noted; Claude's notes stay in To resolve. **Everything Flagged** puts a grey tick beside every paragraph with anything waiting. Click a mark and To resolve opens on that paragraph, without moving your cursor. The setting is remembered for each book; ⌘\ hides it with everything else. VoiceOver can reach and press each mark.

### Menus, keys and words

- **Every menu has been reread.**
  - **Comment on a selection anywhere**: Edit ▸ Comment… (⌘⇧K), or right-click the words. In someone else's chapter, or in read-through, the right-click also offers Suggest, Query and Translator's Note, as the floating toolbar does.
  - **File ▸ New Chapter / New Part** (New Story in a short story; New Prose Piece / New Script in a Collection) adds one where you are and lets you name it straight away.
  - **File ▸ Translate This Chapter into Serbian** while you read a chapter in Serbian, and **Translate Whole Book into Serbian** on the Serbian edition.
  - **Go to the Book**, **Go to the Canvas**, **Go to Research**, **Go to Palette** and **Go to Inbox** in the View menu; **View ▸ Open in Centre** opens whatever is selected in the binder (⌘↓ still does it from the binder).
  - Focus Mode and Full-Screen Focus are ticked in the View menu while they're on, and the window's menu items are greyed out when no project window is in front.
- **Keys that moved.** ⌘⌥H is the Mac's own Hide Others, so it hides your other apps: History is ⌃⌘H. ⌘R is always a check, of the chapter you're typing in (with the Canvas or an edition in the middle, of the chapter the right column is about); a round is ⌃⌘R. ⌘⇧R is Reread, the check read cold. ⌘4 does nothing: editions are rows under Editions in the binder.
- **The checkpoint is of the chapter you're typing in.** ⌘S, Save Checkpoint As… (⌘⇧S), the line above the prose and Translator's Note (⌘⌥C) follow the chapter open in the middle, even when the right column shows another chapter's Brief or an edition's To resolve.
- **Help ▸ Syntax & Keyboard Shortcuts** (⌘/) now lists every key the menus bind, and the binder's own (↑↓, ↩ or Space, ⌘↓). It and **Help ▸ Set up Claude Desktop…** open without a project, in a window of their own.
- **File ▸ Translate…** is greyed out while a round runs, and its tooltip says which.
- **One word for one thing.** Maugham calls a piece what your project calls it — a chapter in a novel, a story, a script, a section in a report, a piece in a Collection — on every button, heading and message. A to-do is a to-do everywhere (no more "task"), a note is a note (no more "annotation"), the left column is the binder, and research is either "Whole-Book" or "This Chapter's".

### Help, the tour and the samples

- **The guide has been rewritten** for the window as it is, in the order you'll meet things: Getting Started, Structure & the Binder, To Resolve, Brief & Pulled Up, then the rest. "Translating Your Book" is one page now, and "Notes & Suggestions" is the new name for the notes page.
- **Help ▸ Welcome to Maugham** is a new eight-card tour, and the **sample novel and screenplay** (Help ▸ Sample Projects) open on their first chapter and walk you through the binder, Brief, a chapter's fold and its to-dos.
- **Claude knows the window.** When Claude Desktop connects, Maugham now tells it what Maugham is, that it never writes your manuscript, and to talk about what you see — the binder, To resolve, Brief, what's pulled up — in your project's own words.

## Fixes

- Promoting a piece of a Collection to its own project no longer leaves the Collection window unusable, whether the promotion succeeds or fails. While a piece is being promoted, Replace All, renames and the assistant leave it alone. If a promotion can't put everything back, the message names the folder and offers Reveal in Finder.
- A whole-book translation run no longer loses every chapter's letter but the last ten.
- Two windows on one book can no longer start two whole-book runs at once.
- Closing a window while the canvas was dimmed left its Escape handling behind. It now goes with the window.
- Dropping several pictures on the binder's Canvas row is one step: ⌘Z takes them all back.
- A window whose Exports folder is slow to answer (an iCloud folder not yet downloaded, or macOS asking for access) still draws at once; the publish view fills in when the folder answers.

## Known issues

- Read-through is remembered on this Mac only. Your phone and your other Macs don't know a chapter is in read-through and can still type into it.
- Claude can still change the research and links of a chapter that's in read-through; read-through stops your own accidental edits.
- Focus Mode hides the toolbar, the status line, the line above the page and the margin; outside the canvas the binder and the right-hand column stay.
- A window that was locked, or in Review Mode, before this version opens in ordinary writing.
- Opening a chapter's intent or its History in the middle of the window clears that chapter's typing Undo.
- While you read a chapter in a translation, Undo is off in that window (the menu says "Undo — Returns in Source"). Switch back to Source to undo.
- A change made only in a translation dots the edition in the binder, not the chapter.
- A book compiled before Maugham 0.33 has no paragraph anchors, so its edition can't scroll to chapters: compile it again.
- Clicking a chapter that's already selected in the binder doesn't scroll the edition's book back to it; use the "starts on page N" link in the book's header.

## Technical notes

- **Release checklist** (found on the branch; nothing here is merged, pushed or tagged):
  - **Schema:** `ProjectManifest.currentSchemaVersion` is 10, as on `main`: no op-log schema change, so no paired phone release is forced.
  - **MaughamCore** changed in fourteen production files (`git diff --stat 25e0a014 HEAD -- Packages/MaughamCore/Sources`, plus Core's `AREA.md`): `ProjectManifest.swift` (`removedEditions`), `RulingsSection.swift`, `ReviewPass.swift` (a key in the Argus brief's text), `RegistryReader.swift` (a directory gone between the check and the listing lists as empty), `BackupSignature.swift` (comments), `JSONLAppendStore.swift` (`loadStrictPlain`, `onElement`; an older-history sentence says "to-do"), `HeldLines.swift` ("the to-do rebalance"), `Annotation.swift`, `SuggestionDisplay.swift` and `TaskMarkup.swift` (comments naming the surfaces that ship), and `OpLogClassifier.swift`, `OpLogPermitContext.swift`, `OpLogStore.swift` and `PermitPartition.swift` (whose a note is, read off the seal that covers its line, for the margin; an optional parameter). The two Core sentences the phone also shows (People & Devices' older history, a set-aside reason) now say "to-do"; the phone's own "Annotations" / "This piece" wording waits for the next paired release. No `MaughamPhone/` source changed on the branch; the one phone file reading a changed type is `MaughamPhone/Settings/BookStandingRow.swift` (`RegistryReader`), and nothing the phone shows changes. **A Mac-only release is expected**; `./scripts/test.sh phone` must be green on the release commit first (result below).
  - **MCP:** no tool added or removed (the catalogue's methods are `main`'s). Changed: tool descriptions (to-do, note, the binder, whose research is whose); `initialize` now sends `instructions`; `translation_status`'s `last_round` is the latest *finished* round for that chapter and language (a cancelled round is no longer reported; a failed one still is, with `stopped_at`); `write_translation`, `compile`, `preview_compile` and `propose_edition_brief` refuse a removed edition's language with a sentence Claude can repeat, and `translation_status` omits it; `move_research_item` says each moved item's new home and every chapter it left. A new served skill, `publishing-setup`, holds the publishing configuration detail the guide no longer carries; the `translation-pass` and `edition-brief` skills no longer mention the desk.
  - **`get_help` topics renamed:** `right-pane` → `right-column`, `translation-review` → `translation`; `publish-department` is gone (folded into `translation` and `publishing`). A Claude that remembers an old topic should ask for the list again.
  - **Derived files gain optional keys**, and an older build drops them with nothing lost: the manifest's `removedEditions` (the removed edition shows again in an older build; with two Macs, update both); the translation rounds ledger (`.maugham/translations/rounds/<lang>.json`, synced) gains `latestByPiece`, and each round `translatorName` and `ruled`; the diagnostics sidecar gains `latestRoundByPass`; `ui-state.json` gains the window's subject, the Book and edition views, the right column's position, Show Source Under Translation and the margin setting (an older build opens on its own defaults). Read-through is a new per-device file, `.maugham/read-through.<device>.json`.
  - **Gates before the cut:** `./scripts/test.sh full` (no skips), `./scripts/test.sh phone`, and a Release build; then the whole-branch review of plan 5 and the milestone's whole-branch review (workflow rule 9).
- **Gate results on the record commit** (shell p5 Task 10, 2026-11-26): `./scripts/test.sh full` passed — Mac scheme 13,491 passed, 0 failed, 16 skipped (the skip ceiling), MaughamCore 3,044 green; `./scripts/test.sh phone` passed — 404 tests, 1 skipped, 0 failures; the Release build succeeded. The two whole-branch reviews are still owed.
- **Gate results after the closing round** (2026-11-26, on the closing round's tree): `./scripts/test.sh full` passed — Mac scheme 13,533 tests, 13,515 passed, 0 failed, 16 skipped (the skip ceiling), MaughamCore 3,044 green; `./scripts/test.sh core` passed — 3,044; `./scripts/test.sh phone` passed — 404 tests, 1 skipped, 0 failures; the Release build succeeded.
- **Merged over v0.48.0** (`origin/main` fc7ba284, issues #145–#149, 2026-11-26): the tree's research moves and renames say the picture links they left through the branch's one move door (`performPlan` returns the outcome, lifts included); Replace All names read-through, promotion and changed-since-read files each in its own sentence; origin's OpLog claim M9-OL-020 (a late close) is filed as M9-OL-026, since the branch's M9-OL-020/-021 hold those ids and M9-OL-022 to -025 are reserved by the promotion-history plan (M9-OL-019 cross-references it as -026). Gates on the merge: `./scripts/test.sh full` — Mac scheme 13,593 tests, 13,575 passed, 0 failed, 16 skipped (the ceiling), 2 expected failures; `./scripts/test.sh core` — 3,044 green; `./scripts/test.sh phone` — 404 tests, 1 skipped, 0 failures; the Release build succeeded.
- **Chapter jumps need paragraph anchors**, emitted since v0.33.0 (2026-08-28): an older PDF says "Compile again to jump from the binder to the page"; anything compiled since jumps without a recompile. Anchor names are not unique across chapters, so a chapter whose anchors are all shared with another chapter says it can't be placed rather than jumping to the wrong page (register `M7-PB-012`).
- **Decisions still open** (each built as described until decided otherwise; [ADR 0040](../adr/0040-the-words-and-the-menus.md), "Open, the owner's"): the two "Ask about…" fields in one head; Help's two sheets opening without a project (changing approved row 57); File ▸ "Save" vs the cheat sheet's "Save Checkpoint"; the Welcome window's sentence-case buttons; ⇥ to the canvas only in a novel's binder; whether republish should reproduce the old words rather than render the current book in the old design; whether Focus Mode should hide the binder and right column; "New Story" / "New Section"; Suggest… everywhere or only where the writer cannot edit; "where a note is, is whose it is"; "People's Notes"; MCP `instructions` at `initialize`; `move_research_item` and a novel's chapters; the Screenplay plural "scripts"; whether a dense To resolve list should gain an All; Claude's notes on a reviewer's copy; the Inbox at scale; ⌘⌥K's title ("To Resolve: Serbian Edition", not the approved "Serbian Edition's To Resolve"); Task 4a's research rulings R1–R6, the group Delete/Move shape and the view-only New Note alert; ⌘R on the open piece; the Research section's "where they went" line; the Inbox's fast "Promote to Research for “…”" removed; the phone's wording waiting for the next paired release.
