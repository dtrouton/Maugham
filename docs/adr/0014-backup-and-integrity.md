# 0014 — Backup & integrity: filesystem-only, integrity-gated, restore-beside

**Status:** Accepted
**Date:** 2026-06-07

## Context

Everything that protected a manuscript lived *inside* the project folder, under iCloud — the op log (source of truth), checkpoints, trash, conflict backups are all derived views over the op log and share its fate. iCloud can silently drop the loser of concurrent JSONL appends (tripwire 17), and a corrupted op-log line was *silently* skipped (`JSONLAppendStore` decoded with `try? … else continue`). So recovery was excellent against in-app damage (rewind/trash/checkpoint) and weak against loss or corruption of the iCloud copy itself.

The Backup & Integrity milestone (shipped **v0.8.0**) closes that gap. Several decisions are load-bearing and recur in every future backup/integrity change.

Full design: `docs/superpowers/specs/2026-06-07-backup-and-integrity-design.md`; plans under `docs/superpowers/plans/2026-06-07-*`.

## Decision

1. **Filesystem-only — no cloud APIs.** A backup destination is a security-scoped *folder* (local, external drive, or a Drive/Dropbox/OneDrive-synced folder); Maugham writes files and nothing more. Getting bytes off-machine is delegated to whatever syncs that folder. This upholds "plain files on disk, full stop," avoids a per-provider OAuth/Keychain/SDK rabbit hole, and gives vendor diversity (a second, differently-timed reconciler) for free. The cost — Maugham can't verify the *remote* — is mitigated by verifying the local write and showing per-destination status.

2. **Not git.** The op log already *is* the version history (append-only, semantic, with a rewind UI); git would be a third history layer. Git also wrecks on the binary content (research images, exports → LFS), collides with the per-device-JSONL sync model (a second merge reconciler over the same files), and breaks "plain files / the user does not write code." A backup *generation* is a clone, not a commit. The one thing worth stealing — content-addressed integrity — is taken via per-generation Merkle manifests, without git.

3. **Backup is the recovery arm of an integrity primitive; integrity is checked *before* every backup.** `ProjectIntegrity.check` surfaces the previously-silent op-log parse-skip (and quarantines the raw lines), plus conflict-twin, dangling-checkpoint-pointer, and semantic garbage-paragraph-id checks. A project that fails the check is **refused** — corruption must never propagate into a destination ("a mirror that copies corruption isn't a backup"). The semantic id check is deliberately conservative (empty/whitespace/control/markup only, *not* the strict 4-char alphabet) because the in-memory id APIs are permissive (tripwire 8) and a stricter rule would false-positive and block all backups.

4. **Skip-unchanged uses a content *signature*, not a whole-tree hash.** The very act that triggers a backup — `CheckpointCapture` on ⌘S — mutates the source every time (a `.checkpoint` breadcrumb op + a `checkpoints.jsonl` entry), so a naive whole-tree hash always differs and every idle save would churn retention. `BackupSignature` hashes manuscript-relevant content while filtering `.checkpoint` ops and excluding volatile bookkeeping. Idle saves correctly skip.

5. **Per-project keying by minted `ProjectManifest.id`.** Generations live at `<destination>/<manifest.id>/<gen>/` so several projects can share one backup folder without intermixing; retention and skip-detection are per-project. Keyed by the stable minted id (folder-name fallback), so renaming/moving a project doesn't orphan its history.

6. **Restore-beside, never overwrite.** Restore copies a verified generation into a *new* folder the user picks — never into the live project. A restore can't destroy current state. Generations are immutable once written; auto-bisect surfaces the newest *intact* one.

7. **Manifest-shadow.** `project.maugham.json` is a single, critical, un-regenerable file; it is mirrored to a checksummed shadow under `.maugham/` on every save, and `ProjectStore.load` self-heals a corrupt manifest from the verified shadow.

## Consequences

- New MaughamCore: `ParseDiagnostics`/`IntegrityQuarantine`/`MerkleManifest`/`IntegrityChecks`/`ProjectIntegrity` (detection), `BackupWriter`/`BackupRunner`/`BackupRestore`/`BackupSignature` (backup+restore), `ManifestShadow`. All pure Foundation + CryptoKit (the package is no longer literally "Foundation-only" — Apple-system-frameworks-only, no third-party deps).
- Mac: a Backups Settings tab, `BackupCoordinator` (results keyed **per project** — a single app-wide object surfacing one shared result lit every window's banner), backup on checkpoint, a "backups paused" banner, and `RestoreWindow`.
- Backup is **Mac-only** for v1; the phone relies on the Mac + iCloud.
- **Encryption is the destination's job** (encrypted disk / provider at-rest) — deliberately not built.
- Complements, does not replace, Time Machine: Maugham's value-add is *semantic* (op-log-aware, integrity-verified, single-generation restore, cloud-folder-portable).
- Deferred follow-ons captured in the roadmap: single-document restore (op-log surgery), derive-and-compare, essential/full remote classification.
- Lesson recorded in CLAUDE.md: a heavy SwiftUI `body` can fail the **Release** type-check while Debug passes — the backup banner additions shipped a Release-only build break to CI on the v0.8.0 tag; SwiftUI body changes now warrant a local `-configuration Release` build before tagging.
