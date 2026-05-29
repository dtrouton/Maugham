// Maugham/OpLog/PendingBuffer.swift
import Foundation
import MaughamCore

/// In-memory buffer of paragraph changes since the last burst boundary,
/// mirrored to disk at `.maugham/ops/<doc-id>.pending.jsonl` on the autosave
/// cadence so a hard-crash mid-burst doesn't lose editorial classification.
@MainActor
public final class PendingBuffer {
    public let projectURL: URL
    public let docId: String
    private var buffer: [String: Op.ParagraphChange] = [:]

    public init(projectURL: URL, docId: String) {
        self.projectURL = projectURL
        self.docId = docId
    }

    public func recordChange(paragraphId: String, prior: String?, next: String) {
        let priorToKeep = buffer[paragraphId]?.prior ?? prior
        buffer[paragraphId] = .init(paragraphId: paragraphId, prior: priorToKeep, next: next)
    }

    public func snapshot() -> [Op.ParagraphChange] {
        // Sort by paragraphId for deterministic output.
        return buffer.values.sorted { $0.paragraphId < $1.paragraphId }
    }

    public func isEmpty() -> Bool { buffer.isEmpty }

    public func flushToDisk() async throws {
        let url = file()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let lines: [String] = try snapshot().map {
            String(data: try enc.encode($0), encoding: .utf8) ?? ""
        }
        let payload = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try Data(payload.utf8).write(to: url, options: .atomic)
    }

    public func loadFromDisk() async throws {
        let url = file()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let d = String(line).data(using: .utf8),
                  let change = try? dec.decode(Op.ParagraphChange.self, from: d) else { continue }
            buffer[change.paragraphId] = change
        }
    }

    public func clear() async throws {
        buffer.removeAll()
        let url = file()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func file() -> URL {
        projectURL
            .appendingPathComponent(".maugham/ops")
            .appendingPathComponent("\(docId).pending.jsonl")
    }
}
