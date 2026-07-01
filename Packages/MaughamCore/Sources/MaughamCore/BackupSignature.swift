import Foundation

/// A content signature that is **stable across pure-checkpoint saves**.
///
/// The backup runner uses this to decide whether anything worth backing up has
/// changed since the last generation. A naive whole-tree hash doesn't work,
/// because the very act that triggers a backup — `CheckpointCapture` on ⌘S —
/// rewrites volatile bookkeeping on *every* save: it appends a `.checkpoint`
/// breadcrumb op to the active doc's op log and adds an entry to
/// `checkpoints.jsonl`. So this signature deliberately ignores that churn:
///
/// - op-log files (`.maugham/ops/*.jsonl`) contribute only their **non-checkpoint
///   op ids** (the per-save breadcrumb is filtered out),
/// - the volatile sidecars are excluded entirely (`checkpoints.jsonl`, `sessions/`,
///   `ui-state/`, `scratch/`, `conflicts/`, and the backup sidecars themselves),
/// - every other file (manuscript `.md`/`.fountain`, `research/`, inbox, publish
///   config, …) contributes its content hash.
///
/// Two saves with no manuscript edit therefore produce the same signature.
public enum BackupSignature {
    /// Marker file a generation carries so the runner can read its signature back.
    public static let signatureName = ".maugham-backup-signature"

    /// `.maugham/` subtrees the checkpoint/autosave machinery rewrites per save.
    private static let excludedPrefixes = [
        ".maugham/checkpoints.jsonl",
        ".maugham/sessions/",
        ".maugham/ui-state/",
        ".maugham/scratch/",
        ".maugham/conflicts/",
    ]
    private static let excludedNames = [
        BackupWriter.manifestName,   // a backed-up generation's own manifest
        signatureName,               // ...and its signature marker
    ]

    public static func compute(projectURL: URL) -> String {
        let rels = ((try? BackupWriter.relativeFilePaths(under: projectURL)) ?? []).sorted()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding

        var lines: [String] = []
        for rel in rels {
            if excludedNames.contains((rel as NSString).lastPathComponent) { continue }
            if excludedPrefixes.contains(where: { rel == $0 || rel.hasPrefix($0) }) { continue }
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
