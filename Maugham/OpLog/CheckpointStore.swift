// Maugham/OpLog/CheckpointStore.swift
import Foundation

/// Project-wide append-only JSONL of named checkpoints.
@MainActor
public final class CheckpointStore {
    public let projectURL: URL
    public let presenter: NSFilePresenter?

    public init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.projectURL = projectURL
        self.presenter = presenter
    }

    private func file() -> URL {
        projectURL.appendingPathComponent(".maugham/checkpoints.jsonl")
    }

    public func load() async throws -> [Checkpoint] {
        let url = file()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var bytes: Data?
        coord.coordinate(readingItemAt: url, options: [], error: &coordErr) { ru in
            bytes = try? Data(contentsOf: ru)
        }
        if let coordErr { throw coordErr }
        return parse(bytes: bytes ?? Data())
    }

    public func append(_ cp: Checkpoint) async throws {
        try FileManager.default.createDirectory(
            at: file().deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let line = try encode(cp) + "\n"
        let url = file()
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
    // (Previously used .secondsSince1970 because plain .iso8601 was lossy;
    //  this formatter preserves full precision while staying spec-compliant.)
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dateEncoding = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        var c = encoder.singleValueContainer()
        try c.encode(CheckpointStore.iso8601Formatter.string(from: date))
    }

    private static let dateDecoding = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        // Accept fractional-second and whole-second ISO8601 strings, plus raw
        // epoch numbers (backward compatibility with data written via .secondsSince1970).
        if let d = CheckpointStore.iso8601Formatter.date(from: s) { return d }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        if let epoch = Double(s) { return Date(timeIntervalSince1970: epoch) }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date: \(s)")
    }

    private func encode(_ cp: Checkpoint) throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = Self.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        return String(data: try enc.encode(cp), encoding: .utf8) ?? ""
    }

    private func parse(bytes: Data) -> [Checkpoint] {
        guard let text = String(data: bytes, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = Self.dateDecoding
        var out: [Checkpoint] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let d = String(line).data(using: .utf8),
                  let cp = try? dec.decode(Checkpoint.self, from: d) else { continue }
            out.append(cp)
        }
        return out
    }
}
