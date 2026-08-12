import Foundation
import os

/// Diagnostic channel for quarantine-return anomalies — specifically a
/// sidecar rewrite that fails AFTER a move-back already succeeded (see
/// `attemptReturn`'s doc comment). Mirrors `Deriver.swift`'s `deriverLog` /
/// `TranslationStore.swift`'s `translationLog`.
private let quarantineLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.core",
    category: "OpLogQuarantine")

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

/// Outcome of `OpLogQuarantine.attemptReturn` (Plan B, spec §5's return
/// path): verified by a real read, merged by the sync rules, never
/// overwriting.
public enum ReturnOutcome: Equatable, Sendable {
    /// Moved back into .maugham/ops/; the report describes the merge.
    case returned(RecoveredHistoryReport)
    /// The device's file reappeared via sync; the archive stays, the report
    /// covers whatever the archive held beyond the current log.
    case supersededBySync(RecoveredHistoryReport)
    /// Still can't be read cleanly — stays held. Reason for the notice.
    case stillUnreadable(reason: String)
    /// Readable but a line fails to decode — stays held; salvage is the
    /// integrity path's job, not a merge input (spec §5 step 1).
    case corrupt(reason: String)
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
    // `nonisolated`: a plain string literal, referenced from both the
    // MainActor-isolated write path and the nonisolated read helpers below —
    // matches `OpLogStore.segmentSealThreshold`'s reasoning for the same
    // annotation on a stateless `static let` inside a `@MainActor` type.
    nonisolated private static let directoryName = ".maugham/conflicts/quarantined-ops"

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
    ///
    /// `nonisolated`: a pure filesystem read touching no MainActor state —
    /// same reasoning as `defaultStubProbe`. Unlike `quarantine`, this has no
    /// write to serialize, so there's no reason to force it onto MainActor.
    public nonisolated static func records(forDocId docId: String, in projectURL: URL) -> [QuarantineRecord] {
        sidecars(in: projectURL)
            .compactMap { $0.record }
            .filter { $0.docId == docId }
            .map { reconciled($0, in: projectURL) }
            .sorted { $0.quarantinedAt < $1.quarantinedAt }
    }

    /// Corrects a stale `.held` record at READ time when its move-back
    /// already happened: `attemptReturn`'s move and its sidecar rewrite are
    /// two separate filesystem operations (the move can't be made to
    /// unwind if the rewrite afterward fails — see that function's doc
    /// comment), so a rewrite failure can leave a record saying `.held`
    /// for a file that has, in fact, already returned.
    ///
    /// The signal is unambiguous: nothing but a completed return-move ever
    /// removes a file from `quarantined-ops/` (`quarantine` only ever
    /// ADDS entries there), so a `.held` record whose quarantined bytes are
    /// gone, paired with its `originalName` sitting at `.maugham/ops/`,
    /// can only mean the move succeeded and the rewrite that should have
    /// followed it did not.
    ///
    /// Deliberately a READ-time correction rather than a write-back repair:
    /// `records` is `nonisolated` by design (a pure filesystem read with no
    /// write to serialize) and this keeps it that way — the write-vs-read
    /// isolation split stays intact, at the cost of recomputing the
    /// correction on every call rather than settling it once on disk.
    private nonisolated static func reconciled(_ record: QuarantineRecord, in projectURL: URL) -> QuarantineRecord {
        guard record.status == .held else { return record }
        let quarantinedURL = quarantinedFileURL(for: record, in: projectURL)
        let destURL = projectURL
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent(record.originalName)
        guard !FileManager.default.fileExists(atPath: quarantinedURL.path),
              FileManager.default.fileExists(atPath: destURL.path)
        else { return record }
        var corrected = record
        corrected.status = .returned
        return corrected
    }

    /// The URL of the quarantined bytes for `record`. Matched by identity
    /// (`docId`, `originalName`, `quarantinedAt`) rather than full equality,
    /// so a caller holding a stale snapshot (e.g. `status` since flipped by a
    /// later return/supersede) still resolves — the triple is this event's
    /// key, `status` is mutable state on top of it. Accepted, documented
    /// assumption: two records whose `(docId, originalName, quarantinedAt)`
    /// agree to the bit (vanishingly unlikely — `Date` carries sub-millisecond
    /// precision — but not impossible) resolve to whichever sidecar the
    /// directory listing returns first.
    ///
    /// `nonisolated`: a pure filesystem read touching no MainActor state —
    /// same reasoning as `defaultStubProbe`.
    public nonisolated static func quarantinedFileURL(for record: QuarantineRecord, in projectURL: URL) -> URL {
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

    // `nonisolated`: shared by the two nonisolated read helpers above; a
    // nonisolated caller can't synchronously call back into a MainActor-
    // isolated function, so this has to be nonisolated too.
    nonisolated private static func sidecars(in projectURL: URL) -> [(url: URL, record: QuarantineRecord?)] {
        let dir = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return entries
            .filter { $0.lastPathComponent.hasSuffix(".quarantine.json") }
            .map { url in
                let record = (try? Data(contentsOf: url))  // adr-0018-ok: a `.quarantine.json` sidecar — this verb's own bookkeeping, never manuscript text
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
    ///
    /// `nonisolated`: used as the default value for a plain `(URL) -> Bool`
    /// parameter on `quarantine` — a MainActor-isolated default is a Swift 6
    /// error there. Precedent: `RecoveryPaneModel.defaultBlockageClearedProbe`
    /// in `Maugham/Views/DocumentRecoveryPane.swift`, `nonisolated` on the
    /// same shape of problem.
    public nonisolated static func defaultStubProbe(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys:
            [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }
}

extension OpLogQuarantine {
    /// Attempts to bring a quarantined op-log file back into `.maugham/ops/`
    /// (Plan B's return path, spec §5): verified by a real read, merged by
    /// the sync rules, never overwriting.
    ///
    /// Isolation: like `quarantine`, this WRITES (moves a file, rewrites the
    /// record on disk), so it stays on the `@MainActor` side of the split —
    /// the pure reads (`records(forDocId:in:)`, `quarantinedFileURL(for:in:)`)
    /// are the only members of this type that are `nonisolated`.
    ///
    /// Order, and why: (1) a coordinated STRICT read of the quarantined
    /// bytes — any failure (permission, a directory squatting on the path,
    /// …) answers `.stillUnreadable` before anything else is touched;
    /// (2) parse as `Op` JSONL — a line that fails to decode answers
    /// `.corrupt` rather than being silently dropped, because salvaging a
    /// torn file is the integrity path's job, not a merge input (spec §5
    /// step 1); (3) load the CURRENT log for this doc via `OpLogStore` —
    /// this is a `do`/`catch`, not `try?`, because a throw here means the
    /// live history is itself unreadable (some OTHER device file is broken)
    /// and merging against a partial current picture would be dishonest, so
    /// that also answers `.stillUnreadable`; (4) compute the recovery
    /// report from both op sets; (5) check the destination path
    /// (`.maugham/ops/<originalName>`) — present means sync already
    /// delivered this device's file back while it was set aside, so the
    /// archive is left exactly where it is and the record is marked
    /// `.superseded`; absent means a coordinated move back (mirroring
    /// `quarantine`'s own move, source and destination swapped) and the
    /// record is marked `.returned`. No branch ever writes to an existing
    /// destination file.
    public static func attemptReturn(
        record: QuarantineRecord, in projectURL: URL, presenter: NSFilePresenter?
    ) async -> ReturnOutcome {
        let dataURL = OpLogQuarantine.quarantinedFileURL(for: record, in: projectURL)

        let quarantinedStore = JSONLAppendStore<Op>(
            fileURL: dataURL, presenter: presenter,
            dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
        let parsed: (elements: [Op], diagnostics: ParseDiagnostics)
        do {
            parsed = try await quarantinedStore.loadDiagnosedStrict()
        } catch {
            return .stillUnreadable(reason: error.localizedDescription)
        }
        guard parsed.diagnostics.skipped.isEmpty else {
            return .corrupt(reason: "a line in the quarantined file failed to decode")
        }
        let returnedOps = parsed.elements

        let currentOps: [Op]
        do {
            currentOps = try await OpLogStore(projectURL: projectURL, presenter: presenter)
                .load(docId: record.docId)
        } catch {
            return .stillUnreadable(reason: "the live history is itself unreadable")
        }

        let report = RecoveredHistory.report(currentOps: currentOps, returnedOps: returnedOps)

        let destURL = projectURL
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent(record.originalName)

        guard !FileManager.default.fileExists(atPath: destURL.path) else {
            if !rewriteRecord(record, status: .superseded, quarantinedFileURL: dataURL, in: projectURL) {
                quarantineLog.error("attemptReturn: left \(dataURL.lastPathComponent, privacy: .public) quarantined (superseded by sync) but failed to rewrite its quarantine record to .superseded")
            }
            return .supersededBySync(report)
        }

        let fm = FileManager.default
        try? fm.createDirectory(
            at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var coordError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        coordinator.coordinate(
            writingItemAt: dataURL, options: .forMoving,
            writingItemAt: destURL, options: [],
            error: &coordError
        ) { newSrcURL, newDestURL in
            do {
                try fm.moveItem(at: newSrcURL, to: newDestURL)
            } catch {
                moveError = error
            }
        }
        if let coordError {
            return .stillUnreadable(reason: coordError.localizedDescription)
        }
        if let moveError {
            return .stillUnreadable(reason: moveError.localizedDescription)
        }

        if !rewriteRecord(record, status: .returned, quarantinedFileURL: dataURL, in: projectURL) {
            quarantineLog.error("attemptReturn: moved \(dataURL.lastPathComponent, privacy: .public) back to .maugham/ops/ but failed to rewrite its quarantine record to .returned — records() reconciles this at read time")
        }
        return .returned(report)
    }

    /// Rewrites the `.quarantine.json` sidecar beside the quarantined file
    /// with an updated status. The sidecar name is derived from the
    /// QUARANTINED file's own name (`quarantinedFileURL`'s name, captured
    /// BEFORE any move) — same `<name>.quarantine.json` convention
    /// `quarantine` writes at creation time — so this resolves correctly
    /// whether or not the data itself just moved out from under it.
    ///
    /// Returns whether the write succeeded. NOT parity with `quarantine`'s
    /// own sidecar write (a bare `try` that propagates because `quarantine`
    /// is a `throws` function) — `attemptReturn` isn't throwing, and by the
    /// time this runs its move has already either happened or been
    /// deliberately skipped, so there is nothing left to unwind. A caller
    /// that gets `false` back has a truthful `ReturnOutcome` (the move DID
    /// happen; only the bookkeeping about it failed) plus a `.held` record
    /// stranded on disk — `attemptReturn` logs the failure loudly, and
    /// `records(forDocId:in:)` self-heals the `.returned` case at read time
    /// (see `reconciled(_:in:)`) so the strand doesn't read as "still set
    /// aside" forever.
    @discardableResult
    private static func rewriteRecord(
        _ record: QuarantineRecord, status: QuarantineRecord.Status,
        quarantinedFileURL: URL, in projectURL: URL
    ) -> Bool {
        var updated = record
        updated.status = status
        let dir = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        let sidecarURL = dir.appendingPathComponent(
            "\(quarantinedFileURL.lastPathComponent).quarantine.json")
        do {
            try JSONEncoder().encode(updated).write(to: sidecarURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
