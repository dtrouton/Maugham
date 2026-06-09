// Maugham/OpLog/PendingBuffer.swift
import Foundation
import MaughamCore

/// In-memory buffer of paragraph changes since the last burst boundary,
/// mirrored to disk on the autosave cadence so a hard-crash mid-burst doesn't
/// lose editorial classification.
///
/// The on-disk path is `.maugham/pending/<docId>.<deviceSlug>.pending.jsonl`:
///   - **device-partitioned** (ADR 0012 / tripwire 17): the buffer is a JSONL
///     file under the iCloud-synced project; two Macs (or a crash mid-sync)
///     would otherwise write the same path and iCloud silently drops a
///     conflict-twin, folding the wrong device's uncommitted keystrokes into a
///     real burst op or losing the right device's. Each device writes only to
///     its own slug file.
///   - **outside `.maugham/ops/`**: the op-log glob matches
///     `<docId>.*.jsonl` under `ops/`, so a pending file living there parses as
///     an op-log file and is read by the op-log loader. Relocating it to its
///     own `pending/` subdir keeps it off the op-log glob entirely.
///
/// Old `.maugham/ops/<docId>.pending.jsonl` files from before this relocation
/// are abandoned by design — the buffer is ephemeral crash-recovery state (real
/// edits already hit the op log at each burst boundary), so no migration.
@MainActor
public final class PendingBuffer {
    public let projectURL: URL
    public let docId: String
    /// Filename-safe, stable-per-device slug for partitioning (ADR 0012).
    private let deviceSlug: String

    private var buffer: [String: Op.ParagraphChange] = [:]

    public init(projectURL: URL, docId: String, device: String) {
        self.projectURL = projectURL
        self.docId = docId
        self.deviceSlug = DeviceSlug.make(from: device)
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

    /// This device's pending-buffer file. `flushToDisk`/`loadFromDisk`/`clear`
    /// all route through here, so they read/write only THIS device's slug file:
    /// crash-recovery folds back only the keystrokes the crashed (= recovering)
    /// device hadn't bursted yet — never a glob-merge of every device's pending
    /// buffer (another device's un-bursted edits are not this device's to commit).
    private func file() -> URL {
        projectURL
            .appendingPathComponent(".maugham/pending")
            .appendingPathComponent("\(docId).\(deviceSlug).pending.jsonl")
    }
}
