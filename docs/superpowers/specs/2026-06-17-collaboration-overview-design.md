# Collaboration — design overview & decomposition

**Status:** Brainstormed design, not yet specced per-slice · **Date:** 2026-06-17

This document captures the coherent shape of Maugham's collaboration vision and decomposes it into shippable slices. It is **not** a single implementation spec — the bet is too large for one. Each slice below gets its own spec → plan → implementation when it's picked up. This overview is the durable record of the decisions made in the 2026-06-17 brainstorm so later specs don't re-litigate them.

It supersedes the sketched "Human reviewer / collaborator layer (single-author lock)" bullet in `docs/roadmap.md` Group 2 and the deferred same-paragraph-conflict note in `Maugham/OpLog/AREA.md`.

## Purpose

Generalize the proven Claude annotation membrane ("Claude proposes via the annotation layer; the writer disposes via the UI") to **human collaborators**, and then to **co-authors who take turns owning a document**. The manuscript stays files-on-disk; everything rides the existing op log + per-device JSONL partitioning ([ADR 0012](../../adr/0012-per-device-jsonl-partitioning.md)) + ULID ordering. No accounts, no new server.

## The two-workflow split

The vision divides cleanly into two workflows, and the relationship between them is load-bearing:

1. **Workflow 1 — One author, many reviewers.** Roles are fixed. Reviewers annotate exactly like Claude does today (comment / suggest change / query), and the author disposes via the existing `AnnotationsPane`. The work is the *annotation surface and its UX*, plus telling reviewers apart from Claude and each other.

2. **Workflow 2 — Co-authors with a per-document baton.** Per piece there is exactly one author; the role can be handed off. You are the author on some pieces and a reviewer on the rest (a collection can have a different author per piece).

**Key relationship: Workflow 2's "reviewer" role *is* Workflow 1.** Anyone who is not the author of a given piece is, for that piece, exactly a Workflow-1 reviewer. So WF1 is the *foundation*, and WF2 = WF1 + (the baton + the ability to become an author). WF2 generalizes a single predicate — "am I the author of *this* doc?" — and otherwise leaves the WF1 design untouched.

---

## Workflow 1 — components and resolutions

| # | Component | Resolution |
|---|---|---|
| 1 | Identity & provenance | Derived from **iCloud Drive collaboration metadata** (see below): `.owner` / `.participant` role + owner/editor **names** as free provenance. A Settings display-name acts as override/fallback. |
| 2 | Reviewer entry + membrane | Role derived from iCloud; **annotate-only membrane enforced at the app layer** (write annotation ops, refuse manuscript-text ops; binder restructuring disabled; ⌘S checkpoint is the author's). |
| 3 | Authoring interaction | **Floating toolbar** over the selection (Comment · Suggest · Query) → compose **in the margin slip**. Suggested change = **scoped inline editing** of the span. |
| 4 | Anchoring model | Paragraph `¶id` spine + quoted-span sub-anchor; **stateless fuzzy re-find**; lost → stale-and-flagged; cross-paragraph → manual recovery. |
| 5 | Disposition (pane) | Extend `AnnotationsPane`: human annotations flow in alongside Claude's, provenance display, filter-by-author, **"stet" on reject**. |
| 6 | Review render | A distinct review *posture* (task-vs-role): margin rail + leader lines + pencil colours + clean small-caps names; layered mark / slip / colour vocabulary. |
| 7 | Phone read surface | Read-only reviewer consumption; same iCloud role signal; provenance display. **No authoring on phone.** |
| 8 | Transport | iCloud Drive **Collaborate** (CKShare); guided setup; sane fallback when an item isn't shared. |

### Identity via iCloud collaboration metadata (components 1 + 8)

iCloud has two modes. **Personal sync** (one Apple ID, several of the user's own devices) has no "other person" concept — every device is the author, trivially. **iCloud Drive collaboration** (a folder shared via Share → Collaborate, CKShare-backed) exposes ownership metadata the OS computes, available on both macOS and iOS as `URLResourceKey`s (and matching `NSMetadataItem` attributes):

- `.ubiquitousItemIsSharedKey` — is the item shared at all.
- `.ubiquitousSharedItemCurrentUserRoleKey` — **`.owner` vs `.participant`** (the decisive signal).
- `.ubiquitousSharedItemCurrentUserPermissionsKey` — `.readOnly` vs `.readWrite`.
- `.ubiquitousSharedItemOwnerNameComponentsKey` — owner's name (`PersonNameComponents`).
- `.ubiquitousSharedItemMostRecentEditorNameComponentsKey` — last editor.

Consequences:
- "My other device" → same Apple ID → personal sync or `.owner` → **author** (no false demotion of one's own second Mac).
- "A different person" → `.participant` → **reviewer**, automatically — no manual toggle, no cooperative bit to invent.
- The collaborator's **name comes free** → it's the provenance/display-name for the pencil-colour slip (overridable in Settings).
- The "no accounts" constraint is satisfied — it's the user's *existing* Apple ID, not a Maugham account.

Caveats baked into the design:
1. Works only when the user shares via **Collaborate** (CKShare), not by both syncing a plain folder. Setup flow must guide this; fallback when unshared = treat as author / own copy.
2. **The read-only trap:** an iCloud read-only share blocks *all* writes on the participant's device, including op-log annotation files. Reviewers therefore need iCloud-level **read-write**, with the annotate-only membrane enforced at the **app layer**. We cannot lean on iCloud read-only to enforce the membrane — too blunt.
3. The ubiquity metadata can **lag or be briefly unknown** on first open — needs an "unknown yet → treat cautiously" state. Read once on open + on share-state-change notification; **cache it**; never poll, never read per-render.

### Anchoring model (component 4) — the deepest decision

Annotations stay **paragraph-centric at the identity/storage/merge layer** — the `¶id` join, paragraph-keyed LWW, and the whole op log are untouched. Sub-paragraph precision is added as an **optional quoted-span sub-anchor** on top, so paragraph-level is just the degenerate case (empty span). We do **not** adopt character-range anchoring (no stable identity; resolves the hardest part of collaborative editing from scratch).

The anchor record: **`¶id` + quoted span + prefix context + suffix context + positional hint (tiebreaker only)** — the W3C `TextQuoteSelector` pattern (exact + prefix + suffix), with position as a weak tiebreaker per diff-match-patch.

Re-find is **stateless** — recomputed from the quoted text on every derive, never persisted and mutated. This matches the op-log "everything is derived" philosophy, can't drift (immune to the OT range-drift class of bug), and makes undo/rewind re-attach for free. A span is **always within one paragraph** (a cross-paragraph selection clamps to the first).

Re-find is a **tiered similarity match**, mirroring `RenderFilter`'s paragraph re-attachment at sub-paragraph scale and reusing its tuned constants as starting points (0.6 overlap / 0.1 margin):
1. Exact (normalized) substring → highlight. Normalization handles **smart-typography drift** (curled quotes, dashes, whitespace) — a Maugham-specific footgun that must be handled or spans go spuriously stale.
2. Fuzzy window (character-bigram overlap — the tool `RenderFilter` uses for short text), disambiguated by prefix/suffix context → re-anchor. Tuned **deliberately lenient** so incidental edits (a comma, a nearby typo fix) keep the comment anchored; only a genuine rewrite of the commented words drops below threshold.
3. No window clears threshold → collapse to paragraph + **stale**.

Behaviour matrix:
- Span intact, paragraph edited around it → silent re-anchor.
- Repeated span, a *different* occurrence deleted → prefix/suffix context still uniquely identifies the target (numeric offset alone could not). Truly identical text with identical context → nearest-to-position last resort.
- The commented words themselves rewritten / deleted → stale + flagged (we do **not** distinguish "deleted" from "rewritten"; both = commented text gone). **Flag, never silently auto-resolve** — silently removing a reviewer's note is the confusing behaviour we are avoiding; offer one-click resolve instead.
- Paragraph split/merge → after `RenderFilter` re-keys `¶id`s, re-find the span across the result; lands wholly in one → re-anchor; straddles the split → stale.
- Paragraph deleted → orphan → archived by the existing `SweepReason` sweep.
- Captured against text the author never saw (skew) → re-find against current state → found or stale; no special-casing (statelessness handles it).

**Automatic where safe and cheap, manual-with-confirmation where risky or expensive:**
- Within the home paragraph → automatic fuzzy re-find.
- Lost in the home paragraph → stale + flagged.
- Beyond the home paragraph (cut-and-paste moved the text) → **manual, on demand:** a stale comment offers **"Find moved text…"** (doc-wide quote+context search → ranked candidates → confirm) plus **"Reattach to selection"** (point at any text to bind manually). This keeps the expensive cross-paragraph search off the derive path and the risky guess behind human confirmation. The reattach action generalizes to any orphaned annotation.

**Contracts:** capture and re-find both operate on **`MarkdownDisplayFilter` output** (display text), never raw source with anchors/markers. A stale `suggested_change` **blocks accept** (or hard-confirms) and accept applies to the *re-found* window. Re-find runs on the derive/debounce boundary, **scoped to annotations whose home paragraph changed** — never per keystroke over all annotations. Offset math operates on grapheme clusters, not UTF-16 (editor ↔ model seam tripwire).

### Review render (component 6) — a first-class editor surface

Reviewing is a different cognitive task from drafting, so it gets its own **editor posture**, lavished with the same care as the writer's mode:
- **Task vs role:** default (and only) posture for the reviewer role; an **opt-in toggle** for the author (read through everyone's notes, then back to drafting). The existing ⌘\ / ⌘⇧F drafting modes are untouched.
- Focus dimming and typewriter scroll **off** (reading, not composing).
- **Margin comment rail** (Google-Docs lineage) with **hand-drawn leader lines** from the marked text to the margin slip.
- Identity by **muted pencil colour + clean small-caps name** — *no fake handwriting*. Capped palette (never a rainbow). **Claude on a fixed terracotta tint** so it never competes with a human's pencil.
- A **layered vocabulary**, pared to marks that genuinely communicate: the **mark = kind** (strike-and-caret = edit, pencil underline = comment, **Qy?** = query), the **slip = why**, the **colour = who**.
- Two grace notes: **Qy?** for queries; **"stet"** (the proofreader's "let it stand") shown briefly when the author *rejects* a suggested change.

### Authoring interaction (component 3)

A reviewer creates an annotation by selecting a span; a minimal dark **floating toolbar** appears above the selection (Comment · Suggest · Query). Choosing a kind opens a fresh **slip in the margin rail** (pencil-coloured, kind pre-selected, selected text echoed). A quiet margin "+" is an optional secondary affordance.

**Suggested change** uses **scoped inline editing** (model 3 of three considered): the selected span itself becomes editable inline; the diff (original → edited) becomes the suggestion, previewing as strike-and-caret. This delivers the "just fix it" feel, handles replace/insert/delete uniformly, and anchors exactly to the span we already capture — without the document-wide edit-interception of a full Google-Docs "Suggesting mode." An explicit replacement field is the fallback for fiddly cases; **full Suggesting mode is a possible future upgrade** once op-mapping is proven.

---

## Workflow 2 — the co-author baton

### Baton as advisory, derived op-log state

The baton lives as **derived op-log state**, like annotations and tasks: `handoff` / `force-takeover` ops, doc-scoped, synced via per-device JSONL. "Author of doc X" = the head of the baton chain. The WF1 membrane predicate — "am I the author of this doc?" — simply changes its answer source (WF1: "am I the iCloud owner?"; WF2: "do I hold this doc's baton, or own an unclaimed doc?"). Everything else in WF1 is untouched.

**The baton cannot be an absolute lock.** iCloud is eventually consistent with no coordinator; true mutual exclusion across a partition is impossible. The baton is therefore **advisory** — it prevents most collisions *socially*. The real safety net is same-paragraph conflict surfacing (below). The two are a pair; the lock alone would be a false promise.

### Directed handoff, CAS-chained

Chosen over a release-to-pool model because it **shrinks the conflict surface**: authority to move the baton flows only from the current holder (single-writer-per-handoff), the strongest property available without a coordinator.

- Baton is always held by **exactly one** person. Initially the **owner holds all** docs and authors unclaimed ones by default.
- Moves only by **directed handoff** from the current holder ("I hand doc X to Bob").
- **"Release" = hand back to the owner** — the baton is never truly on the floor; the owner is always a valid recipient/fallback.
- **Owner-only force-takeover** is the sole non-holder-initiated move, for a stuck/unreachable holder (warned override).
- Each handoff op **names the baton op it supersedes** (compare-and-swap). The Deriver walks the chain; a handoff built on a stale parent, or two handoffs sharing a parent (a **fork** — e.g. the holder acting on two offline devices), is detected → deterministic ULID winner + **surfaced** ("handed off twice from the same point").

No new transport — op log + ULID + a parent-pointer CAS chain. iCloud just syncs files; all logic is in the Deriver's interpretation of the merged set.

A genuine *unclaimed pool* (anyone-can-grab) was considered and **not adopted** — directed handoff + release-to-owner covers the need without claim races.

### Same-paragraph conflict surfacing — the backstop

This is WF2's first deliverable (spec first), and it **also hardens today's solo-multi-device case** (the deferred audit-0.2 skew-induced LWW loss) — so it earns its keep even before the baton.

- **Detection:** every edit op carries a **fingerprint (hash) of the paragraph text it edited from** — its base version (the causal context that pure ULID-order replay loses). On merge, two edits to the same paragraph that **share a base but diverge** = concurrent conflict, surfaced instead of silently LWW'd. (Edits where one's base equals the other's result are causally ordered → no conflict.)
- **Granularity:** per-paragraph and surgical — only the divergent paragraph is flagged; the rest of the doc merges cleanly.
- **Resolution:** reuse the **existing side-by-side conflict diff sheet** (milestone 2b `LineDiff`) as a proper **3-way** (base / mine / theirs — we have the base), resolved by the doc's current author. Extends an existing surface rather than inventing one.
- **Forward-only:** legacy ops lack fingerprints and can't be retro-conflicted (consistent with the no-migration rule, tripwire 11).

### Baton UX — to be designed in Slice 4's spec

Binder per-piece authorship display, the handoff gesture, the force-takeover confirmation dialog, and graceful mid-edit demotion (a held doc force-taken from you → you become a reviewer, editor locks, your already-autosaved ops remain). Conventional UI, low design risk; deferred to the slice spec.

---

## Performance considerations

Every new cost is deliberately placed on the **merge/sync/load** path or the **flush edge**, both cold relative to typing. The codebase guards the keystroke path hard (tripwires; `TypingLatencyProbeTests`; the v0.10/v0.11 typing-latency milestones).

1. **`prior` fingerprint compute** — on the `PendingBuffer`/`flushBurstNow` edge where ops are minted, **never per keystroke**; hashing one paragraph is microseconds. Assert this in a probe test.
2. **Fingerprint storage** — an 8-byte (64-bit) truncated hash per edit op (collision worst-case = a *missed* conflict, never corruption). Interacts with the [ADR 0016](../../adr/0016-op-log-growth-without-compaction.md) growth budget; high-entropy so won't LZFSE-compress in sealed segments. **Re-baseline op-log size on the 100k-word perf fixture** before locking — the one place this could quietly cost.
3. **Detection cost** — O(1) hash-compare per edit op during derive; derive runs at load/sync, not per keystroke. Conflict *materialization* (base/mine/theirs) only on the rare hit.
4. **Identity metadata reads** — cache iCloud role/name on open + share-change notification; never poll, never per-render (ubiquity reads lag/block).
5. **Anchoring re-find** — scoped to changed paragraphs, on the derive/debounce boundary.
6. **Mark rendering** — from cached derived annotation state; leader-line geometry recomputed on layout change only.

Verification follows the v0.11 lesson: re-baseline with `TypingLatencyProbeTests` *and* a live `sample` during *active* typing (an idle sample once masked a real regression). Bar: no measurable keystroke-path change.

---

## Decomposition into shippable slices

| Slice | Scope | Ships |
|---|---|---|
| **Spike** | Confirm iCloud shared-item `URLResourceKey`s on current macOS/iOS with a real shared folder | de-risks the identity story |
| **1 · Identity + membrane** | iCloud Collaborate setup, owner/participant role detection, provenance names, app-level annotate-only membrane, Settings name override, the (static) "am I author of this doc?" predicate | a collaborator opens a shared project *as a reviewer* |
| **2 · Authoring + anchoring** | Floating toolbar, margin compose, comment/query, quoted-span anchoring + re-find + reattach, scoped inline suggesting | humans annotate like Claude — the headline |
| **3 · Review render** | Margin rail, leaders, pencil palette, marks vocabulary, Qy?/stet, pane provenance + filter, phone provenance | the crafted editor experience |
| **4 · The baton** | Directed-handoff op model, CAS chain, release-to-owner, force-takeover, binder authorship UX + mid-edit demotion, per-doc membrane predicate | true co-authoring |
| **5 · Conflict surfacing** | `prior`-fingerprint detection, 3-way resolution via the existing conflict diff sheet | the safety net — *also fixes today's solo-multi-device skew gap* |

**Sequencing notes:**
- Spike first; the identity story leans on it.
- Slices 2 + 3 may merge or follow fast (3 is the polish of 2's plumbing).
- **Slice 5 is promotable earlier/independently** — it hardens the existing single-user multi-device case, so it has standalone value before the baton.
- The membrane (slice 1) is the static special case of the baton predicate (slice 4); building it static-first then generalizing is deliberate, not rework.

## Deferred / out of scope here

- **Full Google-Docs "Suggesting mode"** — future upgrade after scoped inline suggesting proves the op-mapping.
- **Unclaimed-pool claiming** — considered, not adopted (directed handoff + release-to-owner suffices).
- **VCS-steals** (patch commutation / real merge to replace LWW; signed checkpoints; per-paragraph blame) — a later arc, surfaced in the 2026-06-07 backup brainstorm; not part of these slices.
- **Cryptographic enforcement** of roles/membrane — the WF1/WF2 membrane is cooperative + app-enforced, appropriate for trusted collaborators. Hard enforcement is not pursued (no coordinator on iCloud).

## Related

- `docs/roadmap.md` Group 2 — the bullet this supersedes.
- [ADR 0012](../../adr/0012-per-device-jsonl-partitioning.md) — per-device JSONL; the sync substrate the baton and annotations ride.
- `Maugham/OpLog/AREA.md` — the merge/derive contract; the deferred-conflict note this picks up.
- Milestone 2b (Conflict diff sheet) — the resolution UI reused for same-paragraph conflicts.
- Milestone editing (2026-05-19) — the annotation membrane WF1 generalizes.
