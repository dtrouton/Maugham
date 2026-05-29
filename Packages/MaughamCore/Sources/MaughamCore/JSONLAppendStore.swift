// Maugham/OpLog/JSONLAppendStore.swift
import Foundation

/// NSFileCoordinator-coordinated append-only JSONL store. Generic over
/// any Codable element; ISO8601-with-fractional-seconds Date coding is
/// the default since that's what every existing store uses.
///
/// Two configurable knobs:
///   - `dedupKey`: if non-nil, load() drops duplicates by this key,
///     keeping first occurrence. (OpLogStore uses `\.opId`.)
///   - `sortedBy`: if non-nil, load() sorts by this comparator.
///     (OpLogStore uses { $0.opId < $1.opId }.)
@MainActor
public final class JSONLAppendStore<Element: Codable & Sendable> {
    public let fileURL: URL
    public let presenter: NSFilePresenter?
    private let dedupKey: ((Element) -> String)?
    private let sortedBy: ((Element, Element) -> Bool)?

    public init(
        fileURL: URL,
        presenter: NSFilePresenter? = nil,
        dedupKey: ((Element) -> String)? = nil,
        sortedBy: ((Element, Element) -> Bool)? = nil
    ) {
        self.fileURL = fileURL
        self.presenter = presenter
        self.dedupKey = dedupKey
        self.sortedBy = sortedBy
    }

    public func load() async throws -> [Element] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var bytes: Data?
        coord.coordinate(readingItemAt: fileURL, options: [], error: &coordErr) { ru in
            bytes = try? Data(contentsOf: ru)
        }
        if let coordErr { throw coordErr }
        return parseAndPostProcess(bytes: bytes ?? Data())
    }

    public func append(_ element: Element) async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let line = try encode(element) + "\n"
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var writeErr: Error?
        coord.coordinate(writingItemAt: fileURL, options: [], error: &coordErr) { wu in
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

    private func encode(_ element: Element) throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = Self.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(element)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseAndPostProcess(bytes: Data) -> [Element] {
        guard let text = String(data: bytes, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = Self.dateDecoding
        var elements: [Element] = []
        var seen = Set<String>()
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let d = String(line).data(using: .utf8),
                  let element = try? dec.decode(Element.self, from: d) else { continue }
            if let key = dedupKey?(element) {
                if !seen.insert(key).inserted { continue }
            }
            elements.append(element)
        }
        if let sortedBy {
            elements.sort(by: sortedBy)
        }
        return elements
    }

    // === Shared ISO8601-with-fractional-seconds Date coding ===

    // Computed property returning a fresh instance per call keeps this
    // nonisolated without the (unsafe) baggage on a class-typed stored property.
    // These stores are not on the hot path so the allocation cost is negligible.
    nonisolated private static var iso8601Formatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    nonisolated public static var dateEncoding: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(iso8601Formatter.string(from: date))
        }
    }

    nonisolated public static var dateDecoding: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            // Accept fractional-second and whole-second ISO8601 strings.
            if let d = iso8601Formatter.date(from: s) { return d }
            if let d = ISO8601DateFormatter().date(from: s) { return d }
            // Backward-compat for CheckpointStore data written via secondsSince1970.
            if let epoch = Double(s) { return Date(timeIntervalSince1970: epoch) }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unrecognised date: \(s)")
        }
    }
}
