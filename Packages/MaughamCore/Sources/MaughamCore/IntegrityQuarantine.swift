import Foundation

/// Persists op-log lines that failed to decode (from `ParseDiagnostics`) into
/// `.maugham/conflicts/quarantine/` so they are never silently lost — a writer or
/// a future tool can inspect/recover them. Append-only, best-effort forensics;
/// not part of the logical op log.
public enum IntegrityQuarantine {
    /// Writes `skipped` for `docId` to
    /// `.maugham/conflicts/quarantine/<docId>.<contentHash>.<stamp>.jsonl`. Returns
    /// the file URL, or nil if there was nothing to quarantine **or an identical
    /// record was already quarantined for this doc**. `stamp` is injected (no
    /// wall-clock in core) so the file name is deterministic in tests.
    ///
    /// **Content dedup (audit N1):** the same op-log line stays torn forever (the
    /// log is append-only and never repaired), so this is called on *every* load of
    /// the affected doc. Without dedup that meant one fresh-stamped file per open →
    /// unbounded growth under `.maugham/conflicts/quarantine/`. We embed a stable
    /// content hash of the record body in the filename and skip the write when any
    /// existing `<docId>.<contentHash>.*.jsonl` already carries the identical body.
    /// The stamp survives in the name so genuinely-new tears (different content →
    /// different hash) still each get their own dated file.
    @discardableResult
    public static func record(
        skipped: [ParseDiagnostics.SkippedLine],
        forDocId docId: String,
        in projectURL: URL,
        stamp: String
    ) throws -> URL? {
        guard !skipped.isEmpty else { return nil }
        let dir = projectURL.appendingPathComponent(".maugham/conflicts/quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = skipped.map { line in
            #"{"doc_id":"\#(docId)","byte_offset":\#(line.byteOffset),"raw":\#(jsonString(line.raw))}"#
        }.joined(separator: "\n") + "\n"

        // Content-addressed prefix so repeated loads of the same persistent tear
        // collapse onto one file instead of accumulating.
        let contentHash = StableHash.fnv1a64Hex(body)
        let prefix = "\(docId).\(contentHash)."
        let fm = FileManager.default
        if let existing = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
           existing.contains(where: { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "jsonl" }) {
            return nil  // identical record already quarantined — no-op
        }

        let file = dir.appendingPathComponent("\(prefix)\(stamp).jsonl")
        try Data(body.utf8).write(to: file, options: .atomic)
        return file
    }

    /// Minimal JSON string escaping for the raw payload.
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        out += "\""
        return out
    }
}
