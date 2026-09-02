# Translating Your Manuscript

Maugham can hold a translated edition of your manuscript alongside the
original — Claude does the translating, through the same MCP tools it uses
for everything else, and you review it in the editor before it ships as a
PDF or EPUB.

### How it works

Translations live in a parallel layer, keyed paragraph by paragraph to your
source text. Nothing about the translation touches your manuscript — the
source stays exactly as you wrote it, in every language. Ask Claude to
translate a chapter or the whole book into a language (a lowercase tag like
`es` or `pt-br`), and it works through the gaps using its own read/write
tools, checking in with you (via a query, the same as any other annotation)
on voice, register, or ambiguous terms rather than guessing.

You can also run the whole thing from inside Maugham, without asking anyone:
**Run** on a language row of the Publish desk (⌘⌥K) puts a translator, a
blind reader and a collator through seven legs on the open chapter and hands
you a report. See [The Publish Department](publish-department.md).

### Reviewing a translation

Open the picker from **View → Translation Review…** and choose a language
that has translation coverage. The editor switches to a read-only view of
the translated text —
you can read it and move the cursor, but typing is disabled; leave review to
go back to editing your own words. Missing paragraphs show dimmed, in the
source language; paragraphs whose source has been edited since they were
translated show an amber stale badge, so you always know whether what you're
reading matches the current draft.

### Orphaned translations

When you delete a paragraph from the source manuscript, any translation of it
doesn't disappear with it — it becomes an **orphan**: a translated paragraph
with no source paragraph left to match it to. The Review pane lists them in
their own Orphans section, one row per orphaned paragraph, with a **Remove**
button beside each and a **Remove All** for clearing the whole list in one
go. There's no confirmation dialog — an orphan is stale by definition and
Claude can retranslate the paragraph again if you ever needed it back, so
removing one is closer to emptying a wastebasket than deleting a document.
The list refreshes live as translations change. An orphan clears by itself
only if the very paragraph comes back — undoing the deletion restores it with
the same identity, and its translation is a translation again. Retyping the
paragraph doesn't do that: to the manuscript it's a new paragraph, so the old
translation stays an orphan and **Remove** is how it goes.

### The Translation pane (⌘⌥L)

While reviewing a translation, the right pane's Translation mode shows the
selected paragraph's original source text with a freshness chip (fresh /
stale / missing), and any open translator queries for that language. Reply
to a query right there — your answer folds back into the annotation the same
way replying to any other Claude query does.

A query signed by the edition's **reader** or **collator** turns up here and
in your queue like any other, with the translator's reason for declining the
note written into the body under their name. Both bylines are there because
there were two people in the disagreement.

**Two buttons ask about the paragraph under your cursor.** They're how you
audit a translation anywhere, not only where a round happened to look:

- **Gloss** — what does this paragraph now say? The answer comes back as a
  plain, literal rendering into your own language, drawn beneath the source
  text under a *gloss* label. It reads the translation and never your English,
  so it can't quietly flatter what you wrote.
- **Ask the Collator** — does this paragraph still say what I wrote? The
  collator judges this one paragraph against your source, with its neighbours
  for context, and answers with departures if there are any — each with its
  own gloss, and the same three verbs a round's report offers: **Fine**,
  **Keep mine**, **Make it a rule**.

Both are ordinary buttons, with no shortcut of their own. Each is a single
question and a single answer, and **neither writes anything** — the answer is
drawn and that's all it does. Only the verbs write, and you press those.

**An answer belongs to the paragraph it was asked about.** Move the cursor to
another paragraph and the gloss, the collation and anything you marked Fine
go with it — a spot-check isn't a round and there's no record for it to
settle into. Ask again where you want another answer. Both buttons go
unavailable, with the reason on hover, while a round's own leg or another
spot-check is still out: there's one session, and it's busy.

It sits in **Publish**'s pane picker (⌘4): a translation never changes your
source text — it's a parallel layer that an edition is compiled from — so it
belongs with the editions rather than with the notes you adjudicate in
Review. Entering translation review switches the right pane to it from
whatever persona you're in, and ⌘⌥L opens it anywhere.

### Publishing a translated edition

Ask Claude to compile with the language set (e.g. "compile the Spanish
edition"). Maugham refuses to produce an edition with stale or missing
paragraphs — the failure lists exactly which paragraphs need attention, and
translating those and recompiling is the normal way to finish a pass. If you
want a partial edition anyway (a preview to share before translation is
complete), ask for it with the stale/missing paragraphs allowed through —
those spots fall back to your original-language text and are flagged in the
compile warnings. A translated edition can carry its own template and
styling if the language calls for it; ask Claude if you want the look to
differ from the original-language edition.
