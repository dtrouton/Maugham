# Quality & Maintainability Audit — 2026-06-09

Author: Claude. Run two days after the 2026-06-07 audit and **one day after the
codebase-hardening merge (`66a4d1b`, M0–M4 + D1)** that acted on it. Method:
four parallel deep-read agents over disjoint scopes — (1) finding-by-finding
verification of the 06-07 audit against HEAD, (2) deep read of the hardening
diff itself for newly-introduced issues, (3) structural maintainability + CI +
test-suite sweep, (4) roadmap-readiness assessment per open bet. Every claim
below was verified at the cited `file:line` at HEAD.

**Headline:** the hardening pass was real. All eight Tier-1 bugs and four of
six Tier-0 findings from the 06-07 audit are verifiably fixed in production
code with red-first tests; the two that aren't are recorded as explicit,
documented deferrals, not omissions. `ci.yml` now gates both schemes on every
push/PR. Structural health is strong (zero `@unchecked Sendable`, exactly one
TODO in production code, accurate cross-surface registry, no runaway file
growth). What remains is a **short, well-bounded punch list**: four follow-ups
introduced or exposed by the hardening pass itself, a handful of pre-existing
items the pass deliberately didn't scope, and prep work for the two roadmap
bets that will stress the architecture (collaboration, compaction).

---

## 1. Status of the 2026-06-07 audit findings

Legend: ✅ fixed (verified in code) · ◐ partial · ⏸ deferred by recorded
decision · 🛑 still open.

### Tier 0

| ID | Finding | Status | Evidence |
|---|---|---|---|
| 0.1 | Wiki-rename raw bytes | ✅ | Routes through `setFullText` (op log), open + closed targets handled; `ProjectStore+Structure.swift:396-458`; `WikiLinkRenameOpLogTests` |
| 0.2 | Skew-blind cross-device LWW | ⏸ | Deferred to the collaboration milestone; plan `2026-06-07-codebase-hardening.md:132-159`; `OpLog/AREA.md:76-85` ("`Op.at` is DISPLAY-ONLY") |
| 0.3 | PendingBuffer not partitioned | ✅ | `.maugham/pending/<docId>.<deviceSlug>.pending.jsonl`, out of the `ops/` glob; `PendingBuffer.swift:91-95` |
| 0.4 | Same-opId dedupe non-deterministic | ◐ | Survivor now deterministic via `(opId, canonicalEncoding)` sort (`OpLogStore.swift:194-212`); `CrossMacMergeTests` rewritten. **But divergent-content collision is still resolved silently, not quarantined/surfaced** — explicitly deferred in the code comment at `:188-193` |
| 0.5 | `resolveDocId` seed-randomized hash | ✅ | `StableHash.fnv1a64Hex`; `Document+Load.swift:312,321`; grep-tripwire + meta-test |
| 0.6 | Non-atomic op-log append | ◐ | Read-side quarantine wired into the normal load path + torn-line test added (`Document+Load.swift:193-214`, `DocumentLoadQuarantineTests`). **Append is unchanged** (`JSONLAppendStore.swift:66-69`) — no length/checksum framing, so a torn line that still decodes as valid JSON with a severed `changes` is still undetected |

### Tier 1 — all eight fixed ✅

1.1 smart-typography selection (`SmartTypography.swift:30-92` + follow-up
`68a9396` fixing the fix's own off-by-one) · 1.2 manifest self-archive
(`ManifestEcho` SHA-256 content hash, `DocumentStore.swift:779-784`) · 1.3
flush-before-move (typed mover) · 1.4 LaTeX injection (`LaTeXSafeFilename`
allowlist type) · 1.5 output path traversal (`PublishConfigValidator.swift:34-40`,
re-validated on republish) · 1.6 add_note flush race (`AddNoteTool.swift:55`) ·
1.7 MCP partial write (`sendAll` drain loop, `MCPServer.swift:200-211`) ·
1.8 trash restore parent/index (`ProjectStore+Trash.swift:38-60`).

### Tier 2 / architecture / perf / CI — the residue

Fixed: RenderFilter bigram margin rule (+ the missing disagreement test);
typed user-content mover with grep meta-tests; manifest equal-second LWW
(subsumed by content hash); `Op.at` semantics documented; CLAUDE.md tripwire-19
wording; DocumentStore↛inbox-worker extraction (`InboxTranscriptionWorker`
peer); all six silent-`try?` source-of-truth writes now propagate or durably
re-persist (incl. `Document.close()` re-flushing the pending buffer on append
failure); all Addendum-2 schema items (unknown enum cases across
OpKind/SynthesisSource/manifest enums/inbox/checkpoint/publish, tolerant
`TypographySettings` decoder, `decodeGuardingSchema` schemaVersion gate,
quarantine on load path, atomic update swap); ADR 0015 written; `ci.yml`
landed (both schemes + strict-concurrency scan job, push + PR).

**Still open (pre-existing, deliberately out of M1–M4 scope):**

| Item | Where | Why it matters |
|---|---|---|
| Backup proceeds when the integrity check *throws* (`try?` → nil → gate bypassed) | `BackupCoordinator.swift:43` | A throwing check is arguably the strongest corruption signal; no test for the throws case. Cheapest genuine integrity fix left |
| Focus-dim enumerates full storage per cursor move | `EditorCoordinator.swift:819-856` + `FocusFinder.swift:26-81` (O(N) scans from index 0) | Most user-felt remaining perf item — every arrow key with focus mode on |
| `restoreComments` O(P²) shingle match per autosave | `RenderFilter.swift:58-133` | The save-path cost at 5000 paragraphs; exact-match tier is a linear scan that should be a hash index |
| `.maughamScriptDidUpdate` per keystroke → full `FountainScript` into `ProjectWindow` `@State` | `EditorCoordinator.swift:407-411`; `ProjectWindow.swift:198-203` | No re-parse (payload is the already-parsed script) but a per-keystroke SwiftUI invalidation fan-out at scale |
| CompileOrchestrator two-phase commit | `CompileOrchestrator.swift:134` | The single production TODO; version-counter desync blocks the next compile |
| Deriver never drops deleted-paragraph keys; consumers must sequence-project | `Deriver.swift:53-81` | Long-term architectural item; the convention trims remain load-bearing |
| Tab-cycle async cursor reapply | `EditorCoordinator` | Shape tripwire 3 warns about; now test-covered (`EditorCoordinatorCycleTests`) but unchanged |
| `canonicalPath` symlink silently drops files from publish snapshot; backup reads live tree uncoordinated (mitigated by Merkle verify) | `PublicationSnapshotStore.swift:140`; `BackupWriter` | Low probability, fail-safe-leaning |
| `WritableResearchPath` membrane type | — | `LaTeXSafeFilename` landed; the research-path analogue didn't |
| Test gaps 8, 11(throws-half), 12 | — | E2E external-edit ingest (deprioritized with the deletion-ingest rejection); integrity-check-throws; cross-device rewind + Mac↔phone inbox-merge integration |

**Deferred by recorded decision** (sound, with paper trail): skew-aware LWW +
same-paragraph conflict surfacing → collaboration milestone; external-`.md`
deletion-ingest → rejected outright ("external .md edits are not honored",
now a CLAUDE.md hard invariant).

---

## 2. New findings — issues in the hardening pass itself

The pass is high-quality (red-before-green tests, honest comments, no
assertion-weakening, no new Tier-0 class regression found). Four follow-ups:

| # | Severity | Finding |
|---|---|---|
| N1 | **Med** | **Unbounded quarantine-file accumulation.** A persistently-torn op-log line is skipped in-memory but never repaired (append-only log), and `IntegrityQuarantine.record` writes a fresh-timestamped file with no content dedup — so *every* load of that doc adds another file under `.maugham/conflicts/quarantine/`. N opens → N files. Dedup on content hash (skip if an identical record exists). `Document+Load.swift:201-213`; `IntegrityQuarantine.swift:14-33` |
| N2 | **Med** | **`python3` is now a hard dependency of the in-place update.** The atomic swap runs via `python3` from the detached bash helper; python3 is not guaranteed on a clean macOS (needs CLT). With `set -e`, a missing python3 aborts the helper *after the app has quit* → failed-update state. Add a `command -v python3` guard + fallback, or compile a tiny helper. `UpdateInstaller.swift:79-86` |
| N3 | Low-Med | **The swap *fallback* re-introduces a brick window.** If `renamex_np` fails, the fallback is `rename(dst→bak); rename(src→dst)` — the install location is absent between the two. Primary path is genuinely atomic; the commit's "never absent" claim only holds there. `UpdateInstaller.swift:104-117` |
| N4 | Med (latent) | **`.unknown` enum cases re-encode lossily.** No custom `encode(to:)` preserves the original raw value, so a decoded `.unknown` re-encodes as literal `"unknown"`. Harmless for the append-only op log; for the **manifest** (rewritten on every structural edit) a future value surviving on an old build would be permanently degraded. The `decodeGuardingSchema` gate is the real mitigation — **but only if every future enum-case addition bumps `currentSchemaVersion`**. That discipline is undocumented at the enum declarations; add a comment at each + a test, or preserve raw values |

Minor notes: TripwireGrepTests' mover-grep only scans `ProjectStore+*.swift`
(a raw move added in `DocumentStore.swift` or a new file is invisible; a
`copyItem`+`removeItem` pair bypasses it) — acceptable for a recurrence-tripper
but narrower than the AREA.md framing. Wiki-rename still only rewrites
`collectDocuments` (collection-piece bodies and research notes with `[[links]]`
are not rewritten — pre-existing, but the pass touched this function and could
have widened it), and its propagated ops carry synthetic `device: "wiki-rename"`
(forensic oddity, correctness holds). `mergeSortedDedup`'s canonical-encoding
tiebreak only pays the JSON cost on same-opId clusters (fine); two divergent
same-opId ops that *both* fail to encode tie unstably (astronomically unlikely).
The merge commit message says "ADR 0014" for the schema work; the file is
correctly 0015 (cosmetic).

---

## 3. Structural maintainability

**File sizes — no runaway growth.** Top files vs the 06-07 audit:
`ProjectWindow.swift` 1154 (+17, the ViewModifier-extraction discipline is
holding), `EditorCoordinator.swift` 857 (flat), `ProjectStore+Structure` 824,
**`DocumentStore.swift` 807 (+156 — the biggest mover**, partly intentional as
the typed-mover choke point; split the registry into `DocumentStore+Registry`
if it crosses ~900), `ProjectStore+CollectionPieces` 806, `+Research` 775,
`ScreenplayMode` 754, `TasksPane` 692 (new).

**Dead code:** `Maugham/Editor/ScreenplayLayoutManager.swift` (107 LOC) is
fully orphaned — never instantiated, never installed; its trigger attribute
`.maughamDisplayUppercase` is never set anywhere; the live path is the shared
`ScreenplayUppercase` in MaughamCore. **Delete it, together with the stale
`Editor/AREA.md:16` claim** that it's an intentional fallback. (Flagged
alive-or-delete on 06-07; no task picked it up.) `GoalIndicatorView` and
`CharacterAutocompleter` are correctly gone; no other orphans found.

**CI (`ci.yml`):** strong — both schemes as separate jobs + a non-failing
strict-concurrency scan job, push+PR on `main`/`claude/**`,
concurrency-cancel, least-privilege permissions, pinned action SHAs, one-retry
wrapper for the simulator-boot flake. Gaps: (a) **comment says Xcode 26.5,
pin says 26.3** in three places — reconcile; (b) **no `timeout-minutes`** on
any job (a hung simulator burns toward the 6 h default on macOS runners);
(c) **no DerivedData/SPM caching** — every run re-fetches WhisperKit.

**Tests:** 299 test files, ~34.3k test LOC vs ~46.5k prod (~0.74 ratio).
Strong where it matters (Publish ≈20 files, Updates fully covered, MCP
per-tool, OpLog adversarial since M0). All `XCTSkip`s are environmental
guards, none silent. Thinnest area: `Maugham/Views/` (10.8k LOC, ~3 dedicated
test files) — the natural SwiftUI gap, but the new 692-line `TasksPane` is
the one worth direct view-model tests.

**Concurrency debt: effectively zero.** 176 `@MainActor`, 0
`@unchecked Sendable`, 0 `@preconcurrency`. Strict concurrency is surfaced in
CI but not enforced in `project.yml`; once the scan job is quiet, promote
`SWIFT_STRICT_CONCURRENCY=complete` into base settings.

**Docs accuracy:** AREA.md spot-checks pass (MCP 43-tool count, mover names,
`lastDiskEcho`/`_pendingSweep`, `applyFocusDim` three-caller claim) with the
one stale ScreenplayLayoutManager bullet above. Cross-surface contract
registry verified accurate; no new uncontracted Mac/phone duplication.
Exactly **one** TODO/FIXME/HACK in production code (the CompileOrchestrator
one, §1). `project.yml`/`gen.sh` hygiene clean (WhisperKit pinned to an
immutable revision).

---

## 4. Roadmap readiness

| Bet | Verdict | The crux |
|---|---|---|
| **Collaborator layer / author lock** (Group 2) | **Needs prep** | Per-device JSONL + the annotation membrane carry it most of the way — another human is just another `deviceSlug` proposing via existing OpKinds. Gaps: (a) **no author/human provenance field** — `Op` has `device`/`session` (per-install), `Annotation` only `createdBySession`; a named reviewer is indistinguishable from Claude. (b) **No lock state exists anywhere**; best home is per-device claim sidecars (the ADR-0012 pattern), *not* the manifest (wrong grain, churns `modified`) and not naïvely the op log (lock-now is LWW-derived — the unsolved problem). (c) Skew-aware resolution slots cleanly into exactly two centralized places (`Deriver.opOrder` `Deriver.swift:26-35`, `mergeSortedDedup` `OpLogStore.swift:194-212`) — good news; but **no same-paragraph conflict surfacing exists at all**. Prep order: ① ship the additive `author` provenance field standalone (mirror the `appVersion` precedent in `Op.Provenance`); ② design the skew-proof clock *inside* the lock spec (force-takeover is its first real consumer); ③ surface conflicts before resolving them — the `prior`-snapshot divergence detector (same paragraph, same `prior`, different `next` from different devices) reuses fields that already exist (`Op.swift:18`) |
| **Op-log compaction** (Group 4) | **Will fight the architecture** *(resolved same day: ADR 0016 withdraws compaction in favor of keyframed sequence + sealed compressed segments + derive cache)* | Directly contradicts the append-only invariant; there is no base-state concept (`Checkpoint.docPointers` are *pointers into* full history, not materialized state). Breaks: pre-horizon `RewindCursor`, checkpoint pointers (the v0.8.0 dangling-pointer integrity check would false-positive on healthy compacted logs), Merkle/content signatures (spurious full re-backup per compaction), and the per-device partition (a compacted base is a new shared writer). Demands an ADR before any code; sequence after the perf pass proves log size is actually the bottleneck; prototype as a checksummed logical-horizon `compactedBase` under `.maugham/` with logs physically intact first |
| **Performance pass, 100k words** (Group 4) | **Needs prep, well-bounded** | Post-M4.7 the remaining hotspots are exactly the four in §1's open table (focus-dim + FocusFinder are the typing-path pair to fix together; index `restoreComments`' exact-match tier; debounce/lighten the script notification). Project Statistics is **not** a hotspot — word counts are cached per-doc, aggregation is O(docs). Build a committed 100k-word fixture harness first so these are measured, and so the collaboration milestone's per-arrival full re-derive (`Document+ExternalChange.swift:78`) gets regression-watched — bet #1 makes that path hot |
| **Screenplay intelligence 4a** | **Ready** | Harvesting is solved (`FountainScript.characterNames` exists for exactly this; sluglines via `lines.filter`; `lastParsedScript` fresh each keystroke). Tab interception seam exists (`doCommandBy`). Ghost-text rendering is greenfield — go layoutManager temporary attributes, never a popover (tripwire 5); reuse the single parse, don't add one |
| **Manifest schema versioning** (Group 4) | **Needs prep** | ADR 0015 closed forward-tolerance + the too-new gate; there is still **no v1→v2 migrate-on-load dispatch** and nothing has ever bumped `currentSchemaVersion` (`ProjectManifest.swift:12`). Add the `migrate(from:)` dispatch before the first bump forces it; fold the ADR-0007 id-prefix cleanup in as the first payload; spec the manifest-shadow interaction (a migration must update manifest + checksummed shadow atomically or the shadow becomes a corruption vector). Ties directly to N4 |
| **Clean export / Word / FDX** (Group 3) | **Ready** | `ProjectAST` is target-agnostic and the emitters are free functions over it; a new format is a new file. Only the orchestrator dispatch is a closed `switch` (`CompileOrchestrator.swift:87-110`) — mechanical, not architectural. Ship Clean Export first: it's `MarkdownDisplayFilter.stripAnchors` + file copy, no AST needed |

Cross-cutting: the **skew-proof logical clock is the single most-reused
missing primitive** (collaboration LWW *and* lock claims/takeover) — design it
once, in the collaboration spec. The op log + partitioning is the load-bearing
asset for both big bets: one builds on it, the other contradicts it.

---

## 5. Recommended punch list (ranked)

Small, bounded items first; everything here is pre-milestone-sized except the last two.

1. **N1 quarantine dedup** + **BackupCoordinator integrity-throws gate** (`try?` → explicit do/catch that *blocks* the backup, + the missing test) — the two genuine integrity items left. (S each)
2. **N2 python3 guard / fallback in the updater** — a failed update on a CLT-less Mac is a support incident. (S)
3. **Delete `ScreenplayLayoutManager.swift` + fix `Editor/AREA.md:16`.** (S)
4. **ci.yml: reconcile 26.5-comment vs 26.3-pin; add `timeout-minutes`; add DerivedData/SPM cache.** (S)
5. **N4: document the "adding an enum case ⇒ bump `currentSchemaVersion`" contract at each tolerant enum** (or preserve raw values on `.unknown` re-encode) + a test. Do before the next schema change, not after. (S)
6. **Focus-dim + FocusFinder incremental rework** — the one remaining user-felt perf item; self-contained in Editor. (M)
7. **`author` provenance field on `Op.Provenance`** — additive, independently shippable, unblocks the collaboration milestone's UI distinction. (S-M)
8. **100k-word perf fixture harness**, then `restoreComments` exact-match indexing + script-notification debounce as measured. (M)
9. **Surface (don't yet resolve) same-paragraph divergence** via `prior`-snapshot detection — the collaboration milestone's first deliverable, and it retires the 0.4 "silent" residue at the same time. (M, spec first)
10. **Op-log append framing** (length/checksum per line) closing 0.6's valid-JSON-torn-line case — largely subsumed by ADR 0016's sealed-segment checksums (written same day as this audit); only the live-tail framing remains. (M)

What this audit did *not* find: any new Tier-0-class silent-divergence path,
concurrency debt, membrane violations, or doc drift beyond the one stale
AREA.md bullet. The 06-07 audit's "bugs cluster where feedback is absent"
diagnosis was answered with exactly the right medicine — the adversarial M0
harness + CI gate — and the two-day-later evidence is that the feedback loop
is now installed and the residue is enumerable. The codebase is in the best
shape it has been: the right next move is the small punch list above, then
back to roadmap work with the collaboration-prep items (7, 9) leading.
