# Op-log growth — M2 status (2026-06-09)

Status of the ADR 0016 op-log growth plan after M1 + M2 land on branch
`oplog-growth`. Companion to the baseline note
(`2026-06-09-oplog-growth-m0-baseline.md`), whose "After M1" and "After M2"
sections carry the verbatim fixture tables and the full gate arithmetic. This
note is the milestone summary + the M3 go/no-go decision + the manual smoke
checklist.

## What shipped

### M1 — sequence keyframing (commit 431db93 → 4584fbd)

The full `sequence` array no longer rides on every burst. The M1 emission rule
attaches `sequence` only when ordering changed (`_orderingDirty`), on the
first burst after a load, and on an every-50 keyframe floor; otherwise
`sequence: nil` means "unchanged by construction" (a first-class meaning from
M1 on, not a legacy-only signal). The deriver carries the last explicit
sequence forward, so it needed no change. Tests T1–T7.

**ULID monotonicity bugfix found en route (commit 4584fbd):** carrying the
last sequence forward exposed that same-millisecond ops weren't deriving in
generation order — fixed so monotonic ULIDs break ties by generation order, a
correctness fix the M1 LWW path depends on.

### M2 — sealed compressed segments (commits 6013752..6343675)

- `6013752` — `OpLogSegment`: checksummed LZFSE/LZMA container for sealed op-log
  segments (T8).
- `f772411` — segment recognition + read path at the single-source helpers
  (`opLogFileURLs`, `docId(fromOpLogFilename:)`); phone reads segments for free
  (T9, T10 parity, T15).
- `5e2e892` — the seal procedure: threshold-gated tail rotation, torn-tail
  abort, crash-window convergence (T10, T13).
- `70facb2` — seal triggers at `Document.close()` + project-open maintenance;
  segment presenter routing; remote-seal no-op pinned (T11).
- `71e1965` — tampered segment quarantined + unhealthy + salvaged, end to end
  (T12).
- `6343675` — scope rules: legacy unsuffixed file never sealed, phone never
  seals (reads only) via shared helpers; `.mzseg` grep tripwires on both
  targets; docs (T14).

Seal threshold 512 KB, keyframe floor 50, LZFSE default (algorithm byte = 1) —
all confirmed against the M0 baseline, not re-litigated.

## Test counts (all green at HEAD 6343675)

| Scheme | Tests | Notes |
|---|---|---|
| MaughamCore (`swift test`) | **167**, 0 failures | T8–T13 segment container + store + integrity |
| Mac (`MaughamTests.xctest`) | **1664**, 2 skipped, 0 failures | seal triggers, segment integrity, fixture baseline |
| Phone (`MaughamPhone`) | **168**, 0 failures | phone-reads-segments + never-seals + `.mzseg` tripwire |

Both schemes were run for this milestone (CLAUDE.md: a MaughamCore change is
tested against BOTH). The two skips are the pre-existing inert cases, unrelated
to this work.

## Gates met (numbers from the After-M2 fixture re-run)

- **M2 exit — "fixture drafting-month < ~1 MB/doc": MET.** Novel
  **~364 KB/doc** (11,192,822 B / 30); screenplay **~216 KB** single doc (down
  from 1,235,048 B post-M1, −82%). Both well under ~1 MB.
- **M2 exit — "one-generation backup blip observed and documented": MET.**
  Documented in the baseline note's After-M2 §5.4 paragraph: `MerkleManifest` /
  `BackupSignature` hash files as files → a seal is a one-time file-set change
  → exactly one extra backup generation, then segments are immutable so
  skip-unchanged gets *more* stable.
- **M1 exit — "sequence share < 5% of new-write bytes": MET (fixture caveat).**
  Recorded in the After-M1 section; the fixture's deliberately-aggressive
  1-in-7 ordering churn keeps the fixture share at 11.7%/63% but the excess is
  100% legitimate keyframe emissions (op-count math is exact), and the <5%
  budget stands for typical drafting.
- **Sync churn (the M2 motivation): novel −38% / screenplay −90% M0→M2.** The
  single-file screenplay — the case ADR 0016 named — drops 90% of its
  write-amplification proxy; M2 alone cut the screenplay a further 63% past M1
  by retiring sealed bytes from the "rewritten on next append" set.

## M3 go/no-go verdict — **NO-GO (M3 does NOT ship)**

`Document.load` at fixture scale, measured post-M2 (the gate per spec §6/§8):

| Surface | Post-M2 load | 150 ms budget |
|---|---|---|
| Novel | **35.9 ms** | under (~0.24×) |
| Screenplay | **98.8 ms** | under (~0.66×) |

Both surfaces are under the 150 ms line. The screenplay — the only surface ever
over budget (208 ms pre-M1) — sits at 98.8 ms. **M1's byte reduction already
pulled the only over-budget surface back under the line (208 → 97 ms); M2 held
it flat.** Per spec §6 ("Ships only if the post-M2 load-time budget is
violated") the M3 derived-state cache is **not built**: plan Tasks 13–14 do NOT
run. Derive stays ≤ 0.7 ms throughout — load was JSONL-decode-bound and there
is no longer enough JSONL to justify a cache.

## Deferred / out-of-scope reminders

- **M3 is conditional and the condition was not met** → the
  `.maugham/cache/derived/` derived-state cache (and its `MaughamSidecarPath`
  class, the read-at-`Document.load` site, T16–T18) is **not implemented**. The
  smoke step "delete `.maugham/cache/`" from spec §8's M3 row is therefore **not
  applicable** — there is no cache dir to delete.
- **Live-tail framing holds.** Sealing is a storage-layout change to a
  single-writer per-device file; the logical append-only log is untouched. The
  legacy unsuffixed file and other devices' files are **never** sealed (T14) —
  per-device partitioning (tripwire 17) is what makes sealing safe.
- If real-world drafting ever pushes a single `Document.load` over 150 ms (e.g.
  a much larger single-file screenplay than the fixture's ~3000 paragraphs),
  the M3 cache is the pre-designed answer (spec §6) — revisit the gate then, not
  speculatively now.

## Manual smoke checklist (user-run, spec §8)

Screenplay-seal path (the M2-specific smoke):

1. Create a screenplay project; draft past the **512 KB** tail threshold (a
   long session of real typing across many scenes — enough op history that the
   tail rotates into a `.mzseg` on close).
2. ⌘Q.
3. Relaunch → open from Recents → **text intact**.
4. Open History Rewind → scrub the scrubber **back through sealed history**
   (the segment ops must be visible to rewind, not just the live tail).
5. **Restore from a point inside a sealed segment's range** → restored text
   matches that historical state.

Standard CLAUDE.md smoke (both surfaces):

6. New project → Novel → name it → type a sentence → ⌘Q → relaunch → open from
   Recents → **sentence intact**.

(No `.maugham/cache/` deletion step — M3 not built; see deferred reminders.)
