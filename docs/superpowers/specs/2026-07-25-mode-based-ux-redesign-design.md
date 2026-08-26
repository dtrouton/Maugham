# Mode-based UX redesign — umbrella design

*Brainstormed 2026-07-25. This is the umbrella design for a four-persona restructuring of the Maugham window, a new through-line primitive, and a second AI feedback loop. It is deliberately **not** an implementation spec: it settles architecture, boundaries and sequencing, and each of the four milestones below gets its own spec and plan before it is built.*

---

## 1. The bet

Maugham today is one window with one shape: binder, editor, and a right pane with nine undifferentiated segments. That shape serves drafting well and everything else adequately. The bet here is that the work around a manuscript falls into four genuinely different mental states, that a tool which reconfigures itself around whichever one you're in serves each better than one shape serves all, and that **the artifacts connecting those states are the missing spine** — what a piece is trying to do, and what the book is supposed to look like, recorded once and honoured everywhere after.

The four states:

| Persona | The state | Produces |
|---|---|---|
| **Plan** | Deciding what the thing needs to be | Intent, visual language, palette cards, structure |
| **Author** | Getting the words down | The draft; intent that accretes from asking |
| **Review** | Judging a finished unit | Adjudicated notes, revised intent, craft principles |
| **Publish** | Making the artifact | The edition; recorded design decisions |

Two hard constraints on the whole design, both from the writer:

- **Modes are optional. Entering one is all-in and delightful, never an afterthought.** A mode that's a half-hearted rearrangement of existing panes fails the brief.
- **The tool surfaces readiness; it never announces it.** Where you stand is available when you look for it and silent otherwise.

---

## 2. Constitutional test

Three collisions, to be resolved on the record. [`constitution.md`](../../constitution.md) is explicit: a decision that conflicts with a stated principle resolves as an edit to that document, not a silent exception.

### 2.1 The authoring compiler vs must-not #2 — *identity*

Must-not #2 forbids AI inside the editor. Its violation conditions are "any AI-generated content renders inside the editor surface or its immediate chrome" and "any editor affordance invokes AI in-place."

- **First clause: clear.** Diagnostics render in a right pane. Nothing AI-produced ever draws in the writing surface — no squiggles, no margin chips, no ghost text.
- **Second clause: arguable, and must be argued.** The invocation is a keystroke available while writing. What it produces acts in a pane, not in place — but the rule's stated rationale is that "every pause becomes an invitation to consult rather than to think," and a one-key feedback loop is exactly that invitation.

The constitution already names the permitted form of this pressure: *"a read-only companion pane for Claude responses keeps feedback out of the editor while shortening the walk — that's the permitted form of this pressure, not an erosion of the rule."* This design is that shape. But it goes one step beyond what that sentence contemplated, because the trigger sits in the writing context.

**Obligation:** an ADR citing must-not #2 by name, arguing the refined line (output location is the invariant; invocation locality is the position), and amending the constitution's boundary note so the next person doesn't have to re-derive it.

### 2.2 Four modes vs must #2, "imposes no method" — *identity in spirit*

Must #2 requires that Maugham "never requires a workflow, an outline, or a daily quota." A four-stage arc is a method.

**Resolution:** modes are lenses, not gates. There is no threshold, no ceremony, no consolidation step, and no state in which a mode is unavailable. You can write in a project with no intent recorded, publish one that was never reviewed, and never open Planning at all. Readiness is never pushed — it renders where metrics already render, on the same "available when sought" terms.

This resolution is cheap to state and easy to erode. It belongs in the ADR, because the pressure to add "you should really finish planning first" will arrive.

### 2.3 `claude -p` makes Maugham outbound — *position*

Today Maugham is a passive MCP server on a local socket: the door opens only when Claude knocks, and one toggle closes it. Spawning `claude -p` makes Maugham initiate, for the first time.

Tested against the must-nots: manuscript text is still never mutated by AI (must-not #1 — output is annotations and diagnostics); nothing reaches a reader unreviewed (must-not #3); the offline core is untouched and the feature is optional (must-not #4). Privacy holds in substance — the writer's explicit keystroke is the intent gate — but the *posture* changes, and "AI access is local, live-only, and switched off with one toggle" needs to keep being true of the new path too.

**Obligation:** its own ADR. The single toggle must govern outbound invocation as well as inbound service.

---

## 3. The spine — one new primitive

The most important structural finding of the brainstorm: **intent and visual language are the same kind of object**, and that object is new to Maugham.

> Freeform prose the writer produces naturally · op-log backed so it has history · with Claude deriving the checkable structure.

This is deliberately the same shape Maugham already uses everywhere else — the op log is truth and the `.md` is derived (ADR 0018/0019); palette cards are edited visually and their markdown is regenerated. Here the writer's prose is truth and the structure is derived.

### 3.1 Intent

**Scope:** project *and* per-piece. A collection has an intent; each piece has its own.

**Form:** freeform prose. Never a form. Rejected alternatives: named slots (premise / effect / constraints) are precise and measurable but nobody fills them in; pure prose with nothing derived is trivially correct but leaves readiness unable to say anything and review unable to point at a specific unmet intention.

**Why it needs history:** review's job is to compare a draft against *the intent you started with*. Today craft intent is a markdown doc under `research/`, and research mutations are not op-log backed — there is no "as of when I wrote this chapter." Promoting intent to an op-logged artifact gives that baseline for free, forever, **with no freezing ceremony** — which matters, because thresholds were explicitly rejected. History Rewind already renders this UI.

**How it gets written:** partly declared in Planning, and partly *accreted*. The writer's own report is that the forcing function which works is having to externalise and explain an idea to a reader. So when the compiler's feedback is unhelpful because it doesn't know what you were going for, you tell it — and that telling becomes intent. The explanation produces a durable artifact instead of a throwaway prompt.

### 3.2 Visual language

**Scope:** project. The book has one look.

**Form:** freeform, and mixed — images, references, and prose ("cheap, loud, affectionate; the type should feel photocopied"). Claude reads it when authoring the LaTeX/CSS, and **records the concrete decisions it made** — typeface, scale, rule weights, the logic behind per-piece variation — back into the project. Those recorded decisions are what keeps piece six consistent with pieces one to five and what a drift check can test against.

Rejected: typed design tokens. Playlist Volume One's five per-piece typographies were conceptual inventions descending from one idea, not parameter values; tokens could not have expressed the idea that produced them. Rejected: pure reference material with nothing recorded — consistency would then depend entirely on Claude re-deciding well each time.

### 3.3 Relationship to the sensory palette

These are **different objects that happen to look alike**. The sensory palette (shipped) is the *story's* world — what this kitchen smells like — and it is an input to prose. Visual language is the *book's* identity and an input to typesetting. They rhyme; they do not merge. Palette stays per-piece; visual language is project-scope.

---

## 4. Two loops

The clarifying frame, and the writer's own: **authoring feedback is a compiler; review is a code review.**

Taken seriously, the analogy carries further than it looks. A compiler does not ask what you meant — it checks your code against the types you already declared. Intent *is* the type signature. Which makes the four personas: declare the types, type-check, code review, build. Maugham already calls the last one `compile`, with a coverage gate that fails the build on stale translations.

### 4.1 The authoring compiler

| | |
|---|---|
| **Trigger** | One key — a *run* shortcut, distinct from ⌘⌥D which merely shows the pane. No composing, no dialog, no ceremony. |
| **Scope** | The delta since the last run. |
| **Context** | Declared intent + the piece's pinned references + palette. It doesn't ask what you meant. |
| **Latency** | Seconds. Async — you keep writing. |
| **Output** | A Diagnostics pane. Never the editor. |
| **Lifecycle** | Each note anchored to a ¶id; dismissed automatically when that paragraph changes. |

**Why "delta since last run" and not a semantic unit or a selection:** the chunk size ends up set by how often you reach for it, so it tracks the writer's rhythm rather than imposing one, and "wet ink" is definitionally what you just wrote. A selection puts a decision in front of every run, which is the ceremony being removed.

**The delta is structured, not a word window.** The op log already holds the prior text of every paragraph, so a run knows which paragraphs are *new* and which were *revised, and what they said before*. These are different questions — a revision carries an implied goal, new prose only answers to intent — and the compiler should treat them differently. This also keeps each run cheap: the delta plus the intent, not the chapter.

**Three fates for a diagnostic:** fix it (the note dismisses itself when the prose changes), ignore it (gone on the next run), or **promote it to a task** — durable because the writer chose that, ¶-anchored, in the Tasks pane that already exists. Without the third, a useful note you don't want to act on right now would simply evaporate.

**Where the analogy breaks, recorded honestly:** it is non-deterministic (the same paragraph twice yields different notes); it is seconds not milliseconds, so it behaves more like a test run than a compile; it has taste, which is the entire point; and it must be **on demand, never continuous** — a background linter would breach both must #2 (nothing pushed) and must-not #2 (no marks in the writing surface).

### 4.2 Review — named editorial passes

Maugham's current annotation vocabulary — comment, query, suggested change, craft note — describes the *shape* of a note, not the kind of editing being done. Real editorial practice has distinct passes, and mixing them is the classic failure: a developmental read that stops to fix commas is a bad developmental read, and it is what an unstructured "give me feedback" prompt produces by default.

Four passes, each a distinct Claude behaviour with its own skill and its own instruction not to stray:

- **Developmental** — reads intent first; stays structural. Literally "does this serve what you said you wanted."
- **Line** — sentence rhythm, diction, control. Barely references intent.
- **Copy** — mechanical.
- **Proof** — the last sweep.

Readiness follows from the vocabulary: *"chapters 1–4 have had a developmental pass; none have had a line edit."*

### 4.3 Why they cannot share a surface

This is the correction the compiler framing forced. A durable adjudicated queue and a transient self-clearing list have incompatible lifecycles. Every fast-loop note landing in the Annotations pane would drown the surface review depends on. **Two loops, two surfaces**, and Annotations is deliberately *absent* from the Author persona — which is what enforces the separation rather than merely describing it.

---

## 5. Mechanism

Verified hands-on against Claude Code 2.1.219 and Claude Desktop 1.24012.1 on 2026-07-24. Every protocol-shaped route is a dead end:

- **`sampling/createMessage`** — proven absent from both clients. Claude Code answers `-32601`; Desktop declares no `sampling` capability. Do not build on it.
- **Elicitation** — Claude Code supports form mode (v2.1.76); Desktop supports URL mode only. Either way it **cannot start a turn**: it is only issuable while the server is handling a client-initiated request, and its result returns to the *server*, not into Claude's context. Useful for mid-tool-call questions; useless as a wake-up.
- **Server notifications** — `list_changed`, `resources/updated`, logging, progress are all passive on both clients. None ever wakes the model.
- **`claude/channel`** — exactly the right shape, and clearly what Anthropic is building for this, but gated behind a remote flag (`tengu_harbor`, default false) plus an org policy and a plugin allowlist. A probe server pushing a channel notification produced no turn at all.

Also relevant: `maugham-mcp/JSONRPCBridge.swift` is **strictly half-duplex** — one line in, one reply out, with no independent socket reader — so Maugham currently cannot deliver *any* server-initiated message regardless of mechanism.

**The decision: spawn `claude -p`.** Maugham runs it as a subprocess; that Claude instance connects back to Maugham's MCP server as an ordinary client, reads the delta and the intent through existing tools, and writes back through the existing membrane. Verified working: no window, no TTY, no focus theft, uses the writer's existing login, spawnable from a signed Mac app via `Process`.

Its virtues are structural, not incidental. It sidesteps the half-duplex bridge entirely, depends on nothing undocumented, and composes with §4.2 for free — a named pass is a prompt plus one of the skills Maugham already ships. Notably the *supported public CLI* turned out to be the stable path and the protocol features the fragile ones.

Deliberately deferred, not designed in: making the bridge full-duplex (worth doing on its own merits, as a standalone hardening task with round-trip tests), and declaring `experimental["claude/channel"]` behind a feature flag once it is (cheap, and it no-ops until the gate flips).

---

## 6. The shell

### 6.1 Persona switching

**A persona bar in the toolbar, and a window carries its own persona.** ⌘1–4.

Affinity's Personas are the precedent, and they are the right one: they establish the idiom that the *whole toolset* changes, which is the writer's all-in-or-not-at-all requirement. Per-window mode falls out of Maugham already being multi-window, and it earns its keep on a collection — Planning open beside Authoring rather than instead of it.

The honest cost: permanent chrome in a product whose second principle is get out of the way. Mitigation: the persona bar hides in ⌘\ focus mode with the rest of the chrome, so it costs nothing when you have gone under. Rejected: an activity rail (VS Code's idiom, not the Mac's, and it permanently narrows the writing surface); no chrome at all (calmest, but an invisible mode is an undiscovered mode and readiness would have nowhere to live but a menu).

### 6.2 The keyspace

**Personas take numbers, panes take letters.** ⌘1–4 for the personas; ⌘⌥*letter* for panes — R research, O outline, T tasks, P palette, H history, E references, D diagnostics, and A annotations, which already works this way.

This is forced. The flat ⌘⌥ numeric space is **already full at 8**: palette had to wedge in at 7 and translation took the last slot, and this design adds five more panes. Two orthogonal keyspaces give unlimited headroom and let a pane keep the same key in every persona it appears in. The cost is real — seven existing shortcuts get retrained in a product that treats muscle memory as sacred — and it is accepted because the alternatives are worse: keeping today's numbers leaves each persona with an arbitrary sparse subset and no room for the new panes, and renumbering per persona makes one keystroke mean different things in different places.

### 6.3 Pane redistribution

Today's right pane is nine segments in one undifferentiated picker: Inspector ⌘⌥1, Annotations ⌘⌥A, Research ⌘⌥2, Outline ⌘⌥3, History ⌘⌥4, Tasks ⌘⌥5, Inbox ⌘⌥6, Palette ⌘⌥7, Translation ⌘⌥8. Under four personas each shows five or six.

*● primary · ○ available · — absent*

| Pane | Plan | Author | Review | Publish |
|---|:--:|:--:|:--:|:--:|
| Inspector | ○ | ● | ○ | — |
| Research | ● | ○ | — | — |
| Outline / Corkboard | ● | ○ | ○ | — |
| History | — | — | ● | — |
| Tasks | ○ | ● | ○ | — |
| Inbox | ● | — | — | — |
| Palette | ● | ○ | ○ | — |
| Translation | — | — | ○ | ● |
| Annotations | — | — | ● | — |
| **Diagnostics** *(new)* | — | ● | — | — |
| **References** *(new)* | — | ● | ○ | — |
| **Intent** *(new)* | ● | ○ | ● | ○ |
| **Visual language** *(new)* | ● | — | ○ | ● |
| **Editions & publish config** *(new)* | — | — | — | ● |

Two placements worth calling out. **Inbox moves to Planning** — phone captures are raw planning material, and their current position between Tasks and Palette is why the segment needed an unread badge to be discoverable at all. **Publishing gains the most**: it has no right-pane presence today whatsoever, only binder Exports plus MCP tools plus a preview.

All three columns change per persona, not just the right one:

| Persona | Left | Centre | Right |
|---|---|---|---|
| Plan | Research tree | **Canvas** | Promoted artifacts |
| Author | Binder | **Editor** | Writing companions |
| Review | Pieces by review state | **Read-mostly editor** | Annotations |
| Publish | Editions | **Preview** | Config & visual language |

---

## 7. Planning — canvas and promotion

Mood boards, storyboards, mind maps and "notes organised different ways" are not four features. They are one freeform canvas plus a promotion step.

**The canvas is where you think** — messy, spatial, associative, no schema. **Promotion is the seam**: when something firms up you promote it into a structured artifact (a palette card, an intent statement, a visual-language decision, a beat). The canvas is scratch and stays scratch; the promoted artifacts are what the through-line carries. **Readiness measures the artifacts, never the canvas.**

This is the only shape that serves both halves of the brief — thinking wants freedom and a structured form kills it, but "readiness, gently surfaced" needs something countable and a freeform canvas is unmeasurable by construction. Promotion is also a *deliberate act*, arriving at the moment a thought firms up rather than as a form faced before you're allowed to start, which is the kind of structure the writer said they were trying to encourage in themselves.

**Plain-text invariant:** canvas nodes are real files — research notes, palette cards, images — and only the *layout* (positions, connections, groupings) is sidecar UI state under `.maugham/`. Same trick the palette already plays.

---

## 8. The bridge from planning to authoring

**What you cluster around a piece on the canvas becomes what is pinned beside you when you write it, and what the compiler reads as context.** No separate curation step; the spatial work done in planning pays off directly. Most of the data model exists already — research↔manuscript linking is shipped, with `link_research`/`unlink_research` and a pane that shows a document's own and linked research. What is missing is the surface: today it is somewhere you browse *to*, not something that sits *with* you.

Two distinct needs hide inside "side by side":

**Referencing — pinned, promotable.** The piece's pinned set renders as thumbnails in a References pane (⌘⌥E). Clicking a pin promotes it into a full assistant column between binder and editor, at a size you can actually study; clicking again sends it back. Small by default, big when it earns it — which keeps the three-column layout honest at normal window widths and only squeezes the centred writing column when asked.

> **Amended 2026-08-25**: the studied pin no longer opens a fourth column between binder and editor — it takes the right column itself, in place of the pane picker and the pane, and no longer squeezes the prose. The pinned set also gained structure (sections by canvas region, a promoted region contributing its note). See `docs/superpowers/specs/2026-08-25-references-shelf-and-study-column-design.md`.

**Glancing — the intent strip.** A single dimmed line above the prose, permanently visible in the Author persona, hidden in ⌘\ focus mode. This is the compiler frame made literal: an IDE keeps the signature in view while you write the body. It is not a pane and you never open it; you just never quite lose it.

---

## 9. Readiness

Each mode has a defined output, and readiness reports the state of those outputs. It renders where metrics already render — on sight, never announced, no streaks, no nagging.

**Readiness is per-piece, not per-project.** For a novel the four modes are roughly an arc; for a collection they are concurrent — piece one in review while piece six has not been planned. The persona is a lens over the collection, and the useful number is *"three pieces have had a developmental pass, two have no intent recorded,"* not a project-level percentage.

---

## 10. Sequencing

Four milestones. Planning first, then the compiler, then review, then publish.

**Why planning first, against the instinct to ship the highest-desire feature earliest:** the compiler is only as good as the type system. Its entire value is checking prose against declared intent, and if intent has been scribbled into a plain document because there is no good surface for declaring it, the feedback comes back generic — which would poison the one feature the writer already knows they want.

### M1 — Planning persona + the spine
The persona shell (bar, per-window mode, keyspace migration, pane redistribution), intent as an op-logged artifact with derived structure, visual language, the canvas, and promotion.

Two protections, because this is the only from-scratch build in the design and it is going first:
- **Scope the canvas so the milestone cannot fail on it.** The commitments are promotion, intent-with-history and the shell. Spatial editing ships deliberately simple — cards, images, groupings, connections, saved layout — with cleverness deferred.
- **Give visual language a consumer in the same milestone.** Otherwise it is an artifact that does nothing for three milestones. The cheap half of the publish work is Claude *reading* visual language when authoring a template: an MCP read tool and a line in a skill. Ship that here; recorded derived decisions stay in M4.

### M2 — Author persona + the compiler
`claude -p` invocation, structured op-log delta, Diagnostics pane with ¶-anchored dismissal, promote-to-task, the intent strip, pinned references and the assistant column.

### M3 — Review persona
Named editorial passes with distinct behaviours, intent↔draft comparison, per-pass readiness, and the `author`/`source` provenance field on annotations.

### M4 — Publish persona
Editions and config as a real surface, recorded derived design decisions, drift checking against visual language.

---

## 11. Out of scope

- **Human reviewers / the collaborator layer.** The largest open bet in Group 2, with its own provisional design (three roles, a transferable author lock, owner force-takeover). Folding it in would roughly double this. The `author`/`source` provenance field lands in M3 so that human reviewers are an additive milestone rather than a retrofit.
- **A full-duplex MCP bridge and `claude/channel`.** Worth doing, separately, on their own merits — see §5.
- **Continuous background analysis.** Constitutionally excluded, not merely deferred.
- **Phone surfaces for any of this.** Planning, the compiler and passes are Mac-only in this design.

---

## 12. Open questions

- **How much of today's Inspector belongs in Planning**, given the canvas takes over most of what "look at this item's metadata" means there.
- **What promotion looks like as a gesture** — drag to the artifact rail, a context action, or a keystroke. Deliberately left to M1's spec.
- **Whether Review's left column ordering is a new view or a filter** over the existing binder.
- **How a diagnostic promoted to a task carries its reasoning** — the note's text, a reference to the run, or both.
- **Whether the intent strip shows project intent, piece intent, or a blend** when both exist.
