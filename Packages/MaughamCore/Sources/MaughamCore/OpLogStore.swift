// Maugham/OpLog/OpLogStore.swift  (now in MaughamCore)
import CryptoKit
import Foundation
import os

/// Diagnostic channel for the two things a LOAD can fail at without failing:
/// recording the lines it set aside, and signing a segment it just minted.
/// Neither may cost the writer their manuscript, so neither throws — and a
/// silent best-effort is only honest if it says so somewhere.
private let opLogLoadLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.core",
    category: "OpLogStore")

/// One device's signature over a sealed segment's digest, written beside the
/// segment as `<name>.mzseg.sig`.
///
/// **Why beside rather than inside.** A `.mzseg` is immutable bytes whose
/// checksum is part of its own header; signing it in place would mean rewriting
/// it, and a segment that can be rewritten is not sealed. The signature is
/// therefore a sidecar, and losing it costs exactly what losing any derived
/// file costs: the segment reads as unsigned history, which is honest.
///
/// **Why over the digest.** The segment already commits to every one of its
/// bytes through the SHA-256 in its header, so signing those 32 bytes signs the
/// whole segment — one signature per segment instead of one per line, and the
/// verification is a single P256 check however long the history is. It is the
/// same three fields a seal line carries (`OpLogChain.Seal`) over a different
/// digest, and it goes through the same credential helpers so the two shapes
/// cannot drift apart.
public struct SegmentSignature: Codable, Equatable, Sendable {
    /// The segment's own uncompressed-content digest, 64 hex characters.
    public let digest: String
    /// The signing key's fingerprint (`DeviceIdentity.fingerprint(of:)`).
    public let key: String
    /// Base64 of the public key's X9.63 representation.
    public let pub: String
    /// Base64 of the 64-byte raw P256 signature over the digest's 32 bytes.
    public let sig: String
    public let at: Date

    public init(digest: String, key: String, pub: String, sig: String, at: Date) {
        self.digest = digest
        self.key = key
        self.pub = pub
        self.sig = sig
        self.at = at
    }

    /// Sign `digest` with `identity`. Throws `DeviceIdentityError.unsigned` on a
    /// device with no key — a condition, not a failure.
    public static func make(
        digest: String, identity: DeviceIdentity, at: Date = Date()
    ) throws -> SegmentSignature {
        let credentials = try OpLogChain.credentials(signing: digest, identity: identity)
        return SegmentSignature(
            digest: digest, key: credentials.key,
            pub: credentials.pub, sig: credentials.sig, at: at)
    }

    /// Does this signature hold together over the digest it names? Says nothing
    /// about whether the key is TRUSTED — that is the reader's question.
    public func verifies() -> Bool {
        OpLogChain.credentialsVerify(
            .init(key: key, pub: pub, sig: sig), over: digest)
    }

    /// The signature beside a segment, or nil when there is none to read. A
    /// missing or unreadable sidecar is never an error: it means the segment is
    /// unsigned history.
    public static func read(at url: URL) -> SegmentSignature? {
        guard let bytes = try? Data(contentsOf: url) else { return nil }  // adr-0018-ok: derived signature sidecar, never manuscript text
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = JSONLAppendStore<SegmentSignature>.dateDecoding
        return try? decoder.decode(SegmentSignature.self, from: bytes)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<SegmentSignature>.dateEncoding
        return try encoder.encode(self)
    }
}

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

    /// This device's four writers, as every line one of them writes will name
    /// it. Defaulted, so every existing caller still compiles and gets the real
    /// identities.
    ///
    /// A store holds all four rather than one because the three questions the
    /// op log asks about a key have stopped having the same answer: which key
    /// SIGNS a line (the actor named by `op.device`), which keys are TRUSTED on
    /// read (all four — every actor here is this device), and which files this
    /// device seals (each actor's own).
    public let identities: LocalIdentities
    /// What this device remembers about the files it has written.
    public let deviceState: OpLogDeviceState

    public init(
        projectURL: URL,
        presenter: NSFilePresenter? = nil,
        identities: LocalIdentities = .current,
        state: OpLogDeviceState = .shared
    ) {
        self.projectURL = projectURL
        self.presenter = presenter
        self.identities = identities
        self.deviceState = state
    }

    /// Lines this device has appended to each file since that file's last seal.
    /// In memory and per store instance on purpose: it is a cadence, not a
    /// fact — losing it costs at most one late seal, and the seal itself is
    /// idempotent (nothing unsealed, nothing written).
    ///
    /// Keyed on the file APPENDED to, which is the same file `sealChain` seals
    /// because `append` only ever counts a line it CHAINED, and it only chains
    /// this device's own. Before that rule (the whole-branch review's C1) a
    /// foreign-device append could push this counter over the interval and
    /// spend the seal on a file the run of lines was never in.
    private var linesSinceSeal: [URL: Int] = [:]

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
        async throws -> (ops: [Op], diagnostics: ParseDiagnostics, provenance: OpLogProvenance)
    {
        let urls = Self.opLogFileURLs(forDocId: docId, in: projectURL)
        guard !urls.isEmpty else { return ([], ParseDiagnostics(), OpLogProvenance()) }
        var merged: [Op] = []
        var skipped: [ParseDiagnostics.SkippedLine] = []
        var files: [FileProvenance] = []
        for url in urls {
            let result = try await Self.loadFileDiagnosed(
                url: url, presenter: presenter,
                identities: identities, state: deviceState)
            merged.append(contentsOf: result.ops)
            skipped.append(contentsOf: result.diagnostics.skipped)
            files.append(result.provenance)
        }
        return (Self.mergeSortedDedup(merged),
                ParseDiagnostics(skipped: skipped),
                OpLogProvenance(files: files))
    }

    /// The result of `loadDiagnosedPartial` — the recovery spec §4's read.
    public struct PartialOpLogLoad {
        public let ops: [Op]
        public let diagnostics: ParseDiagnostics
        /// Sorted by filename; reuses the checkpoint slice's pair type.
        public let unreadableFiles: [CheckpointLoad.UnreadableFile]
        /// What each READABLE file turned out to be made of. A file that could
        /// not be read has no provenance — it is named in `unreadableFiles`
        /// instead, which is a different fact and must not be blurred into a
        /// count of zero verified lines.
        public let provenance: OpLogProvenance
    }

    /// RULING-54's DELIBERATE partial read, for the read-only recovery rung
    /// ONLY (spec §4): every readable file loads, every unreadable-yet-present
    /// file is NAMED in the result. This must never become a general-purpose
    /// lenient read — `loadDiagnosed` stays the strict default, and the one
    /// production caller is `Document.load(recovery: .readOnlyPartial)`,
    /// whose Document can write nothing.
    public func loadDiagnosedPartial(docId: String) async -> PartialOpLogLoad {
        var all: [Op] = []
        var skipped: [ParseDiagnostics.SkippedLine] = []
        var unreadable: [CheckpointLoad.UnreadableFile] = []
        var files: [FileProvenance] = []
        for url in Self.opLogFileURLs(forDocId: docId, in: projectURL) {
            do {
                let result = try await Self.loadFileDiagnosed(
                    url: url, presenter: presenter,
                    identities: identities, state: deviceState)
                all.append(contentsOf: result.ops)
                skipped.append(contentsOf: result.diagnostics.skipped)
                files.append(result.provenance)
            } catch {
                unreadable.append(.init(
                    name: url.lastPathComponent,
                    reason: error.localizedDescription))
            }
        }
        return PartialOpLogLoad(
            ops: Self.mergeSortedDedup(all),
            diagnostics: ParseDiagnostics(skipped: skipped),
            unreadableFiles: unreadable.sorted { $0.name < $1.name },
            provenance: OpLogProvenance(files: files))
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

    /// The coordinated read of one op-log file's exact bytes. Nil when the file
    /// is not there (which is not a failure); a throw when it is there and
    /// cannot be read (RULING-54: unreadable-yet-present is never empty).
    private static func readCoordinated(
        url: URL, presenter: NSFilePresenter?
    ) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var readErr: Error?
        var bytes: Data?
        coord.coordinate(readingItemAt: url, options: [], error: &coordErr) { ru in
            do { bytes = try Data(contentsOf: ru) }  // adr-0018-ok: op-log file bytes — the op log IS the source of truth (ADR 0018)
            catch { readErr = error }
        }
        // Unreadable, not corrupt: a CHECKSUM failure salvages and quarantines,
        // because the bytes were readable and partial truth is recordable. Here
        // nothing can be known — throw, the same split the inbox fix drew.
        if let failure = (coordErr as Error?) ?? readErr {
            throw ReadError.unreadableFile(
                name: url.lastPathComponent,
                underlying: failure.localizedDescription)
        }
        return bytes ?? Data()
    }

    public static func loadFileDiagnosed(
        url: URL, presenter: NSFilePresenter?,
        identities: LocalIdentities? = nil, state: OpLogDeviceState? = nil
    ) async throws -> (ops: [Op], diagnostics: ParseDiagnostics, provenance: FileProvenance) {
        guard let bytes = try readCoordinated(url: url, presenter: presenter) else {
            return ([], ParseDiagnostics(),
                    FileProvenance(name: url.lastPathComponent,
                                   isSealedSegment: url.pathExtension == OpLogSegment.fileExtension))
        }
        let classified = classify(
            url: url, bytes: bytes, identities: identities, state: state)

        // The three writes a load is allowed to make, all of them derived
        // bookkeeping and every one best-effort: nothing here may cost the
        // writer the load of their own manuscript.
        if let digest = classified.verifiedSegmentDigest {
            state?.markVerified(segmentDigest: digest)
        }
        if let head = classified.adoptedHead {
            // The root is the one `fileKey` scoped this file to, not a
            // handle of this static function's own: it has a URL and no
            // project. Recording the same directory the hash was taken over is
            // what lets the entry be pruned when that project is gone.
            state?.remember(head: head, for: OpLogDeviceState.fileKey(url),
                            root: OpLogDeviceState.projectRoot(of: url))
        }
        // A forensic record is the LOAD path's to write, and only its. A caller
        // taking the nil defaults — `ProjectIntegrity.check`, and anything else
        // that inspects a project without opening it — classifies with no key
        // and no remembered head, so its picture is strictly WEAKER than the
        // load's: it cannot see an `afterRememberedHead` break at all, and what
        // it does see it would file under the load's name. A check reports; the
        // load records.
        let recordsWhatItSetsAside = identities != nil && state != nil
        if recordsWhatItSetsAside, let verification = classified.verification,
           let docId = docId(fromOpLogFilename: url.lastPathComponent) {
            do {
                try JSONLAppendStore<Op>.setAside(
                    verification, from: url, docId: docId,
                    in: projectRoot(of: url))
            } catch {
                // Mirrors `Document+Load.swift`'s stance on a forensic write
                // that fails: the record is how the writer LEARNS, never how
                // the load proceeds.
                opLogLoadLog.error("""
                    Could not record set-aside lines from \
                    \(url.lastPathComponent, privacy: .public): \
                    \(String(describing: error), privacy: .public).
                    """)
            }
        }
        return (classified.ops, classified.diagnostics, classified.provenance)
    }

    /// The project root a `.maugham/ops/<file>` URL sits under.
    private nonisolated static func projectRoot(of url: URL) -> URL {
        url.deletingLastPathComponent()      // .maugham/ops
            .deletingLastPathComponent()     // .maugham
            .deletingLastPathComponent()     // the project
    }

    // MARK: - Classification (the one rule both readers obey)

    /// What one file turned out to be, and what the reader that can write is
    /// asked to do about it. Pure over the bytes plus two READS (this device's
    /// remembered head and verified-segment memory, and the signature sidecar
    /// beside a segment) — so the coordinated reader and the synchronous one
    /// can call the same function and cannot disagree about which ops a
    /// document is made of. Only the coordinated one performs the side effects.
    struct FileClassification {
        let ops: [Op]
        let diagnostics: ParseDiagnostics
        let provenance: FileProvenance
        /// The walk this classification came out of, when there was one —
        /// what it kept, what it held back, and why. Nil only where a segment
        /// failed before any line could be walked. The reader that can WRITE
        /// hands it to `JSONLAppendStore.setAside`, which owns both the record
        /// and the words for it.
        let verification: OpLogChain.Verification?
        /// Non-nil when this device may now adopt the file's head as its own
        /// (the crash window: a remembered head no line in the file hashes to,
        /// in a file that holds together and whose every seal is ours).
        let adoptedHead: String?
        /// Non-nil when a segment's signature settled it for the first time and
        /// the digest is worth remembering.
        let verifiedSegmentDigest: String?
    }

    nonisolated static func classify(
        url: URL, bytes: Data, identities: LocalIdentities?, state: OpLogDeviceState?
    ) -> FileClassification {
        url.pathExtension == OpLogSegment.fileExtension
            ? classifySegment(url: url, container: bytes, identities: identities, state: state)
            : classifyTail(url: url, bytes: bytes, identities: identities, state: state)
    }

    /// A live `.jsonl` tail: verified against this device's remembered head,
    /// with everything the walk quarantined held back.
    private nonisolated static func classifyTail(
        url: URL, bytes: Data, identities: LocalIdentities?, state: OpLogDeviceState?
    ) -> FileClassification {
        let fileKey = OpLogDeviceState.fileKey(url)
        // Trusted is EVERY actor on this device: the assistant's seal over the
        // assistant's own file is this device's word, and a trust set of one
        // fingerprint would file the writer's own MCP history under "another
        // device's unsigned history" in the History pane.
        let trusted = identities?.fingerprints ?? []
        let walked = OpLogChain.verify(
            bytes: bytes,
            trusted: { trusted.contains($0) },
            rememberedHead: state?.head(for: fileKey))

        // The adopt rule (spec §4.2's crash window) and its converse, both in
        // `OpLogChain.resolveAbsentHead` — the one place that decides what a
        // missing remembered head means, shared with the chained WRITE so a
        // load cannot hold back lines the next append would chain onto.
        let (verification, adopted) = OpLogChain.resolveAbsentHead(
            walked,
            rememberedHead: state?.head(for: fileKey),
            previousHead: state?.previousHead(for: fileKey))

        let parsed = JSONLAppendStore<Op>.parse(
            bytes: JSONLAppendStore<Op>.applied(verification, whole: bytes),
            dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })

        return FileClassification(
            ops: parsed.elements,
            diagnostics: parsed.diagnostics,
            provenance: provenance(
                name: url.lastPathComponent, lines: verification.lines,
                isSealedSegment: false, segmentVerified: nil),
            verification: verification,
            adoptedHead: adopted,
            verifiedSegmentDigest: nil)
    }

    /// A sealed `.mzseg` segment. Immutable bytes with a digest already inside
    /// them, so the question is asked once and then remembered: does a
    /// signature this device trusts name this digest? If so the segment's lines
    /// are settled WHOLE and never walked again. If not — a foreign signature,
    /// no signature at all, a segment minted before this milestone — the lines
    /// are walked keylessly, which still catches a break.
    private nonisolated static func classifySegment(
        url: URL, container: Data, identities: LocalIdentities?, state: OpLogDeviceState?
    ) -> FileClassification {
        let decoded = OpLogSegment.decodeVerifying(container)
        var skipped: [ParseDiagnostics.SkippedLine] = []
        if let failure = decoded.failure {
            skipped.append(.init(
                byteOffset: 0,
                raw: "<segment \(url.lastPathComponent): \(failure)>"))
        }
        guard let jsonl = decoded.jsonl else {
            return FileClassification(
                ops: [], diagnostics: ParseDiagnostics(skipped: skipped),
                provenance: FileProvenance(
                    name: url.lastPathComponent,
                    isSealedSegment: true, segmentVerified: false),
                verification: nil,
                adoptedHead: nil, verifiedSegmentDigest: nil)
        }

        // Only a container that verified may be keyed on: the digest a file
        // CARRIES is the digest a tamperer would leave alone.
        let digest = decoded.isVerified ? decoded.digest : nil
        var settled = false
        var toRemember: String?
        if let digest {
            if state?.isVerified(segmentDigest: digest) == true {
                settled = true
            } else if let identities,
                      let signature = SegmentSignature.read(
                          at: segmentSignatureURL(for: url)),
                      signature.digest == digest,
                      identities.fingerprints.contains(signature.key),
                      signature.verifies() {
                settled = true
                toRemember = digest
            }
        }

        let parsedAll = JSONLAppendStore<Op>.parse(
            bytes: jsonl, dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
        if settled {
            // Per-line skips inside a segment only matter when the container
            // itself verified (otherwise the container record covers it) — and
            // a settled segment always verified.
            skipped.append(contentsOf: parsedAll.diagnostics.skipped)
            let lines = nonEmptyLineCount(jsonl)
            return FileClassification(
                ops: parsedAll.elements,
                diagnostics: ParseDiagnostics(skipped: skipped),
                provenance: FileProvenance(
                    name: url.lastPathComponent, verified: lines,
                    isSealedSegment: true, segmentVerified: true),
                verification: nil,
                adoptedHead: nil, verifiedSegmentDigest: toRemember)
        }

        let read = JSONLAppendStore<Op>.verifiedParse(
            bytes: jsonl, trusted: { _ in false }, rememberedHead: nil,
            dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
        if decoded.isVerified {
            skipped.append(contentsOf: read.diagnostics.skipped)
        }
        return FileClassification(
            ops: read.elements,
            diagnostics: ParseDiagnostics(skipped: skipped),
            provenance: provenance(
                name: url.lastPathComponent, lines: read.verification.lines,
                isSealedSegment: true, segmentVerified: false),
            verification: read.verification,
            adoptedHead: nil, verifiedSegmentDigest: nil)
    }

    /// How many non-blank lines these bytes hold — counted, never SPLIT.
    ///
    /// The settled-segment branch needs this number and nothing else from the
    /// bytes, and `split(separator:)` over a five-megabyte segment allocates one
    /// `Data` slice per line to answer it. On the 50,000-line fixture that was
    /// the single largest cost the chain added to a load, for a count.
    private nonisolated static func nonEmptyLineCount(_ bytes: Data) -> Int {
        bytes.withUnsafeBytes { raw -> Int in
            var count = 0
            var inLine = false
            for byte in raw {
                if byte == 0x0A {
                    if inLine { count += 1; inLine = false }
                } else {
                    inLine = true
                }
            }
            return inLine ? count + 1 : count
        }
    }

    /// The counts, taken off the LINES themselves rather than off the walk's
    /// own tallies — one place decides what each class means, and a new state
    /// on `OpLogChain.Line` is a compile error here rather than a silent zero.
    private nonisolated static func provenance(
        name: String, lines: [OpLogChain.Line],
        isSealedSegment: Bool, segmentVerified: Bool?
    ) -> FileProvenance {
        var legacy = 0, verified = 0, unsealed = 0, unsignedHistory = 0, quarantined = 0
        for line in lines {
            switch line.state {
            case .legacy: legacy += 1
            case .verified: verified += 1
            case .unsealed: unsealed += 1
            case .unsignedHistory: unsignedHistory += 1
            // A torn last line is in no provenance class: it was never
            // applied as history and it was never held back either. The
            // element decoder reports it in `diagnostics.skipped`, which is
            // the channel a torn line has always used.
            case .tornTail: break
            case .quarantined: quarantined += 1
            }
        }
        return FileProvenance(
            name: name, legacy: legacy, verified: verified, unsealed: unsealed,
            unsignedHistory: unsignedHistory, quarantined: quarantined,
            isSealedSegment: isSealedSegment, segmentVerified: segmentVerified)
    }

    /// Append to the writer's own per-device file, keyed by `op.device`.
    ///
    /// The write is chained (spec §3) **only when the op is this device's own**:
    /// it verifies the file's tail against this device's remembered head first,
    /// sets aside anything it did not write, and links the new line to what it
    /// kept. Every `chainSealInterval` lines it also asks for a seal, which is
    /// what turns a run of chained lines into history this device has signed.
    ///
    /// **A device string this device holds no key for takes the plain,
    /// unchained append.** An op self-describes the device that made it, and
    /// the write target is derived from that string. In the ordinary case that
    /// is another Mac's ops arriving through sync; it was also, until P1b's Mac
    /// rewiring, every op carrying a SENTINEL, which lands in a file every Mac
    /// derives the same name for. Such a file is the single exception to ADR
    /// 0012's one-writer-per-file premise, and the chained append's rewrite step
    /// is licensed by exactly that premise: chaining it would have each Mac set
    /// aside and TRUNCATE the other's ops, and tell the writer their own second
    /// machine is "something that is not Maugham". A device chains only its own
    /// files; anything else is appended to, never rewritten. Whether any
    /// sentinel still reaches here is a grep, never this sentence.
    public func append(_ op: Op) async throws {
        if let injected = appendFailureForTesting { throw injected }
        let slug = DeviceSlug.make(from: op.device)
        // WHICH of this device's writers made this op — the whole id, never a
        // prefix: another Mac's author carries `author-` too, and adopting one
        // would have this device chain and seal a file it does not own.
        let signer = identities.identity(forDeviceId: op.device)
        try await store(
            forDocId: op.docId, deviceSlug: slug, signer: signer
        ).append(op)

        guard let signer else {
            opLogLoadLog.notice("""
                An op naming a device that is not this device's was written \
                unchained to \
                \(Self.opLogFileURL(forDocId: op.docId, deviceSlug: slug, in: self.projectURL)
                    .lastPathComponent, privacy: .public): \
                its device (\(op.device, privacy: .public)) is not this one, so \
                the file has more than one writer and must not be rewritten.
                """)
            return
        }

        let url = Self.opLogFileURL(forDocId: op.docId, deviceSlug: slug, in: projectURL)
        let count = (linesSinceSeal[url] ?? 0) + 1
        linesSinceSeal[url] = count
        guard count >= Self.chainSealInterval else { return }
        // The cadence belongs to the FILE, so the seal it triggers is that
        // file's — signed by the actor who just wrote into it, not by the
        // author on everyone's behalf, and not spread over four files because
        // one of them filled up.
        if try await sealChain(docId: op.docId, by: signer) { linesSinceSeal[url] = 0 }
    }

    /// How many chained lines this device writes into a file before it seals
    /// them. A seal is one signature over the whole run, so the interval trades
    /// signing cost against how much of the tail is merely chained (tamper-
    /// EVIDENT) rather than sealed (tamper-evident and signed).
    ///
    /// `nonisolated` for `segmentSealThreshold`'s reason: an immutable
    /// `Sendable` `Int` that touches no actor state.
    public nonisolated static let chainSealInterval = 100

    /// Seal this device's own live tail for `docId`: one signature over the
    /// chain head, committing to every line since the last seal.
    ///
    /// Answers whether a seal was written. False is the ordinary answer on a
    /// device with no key and on a file with nothing new — neither is an error,
    /// and neither throws.
    ///
    /// **`__project__` is sealed here and rotated by the open sweep** (since
    /// 2026-09-09). The two verbs are still different acts: this one SIGNS a
    /// run of lines in place, `sealTailIfNeeded` REWRITES the tail into an
    /// immutable segment. Neither refuses the project stream any more, so the
    /// project's task log is signed history like every other tail AND bounded
    /// like every other tail — the seal is what `ProjectStore._projectOpLogStore`
    /// exists to make possible, the rotation is `DocumentStore.open`'s.
    /// **One seal per local actor THIS STORE has written to since that file's
    /// last seal** (P1b, narrowed by the whole-branch review's I1). A device is
    /// four writers with four files, and a seal signs a run of lines in ONE of
    /// them; sealing only the author's would leave everything the assistant,
    /// the translator and Maugham itself wrote chained but never signed.
    ///
    /// The decision is the in-memory `linesSinceSeal` counter and nothing else,
    /// because "has this file anything unsealed?" is not a cheap question to
    /// ask the file. `appendSeal` opens an `NSFileCoordinator` writing
    /// coordination, reads the whole file and runs a full `OpLogChain.verify`
    /// over it BEFORE it can discover there is nothing to sign — so a fan-out
    /// over four actors at every burst boundary is three extra coordinated
    /// acquisitions, three extra whole-file reads and three extra verifies on
    /// the writer's own keystroke path, on a document Claude has annotated. The
    /// counter already knows the answer for free.
    ///
    /// What the counter cannot know is another actor's file this store never
    /// touched — a crash-window leftover, or a tail an MCP call in a different
    /// store grew. Those are sealed by their own writer's cadence, by that
    /// writer's own close, and by the open-time sweep, which is why this can be
    /// the narrow verb. The sweep's own store has no counters at all and asks
    /// for `sealChain(docId:actor:)` instead.
    @discardableResult
    public func sealChain(docId: String) async throws -> Bool {
        var sealed = false
        for actor in identities.all {
            let url = Self.opLogFileURL(
                forDocId: docId, deviceSlug: actor.slug, in: projectURL)
            guard (linesSinceSeal[url] ?? 0) > 0 else { continue }
            if try await sealChain(docId: docId, by: actor) { sealed = true }
            linesSinceSeal[url] = 0
        }
        return sealed
    }

    /// Seal one named actor's tail for `docId`, whatever this store may or may
    /// not have written to it.
    ///
    /// The counter-free door, for a store that has no counters to consult: the
    /// project-open sweep builds a fresh `OpLogStore` for maintenance and asks
    /// for the AUTHOR's tail alone (P1's shape), because a crash-window
    /// leftover of the writer's is the case it exists for and the other three
    /// actors' leftovers are sealed on their own next write. Naming the actor
    /// mints its key if this device has never used it, so the caller should
    /// name one it means.
    ///
    /// Answers false — never throws — when the actor has no file here.
    @discardableResult
    public func sealChain(docId: String, actor: DeviceActor) async throws -> Bool {
        let identity = identities[actor]
        let url = Self.opLogFileURL(
            forDocId: docId, deviceSlug: identity.slug, in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let sealed = try await sealChain(docId: docId, by: identity)
        if sealed { linesSinceSeal[url] = 0 }
        return sealed
    }

    /// One local actor's own tail for `docId`, sealed with that actor's key.
    @discardableResult
    private func sealChain(docId: String, by actor: DeviceIdentity) async throws -> Bool {
        try await store(
            forDocId: docId, deviceSlug: actor.slug, signer: actor
        ).appendSeal()
    }

    /// The append store for one (docId, slug) file. `signer` is the ONE place
    /// the policy is attached, and `append` is the one place that decides it —
    /// a device chains only its own files, and signs each with the key of the
    /// actor that owns it. Nil signer is the plain, unchained store.
    private func store(
        forDocId docId: String, deviceSlug: DeviceSlug, signer: DeviceIdentity?
    ) -> JSONLAppendStore<Op> {
        JSONLAppendStore<Op>(
            fileURL: Self.opLogFileURL(forDocId: docId, deviceSlug: deviceSlug, in: projectURL),
            presenter: presenter,
            dedupKey: { $0.opId },
            sortedBy: { $0.opId < $1.opId },
            chain: signer.map {
                ChainPolicy(
                    identity: $0, state: deviceState,
                    docId: docId, projectURL: projectURL,
                    trustedFingerprints: identities.fingerprints)
            })
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
    /// Scope rules (enforced by tests T13/T14): only ever a tail belonging to
    /// one of THIS device's own actors — sealing is a rewrite of a
    /// single-writer file, the exact case ADR 0012 makes conflict-twin-free.
    /// NEVER the legacy unsuffixed `<docId>.jsonl` (no unambiguous owner;
    /// frozen since ADR 0012), and never another device's file. The synthetic
    /// `__project__` stream is not an exception: it rotates at this same
    /// threshold (Denver, 2026-09-09 — one constant, not two).
    ///
    /// **Its two callers, and why each is inside that rule** (the whole-branch
    /// review's I3). `Document.close()` rotates the tail of the actor that
    /// Document was LOADED as, and no other: an MCP call is a Document loaded
    /// as the assistant, and a close that swept all four would delete the file
    /// the writer's own open Document is appending to. The project-open sweep
    /// in `DocumentStore.open` is the one place every local actor rotates, and
    /// it is safe there for two reasons that do not hold at close — all four
    /// slugs name this device's own actors, and the sweep is awaited before the
    /// first `Document.load`, so no live appender exists to race the
    /// read→delete gap the note below reasons about. That sweep is also the
    /// project stream's ONLY boundary: `__project__` has no close to rotate at,
    /// so open is its moment.
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

        // 2b. Sign the segment's digest, beside the segment. Best-effort for
        //     the same reason the seal itself is maintenance rather than truth:
        //     a device with no key signs nothing, a failed write leaves a
        //     segment that reads as unsigned history, and neither may cost the
        //     writer the rotation their tail needs.
        // The sidecar carries the key of the actor whose slug this segment
        // is named for — the same key that sealed the lines inside it. A slug
        // naming no local actor gets no signature at all: nothing on this
        // device may vouch for another device's bytes.
        if let signer = identities.all.first(where: { $0.slug == deviceSlug }),
           signer.canSign {
            do { try Self.writeSegmentSignature(
                    for: segURL, jsonl: bytes, identity: signer) }
            catch {
                opLogLoadLog.error("""
                    Could not sign segment \
                    \(segURL.lastPathComponent, privacy: .public): \
                    \(String(describing: error), privacy: .public). \
                    It will read as unsigned history.
                    """)
            }
        }

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

    /// The signature beside a sealed segment: the segment's own name with
    /// `.sig` appended, so it sorts next to it and `opLogFileURLs` — which
    /// matches on `.jsonl` and `.mzseg` endings — can never list it as history.
    /// SINGLE SOURCE OF TRUTH for the sidecar's name.
    public nonisolated static func segmentSignatureURL(for segmentURL: URL) -> URL {
        segmentURL.deletingLastPathComponent()
            .appendingPathComponent(segmentURL.lastPathComponent + ".sig")
    }

    /// Sign a freshly minted segment's digest and write the sidecar beside it.
    ///
    /// Throws on a device with no key and on a failed write. Both are conditions
    /// the SEAL is required to survive — the caller logs and carries on, and a
    /// segment with no signature is unsigned history rather than a refusal.
    @discardableResult
    nonisolated static func writeSegmentSignature(
        for segmentURL: URL, jsonl: Data, identity: DeviceIdentity, at: Date = Date()
    ) throws -> URL {
        let digest = OpLogSegment.hex(Data(SHA256.hash(data: jsonl)))
        let signature = try SegmentSignature.make(
            digest: digest, identity: identity, at: at)
        let url = segmentSignatureURL(for: segmentURL)
        try signature.encoded().write(to: url, options: .atomic)
        return url
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
    /// The synchronous reader classifies exactly as the coordinated one does —
    /// same `classify`, same applied set — and writes NOTHING: no quarantine
    /// record, no remembered head, no verified digest. It is a reader with no
    /// presenter and no writer's authority, so it simply omits what it will not
    /// apply. That the two agree is not a matter of care; it is the same
    /// function called twice, and `OpLogVerifiedLoadTests` pins it anyway,
    /// because this is the reader MCP's `read_document` and the Practice walk
    /// see a closed manuscript through.
    public nonisolated static func loadSyncMerged(
        forDocId docId: String, in projectURL: URL,
        identities: LocalIdentities? = .current,
        state: OpLogDeviceState? = .shared
    ) throws -> [Op] {
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
            ops.append(contentsOf: classify(
                url: url, bytes: data, identities: identities, state: state).ops)
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
