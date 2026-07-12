# Maugham — Product Constitution

*This is the opinions document: the value thesis, who Maugham is for and isn't, and the musts and must-nots that every future feature is tested against. The facts — what's built, what's half-built — live in [`product.md`](product.md).*

*Each principle carries a rationale and a falsification condition ("we'd know this rule was wrong if…"). Some principles are marked **identity**: they define what Maugham is, and no evidence would revise them — abandoning one means building a different product. Others are marked **position**: held with conviction, but honest about what would change our mind. A proposal that collides with an identity principle is dead on arrival; one that collides with a position must clear the stated bar. That test applies to *solutions*. A problem or job that lives in territory these principles exclude is not dead on arrival — flag it against the principle and preserve it; a flagged job that keeps resurfacing is evidence about the rule.*

*ADRs may cite these principles by name. When a decision genuinely conflicts with a position stated here, the resolution is an edit to this document, not a silent exception.*

---

## Value thesis

**The writing is the writer's. Everything around the writing is where the tool — and the AI — earn their keep.**

Writing a novel is mostly not typing sentences. It is research, structure, memory, continuity, feedback, transcribing the idea that arrived in the supermarket queue, and eventually turning a folder of files into a book-shaped thing a reader can hold. Maugham's bet is that AI is transformative for *all of that* while remaining categorically excluded from the sentence-making itself. Claude is the trusted reader in the next room: deeply familiar with the manuscript, full of observations when asked, and never — structurally never — the hand on the keyboard.

This is not AI-skepticism. It is a division of labor. The tools that will matter to serious writers are not the ones that write; they are the ones that make the writer's own writing easier to sustain, safer to keep, and more beautiful to deliver.

## Who it's for — and who it isn't

**For:** serious creative writers — prose, novels, screenplays — who work on a Mac, want their manuscript in plain text they own, and want an AI collaborator as reader, researcher, editor-who-suggests, and production assistant. People for whom the novel is the point.

**Not for:**

- Writers who want AI to draft, co-write, or generate prose. Many tools compete to do this. Maugham is constitutionally unable to, and that's the pitch, not a gap.
- Teams. Maugham is single-writer today; a collaborator layer is designed but unbuilt, and even that design admits reviewers, not co-authors.
- Anyone needing Windows, Linux, or the web. Maugham is Mac-native by conviction, not by resource constraint.
- Content production at volume — blogs, copy, SEO. Wrong tool, on purpose.

---

## Musts

### 1. The words are safe — *identity*

Never lose a word: every edit is durably captured, and a crash, a sync conflict, or a bug must never cost written work. Everything is reversible: undo, rewind, trash, and checkpoints mean no state of the manuscript is unreachable. The words outlive Maugham: manuscripts are standard plain text on disk, readable by any tool, forever — if Maugham dies, the novel doesn't. And the words are private: nothing leaves the machine without the writer's explicit intent; AI access is local, live-only, and switched off with one toggle.

**Rationale:** a writer trusting a novel to an app is an act of faith the app must deserve before it deserves anything else. Every other virtue is worthless if the words aren't safe. This is why the operation log, the append-only invariant, per-device sync partitioning, integrity-checked backups, and clean-plain-text-on-disk all exist — safety is the majority of the architecture.

**Violated if:** any feature can silently discard written work; any operation is destructive without a way back; any manuscript content becomes readable only through Maugham; any manuscript content leaves the machine by default.

**We'd know this was wrong if:** nothing would. This is identity. A Maugham that trades word-safety for anything is not Maugham.

### 2. Get out of the way — *identity in spirit*

A writer must be able to open Maugham and write, with zero configuration. Preferences exist; none are required. Metrics — word counts, targets, session stats — are available when sought and never pushed: no streaks, no badges, no nagging. And Maugham imposes no method: it supports acts, chapters, index cards, targets, and research, but never requires a workflow, an outline, or a daily quota.

**Rationale:** the product exists to protect the writing state of mind. Every demand the tool makes — configure me, look at your numbers, follow the method — is a withdrawal from the attention the words needed.

An honest note: Maugham is not minimalist and doesn't claim to be. It has a binder, an inspector, seven right-pane modes, and a phone app. The principle is *calm*, not sparse — capability lives beside the writing surface and waits to be summoned. Richness around the edges is fine; demands are not.

**Violated if:** any feature requires setup before writing can start; any metric or reminder interrupts unprompted; any feature only works if the writer adopts a prescribed process.

**We'd know this was wrong if:** essentially nothing would; this is identity in spirit. The one honest caveat is the balance point of "calm, not sparse" — if the surfaces around the editor ever grew until writers reported *presence* (not demands) as the distraction, we'd revisit how much richness the edges can carry. The principle itself would survive; the calibration would move.

### 3. Delight, end to end — *position*

Daily craft-feel *and* occasional magic, one standard. The everyday touches — typography, the focus dim, the ⌘S checkpoint flash, smart quotes — should make the hours of ordinary writing quietly pleasurable. And once in a while the tool should produce a wow: Claude finding the dropped thread across eighty thousand words, a voice note from a walk transcribed and filed by morning, a bespoke typeset PDF of your own novel compiled on your own machine. Delighting the writer, and helping the writer delight others — the reader holding the book-shaped thing — are one pillar, keystroke to bound PDF.

**Rationale:** serious tools are allowed to be joyless, and most are. But a writer spends thousands of hours here; the difference between a tool that is merely correct and one that is a pleasure compounds across every one of them. Delight is also the honest test of craftsmanship — you can't fake it with a feature list.

**Violated if:** a feature ships that works but feels cheap; an export looks like a printout instead of a book; a daily interaction stays clunky because "it's functional."

**We'd know this was wrong if:** the pursuit of polish measurably starved safety or flow work — if delight ever competed with must #1 or #2 and won. Delight is the standard for how things ship, never a reason to ship the wrong thing.

### 4. AI helps with everything else — *position*

The affirmative half of the thesis. Claude should keep getting deeper access to everything *around* the manuscript: reading and remembering the whole project, research, continuity, structure, annotations, transcription, palette, publishing. The ambition for AI support is unbounded; only its direction is constrained (see must-nots). "Claude can't touch the words" is never an excuse for Claude being shallow everywhere else.

**Rationale:** the must-nots below are so absolute that the temptation is to play AI timid across the board. That forfeits the actual bet. The membrane is what *permits* ambition: because the manuscript is structurally untouchable, everything else can be opened to AI without anxiety.

**Violated if:** an AI-support capability is rejected *solely* because it involves AI rather than because it breaks a principle; or the AI surface stagnates while the editor grows.

**We'd know this was wrong if:** deep AI involvement around the edges demonstrably degraded the writing itself — if having Claude's observations always available made the writer's own instrument weaker, not stronger. That evidence would force a narrowing of the thesis, not just a feature change.

---

## Must nots

### 1. AI is never the author — *identity*

No AI system may originate manuscript text autonomously. The precise line: Claude may read, comment, query, and *propose* — including proposing concrete replacement text. The writer may apply a proposal through a deliberate, per-suggestion, writer-initiated action; that is the writer wielding a suggestion, and it is fine. What is forbidden, permanently: AI editing the manuscript autonomously, bulk-applying its own suggestions, or any path where AI words enter the manuscript without a specific human decision about those specific words.

**Rationale:** the whole product is a bet on the writer's own voice. The moment AI text can flow into the manuscript unmediated, the manuscript's authorship becomes ambiguous, and ambiguity of authorship is fatal to the kind of writer Maugham serves. The architecture enforces this — the MCP layer has no manuscript-mutation tools at all, by construction, not by policy.

**Violated if:** any tool, feature, or "accept all" affordance lets AI-originated text reach the manuscript without a per-instance writer decision; any background process modifies manuscript text; any future MCP tool mutates a manuscript file.

**We'd know this was wrong if:** nothing would. Identity. A Maugham where AI writes is a different product with the same name.

#### Corollary: reproduction is not a license to author — *identity*

Some AI tasks claim to *reproduce* the writer's own words rather than propose new ones — transcribing a photographed manuscript page, OCR, importing handwriting. This is the disguised case of the rule above, and the most dangerous one: a confident fabrication in a reproduction channel wears the writer's own voice and invites acceptance instead of scrutiny. A suggestion announces itself as the AI's and asks to be judged; a transcription claims to be *yours already* and asks only to be pasted. (This is not hypothetical — a transcription pass once fabricated a continuation of the story in place of the page's actual words; the only safeguard was the writer's suspicious read. See [`problem-map.md`](problem-map.md), "Know the transcription says what the page says," and the evidence behind it.)

So: AI-reproduced content is unverified manuscript-candidate text until the writer confirms it against the source. The reproduction and its source must be checkable side by side; reproduced text must never auto-place into the manuscript; and it must never silently shed its unconfirmed status.

**Violated if:** transcribed, OCR'd, or imported text flows into the manuscript without a per-instance writer confirmation; the source (photo, scan, original) isn't available beside the reproduction for checking; reproduced text is presented as indistinguishable from words the writer confirmed.

**We'd know this was wrong if:** the identity core wouldn't move — reproduction must stay verifiable and never auto-authored; it is must-not #1 seen in a mirror. The *friction* is a position: if transcription grew reliable enough that side-by-side confirmation became pure ceremony, the mechanism could lighten — but never below "the writer can always see the source, and nothing reproduced enters the manuscript unbidden." Reliability rising does not make a hidden fabrication less catastrophic; it makes it rarer and therefore less expected, which cuts the other way.

### 2. No AI inside the editor — *identity*

Claude lives in another window. No chat panel, no inline copilot, no ghost-text completions from a language model, no AI margin whispering in the writing surface. The friction of switching windows is a feature: writing-mode and feedback-mode are different mental states, and the boundary between them deserves physical form.

**Rationale:** an AI presence inside the editor changes what the editor is — every pause becomes an invitation to consult rather than to think. The master design said "no in-app AI panel ever" on day one, and everything since has confirmed it: the annotation membrane works *because* it is somewhere else.

**Violated if:** any AI-generated content renders inside the editor surface or its immediate chrome; any editor affordance invokes AI in-place. (Boundary note: mechanical intelligence — Fountain autocomplete from the writer's own sluglines, wiki-link completion from the writer's own names — is not AI in this sense. The line is generative-model output, not code being clever with the writer's own material.)

**We'd know this was wrong if:** nothing would move the editor-surface rule. The nearest revisable neighbor is already accommodated: a read-only companion *pane* for Claude responses keeps feedback out of the editor while shortening the walk — that's the permitted form of this pressure, not an erosion of the rule.

### 3. Nothing AI-made reaches readers unreviewed — *identity*

Anything AI-produced that could reach an audience — a compiled PDF's template, an EPUB, a blurb, front matter, any future submission artifact — passes through the writer's explicit review before it ships anywhere. The writer is accountable for every word and every design choice that reaches a reader; Maugham must never create a path where AI output goes public on the writer's behalf without their eyes on it.

**Rationale:** must-not #1 protects the manuscript's authorship; this protects the writer's *name*. The publishing pipeline is Claude's biggest creative surface (it co-authors LaTeX templates), which is exactly why the writer's review gate on outputs is constitutional.

**Violated if:** any feature auto-sends, auto-publishes, or auto-submits AI-produced content; any pipeline's default flows AI output to an external destination without a review step.

**We'd know this was wrong if:** nothing would. Identity — this is the writer's accountability to their readers, which isn't Maugham's to trade.

### 4. No cloud required — *position*

The core writing experience — writing, structuring, research, safety, publishing — works fully offline, forever, with no account, no subscription, and no server. Sync is optional and rides the writer's own iCloud Drive; AI is optional and runs over a local socket to an app the writer chose; transcription runs on-device. Maugham must keep working in an off-grid cabin, which is where some of the best writing happens.

**Rationale:** dependence is a safety issue wearing a convenience costume. A cloud requirement is a lock-in vector, a privacy hole, and a bet that some company's server outlives the writer's novel. The words are on the writer's machine; the tool should be too.

**Violated if:** any core capability stops working without a network or an account; any feature defaults manuscript content to a server Maugham controls.

**We'd know this was wrong if:** a capability emerged that genuinely required a relay — real-time human collaboration is the plausible candidate — *and* writers demonstrably wanted it more than they wanted the offline guarantee. Even then the bar is: the offline core remains fully functional, the cloud-dependent capability is additive and opt-in, and manuscript content never rests on infrastructure Maugham controls. A "cloud-optional extra" could clear that bar; a "cloud-required Maugham" could not.

---

## Using this document

When scoping a milestone, test it here first: does it collide with an identity principle (stop), demand a position clear its bar (argue it in the ADR), or advance a must (say which)? When a shipped feature and this document disagree, one of them is wrong — decide which, on the record.
