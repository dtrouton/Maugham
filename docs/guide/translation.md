# Translating Your Book

Maugham can hold a translated edition of your book beside the original. The translation lives in its own layer, paragraph by paragraph against your text, and nothing about it touches your manuscript: your words stay exactly as you wrote them. You read the translation in the editor, settle what its translators raise, and publish it as its own PDF or EPUB.

A translation can come two ways: from inside Maugham, by a cast of three who work a chapter in rounds (below), or from Claude Desktop, by asking Claude to translate a chapter, which it does with the same tools and asks you a question (as a note) where it shouldn't guess.

## Editions in the binder

The binder's **Editions** section lists the book's own language first, labelled **Source**, then one row per translated edition. Click an edition and the centre shows it, with two views in the toolbar:

- **Book** (⌃⌘1) — the edition's typeset pages, in its language. Click a chapter in the binder and the book scrolls to where it starts: *Chapter Three starts on page 41*. Compile… and the imprint picker sit in its header ([Publishing](publishing.md#compiling-an-edition)).
- **Status** (⌃⌘3) — per chapter: how much is translated, the latest round, open questions, what the last round left **to look at**, the trend, and the chapter's publishing settings. Click a row to open the chapter read in this language. The Source's Status shows the publishing settings, with a line to the Book's Status for the rest.

The right column follows the edition: its **To resolve** gathers the edition's questions and what its rounds left, by chapter; its **Brief** is the edition brief and its cast. ⌘⌥K (View ▸ To Resolve: Spanish Edition) takes you to the To resolve of the edition you are reading in, else the Source's.

A dot on an edition's row means its To resolve has something; **Proposed** means Claude drafted a brief for it.

### Starting an edition

**Add Language…** — the **+** on the Editions header, the Source row's menu, or **File ▸ Add Language…** — asks for the language's tag (`es`, `fr`, `pt-br`; capitals are fine) and the name of its translator. Two more fields, both optional, name the edition's reader and collator. For the five languages that come with a cast, all three names fill in as you type the tag. A tag that isn't a language says so in the sheet. The new edition is selected in the binder.

**Remove Edition…** — on a translated edition's row menu, and in File — hides it. It asks first: *Remove the Spanish edition? Its translations stay in the project and come back if you add Spanish again.* Add the language again and it is back as it was, translations and cast included. The Source can't be removed.

### The edition brief and the cast

An edition's **Brief** (⌘2) holds:

- **The edition brief** — a statement you own, like a chapter's intent: register, idiom policy, what stays untranslated, typographic conventions for that language. Its **Decided** section holds the edition's own decisions and its **Glossary** table. The translator is briefed with it, and Claude can read it too. Claude can propose one (through the `edition-brief` skill); see [Decisions](right-column.md#decisions) for Adopt and Discard.
- **Cast** — who translates, reads and collates this edition, with **Change…**.
- **Visual Language** — the book's, which pulls up.

The Source's Brief names the book's **Designer**, with **Change…**, and lists any brief Claude proposed for a language the book has no edition in yet, with **Add <Language>…** and **Discard**.

## The people

**Every edition has three people, not one.** The **translator** writes it. The **reader** reads that translation and nothing else — never your English — and says where the prose doesn't sound like a book written in that language. Never having seen the source, they can't tell you a sentence is wrong, only that it reads badly. The **collator** holds both texts side by side and says where the translation has moved from what you wrote, and every departure they raise carries a **gloss** — a plain, literal rendering back into your language of what the translation now says. The gloss is what lets you rule on a paragraph in a language you don't read.

Five languages come with all three picked, from literary history:

| Language | Translator | Reader | Collator |
|---|---|---|---|
| Spanish | Cortázar | Ocampo | Borges |
| French | Baudelaire | Colette | Yourcenar |
| German | Tieck | Bachmann | Schlegel |
| Japanese | Motoyuki | Enchi | Futabatei |
| Serbian | Kiš | Sekulić | Vinaver |

Their names sign every paragraph, note and question their work produces, as a review pass's editor signs its notes. For a language with no preset, the first round asks you to name its translator (**Name & Run**); the reader and collator, if you leave them blank, are named when a round needs them. **Change…** renames the cast. A new name signs everything from then on; what the old name signed stays theirs.

## Reading a chapter in a language

A chapter with translations can be read in one: the **language switch** in the toolbar, **View ▸ Read In ▸**, or ⌃⌘L (Read In Next Language). The chapter's text becomes the translation, read-only, with your source under each paragraph in grey (⌃⇧⌘L, **View ▸ Show Source Under Translation**, turns that off). A paragraph whose source changed since it was translated has an amber dot and shows its current source; an untranslated one shows its source once, lighter, with a hollow dot. A line over the text names the language and the counts, with **Read Source**.

While you read a translation you can't type in it, and Undo waits: **Edit ▸ Undo** reads *Undo — Returns in Source*. Back in Source, your undo is where you left it. The language carries to the next chapter you open, if it has that translation. Read-through can't start while you're reading a translation.

**Its To resolve** is that language's, for that chapter: headed *Spanish translation*, the chapter's latest round letter (with **Earlier letters**), and **Translate This Chapter into Spanish** with what it will cost. Below: the translator's questions and what the round left to look at, by paragraph, and glossary proposals under *Whole chapter*.

- **The counts** — *3 paragraphs out of date · 2 not translated yet* — open to links that take you to each one.
- **Left-over translations**, of paragraphs you have since deleted, are shown with their text and **Clear**, which asks first. Undo the deletion instead and the paragraph's translation is a translation again.
- **This paragraph** — with the cursor in a paragraph, two buttons ask about it. **Gloss** asks what it now says, rendered literally back into your language. **Ask the Collator** asks whether it still says what you wrote, and answers with any departures, each with the round report's verbs. Neither writes anything; only the verbs you press do. An answer belongs to the paragraph it was asked about, and goes when you move on.
- **See this chapter in the Spanish book** opens the edition's typeset pages at this chapter.

A chapter that isn't open lists its items but offers no verbs, and says *Open this chapter to answer its questions*. ⌘⌥A, ⌘⌥D and ⌘⌥T read the chapter in Source first, since a translation's list holds no notes, checks or to-dos.

## Running a translation

**Translate This Chapter into Spanish**, at the head of the chapter's Spanish To resolve, or **File ▸ Translate This Chapter into Spanish**, runs one round on the chapter open in the centre. **File ▸ Translate…** acts on what To resolve is showing: a chapter read in a language, or an edition's whole book. Elsewhere it is grey, and says why. A round is **seven legs of work**:

1. **Translate** — the translator works through what is stale, missing, or covered by a directive you wrote, and asks a question where something needs your call.
2. **Read** — the reader reads the translation cold and writes notes.
3. **Fix** — the translator answers them, or says why not.
4. **Re-read** — the reader reads the repaired text, cold again.
5. **Fix** — the translator answers the second read.
6. **Collate** — the collator compares the translation with your English and raises departures, each with its gloss.
7. **Fix** — the translator answers the departures, writes the round's summary, and proposes glossary terms.

**A leg with nothing to do is skipped, and the report says so.** The second read is skipped when the first fix changed nothing.

The line beside the button says what it runs and roughly what it costs — *Translates this chapter into Spanish · 7 legs · ~4,300 words briefed.* **Only one round runs at a time**, across the whole book. While one runs, a line in the toolbar names it — *Translating · Serbian · “Chapter Three” (3 of 12), re-reading* — in every window on the book; click it to read that chapter in that language. **Cancel** stops the round after the leg that's running, and what earlier legs wrote stays. A failed leg ends the round the same way, and the report names where and why.

### The whole book

**Translate Whole Book into Spanish**, at the head of the Spanish edition's To resolve (or File, with the edition picked), runs one round on every chapter, in binder order. Its line says how many, then the cost: *Translates every chapter of the book: 12 chapters*. If an imprint is chosen, it is that imprint's chapters only. It needs no chapter open. **Cancel** stops after the running leg; the chapters already done stay done. **A failed round stops the queue**, so you see what went wrong first.

## The round report

**Open the report**, at the head, opens a round in the centre. It's written to you in your own language — every verb on it is one you can press without reading the translation.

**The reader's report.** The first read beside the second, each with its verdict. Beneath them, **The collator**'s verdict on the chapter as a whole.

**Where your prose was changed.** One row per departure: your paragraph, the collator's gloss, their reason, what the translator did. Three verbs:

- **Fine** — you're happy with the change. It's recorded on the round beside what the translator did.
- **Keep mine** — opens the Translator's Note sheet with the collator's note in it, set to **this edition only**. What you write is a dated directive on that paragraph, and the next round treats the paragraph as work.
- **Make it a rule** — a decision in this edition's brief, from the next round on.

**Show the translation** shows the before and after, when you ask.

**Disagreements.** The notes the translator turned down, with both names: who raised it, and why the translator declined. The verbs are **Translator's right**, **Reader's right** or **Collator's right**, and **Make it a rule**.

**Questions for you.** The round's own questions, with **Answer** and, where it is about one edition, **Answer as ruling…**.

**Glossary proposals.** Terms the round thinks the book should fix. **Adopt** writes it into the edition brief's glossary; **Skip** is remembered.

**Summary.** The round's closing words and counts, and **Open the queue**, which opens the chapter in that language on its questions.

Click a source paragraph on the report and Maugham opens that chapter read in that language, at that paragraph.

## Answering a translator

A translator's question, and a question about the whole chapter (voice, an honorific, whether to translate a name), wait in To resolve under **Questions** (⌘⌥L), tagged with their language. **Answer as ruling…** beside the ordinary reply writes a dated entry into that edition's brief in the same act — so the next round doesn't ask again, and neither does a translator working another chapter. A note the reader or collator raised and the translator declined arrives the same way, signed by whoever raised it, with the translator's reason in its body.

## Table labels

A table's text cells — its row and column labels, anything typed as words — translate per language like paragraphs; numbers, dates and formulas are the same in every language. A round on a chapter also translates the missing or stale labels of the tables it uses (a table two chapters share is done once; a table parked in Research is skipped). Claude can write them too, addressing each cell by its name (`B3`). Reading a chapter in a language, a table's card shows the translated labels, and the figure's details show its coverage per language. A table sent to Research keeps its translations out of the count until you bring it back.

## Publishing a translated edition

Compile the edition from its Book view (see [Publishing → Compiling an edition](publishing.md#compiling-an-edition)), or ask Claude to. Maugham refuses an edition with stale or missing paragraphs — the failure lists exactly which — and tables count too ("Table cashflow: B3, C1 untranslated"). To share a partial edition anyway, turn on **Allow stale translations** in Compile…: the gaps print in your original language and are listed as warnings, and the file is a real, numbered edition. An edition can carry its own template if the language calls for it.
