# OpLogChainCostTests baseline measurements

The performance fixture `test_fixture_fiftyThousandChainedLines` in `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogChainCostTests.swift` measures the cost of chain verification over a synthetic 50,000-line op log with 7 sealed segments plus a tail. The fixture runs each measurement best-of-three and prints the smallest time observed in each category. Machine state: Apple M4, running with load averages ranging from 2.6–3.3 over the three runs. Command: `MAUGHAM_PERF_FIXTURE=1 swift test -c release --package-path Packages/MaughamCore --filter OpLogChainCostTests`. Commit measured: 8e9aabf7.

## Before

| run | cold ms | warm ms | control ms | chain walk ms | signature checks ms |
|-----|---------|---------|------------|---------------|---------------------|
| 1   | 6012.8  | 6289.6  | 5855.9     | 48.9          | 1.7                 |
| 2   | 5974.7  | 5924.5  | 5877.0     | 49.5          | 1.8                 |
| 3   | 5934.2  | 5918.7  | 5832.0     | 48.9          | 1.7                 |
| min | 5934.2  | 5918.7  | 5832.0     | 48.9          | 1.7                 |

## After

Same fixture, same command, same machine (Apple M4), taken 2026-09-09 at commit
`4543b1a4` — the branch's last implementation commit (Tasks 1, 2 and 3 all in).
`ps ax | grep -c '[x]codebuild'` printed `0` before each of the three runs; the
one-minute load average read 2.61, 2.52 and 2.41 at the start of runs 1, 2 and 3
(full triples: `2.61 5.77 4.73`, `2.52 5.34 4.62`, `2.41 5.18 4.57`), against the
2.6–3.3 the `## Before` runs were taken under. Run 1 included the release build.

| run | cold ms | warm ms | control ms | chain walk ms | signature checks ms |
|-----|---------|---------|------------|---------------|---------------------|
| 1   | 518.8   | 512.4   | 429.1      | 34.4          | 0.9                 |
| 2   | 526.7   | 505.5   | 423.3      | 34.1          | 0.9                 |
| 3   | 514.6   | 503.1   | 421.5      | 33.9          | 0.8                 |
| min | 514.6   | 503.1   | 421.5      | 33.9          | 0.8                 |

## Delta

Before-min against after-min, per column.

| quantity | before ms | after ms | change | % |
|---|---|---|---|---|
| cold verified load (empty state) | 5934.2 | 514.6 | −5419.6 | −91.3% |
| warm verified load (state warm)  | 5918.7 | 503.1 | −5415.6 | −91.5% |
| control (parse only, no verify)  | 5832.0 | 421.5 | −5410.5 | −92.8% |
| chain walk over the live tail    | 48.9   | 33.9  | −15.0   | −30.7% |
| 7 sidecar reads + signature checks | 1.7  | 0.8   | −0.9    | −52.9% |

Two readings of that table:

- **The three end-to-end columns move together because the date parse moved**
  (Task 2, `ISO8601Fast`). The control decodes without verifying, so its −92.8%
  is the parse alone; cold and warm follow it down. Nothing on the chain's side
  of the work explains a change of that size, and the disable experiment in the
  Task 2 report confirms it: with the one wiring line commented out the control
  read 5817.6 ms again.
- **The chain walk's −30.7% is Task 1's `prev` fast path**, the only change on
  that path. The signature-check column is 0.9 ms of noise either side of a
  measurement under 2 ms; it is reported for completeness and no change on this
  branch touched signature verification.

### Against the budget (decision #1, 2026-09-09)

Decision #1 states the budget as the chain's own cost read directly by the
fixture, in two figures.

| figure | budget | measured | holds |
|---|---|---|---|
| walk over the fixture's 8×-oversized 6,250-line tail | under 100 ms | 33.9 ms | yes, measured |
| walk over a realistic tail (≤ 512 KB, ~600 lines) | under 20 ms | ≈ 3.4 ms | yes, **derived** |

The realistic figure is **derived, not measured**: the fixture only ever walks
its own 6,250-line tail, and a real tail is rotated into a segment past
`OpLogStore.segmentSealThreshold` (512 KB, some 600 lines) — about a tenth of
the fixture's — so the figure quoted is the measured walk divided by ten. It is
labelled that way wherever it appears.
