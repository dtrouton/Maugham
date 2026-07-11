# Maintainability Review — Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute the review designed in `docs/superpowers/specs/2026-07-11-maintainability-review-design.md`, producing `docs/superpowers/notes/2026-07-11-maintainability-review.md`.

**Architecture:** Four phases: mechanical git-history pre-pass → 9 parallel read-only map+find agents (6 dimensions, 3 tracers) → synthesis over territory maps in the coordinating session → targeted hypothesis probes → verified, severity-ranked findings doc.

**Tech Stack:** bash/git for Phase 0; Agent-tool subagents (read-only) for Phases 1 and 3; no code changes anywhere.

## Global Constraints

- **Read-only review.** No fix, refactor, or doc edit is applied. The only files created are the Phase 0 outputs (scratchpad), this plan's checkboxes, and the findings doc.
- Every High/Critical finding is re-verified against source by the coordinator before entering the findings doc.
- Every agent must return the two-part output (FINDINGS + TERRITORY MAP with a non-empty "Surprises & tensions" section). A thin map ⇒ re-dispatch that agent once with the map requirement emphasized.
- Models: `opus` for architecture, security, bug-hunt, and all tracers; `sonnet` for tests, docs, memory dimensions.
- Refuted probe hypotheses are recorded in the findings doc (one line each).
- Scratchpad dir for intermediates: the session scratchpad (not `/tmp`).

## Shared agent output contract (verbatim, appended to every Phase 1 brief)

```
You are a READ-ONLY reviewer. Do not edit, create, or delete any file. Your final message is data for a coordinating session, not prose for a human.

Return EXACTLY this structure:

## FINDINGS
One bullet per problem, most severe first:
- [Critical|High|Medium|Low] <one-line defect> — <file:line> — fix-shape: <one line describing the hardening task> — effort: S|M|L
If none in a severity band, omit the band. An empty FINDINGS section is acceptable; an empty map is not.

## TERRITORY MAP
### Seams & boundaries — the real module boundaries you observed (not the documented ones): what talks to what, through which types/functions.
### Data flows — where data enters, transforms, persists, exits, for the code you covered.
### Invariants assumed — conditions the code relies on but does not check or enforce; say WHERE each is relied on and WHERE (if anywhere) it is guaranteed.
### Duplication observed — logic/knowledge that exists in 2+ places, even if currently in sync.
### Surprises & tensions — MANDATORY, non-empty. Things that looked FINE but were odd, assumption-laden, or correct-only-because-something-else-happens-to-hold. Reporting a non-problem oddity here is success, not noise. If you truly found nothing, explain what you checked and why nothing qualified.

Cite file:line for every concrete claim. Read files directly; do not trust doc claims about the code.
```

---

### Task 1: Phase 0 mechanical pre-pass

**Files:**
- Create: `<scratchpad>/phase0.sh`
- Output: `<scratchpad>/hotspots.txt`, `<scratchpad>/coupling.txt`, `<scratchpad>/trends.md`

**Interfaces:**
- Produces: `hotspots.txt` (rank, commits, LOC, path), `coupling.txt` (count, fileA, fileB — cross-area pairs only), `trends.md` (metric table for findings doc §1). Tasks 2, 4, and 7 consume these.

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
# Phase 0 pre-pass — run from repo root; SCRATCH env var must be set
set -euo pipefail
SINCE="2026-05-19"

# --- Hotspots: commit-count x LOC per swift file ---
git log --since="$SINCE" --name-only --pretty=format: -- '*.swift' \
  | grep -v '^$' | sort | uniq -c | sort -rn > "$SCRATCH/churn_raw.txt"
: > "$SCRATCH/hotspots.txt"
while read -r count path; do
  [ -f "$path" ] || continue
  loc=$(wc -l < "$path" | tr -d ' ')
  echo "$((count * loc))	$count	$loc	$path"
done < "$SCRATCH/churn_raw.txt" | sort -rn | head -40 > "$SCRATCH/hotspots.txt"

# --- Temporal coupling: swift file pairs co-changing in the same commit ---
git log --since="$SINCE" --pretty=format:'@@%h' --name-only -- '*.swift' \
  | awk '
    /^@@/ { n=0; next }
    /\.swift$/ { f[n++]=$0 }
    /^$/ { for(i=0;i<n;i++) for(j=i+1;j<n;j++) { pair = (f[i]<f[j]) ? f[i]"|"f[j] : f[j]"|"f[i]; c[pair]++ }; n=0 }
    END { for(p in c) if (c[p]>=8) print c[p] "\t" p }
  ' | sort -rn > "$SCRATCH/coupling_all.txt"
# Cross-area pairs only (different top-two path components)
awk -F'\t' '{ split($2, ff, "|");
  split(ff[1], a, "/"); split(ff[2], b, "/");
  if (a[1]"/"a[2] != b[1]"/"b[2]) print }' "$SCRATCH/coupling_all.txt" > "$SCRATCH/coupling.txt"

# --- Trend metrics ---
{
  echo "| Metric | Value (2026-07-11) |"
  echo "|---|---|"
  echo "| Swift files | $(find Maugham MaughamPhone Packages -name '*.swift' | wc -l | tr -d ' ') |"
  echo "| Swift LOC | $(find Maugham MaughamPhone Packages -name '*.swift' -exec cat {} + | wc -l | tr -d ' ') |"
  echo "| Test files | $(find Maugham MaughamPhone Packages -name '*Tests*.swift' -o -name '*Test.swift' | grep -cv xcodeproj) |"
  echo "| Files >800 LOC | $(find Maugham MaughamPhone Packages -name '*.swift' -exec wc -l {} + | awk '$1>800 && $2!="total"' | wc -l | tr -d ' ') |"
  echo "| ADRs | $(ls docs/adr/*.md | grep -cv README) |"
  echo "| CLAUDE.md tripwires | $(grep -c '^| [0-9]' CLAUDE.md) |"
  echo "| MCP tools (MCPToolCatalog.all) | $(grep -c 'Tool(' Maugham/MCP/MCPToolCatalog.swift 2>/dev/null || echo VERIFY-BY-HAND) |"
  echo "| Memory files | $(ls ~/.claude/projects/-Users-denver-src-Maugham/memory/ | wc -l | tr -d ' ') |"
  echo "| Commits since 2026-05-19 | $(git log --oneline --since="$SINCE" | wc -l | tr -d ' ') |"
} > "$SCRATCH/trends.md"
echo "phase0 done"
```

- [ ] **Step 2: Run it**

Run: `SCRATCH=<scratchpad> bash <scratchpad>/phase0.sh` — expected: `phase0 done`, three output files non-empty. If the MCP tool count line printed `VERIFY-BY-HAND` or a suspicious number, open `Maugham/MCP/MCPToolCatalog.swift` and count the catalog entries directly.

- [ ] **Step 3: Sanity-check outputs** — top hotspot should plausibly be a known big file (e.g. `EditorCoordinator.swift`); coupling.txt pairs should be real files. If a script bug is found: source wins, fix script, re-run (spec's error-handling rule).

### Task 2: Dispatch Phase 1 — 9 agents in parallel

**Files:** none created (agent results held by coordinator; optionally mirrored to `<scratchpad>/maps/<agent>.md`).

**Interfaces:**
- Consumes: `hotspots.txt`, `coupling.txt` (paste top ~20 lines of each into every brief).
- Produces: 9 two-part agent reports (contract above). Tasks 3–4 consume them.

- [ ] **Step 1: Dispatch all 9 in ONE message** (parallel Agent calls, `run_in_background: true`, read-only general-purpose agents). Each brief = role paragraph below + hotspot/coupling excerpt + the shared output contract verbatim.

**A1 — Architecture & code health (opus):**
> Audit architecture and code health of the whole Maugham repo (Mac app `Maugham/`, iOS `MaughamPhone/`, shared `Packages/MaughamCore/`). Rubric: ISO 25010 maintainability sub-characteristics — modularity, reusability, analysability, modifiability, testability. Specifically: (1) do the NEWEST areas — sensory palette (`Maugham/Research/`+palette files, find them), tasks (`Document+Tasks.swift`, `TasksPane.swift`), craft intent, unified undo (`OpUndoRegistrar`, compensating ops) — follow the established seam patterns documented in `CLAUDE.md` per-area table and `*/AREA.md` files, or are they drifting? (2) dead code (e.g. `CharacterAutocompleter` is known-dead — find others). (3) ADR compliance: skim `docs/adr/0016`–`0023` and verify the code still matches each decision. (4) the hotspot files listed below get priority reading. (5) context-window economics: flag any file whose size + coupling makes it unsafe to edit without loading more than ~3k lines of context; `EditorCoordinator.swift` is 2,293 lines — assess whether its internal structure mitigates or aggravates this.

**A2 — Test suite (sonnet):**
> Audit the test suite of the Maugham repo. Lens: Feathers — which SEAMS are untested, not just raw coverage. (1) Map every seam named in `CLAUDE.md`'s tripwire table to its enforcing test (many claim one — verify the test exists and actually pins the behavior, e.g. `TripwireGrepTests`, `BootstrapWiringTests`, `EditorIntegrationHarnessTests`, `OpLogStoreSegmentTests`); report tripwires that are PROSE-ONLY. (2) Coverage of the newest seams: unified-undo compensating ops (ADR 0023), `MarkdownBlockParser`, palette store APIs (`updatePaletteCard`, image-add), scoped research (`ResearchScope`), `claudeAcceptRevert` schema v2/v3. (3) Behavior-coupled vs implementation-coupled: sample 10 test files incl. the largest; flag tests that would break on refactor without behavior change. (4) Cross-surface round-trip tests (Mac↔phone) — do they exercise real on-disk data shapes? (5) Anything skipped/disabled/flaky-marked.

**A3 — Docs & context files (sonnet):**
> Audit documentation accuracy for the Maugham repo. Method — the fresh-session onboarding test: a new Claude session reads only `CLAUDE.md` + the relevant `AREA.md` before editing. (1) For each of these historical failures, would those files have prevented a repeat: recordWordCount silently unwired during a refactor; phone reimplementing a stricter doc-id parser than Mac; raw `.md` read as truth (ADR 0018); unscoped NotificationCenter broadcast (ADR 0021)? Say yes/no per incident with the exact doc line that does/doesn't cover it. (2) Diff `CLAUDE.md` claims against reality: per-area table (sensory palette / craft intent shipped in v0.19.0 — is it covered?), "47 tools" count vs `MCPToolCatalog.all`, tripwire enforcement claims. (3) Every `AREA.md` (find all) — stale claims vs current code. (4) `docs/guide/` help topics vs shipped features; `README.md`/`docs/roadmap.md` currency. (5) For EVERY factual doc claim you checked, answer: could it be generated or asserted by a test instead of hand-maintained (the generated `EMISSION.md` pattern)? List the candidates.

**A4 — Memory→tripwire promotion (sonnet):**
> Read all 21 tripwires in `CLAUDE.md` and all 58 files in `~/.claude/projects/-Users-denver-src-Maugham/memory/`. Classify EACH on the enforcement ladder: (1) prose warning → (2) checklist → (3) grep/CI test → (4) type-system constraint → (5) impossible-by-construction. For each: current rung (verify claimed enforcement actually exists in the test code — don't trust the table), highest achievable rung, and recommended action: keep-as-prose / promote-to-test / promote-to-structure / retire. Retirement is Chesterton-fenced: only recommend retire if you traced the originating incident and show why it can no longer recur. Also flag: memories contradicting current code, duplicate/overlapping memories, and lessons buried in milestone memories that deserve their own tripwire. Output the classification as a markdown table in your FINDINGS section, plus regular findings for the biggest promotion gaps.

**A5 — Security (opus):**
> Security review of Maugham (local Mac app + iOS companion), four surfaces: (1) MCP Unix-socket bridge (`Maugham/MCP/`): who can connect (socket path perms, `BuildVariant` socket paths), tool-argument path traversal (research file writes, image reads, `get_help` topic ids), response-size handling, injection via manuscript content into tool responses. (2) Release/CI pipeline (`.github/workflows/`, `scripts/cut-release.sh`): action pinning (a fabricated-action-SHA was caught before — re-audit all SHAs), secret handling, updater trust chain (signature verification before install-in-place?), notarization flow. (3) Store file handling (`Maugham/Stores/`): symlink following, paths escaping project root, `.maugham/` sidecar trust. (4) iCloud JSONL flow: what does a hostile/corrupt `inbox.<slug>.jsonl` or op-log segment do to `JSONLAppendStore`/`OpLogStore`/`Materializer` — crash, hang, silent data loss, or contained failure? Also: Hyrum's-law check on `docs/superpowers/notes/cross-surface-contracts.md` — find behaviors BOTH Mac and phone depend on that are NOT in the registry. This is defensive review of the maintainers' own code.

**A6 — Bug hunt (opus):**
> Adversarial bug hunt over the least-soaked code in Maugham, priority order: (1) unified undo (ADR 0023 — `OpUndoRegistrar`, compensating ops, inverse factories, rewind-undo task-window closer, live-um redo; hunt interaction bugs between undo and: autosave debounce, iCloud merge, annotation accept/revert, inbox promote, checkpoint restore). (2) Sensory palette editor (`PaletteCardEditor`, `updatePaletteCard`, image-add APIs, swatch rendering, body round-trip — the round-trip had a heading/kind-like-prose bug fixed in 430df80; hunt its siblings). (3) `MarkdownBlockParser` edges (nested fences, tables at buffer boundaries, CRLF, the pinned deviation). (4) The hotspot files below. For each suspected bug: trace the exact failure path in source; report inputs/state → wrong outcome. Do not report style issues — real defects only.

**T-A — Tracer: paragraph edit lifecycle (opus):**
> Trace ONE paragraph edit end-to-end through Maugham, reading every function on the path: keystroke in `EditorCoordinator`/`EditorHost` binding → `Document` op append (`Maugham/OpLog/`) → materialize/render → 750ms autosave via `DocumentStore` → clean-.md render (ADR 0019, anchors stripped) → iCloud per-device JSONL sync (ADR 0012 merge) → phone read path (`MaughamPhone/`) → annotation attach on that paragraph → unified undo of the edit (ADR 0023) and what that does to the annotation and the synced device. At EVERY seam crossing record in your map: what is passed, what is assumed, what happens if the assumption fails. You are hunting mismatches BETWEEN stages that no per-area review can see.

**T-B — Tracer: MCP call trust path (opus):**
> Trace ONE MCP tool call end-to-end: Claude Desktop connects to the Unix socket (`Maugham/MCP/`, ADR 0003) → framing/parse → `MCPToolCatalog` dispatch → argument decode (shared MCP decode from v0.7.0) → store/Document access (which thread? main-actor hops?) → disk read/write → response encode → 1MB cap (ADR 0004, tripwire 10). Pick `add_note` (mutating, annotation layer) and `read_document` (must derive from op log per ADR 0018, tripwire 20) as the two concrete calls; also check one research-write tool for path handling. At every stage record assumptions and failure behavior (malformed args, unknown ids — tools must fail loudly, doc claims). Hunt seam mismatches: id namespace disagreements, stale-derived reads, main-thread stalls on large docs.

**T-C — Tracer: release lifecycle (opus):**
> Trace ONE release end-to-end from `git tag` push: `.github/workflows/` triggers → version derivation from tag → `./gen.sh`/xcodebuild → signing (Developer ID) → notarization (submit-then-poll) → artifact upload → the in-app updater (Tier 1.5, install-in-place) discovering, downloading, verifying, and swapping the app → dev/stable `BuildVariant` coexistence. Read the actual workflow YAML and `scripts/cut-release.sh` and the updater source. At every stage record: what is trusted, what is verified, what fails silently. Include the phone TestFlight pipeline at skim depth.

- [ ] **Step 2: While agents run** — coordinator reads `trends.md` + `coupling.txt` fully; pre-select the ~5 strongest cross-area coupling pairs for Task 4.

### Task 3: Collect + quality-gate agent output

- [ ] **Step 1:** As each agent completes, check contract compliance: two sections present, "Surprises & tensions" non-empty and substantive, findings carry file:line.
- [ ] **Step 2:** Any agent with a thin/missing map ⇒ re-dispatch ONCE via SendMessage (or fresh agent) with: "Your TERRITORY MAP is the primary deliverable; findings are secondary. Expand Seams/Invariants/Surprises with file:line specifics." Accept the second result either way.
- [ ] **Step 3:** Mirror all 9 reports to `<scratchpad>/maps/` for durability across context compaction.

### Task 4: Synthesis over maps (coordinator, main context — NOT an agent)

**Interfaces:** Consumes all 9 maps + `coupling.txt`. Produces `<scratchpad>/suspicions.md`: numbered hypotheses, each with the cross-cutting question + exact files to check.

- [ ] **Step 1:** Load all maps. For each historical emergent-bug class, hunt across map boundaries — cross-referencing FACTS (invariants-assumed vs data-flows vs duplication), not findings:
  - (a) two-correct-features-interacting: does any invariant assumed in one map get violated by a flow in another? (T5×T6 pattern)
  - (b) cross-surface contract drift: any datum both Mac and phone maps mention with different shapes/parsers? (doc-id pattern)
  - (c) silently-unwired-after-refactor: anything a map says exists that no other map's flow ever reaches? (recordWordCount pattern)
  - (d) output-read-back-as-input: any flow where a derived artifact feeds a stage that treats it as source? (ADR 0018 pattern)
- [ ] **Step 2:** Reconcile the pre-selected temporal-coupling pairs against declared seams in the maps: co-change ≥8 with no declared seam ⇒ suspicion.
- [ ] **Step 3:** Write `suspicions.md`. Each entry: hypothesis, why (which two facts collided), files, and what would confirm/refute.

### Task 5: Hypothesis probes

- [ ] **Step 1:** One read-only probe agent per suspicion (opus, parallel, one message). Brief template: "Investigate this specific hypothesis: <hypothesis>. Context: <the two colliding facts, with file:line>. Read <files> and any code they call. Return: CONFIRMED (failure scenario: inputs/state → wrong outcome, file:line) or REFUTED (the exact mechanism that prevents it, file:line). No other findings."
- [ ] **Step 2:** Collect verdicts. REFUTED entries → one-liners for findings doc §6.

### Task 6: Verify High/Critical against source

- [ ] **Step 1:** For EVERY High/Critical from any phase, coordinator opens the cited source and confirms the defect is real and the fix-shape sensible. Project memory: review claims have been wrong before — verify against source, not against the agent's confidence.
- [ ] **Step 2:** Downgrade/drop anything that doesn't hold; note dropped claims (they inform agent-brief quality next audit).

### Task 7: Findings doc + commit

**Files:**
- Create: `docs/superpowers/notes/2026-07-11-maintainability-review.md`

- [ ] **Step 1:** Write the doc with this exact section skeleton:

```markdown
# Maintainability Review — 2026-07-11
## 1. Trend metrics (longitudinal baseline)   ← trends.md table + hotspot top-10 + prior-audit comparison where known
## 2. Per-dimension findings                   ← per agent: severity · defect · file:line · fix-shape · effort
## 3. Emergent / cross-cutting findings        ← Task 4–5 CONFIRMED items, sectioned separately per spec
## 4. Tripwire & memory promotion table        ← A4's table: item · current rung · achievable rung · action
## 5. Proposed hardening-milestone shortlist   ← prioritized: Criticals, then High×S-effort, then themes
## 6. Refuted suspicions                       ← one line each, so the next audit doesn't re-chase
## 7. Review-process notes                     ← thin maps, dropped claims, brief improvements for next time
```

- [ ] **Step 2:** Commit:

```bash
git add docs/superpowers/notes/2026-07-11-maintainability-review.md
git commit -m "docs(notes): maintainability review findings — full fresh-eyes audit"
```

- [ ] **Step 3:** Present to user: top-5 findings in prose, the emergent-findings section, and the proposed milestone shortlist. Milestone scoping is a NEW brainstorm with the user — not part of this plan.
