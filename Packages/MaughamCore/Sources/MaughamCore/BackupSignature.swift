import Foundation

/// A content signature that is **stable across pure-checkpoint saves**.
///
/// The backup runner uses this to decide whether anything worth backing up has
/// changed since the last generation. A naive whole-tree hash doesn't work,
/// because the very act that triggers a backup — `CheckpointCapture` on ⌘S —
/// rewrites volatile bookkeeping on every save: it adds an entry to
/// `checkpoints.jsonl`, and — *when the window's subject is one of the
/// project's documents* — appends a `.checkpoint` breadcrumb op to that
/// document's op log. (The subject may be a group or the project row, and since
/// the persona shell's slice 1 the breadcrumb is skipped entirely for those; the
/// `checkpoints.jsonl` entry is written either way. Skipping it only removes
/// churn this signature was already filtering.) So this signature deliberately
/// ignores that churn:
///
/// - op-log files (`.maugham/ops/*.jsonl`) contribute only their **non-checkpoint
///   op ids** (the per-save breadcrumb is filtered out),
/// - the volatile sidecars are excluded entirely (`checkpoints.jsonl`,
///   `sessions.json`, `ui-state.json`, `scratch/`, `conflicts/`, and the backup
///   sidecars themselves),
/// - every other file (manuscript `.md`/`.fountain`, `research/`, inbox, publish
///   config, …) contributes its content hash.
///
/// Two saves with no manuscript edit therefore produce the same signature.
public enum BackupSignature {
    /// Marker file a generation carries so the runner can read its signature back.
    public static let signatureName = ".maugham-backup-signature"

    /// `.maugham/` files and subtrees the checkpoint/autosave machinery rewrites
    /// per save.
    ///
    /// **Both the file and the directory spelling are listed on purpose.** This
    /// list carried `sessions/` and `ui-state/` — directories that have never
    /// existed — while the real artifacts are `sessions.json` and
    /// `ui-state.json`. Neither matched `rel == $0` nor `rel.hasPrefix($0)`, so
    /// both contributed their full content hash and every UI-state change wrote
    /// a whole new backup generation. That was invisible for as long as
    /// `ui-state.json` only tracked selection and focus mode; the persona work
    /// (2026-07-25) put `persona` and `personaMemory` in it, so every ⌘1–⌘4
    /// press started minting a generation. Keep the directory forms so a future
    /// move to a subdirectory does not silently reopen this.
    ///
    /// **`checkpoints` is matched as a partitioned STREAM, not as one path**
    /// (see `excludedStems`). Once FM-1 gave the checkpoint log a device slug,
    /// an exact-path exclusion stopped matching the file that is actually
    /// written — which is the same failure the `sessions/` entry above records,
    /// one milestone later: every ⌘S would have hashed a fresh
    /// `checkpoints.<slug>.jsonl` and minted a whole backup generation.
    private static let excludedPrefixes = [
        ".maugham/sessions.json",
        ".maugham/sessions/",
        ".maugham/ui-state.json",
        ".maugham/ui-state/",
        ".maugham/scratch/",
        ".maugham/conflicts/",
    ]
    private static let excludedNames = [
        BackupWriter.manifestName,   // a backed-up generation's own manifest
        signatureName,               // ...and its signature marker
    ]

    /// Per-device-partitioned JSONL streams excluded whole: every
    /// `<stem>.<deviceSlug>.jsonl` as well as the legacy `<stem>.jsonl`.
    private static let excludedStems = [
        CheckpointStore.stemPath,
    ]

    public static func compute(projectURL: URL) -> String {
        let rels = ((try? BackupWriter.relativeFilePaths(under: projectURL)) ?? []).sorted()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding

        var lines: [String] = []
        for rel in rels {
            if excludedNames.contains((rel as NSString).lastPathComponent) { continue }
            if excludedPrefixes.contains(where: { rel == $0 || rel.hasPrefix($0) }) { continue }
            if excludedStems.contains(where: {
                PartitionedJSONLFile.matches(relativePath: rel, stemPath: $0)
            }) { continue }
            let fileURL = projectURL.appendingPathComponent(rel)

            if rel.hasPrefix(".maugham/ops/") {
                // Op log: contribute only the non-checkpoint op ids, so the per-save
                // `.checkpoint` breadcrumb doesn't perturb the signature.
                guard let data = try? Data(contentsOf: fileURL),  // adr-0018-ok: backup file bytes read for signature, not manuscript-as-truth
                      let text = String(data: data, encoding: .utf8) else { continue }
                var ids: [String] = []
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let d = String(line).data(using: .utf8),
                          let op = try? dec.decode(Op.self, from: d) else { continue }
                    if op.kind == .checkpoint { continue }
                    ids.append(op.opId)
                }
                lines.append("\(rel)\tops\t\(ids.sorted().joined(separator: ","))")
            } else {
                guard let data = try? Data(contentsOf: fileURL) else { continue }  // adr-0018-ok: backup file bytes read for signature, not manuscript-as-truth
                lines.append("\(rel)\t\(MerkleBuilder.sha256Hex(data))")
            }
        }
        return MerkleBuilder.sha256Hex(Data(lines.joined(separator: "\n").utf8))
    }
}
