# Signed op log — the performance step — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close decisions #1, #3, #4 and #5 of the P1 handoff with measured changes: a faster date decode on the cold open, a byte-level `prev` read on the chain walk, a rotating project stream, a pruning device-state file, and a quiet-machine cost table recorded in the ADR and the area guide.

**Architecture:** Every change is inside `Packages/MaughamCore` (the parser, the chain, the store, the device state) except the two production owners of rotation in `Maugham/Stores/`. Nothing here changes a byte of the wire format: the encoding side of the date strategy is untouched, `prev` keeps its position and its spelling, a rotated project segment is the same container every manuscript segment is. Measurement brackets the work — the fixture runs before Task 1 and after Task 3.

**Tech Stack:** Swift 6, Foundation, CryptoKit, XCTest; `swift test` for the package, `./scripts/test.sh` for the Mac and phone gates.

**Spec:** `docs/superpowers/notes/2026-09-08-signed-op-log-performance-handoff.md` (the brief), amended by the two decisions Denver made on 2026-09-09 (below). Read ADR 0032 §3–§5 and `Maugham/OpLog/AREA.md` "Chained and sealed" before touching the store.

## Decisions made 2026-09-09 (Denver)

1. **The budget is the chain's own cost, read directly by the fixture** — never an end-to-end subtraction. Two figures: the walk over a realistic tail (≤ 512 KB, ~600 lines) under **20 ms**; the walk over the fixture's 8×-oversized 6,250-line tail under **100 ms**. (P1 handoff decision #1, accepted as reframed.)
2. **`__project__` rotates at the same 512 KB** as every other stream, `OpLogStore.segmentSealThreshold`, no second constant. (P1 handoff decision #4.)

## Corrections to the brief, found while planning

- **Item 5's "coalesce persists to one per `sealChain`" is not done.** `JSONLAppendStore.append`'s chained path calls `chain.state.remember(head:for:)` *before* it writes the batch (`JSONLAppendStore.swift:368`, "Persist-before-write"): a crash between the two leaves a remembered head no line hashes to, which `OpLogChain.resolveAbsentHead` adopts — where a crash the other way round would leave a line this device wrote sitting after its remembered head, which is the quarantine case. Deferring the persist would turn a crash into a set-aside of the writer's own words. The persist is already once per BATCH, not once per line. Item 5 is therefore prune-only, plus a pinned measurement of the persist count.
- **`OpLogDeviceState.fileKey` hashes the project root**, so "prune entries whose project root no longer exists" cannot be answered from the key alone. The state records the root path beside the hash from now on; an entry whose root is recorded and gone is pruned at load, an entry with no recorded root is kept until its next `remember` records one.
- **`sealChain` and `sealTailIfNeeded` are two verbs and `__project__` only ever refused the second** (`OpLogStore.swift:801`). The other `__project__` guard, in `docId(fromOpLogFilename:)` at `OpLogStore.swift:923`, is a different reader — it keeps the project stream out of the set of MANUSCRIPT doc ids — and stays.
- **The boundary owner for the project stream is the open sweep alone** (`DocumentStore.open`, `DocumentStore.swift:185–230`). A document rotates at close and at open; the project stream has no close, so open is its moment. In-session growth past 512 KB needs ~2,500 task ops in one session at ~200 bytes each — accepted, and recorded as a ruling Denver can undo.

## Global Constraints

- The **encoding** of dates does not change by one byte: `JSONLAppendStore.dateEncoding` is not edited. (Every remembered chain head is a hash over encoded bytes.)
- `prev` is the FIRST key of a chained line, spelled exactly `{"prev":"<64 hex>"` (`OpLogChain.chainedLine`, `OpLogChain.swift:116`); a fast path reads that shape and falls back to the existing reader for anything else. No wire-format change.
- No software `P256.Signing.PrivateKey(` in production (tripwire 36); every verified-path test injects `DeviceIdentity.softwareForTesting`.
- A seal line is recognised in `OpLogChain` only (tripwire 37).
- Every task green on `swift test --parallel --package-path Packages/MaughamCore`, `./scripts/test.sh`, and `./scripts/test.sh phone`; `./scripts/test.sh full` before the branch merges.
- The perf fixture is `MAUGHAM_PERF_FIXTURE=1 swift test -c release --package-path Packages/MaughamCore --filter OpLogChainCostTests`. Every number in a task report comes from three runs on a quiet machine (`ps ax | grep xcodebuild` empty, load average under 2), reported as the fixture prints them (best of three per quantity).
- Branch: `claude/signed-op-log-perf-step-2026-09-09` off `main`. Merge to local `main`, unpushed.

---

### Task 0: The "before" table

**Files:**
- Read only: `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogChainCostTests.swift`

- [ ] **Step 1: Confirm the machine is quiet.** `ps ax | grep -c '[x]codebuild'` prints 0; `uptime` load average under 2. Wait if not.
- [ ] **Step 2: Run the fixture three times**, saving each run's printed `=== OpLogChainCostTests fixture ===` block to the scratchpad. The fixture already reports best-of-three per quantity; three invocations give three such bests.
- [ ] **Step 3: Record the table** in `docs/superpowers/notes/2026-09-09-perf-step-measurements.md` under a `## Before` heading: cold, warm, control, chain walk, signature checks — one row per run, then the minimum. Commit: `docs(perf): the before table for the performance step`.

---

### Task 1: `prev(ofLine:)` by bytes, and the device state prunes

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpLogChain.swift:173–222` (`prev(ofLine:)`)
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpLogDeviceState.swift` (`Stored`, `init`, `remember`, `persistLocked`)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogChainTests.swift`, `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogDeviceStateTests.swift`

**Interfaces:**
- Consumes: `OpLogChain.chainedLine(elementJSON:prev:)`, `OpLogChain.lineHash(_:)`, `OpLogChain.genesis` (64 hex), `OpLogDeviceState.fileKey(_:)` (`<sha256 hex of root>/<filename>`), `OpLogDeviceState.remember(head:for:)`, `.head(for:)`, `.previousHead(for:)`, `.markVerified(segmentDigest:)`.
- Produces: `OpLogDeviceState.remember(head: String?, for fileKey: String, root: URL?)` — a new optional parameter, default `nil`, so the two existing callers (`OpLogStore.swift:333`, `JSONLAppendStore.swift:368`) compile unchanged and Task 1 then passes the root at both (the store's `projectURL`; `JSONLAppendStore`'s `chain.projectURL`). `internal var persistCountForTesting: Int` on `OpLogDeviceState`, incremented in `persistLocked`.

**Part A — `prev(ofLine:)`**

- [ ] **Step 1: Write the failing tests** in `OpLogChainTests`:
  - The fast shape: `chainedLine(elementJSON: element(1), prev: genesis)` answers `.some(.some(genesis))` (already pinned at line 257 — keep it; it is the contract).
  - Equivalence over a corpus: for each of `{"prev":"<64 hex>","a":1}`, `{"prev":"<64 hex>"}`, ` {"prev":"<64 hex>"}` (leading space), `{ "prev" : "<64 hex>" }` (inner spaces), `{"prev":"short"}` (a non-64 value), `{"prev":"<64 hex>` (unterminated), `{"prev":<64 hex>}` (unquoted), `{"prevx":"<64 hex>"}`, `{"a":1,"prev":"<64 hex>"}`, `{}`, `[1]`, empty — the answer equals what the pre-change reader gives. Capture the pre-change answers by running the corpus through the current implementation FIRST and hard-coding them as the expected values (this is how a refactor pins equivalence without keeping two implementations).
  - A timing sanity pin, NOT a gate: 6,000 chained lines through `prev(ofLine:)` in under 50 ms in debug — unconditional, because 50 ms is 50× the target and cannot flake.
- [ ] **Step 2: Run** `swift test --package-path Packages/MaughamCore --filter OpLogChainTests` — the corpus test passes already (same reader), the timing pin may or may not. Note which.
- [ ] **Step 3: Implement the fast path** at the top of `prev(ofLine:)`: if the line begins with the exact bytes `{"prev":"` (9 bytes, no whitespace), and byte 9+64 exists and is `"`, return `.some(String(decoding: line[9..<73], as: UTF8.self))`. Any other shape falls through to the existing reader untouched. Use `line.withUnsafeBytes` or index arithmetic off `line.startIndex` — `Data` slices do not start at 0. No `Data()` accumulation on the fast path.
- [ ] **Step 4: Run the tests** — all green. Run the fixture's chain-walk figure once (it isolates `verify`, of which `prev` is the per-line cost) and note before/after in the task report.

**Part B — the device state prunes**

- [ ] **Step 5: Write the failing tests** in `OpLogDeviceStateTests`:
  - `test_anEntryWhoseRecordedRootIsGoneIsPrunedAtLoad`: make two temp project roots each with a `.maugham/` child; `remember(head:for:root:)` a head under each; delete one root; a fresh `OpLogDeviceState` over the same file answers `head(for:)` nil for the deleted root's key and the head for the surviving one; `previousHead` for the pruned key is nil too.
  - `test_anEntryWithNoRecordedRootIsKept`: a state file written by the current shape (no `roots` key — build it by encoding the current `Stored` JSON by hand: `{"identity":"…","heads":{"k/one":"h"},"previousHeads":{},"verifiedSegments":[]}`) loads with `head(for: "k/one")` intact.
  - `test_rememberRecordsTheRootBesideTheHead`: after `remember(head:for:root:)`, the file's JSON has a `roots` object mapping the key's hash prefix (the part before `/`) to the root's `standardizedFileURL.path`.
  - `test_aBatchPersistsOnce`: `persistCountForTesting` goes up by exactly 1 per `remember` and per `markVerified` (this is the pinned MEASUREMENT the brief asked for; the number is one per batch because `JSONLAppendStore.append` remembers once per batch — cite `JSONLAppendStore.swift:368` in the test's doc comment).
  - `test_pruningIsBestEffortOverAnUnreadableRoot`: a recorded root path that is a FILE rather than a directory is treated as gone (its `.maugham` child cannot exist).
- [ ] **Step 6: Run to see them fail** (`remember` has no `root:` parameter; `roots` absent from the file).
- [ ] **Step 7: Implement:**
  - `Stored` gains `var roots: [String: String] = [:]` (hash → path), decoded with `decodeIfPresent … ?? [:]` like its siblings.
  - `remember(head:for:root:)`: when `root` is non-nil, `stored.roots[<hash part of fileKey>] = root.standardizedFileURL.path`. Forgetting (`head == nil`) does not remove the root record (other files under the same root still use it).
  - `init`: after a successful decode with matching identity, prune: for every `(hash, path)` in `roots` where `FileManager.default.fileExists(atPath: path + "/.maugham")` is false, remove every `heads`/`previousHeads` key with prefix `hash + "/"` and the `roots` entry. Persist once if anything was pruned. Heads whose hash has no `roots` entry are untouched.
  - `persistLocked` increments `persistCountForTesting`.
  - Pass the root at both callers: `OpLogStore.swift:333` (`root: projectURL`) and `JSONLAppendStore.swift:368` (`root: chain.projectURL`).
- [ ] **Step 8: Run** the package tests, then `./scripts/test.sh` and `./scripts/test.sh phone`. All green.
- [ ] **Step 9: Commit** `perf(oplog): prev(ofLine:) reads the fixed prefix by bytes; the device state records roots and prunes the dead ones`.

---

### Task 2: The date fast path

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/ISO8601Fast.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/JSONLAppendStore.swift:489–501` (`dateDecoding` only)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/ISO8601FastTests.swift` (new), plus one round-trip test in `Packages/MaughamCore/Tests/MaughamCoreTests/JSONLVerifiedReadTests.swift` or a new `JSONLDateCodingTests.swift`

**Interfaces:**
- Produces: `enum ISO8601Fast { static func date<C: Collection>(utf8: C) -> Date? where C.Element == UInt8 }` — accepts exactly `YYYY-MM-DDTHH:MM:SSZ` and `YYYY-MM-DDTHH:MM:SS.fffZ` (1–9 fraction digits, `Z` only), answers nil for any other shape including offsets, lowercase `z`, missing `T`, out-of-range fields (month 13, day 32, hour 24, minute/second 60). Days-from-civil arithmetic (Howard Hinnant's algorithm), no `Calendar`, no `DateFormatter`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests** in `ISO8601FastTests`:
  - Equivalence with the formatter over a corpus: for each string, `ISO8601Fast.date(…)` equals `ISO8601DateFormatter` (with `[.withInternetDateTime, .withFractionalSeconds]` for fractional shapes, plain for whole-second) to within `1e-6` seconds — assert `abs(a.timeIntervalSinceReferenceDate - b.timeIntervalSinceReferenceDate) < 1e-6`, because the formatter's fraction handling need not be bit-identical. Corpus: `1970-01-01T00:00:00Z`, `1970-01-01T00:00:00.000Z`, `2000-02-29T12:00:00.500Z`, `2024-02-29T23:59:59.999Z`, `2026-09-09T00:00:00.001Z`, `2099-12-31T23:59:59Z`, `1969-12-31T23:59:59Z` (negative interval), `2026-03-01T00:00:00Z` after a non-leap February.
  - Refusals (nil): `2026-09-09T12:00:00+01:00`, `2026-09-09T12:00:00.123+00:00`, `2026-09-09 12:00:00Z`, `2026-09-09T12:00:00`, `2026-13-01T00:00:00Z`, `2026-02-30T00:00:00Z`, `2026-09-09T24:00:00Z`, `2026-09-09T12:60:00Z`, `1757000000` (epoch), `2026-09-09T12:00:00z`, empty.
  - Property over 10,000 random dates in 1970–2100: `ISO8601Fast.date(formatter.string(from: d))` within `1e-3` of `d` (the formatter rounds to milliseconds).
- [ ] **Step 2: Write the failing round-trip test** for the strategy (`JSONLDateCodingTests`): encode `[Date]` fixtures with `JSONLAppendStore<Op>.dateEncoding`, decode with `dateDecoding`, re-encode — **the bytes are identical** for: a fractional date, a whole-second date (build the whole-second STRING by hand and decode it — the encoder never writes one), and an epoch string `"1757000000.5"` (decodes to `Date(timeIntervalSince1970: 1757000000.5)`). Also decode a hand-written `"2026-09-09T12:00:00+02:00"` and assert it equals the formatter's answer (the fallback path still works).
- [ ] **Step 3: Run** the two new suites — fail (`ISO8601Fast` undefined).
- [ ] **Step 4: Implement `ISO8601Fast`**: parse fixed positions (digits at 0–3, `-`, 5–6, `-`, 8–9, `T`, 11–12, `:`, 14–15, `:`, 17–18, then either `Z` at 19 and end, or `.` at 19, 1–9 digits, `Z`, end). Validate ranges including day-of-month against a leap-aware table. Compute days since 1970-01-01 with days-from-civil, then `Date(timeIntervalSince1970: Double(days * 86400 + h*3600 + m*60 + s) + fraction)`, where `fraction` is the digits over `10^count`.
- [ ] **Step 5: Wire the fast path** into `dateDecoding`: after `c.decode(String.self)`, `if let d = ISO8601Fast.date(utf8: s.utf8) { return d }` before the existing formatter lines. Leave the formatter fallbacks and the epoch fallback exactly as they are. Update the comment above `iso8601Formatter` ("not on the hot path" is false since the op log runs through it; say the fast path takes the hot shapes and the formatter is the fallback).
- [ ] **Step 6: Run** the package tests, `./scripts/test.sh`, `./scripts/test.sh phone` — green.
- [ ] **Step 7: Measure**: the fixture's **control** row (parse-only) three runs on a quiet machine, against Task 0's. Report both. Expected: roughly half. If the gain is under 20 %, stop and report before committing — the spike's 1,736 → 650 ms claim was on a different fixture and the number is the deliverable.
- [ ] **Step 8: Commit** `perf(oplog): a hand parser for the two ISO 8601 shapes the op log writes; the formatter is the fallback`.

---

### Task 3: `__project__` rotates

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift:801` (delete the guard), `:643–650` and `:755–762` (doc comments)
- Modify: `Maugham/Stores/DocumentStore.swift:185–230` (the open sweep adds the project stream)
- Modify: `Maugham/Stores/ProjectStore.swift:280–291` (the `_projectOpLogStore` comment), `Maugham/Stores/ProjectStore+Tasks.swift:297–310` (the loader comment: it now reads segments plus tail, which `loadSyncMerged` already does)
- Test: `MaughamTests/Stores/ProjectStreamSealTests.swift` (rewrite `test_sealChainDoesNotRefuseTheProjectStreamAndSealTailStillDoes`), `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogStoreSegmentTests.swift`

**Interfaces:**
- Consumes: `OpLogStore.sealTailIfNeeded(docId:deviceSlug:threshold:) async throws -> URL?`, `OpLogStore.sealChain(docId:actor:)`, `OpLogStore.loadSyncMerged(forDocId:in:identities:state:)`, `ProjectStore.projectTasksDocId` (`"__project__"`), `OpLogStore.docIds(inOpsDirectoryFilenames:)` (excludes `__project__` — unchanged), `Document.segmentSealThresholdForTesting`.
- Produces: nothing new; a behaviour change.

- [ ] **Step 1: Rewrite the pinning test** in `ProjectStreamSealTests`: rename to `test_theProjectStreamRotatesLikeEveryOtherTail`. Append project task ops through `ProjectStore.appendProjectTaskOp` until the author's `__project__` tail exceeds a small `threshold:` (pass 2 KB explicitly), then call `sealTailIfNeeded(docId: ProjectStore.projectTasksDocId, deviceSlug: <author slug>, threshold: 2048)` and assert: a `__project__.<slug>.seg0001.mzseg` exists, the tail is gone, and `OpLogStore.loadSyncMerged(forDocId: "__project__", …)` answers every op appended (count and opIds). Then append one more op and assert the tail is recreated and `loadSyncMerged` answers N+1.
- [ ] **Step 2: Write the sweep test** in the same file: with a project whose `__project__` author tail is already over `Document.segmentSealThresholdForTesting` (set it to 2048 for the test, restore in `tearDown`), `DocumentStore.open` on that project rotates it (a segment exists afterwards) and `ProjectStore.projectTasksOpLog()` on the reopened store answers every op. Look at `test_theIntervalSealsTheProjectStream` for how this file builds a project and a store; reuse its fixture helpers.
- [ ] **Step 3: Add to `OpLogStoreSegmentTests`**: `test_docIdFromFilename_stillExcludesProjectSegments` — `docId(fromOpLogFilename: "__project__.author-abc.seg0001.mzseg")` is nil (the manuscript-id reader keeps excluding the stream; line 56 already pins the `.jsonl` twin — extend, do not duplicate).
- [ ] **Step 4: Run** — Step 1's test fails (`sealTailIfNeeded` answers nil), Step 2's fails (no segment), Step 3 passes.
- [ ] **Step 5: Implement:**
  - Delete the `guard docId != "__project__" else { return nil }` at `OpLogStore.swift:801`.
  - In `DocumentStore.open`'s sweep, iterate `OpLogStore.docIds(inOpsDirectoryFilenames: opsDirNames).sorted() + [ProjectStore.projectTasksDocId]` — the project stream last, same body (author seal first, then every local actor's rotation). Add a comment: the manuscript-id reader excludes the stream by contract, so it is named here explicitly.
  - Doc comments: `OpLogStore.swift:643–650` ("`__project__` is sealed here and rotated nowhere" → sealed here and rotated by the open sweep, since 2026-09-09); `:755–762` (delete "never `__project__`" from the scope rules; the scope rule is still "only this device's own actors' tails"); `ProjectStore.swift:286–289` (drop "because segment rotation refuses it too … a recorded Denver decision"); `ProjectStore+Tasks.swift:300–302` ("The project log is tiny" → bounded at `segmentSealThreshold` per tail by the open sweep; the read is segments plus tail).
- [ ] **Step 6: Run** the package tests, `./scripts/test.sh`, `./scripts/test.sh phone` — green. The Mac gate is where `ProjectStreamSealTests` lives.
- [ ] **Step 7: Commit** `feat(oplog): the project stream rotates at the same 512 KB as every other tail, at the open sweep`.

---

### Task 4: The "after" table and the prose

**Files:**
- Modify: `docs/superpowers/notes/2026-09-09-perf-step-measurements.md` (`## After`)
- Modify: `docs/adr/0032-the-signed-op-log.md` §5 (or wherever the "measured under load" caveat sits — grep `load average` and `not met`), the Consequences section's cost line
- Modify: `Maugham/OpLog/AREA.md:463–478` ("Where the time goes")
- Modify: `docs/superpowers/notes/2026-09-07-signed-op-log-p1-handoff.md` "Decisions owed" #1, #3, #4, #5 — each gets a `**Decided 2026-09-09:**` line
- Modify: `docs/superpowers/notes/2026-09-08-signed-op-log-performance-handoff.md` — a `## Outcome` section at the foot
- Modify: `docs/roadmap.md` if the signed-op-log entry lists the performance step; `CLAUDE.md`'s `Maugham/OpLog/` row only if it states something now false (grep `__project__` and `rotated nowhere` in it — the row currently says nothing about the project stream, so likely no edit)

- [ ] **Step 1: Quiet machine, three fixture runs**, recorded under `## After` in the measurements note, same columns as Task 0.
- [ ] **Step 2: ADR 0032**: replace the under-load caveat with the quiet-machine table (before and after), state the budget in decision 1's two figures, and record that it holds (or does not — write what was measured). Add a line to §3 that the device state records roots and prunes, and one to §4/§5 that the project stream rotates.
- [ ] **Step 3: AREA.md "Where the time goes"**: rewrite the paragraph to the measured after-numbers; keep the two must-not-undo items (`Hex`, the counting branch) and add two more: the `prev` fast path and the date fast path, each with the shape that must not come back. Add the persist-before-write reason item 5's coalescing was refused.
- [ ] **Step 4: The handoffs**: decisions #1, #3, #4, #5 answered in the P1 handoff; the performance handoff gets its outcome (five items: what shipped, what was refused and why, the numbers).
- [ ] **Step 5: Commit** `docs(oplog): the performance step's after table; the budget restated and answered; decisions 1, 3, 4, 5 closed`.

---

## Whole-branch review

One review of the full branch diff plus this plan's ledger (the two decisions, the four corrections). Name the seams for the reviewer: the persist-before-write rule versus any persist that moved; `mergeSortedDedup`'s canonical encoding and any re-encoding path versus the date change (encoding must be byte-identical); the open sweep's ordering (seal, then rotate, project stream last); `docId(fromOpLogFilename:)`'s exclusion of `__project__` surviving; `prev(ofLine:)`'s fallback covering every shape the slow path covered. Then `./scripts/test.sh full`, merge to local `main`, unpushed.
