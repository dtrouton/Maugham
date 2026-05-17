// Maugham/OpLog/OpLogStore.swift
import Foundation

/// Per-document append-only JSONL op log. One file per document at
/// `.maugham/ops/<doc-id>.jsonl`. Coordinated via NSFileCoordinator for
/// safety under iCloud and external editors.
@MainActor
public final class OpLogStore {
    public let projectURL: URL
    public let presenter: NSFilePresenter?

    public init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.projectURL = projectURL
        self.presenter = presenter
    }

    private func opsDir() -> URL {
        projectURL.appendingPathComponent(".maugham/ops")
    }

    private func file(for docId: String) -> URL {
        opsDir().appendingPathComponent("\(docId).jsonl")
    }

    public func load(docId: String) async throws -> [Op] {
        let url = file(for: docId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var bytes: Data?
        coord.coordinate(readingItemAt: url, options: [], error: &coordErr) { ru in
            bytes = try? Data(contentsOf: ru)
        }
        if let coordErr { throw coordErr }
        return parseAndSort(bytes: bytes ?? Data())
    }

    public func append(_ op: Op) async throws {
        try FileManager.default.createDirectory(
            at: opsDir(), withIntermediateDirectories: true)
        let url = file(for: op.docId)
        let line = try encode(op) + "\n"
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var writeErr: Error?
        coord.coordinate(writingItemAt: url, options: [], error: &coordErr) { wu in
            do {
                if FileManager.default.fileExists(atPath: wu.path) {
                    let h = try FileHandle(forWritingTo: wu)
                    try h.seekToEnd()
                    try h.write(contentsOf: Data(line.utf8))
                    try h.close()
                } else {
                    try Data(line.utf8).write(to: wu, options: .atomic)
                }
            } catch { writeErr = error }
        }
        if let coordErr { throw coordErr }
        if let writeErr { throw writeErr }
    }

    // ISO8601 formatter with fractional-second precision so sub-millisecond
    // timestamps survive a JSON round-trip without truncation.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dateEncoding = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        var c = encoder.singleValueContainer()
        try c.encode(OpLogStore.iso8601Formatter.string(from: date))
    }

    private static let dateDecoding = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        // Accept both fractional-second and whole-second ISO8601 strings for
        // backward compatibility with data written before this change.
        if let d = OpLogStore.iso8601Formatter.date(from: s) { return d }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date: \(s)")
    }

    private func encode(_ op: Op) throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = Self.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(op)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseAndSort(bytes: Data) -> [Op] {
        guard let text = String(data: bytes, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = Self.dateDecoding
        var seen = Set<String>()
        var ops: [Op] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let op = try? dec.decode(Op.self, from: data) else { continue }
            if seen.insert(op.opId).inserted {
                ops.append(op)
            }
        }
        return ops.sorted { $0.opId < $1.opId }
    }
}
