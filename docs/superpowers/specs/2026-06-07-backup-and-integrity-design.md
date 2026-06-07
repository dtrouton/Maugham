# Backup & Integrity — Design

- **Date:** 2026-06-07
- **Status:** Design approved; pre-implementation
- **Supersedes/extends:** Group 4 "Backup & recovery story" roadmap item; relates to the
  collaborator-layer milestone (Group 2) and the deferred op-log-compaction work.

## 1. Motivation

Everything that protects a Maugham manuscript currently lives **inside the project folder,
under iCloud**: the op log (source of truth), checkpoints (pointers into it), trash, conflict
backups. They are all derived views over the op log and share its fate. If iCloud corrupts,
loses, or mis-resolves the folder — and tripwire 17 documents that iCloud *does* silently drop
the loser of concurrent JSONL appends as a conflict-twin — the manuscript and all of its
recovery scaffolding go down together.

Two concrete gaps:

1. **No independent copy.** Recovery today is excellent against in-app / self-inflicted damage
   (History Rewind, Trash, checkpoints) and weak against loss of the iCloud copy itself. Every
   safety net is fate-shared with the thing it protects.
2. **Corruption is silent.** `JSONLAppendStore.parseAndPostProcess` decodes each line with
   `try? dec.decode(...) else { continue }` — torn-trailing-line tolerant (good), but a mid-log
   mangle silently drops an op. Because ops are LWW-by-paragraph edits, a dropped op means a
   paragraph quietly loses an edit or reverts, with **zero signal** to the writer.

This milestone builds an **integrity primitive** (detect corruption in the source-of-truth
files and surface it) and a **backup system** (independent, generational, off-iCloud copies).
Backup is the *recovery arm* of the integrity primitive; integrity is its *alarm*.

## 2. Non-goals

- **Not a sync system.** Backup is one-way write + restore-on-demand. Cross-device sync remains
  the op-log / per-device-JSONL job (ADR 0012).
- **Not a cloud-API integration.** Filesystem-only. Off-machine delivery is delegated to whatever
  syncs the chosen folder (Drive, Dropbox, OneDrive, NAS, external SSD). No OAuth, no Keychain
  secrets, no per-provider code. This upholds "plain files on disk, full stop."
- **Not a Time Machine replacement.** Complementary: Time Machine is the OS-level file safety net;
  Maugham backup is *semantic* — op-log-aware, integrity-verified, single-paragraph restore,
  cloud-folder-portable, self-verifying. The two are belt-and-suspenders, not redundant.
- **Encryption deferred.** Handled externally (provider at-rest encryption / encrypted disk).

## 3. Source-of-truth classification

The integrity primitive and the "essential" backup tier both turn on this distinction:

| Category | Examples | Regenerable? | Integrity-checked? | In "essential" backup? |
|---|---|---|---|---|
| **Truth** | op log (`.maugham/ops/`), `project.maugham.json` | no | **yes** | yes |
| **Primary content** | `research/` files & images, un-promoted `.maugham/inbox/` audio/text, publish templates/config, `.maugham/trash/` | no | manifest-hash only | yes |
| **Derived** | manuscript `.md`/`.fountain`, `Exports/`, publish build artifacts | **yes** (from op log / re-compile) | no | **no** (local-full only) |

**Key consequence:** the only large-feeling thing that is actually *derived* is the manuscript
`.md` (and it is small text); the bytes that dominate a project (research images, inbox audio)
are **primary content that can never be skipped**. So a "truth-only" backup saves little and is
dangerous. The real distinction is: *always back up the irreplaceable; the regenerable derived
artifacts are the only thing optional.* On restore the `.md` is **always re-derived** from the op
log (source-of-truth invariant) — a backed-up `.md` is never trusted on the way back.

## 4. Integrity primitive

Applies **only** to Truth + Primary files. Never to derived files (checking regenerable output is
noise).

1. **Surface the silent skip + quarantine.** `parseAndPostProcess` returns a result that includes
   the loaded elements *and* a list of skipped lines (raw bytes + byte offset). Loaders surface
   "this doc's op log has N unreadable entries." Raw bad lines are **quarantined** to
   `.maugham/conflicts/quarantine/` (not dropped) for forensic recovery. *Lives in MaughamCore →
   shared by Mac + phone (correct single source).*
2. **Merkle manifest.** Hash each Truth/Primary file; combine into a tree with one **root hash**.
   One root comparison verifies the whole project; a mismatch localizes the corrupt file in
   O(log n). Used for live "Verify project" and as each backup generation's manifest.
3. **Manifest shadow.** Keep a verified shadow of `project.maugham.json` + its checksum, so a
   mangled manifest (→ "can't open project / lost minted `ProjectManifest.id`") is detectable and
   recoverable without a full restore.
4. **Checkpoint-pointer validation.** After load, verify every `Checkpoint.docPointers` op-id
   resolves to a real op. A dangling pointer independently corroborates op-log loss.
5. **Set-integrity.** Track the expected set of per-device op-log files; warn on a missing sibling
   or a conflict-twin (`d_x 2.jsonl`) — integrity of the *set*, complementing per-file hashing.
6. **Derive-and-compare.** Check `on-disk .md == derive(opLog)`. Divergence means an external edit
   (→ Reconciler) **or** corruption — reuses Reconciler machinery, adds a corruption lens.
7. **"Verify project" action + passive health indicator.** On-demand fsck-style check, plus a
   glanceable health state derived from 1–6.

## 5. Backup system

### 5.1 Destinations
- A **global, app-level list** of 1..N security-scoped folder bookmarks (same mechanism as the
  iPhone projects-root). Bookmarks are inherently machine-local, so they live in app prefs.
- Each destination records: path, **kind** (auto-detected: *same-APFS-volume → clone-capable* vs
  *other → real-copy*), retention count, and per-destination status/health.
- **Safe by default:** every project is backed up to the global destinations automatically. New
  projects are protected from their first checkpoint — there is no "forgot to enable backups."

### 5.2 Keying
- Generations land at `<destination>/<manifest.id>/<generation-id>/`.
- Keyed by the **minted `ProjectManifest.id`**, not the folder path, so renaming/moving the
  project folder neither orphans its history nor silently starts a new one.
- `generation-id` = **ULID** (monotonic — avoids the clock-skew "newest" bug, tripwire 17 lesson)
  carrying a human wall-clock label.

### 5.3 Scope by destination type (full vs essential — automatic)
- **Local clone-capable → Full.** Everything incl. exports/builds; CoW-cheap, so no reason to trim.
- **Remote/external copy → Essential.** Skip regenerable derived (exports, build artifacts,
  derived `.md`); keep all Truth + Primary content.
- **Advanced escape hatch:** a per-remote "**trim research images**" toggle (→ manuscript-truth)
  for bandwidth-constrained users who deliberately keep images local-only. Off by default, warned
  ("research images will not live at this destination").

### 5.4 Trigger & throttle
- Fires on **checkpoint** (⌘S / auto-checkpoint), riding `CheckpointCapture`'s force-flush so the
  source op logs are quiescent.
- **Throttle:** skip if all op-log heads are unchanged since the last generation; enforce a minimum
  interval so rapid ⌘S can't thrash.
- All copy/verify work runs **off the main actor**; large first backups show **progress + cancel**.

### 5.5 Generation write
- Write to a hidden `.partial-<id>/`, then **atomically rename** into place — a cloud client never
  starts uploading a torn copy, and a restore never reads a half-written generation.
- **Source reads are `NSFileCoordinator`-coordinated** (consistent snapshot; checkpoint flush has
  already run).
- **Clone-capable:** APFS `clonefile` → unchanged files (research images) cost zero extra disk.
  **Copy:** incremental — skip files unchanged since the previous generation (spare upload
  bandwidth).
- Each generation carries its **Merkle manifest**; the write is verified against the source.

### 5.6 Retention — deep-local / shallow-remote
- Per-destination retention count.
- **Generations and destinations protect orthogonal failures:** generations guard against
  *source corruption over time*; destinations guard against *media/machine loss*. Extra
  destinations do not reduce the need for generations (all destinations inherit the same
  same-moment source). So: deep generational history where it is cheap, broad media redundancy
  where it matters.
- Defaults: local ~10+ (cheap clones); remote/external 1–2 (real bytes). Pruning removes oldest
  beyond the count — a *local* delete; how a cloud client interprets that deletion is documented,
  not controlled.
- **Generations are immutable once written** (ransomware / propagated-deletion defense). Cloud
  providers' own version history is the deep backstop.

### 5.7 Test-restore verification (anti "Schrödinger's backup")
- After writing the newest generation, **dry-run restore it to a temp dir, re-derive the op log,
  and compare the word count to `Checkpoint.manuscriptWordCount`.** Success →
  "verified-restorable as of HH:MM." A backup that exists but can't restore is worthless; this
  makes restorability a *checked* property, not a hope.

### 5.8 Status & visibility (kills the silent-failure downside)
- Per-destination glanceable status: `Local ✓ 14:32 · 11 gens · 0.9 GB` /
  `Dropbox ⚠ last ok 2 days ago`.
- Warnings: no success in N days; destination looks eviction-prone (online-only placeholders);
  a note that **a backup reflects this device's currently-synced view**, which under iCloud lag may
  trail another device's recent ops.

### 5.9 Config storage
- **Global destinations** (bookmarks) → app prefs (machine-local by nature).
- **Per-project policy** (opt-out flag, advanced image-trim) → in the project
  (`.maugham/backup-policy.json`) so intent travels with the project and is itself backed up.

## 6. Restore

- **Entry:** "Restore from backup…" lists generations **across all destinations**, merged
  newest-first, each tagged with its source destination and an **integrity badge** (✓/⚠ from
  Merkle verify).
- **Whole-project restore → restore-beside.** Always into a *new* folder; **never overwrite the
  live project in place.** The user then switches to the restored copy. A restore can never
  destroy current state. *(Safety-critical invariant.)*
- **Single-document restore.** Pull the doc's op-log slice back into the live project as **new
  ops** (itself rewindable) — never a silent file overwrite. The `.md` is re-derived.
- **Auto-bisect-to-good.** On detected corruption, binary-search generations to surface the
  *newest non-corrupt* generation, instead of making the user guess.
- Restore **always re-derives** `.md`/`.fountain` from the op log — proving the op log is intact
  in the act of restoring (the truth-only self-verification property).

## 7. Cross-surface considerations

- The `JSONLAppendStore` parse-result change is in **MaughamCore** → shared by Mac + phone, the
  correct single source (don't add a target-local copy — tripwire 19).
- **Backup itself is Mac-only for v1.** The phone is a capture/read/review surface; the Mac (plus
  iCloud) owns durability. Integrity *surfacing* on the phone can follow later.

## 8. Forward items (cross-roadmap — capture now, build later)

- **Op-log compaction (Automerge/CRDT-style)** → Group 4 perf. Snapshot derived state + truncate
  ancient ops into a compacted base, keeping recent ops for rewind. Smaller backups + faster
  derive; deep rewind beyond the horizon is preserved *in pre-compaction backup generations* — a
  direct interplay with this milestone.
- **Patch commutation / real merge (Darcs, Pijul)** → collaborator layer. Replaces crude
  LWW-by-paragraph with clean reorder/merge for multi-author.
- **Signed generations & checkpoints (signed tags)** → collaborator attribution + integrity
  provenance ("authentically produced by Maugham on this Mac, untampered").
- **Blame / annotate view (git blame, hg annotate)** → collaborator layer; the op log already
  holds per-op device/session/at.

## 9. Testing

- **Unit:** `parseAndPostProcess` returns the skip-list + offsets; Merkle build/verify + corruption
  localization; checkpoint-pointer validation; set-integrity (missing sibling / conflict-twin);
  derive-and-compare; retention pruning; ULID generation-id ordering under simulated clock skew.
- **Integration:** corrupt a mid-log line → health surfaces it + line quarantined; backup →
  restore-beside round-trip; test-restore word-count oracle; a `.partial-` generation is never
  visible to a reader; multi-destination independence (one destination fails → others still
  succeed, each with its own status).
- Tests crossing the `.md ↔ op log` boundary use 4-char alphabet-restricted paragraph IDs
  (tripwire 8).

## 10. Decisions (resolved 2026-06-07) + remaining open questions

**Decided:**
- **Retention defaults:** local destinations keep **10** generations (cheap APFS clones), remote/external keep **2** (real bytes). Per-destination, overridable.
- **Configuration home:** a new **"Backups" tab in the Settings window** (alongside General / Voice transcription) — add/remove destination folders (security-scoped bookmarks), set per-destination retention, and view last-backup status.
- **Integrity-check timing:** run `ProjectIntegrity.check` **on project open (background)** AND **before each backup** — a corrupt source is caught and surfaced before it can be propagated to any destination (consistent with "a mirror that copies corruption isn't a backup"). A manual "Verify project" command also exists.

**Still open (later UI plan):**
- Health-indicator *placement* for the on-open result (status footer vs a badge vs a banner) — the Backups Settings tab owns destination status; the open-time integrity result needs a home.
- Whether the per-project opt-out needs its own UI surface or is config/MCP-only for v1.
