# Foundations Plan 1: The Docs Diet — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut what every agent must read before it works. CLAUDE.md goes from 23,030 words to at most 4,000. The shared package gets the map it lacks, the stale claims are fixed, about 3.6 GB of scratch copies leave the tree, and budget tests stop the docs regrowing.

**Architecture:** This is a MOVE, never a delete. Every rule CLAUDE.md drops is first written into the doc it belongs in:
- the full tripwire table goes to `docs/tripwires.md`;
- build troubleshooting goes to `docs/testing/TROUBLESHOOTING.md`;
- per-area detail goes to that area's AREA.md;
- the shared package's map goes to a new Core AREA.md.

A rule ledger records each moved rule and its new home. Budget tests live in MaughamCore's package tests, so they run in about 6 s, in CI's `core-tests` job, with no app build. They ratchet: each ceiling starts at today's size and is lowered as a task cuts.

**Tech Stack:** Markdown, Swift 5.10 XCTest (MaughamCore package tests), bash/git.

**Spec:** `docs/superpowers/notes/2026-10-17-foundations-audit.md` (§2 S2, §3 D1, D3, D4, D5, D8, §4 Plan 1). Reviewer D's report numbers are quoted there.

## Global Constraints

- **Nothing a rule says may be lost.** History may be dropped, because git keeps it. A RULE (anything an agent must obey or check) is moved, and its new home is recorded in `.superpowers/sdd/2026-10-17-foundations-plan1-docs-diet/rule-ledger.md` as `old CLAUDE.md line → new file:heading`.
- **Tripwire NUMBERS do not change.** 822 code comments cite them. `docs/tripwires.md` keeps rows 1–53 in order.
- **Final CLAUDE.md is at most 4,000 words** (whitespace-split count), and no line is longer than 1,000 characters.
- **CLAUDE.md carries no milestone tags**: no `Task N`, no `P3a`/`P3c plan 2`-style tags, no `fix round`, and no ISO dates.
- **CLAUDE.md states no count of a list that code owns** (tools, tests, enum cases). Name the source instead.
- **No code change outside tests**, and none to `docs/guide/` or `docs/skills/`. Those two folders are bundled into the app (`project.yml:58-60`).
- **Never delete** anything under `.claude/worktrees/` that `git worktree list` shows as dirty or unmerged, and never delete an sdd folder's `progress.md`, briefs or reports. Only `*-scratch` folders go.
- Gates: `./scripts/test.sh core` after every task that touches a test. `./scripts/test.sh` (fast) once at the end, because `DocSyncTests` is in the Mac scheme. Never raw `xcodebuild test` or bare `swift test`: another session shares the machine-wide gate lock.
- **CLAUDE.md is Denver's file.** The branch is reviewed whole, and the controller shows Denver the new CLAUDE.md before merging.

## Review Focus

1. **A rule silently dropped from CLAUDE.md.** An agent would then break an invariant it was never told about. *Pinned by:* the rule ledger (Tasks 3, 4, 6, 7), plus the whole-branch reviewer diffing old against new CLAUDE.md rule by rule against the ledger.
2. **A pointer to a file that doesn't exist.** The new docs lead agents somewhere; a wrong path is worse than none. *Pinned by:* the path census (Task 1) over CLAUDE.md, `docs/INDEX.md`, `docs/tripwires.md`, `docs/testing/TROUBLESHOOTING.md` and the Core AREA.
3. **The docs regrow next milestone.** CLAUDE.md was trimmed once in June and grew tenfold. *Pinned by:* the ratcheted word ceilings and the milestone-tag ban (Task 1, lowered in Tasks 3–7).
4. **Deleting work in progress during hygiene.** Two folders under `.claude/worktrees/` are not registered worktrees, and another session works in `../Maugham-wt/`. *Pinned by:* Task 2's merged-and-clean checks before every removal.
5. **`DocSyncTests` going red because CLAUDE.md no longer carries the tool count or the round-ring figure.** *Pinned by:* Task 7's edits to those two tests, so they read the doc that now carries the fact and forbid the count in CLAUDE.md.

---

### Task 1: Doc budget and path censuses (ratchet at today's sizes)

**Files:**
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`

**Interfaces:**
- Produces:
  - `DocBudgetTests.wordCeilings: [String: Int]`, a repo-relative path → maximum words. Later tasks LOWER these numbers and ADD rows for new docs.
  - `DocBudgetTests.lineCeilings: [String: Int]`, path → maximum characters on one line.
  - `DocBudgetTests.pathCheckedDocs: [String]`, the docs whose backticked file paths must resolve. Later tasks add rows.
  - Static helpers `wordCount(_:)`, `longestLine(_:)`, `milestoneTags(in:)` and `unresolvedPaths(in:repoRoot:)`, all pure over `String`.

Why a Core test: it runs in `./scripts/test.sh core` (~6 s) and in CI's `core-tests` job, with no app build. It reads the repo through `#filePath`, as `TripwireGrepTests` does. It must not name the temp directory (the `TestTemp` census); it needs no temp files.

- [ ] **Step 1: Measure today's sizes**

Run:
```bash
cd /Users/denver/src/Maugham
for f in CLAUDE.md Maugham/*/AREA.md MaughamPhone/AREA.md; do echo "$(wc -w < "$f") $f"; done
awk '{ if (length($0) > m) m = length($0) } END { print m }' CLAUDE.md
```
Write the numbers down. Expected now: CLAUDE.md 23030, Canvas 48005, OpLog 29586, Views 27098, Compiler 23303, Stores 16059, MCP 8490, MaughamPhone 5007, Editor 3673, Updates 1622.

- [ ] **Step 2: Write the test file**

```swift
import XCTest

/// **The docs' budgets** (foundations audit 2026-10-17, D1/D5). CLAUDE.md is
/// loaded into every session and every subagent; an AREA.md must be read
/// before its directory is edited. Both grew without limit because nothing
/// measured them. These ceilings RATCHET: a task that cuts a doc lowers its
/// number in the same commit, and no number is ever raised without a reason
/// written beside it.
final class DocBudgetTests: XCTestCase {

    /// Repo-relative path → the most words it may hold.
    static let wordCeilings: [String: Int] = [
        "CLAUDE.md": 23_030,
        "Maugham/Canvas/AREA.md": 48_005,
        "Maugham/OpLog/AREA.md": 29_586,
        "Maugham/Views/AREA.md": 27_098,
        "Maugham/Compiler/AREA.md": 23_303,
        "Maugham/Stores/AREA.md": 16_059,
        "Maugham/MCP/AREA.md": 8_490,
        "MaughamPhone/AREA.md": 5_007,
        "Maugham/Editor/AREA.md": 3_673,
        "Maugham/Updates/AREA.md": 1_622,
    ]

    /// Repo-relative path → the longest line it may hold, in characters.
    /// A single 15,000-character bullet cannot be skimmed or cited.
    static let lineCeilings: [String: Int] = [
        "CLAUDE.md": 16_000,
    ]

    /// Docs whose backticked file names must name a file that exists.
    static let pathCheckedDocs: [String] = []

    /// Docs that must carry no milestone tag (a rule outlives the milestone
    /// that made it; the tag is history and belongs in git or an ADR).
    static let untaggedDocs: [String] = []

    // MARK: - Helpers (pure; the planted controls below exercise them)

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // MaughamCore/
            .deletingLastPathComponent()   // Packages/
            .deletingLastPathComponent()   // repo root
    }

    static func read(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func longestLine(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count).max() ?? 0
    }

    /// `Task 4`, `P3a`, `P3c plan 2`, `plan 1`, `fix round`, an ISO date.
    static func milestoneTags(in text: String) -> [String] {
        let pattern = #"\bTask \d+\b|\bP\d[a-c]?\b|\bplan \d+\b|\bfix round\b|\b20\d\d-\d\d-\d\d\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// Every `` `…something.ext` `` (swift, md, yml, sh, json) that names no
    /// file. With a `/`, the token is repo-relative and must exist exactly; a
    /// bare name must exist somewhere under the searched roots. Tokens with
    /// `*`, `<` or a space are patterns, not files, and are skipped.
    static func unresolvedPaths(in text: String, repoRoot: URL) -> [String] {
        let pattern = #"`([A-Za-z0-9_+./-]+\.(?:swift|md|yml|sh|json))`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let names = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        let fm = FileManager.default
        var basenames: Set<String>?
        func allBasenames() -> Set<String> {
            if let basenames { return basenames }
            var found: Set<String> = []
            for root in ["Maugham", "MaughamPhone", "Packages", "MaughamTests",
                         "MaughamPhoneTests", "docs", "scripts", "register", ".github"] {
                let url = repoRoot.appendingPathComponent(root)
                guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil)
                else { continue }
                for case let file as URL in walker { found.insert(file.lastPathComponent) }
            }
            for top in (try? fm.contentsOfDirectory(atPath: repoRoot.path)) ?? [] {
                found.insert(top)
            }
            basenames = found
            return found
        }
        var missing: [String] = []
        for name in Set(names).sorted() {
            if name.contains("/") {
                let trimmed = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
                if !fm.fileExists(atPath: repoRoot.appendingPathComponent(trimmed).path) {
                    missing.append(name)
                }
            } else if !allBasenames().contains(name) {
                missing.append(name)
            }
        }
        return missing
    }

    // MARK: - The censuses

    func test_everyBudgetedDocIsWithinItsWordCeiling() throws {
        for (path, ceiling) in Self.wordCeilings.sorted(by: { $0.key < $1.key }) {
            let words = Self.wordCount(try Self.read(path))
            XCTAssertLessThanOrEqual(words, ceiling,
                "\(path) holds \(words) words, over its ceiling of \(ceiling). "
                + "Move detail into the AREA.md, ADR or note it belongs in; "
                + "do not raise the ceiling without a reason beside it.")
        }
    }

    func test_noBudgetedDocHasAnOverlongLine() throws {
        for (path, ceiling) in Self.lineCeilings.sorted(by: { $0.key < $1.key }) {
            let longest = Self.longestLine(try Self.read(path))
            XCTAssertLessThanOrEqual(longest, ceiling,
                "\(path) has a \(longest)-character line, over \(ceiling). Split it.")
        }
    }

    func test_everyBacktickedFileInACheckedDocExists() throws {
        for path in Self.pathCheckedDocs {
            let missing = Self.unresolvedPaths(in: try Self.read(path), repoRoot: Self.repoRoot)
            XCTAssertEqual(missing, [], "\(path) names files that do not exist: \(missing)")
        }
    }

    func test_untaggedDocsCarryNoMilestoneTag() throws {
        for path in Self.untaggedDocs {
            let tags = Self.milestoneTags(in: try Self.read(path))
            XCTAssertEqual(tags, [], "\(path) carries milestone tags (history belongs in git or an ADR): \(tags)")
        }
    }

    func test_theCeilingsNameRealDocs() {
        for path in Set(Self.wordCeilings.keys).union(Self.lineCeilings.keys)
            .union(Self.pathCheckedDocs).union(Self.untaggedDocs) {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: Self.repoRoot.appendingPathComponent(path).path),
                "a budget names \(path), which does not exist: the census would read nothing")
        }
    }

    // MARK: - Planted controls (each helper fires, and lets clean text through)

    func test_theHelpersFireOnPlantedOffenders() {
        XCTAssertEqual(Self.wordCount("one two\nthree\t four  "), 4)
        XCTAssertEqual(Self.longestLine("ab\nabcde\n"), 5)
        XCTAssertEqual(Self.milestoneTags(in: "Shipped in P3c plan 2, Task 4, fix round 1, on 2026-10-17."),
                       ["P3c", "plan 2", "Task 4", "fix round", "2026-10-17"])
        XCTAssertEqual(Self.milestoneTags(in: "Phase 3d was abandoned; tripwire 36 holds."), [],
                       "Phase 3d and tripwire numbers are not milestone tags")
        let missing = Self.unresolvedPaths(
            in: "See `CLAUDE.md`, `Packages/MaughamCore/Package.swift`, `NoSuchFile.swift`, "
                + "`docs/nope.md` and the pattern `Foo*.swift`.",
            repoRoot: Self.repoRoot)
        XCTAssertEqual(missing, ["NoSuchFile.swift", "docs/nope.md"])
    }
}
```

- [ ] **Step 3: Run it**

Run: `./scripts/test.sh core`. Expected: PASS, with all six `DocBudgetTests` green. If the planted control's expected array differs, fix the regex, not the expectation: `Phase 3d` and `tripwire 36` must pass, and every planted tag must fire.

- [ ] **Step 4: Disable experiment**

Temporarily change the CLAUDE.md word ceiling to `100` and run `./scripts/test.sh core`. Expected: FAIL naming CLAUDE.md. Restore it.

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift
git commit -m "test(docs): ratcheted word, line, path and milestone-tag budgets for the agent docs"
```

---

### Task 2: Repo hygiene (scratch copies and merged worktrees)

**Files:**
- Modify: `.gitignore` (only if needed)
- Untrack: `.superpowers/brainstorm/**` (29 files)
- Remove from disk (not tracked): four registered worktrees under `.claude/worktrees/`, two unregistered generated-project folders, the `*-scratch` folders of shipped plans under `.superpowers/sdd/`

**Interfaces:** none.

- [ ] **Step 1: Prove each worktree is merged and clean**

Run:
```bash
cd /Users/denver/src/Maugham
git worktree list
for b in claude/p3b-fix-f7 claude/p3b-fix-f6-f3 claude/p3b-fix-f124 worktree-hardening-2026-07; do
  git merge-base --is-ancestor "$b" main && echo "$b merged" || echo "$b NOT MERGED — STOP"
done
for w in agent-a60c882237ef6bec7 agent-aa4c0b327be75273f agent-acb62984dc7e39702 hardening-2026-07; do
  echo "$w: $(git -C .claude/worktrees/$w status --porcelain | wc -l) dirty"
done
```
Expected: all four merged and 0 dirty. If any prints NOT MERGED or non-zero dirty, leave that one and report it.

- [ ] **Step 2: Remove them and prune**

```bash
for w in agent-a60c882237ef6bec7 agent-aa4c0b327be75273f agent-acb62984dc7e39702 hardening-2026-07; do
  git worktree remove ".claude/worktrees/$w"
done
git worktree prune
git worktree list
```
Expected: only the main checkout remains, plus any worktree outside the repo that another session owns (for example `../Maugham-wt/...`). Do not touch those.

- [ ] **Step 3: The two unregistered folders**

`.claude/worktrees/editor-typing-bugs` and `.claude/worktrees/publishing-pipeline-design` are not git worktrees. Confirm each holds only a generated `Maugham.xcodeproj`:
```bash
for d in editor-typing-bugs publishing-pipeline-design; do echo "== $d"; ls -A ".claude/worktrees/$d"; done
```
Expected: `Maugham.xcodeproj` only. If so, `rm -rf` both. Otherwise leave them and report what is there.

- [ ] **Step 4: Scratch copies of shipped plans**

Only folders named `*-scratch` go. Ledgers, briefs, reports and `progress.md` stay.
```bash
find .superpowers/sdd -maxdepth 2 -type d -name '*-scratch' -print
```
Check that every printed path belongs to a plan whose milestone is released: the 2026-09-20, 2026-09-24 and 2026-09-26 signed-op-log plans, or earlier. Then:
```bash
find .superpowers/sdd -maxdepth 2 -type d -name '*-scratch' -exec rm -rf {} +
du -sh .superpowers/sdd .claude/worktrees 2>/dev/null
find . -name AREA.md -not -path './.git/*' | wc -l
```
Expected: sdd well under 100 MB, and exactly 9 AREA.md files (the real ones).

- [ ] **Step 5: Untrack the brainstorm files**

`.gitignore:32` already ignores `.superpowers/`, but 29 files were tracked before that rule.
```bash
git rm -r --cached -q .superpowers/brainstorm
git ls-files .superpowers | wc -l
```
Expected: `0`.

- [ ] **Step 6: Commit**

```bash
git commit -m "chore: untrack .superpowers/brainstorm (already ignored); worktrees and scratch cleared on disk"
```

---

### Task 3: Troubleshooting and the docs index

**Files:**
- Create: `docs/testing/TROUBLESHOOTING.md`
- Create: `docs/INDEX.md`
- Modify: `CLAUDE.md` ("First five minutes", "Build flow", "Outstanding correctness concerns")
- Modify: `Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`
- Create: `.superpowers/sdd/2026-10-17-foundations-plan1-docs-diet/rule-ledger.md` (not tracked; the controller's evidence)

**Interfaces:**
- Consumes: `DocBudgetTests.wordCeilings`, `pathCheckedDocs`, `untaggedDocs` (Task 1).
- Produces: `docs/testing/TROUBLESHOOTING.md` and `docs/INDEX.md`. Task 7 points CLAUDE.md at both.

- [ ] **Step 1: Write TROUBLESHOOTING.md (a verbatim move)**

Create `docs/testing/TROUBLESHOOTING.md`, opening with:

```markdown
# Test and build troubleshooting

Read this when a gate is red and the failure does not obviously name your change. Each section is a SYMPTOM, then what it really is, then what to do. The text was moved from CLAUDE.md on 2026-10-17 and keeps its original wording, measurements and pointers.

| Symptom | Section |
|---|---|
```

Then add one `##` section per bullet that CLAUDE.md's **Build flow** section carries after its command block (CLAUDE.md lines 46–65 today), plus both bullets of **Outstanding correctness concerns** about the MCP tests (lines 182–185). Title each section with the symptom an agent sees, for example:
- `## A 0.000s crash with "attempt to insert nil object" in a styling test`
- `## A red PDF-compile test whose response carries "errors": []`
- `## A Core test dies with only "Test Case … started."`
- `## "The test runner hung before establishing connection" on several workers`
- `## A mounted click test sees selectedRow == -1`
- `## A unit test stalls ~64 s on an NSOpenPanel`
- `## A new test file runs 0 tests`
- `## A test fails in the parallel suite but passes alone`
- `## A mounted-view test is red on CI only`
- `## Phantom "Undefined symbol" after a signature change`
- `## A warning census reads clean on an incremental build`
- `## SourceKit diagnostics`
- `## The dev app's compiler checks say "couldn't be read as notes" after a gate`
- `## MCP tests hang or park (history)`

Under each heading, paste that bullet's text verbatim. Fill the table's rows with each symptom and a link to its section.

The facts that are durable RULES rather than troubleshooting stay in CLAUDE.md as one line each (Step 4). For example: always use `pgrep -x xcodebuild`, never `-f`; never put `xcodebuild` in a wait loop's argv; `./gen.sh` after adding a file; `FontWarmup.ensure()` in a new styling suite; `TectonicProbe.requireReady()` in a new compile suite; `TestWindow` is the one window constructor; `TestTemp` is the one temp root; a Release build after any `ProjectWindow.body` change. List each of those rule lines in the rule ledger with "kept in CLAUDE.md".

- [ ] **Step 2: Write docs/INDEX.md (at most 600 words)**

Write a one-page map of where things are, with one line each, linking these files:
- `README.md`, `docs/constitution.md`, `docs/product.md`, `docs/problem-map.md`
- `docs/roadmap.md` (say "read the section for the area you're touching, not the whole file")
- `docs/adr/README.md` and the ADR folder
- `docs/tripwires.md` (it arrives in Task 4: link it now and add the path to `pathCheckedDocs` only in Task 4)
- `docs/testing/TROUBLESHOOTING.md`, `docs/RELEASING.md`
- `register/START-HERE.md`
- `docs/superpowers/{specs,plans,notes}/`, with the newest audit `docs/superpowers/notes/2026-10-17-foundations-audit.md`
- the AREA.md files
- `MaughamPhone/AREA.md`

State no counts.

- [ ] **Step 3: Start the rule ledger**

Create `.superpowers/sdd/2026-10-17-foundations-plan1-docs-diet/rule-ledger.md`. Write one row per CLAUDE.md line moved in this task: `CLAUDE.md:<old line> "<first 8 words>" → <new file>#<heading>` (or `→ kept in CLAUDE.md`).

- [ ] **Step 4: Cut CLAUDE.md's Build flow and Outstanding sections**

Keep the four `./gen.sh` / `test.sh` command lines and the "Raw invocations" block. Replace every explanatory bullet with:
- the one-line rules listed in Step 1;
- a final line: `When a gate is red and the failure doesn't name your change, read docs/testing/TROUBLESHOOTING.md before touching code.`

Delete the **Outstanding correctness concerns** heading. Its pbxproj bullet duplicates the Build flow's "`Maugham.xcodeproj/` is generated" line, which stays.

- [ ] **Step 5: Ratchet and register**

Measure with `wc -w CLAUDE.md docs/testing/TROUBLESHOOTING.md docs/INDEX.md`. Then in `DocBudgetTests`:
- set `"CLAUDE.md"` to its new count;
- add `"docs/INDEX.md": 600`;
- add `"docs/testing/TROUBLESHOOTING.md"` at its count rounded up to the next 100;
- add both new files to `pathCheckedDocs`;
- add `"docs/INDEX.md"` to `untaggedDocs`.

Run `./scripts/test.sh core`. Expected: PASS. If the path census names a missing file, fix the doc (moved text sometimes cites a renamed file; correct the path, never drop the pointer).

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/INDEX.md docs/testing/TROUBLESHOOTING.md Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift
git commit -m "docs: troubleshooting and a one-page index leave CLAUDE.md; build rules stay as one line each"
```

---

### Task 4: The tripwire table moves to docs/tripwires.md

**Files:**
- Create: `docs/tripwires.md`
- Modify: `CLAUDE.md` ("Architectural tripwires")
- Modify: `Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`

**Interfaces:**
- Consumes: Task 1's census arrays.
- Produces: `docs/tripwires.md`, holding rows 1–53 with their numbers unchanged.

- [ ] **Step 1: Move the table verbatim**

Create `docs/tripwires.md` with a short preamble:

```markdown
# Architectural tripwires

"Do not do X — here's why it broke before." Numbers are permanent: code comments cite them. CLAUDE.md carries one line per row; this file carries the why and the enforcement. When a census exists, its failure message states the rule too.
```

Paste CLAUDE.md's whole tripwire table (header plus rows 1–53) unchanged. Then fix the two stale facts the audit verified:
- Row 39's arm list: add `.retired`, and the sentence that says `trusted: { _ in false }` appears "twice in `OpLogStore.swift`" should say three times (`OpLogStore.swift` at the positions sweep, the tail and the segment fallback). Check the count first with `grep -c "trusted: { _ in false }" Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift`.
- Row 13 names `BuildVariant.swift`; its path is `Packages/MaughamCore/Sources/MaughamCore/BuildVariant.swift`.

- [ ] **Step 2: Replace CLAUDE.md's table with one line per row**

Use this format, with a rule of at most 25 words, then the enforcing test (or `prose only`):

```markdown
## Architectural tripwires

One line each; the why, the history and the full enforcement are in docs/tripwires.md. If your change rhymes with a row, read that row there first.

| # | Rule | Enforced by |
|---|---|---|
| 1 | No `NSTextStorage` subclass fronting several files | prose only (ADR 0001) |
| 2 | No SwiftUI ↔ AppKit two-way sync guarded by flags | prose only |
| 7 | No 4th caller of `EditorSurface.applyExternalText` | `TripwireGrepTests.test_applyExternalTextHasExactlyOneProductionCallSite` |
| 36 | No software private key in production; the person key (`PersonKey.swift`) is the one named exception | `TripwireGrepTests.test_noSoftwarePrivateKeyInProduction` |
```

Write all 53 rows this way. Copy each test name exactly from the row's "Enforced / more" cell; where a row names several tests, give the first and add `+N` (where N is how many more are named). Record all 53 rows in the rule ledger as `→ docs/tripwires.md row N`.

- [ ] **Step 3: Ratchet and register**

- Set `"CLAUDE.md"` to its new word count.
- Add `"docs/tripwires.md"` at its count rounded up to the next 100.
- Add `"docs/tripwires.md"` to `pathCheckedDocs`.
- Set `lineCeilings["CLAUDE.md"]` to CLAUDE.md's new longest line rounded up to the next 100. (It will fall to 1,000 in Task 7.)

Run `./scripts/test.sh core`. Expected: PASS. Fix any path the census names in `docs/tripwires.md` by correcting it to the file's real location.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/tripwires.md Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift
git commit -m "docs: tripwires get their own file; CLAUDE.md keeps one line per row with its test"
```

---

### Task 5: A map for MaughamCore

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/AREA.md`
- Modify: `Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`

Check first that a `.md` file inside the package's Sources folder is harmless. Run `./scripts/test.sh core` after adding it. If SwiftPM warns about an unhandled file, add `exclude: ["AREA.md"]` to the `MaughamCore` target in `Packages/MaughamCore/Package.swift`, run `./gen.sh`, and include `Package.swift` in the commit.

**Interfaces:**
- Produces: the Core AREA. Task 6 points CLAUDE.md's area table at it.

- [ ] **Step 1: List the files**

Run `ls Packages/MaughamCore/Sources/MaughamCore/*.swift`. Read each file's first doc comment (the first 30 lines are usually enough).

- [ ] **Step 2: Write the AREA (at most 6,000 words)**

Use exactly these four sections:

```markdown
# MaughamCore — area guide

Shared by the Mac app and the phone (tripwire 19: anything both surfaces touch is implemented here, once). Apple frameworks only; no UI imports. Cross-module API is `public`.

## Map
### The op log (storage, chain, seals)
- `OpLogStore.swift` — <one line: what it owns>
- …
### Trust and the register
### Permits and posture
### The person key
### Text model and parsing
### Statements, passes and roles
### Project model
### Publishing and translation shared types
### Build variant, identity and utilities

## Rules
One line each, with the tripwire number from docs/tripwires.md where one applies.

## Recipes
### Add a block kind to the text model
### Add a Statement.Kind
### Add a ProjectType case

## Pointers
- The op log's behaviour and history: `Maugham/OpLog/AREA.md`
- ADR 0032 (signed op log), ADR 0015 (schema evolution), ADR 0019 (clean derived .md), ADR 0022 (grammar ledger)
```

Map rules:
- Every `.swift` file in the folder appears exactly once, under the group that fits, with one line (at most 20 words) saying what it owns.
- Leave out history; no milestone tags.

Recipe rules: each recipe is at most 200 words, listing the files to touch in order and the census or exhaustive switch that checks the work. Build them from the audit note's C1/C2 evidence and the code:
- **Add a block kind:** `MarkdownBlockParser` → `ProjectAST` / `ElementCensus` → the LaTeX and XHTML emitters → `EmissionContract` → the phone reader.
- **Add a Statement.Kind:** `Statement.Kind` plus its switch sites. Grep `case .lessons` across all targets and list each file.
- **Add a ProjectType case:** the eight exhaustive switches, plus the defaulted `type ==` sites. Grep `\.screenplay\b` and say "these default silently".

- [ ] **Step 3: A census that the map stays complete**

Add to `DocBudgetTests`:

```swift
    /// Every Core source file is on the Core map (D3). A new file that is
    /// missing fails here, so the map cannot rot into a partial list.
    func test_everyCoreSourceFileIsOnTheCoreMap() throws {
        let dir = Self.repoRoot.appendingPathComponent("Packages/MaughamCore/Sources/MaughamCore")
        let area = try Self.read("Packages/MaughamCore/Sources/MaughamCore/AREA.md")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertFalse(files.isEmpty, "the control: no Core files found means the scan reads nothing")
        let missing = files.filter { !area.contains("`\($0)`") }
        XCTAssertEqual(missing, [], "Core files missing from Packages/MaughamCore/Sources/MaughamCore/AREA.md's Map")
    }
```

Then:
- Add `"Packages/MaughamCore/Sources/MaughamCore/AREA.md": 6_000` to `wordCeilings`.
- Add the same path to `pathCheckedDocs` and `untaggedDocs`.
- Add `"Packages/MaughamCore/Sources/MaughamCore/AREA.md": 1_000` to `lineCeilings`.

- [ ] **Step 4: Run and disable-test**

Run `./scripts/test.sh core`. Expected: PASS. Then temporarily delete one map line, run again (expected: FAIL naming that file), and restore it.

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/AREA.md Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift
git commit -m "docs(core): MaughamCore gets an area guide — a complete map, rules and three recipes"
```

---

### Task 6: CLAUDE.md's area table becomes one line per area

**Files:**
- Modify: `CLAUDE.md` ("Per-area pointers", "Inbox + transcription", "Behavioural claims + rulings")
- Modify: each `Maugham/*/AREA.md` and `MaughamPhone/AREA.md` that receives residual facts
- Modify: `Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`

**Interfaces:**
- Consumes: the Core AREA (Task 5).

- [ ] **Step 1: Find each cell's residue**

For each row of CLAUDE.md's per-area table, list the cell's sentences that state a RULE or a FACT not already in that area's AREA.md. To find them, grep the AREA for the cell's distinctive identifiers. The audit measured 78–96% overlap, so the residue is small.

- [ ] **Step 2: Move the residue**

Append each area's residue to its AREA.md under one heading, `## From CLAUDE.md's area table (2026-10-17)`, verbatim. The residue of the `Packages/MaughamCore/` cell goes into the Core AREA's Rules section instead. Record each sentence in the rule ledger. Pure history, such as "As of milestone X…" narrative with no rule in it, is not moved; mark it `dropped (history; git keeps it)` in the ledger.

- [ ] **Step 3: Rewrite the section as a lookup table**

Replace the whole "Per-area pointers" section with:

```markdown
## Per-area pointers

Before editing a path, read the area guide its row names. If a path matches several rows, read the most specific.

| Path | Area guide | The one rule to remember |
|---|---|---|
| `Packages/MaughamCore/**` | `Packages/MaughamCore/Sources/MaughamCore/AREA.md` | Both apps share it: implement once here, never twice (tripwire 19). |
| `Maugham/OpLog/**` | `Maugham/OpLog/AREA.md` | The op log is the source of truth; every load goes through `Document.load`. |
| `Maugham/Stores/**` | `Maugham/Stores/AREA.md` | Move or delete user content only through `DocumentStore`'s typed mover (tripwire 14). |
| `Maugham/Views/**` | `Maugham/Views/AREA.md` | Ask `Posture` what to offer; never compare a permit rung (tripwires 47, 51). |
| `Maugham/Editor/**` | `Maugham/Editor/AREA.md` | The `EditorHost` binding is fragile (tripwires 2, 3, 6, 7). |
| `Maugham/Canvas/**` | `Maugham/Canvas/AREA.md` | Membership never changes on a move or resize (tripwire 31). |
| `Maugham/Compiler/**` | `Maugham/Compiler/AREA.md` | The compiler reads and never writes; Maugham writes at ingest. |
| `Maugham/MCP/**` | `Maugham/MCP/AREA.md` | One catalogue, `MCPToolCatalog.all`; MCP never writes manuscript text. |
| `Maugham/Publish/**` | `Maugham/Resources/PublishStarter/EMISSION.md` (generated) | Edit `EmissionContract.swift`, never `EMISSION.md`; keep `style_file` inside its `\begingroup`. |
| `Maugham/Updates/**` | `Maugham/Updates/AREA.md` | — |
| `Maugham/Models/**` | `Packages/MaughamCore/Sources/MaughamCore/AREA.md` (Project model) | Schema evolution follows ADR 0015. |
| `MaughamPhone/**` | `MaughamPhone/AREA.md` | AppKit never; WhisperKit is Mac-only. |
```

Check each "one rule" against its AREA before writing it. Shorten "Inbox + transcription" and "Behavioural claims + rulings" to two lines each, keeping the rules:
- MCP inbox scope is read and promote only;
- read a module's filings before changing behaviour it has claims for;
- fixing a filed defect closes the loop in the same branch.

Move their remaining sentences to `Maugham/Stores/AREA.md` and `register/START-HERE.md` respectively, if they aren't there already.

- [ ] **Step 4: Ratchet**

Set every AREA.md's ceiling in `wordCeilings` to its new size. Most grew by their residue; write `// + residue from CLAUDE.md, 2026-10-17` beside each raised number. Set `"CLAUDE.md"` to its new count. Run `./scripts/test.sh core`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md Maugham/*/AREA.md MaughamPhone/AREA.md Packages/MaughamCore/Sources/MaughamCore/AREA.md register/START-HERE.md Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift
git commit -m "docs: CLAUDE.md's area table becomes a path → guide lookup; each cell's residue moves into its guide"
```

---

### Task 7: The kernel — invariants, onboarding, stale claims, the two DocSync tests

**Files:**
- Modify: `CLAUDE.md` ("First five minutes", "Hard invariants", "Releases", "Default workflow", "Questions")
- Modify: `Maugham/OpLog/AREA.md`, `Maugham/Views/AREA.md`, `Maugham/Stores/AREA.md` (stale claims)
- Modify: `MaughamTests/DocSyncTests.swift` (the tool-count and round-ring tests)
- Modify: `Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`

**Interfaces:**
- Consumes: `docs/INDEX.md`, `docs/tripwires.md`, `docs/testing/TROUBLESHOOTING.md`.

- [ ] **Step 1: First five minutes**

Replace that section with:

```markdown
## First five minutes of any session

1. Read `MEMORY.md` (the milestone index; it loads automatically).
2. Skim `docs/INDEX.md` for where things are.
3. Before editing a path, read the area guide the table below names for it.
4. Test new milestones against `docs/constitution.md`; ADRs in `docs/adr/` supersede the master spec.
```

- [ ] **Step 2: Hard invariants**

Keep all six invariants, each at most 80 words.

The op log bullet and the `Bootstrap.run` bullet carry signed-op-log and Option A detail (about 390 words for Bootstrap alone). Shorten them to the rule:
- every manuscript load goes through `Document.load`;
- the op log is the source of truth and the `.md` is derived;
- external `.md` edits are discarded;
- every line is chained and signed by one of four actor keys;
- in a narrowed book the load mints only where `LocalWritePermit.mayMintOpening` says;
- the load's own emissions are the author actor's.

Move the full original text of both bullets, verbatim, into `Maugham/OpLog/AREA.md` under `## The load seam and the op-log invariant (moved from CLAUDE.md, 2026-10-17)`. Record both in the ledger.

- [ ] **Step 3: Releases, workflow, questions**

- **Releases** stays at its current two lines.
- **Default workflow**: keep all 12 items at most 40 words each. Cut the milestone stories inside items 11 and 12 (M1C's numbers); the memory files hold them (`feedback_plan_detail_and_sequencing.md`).
- **Questions you do not need to ask**: keep it as is.
- Delete tripwire-11 duplication from the Questions list only if the tripwire line already says it. It does: tripwire 11 is "No test data migration".

- [ ] **Step 4: Fix the stale claims (D4)**

Each was verified by the audit; check each against the code before editing.

1. CLAUDE.md's "most recent codebase audits … 2026-05-19": delete it (INDEX.md now points at the newest audit).
2. CLAUDE.md's test counts ("4,624 tests", "5,780 passed"): removed in Task 3. Confirm they're gone.
3. CLAUDE.md's register coverage ("covers `TrashStore` and `Document+Rewind`"): replace with "see `register/reconciliation/` for the modules covered".
4. `Maugham/OpLog/AREA.md:3`'s "Cleanest area — don't refactor structurally": replace with "Structural changes need the census allow-lists updated in the same commit; the foundations audit (2026-10-17, plan 5) schedules `OpLogStore`'s split."
5. `Maugham/OpLog/AREA.md`'s Layout lists Core files (`OpLogStore`, `CheckpointStore`, `Bootstrap`, `ParagraphID`, `OpKind` and others) as if they lived in `Maugham/OpLog/`. Prefix each Core entry with `Packages/MaughamCore/Sources/MaughamCore/` or move it under a "In MaughamCore" sub-heading. Check every entry with `ls`.
6. `Maugham/OpLog/AREA.md`'s "P2 ships whole … until the admission sheet exists" warning: P2 shipped in v0.39.0; delete the warning.
7. `Maugham/Views/AREA.md`'s `EditorIntegrationHarnessTests` path: the file is `MaughamTests/Editor/EditorIntegrationHarnessTests.swift`. Remove the "10/10" count.
8. `Maugham/Views/AREA.md`'s claim that `PersonaMemory` remembers the binder segment: it holds only `detail` (`Maugham/Models/PersonaMemory.swift`).
9. `Maugham/Stores/AREA.md`'s "~170 lines" and "eight peer extension files": replace with "a façade plus peer extension files (`ls Maugham/Stores/ProjectStore*.swift`)".

- [ ] **Step 5: The two DocSync tests that read CLAUDE.md**

In `MaughamTests/DocSyncTests.swift`:

(a) `test_toolCountSyncedAcrossDocsAndCatalog`: CLAUDE.md no longer states the count. Keep the AREA.md check. Replace the CLAUDE.md half with an assertion that CLAUDE.md states NO tool count, so the number cannot drift back in:

```swift
        let claudeMd = try readFile("CLAUDE.md")
        XCTAssertNil(Self.claudeToolCount(from: claudeMd),
            "CLAUDE.md states an MCP tool count again. Count MCPToolCatalog.all instead; "
            + "the count lives in Maugham/MCP/AREA.md's catalogue heading only.")
```

Keep `claudeToolCount(from:)` and its planted self-check: it still proves the parser would find a count if one came back.

(b) `roundRingDocs`: if the new CLAUDE.md no longer states the round ring's memory, remove `"CLAUDE.md"` from the array. The check fires on silence, so a doc that no longer states the figure must leave the list (this array's own comment says so). Add a line to that comment: `CLAUDE.md left this census in the 2026-10-17 docs diet; the figure lives in Maugham/Compiler/AREA.md.`

- [ ] **Step 6: Final ratchet**

- Run `wc -w CLAUDE.md`. Expected: at most 4,000. If it is over, shorten the longest remaining section, moving text, never deleting a rule.
- Set `wordCeilings["CLAUDE.md"] = 4_000`.
- Set `lineCeilings["CLAUDE.md"] = 1_000`. If a line is over, split it.
- Add `"CLAUDE.md"` to `pathCheckedDocs` and `untaggedDocs`.
- Set every AREA ceiling to its new size.

- [ ] **Step 7: Gates**

Run `./scripts/test.sh core`. Expected: PASS. Then `./scripts/test.sh` (fast, for `DocSyncTests`). Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md Maugham/OpLog/AREA.md Maugham/Views/AREA.md Maugham/Stores/AREA.md MaughamTests/DocSyncTests.swift Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift
git commit -m "docs: CLAUDE.md becomes a ≤4k-word kernel; stale claims fixed; DocSync stops reading counts from it"
```

---

### Task 8: AGENTS.md is generated, not hand-copied

**Files:**
- Create: `scripts/gen-agents-md.sh`
- Create: `scripts/tests/gen-agents-md.test.sh`
- Generate: `AGENTS.md` (currently untracked; whether to track it is Denver's decision, asked at handoff)

`AGENTS.md` is an untracked hand copy of CLAUDE.md for another agent tool. It has already drifted, and its memory path reads `~/.Codex/…`.

**Interfaces:** `scripts/gen-agents-md.sh` writes `AGENTS.md` from `CLAUDE.md`. It takes no arguments and exits 0.

- [ ] **Step 1: Write the test first**

```bash
#!/usr/bin/env bash
# scripts/tests/gen-agents-md.test.sh — AGENTS.md is CLAUDE.md with a header and nothing else changed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/CLAUDE.md" "$TMP/CLAUDE.md"
MAUGHAM_REPO_ROOT="$TMP" "$ROOT/scripts/gen-agents-md.sh"
head -1 "$TMP/AGENTS.md" | grep -q 'GENERATED from CLAUDE.md' || { echo "FAIL: no generated header"; exit 1; }
diff <(tail -n +3 "$TMP/AGENTS.md") "$TMP/CLAUDE.md" > /dev/null || { echo "FAIL: body differs from CLAUDE.md"; exit 1; }
echo "ok"
```

Run `bash scripts/tests/gen-agents-md.test.sh`. Expected: FAIL (the script does not exist yet).

- [ ] **Step 2: The generator**

```bash
#!/usr/bin/env bash
# scripts/gen-agents-md.sh — write AGENTS.md from CLAUDE.md. Never edit AGENTS.md by hand.
set -euo pipefail
ROOT="${MAUGHAM_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
{
  echo "<!-- GENERATED from CLAUDE.md by scripts/gen-agents-md.sh — edit CLAUDE.md, then re-run. -->"
  echo
  cat "$ROOT/CLAUDE.md"
} > "$ROOT/AGENTS.md"
```

Run `chmod +x scripts/gen-agents-md.sh`, then the test. Expected: `ok`. Then run `scripts/gen-agents-md.sh` for real and check that `AGENTS.md` now starts with the header.

- [ ] **Step 3: Commit**

```bash
git add scripts/gen-agents-md.sh scripts/tests/gen-agents-md.test.sh
git commit -m "chore: AGENTS.md is generated from CLAUDE.md, never hand-copied"
```

---

## Finish

1. **Whole-branch review** (opus), given the audit note, this plan, the rule ledger, and `git diff main...HEAD`. Ask it to:
   - diff old CLAUDE.md (`git show main:CLAUDE.md`) against new, rule by rule, and confirm every rule's new home exists and says the same thing;
   - check the path census and budgets pass;
   - spot-check five rows of `docs/tripwires.md` against CLAUDE.md's one-liners;
   - try the audit's five discoverability tasks (add an MCP tool, a Statement.Kind, a review-pass editor, a publish block, a phone Settings row) from the new docs alone, and say where an agent would go wrong.
2. Show Denver the new CLAUDE.md before merging (it is his file).
3. The controller fixes MEMORY.md's stale line about the test host unlinking the dev socket (that fix shipped on 2026-09-06). This is outside the repo, so no commit.
