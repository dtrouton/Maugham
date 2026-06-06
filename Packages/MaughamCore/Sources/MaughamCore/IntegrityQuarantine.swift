import Foundation

/// Persists op-log lines that failed to decode (from `ParseDiagnostics`) into
/// `.maugham/conflicts/quarantine/` so they are never silently lost — a writer or
/// a future tool can inspect/recover them. Append-only, best-effort forensics;
/// not part of the logical op log.
public enum IntegrityQuarantine {
    /// Writes `skipped` for `docId` to
    /// `.maugham/conflicts/quarantine/<docId>.<stamp>.jsonl`. Returns the file URL,
    /// or nil if there was nothing to quarantine. `stamp` is injected (no wall-clock
    /// in core) so the file name is deterministic in tests.
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
        let file = dir.appendingPathComponent("\(docId).\(stamp).jsonl")
        let body = skipped.map { line in
            #"{"doc_id":"\#(docId)","byte_offset":\#(line.byteOffset),"raw":\#(jsonString(line.raw))}"#
        }.joined(separator: "\n") + "\n"
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
