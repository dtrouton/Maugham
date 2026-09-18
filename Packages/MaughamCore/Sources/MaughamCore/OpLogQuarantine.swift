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
    /// Whether a whole FILE was set aside (the unreadable-file ladder) or a run
    /// of LINES was (the chain's provenance check). The two are different
    /// events with different endings: a file can come back, a foreign line
    /// never can. Defaulted, and decoded tolerantly, so every record already on
    /// disk reads `.file` without a migration.
    public var kind: Kind

    public enum Status: String, Codable, Sendable {
        case held           // set aside, not yet returnable
        case superseded     // sync delivered the same history; archive kept
        case returned       // moved back into .maugham/ops/
    }

    public enum Kind: String, Codable, Sendable {
        case file           // the whole per-device file, moved out of the glob
        case lines          // a run of lines this device did not write
    }

    public init(docId: String, originalName: String, quarantinedAt: Date,
                reason: String, status: Status, kind: Kind = .file) {
        self.docId = docId
        self.originalName = originalName
        self.quarantinedAt = quarantinedAt
        self.reason = reason
        self.status = status
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case docId, originalName, quarantinedAt, reason, status, kind
    }

    /// Hand-written for one reason: `kind` arrived after records were already
    /// on disk, and a synthesized decoder would fail on every one of them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        docId = try c.decode(String.self, forKey: .docId)
        originalName = try c.decode(String.self, forKey: .originalName)
        quarantinedAt = try c.decode(Date.self, forKey: .quarantinedAt)
        reason = try c.decode(String.self, forKey: .reason)
        status = try c.decode(Status.self, forKey: .status)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .file
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
    /// A `.lines` record: a run of lines this device did not write. It is not
    /// a file that failed to read, so there is nothing to bring back — the
    /// bytes are forensics. Nothing is touched and nothing is merged.
    case setAsideByProvenance
}

/// One CHANGE a set-aside record holds, with the reason its record was filed
/// under (signed op log P2 smoke, find 6).
///
/// A change, not a line: a seal is neither, and the same op reaching the archive
/// twice is one. `OpLogQuarantine.setAsideChanges` is the one derivation — see
/// its doc comment for both rules.
public struct SetAsideChange: Equatable, Sendable {
    /// The identity the line's own stream gives it — an op's `op_id`, an inbox
    /// row's `id`, or a digest of the bytes for a line that names neither.
    public let id: String
    /// The reason the FIRST record to hold this change was filed under, in
    /// `JSONLAppendStore.quarantineReason`'s words.
    public let reason: String

    public init(id: String, reason: String) {
        self.id = id
        self.reason = reason
    }
}

/// **What a revocation keeps and what it sets aside** (spec §5; find 5, ruled
/// 2026-09-18).
///
/// Pure, and deliberately one layer above the walk: `OpLogChain` sees seals and
/// chains, not opIds, and the mark this turns on is a number the ROOT recorded
/// when it revoked somebody. So the walk refuses the span whole and says why,
/// and this decides which of those lines were already in the book.
///
/// **Nothing here is newly trusted, and that is the whole argument.** An op at
/// or below `highestOpIdSeen` is one this Mac had ALREADY APPLIED while that
/// device was admitted — the mark is this Mac's own record of having applied
/// it, not the device's word about itself. Re-admitting such a line is not the
/// revocation trusting a revoked key; it is the revocation declining to reach
/// backwards into work the writer has already read, redrafted and published.
/// What the device wrote AFTER the door closed is refused, as it always was.
///
/// The writer's other choice — *set aside everything it wrote* — arrives here
/// as a revocation record carrying no mark, and keeps its own meaning exactly:
/// nothing was ever *already here*, so nothing is re-admitted.
public enum RevocationSplit {

    /// A revoked span cut in two: the lines that stay in the book, and the
    /// lines that leave it.
    public struct Partition: Equatable, Sendable {
        /// Lines this Mac had already applied. Re-settled `.verified` and
        /// parsed with the rest of the file.
        public let readmitted: [Data]
        /// Every line that stays set aside — and **not one cause, but every
        /// cause the walk met in this file** (find-5 review, the Critical; this
        /// comment claimed the narrow thing until 2026-09-18).
        ///
        /// Most of these are what the device wrote after the door closed, which
        /// is what a revocation is about. The rest never were: a line refused
        /// for a broken chain, for a truncation, as another claimant's, or as
        /// written after a retirement is **not a candidate at all** — it is
        /// dropped in here by the first guard in `partition`, whatever opId it
        /// carries — and so is a candidate whose own person's revocation
        /// recorded no mark, and a line with no op before it whose position
        /// cannot be established.
        ///
        /// A reader that treats this array as *the revocation's leavings* will
        /// re-open the Critical the guard closed: `Verification.quarantineCause`
        /// answers one cause for a whole FILE and answers the FIRST one met, so
        /// a splice sitting after a revoked seal wore the revocation's name and
        /// was filed, and counted, as something the revocation had done. **Each
        /// line's own `refusal` is the only thing that says why it is here**;
        /// anything narrating this array must ask it per line.
        public let refused: [Data]

        public init(readmitted: [Data], refused: [Data]) {
            self.readmitted = readmitted
            self.refused = refused
        }
    }

    /// How this revocation's refused lines divide, or **nil where nothing
    /// divides them** — which is every case but a revocation carrying a mark.
    ///
    /// Nil rather than an all-refused partition on purpose: the caller's job is
    /// then *leave the walk exactly as it found it*, which is a different act
    /// from re-admitting an empty list and has to be told apart at the call
    /// site. A broken chain has no *before*; a revocation with no mark has no
    /// *already here*.
    ///
    /// **A seal travels with the op immediately before it in file order.** A
    /// seal carries no opId of its own and the span it closes is the one ending
    /// at the line above it, so filing `seal1` under *after revocation* while
    /// re-admitting the `op1` it sealed would accuse a signature of a position
    /// its own op does not have — the third cause behind the smoke's wrong
    /// set-aside count (find 6). A line with no op before it at all — the head
    /// of the span, a shape this build cannot parse — has no position that can
    /// be established, and stays refused: the strict side is the side to be
    /// wrong on. The span that is entirely below the mark falls out of the same
    /// rule with no clause of its own.
    nonisolated public static func partition(
        of verification: OpLogChain.Verification,
        highestOpIdSeen mark: (String) -> String?
    ) -> Partition? {
        guard !verification.quarantined.isEmpty else { return nil }

        var readmitted: [Data] = []
        var refused: [Data] = []
        // What the last CANDIDATE line carrying an opId decided. Reset by any
        // line that is not a candidate, so a seal never travels across one.
        var travellingWith: Bool?
        var sawCandidate = false
        for line in verification.lines where line.state == .quarantined {
            // **The refusal is the line's own** (find-5 review, the Critical).
            // A line refused for a chain fault, a truncation, another
            // claimant's root or a retirement is not a candidate whatever its
            // op id, and `Verification.quarantineCause` cannot answer this —
            // it is one cause for the whole file and it is the FIRST one met,
            // so a splice after a revoked seal wore the revocation's name.
            guard case .afterRevocation? = line.refusal else {
                refused.append(line.bytes)
                travellingWith = nil
                continue
            }
            // Each line against ITS OWN person's mark, asked per line rather
            // than resolved once: a file holds one device's writing (ADR 0012),
            // and a rule that assumed so would be assuming it silently.
            guard case let .afterRevocation(person) = line.refusal,
                  let theirMark = mark(person) else {
                refused.append(line.bytes)
                travellingWith = nil
                continue
            }
            sawCandidate = true
            let keeps: Bool
            if let opId = opId(ofLine: line.bytes) {
                keeps = opId <= theirMark
                travellingWith = keeps
            } else {
                // A seal travels with the op immediately before it — and only
                // if that op was itself refused for the revocation, which is
                // what `travellingWith` being nil records.
                keeps = travellingWith ?? false
            }
            if keeps { readmitted.append(line.bytes) } else { refused.append(line.bytes) }
        }
        guard sawCandidate else { return nil }
        return Partition(readmitted: readmitted, refused: refused)
    }

    /// The opId a raw op line carries — nil for a seal, and for anything that
    /// does not parse, which is filed on the strict side by the rule above.
    ///
    /// Read off the OBJECT rather than by decoding an `Op`: the only field this
    /// needs is the id, and a line a later build wrote — a new op kind, a field
    /// this build has no property for — still has an opId that can be read off
    /// it, where a full decode would fail and file a line as unplaceable on the
    /// strength of something it does not turn on.
    ///
    /// The key is `Op`'s own (`op_id` on the wire), asked of its `CodingKeys`
    /// rather than spelled again here: a second spelling would go on reading
    /// nil, silently, the day that name changed.
    nonisolated static func opId(ofLine line: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        return object?[Op.CodingKeys.opId.stringValue] as? String
    }
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
    ///
    /// **Order: the record is written FIRST, then the bytes move.** The two are
    /// separate filesystem operations and only one order is safe. Writing the
    /// sidecar afterward means a failed sidecar write strands MOVED BYTES with
    /// no record of them — a file gone from `.maugham/ops/` that nothing in the
    /// app knows to offer back (the review's M1). Written first, the two
    /// failure modes are both recoverable: a failed sidecar write moves
    /// nothing at all, and a failed MOVE deletes the record-of-nothing it just
    /// wrote before rethrowing. The one cost is a sub-millisecond window in
    /// which the sidecar describes a file that has not moved yet, during which
    /// `records(forDocId:in:)`'s read-time reconciliation reads it as
    /// `.returned` — honest in its own way (the bytes ARE at
    /// `.maugham/ops/`), and gone the instant the move lands.
    ///
    /// `now` exists so a test can predict the destination name this mints (the
    /// stamp is otherwise a wall-clock read with no seam), which is what makes
    /// both the sidecar-write failure and the same-millisecond collision
    /// reachable from a test rather than argued about in prose. Production
    /// never passes it.
    @discardableResult
    public static func quarantine(
        fileURL: URL, docId: String, reason: String,
        in projectURL: URL,
        now: Date = Date(),
        isDatalessStub: (URL) -> Bool = OpLogQuarantine.defaultStubProbe
    ) throws -> QuarantineRecord {
        guard !isDatalessStub(fileURL) else {
            throw QuarantineError.datalessStub(fileURL)
        }

        let fm = FileManager.default
        let dir = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let originalName = fileURL.lastPathComponent
        let quarantinedAt = now
        let stampText = stamp(from: quarantinedAt)

        // Disambiguate on collision (two quarantines of the same original
        // name landing in the same stamp millisecond) rather than overwrite.
        // The SIDECAR's existence counts as a collision too: a record whose
        // file has already returned leaves its forensic sidecar behind with
        // the data file gone, and a re-quarantine that looked only at the data
        // path would overwrite that record (the review's M3) — the one durable
        // account of what was set aside and why.
        var destURL = dir.appendingPathComponent("\(originalName).\(stampText)")
        var suffix = 2
        while fm.fileExists(atPath: destURL.path)
                || fm.fileExists(atPath: sidecarURL(forQuarantinedName: destURL.lastPathComponent, in: dir).path) {
            destURL = dir.appendingPathComponent("\(originalName).\(stampText)-\(suffix)")
            suffix += 1
        }

        let record = QuarantineRecord(
            docId: docId, originalName: originalName, quarantinedAt: quarantinedAt,
            reason: reason, status: .held)
        let sidecar = sidecarURL(forQuarantinedName: destURL.lastPathComponent, in: dir)
        try JSONEncoder().encode(record).write(to: sidecar, options: .atomic)

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
        // Nothing moved on either failure, so the record above describes
        // nothing. Remove it rather than leave a `.held` row for a file still
        // sitting in `.maugham/ops/` — the pane would offer a Retry for
        // history the writer already has.
        if let coordError {
            try? fm.removeItem(at: sidecar)
            throw coordError
        }
        if let moveError {
            try? fm.removeItem(at: sidecar)
            throw moveError
        }

        return record
    }

    /// Sets a run of LINES aside: the bytes this device found in its own
    /// op-log file that it did not write (spec §3's provenance check).
    ///
    /// Distinct from `quarantine` in every way that matters. Nothing moves —
    /// the file itself is fine and stays exactly where it is; the caller has
    /// already decided which of its lines are kept and rewrites the tail
    /// without these. So this WRITES a copy of the foreign bytes under
    /// `.maugham/conflicts/quarantined-ops/` as
    /// `<originalName>.<hash>.<stamp>.lines`, with a `.lines` record beside
    /// it, and that is the whole event: forensics the writer can read, never
    /// a file that can come back (`attemptReturn` answers
    /// `.setAsideByProvenance` for one and touches nothing).
    ///
    /// **Content-deduped**, exactly as `IntegrityQuarantine.record` is: the
    /// FNV-64 of the joined lines goes in the destination name, and a second
    /// call carrying the same bytes for the same file answers nil rather than
    /// accumulating a new archive on every append. The same foreign line found
    /// on ten consecutive opens is one record, not ten.
    ///
    /// The record is written FIRST for `quarantine`'s reason, one failure mode
    /// shorter: a failed record write leaves no bytes, and a failed byte write
    /// removes the record it just wrote.
    ///
    /// `nonisolated`: this is called from inside an `NSFileCoordinator`
    /// writing-accessor block on the append path, which is a plain synchronous
    /// closure with no isolation of its own. Nothing here touches MainActor
    /// state — it is a directory create and two file writes under a path the
    /// coordinated file is not in — so stating that is honest rather than a
    /// route around the checker.
    @discardableResult
    public nonisolated static func setAsideLines(
        _ lines: [Data], from fileURL: URL, docId: String, reason: String,
        in projectURL: URL, now: Date = Date()
    ) throws -> QuarantineRecord? {
        guard !lines.isEmpty else { return nil }

        let fm = FileManager.default
        let dir = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var body = Data()
        for line in lines {
            body.append(line)
            body.append(0x0A)
        }

        let originalName = fileURL.lastPathComponent
        let contentHash = StableHash.fnv1a64Hex(String(decoding: body, as: UTF8.self))
        let prefix = "\(originalName).\(contentHash)."
        if let existing = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
           existing.contains(where: {
               $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "lines"
           }) {
            return nil  // the same bytes are already on file for this doc
        }

        let destURL = dir.appendingPathComponent("\(prefix)\(stamp(from: now)).lines")
        let record = QuarantineRecord(
            docId: docId, originalName: originalName, quarantinedAt: now,
            reason: reason, status: .held, kind: .lines)
        let sidecar = sidecarURL(forQuarantinedName: destURL.lastPathComponent, in: dir)
        try JSONEncoder().encode(record).write(to: sidecar, options: .atomic)
        do {
            try body.write(to: destURL, options: .atomic)
        } catch {
            try? fm.removeItem(at: sidecar)
            throw error
        }
        return record
    }

    /// The `<quarantined name>.quarantine.json` convention, in one place —
    /// `quarantine` mints it, its collision loop probes it, and
    /// `rewriteRecord` resolves it back. Three spellings of the same suffix
    /// was one rename away from a record nothing could find.
    nonisolated static func sidecarURL(forQuarantinedName name: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(name).quarantine.json")
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
        guard record.status == .held, record.kind == .file else { return record }
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
    /// The CHANGES a set of records held back, in the order they were filed,
    /// each counted once (signed op log P2 smoke, finds 6 and 7).
    ///
    /// **Op lines only.** A seal is not a change — it is the signature that
    /// closes a span — and it is held back with the lines it settles, so a span
    /// of two ops under one signature is three LINES and two changes. The
    /// pending counts have said this since P2b (`OpLogProvenance.pendingOpLines`
    /// over `OpLogChain.pendingByDevice`, which filters `kind == .op`); this is
    /// the same rule for the refused half, so History cannot put a different
    /// number in front of the same noun. A seal is recognised through
    /// `OpLogChain.isSealLine` and nowhere else (tripwire 37).
    ///
    /// **Deduplicated across records.** The same op reaches the archive more
    /// than once whenever a span is set aside twice and split differently on the
    /// two loads — the smoke's own case: `[op1, seal1]` on one open, then
    /// `[op1]` and `[seal1, op2, seal2]` on the next. Three records, four op
    /// lines, TWO changes. The identity is the line's own (`op_id` for an op,
    /// `id` for an inbox row); a line carrying neither is keyed on a digest of
    /// its bytes, so it is still counted once rather than once per record.
    ///
    /// The order is (`quarantinedAt`, then the archive's own name), so a change
    /// found in two records is attributed to the reason of the FIRST record that
    /// held it and one folder answers one way however its sidecars happened to
    /// be enumerated.
    ///
    /// Lives here rather than on a pane because TWO panes ask it: History for
    /// a document's own op-log files, the Inbox for the manifest stream
    /// (`InboxManifest.chainDocId`). A second copy would be two answers to one
    /// question. Separate from the notice copy on purpose — a notice that read
    /// disk would do file I/O on every `body` evaluation; each pane calls this
    /// once, on refresh.
    ///
    /// `.file` records are skipped: their data file is a whole op log, whose
    /// line count is a different quantity entirely.
    public nonisolated static func setAsideChanges(
        records: [QuarantineRecord], in projectURL: URL
    ) -> [SetAsideChange] {
        // Split out of one chained expression on purpose: written as a single
        // `filter`/`map`/`sorted` chain, this defeats the type-checker's budget
        // outright (CLAUDE.md's "unable to type-check in reasonable time" is
        // real, and this is where it fired).
        var ordered: [(record: QuarantineRecord, url: URL)] = []
        for record in records where record.kind == .lines {
            ordered.append((record, quarantinedFileURL(for: record, in: projectURL)))
        }
        ordered.sort { left, right in
            if left.record.quarantinedAt != right.record.quarantinedAt {
                return left.record.quarantinedAt < right.record.quarantinedAt
            }
            return left.url.lastPathComponent < right.url.lastPathComponent
        }

        var seen: Set<String> = []
        var changes: [SetAsideChange] = []
        for entry in ordered {
            guard let bytes = try? Data(contentsOf: entry.url) else { continue }  // adr-0018-ok: a set-aside `.lines` archive — forensics this counts, never manuscript truth
            for slice in bytes.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let line = Data(slice)
                guard !OpLogChain.isSealLine(line) else { continue }
                let id = changeIdentity(ofLine: line)
                guard seen.insert(id).inserted else { continue }
                changes.append(SetAsideChange(id: id, reason: entry.record.reason))
            }
        }
        return changes
    }

    /// How many set-aside changes a writer still has NOT got — `applied` is the
    /// identities the stream is currently carrying, and a change in it is one a
    /// later admission brought in (find 7).
    ///
    /// The records are permanent evidence and the disclosure goes on listing
    /// every one of them; what stops being true after a re-admission is the
    /// SENTENCE, because those changes are in the writer's draft.
    public nonisolated static func setAsideChangeCount(
        records: [QuarantineRecord], in projectURL: URL, applied: Set<String> = []
    ) -> Int {
        setAsideChanges(records: records, in: projectURL)
            .reduce(0) { $0 + (applied.contains($1.id) ? 0 : 1) }
    }

    /// The identity a line's own stream gives it.
    ///
    /// `op_id` is read through `RevocationSplit.opId(ofLine:)` rather than
    /// spelled again — one reader of that key. An inbox manifest row has no
    /// `op_id`; its own `id` is asked of `InboxEntry.CodingKeys` for the same
    /// reason. A line that carries neither (a legacy shape, a build this one
    /// cannot parse) keys on a digest of its bytes: the same bytes in two
    /// records are one change, and two different unidentifiable lines stay two.
    nonisolated private static func changeIdentity(ofLine line: Data) -> String {
        if let opId = RevocationSplit.opId(ofLine: line) { return opId }
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        if let rowId = object?[InboxEntry.CodingKeys.id.stringValue] as? String {
            return rowId
        }
        return "line:" + StableHash.fnv1a64Hex(String(decoding: line, as: UTF8.self))
    }

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
    ///
    /// Internal rather than private so a test that pins `quarantine`'s
    /// destination naming can predict the name from the `now` it injected,
    /// instead of re-spelling this format and drifting from it.
    nonisolated static func stamp(from date: Date) -> String {
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
    /// that also answers `.stillUnreadable`; (4) check the destination path
    /// (`.maugham/ops/<originalName>`) — present means sync already
    /// delivered this device's file back while it was set aside, so the
    /// archive is left exactly where it is and the record is marked
    /// `.superseded`; absent means a coordinated move back (mirroring
    /// `quarantine`'s own move, source and destination swapped) and the
    /// record is marked `.returned`. No branch ever writes to an existing
    /// destination file. (5) compute the recovery report — **inside** each
    /// branch and never before it, because what counts as an orphan depends
    /// on whether the archive actually MOVED (`RecoveredHistory.report`'s
    /// `mergeHappened`); a report computed once, up front, against the
    /// hypothetical merge was the whole-branch review's C1.
    public static func attemptReturn(
        record: QuarantineRecord, in projectURL: URL, presenter: NSFilePresenter?
    ) async -> ReturnOutcome {
        // A `.lines` record is not a file that failed to read — it is a copy of
        // bytes this device did not write, kept as forensics. There is nothing
        // to bring back, so this answers before touching anything at all.
        guard record.kind == .file else { return .setAsideByProvenance }

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

        let destURL = projectURL
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent(record.originalName)

        guard !FileManager.default.fileExists(atPath: destURL.path) else {
            // NOTHING MOVES on this branch, so the report is computed against
            // the current derivation ALONE (`mergeHappened: false`). Computing
            // it against the merge here was the whole-branch review's C1: an
            // archive whose keyframe would have WON a merge reported zero
            // orphans, the record flipped `.superseded`, the standing notice
            // went away, and the writer was told "nothing was missing" about
            // paragraphs that live in no readable log.
            let report = RecoveredHistory.report(
                currentOps: currentOps, returnedOps: returnedOps, mergeHappened: false)
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
        // The move DID happen, so the draft the writer will see derives from
        // both op sets: `mergeHappened: true`.
        return .returned(RecoveredHistory.report(
            currentOps: currentOps, returnedOps: returnedOps, mergeHappened: true))
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
    ///
    /// **`.returned` is sticky.** Two returns can be in flight over the same
    /// record — `EditorHost`'s auto-return sweep fires on every normal open
    /// and the History pane's Retry is a button the writer can press while it
    /// runs — and the LOSER of that race would otherwise write its own,
    /// staler, verdict over the winner's: a `.superseded` stamped on top of a
    /// `.returned` says the archive is still in `quarantined-ops/` when the
    /// bytes are back in `.maugham/ops/`, which sends the pane looking for a
    /// file that is not there (the review's M2). So a non-`.returned` write
    /// re-reads the sidecar first and declines when it already says
    /// `.returned`. The decline answers `true`: the sidecar holds the truth
    /// this call was trying to establish, which is success — a `false` here
    /// would put a spurious "failed to rewrite" line in the log.
    @discardableResult
    private static func rewriteRecord(
        _ record: QuarantineRecord, status: QuarantineRecord.Status,
        quarantinedFileURL: URL, in projectURL: URL
    ) -> Bool {
        var updated = record
        updated.status = status
        let dir = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        let sidecar = sidecarURL(
            forQuarantinedName: quarantinedFileURL.lastPathComponent, in: dir)
        if status != .returned, onDiskStatus(at: sidecar) == .returned { return true }
        do {
            try JSONEncoder().encode(updated).write(to: sidecar, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The status the sidecar at `url` currently records, or nil when there is
    /// nothing readable there. An unreadable sidecar answers nil rather than
    /// throwing: the caller's fallback is to write its own verdict, which is
    /// the same thing it would do for a sidecar that was never written.
    private static func onDiskStatus(at url: URL) -> QuarantineRecord.Status? {
        (try? Data(contentsOf: url))  // adr-0018-ok: a `.quarantine.json` sidecar — this verb's own bookkeeping, never manuscript text
            .flatMap { try? JSONDecoder().decode(QuarantineRecord.self, from: $0) }?
            .status
    }
}
