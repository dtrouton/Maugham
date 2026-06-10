# Op-log growth — M0 baseline (2026-06-09)

Recorded from a real run of `OpLogGrowthBaselineTests` (env-gated harness,
growth spec §3) against the `OpLogGrowthFixture` corpus generated through the
production `Document` API. This baseline gates M1+ per ADR 0016.

**Machine:** Apple M4, macOS 26.5, Xcode 26.5. Fixture seed 42 (deterministic
content; timings are machine-relative, byte counts are not).

Run command:

```
TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1 xcodebuild -project Maugham.xcodeproj \
  -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamTests/OpLogGrowthBaselineTests
```

## Baseline tables

Verbatim harness output (novel ran in 26.7 s, screenplay in 5.6 s):

```
===== M0 BASELINE — novel =====
docs: 30, bursts: 7200, ops: 7230
total op-log bytes on disk:      18426662
encoded op bytes (canonical):    18419432
sequence-attributable bytes:     8545860 (46.4% of encoded)
tail bytes rewritten (sync churn proxy): 2285546611
Document.load (largest doc, min of 3):   0.04324475 seconds
Deriver.derive (full log, min of 5):     0.000225042 seconds
compression probe (largest tail):
  LZFSE: 645382 → 22369 B (28.9×) in 0.001748125 seconds
  LZMA : 645382 → 17324 B (37.3×) in 0.021266791 seconds
=======================================
```

```
===== M0 BASELINE — screenplay =====
docs: 1, bursts: 240, ops: 241
total op-log bytes on disk:      5521869
encoded op bytes (canonical):    5521628
sequence-attributable bytes:     5064133 (91.7% of encoded)
tail bytes rewritten (sync churn proxy): 701596500
Document.load (largest doc, min of 3):   0.208313917 seconds
Deriver.derive (full log, min of 5):     0.00070625 seconds
compression probe (largest tail):
  LZFSE: 5521869 → 59936 B (92.1×) in 0.013013292 seconds
  LZMA : 5521869 → 39084 B (141.3×) in 0.190715875 seconds
=======================================
```

Headline reads:

- ADR 0016's diagnosis is confirmed by measurement: `sequence` redundancy is
  46.4% of all encoded op bytes for the novel and **91.7%** for the
  single-file screenplay (~3,000 paragraph ids re-serialized on every burst).
- Sync churn is the worst cost: the novel fixture re-uploaded **2.29 GB** of
  tail bytes to produce 18.4 MB of log (124× write amplification); the
  screenplay re-uploaded 702 MB for 5.5 MB (127×). This is the M2 motivation
  in one number.
- `Deriver.derive` is trivially fast (≤ 0.7 ms at full log) — load time is
  dominated by JSONL decode + bootstrap/anchor work, not derivation.

## Budgets (confirmed/adjusted)

- **`sequence` share of new-write bytes < 5% after M1 — confirmed, with a
  fixture caveat.** The baseline shows sequence is the dominant redundancy
  (46.4% / 91.7%), so keyframing attacks the right bytes. Caveat: the fixture
  forces an ordering change every 7th burst (deliberately aggressive), so
  bursts that legitimately carry `sequence` under the M1 emission rule
  (orderingDirty + first-burst-after-load + floor) are ~16% of fixture bursts
  — the fixture-measured post-M1 share may land slightly above 5%
  (≈ 6–8% novel). If M1's measurement exceeds 5% *on this fixture*, verify the
  excess is attributable to those legitimate emissions before tuning; the <5%
  budget stands for typical drafting (ordering changes far rarer than 1-in-7
  bursts).
- **Heavy drafting month per doc < ~1 MB after M2 — confirmed.** Pre-M1 the
  novel fixture (a month-scale history) costs ~614 KB/doc (18.4 MB / 30) and
  the screenplay 5.5 MB for its one doc. M1 removes 46%/92% of those bytes
  (→ ~330 KB and ~460 KB per fixture-month), and M2 seals at 29–92×
  compression — comfortably under 1 MB even for the screenplay.
- **`Document.load` at fixture scale < 150 ms after M3 — kept; gate
  re-measured post-M2.** Novel is already 43 ms (under budget). **Screenplay
  is 208 ms today, pre-M1 — already over the 150 ms line.** Since derive is
  0.7 ms, load is dominated by decoding 5.5 MB of JSONL; M1 (-92% bytes) and
  M2 (compressed segments) shrink exactly that input, so the M3 ship/no-ship
  gate is re-measured after M2 lands, not against this pre-M1 number.

## Decisions (spec §9)

1. **Keyframe floor: 50 (default confirmed).** A 1-in-50 keyframe re-adds at
   most ~0.9% (novel: 46.4%/50) to ~1.8% (screenplay: 91.7%/50) of encoded
   bytes — well inside the 5% budget — while keeping ordering anchors dense
   enough that no recovery scan ever walks more than 50 bursts.
2. **Seal threshold: 512 KB (default confirmed).** The novel's busiest tail
   reached 645 KB over this month-scale fixture *pre-M1*; post-M1 tails shrink
   46–92%, so 512 KB ≈ several drafting-months per doc — seals stay rare
   (never mid-typing-frequency) and each segment is meaty enough to compress
   well (645 KB → 22 KB at this size).
3. **LZFSE default (algorithm byte = 1).** LZFSE achieves 28.9× / 92.1× in
   1.7–13 ms; LZMA's better ratio (37.3× / 141.3×) costs 12–15× the CPU
   (21–191 ms) to save only ~5–21 KB per segment in absolute terms. Sealing
   runs at Document.close/project-open — not worth the latency. The container
   carries the algorithm byte, so LZMA (= 2) stays a config flip, not a format
   change.
