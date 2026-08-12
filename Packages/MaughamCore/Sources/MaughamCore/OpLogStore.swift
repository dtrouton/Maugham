// Maugham/OpLog/OpLogStore.swift  (now in MaughamCore)
import Foundation

/// Per-document append-only JSONL op log, **partitioned per device** (ADR 0012,
/// spec §3.12). Each device writes only to its own file
/// `.maugham/ops/<docId>.<deviceSlug>.jsonl`; readers glob every sibling for the
/// doc (including the legacy unsuffixed `<docId>.jsonl`) and merge.
///
/// The logical op log is unchanged: the merged, opId-deduped, opId-sorted set of
/// all ops. ULID opIds give a deterministic total order regardless of which file
/// each op came from, so `Deriver`/`Materializer`/rewind see one `[Op]` and don't
/// care how it was assembled. Partitioning exists only so iCloud Drive never has
/// to reconcile two writers of the same path — it resolves divergence by
/// whole-file replace, silently dropping the loser as a conflict-twin the loader
/// would never open.
///
/// The write target is derived from `op.device` itself — an op self-describes the
/// device that created it, which is exactly the file it belongs in — so no caller
/// has to thread a device slug through.
@MainActor
public final class OpLogStore {
    public let projectURL: URL
    public let presenter: NSFilePresenter?

    public init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.projectURL = projectURL
        self.presenter = presenter
    }

    /// Test-only failure-injection seam. When non-nil, `append` throws this
    /// error instead of writing — letting tests exercise the disk-error
    /// recovery paths (e.g. `Document.close()`'s durable pending-flush
    /// fallback) without an actual unwritable filesystem. Default nil, so
    /// production behaviour is unchanged. `internal` + `@testable import` is
    /// the access surface; not part of the public API.
    var appendFailureForTesting: Error?

    private var opsDir: URL { projectURL.appendingPathComponent(".maugham/ops") }

    /// Glob every file for `docId` (legacy `<docId>.jsonl` + per-device
    /// `<docId>.<slug>.jsonl`), load each (coordinated), and merge: dedupe by
    /// opId, sort by opId. docIds contain no dots (delimiter between id and device
    /// slug), so the `<docId>.` boundary is unambiguous and can't prefix-collide
    /// with another doc. Format is `doc-<hex>` / `scene-<hex>` (ADR 0008) or the
    /// synthetic `__project__`.
    public func load(docId: String) async throws -> [Op] {
        try await loadDiagnosed(docId: docId).ops
    }

    /// Like `load(docId:)` but also surfaces the lines that failed to decode in
    /// any of the globbed per-device files, merged into one `ParseDiagnostics`.
    /// A torn/corrupt line (e.g. a crash mid-`append` leaving a truncated final
    /// line) is excluded from `ops` and reported in `diagnostics.skipped` so the
    /// caller can write a forensic record (`IntegrityQuarantine`) instead of
    /// dropping it silently. `load(docId:)` delegates here and discards the
    /// diagnostics, so existing callers are unaffected.
    public func loadDiagnosed(docId: String)
        async throws -> (ops: [Op], diagnostics: ParseDiagnostics)
    {
        let urls = Self.opLogFileURLs(forDocId: docId, in: projectURL)
        guard !urls.isEmpty else { return ([], ParseDiagnostics()) }
        var merged: [Op] = []
        var skipped: [ParseDiagnostics.SkippedLine] = []
        for url in urls {
            let result = try await Self.loadFileDiagnosed(url: url, presenter: presenter)
            merged.append(contentsOf: result.ops)
            skipped.append(contentsOf: result.diagnostics.skipped)
        }
        return (Self.mergeSortedDedup(merged), ParseDiagnostics(skipped: skipped))
    }

    /// Load + parse ONE op-log file — plain `.jsonl` tail or sealed `.mzseg`
    /// segment — into ops + diagnostics. The single per-file read shared by
    /// `loadDiagnosed(docId:)` and `ProjectIntegrity.check`, so opIds inside
    /// segments stay visible to the dangling-pointer check exactly as tail
    /// opIds are (growth spec §5.4).
    ///
    /// Segment verification failure (bad magic / decompress / checksum) is a
    /// data condition, not an error: surfaced as a `ParseDiagnostics.skipped`
    /// entry (so `ProjectIntegrity.check` marks the doc unhealthy and the
    /// load path quarantines it) while any salvageable decompressed lines
    /// still parse — best-effort, never silent (spec §5.3).
    /// RULING-54: a reader of a durable store treats an unreadable-yet-present
    /// file as an ERROR to surface, never as empty. The op log is the surface
    /// this ruling named FIRST: an unreadable device file used to contribute
    /// zero ops with empty diagnostics, the document opened SHORTER with no
    /// quarantine record, and the writer's next autosave truncated the `.md`
    /// to match — with the file's paragraphs superseded by the new sequence
    /// keyframe when it came back. Refusal at load is the only safe shape.
    public enum ReadError: Error, LocalizedError {
        case unreadableFile(name: String, underlying: String)
        case unlistableOpsDirectory(underlying: String)
        public var errorDescription: String? {
            switch self {
            case .unreadableFile(let name, let underlying):
                return "The manuscript's history file “\(name)” exists but can't be read (\(underlying)). "
                     + "Your words are intact inside it — check the file's permissions or wait for "
                     + "iCloud to finish syncing, then reopen the document. Maugham won't open a "
                     + "shortened version over it."
            case .unlistableOpsDirectory(let underlying):
                return "The manuscript's history folder (.maugham/ops) exists but can't be listed "
                     + "(\(underlying)). Check its permissions, then reopen — opening without it "
                     + "would start a second, parallel history."
            }
        }
    }

    /// RULING-54's directory half: an ops directory that EXISTS but cannot be
    /// LISTED must throw — `opLogFileURLs` is presence-only (`try?` → `[]`),
    /// and an empty answer there reads as "no log yet", which sends
    /// `Document.load` into `Bootstrap.run` to mint FRESH paragraph ids: a
    /// second, parallel history for a manuscript whose real history is intact
    /// behind a permissions error.
    public nonisolated static func verifyOpsDirectoryListable(in projectURL: URL) throws {
        let dir = projectURL.appendingPathComponent(".maugham/ops", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do { _ = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) }
        catch {
            throw ReadError.unlistableOpsDirectory(underlying: error.localizedDescription)
        }
    }

    public static func loadFileDiagnosed(
        url: URL, presenter: NSFilePresenter?
    ) async throws -> (ops: [Op], diagnostics: ParseDiagnostics) {
        if url.pathExtension == OpLogSegment.fileExtension {
            let coord = NSFileCoordinator(filePresenter: presenter)
            var coordErr: NSError?
            var readErr: Error?
            var bytes: Data?
            coord.coordinate(readingItemAt: url, options: [], error: &coordErr) { ru in
                do { bytes = try Data(contentsOf: ru) }  // adr-0018-ok: op-log file bytes — the op log IS the source of truth (ADR 0018)
                catch { readErr = error }
            }
            if let coordErr { throw coordErr }
            if let readErr {
                // Unreadable, not corrupt: a CHECKSUM failure below salvages
                // and quarantines, because the bytes were readable and partial
                // truth is recordable. Here nothing can be known — throw
                // (RULING-54), the same split the inbox fix drew.
                throw ReadError.unreadableFile(
                    name: url.lastPathComponent,
                    underlying: readErr.localizedDescription)
            }
            guard let container = bytes else { return ([], ParseDiagnostics()) }

            let decoded = OpLogSegment.decodeVerifying(container)
            var skipped: [ParseDiagnostics.SkippedLine] = []
            if let failure = decoded.failure {
                skipped.append(.init(
                    byteOffset: 0,
                    raw: "<segment \(url.lastPathComponent): \(failure)>"))
            }
            guard let jsonl = decoded.jsonl else {
                return ([], ParseDiagnostics(skipped: skipped))
            }
            let parsed = JSONLAppendStore<Op>.parse(
                bytes: jsonl,
                dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
            // Per-line skips inside a salvaged segment only matter when the
            // container itself verified (otherwise the container record covers it).
            if decoded.isVerified {
                skipped.append(contentsOf: parsed.diagnostics.skipped)
            }
            return (parsed.elements, ParseDiagnostics(skipped: skipped))
        }
        let store = JSONLAppendStore<Op>(
            fileURL: url, presenter: presenter,
            dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
        do {
            let result = try await store.loadDiagnosedStrict()
            return (result.elements, result.diagnostics)
        } catch {
            throw ReadError.unreadableFile(
                name: url.lastPathComponent,
                underlying: error.localizedDescription)
        }
    }

    /// Append to the writer's own per-device file, keyed by `op.device`.
    public func append(_ op: Op) async throws {
        if let injected = appendFailureForTesting { throw injected }
        try await store(forDocId: op.docId, deviceSlug: DeviceSlug.make(from: op.device))
            .append(op)
    }

    private func store(forDocId docId: String, deviceSlug: DeviceSlug) -> JSONLAppendStore<Op> {
        JSONLAppendStore<Op>(
            fileURL: Self.opLogFileURL(forDocId: docId, deviceSlug: deviceSlug, in: projectURL),
            presenter: presenter,
            dedupKey: { $0.opId },
            sortedBy: { $0.opId < $1.opId })
    }

    // MARK: - Seal (tail → immutable segment)

    /// Tail size above which a device's live per-doc file is sealed into an
    /// immutable compressed segment (ADR 0016 / growth spec §5.2). Default
    /// confirmed against the M0 baseline (spec §9.1).
    ///
    /// `nonisolated`: unlike the class it lives on, this constant has no
    /// isolation requirement of its own — it's an immutable `Sendable` `Int`
    /// that touches no actor state. Without the annotation it inherits
    /// `OpLogStore`'s `@MainActor`, and `sealTailIfNeeded`'s default-argument
    /// expression `= OpLogStore.segmentSealThreshold` is evaluated in a
    /// nonisolated context regardless of the enclosing type's isolation (the
    /// same default-argument behaviour found fixing the `Maugham/Updates/`
    /// warnings) — so referencing a `@MainActor`-isolated static from there
    /// warns. `nonisolated` states the true fact about the constant rather
    /// than routing around the default-argument quirk.
    public nonisolated static let segmentSealThreshold = 512 * 1024

    /// Seal THIS device's live tail for `docId` into the next-numbered
    /// `.mzseg` segment, iff the tail exceeds `threshold` bytes. Returns the
    /// segment URL, or nil when nothing was sealed (missing/small/torn tail).
    ///
    /// Scope rules (enforced by tests T13/T14): only ever the caller's OWN
    /// per-device tail — sealing is a rewrite of a single-writer file, the
    /// exact case ADR 0012 makes conflict-twin-free. NEVER the legacy
    /// unsuffixed `<docId>.jsonl` (no unambiguous owner; frozen since ADR
    /// 0012), never another device's file, never `__project__`.
    ///
    /// Crash safety is by construction, not by care: dying between the
    /// segment write and the tail delete leaves the same ops in both files —
    /// `mergeSortedDedup` collapses them by opId, and the next seal converges
    /// (the still-oversized tail becomes the next segment). A half-written
    /// temp file is ignored forever (wrong extension, never renamed).
    ///
    /// Coordinator policy: a fresh `NSFileCoordinator` for the read and another
    /// for the delete, matching `JSONLAppendStore` (one coordinator per file
    /// operation, never reused across operations). The unprotected gap between
    /// them is exactly the crash window the dedupe/converge contract already
    /// covers, so a single long-held coordinator would buy nothing.
    ///
    /// NOTE the dedupe/converge contract covers the CRASH case (same ops in
    /// both files). A concurrent APPEND into this same tail landing inside the
    /// read→delete gap would be deleted without being in the segment — that
    /// case is excluded by ADR 0012's single-writer-per-(device, project)
    /// guarantee: only this device's editor process writes this tail, and the
    /// seal runs on the same MainActor as every append, so the interleaving
    /// requires two same-variant app instances on one Mac, which the app's
    /// single-instance model rules out. If that model ever changes, this gap
    /// needs a single coordinated read+rewrite instead.
    @discardableResult
    public func sealTailIfNeeded(
        docId: String, deviceSlug: DeviceSlug,
        threshold: Int = OpLogStore.segmentSealThreshold
    ) async throws -> URL? {
        guard docId != "__project__" else { return nil }
        let fm = FileManager.default
        let tailURL = Self.opLogFileURL(
            forDocId: docId, deviceSlug: deviceSlug, in: projectURL)
        let size = ((try? fm.attributesOfItem(atPath: tailURL.path))?[.size] as? Int) ?? 0
        guard size > threshold else { return nil }

        // 1. Coordinated read of the tail's exact bytes; abort on any torn
        //    line — never bake unparseable bytes into a checksummed segment
        //    (the existing quarantine path owns torn tails).
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var tailBytes: Data?
        coord.coordinate(readingItemAt: tailURL, options: [], error: &coordErr) { ru in
            tailBytes = try? Data(contentsOf: ru)  // adr-0018-ok: op-log segment tail bytes — the op log IS the source of truth (ADR 0018)
        }
        if let coordErr { throw coordErr }
        // RULING-54 lenient, reason recorded: an unreadable tail SKIPS the
        // seal rather than surfacing. Sealing is maintenance, not truth — the
        // ops stay in the tail, the skip is retried on every autosave/close,
        // and a tail that is genuinely unreadable meets the strict refusal at
        // the next document load (M9-OL-001), so the state cannot persist
        // silently across sessions. The torn-line skip below is likewise
        // deliberate: the quarantine path owns torn tails, and a checksummed
        // segment must never bake in unparseable bytes.
        guard let bytes = tailBytes, !bytes.isEmpty else { return nil }
        let parsed = JSONLAppendStore<Op>.parse(bytes: bytes)
        guard parsed.diagnostics.skipped.isEmpty else { return nil }

        // 2. Next index = max existing + 1 for this (docId, slug); write the
        //    container to a temp name, then atomic-rename. Never overwrite.
        let existing = Self.opLogFileURLs(forDocId: docId, in: projectURL)
            .compactMap {
                Self.segmentIndex(fromFilename: $0.lastPathComponent,
                                  docId: docId, deviceSlug: deviceSlug)
            }
        let index = (existing.max() ?? 0) + 1
        let segURL = Self.segmentFileURL(
            forDocId: docId, deviceSlug: deviceSlug, index: index, in: projectURL)
        guard !fm.fileExists(atPath: segURL.path) else { return nil }
        let container = try OpLogSegment.encode(jsonl: bytes)
        let tmpURL = segURL.deletingLastPathComponent()
            .appendingPathComponent(".seal-tmp-\(UUID().uuidString)")
        try container.write(to: tmpURL, options: .atomic)
        try fm.moveItem(at: tmpURL, to: segURL)

        // 3. Coordinated delete of the tail; the next append recreates it via
        //    JSONLAppendStore.append's create branch.
        let delCoord = NSFileCoordinator(filePresenter: presenter)
        var delErr: NSError?
        var removeErr: Error?
        delCoord.coordinate(writingItemAt: tailURL, options: .forDeleting,
                            error: &delErr) { wu in
            do { try fm.removeItem(at: wu) } catch { removeErr = error }
        }
        if let delErr { throw delErr }
        if let removeErr { throw removeErr }
        return segURL
    }

    // MARK: - Glob helpers (shared with synchronous readers)

    /// The op-log file URL a writer for `docId` on device `deviceSlug` appends to:
    /// `<projectURL>/.maugham/ops/<docId>.<deviceSlug>.jsonl`. SINGLE SOURCE OF TRUTH
    /// for op-log filename CONSTRUCTION — the producer-side twin of
    /// `docId(fromOpLogFilename:)`. Surfaces (phone `AnnotationWriter`, Mac
    /// `OpLogStore.store`) MUST call this, never hand-roll the `"\(docId).\(slug).jsonl"`
    /// template. See docs/superpowers/notes/cross-surface-contracts.md.
    public nonisolated static func opLogFileURL(
        forDocId docId: String, deviceSlug: DeviceSlug, in projectURL: URL
    ) -> URL {
        projectURL
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent("\(docId).\(deviceSlug.raw).jsonl")
    }

    /// The doc id encoded in an op-log filename, or nil if `name` is not a
    /// manuscript doc op-log file. Filenames are `<docId>(.<slug>)?.jsonl`; the
    /// doc id is the component before the first `.` (doc ids contain no dot) and is
    /// `doc-<hex>` / `scene-<hex>` (ADR 0008). Deliberately NOT format-validated —
    /// this store is id-agnostic by contract; the only excluded stream is the
    /// synthetic `__project__` (tasks/checkpoints — no manuscript content).
    ///
    /// SINGLE SOURCE OF TRUTH for filename→docId. Surfaces (phone + Mac) MUST call
    /// this, never hand-roll a predicate (a stricter local copy is what shipped the
    /// phone-v0.1.1 "No open annotations" bug). Enforced by the reach-around
    /// tripwires; see docs/superpowers/notes/cross-surface-contracts.md.
    public nonisolated static func docId(fromOpLogFilename name: String) -> String? {
        let stem: String
        if name.hasSuffix(".jsonl") {
            stem = String(name.dropLast(".jsonl".count))
        } else if name.hasSuffix(".\(OpLogSegment.fileExtension)") {
            // Sealed segment `<docId>.<slug>.seg<NNNN>.mzseg` (ADR 0016).
            stem = String(name.dropLast(".\(OpLogSegment.fileExtension)".count))
        } else {
            return nil
        }
        let head = String(stem.split(separator: ".", maxSplits: 1,
                                     omittingEmptySubsequences: false)[0])
        guard !head.isEmpty, head != "__project__" else { return nil }
        return head
    }

    /// Distinct doc ids among a set of `.maugham/ops/` filenames (per-device +
    /// legacy files for one doc collapse to one id).
    public nonisolated static func docIds(inOpsDirectoryFilenames filenames: [String]) -> Set<String> {
        Set(filenames.compactMap(docId(fromOpLogFilename:)))
    }

    /// Every op-log file URL for `docId` (legacy + per-device). Pure listing,
    /// no read coordination — for readers that need the file set without the
    /// async coordinated load (mtime-change heuristics; the synchronous
    /// local-log readers in ProjectStore+Tasks). Returns [] if the ops dir or
    /// matching files don't exist.
    public nonisolated static func opLogFileURLs(
        forDocId docId: String, in projectURL: URL
    ) -> [URL] {
        let dir = projectURL.appendingPathComponent(".maugham/ops")
        let all = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { url in
            let n = url.lastPathComponent
            return n == "\(docId).jsonl"
                || (n.hasPrefix("\(docId).") && n.hasSuffix(".jsonl"))
                || (n.hasPrefix("\(docId).") && n.hasSuffix(".\(OpLogSegment.fileExtension)"))
        }
    }

    /// Sealed-segment URL: `.maugham/ops/<docId>.<deviceSlug>.seg<NNNN>.mzseg`
    /// (ADR 0016 / growth spec §5.1). SINGLE SOURCE OF TRUTH for segment
    /// filename construction — never hand-roll the template (grep tripwires
    /// on both targets enforce; see cross-surface-contracts.md).
    public nonisolated static func segmentFileURL(
        forDocId docId: String, deviceSlug: DeviceSlug, index: Int, in projectURL: URL
    ) -> URL {
        projectURL
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent(
                "\(docId).\(deviceSlug.raw).seg\(String(format: "%04d", index)).\(OpLogSegment.fileExtension)")
    }

    /// Parse `<docId>.<deviceSlug>.seg<NNNN>.mzseg` → NNNN, or nil if `name`
    /// is not a segment of this (docId, deviceSlug) pair.
    nonisolated static func segmentIndex(
        fromFilename name: String, docId: String, deviceSlug: DeviceSlug
    ) -> Int? {
        let prefix = "\(docId).\(deviceSlug.raw).seg"
        let suffix = ".\(OpLogSegment.fileExtension)"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// Synchronous globbed read+merge, bypassing `NSFileCoordinator`. For the
    /// local-only / heuristic readers that deliberately avoid async
    /// coordination; the async `load(docId:)` is the coordinated path and is
    /// preferred where the call site can await. Same opId dedupe + sort.
    public nonisolated static func loadSyncMerged(
        forDocId docId: String, in projectURL: URL
    ) throws -> [Op] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        var ops: [Op] = []
        for url in opLogFileURLs(forDocId: docId, in: projectURL) {
            let data: Data
            do { data = try Data(contentsOf: url) }  // adr-0018-ok: op-log file bytes — the op log IS the source of truth (ADR 0018)
            catch {
                // RULING-54: an unreadable-yet-present file throws — a closed
                // document must not derive SHORTER because one device's file
                // could not be read (the reader here includes MCP
                // read_document, which would otherwise hand Claude a shorter
                // manuscript as the truth).
                throw ReadError.unreadableFile(
                    name: url.lastPathComponent,
                    underlying: error.localizedDescription)
            }
            if url.pathExtension == OpLogSegment.fileExtension {
                guard let jsonl = OpLogSegment.decodeVerifying(data).jsonl else { continue }
                ops.append(contentsOf: JSONLAppendStore<Op>.parse(bytes: jsonl).elements)
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = String(line).data(using: .utf8),
                      let op = try? dec.decode(Op.self, from: lineData) else { continue }
                ops.append(op)
            }
        }
        return mergeSortedDedup(ops)
    }

    /// Collapse a union of op arrays into the canonical merged log: opId-sorted,
    /// **content-deterministic, load-order-independent** dedupe. Each source file
    /// is already internally deduped+sorted; this collapses any cross-file opId
    /// overlap (e.g. an op in both legacy and a per-device file).
    ///
    /// The survivor of a same-opId collision must be the SAME regardless of the
    /// order the inputs arrive in — production feeds this from
    /// `contentsOfDirectory` enumeration, whose order is NOT guaranteed, so two
    /// devices with identical logs must still derive identical text. A plain
    /// `.sorted { $0.opId < $1.opId }` is not a stable sort, so a same-opId pair
    /// with DIFFERENT content could survive non-deterministically (the loser
    /// depended on file-enumeration order). We fix that by sorting on a TOTAL
    /// order `(opId, canonicalEncoding)`: two ops with the same opId but different
    /// content always order the same way (by their canonical `.sortedKeys` JSON),
    /// so first-wins-by-opId after the sort yields a deterministic survivor.
    ///
    /// NOTE: a same-opId collision whose payloads DIVERGE is a corruption signal
    /// (ULIDs don't collide; a divergent collision means a replay / hand-recovery
    /// / duplicated op). Picking a deterministic survivor here keeps merge correct;
    /// SURFACING the collision (e.g. via `IntegrityQuarantine`) is worth doing
    /// later but needs the `projectURL`/stamp this pure fn deliberately lacks —
    /// don't entangle it here. See `OpLog/AREA.md` for the resolution contract.
    nonisolated static func mergeSortedDedup(_ ops: [Op]) -> [Op] {
        // Canonical, content-deterministic encoding of an op — the same
        // `.sortedKeys` + ISO8601-fractional date coding the store writes to
        // disk, so the tiebreaker is a stable function of content alone (no
        // ordering/clock/enumeration dependence).
        func canonical(_ op: Op) -> String {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
            enc.outputFormatting = [.sortedKeys]
            return (try? enc.encode(op)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        var seen = Set<String>()
        return ops
            .sorted { a, b in
                if a.opId != b.opId { return a.opId < b.opId }
                return canonical(a) < canonical(b)
            }
            .filter { seen.insert($0.opId).inserted }
    }
}
