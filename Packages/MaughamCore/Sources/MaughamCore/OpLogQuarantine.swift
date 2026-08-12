import Foundation

/// A durable record of one set-aside op-log file (Plan B, spec §5): what was
/// moved, why, and whether it can come back. Lives beside the moved bytes as
/// `<destName>.quarantine.json` under `.maugham/conflicts/quarantined-ops/`.
public struct QuarantineRecord: Codable, Equatable, Sendable {
    public let docId: String
    public let originalName: String   // e.g. "doc-x.phone.jsonl"
    public let quarantinedAt: Date
    public let reason: String         // the read error at quarantine time
    public var status: Status

    public enum Status: String, Codable, Sendable {
        case held           // set aside, not yet returnable
        case superseded     // sync delivered the same history; archive kept
        case returned       // moved back into .maugham/ops/
    }

    public init(docId: String, originalName: String, quarantinedAt: Date,
                reason: String, status: Status) {
        self.docId = docId
        self.originalName = originalName
        self.quarantinedAt = quarantinedAt
        self.reason = reason
        self.status = status
    }
}

/// Errors `OpLogQuarantine.quarantine` can throw beyond the move itself.
public enum QuarantineError: Error, Equatable {
    /// Refused: `fileURL` is a dataless iCloud stub. Moving it would fight
    /// the download the wait-and-retry rung already triggered (spec §3).
    case datalessStub(URL)
}

/// The typed verb for setting an unreadable op-log file aside (Plan B,
/// spec §5) — the recovery ladder's rung above read-only (Plan A). This IS
/// tripwire 14's typed mover for op-log sidecar relocation: a raw
/// `FileManager.moveItem` on an op-log file elsewhere in the tree stays
/// forbidden. The move never opens the bytes — no parse, no read beyond what
/// the move/coordination itself performs — because a file that refused to
/// read is exactly the file this verb must not risk reading.
@MainActor
public enum OpLogQuarantine {
    private static let directoryName = ".maugham/conflicts/quarantined-ops"

    /// Moves `fileURL` byte-identically into
    /// `.maugham/conflicts/quarantined-ops/` and writes a `QuarantineRecord`
    /// beside it. Throws `QuarantineError.datalessStub` (nothing moved) when
    /// `isDatalessStub` says the file is a not-yet-downloaded iCloud stub.
    ///
    /// Coordinator policy: one `NSFileCoordinator`, coordinating writes on
    /// BOTH the source (`.forMoving`) and destination — the standard AppKit
    /// shape for a coordinated move — mirroring `sealTailIfNeeded`'s "one
    /// coordinator per file operation" discipline in `OpLogStore.swift`.
    @discardableResult
    public static func quarantine(
        fileURL: URL, docId: String, reason: String,
        in projectURL: URL,
        isDatalessStub: (URL) -> Bool = OpLogQuarantine.defaultStubProbe
    ) throws -> QuarantineRecord {
        guard !isDatalessStub(fileURL) else {
            throw QuarantineError.datalessStub(fileURL)
        }

        let fm = FileManager.default
        let dir = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let originalName = fileURL.lastPathComponent
        let quarantinedAt = Date()
        let stampText = stamp(from: quarantinedAt)

        // Disambiguate on collision (two quarantines of the same original
        // name landing in the same stamp millisecond) rather than overwrite.
        var destURL = dir.appendingPathComponent("\(originalName).\(stampText)")
        var suffix = 2
        while fm.fileExists(atPath: destURL.path) {
            destURL = dir.appendingPathComponent("\(originalName).\(stampText)-\(suffix)")
            suffix += 1
        }

        var coordError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: fileURL, options: .forMoving,
            writingItemAt: destURL, options: [],
            error: &coordError
        ) { newSrcURL, newDestURL in
            do {
                try fm.moveItem(at: newSrcURL, to: newDestURL)
            } catch {
                moveError = error
            }
        }
        if let coordError { throw coordError }
        if let moveError { throw moveError }

        let record = QuarantineRecord(
            docId: docId, originalName: originalName, quarantinedAt: quarantinedAt,
            reason: reason, status: .held)

        let sidecarURL = dir.appendingPathComponent("\(destURL.lastPathComponent).quarantine.json")
        try JSONEncoder().encode(record).write(to: sidecarURL, options: .atomic)

        return record
    }

    /// Every `QuarantineRecord` filed for `docId`, oldest first. Decodes every
    /// `*.quarantine.json` sidecar in the quarantine directory; unreadable or
    /// undecodable sidecars are skipped rather than thrown (best-effort
    /// forensics, matching `IntegrityQuarantine`'s stance).
    public static func records(forDocId docId: String, in projectURL: URL) -> [QuarantineRecord] {
        sidecars(in: projectURL)
            .compactMap { $0.record }
            .filter { $0.docId == docId }
            .sorted { $0.quarantinedAt < $1.quarantinedAt }
    }

    /// The URL of the quarantined bytes for `record`. Matched by identity
    /// (`docId`, `originalName`, `quarantinedAt`) rather than full equality,
    /// so a caller holding a stale snapshot (e.g. `status` since flipped by a
    /// later return/supersede) still resolves — the triple is this event's
    /// key, `status` is mutable state on top of it.
    public static func quarantinedFileURL(for record: QuarantineRecord, in projectURL: URL) -> URL {
        let dir = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        for entry in sidecars(in: projectURL) {
            guard let found = entry.record,
                  found.docId == record.docId,
                  found.originalName == record.originalName,
                  found.quarantinedAt == record.quarantinedAt
            else { continue }
            let sidecarName = entry.url.lastPathComponent
            let dataName = String(sidecarName.dropLast(".quarantine.json".count))
            return dir.appendingPathComponent(dataName)
        }
        // Fallback for a record with no sidecar on disk (shouldn't happen in
        // production — kept so the function stays total rather than optional).
        return dir.appendingPathComponent(record.originalName)
    }

    // MARK: - Private

    private static func sidecars(in projectURL: URL) -> [(url: URL, record: QuarantineRecord?)] {
        let dir = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return entries
            .filter { $0.lastPathComponent.hasSuffix(".quarantine.json") }
            .map { url in
                let record = (try? Data(contentsOf: url))
                    .flatMap { try? decoder.decode(QuarantineRecord.self, from: $0) }
                return (url: url, record: record)
            }
    }

    /// A filesystem-safe timestamp, ISO8601 with fractional seconds and `:`
    /// replaced by `-`. Mirrors `ISO8601DateFormatter.quarantineStamp` in
    /// `Maugham/OpLog/Document+Load.swift` — that one lives app-side because
    /// MaughamCore was historically wall-clock-free; this verb needs its own
    /// wall clock (there is no injected clock in the public signature), so
    /// the format is duplicated here rather than shared across the module
    /// boundary MaughamCore can't cross.
    private static func stamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    /// Production stub probe: an item iCloud knows about whose content isn't
    /// current on this machine. Mirrors `RecoveryCause.defaultStubProbe` in
    /// `Maugham/OpLog/RecoveryCause.swift` — that one is app-layer and
    /// MaughamCore cannot import it, so the same five lines are duplicated
    /// here. Any resource-read failure answers false: misclassifying a stub
    /// as quarantinable degrades to an honest quarantine of a file that will
    /// re-download fine; the reverse (refusing to quarantine a genuinely
    /// broken file because it looked like a stub) is worse.
    public static func defaultStubProbe(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys:
            [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }
}
