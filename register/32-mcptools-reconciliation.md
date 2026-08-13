# MCP/Tools characterisation — reconciliation report (2026-08-13)

The register's MCP/Tools module (PLAN phase 4's named module). Broad-but-shallow: the
long tail of per-tool FAILURE behaviour across all tool families. Pinned by
`MaughamTests/Claims/MCPTools*Characterization.swift` (four classes, 80 tests, permanent
residents of the Mac suite); reconciled in `register/reconciliation/MCPTools.{claims,filings}.json`.

## Numbers

**41 claims, 27 reached, 15 complies / 12 violates, 14 no-ruling (66% coverage).**

The 12 violates are the app layer's FIRST — every prior app module reconciled post-fix at
N:0. This module was characterised FRESH, pre-fix, exactly as the handoff directs: defects
file VIOLATES and go to a Denver sitting; fix loops come after rulings. App layer now stands
at 186:12 (was 171:0), 484 claims total (was 443).

Coverage is high (66%, like Publications 91% / Inbox 75%) because this module was selected
for RULING-21/7/54 density — the failure tail is where failure-honesty rulings reach. A
writer-distant module would score far lower.

## The lens (RULING-21)

Every tool RESPONSE is a writer-facing surface: "What Maugham serves to Claude IS a
writer-facing surface for the purposes of RULING-7… An ANSWER about the writer's content
must be true; only a REPAIR may be silent." So the axis that decides comply/violate is
**refuse-vs-empty**, and a secondary render-quality axis runs underneath it.

## The one structural finding — RULING-54 HOLDS, its render does not

The manuscript/statement/translation/publications-catalog readers all correctly REFUSE an
unreadable op-log/store file (M9-OL-004/009's strict reads reached the tool layer) — none
derives a shortened truth. **On the refuse-vs-empty axis they COMPLY** (M10-MT-002, -017,
-026, -033, -035). But the refusal reaches Claude through
`MCPToolsCallHandler.toolErrorPayload(for:)`'s DEFAULT arm, which interpolates `"\(error)"`
— the Swift enum's reflected form — with no hint and no fields. The authored
`OpLogStore.ReadError.errorDescription` ("Your words are intact inside it… Maugham won't
open a shortened version over it") is DISCARDED. The filename and OS cause survive, so
RULING-7's "a refusal names its real cause" is technically met — which is why these file
COMPLIES, not VIOLATES. `compile` is the one caller that catches the error and renders the
full sentence, proving the good render exists.

This is the module's headline GAP-CANDIDATE (M10-MT-001): does a writer-facing refusal owe
Claude the authored recovery prose + a hint + the right error category, or is the raw cause
enough? Proposed sub-ruling below.

## The 12 VIOLATES (to a sitting)

**Unreadable presented as empty (RULING-7 "unreadable is never presented as empty"), 5 —
the same defect class across five surfaces that never got RULING-54's propagation because
they don't read through JSONLAppendStore:**
- M10-MT-010 `read_document` research arm — `(try? String(contentsOf:)) ?? ""` reads a
  missing/unreadable research file as empty.
- M10-MT-028 `list_canvas` — an unreadable sidecar reads as an empty canvas; `CanvasStore`
  computes `SidecarState.refused` and `CanvasClaudeWrite.readScene` drops it.
- M10-MT-029 `add_canvas_scraps` — WORSE: a write over an unreadable sidecar loads the empty
  fallback and STAMPS OVER the writer's arrangement (`SidecarState.acceptsARepairWrite`
  forbids exactly this and is never consulted).
- M10-MT-030 `list_inbox` / `read_inbox_entry` — the store records the unreadable manifest
  (M8-IN-012) but the tool drops the record: 'no captures' / 'not found' for captures that
  exist unreadably.
- M10-MT-031 palette — an unreadable card is presented as an unknown id, pointing the caller
  at a listing that has also lost it.
- M10-MT-037 `list_publish_files` — an unreadable publish DIRECTORY reads as an empty tree
  (the single-file readers on the same family distinguish absent/unreadable and comply).

**One question, N answers (RULING-8), 3:**
- M10-MT-005 the scanning family splits three ways on one unreadable doc (search_text skips
  silently; find_references/list_all_links/list_scenes refuse whole; get_outline/get_metadata
  unaffected).
- M10-MT-020 unknown-id refusals in three qualities (structured task_not_found / bare
  invalid_argument / internal_error enum dump that omits the id).
- M10-MT-039 compile's two refusal channels (thrown isError vs status:"failed") — a client
  keying on isError sees a post-resolution refusal as a success.

**Partial-failure and robustness, 2:**
- M10-MT-024 `add_note` (RULING-52) — a mid-create failure leaves an empty orphan .md, holds
  the note in the in-memory manifest only, and the refusal names none of it.
- M10-MT-038 `set_publish_config` (RULING-7 "says so rather than appearing broken") — a
  scalar `patch` value raises an uncatchable NSInvalidArgumentException that ABORTS the whole
  MCP server. Sharpest defect: one bad argument takes down every tool. (The characterisation
  test is documentation-only and does NOT trigger the abort in-suite.)

**Derived drop unreported (RULING-4), 1:**
- M10-MT-009 `get_session_stats` — an unreadable/corrupt sessions.json drops to an all-zero
  aggregate indistinguishable from genuine no-activity.

## GAP-CANDIDATES for the sitting (NO_RULING, need a ruling)

Present each with the live example + mechanics BEFORE the options, recommended option first,
capture Denver's choice verbatim into `basis` (the three-for-three finding).

1. **M10-MT-041 — highest priority, a security dimension.** `write_publish_file` refuses `..`
   but `PublishPath.validateAndResolve` standardizes WITHOUT resolving symlinks, so a symlink
   already inside `.maugham/publish/` lets a write place bytes ANYWHERE on disk and report
   status:written. A write tool escaping the planning-plane sandbox — CLAUDE.md tripwire 4 /
   ADR 0004 / constitution must-not #1 — with NO behavioural ruling behind the membrane.
   Proposed: a write tool's path validation resolves symlinks; a write never lands outside
   the plane it declares. (Not reachable through the publish tools alone — they can't create
   the symlink — but reachable through one a sync client / unpacked archive / the writer left.)
2. **M10-MT-001 — the authored-prose-to-Claude question** (spans 002/017/026/034/035/040).
   Should a writer-facing refusal carry the LocalizedError prose + a hint + the right error
   category, or is the raw cause enough? `compile` shows the good render is one `catch` away.
3. **M10-MT-004 / -018 / -036 — the corrupt-but-readable cluster.** A torn op line, an
   undecodable op log, and corrupt catalog lines all read short/empty silently. RULING-54 (and
   M9-OL-009's fix) covers only the unreadable FILE; a corrupt line in a READABLE file is
   outside its wording. Is silent-drop acceptable, or must it surface like unreadable does?
4. **M10-MT-003 — words-in-the-.md-as-empty.** A manifest doc with no op log reads as empty
   while its .md holds words. The ADR-0018 un-bootstrapped state, or the writer's words served
   to Claude as empty (RULING-21)? Denver's call (the corereads probe deliberately did not
   decide it).
5. **M10-MT-008 — the quarantine archive is invisible to every tool.** A quarantined-and-
   continued doc answers from its surviving log; the archive under
   `.maugham/conflicts/quarantine/` is invisible. Honest under RULING-21 when the answer lives
   partly in the archive?
6. **M10-MT-022 — must write tools validate their id arguments?** `link_research` reports
   linked:true and persists a dangling link to a nonexistent research item. 'linked:true' is
   not strictly false (a link record was written), so RULING-7 does not cleanly reach. Sharper
   than "sloppy validation": `resolveResearchLinks` skips orphans on read, so the bad link
   never surfaces in the Inspector or a subsequent read — Claude is told it happened and has no
   route to discover it did not. That arrangement (told done, silently not done, undiscoverable)
   is the honest-report angle worth a ruling.

### Two smaller sitting items the probe reports surfaced

- **`list_tasks(scope:"document")` on an unknown doc returns `{"tasks":[]}` — and the tool
  ARGUES for it** ("no document_not_found envelope was specified in §10; aligning with that
  silence"). This is the one place the loud-failure convention was consciously DECLINED, so it
  deserves a ruling either way rather than being lumped with the unknown-id drift (M10-MT-020).
- **M10-MT-021 filter-widening is stronger than a NO_RULING quirk**: `list_annotations` validates
  `scope` LOUDLY and rewrites an unrecognised `statuses`/`kinds` token to the default set
  SILENTLY, four lines apart in the same handler — silent wrong-answering (a Claude guessing
  "suggestion" for "suggested_change" gets the open set as if it asked). Filed NO_RULING (no
  clause cleanly reaches a filter Claude itself sent) but flagged here as a gap-candidate.

### Duplicate site for the symlink gap (M10-MT-041)

`PublishPath.validateAndResolve`'s `standardizedFileURL` (which normalises `..` but not
symlinks) is MIRRORED at `PublicationSnapshotStore.extract`, which the guard's own comment
names as the shape it copies — so the containment gap exists at BOTH the write-tool path and
the snapshot-extraction path. A ruling/fix should name both.

## Composition claims worth keeping (COMPLIES, the protections that hold)

- M10-MT-007 — a read-only recovery doc is invisible to the MCP-resolving registry, so MCP
  gets the strict refusal and never a partial view (RULING-21). Census-held.
- M10-MT-012 / -013 — unknown-project and malformed-params answers are byte-identical across
  every tool via shared helpers (RULING-8's good half).
- M10-MT-016 — the annotation creation tools are the exemplar: named codes, hints, typed
  fields.
- M10-MT-025 / -027 / -032 — move_research_item, add_canvas_scraps and write_translation all
  validate the whole batch before any write (RULING-52's validate-first route).

## Method notes

- Worktree pinned at 5366b498; four probe agents, one per family, probe-before-assert; the
  four suites promoted from `MaughamTests/Experiment/` to `MaughamTests/Claims/` (classes
  renamed `*ProbeTests` → `MCPTools*Characterization`, refs updated, 0 unmatched).
- Two corrections carried into the register: the quarantine dir is
  `.maugham/conflicts/quarantine/` (not `…/quarantined-ops/` as the handoff had it); planning
  suite has 22 tests not the 17 first reported.
- Changes are confined to `register/` + `MaughamTests/`. No production code touched — defects
  are filed, not fixed.
