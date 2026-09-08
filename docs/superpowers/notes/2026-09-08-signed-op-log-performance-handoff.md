# Signed op log — the performance step between P1b and P2 (handoff, 2026-09-08)

**Why this note exists.** Denver's ruling after the P1/P1b smoke: push and tag (Mac 0.37.0, phone 0.11.0), then run a *mini performance improvement step* before P2 is planned. This is that step's brief. Every number below is measured (task 5 of the P1 plan, its fix wave, and the P1b whole-branch review); nothing here is estimated unless it says so.

**Read first:** `docs/adr/0032-the-signed-op-log.md` §4–§5 and its actors addendum; `Maugham/OpLog/AREA.md` "Chained and sealed" (where verification time goes); the P1 handoff's Decisions owed (#1, #3, #4, #5) in `docs/superpowers/notes/2026-09-07-signed-op-log-p1-handoff.md`; the cost fixture `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogChainCostTests.swift` (env-gated, `MAUGHAM_PERF_FIXTURE=1`).

## What is already settled (do not redo)

| item | before | after | where |
|---|---|---|---|
| per-byte `String(format: "%02x")` hex in `lineHash` | 107 of 109 ms on 6,312 lines | 1.2 ms (`Hex`, table-driven) | `OpLogChain.swift` |
| settled-segment line count by `split` | one `Data` slice per line of a 5 MB segment | one `withUnsafeBytes` pass | `OpLogStore.nonEmptyLineCount` |
| clean-file rebuild before parse | reassembled line by line | original bytes handed through when nothing is quarantined | `OpLogStore.applied(_:whole:)` |
| seal fan-out at a burst boundary | four coordinated reads + verifies per burst (P1b) | one, counter-driven | `OpLogStore.sealChain` |
| close-time rotation | every actor's tail | the Document's own actor only; the open sweep rotates the rest by stat | `Document.close()`, `DocumentStore` |
| the verify cache | — | a segment whose digest is remembered is never walked | `OpLogDeviceState.verifiedSegments` |

## The measured picture on the 50k-line fixture (release, machine at load average ~4.5)

| what | ms |
|---|---|
| chain walk over the fixture's 6,250-line tail | 55–83 |
| seven sidecar reads + signature checks | 2–3 |
| `prev(ofLine:)` over 6,312 lines | ~11 |
| `decodeVerifying` × 7 segments (SHA-256 over ~35 MB) | ~22 |
| end-to-end cold open (parse-dominated, `JSONDecoder`) | ~6,000, spread larger than the chain's total |

A real tail rotates at 512 KB (~600 lines), so a real open walks about an eighth of the tail above: single-digit milliseconds. **The plan's stated budget (50k ops add < 100 ms to a cold open) was not met as an end-to-end subtraction and cannot be measured that way on this box** — it is inside the parse's noise. Decision #1 in the P1 handoff asks whether the reframe (the chain's own cost, ≤ 83 ms on an 8×-oversized tail) is the budget that stands.

## The step — five items, smallest plan that closes decisions #1, #3, #4 and #5

Each item is measure-first: the fixture prints its numbers; a change ships with a before/after pair from a quiet machine, or it does not ship.

1. **Re-run the cost fixture on a quiet machine and record it durably.** `MAUGHAM_PERF_FIXTURE=1 swift test -c release --package-path Packages/MaughamCore --filter OpLogChainCostTests`, nothing else running, three runs; paste the table into ADR 0032 §5 (replacing the "measured under load" caveat) and the AREA guide. Then restate the budget in the plan's own terms and record Denver's answer to decision #1. *(closes #1, #5)*

2. **The date strategy — the one change that moves the cold open.** The spike measured ~1.1 s of a 50k-line load as `JSONLAppendStore`'s custom `ISO8601DateFormatter` strategy (production 1,736 ms; built-in `.iso8601` 650 ms; date not decoded 267 ms). `dateDecoding` must keep accepting fractional-second, whole-second and epoch strings (checkpoints once wrote `secondsSince1970`); the built-in `.iso8601` accepts only whole seconds, so the shape is a fast path (try `.iso8601`-style parsing without allocating a formatter per line — e.g. a cached `ISO8601DateFormatter` per thread, or a hand parser for the two ISO shapes) with the existing fallbacks behind it. Pin round-trip equality for all three shapes and the `mergeSortedDedup` canonical encoding (it re-encodes; the ENCODING must not change a byte, or every remembered chain head is wrong). Measure on the fixture's parse-only control. Expected: the cold open roughly halves. *(the headroom the spike named)*

3. **`__project__` rotates.** `sealTailIfNeeded` refuses it today (`OpLogStore.swift`, the `guard docId != "__project__"` at the top) so its tail has no ceiling and each task toggle re-verifies all of it. Rotation of the project stream is the same single-writer rewrite as any other actor tail; the one reader that must keep working over segments + tail is `ProjectStore+Tasks`' synchronous `loadSyncMerged` (already segment-aware). Decide with Denver whether it rotates at the same 512 KB or a smaller threshold (it is small ops, many of them). *(closes #4)*

4. **`prev(ofLine:)`.** ~11 ms per 6,000 lines is now the largest per-line cost on the walk. It inspects the first key textually; a byte-level check for the literal `{"prev":"` prefix (64 hex + `"`) with no `String` construction should take it under 1 ms. Pin against the wire format (constraint 4 of the P1 plan) — the position is fixed by design.

5. **The state file.** `OpLogDeviceState` rewrites the whole `op-log-state.json` on every `remember` and never prunes projects that no longer exist. Bounded today; the cheap fix is to prune entries whose project root no longer exists at load, and to coalesce writes within a burst (one persist per `sealChain`, not per line). Measure the write count per burst before and after. *(closes #3)*

Not in this step: a segment-level index, an incremental verify cache for tails, the Merkle manifest's own hashing, or anything that changes the wire format. A change to the encoding side of the date strategy is a wire-format change and is out of bounds.

## Gates and shape

Two or three tasks, one plan, subagent-driven as usual; opus on the store/parse changes, haiku reviewers; every task green on the package, Mac and phone gates; the fixture's before/after numbers in each task's report and the whole-branch review's ledger. Merge to local `main` unpushed; Denver decides the release cadence.
