# Issue #40 — the round ring's depth is stated once by the code and guarded in every doc

**Issue:** https://github.com/dtrouton/Maugham/issues/40
**Spec authority:** CLAUDE.md's `Maugham/Compiler/` row (the true sentence: the document remembers **six** finished checks — the 5-deep `rounds` ring PLUS the standing run; a round ages out once six later checks stack up behind it) and `DiagnosticsStore.roundHistoryDepth` itself. House doctrine: "count the array, not this cell" — a number in prose gets a guard or gets removed.
**Branch:** `worktree-issue-40-round-ring-doc-truth`, off main `c762df4f`.

## Findings, re-verified 2026-08-27

- **The constant:** `Maugham/Compiler/DiagnosticsStore.swift:399` — `static let roundHistoryDepth = 5`. Rounds are filed into the ring only when superseded (`:216-217` trims to the depth), so the document's memory is the ring plus the standing run: **depth + 1 = six** finished checks; a round ages out after **six** later checks.
- **True today (say six):** `CLAUDE.md:135` ("SIX finished checks (the 5-deep `rounds` ring PLUS the standing run"), `docs/guide/compiler.md:138`, `docs/guide/review-passes.md:108` — all fixed by `33af6f3`.
- **D1, stale:** `Maugham/Compiler/AREA.md:758-760` — "capped at `roundHistoryDepth` (5)" is correct (that IS the ring), but "so five finished checks in Line push a Structural round out of it exactly as five more Structural checks would" is the off-by-one: a round in the ring is pushed out by the **sixth** later check (five filed behind it plus the standing one).
- **D2, stale:** `docs/roadmap.md:240` (M3 entry) — "computed against the document's 5-deep ring of finished checks" — the ring is 5-deep but the memory the since-line is computed against is six checks (CLAUDE.md's own wording: the ring PLUS the standing run).
- **D3, stale and drifting:** `docs/roadmap.md:316` — "`project.maugham.json` is at `schemaVersion: 1`"; actual `ProjectManifest.currentSchemaVersion = 8` (`Packages/MaughamCore/Sources/MaughamCore/ProjectManifest.swift:95`); it was 7 at the sweep. The bullet's premise ("define migration story before it evolves") is moot — ADR 0015 settled additive-optional evolution with no migrations.
- **E1, the cause:** the number lives in five docs and one constant with no guard. `MaughamTests/DocSyncTests.swift` already pins a constant↔doc pair with a parser + planted-offender self-check (`test_theCalibrationFiguresInTheCanvasAreaFileMatchTheirConstants` / `…WouldFireOnPlantedOffenders`, `:491-540`) and reads files via `readFile(_:)` (`:21`).

## Global constraints

1. The guard derives the expected number FROM `DiagnosticsStore.swift` (parse `static let roundHistoryDepth = N`), never from a literal in the test; the remembered count is `N + 1`.
2. Every doc the guard covers is listed in one array in the test — the array is the census; the test's failure message names the file and the sentence.
3. Each guarded doc must contain the CORRECT spelled number in the ring sentence AND must not contain the stale one (both directions — a doc that says neither is a doc that stopped stating the fact, which is also a failure, because the fact is load-bearing for a reader deciding whether a pass's round 1 is really round 1).
4. A planted-offender self-check proves the guard fires (a doctored string with "five finished checks" and one with no ring sentence at all).
5. No new prose count anywhere; where a number is removed rather than guarded (D3), the sentence names the constant instead.
6. `./scripts/test.sh` before committing; `DocSyncTests` is in the Mac scheme.

## Task 1 — the guard, and the two docs it immediately catches

**Files:** `MaughamTests/DocSyncTests.swift`; `Maugham/Compiler/AREA.md:758-760`; `docs/roadmap.md:240` and `:316`.

1. TDD — write the guard first, in `DocSyncTests`, mirroring the calibration pair's shape:
   - `static let roundRingDocs: [String]` = `["CLAUDE.md", "Maugham/Compiler/AREA.md", "docs/guide/compiler.md", "docs/guide/review-passes.md", "docs/roadmap.md"]` — with a comment: this array is the census of every doc that states the ring's memory; add a doc here when it starts stating it.
   - `static func roundHistoryDepth(fromSource text: String) -> Int?` — regex `static let roundHistoryDepth = (\d+)`.
   - `static func spelled(_ n: Int) -> String` — a small table (`1...12` is plenty; `precondition` beyond).
   - `static func roundRingMismatch(in doc: String, path: String, remembered: String, stale: String) -> String?` — returns nil when the doc contains a sentence with `remembered` + "finished checks" or `remembered` + "later checks" (case-insensitive — CLAUDE.md capitalises SIX) AND contains no `stale` + "finished checks" / `stale` + "later checks" / "\(depth)-deep ring of finished checks"; otherwise a sentence naming the file and which way it is wrong ("says five, should say six" / "no longer states how many checks the document remembers"). Note `"5-deep rounds ring PLUS the standing run"` in CLAUDE.md is CORRECT and must not match — the stale pattern is the bare `-deep ring of finished checks`.
   - `test_everyDocStatesTheRoundRingsMemoryAsTheConstantPlusTheStandingRun()` — reads `Maugham/Compiler/DiagnosticsStore.swift`, parses the depth (`XCTAssertNotNil` self-check, as the calibration test does), computes `remembered = spelled(depth + 1)`, `stale = spelled(depth)`, runs every doc in `roundRingDocs`, asserts no mismatches with a message that says why this matters: the number drifted twice in one milestone (M3), and `33af6f3` fixed three docs and missed two.
   - `test_theRoundRingCheckWouldFireOnPlantedOffenders()` — three doctored strings: one saying "five finished checks" (fires: stale), one saying "5-deep ring of finished checks" (fires: stale), one with no ring sentence (fires: missing), and one control saying "last SIX finished checks" that does NOT fire. Assert the exact set.
   Run it RED: it must fail on exactly `Maugham/Compiler/AREA.md` and `docs/roadmap.md` (say so in the report — that is the evidence D1/D2 were live).
2. **D1** — `Maugham/Compiler/AREA.md:758-760`: keep "capped at `roundHistoryDepth` (5)" (the calibration-notation form; it is the ring); rewrite the consequence: the document remembers six finished checks — the ring plus the standing run, which is filed into the ring only when superseded — so a Structural round is pushed out once six later checks (in any lane) stack up behind it. One or two sentences, in the file's voice.
3. **D2** — `docs/roadmap.md:240`: "computed against the document's 5-deep ring of finished checks" → "computed against the document's memory of its last six finished checks (the 5-deep `rounds` ring plus the standing run)". Keep the rest of the sentence.
4. **D3** — `docs/roadmap.md:316`: replace the bullet's number with the constant's name and retire the moot premise: "`project.maugham.json` carries `ProjectManifest.currentSchemaVersion` (read the constant, not this line); evolution is additive-optional with no migrations (ADR 0015), so there is no migration story to define — the bullet's original ask is closed." Keep the ID-prefix-rename clause if it still reads true (ADR 0007). Mark the bullet ✓ or ⤴ per the roadmap's own legend, whichever the file uses for "closed by a decision".
5. Run the guard GREEN, then `./scripts/test.sh`.
6. Also grep once for any OTHER doc stating the ring's memory that the census array doesn't cover (`grep -rn -i "finished checks\|later checks\|-deep ring" docs Maugham CLAUDE.md README.md register`) — add any hit to the array (and fix it if stale); report the grep's hit list.

**Commit:** `docs(review): the round ring's memory is six checks in every doc, and DocSyncTests keeps it so (#40)`
