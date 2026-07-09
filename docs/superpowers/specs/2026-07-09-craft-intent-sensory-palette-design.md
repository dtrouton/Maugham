# Craft Intent + Sensory Palette — Design

**Date:** 2026-07-09
**Status:** Implemented (branch feat/craft-intent-sensory-palette, 2026-07-09)
**Roadmap home:** Group 1 (mood board item, `docs/roadmap.md` "Visual reference") + first concrete instance of Group 2's prompt-templates item

## Problem

The writer's stated craft problem: "I can veer away from texture and detail. I want to push my writing to be more grounded **when it's right for the story** — but not every story needs that, so I want to force myself to be thoughtful about what I think the story needs."

This is not a detector problem ("find scenes with no smell"). It is an **intent-first** problem: declare what the story needs, gather the material, then audit the draft against the declaration. A universal sensory lint would false-positive on deliberately spare stories; measurement must be relative to declared intent.

## The loop

1. **Declare** — an optional freeform craft-intent doc states what this piece needs sensorially.
2. **Gather** — a sensory palette (subject-keyed cards: images, swatches, sensory notes) holds the material.
3. **Audit** — a Claude "sense pass" reads intent + palette + manuscript over MCP and leaves paragraph-anchored annotations through the existing membrane.

Absence of an intent doc is a first-class valid state: "this story doesn't need the apparatus" is itself the thoughtful decision the feature exists to force.

## Component 1 — Craft-intent doc

- **Scope grain:** one optional doc per intent scope — the project for novel/screenplay/short-story; **per piece** in a collection (loose docs and project references each get their own), riding the existing per-item metadata grain.
- **Format:** freeform markdown. No dials, no schema. The forcing function is served by writing the reflection, not filling a form. (Optional light structure for a future mechanical layer is explicitly deferred.)
- **Location on disk:** reference material, not manuscript — lives with notes/research content, so it is automatically outside compile/publish. Plain text, portable.
- **Creation/entry:** an explicit, quiet affordance ("Add craft intent…") from the binder/inspector for the relevant scope. **Never a nag, badge, or gate.** The only surfacing of absence is the affordance itself.
- **Editing:** plain-file editing on the research-note pattern (`ResearchNoteEditor` + `DocumentStore.scheduleFileSave`, 750ms debounce) — **not** op-logged, no ¶id anchors. The `Document.load`/Bootstrap invariant is for manuscripts; intent docs and palette cards are reference material, exactly like research notes (which established this precedent). *(Amended 2026-07-09 after codebase exploration; the original draft wrongly routed this through Bootstrap.)*
- **Living doc:** revised as the story teaches the writer what it is; nothing pins it to project creation.

## Component 2 — Sensory palette

### Data model

- A **card per subject**: `kind` enum (location / character / motif / other) + free-form name.
- A card holds:
  - **Images** — ordinary research images, referenced from the card.
  - **Colour swatches** — hex values.
  - **Sensory notes** — freeform lines, each optionally tagged by sense (sight / sound / smell / touch / taste); untagged lines valid.

### On disk (plain-text invariant)

- Each card is a markdown file under `research/palette/<subject>.md`; images live as normal research files and are referenced by relative path; swatches are hex strings in the markdown. Human-readable, portable, git-diffable.
- Cards are ordinary research assets under a `research/palette/` **group** in the manifest research tree — so rename/move/trash/reorder ride the existing typed-mover machinery and ResearchView affordances for free, and wall ordering is manifest order. No new `.maugham/` layout state needed. *(Amended 2026-07-09: the manifest tree supersedes the earlier "layout under `.maugham/`" idea.)*
- All moves/deletes of card files go through the typed `DocumentStore` mover (tripwire 14).

### Presentation A — the wall (main content surface)

- A **visual wall** of cards in the main content area: image thumbnails, swatch strips, sensory-note snippets. Rhymes with the Corkboard pattern from the Writing Companion milestone. Click a card to open/edit it.
- Reached as a **binder segment** (like Research).
- **Room for the wall:** entering the Palette segment **auto-hides the right pane (inspector)** and restores its prior state on leaving. The binder remains collapsible via its existing toggle. The wall lays out adaptively to available width (no fixed-column assumption). Default = binder + full remaining width; one keystroke = whole window.
- Freeform spatial canvas (drag-anywhere pinboard) is **deferred presentation polish** — the subject-keyed model does not preclude it.
- Per-row/card rendering must cache derived content (tripwire 4 — no per-card re-parse on wall layout).

### Presentation B — palette card in the right pane (write against it)

- A new **right-pane mode** in the ⌘⌥N mode-swap family (ADR 0005): pick a subject card, view it **read-only** beside the editor — images, swatches, sensory notes — while drafting the scene it belongs to. Click-through opens the full card/wall.
- This is the feature's daily face: the wall is where you gather; the right-pane card is what you write against.
- Follows the established pane conventions: `ContentUnavailableView` empty state with full-frame + top-anchored outer VStack (tripwire 15), `AdaptiveFilterRow` if a filter row is needed.

## Component 3 — Claude sense pass (MCP + annotation membrane)

- **New read-only MCP tools (3):** `read_craft_intent`, `list_palette_cards`, `read_palette_card`. Registered via `MCPToolCatalog.all` like all tools; fail loudly on unknown ids; responses under the 1 MB cap. **`read_palette_card` serves images**, reusing the existing crop-on-demand image polymorphism from `read_document` (ADR 0004 / mixed-content milestone): the card's text (name, kind, swatches, sensory notes) plus its images as image content blocks, crop-on-demand keeping each response under the transport cap.
- **MCP never mutates** holds: intent doc and palette are writer-authored; Claude reads. (Claude *proposing* palette additions is deferred.)
- **The sense pass is a curated prompt template** — the first concrete instance of the Group 2 "project-level Claude prompt templates" backlog item: "Do a sense pass on <doc>" pre-wired to read the craft-intent doc, relevant palette cards, and the manuscript, then leave **paragraph-anchored annotations via the existing tools** (`add_comment` / `add_craft_note`). No new `OpKind`; sense-pass output inherits the full Accept/Reject/Archive membrane and AnnotationsPane surface for free.
- **No intent doc present:** the template instructs Claude to say so and either offer a generic pass or help the writer draft an intent doc — never to invent a standard silently.

## Out of scope (deferred, not rejected)

- Mechanical always-on sensory lint / sense-coverage grid / density analytics — a later opt-in analytical layer for pieces where the writer adds structure; fits the Author's IDE arc when it comes.
- Freeform spatial canvas presentation for the wall.
- Per-scene intent dials.
- Phone surface for palette/intent (Read tab shows manuscripts; palette is Mac-only this milestone).
- Claude proposing palette additions via annotations.
- A dedicated annotation tag/filter for sense-pass results (add later if volume demands).

## Testing shape

- Card markdown round-trip: parse ↔ render stability for images/swatches/sensory-note tags.
- Palette store CRUD through the typed mover; grep tripwire coverage extends automatically.
- MCP tools against fixture projects (including a collection with per-piece intent docs; including the no-intent-doc case).
- Intent-doc save path covered by the research-note plain-edit pattern (raw reads carry `// adr-0018-ok:` annotations per the ADR 0018 addendum).
- Wall view: card-derivation caching pinned (no per-card re-parse per layout pass).
- Right-pane mode: mode-swap registration + empty-state layout (tripwire 15 pattern tests where practical).

## Risks / tripwires touched

- `ProjectWindow.body` grows (new binder segment + right-pane mode): extract `ViewModifier`s per house pattern; **run a local Release build before tagging** (Release type-check budget).
- New binder segment must follow `BinderSegment` conditional-case auto-coercion conventions.
- Pane show/hide on segment entry must restore prior state exactly (no stuck-hidden inspector); scoped via `MaughamEvent` if cross-window signalling is needed (tripwire 21).
- Every new data type gets a UI surface (house rule): intent doc → binder affordance + editor; palette card → wall + right-pane mode. MCP-only access would violate the rule; this design satisfies it.

## Resolved micro-decisions

- Intent doc lives with research/notes content (out of publish automatically). **(approved)**
- Sense-pass annotations reuse existing annotation kinds; no new `OpKind`. **(approved)**
- Wall room: auto-hide inspector on segment entry + adaptive width; binder collapsible as usual. **(approved)**
- Right-pane palette-card mode is in scope this milestone. **(approved)**
