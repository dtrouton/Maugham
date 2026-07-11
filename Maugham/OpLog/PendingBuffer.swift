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
///
/// The on-disk payload is a single JSON object `{ basis?, changes, sequence }`
/// (ADR 0019; `basis` added Issue 2b, 2026-07-01): the durable paragraph order
/// travels WITH the un-bursted changes, so a hard-crash mid-reorder recovers from
/// the op-log domain alone — the `.md` is no longer needed to reconstruct
/// ordering. Legacy line-delimited JSONL pending files (a bare
/// `Op.ParagraphChange` per line) fail to decode as the wrapper object and are
/// silently ignored = abandoned-by-design, per the contract above.
///
/// `sequence` is durable *independently* of `changes` (F1): an ordering-only
/// edit (paragraph delete / pure reorder) records NO change here but autosave
/// stamps the new order via `setSequence`, so a `{sequence, changes: []}`
/// pending file is the crash-recovery carrier for an un-bursted reorder.
///
/// `basis` (optional) is the opId of the newest op the Document had folded when
/// `sequence` was stamped (Issue 2b). It lets `Document.load` tell a CURRENT
/// pending order from a STALE one: if ops the pending file never saw have merged
/// in since (basis != the log's newest opId — e.g. a peer's while-closed delete),
/// the empty-changes fold is SKIPPED and a non-empty-changes fold recovers text
/// with `sequence: nil` rather than reasserting a superseded order. A CLEAN close
/// deletes the pending file outright now (Issue 2a), so a stale `{seq, []}` mirror
/// only survives a crash; legacy files (no `basis`) decode to nil and are treated
/// conservatively — see `Document+Load`'s basis-aware fold.
@MainActor
public final class PendingBuffer {
    public let projectURL: URL
    public let docId: String
    /// Filename-safe, stable-per-device slug for partitioning (ADR 0012).
    private let deviceSlug: DeviceSlug

    private var buffer: [String: Op.ParagraphChange] = [:]

    /// The durable paragraph order as of the last autosave flush. Recovery
    /// (`Document+Load`) folds the un-bursted changes into a real op carrying
    /// THIS order — not the `.md`'s parsed anchor order (ADR 0019). Empty until
    /// `setSequence` is called (legacy pending files also load empty).
    private var seq: [String] = []

    /// The current durable paragraph order (op-log-domain). See `seq`.
    public var sequence: [String] { seq }

    /// The opId of the newest op the writer had folded when `seq` was stamped
    /// (Issue 2b, 2026-07-01). It lets `Document.load` tell a CURRENT pending
    /// order from a STALE one: if ops the pending file never saw have merged in
    /// since (e.g. a peer's while-closed delete), `basis` no longer matches the
    /// log's newest opId, and the recovery fold must NOT reassert this order.
    /// Optional so legacy pending files (which predate the field) decode to nil
    /// — `Document.load` treats missing-basis conservatively for the
    /// empty-changes fold. `PendingBuffer` stays dumb: it only stores + round-
    /// trips the value the Document supplies.
    private var basisOpId: String? = nil

    /// The basis opId (see `basisOpId`). Nil until `setSequence(_:basis:)` is
    /// called with one, or after a legacy pending file loads.
    public var basis: String? { basisOpId }

    /// Record the live paragraph order (and, optionally, the basis opId — the
    /// newest folded op at stamp time) so the next `flushToDisk` persists them.
    public func setSequence(_ s: [String], basis: String? = nil) {
        seq = s
        basisOpId = basis
    }

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

    /// The durable on-disk shape: a single JSON object pairing the paragraph
    /// order with the un-bursted changes, plus the optional `basis` opId
    /// (Issue 2b) the order was stamped against. Replaces the legacy line-
    /// delimited JSONL so the order survives a crash without consulting the
    /// `.md`. `basis` is optional: `encodeIfPresent`/`decodeIfPresent` omit it
    /// for a nil basis, so a legacy pending file (no `basis` key) decodes to nil.
    private struct DiskState: Codable {
        let sequence: [String]
        let changes: [Op.ParagraphChange]
        let basis: String?
    }

    public func flushToDisk() async throws {
        let url = file()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let state = DiskState(
            sequence: seq, changes: snapshot(), basis: basisOpId)
        try enc.encode(state).write(to: url, options: .atomic)
    }

    public func loadFromDisk() async throws {
        let url = file()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),  // adr-0018-ok: PendingBuffer's own pending file, not a manuscript
              let state = try? JSONDecoder().decode(DiskState.self, from: data) else { return }
        seq = state.sequence
        basisOpId = state.basis
        for change in state.changes { buffer[change.paragraphId] = change }
    }

    public func clear() async throws {
        buffer.removeAll()
        seq = []
        basisOpId = nil
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
            .appendingPathComponent("\(docId).\(deviceSlug.raw).pending.jsonl")
    }
}
