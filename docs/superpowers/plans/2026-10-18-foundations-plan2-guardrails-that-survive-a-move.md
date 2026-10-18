# Foundations Plan 2: Guardrails That Survive a Move — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the grep censuses and source-reading tests find code by TYPE and SYMBOL instead of by file name. Every census whose target disappears must fail rather than pass, so that plans 4 and 5 (splitting `ProjectWindow` and `OpLogStore`) can move code without silently switching guardrails off.

**Architecture:**
- One test-support type, `SourceTree`, owns the repo's production roots, reads files by repo-relative path, finds the files that declare a type, and extracts a declaration's body wherever it lives.
- The two file-scoped `grepSwift` overloads fail loudly when a named scope file is missing.
- The filename-keyed allow-lists for the monoliths plans 4–5 will split accept a `type:` key ("any file declaring this type").
- The ~100 tests that read `Views/ProjectWindow.swift` by path move onto `SourceTree`.

**Tech Stack:** Swift 5.10 XCTest (Mac test target `MaughamTests`), bash (`scripts/test.sh`).

**Spec:** `docs/superpowers/notes/2026-10-17-foundations-audit.md` §2 S1, §3 G1–G3 and G5, §4 Plan 2. The audit's reviewer E and A reports are summarised there.

## Global Constraints

- **No census may become weaker.** Every census keeps its planted-offender control, and every migrated one gains a control proving the new lookup still fires. A census whose scope or target is missing must FAIL, never pass empty.
- **Absence assertions widen, never narrow.** "Pattern X must not appear in `ProjectWindow.swift`" becomes "must not appear under `Maugham/Views`", or under the directory the rule is really about. A narrower type scope would let the pattern escape into a child view.
- **Order assertions keep their scope.** A test asserting token ORDER inside one function stays scoped to that function's body, now found by symbol.
- **Production code is unchanged.** This is a test-and-script plan.
- **Do not edit `CLAUDE.md`, `docs/tripwires.md` or any `AREA.md`.** Plan 1's branch is rewriting them. The controller sweeps the docs after both plans merge.
- **Gates:** `./scripts/test.sh` (fast) after each task that touches tests; `./scripts/test.sh full` before the final review. Never raw `xcodebuild test` or bare `swift test`; another session shares the gate lock. Use `pgrep -x`, never `-f`.
- Branch `claude/foundations-plan2-guardrails`, off `main`. Never push.

## Review Focus

1. **A migrated test that passes vacuously** because the symbol lookup returned nothing and the test checked `isEmpty`/`!contains`. *Pinned by:* `SourceTree` throws on zero matches (Task 1), plus a per-file planted control in Tasks 4–5.
2. **A symbol found in two files** (a struct and its extension both "declare" a name, or two types share a method name), so the test reads the wrong body. *Pinned by:* `declaration(named:under:)` throws when more than one match is found (Task 1).
3. **A `type:` allow-list key that matches no file**, so the allow-list grants nothing and the census looks fine. *Pinned by:* a type key must resolve to at least one file, or the census fails (Task 3).
4. **A new package under `Packages/` that no census scans.** *Pinned by:* the source-roots classification census (Task 2).
5. **`test.sh only` bypassing the lock, or running a stale project with 0 tests.** *Pinned by:* Task 6 runs `only` inside the same lock, and the stale-project guard regenerates first.

---

### Task 1: `SourceTree` — roots, reads, type and symbol lookup

**Files:**
- Create: `MaughamTests/TestSupport/SourceTree.swift`
- Create: `MaughamTests/TestSupport/SourceTreeTests.swift`

**Interfaces (produced; later tasks use these exact names):**

```swift
enum SourceTree {
    struct LookupError: Error, CustomStringConvertible { let description: String }

    /// The repo root, from this file's #filePath (MaughamTests/TestSupport/ → two up).
    static var repoRoot: URL { get }

    /// Every production Swift root, repo-relative: "Maugham", "MaughamPhone",
    /// and each "Packages/<pkg>/Sources/<target>" that exists on disk.
    static var productionRoots: [String] { get }

    /// The file at a repo-relative path. Throws LookupError naming the path if absent.
    static func read(_ repoRelative: String) throws -> String

    /// Repo-relative paths of every .swift file under `root` (a repo-relative dir).
    static func swiftFiles(under root: String) throws -> [String]

    /// Repo-relative paths of the files under `roots` that DECLARE `typeName`:
    /// a line whose code (after attributes and access/final/@MainActor modifiers)
    /// begins `class|struct|enum|actor|protocol|extension <typeName>` followed by
    /// a non-identifier character. Throws if none.
    static func filesDeclaring(_ typeName: String, under roots: [String]) throws -> [String]

    /// The concatenated text of every file declaring `typeName`.
    static func sourceOfType(_ typeName: String, under roots: [String]) throws -> String

    /// The brace-matched body (header through closing brace) of the ONE declaration
    /// whose line contains `header` (e.g. "private func manuscriptEditor(",
    /// "static func reviewCentreShowsBoard("), searched across every .swift file
    /// under `root`. Throws if zero matches or more than one.
    static func declaration(named header: String, under root: String) throws -> String
}
```

**Contract details** the implementer must get right:
- Brace matching ignores braces inside string literals and `//` comments. Reuse `SourceScan.codeLines(of:)` (`MaughamTests/SourceScan.swift`) where it fits, or strip strings and comments the same way.
- A `header` match inside a comment line does not count.
- Every error message names the header, type or path, and the roots searched.

- [ ] **Step 1: Write `SourceTreeTests` first.** Pin each rule against planted text written under `TestTemp.root`, with no reads of real production files except one smoke check:
  - (a) `filesDeclaring` finds a struct and its extension in two files, and does not match `ProjectWindowX`.
  - (b) It throws on no match.
  - (c) `declaration(named:)` returns the body of a function whose body contains a string literal holding `}`.
  - (d) It throws on two matches.
  - (e) It throws on zero.
  - (f) A header inside a `//` comment is ignored.
  - (g) Smoke check: `filesDeclaring("ProjectWindow", under: ["Maugham"])` includes `Maugham/Views/ProjectWindow.swift`.

  The lookup functions take roots, so testing against planted files needs a seam. Give `SourceTree` an internal overload of each lookup that takes a base URL, and have the public ones pass `repoRoot`.

  Run `./scripts/test.sh` (expected: compile failure). Then `./gen.sh`; new files need it.

- [ ] **Step 2: Implement `SourceTree`** until `SourceTreeTests` passes. Run `./scripts/test.sh` and expect `** TEST SUCCEEDED **`.

- [ ] **Step 3: Disable experiment.** Make `declaration(named:)` return the first match instead of throwing on two. The (d) test must fail. Restore.

- [ ] **Step 4: Commit**
  `test(support): SourceTree — production roots, type and symbol lookup that throws on zero or many`

---

### Task 2: Loud scopes, and every package classified

**Files:**
- Modify: `MaughamTests/TripwireGrepTests.swift`:
  - the `grepSwift(in:files:patterns:excludeLine:)` overload (`:50-73`);
  - the `grepSwift(in:patterns:allowedSpellings:excludeLine:onlyFiles:)` overload (`:8034`);
  - `test_theSilentAdmissionNarrowsNobody` (`:9462`) and the census at `:9622`;
  - a new census and its control.

**Interfaces:**
- Consumes: `SourceTree.filesDeclaring`, `SourceTree.productionRoots` (Task 1).
- Produces: `TripwireGrepTests.knownSourceRoots: [String: String]` (repo-relative root → which censuses scan it).

- [ ] **Step 1: Planted controls first.**
  - Write `test_aFileScopedCensusFailsWhenItsFileIsMissing`. It calls the `files:` overload with a planted dir under `TestTemp.root` holding `A.swift` but not `B.swift`, with `files: ["A.swift", "B.swift"]`. It expects the result to contain an offender line beginning `MISSING SCOPE: B.swift`.
  - Write the same for `onlyFiles:`.
  - Run them; expect FAIL, because today a missing file is skipped silently.

- [ ] **Step 2: Make both overloads report missing scope.** After the walk, add `"MISSING SCOPE: <name> — the census reads nothing; the file moved or was renamed"` as an offender for every name in `files`/`onlyFiles` that was never seen. Every caller asserts `isEmpty`, so a missing file now fails with that sentence.
  - Run `./scripts/test.sh`. Expected: PASS.
  - If a real caller now fails, its file really has moved. Report it as a finding; do not paper over it.

- [ ] **Step 3: Scope the silent-admission census by type.** In `test_theSilentAdmissionNarrowsNobody` and the sibling at `:9622`, replace `onlyFiles: ["RegistryPresence.swift"]` with the basenames of `try SourceTree.filesDeclaring("RegistryPresence", under: SourceTree.productionRoots)`. Its allow-list (`silentAdmissionAllowed`) is keyed by file name; if `filesDeclaring` returns more than one file, give each the same allowed spelling. Planted control: a `RegistryPresence` extension in a second planted file carrying `role: "reviewer"` is caught.

- [ ] **Step 4: Every source root is classified.**
  - Add `static let knownSourceRoots: [String: String]`, with one entry per element of `SourceTree.productionRoots`. The value names who scans that root, e.g. `"Maugham": "sourceDir censuses + admissionRoots"`, `"Packages/MaughamCore/Sources/MaughamCore": "admissionRoots, coreRoot censuses"`, `"MaughamPhone": "TripwirePhoneGrepTest"`.
  - Add `test_everyProductionRootIsClassified`, asserting `Set(knownSourceRoots.keys) == Set(SourceTree.productionRoots)`, with the failure message: "a new source root exists: decide which censuses must scan it, then name it here".
  - Add a control: a planted `Packages/Fake/Sources/Fake` under a planted base is reported. This uses Task 1's base-URL seam.

- [ ] **Step 5: Disable experiment.** Revert Step 2's missing-scope line; the Step 1 controls must fail. Restore.

- [ ] **Step 6: Commit**
  `test(tripwires): a file-scoped census fails when its file is gone; the silent-admission census scopes by type; every source root is classified`

---

### Task 3: `type:` keys in the file-plus-spelling allow-lists

**Files:**
- Modify: `MaughamTests/TripwireGrepTests.swift`:
  - the file-plus-spelling overload (`:8034`), where `allowedSpellings[name]` is looked up;
  - the counted-list helper behind `countedLists` (`:9510`);
  - `partitionCallSites` (`:8674`).
- Modify: `MaughamTests/PersonKeyCensusTests.swift` (its per-file arrays).

**Interfaces:**
- Consumes: `SourceTree.filesDeclaring` (Task 1).
- Produces: an allow-list key may be `"type:<TypeName>"`, which means every file that declares `TypeName`. In a COUNT map, a type key's count is the SUM over those files.

- [ ] **Step 1: Planted controls first.**
  - (a) An allow-list `["type:Widget": ["sanctioned("]]` lets `sanctioned(` through in BOTH `Widget.swift` and `Widget+More.swift` (`extension Widget`), and still catches it in `Other.swift`.
  - (b) A count map `["type:Widget": 2]` passes with one site in each file and fails with three.
  - (c) A `type:` key that resolves to no file FAILS the census with "type key `type:Nothing` names no file".
  - Run; expect FAIL.

- [ ] **Step 2: Implement.** Before a census walks, expand every `type:` key into the basenames `SourceTree.filesDeclaring` returns: merge spellings for allow-lists, and compare sums for count maps. A key that expands to nothing is an offender.

- [ ] **Step 3: Convert the keys plans 4–5 will need.** Change file keys to type keys for every entry naming:
  - `OpLogStore.swift` → `type:OpLogStore`
  - `RegistryAdmission.swift` → `type:RegistryAdmission`
  - `DocumentStore.swift` and `DocumentStore+*.swift` → `type:DocumentStore` (merging their spellings; sum their counts)
  - `ProjectWindow.swift` → `type:ProjectWindow`
  - `OpLogChain.swift` → `type:OpLogChain`

  This applies to `trustClosureAllowedSpellings`, `partitionCallSites`, `localWritePermitAllowed`, `narrowingAllowed`, `countedLists`, `postureAskAllowed`, `manuscriptWriterCallSites`, `registryWriterCallers` and `permitFieldAllowedFiles`/`permitTableAllowed`, plus `PersonKeyCensusTests`' arrays.

  A `Set<String>` of file names (e.g. `registryWriterCallers`) also accepts `type:` entries.

  Leave a key as a file only where the rule truly is about one file; write `// file-scoped: <why>` beside it.

  Run `./scripts/test.sh`. Expected: PASS, with identical behaviour today because each type lives in the files it was keyed by.

- [ ] **Step 4: Disable experiment.** Temporarily move one sanctioned `OpLogStore` line into a new planted extension file under a planted base. The census must still pass, because the type key follows the code. The same line in a planted non-`OpLogStore` file must fail.

- [ ] **Step 5: Commit**
  `test(tripwires): allow-lists for the monoliths are keyed by type, so a split moves no census`

---

### Task 4: `ProjectWindow` path reads → symbols (the heavy files)

**Files:** `MaughamTests/Canvas/PromotionCommandTests.swift`, `ReviewBoardRoutingTests.swift`, `DetailColumnWidthTests.swift`, `PublishPreviewCentreTests.swift`, `ManuscriptForceCensusTests.swift`, `PaletteWallDoorTests.swift`, `DesignGateTests.swift`. Together they hold about 53 of the reads.

**Interfaces:** Consumes `SourceTree.declaration(named:under:)`, `sourceOfType`, `read`.

- [ ] **Step 1: Classify every read.** For each `ProjectWindow.swift` read, record its class in the report:
  - **(D) Declaration lookup:** the test finds a function or type in the file and inspects its body. Use `SourceTree.declaration(named: <header>, under: "Maugham")`.
  - **(P) Presence:** "the window does X somewhere". Use `SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"])`.
  - **(A) Absence:** "X never appears". Widen to every file under `Maugham/Views` (or the rule's directory), never narrower.
  - **(C) Count:** "exactly N occurrences". Count over `sourceOfType("ProjectWindow", …)` unless the rule names a single function, in which case use (D).

  Delete each file's private `source(of:)`/`declaration(named:)` helper once nothing in that file uses it.

- [ ] **Step 2: Migrate file by file**, running `./scripts/test.sh` after each file. Every test must pass unchanged in meaning.

- [ ] **Step 3: One planted control per migrated file.** In each file, add one test that runs that file's own check against a planted source tree (a planted `ProjectWindow` struct plus an extension in a second file) and proves the check still fires: (D) finds the body across the extension, (A) catches the offender in a sibling view file, (C) counts across both files.

- [ ] **Step 4: Commit**
  `test: the heavy ProjectWindow-pinned suites read by symbol and type, not by path`

---

### Task 5: `ProjectWindow` path reads → symbols (the rest)

**Files:** every other test file that names `ProjectWindow.swift`. Find them with:

```
grep -rln "ProjectWindow.swift" MaughamTests | grep -v -e PromotionCommandTests -e ReviewBoardRoutingTests -e DetailColumnWidthTests -e PublishPreviewCentreTests -e ManuscriptForceCensusTests -e PaletteWallDoorTests -e DesignGateTests
```

Today that is about 30 files, including the 5 references in `TripwireGrepTests.swift` (the persona decider `:6212`, reveal facts `:7202`, `manuscriptWriterCallSites` `:9959`).

Same steps as Task 4, with the same four classes and a planted control per file where the file has a check that could go vacuous. Mentions of `ProjectWindow.swift` that only sit in comments may stay.

Finish by running:

```
grep -rn '"Views/ProjectWindow.swift"\|ProjectWindow.swift")' MaughamTests | grep -v "^\s*//"
```

Expected: no code reads remain.

- [ ] Commit: `test: no test reads ProjectWindow.swift by path`

---

### Task 6: `test.sh only` and the stale-project guard

**Files:**
- Modify: `scripts/test.sh`
- Create: `scripts/tests/test-sh.test.sh`

**Contract:**
- `./scripts/test.sh only <Class> [<Class>…]` runs `xcodebuild … test -only-testing:MaughamTests/<Class>` for each class, with the same `$TIMEOUTS`, inside the same machine-wide lock the other modes take.
- A class name containing `/` is passed through as given (e.g. `MaughamTests/Foo/test_bar`).
- An unknown class is xcodebuild's failure to report; the script adds nothing.
- **Stale-project guard, in every Mac mode:** before building, if `project.yml`, or any tracked `.swift` file under `Maugham*/` or `Packages/`, is newer than `Maugham.xcodeproj/project.pbxproj`, run `./gen.sh` first and print `▸ project.yml or the file set changed — regenerating`.
  - Detect it with `find project.yml Maugham MaughamTests MaughamPhone MaughamPhoneTests Packages -newer Maugham.xcodeproj/project.pbxproj \( -name '*.swift' -o -name project.yml \) -print -quit`.
  - Also regenerate when the set of tracked `.swift` files changed. Keep `git ls-files '*.swift' | shasum` in `Maugham.xcodeproj/.maugham-fileset`, and regenerate when it differs.

- [ ] **Step 1:** Write `scripts/tests/test-sh.test.sh`. It sources the guard as a function, or runs `test.sh` with `MAUGHAM_TEST_DRY_RUN=1` (add that variable: it prints the commands it would run and exits 0). It asserts:
  - (a) `only Foo Bar` prints one `xcodebuild` line with both `-only-testing` flags, inside the lock;
  - (b) touching a planted newer `.swift` file makes the guard print the regenerate line;
  - (c) an unchanged tree does not.

- [ ] **Step 2:** Implement, and keep the usage line current: `usage: $0 [fast|full|phone|core|only <Class>…]`.

- [ ] **Step 3:** Run `bash scripts/tests/test-sh.test.sh` (expect `ok`). Then run `./scripts/test.sh only SourceTreeTests` for real (expect `** TEST SUCCEEDED **`).

- [ ] Commit: `chore(test.sh): an 'only' mode under the lock, and regenerate the project when the file set changed`

---

## Finish

1. `./scripts/test.sh full` must be green.
2. Whole-branch review on opus, given the audit note, this plan, the ledger and the diff. Ask it:
   - Hunt for any census or source test that became weaker: vacuous, narrowed absence, or lost control.
   - Check that every `type:` key resolves.
   - Plant one move of real code in a scratch copy and run the affected censuses: move `OpLogStore`'s `localWritePermit` into a new `OpLogStore+Permit.swift`, and move `ProjectWindow.manuscriptEditor` into an extension file. Confirm they still pass, and that a planted offender in the moved code still fails.
3. Do not merge without Denver. The controller then sweeps `CLAUDE.md`, `docs/tripwires.md` and `Maugham/OpLog/AREA.md` for "keyed by file" claims, after plan 1 merges.

## Out of scope (ruled)

- **Moving the censuses into their own SwiftPM package (audit G4).** With scopes loud and allow-lists keyed by type, the remaining gain is speed. The move would also need `SourceTree` in two test targets. Revisit with the module split (audit E1).
- **Re-keying censuses for files no plan intends to split.** File keys stay where the rule is about one file.
