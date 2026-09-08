# OpLogChainCostTests baseline measurements

The performance fixture `test_fixture_fiftyThousandChainedLines` in `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogChainCostTests.swift` measures the cost of chain verification over a synthetic 50,000-line op log with 7 sealed segments plus a tail. The fixture runs each measurement best-of-three and prints the smallest time observed in each category. Machine state: Apple M4, running with load averages ranging from 2.6–3.3 over the three runs. Command: `MAUGHAM_PERF_FIXTURE=1 swift test -c release --package-path Packages/MaughamCore --filter OpLogChainCostTests`. Commit measured: 8e9aabf7.

## Before

| run | cold ms | warm ms | control ms | chain walk ms | signature checks ms |
|-----|---------|---------|------------|---------------|---------------------|
| 1   | 6012.8  | 6289.6  | 5855.9     | 48.9          | 1.7                 |
| 2   | 5974.7  | 5924.5  | 5877.0     | 49.5          | 1.8                 |
| 3   | 5934.2  | 5918.7  | 5832.0     | 48.9          | 1.7                 |
| min | 5934.2  | 5918.7  | 5832.0     | 48.9          | 1.7                 |
