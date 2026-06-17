# Workflow 1 — Human Reviewers (milestone spec)

**Status:** Spec for implementation · **Date:** 2026-06-17
**Parent:** [`2026-06-17-collaboration-overview-design.md`](2026-06-17-collaboration-overview-design.md) (rationale lives there; this is the *what to build*)

## Goal

A human collaborator opens a project the author has shared via iCloud Drive, is recognized **by name** as a reviewer, and can leave **comments, suggested changes, and queries** against the manuscript — annotating exactly as Claude does today — in a crafted review surface. The author disposes of those annotations in the existing `AnnotationsPane`. The manuscript text stays the author's; the reviewer never mutates it.

This bundles overview slices **1 (identity + membrane) + 2 (authoring + anchoring) + 3 (review render)** plus the de-risking **spike**.

## Non-goals (explicitly later)

- The co-author **baton** and **same-paragraph conflict surfacing** (WF2, separate milestone).
- Full Google-Docs "**Suggesting mode**" (scoped inline suggesting is enough for v1).
- Authoring **on the phone** (phone is read-only consumption + provenance display).
- Cryptographic enforcement (membrane is cooperative + app-enforced for trusted collaborators).

---

## Task 0 — Spike (do first, gates the approach)

Confirm on current macOS **and** iOS, against a *real* iCloud-shared folder, that these `URLResourceKey`s behave as documented:
`.ubiquitousItemIsSharedKey`, `.ubiquitousSharedItemCurrentUserRoleKey` (`.owner`/`.participant`), `.ubiquitousSharedItemCurrentUserPermissionsKey` (`.readOnly`/`.readWrite`), `.ubiquitousSharedItemOwnerNameComponentsKey`, `.ubiquitousSharedItemMostRecentEditorNameComponentsKey`.

Record: which keys populate, how quickly after open (latency / "unknown" window), whether the participant name is reliably present, and behaviour for an *unshared* item. **Contingency:** if role/name are unreliable, fall back to a Settings-declared identity + an explicit "Open as Author / Reviewer" prompt (overview option B) — the rest of the milestone is unaffected because everything downstream consumes a single resolved role, not iCloud directly.

---

## Component A — Identity & role (MaughamCore + Mac/phone seams)

**`CollaborationRole`** (MaughamCore, shared): `.author` | `.reviewer` | `.unknown`. Plus a resolved **`Collaborator`** value: `{ id, displayName, role }`.

**`ShareIdentityResolver`** — reads the iCloud resource keys for the project URL, maps `.owner`→author / `.participant`→reviewer / not-shared→author, extracts owner & current-user names. Returns `.unknown` until the ubiquity layer reports. **Read once on project open + on a share-state-change notification; cache the result; never poll, never read per-render** (ubiquity reads lag/block). The platform-specific URL read sits behind a protocol seam (Mac and phone inject their own), but the role mapping + caching is shared MaughamCore (per the cross-surface contract registry — phone must not reimplement it).

**Display-name override:** a Settings field (`UserPreferences.collaboratorDisplayName`) supplements/overrides the Apple-ID name for provenance. Per-device, no account.

**The author predicate (static for WF1):** `isAuthor(of: doc) == (role == .author)`. WF2 later generalizes this to consult the baton; structure it as a single function now so WF2 only changes its body.

## Component B — The membrane (Mac app)

When `role == .reviewer`, the app is **annotate-only**:
- **Editor:** manuscript text is **read-only** — `EditorHost`/`EditorCoordinator` reject text-mutating input (no typing, paste-over, delete into the manuscript). Selection, navigation, find, scroll, copy all still work.
- **Binder:** structural ops disabled — new/rename/move/duplicate/delete/reorder/trash. (Reuse the typed `DocumentStore` mover's call sites as the choke points.)
- **⌘S checkpoint:** disabled (checkpoints are the author's project-scope action).
- **Allowed:** reading everything, navigating, find, opening research, and **creating annotations** (Component D).
- **`.unknown` role:** treat cautiously — read-only until resolved (don't flash author affordances then yank them).

Enforcement is app-layer, not iCloud-read-only (a read-only iCloud share would also block annotation-op writes — reviewers need read-write at the iCloud level). The reviewer's annotation ops are ordinary op-log appends to their per-device JSONL ([ADR 0012](../../adr/0012-per-device-jsonl-partitioning.md)).

## Component C — Provenance on annotation ops (MaughamCore)

Add **`Op.Provenance.author`** (audit item 7): an optional `{ sourceKind: .claude | .human, displayName, collaboratorId }` carried on annotation-creating ops. Annotation **kinds are source-agnostic** — a human comment uses the same kind as a Claude comment, distinguished by provenance. (`comment` / `suggestedChange` / `query` / `craftNote` already exist as op kinds and MCP tools — `add_comment` / `add_suggested_change` / `add_query` / `add_craft_note`.)

`AnnotationDeriver` surfaces provenance on the derived `Annotation`. Schema evolution per [ADR 0015](../../adr/0015-persisted-schema-evolution.md): optional field, legacy ops decode with `author == nil` → rendered with the existing generic style. **Forward-only**; no migration (tripwire 11).

**The Claude emit-sites must stamp `.claude` provenance** (`sourceKind: .claude, displayName: "Claude"`) — otherwise Claude's annotations decode as legacy `nil` instead of getting the terracotta tint. **Wrinkle, recorded:** the existing op-kind raw values are `claude_comment` / `claude_query` / `claude_craft_note` / `claude_archive`. We **do not rename them** (renaming raw values breaks decoding of existing ops — violates no-migration, tripwire 11). They keep the historical prefix on disk but are now **semantically source-agnostic** — *provenance* is authoritative for "who," the kind is only "what." A human comment and a Claude comment share the kind and differ only in provenance.

## Component D — Authoring interaction (Mac app)

**Trigger:** select a manuscript span → a minimal floating toolbar appears above the selection: **Comment · Suggest · Query**. (Optional quiet margin "+" as secondary.)

**Compose:** choosing a kind opens a fresh **slip in the margin rail** (pencil-coloured, kind preselected, selected text echoed). Type + ⏎ to post → emits the annotation op with provenance + anchor.

**Suggested change = scoped inline editing:** the selected span itself becomes an inline editable field; the reviewer types over it; the diff (original → edited) is captured as the `suggestedChange` payload, previewing as strike-and-caret. Bounded to the span (no document-wide edit interception). Explicit replacement field is the fallback for awkward cases.

## Component E — Anchoring model (MaughamCore — the technical core)

Annotation anchor record gains an **optional span sub-anchor**: `{ quote, prefix, suffix, posHint }` on top of the existing `¶id`. Empty span ⇒ paragraph-level (degenerate case). Capture and re-find operate on **`MarkdownDisplayFilter` output** (display text), never raw source. Offsets are **grapheme-cluster** based (not UTF-16), bridged at the editor seam.

**`SpanAnchorResolver`** (MaughamCore, new) — **stateless** re-find, recomputed each derive, never persisted-and-mutated:
1. Exact normalized-substring match (normalize smart quotes / dashes / whitespace — Maugham smart-typography footgun).
2. Fuzzy window via character-bigram overlap (reuse `ShingleMatcher.bigramOverlap`), disambiguated by prefix/suffix context, position as tiebreaker. Reuse `RenderFilter`'s tuned constants as starting points (0.6 overlap / 0.1 margin); tune **lenient** so incidental edits keep the anchor.
3. No window clears threshold → **stale** (collapse to paragraph, flag).

Behaviour: paragraph deleted → existing `SweepReason` archive; paragraph split/merge → re-find after `RenderFilter` re-keys, re-anchor if the span lands wholly in one resulting paragraph else stale. **Flag stale, never silently auto-resolve.**

**Manual recovery** (cross-paragraph / moved text): a stale annotation offers **"Find moved text…"** (doc-wide quote+context search → ranked candidates → confirm) and **"Reattach to selection."** This is the only place the expensive doc-wide span search runs — on demand, never on derive.

**Performance contract:** re-find runs on the derive/debounce boundary, **scoped to annotations whose home paragraph changed** — never per keystroke over all annotations. Pin with a probe-style test. (No keystroke-path change is the bar; nothing here touches `flushBurstNow`'s hot path.)

## Component F — Review render (Mac app)

A distinct **review posture** for the editor:
- **Task vs role:** default & only posture for `role == .reviewer`; **opt-in toggle** for the author. Existing ⌘\ / ⌘⇧F drafting modes untouched. Focus-dim + typewriter **off** in review.
- **Margin comment rail** with **leader lines** from marked text to slips.
- Identity by **muted pencil colour + clean small-caps name** (no handwriting). Capped palette, never a rainbow. **Claude on a fixed terracotta tint.**
- **Layered vocabulary:** mark = kind (strike-and-caret = edit, pencil underline = comment, **Qy?** = query), slip = why, colour = who.
- Grace notes: **Qy?** for queries; **"stet"** flash when the author rejects a suggested change.

The marks render from **cached derived annotation state**; leader-line geometry recomputes on layout change only, not continuously.

## Component G — Disposition pane (Mac app)

Extend `AnnotationsPane`: human annotations flow in alongside Claude's; **provenance display** (colour + name); **filter-by-author**; the **stet-on-reject** moment. Existing Accept / Reject / Archive / Reply + stale-confirm behaviour is reused; suggested-change accept applies to the **re-found** window and a stale suggestion blocks accept.

## Component H — Transport / setup (Mac app)

A guided **"Share for review…"** flow that walks the author to iCloud Drive → Share → **Collaborate** (read-write), since plain folder-syncing won't produce the share metadata. Sane fallback + messaging when a project isn't an iCloud-shared item.

## Component I — Phone (MaughamPhone)

Read-only reviewer consumption: the Read tab + annotation views show **provenance** (name + colour, Claude's tint) from the shared MaughamCore provenance + role resolution. **No authoring.** Role resolved via the same `ShareIdentityResolver` seam (phone-injected URL read, shared mapping). Phone must also render Claude/human **span** highlights from the shared resolver (cross-surface contract — no reimplementation).

## Component J — Claude / MCP path alignment

The Claude annotation path converges on the same provenance-tagged, span-capable model — so Claude and humans share one annotation surface rather than diverging.

- **Provenance:** the MCP/Claude annotation emit-sites stamp `.claude` provenance (see Component C).
- **Spans for Claude (ships the deferred roadmap "sub-paragraph range anchors" item):** `add_comment` / `add_suggested_change` / `add_query` gain an **optional `quote`** parameter. When present, the server captures the span via the same `SpanAnchorResolver` (deriving `prefix`/`suffix`/`posHint` from the paragraph's display text); when absent, the annotation stays paragraph-level (unchanged behaviour). Claude works in quoted text natively, so a quote is the natural anchor — no offset math on Claude's side.
- **Fail loud:** a new structured `span_not_found` error envelope (alongside the existing `paragraph_not_found` / `prior_text_capture_failed` factories) when the quote is missing or ambiguous in the named paragraph, so Claude retries with more context rather than mis-anchoring silently.
- Exercising `SpanAnchorResolver` from **both** the human UI and the MCP path widens its test coverage and keeps the two surfaces honest.

---

## Op-schema changes (all additive, forward-only)

- `Op.Provenance.author?: { sourceKind, displayName, collaboratorId }` — Component C.
- Annotation anchor `span?: { quote, prefix, suffix, posHint }` — Component E.

Both optional, decoded `nil` on legacy ops, no migration (tripwires 11/15; ADR 0015). Must round-trip through the existing op (de)coders; covered by the shared MaughamCore tests so phone + Mac stay byte-identical.

## Testing

- **Identity:** role mapping (owner/participant/unshared/unknown) over injected resource-key fixtures; caching; the static author predicate.
- **Membrane:** reviewer cannot emit manuscript-text ops or binder structural ops; *can* emit annotation ops; `.unknown` is read-only.
- **Anchoring (the risk area):** the full behaviour matrix — intact/edited-around, lenient incidental edits keep anchor, repeated-span-with-other-occurrence-deleted via context, rewrite→stale, split/merge, smart-quote normalization, display-vs-source capture, grapheme clusters, manual reattach. Property test: empty span ≡ paragraph-level.
- **Provenance round-trip:** human vs Claude vs legacy(nil) through the op coders, Mac + phone parity (cross-surface contract).
- **Perf:** re-find scoped to changed paragraphs; `TypingLatencyProbeTests` re-baseline + live `sample` during active typing → no keystroke-path change.
- **Suggested-change:** scoped-edit diff capture; accept applies to re-found window; stale blocks accept.
- **Claude/MCP alignment (J):** `.claude` provenance stamped; optional `quote` resolves to a span via the shared resolver; `span_not_found` on missing/ambiguous quote; same `SpanAnchorResolver` exercised from both UI and MCP.

## Build order (for the plan)

Spike → C (provenance) + E (anchoring core, MaughamCore) → J (Claude/MCP alignment — small, lands right after C+E and exercises the resolver) → B (membrane) + A (identity) → D (authoring UI) → F (review render) → G (pane) → H (setup) → I (phone). E is the technical long-pole; do it early and test it hard.

## Open decisions to confirm at plan time

- Exact normalization set for span matching (which smart-typography transforms to canonicalize).
- Whether the floating toolbar is `NSView`-hosted vs SwiftUI overlay (editor seam — heed the AREA.md tripwires; **no `NSPopover`**, per tripwire 5).
- The pencil palette's concrete colours + the assignment rule (stable per collaborator id).
- `craftNote` authoring surface for humans (Claude-only for now? — likely defer human craft notes).

## Related tripwires / contracts

Cross-surface (provenance + anchoring in MaughamCore, phone must not reimplement) — registry `docs/superpowers/notes/cross-surface-contracts.md`. Editor seam tripwires 2/3/5/6/7 (`Maugham/Editor/AREA.md`). Typed-enum/schema tripwires 12/15. No-migration 11. Typed mover 14 (binder membrane choke points).
