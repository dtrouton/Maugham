# Pre-registered predictions — backup retention vs auto-bisect

*Written 2026-08-01 **before** `BackupRetention.tla` existed or ran, committed in its own commit so the ordering is checkable in git.*

**Why this target.** Three of the four defects found so far live in the sync/derive family, where ADR 0012 had already done the hard thinking. This one is deliberately **off the op log** — it tests whether the method generalises or only worked on ground someone else had already prepared.

## What I established by reading

- `BackupWriter.prune(destination:keeping:)` — keeps the highest-sorting `keeping` ids, deletes the rest. **It never calls `verify`.** Corruption-blind by construction.
- `BackupRestore.newestIntact(across:)` — newest-first, first generation that verifies. So retention orders by **recency** and recovery orders by **intactness**. Two different orderings over one set.
- `BackupRunner.latestSignature(at:)` — reads the signature of `generationIds().last`, i.e. the newest **by id**, with no intactness check. If it equals the source signature, `run` returns `.skippedUnchanged` and **writes nothing**.
- The signature file is written *inside* the generation directory (`BackupRunner.swift:81–84`), so it shares the fate of the content it describes — but not necessarily: partial corruption can take the content and leave the marker.
- `BackupRestore.verify` maps an unreadable manifest to `["<unverifiable>"]`, i.e. **not intact** — a deliberately conservative choice.
- ADR 0014 §6: *"auto-bisect surfaces the newest intact one"*, and generations are immutable once written.

## Predictions

**P1 — expected VIOLATED.** `prune` deletes an intact generation while retaining a corrupt one. It sorts by id and never consults `verify`, so a corrupt newer generation outranks an intact older one. Near-certain; **this is confirmation, not discovery**, and is stated so it can be scored that way.

**P2 — expected VIOLATED, and the one I actually care about.** A corrupt **newest** generation whose signature marker survives will make every subsequent run return `.skippedUnchanged` for as long as the source is unchanged. The newest backup is corrupt, the system reports success, and nothing replaces it without a source edit. I am moderately confident but have not traced every path — if TLC shows this unreachable, that is a useful negative.

**P3 — expected to HOLD.** With retention `R`, if strictly fewer than `R` of the retained generations are corrupt, `newestIntact` is non-nil. Reasoning: prune keeps `R`, corruption takes `c < R` of them, so `R − c ≥ 1` intact remain. If TLC violates this, my model of how the two orderings interact is wrong and it is **discovery**.

**P4 — expected to HOLD.** A `run` that actually writes always leaves at least one intact generation (the one it just wrote). Violation would mean prune can delete the generation written in the same run.

## What would count as DISCOVERY

- P3 violated — fewer corruptions than retention still losing every intact copy
- P4 violated — a run destroying its own output
- any trace where `newestIntact` goes from non-nil to nil **without the environment corrupting anything** (i.e. our own pruning did it)
- a defect involving the signature-marker path that is not P2
- any state where `latestSignature` and `newestIntact` disagree in a way that compounds rather than cancels

## What would count as CONFIRMATION ONLY

P1 and P2 violated, P3 and P4 hold, nothing else. That is the fourth confirmation-only result for the method and, per the stopping rule, argues against (b) rather than for it.
