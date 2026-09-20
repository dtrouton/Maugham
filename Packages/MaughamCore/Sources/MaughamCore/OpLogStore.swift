// Maugham/OpLog/OpLogStore.swift  (now in MaughamCore)
import CryptoKit
import Foundation
import os

/// Diagnostic channel for the two things a LOAD can fail at without failing:
/// recording the lines it set aside, and signing a segment it just minted.
/// Neither may cost the writer their manuscript, so neither throws — and a
/// silent best-effort is only honest if it says so somewhere.
/// `internal` since P3a Task 5's fix round 1: `OpLogPermitContext` reports a
/// manifest it could not read through the same channel the load already uses.
let opLogLoadLog = Logger(
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
        state: OpLogDeviceState = .shared,
        cache: RegistryCache? = nil
    ) {
        self.projectURL = projectURL
        self.presenter = presenter
        self.identities = identities
        self.deviceState = state
        self.registryCache = cache
    }

    /// The registry memory this store reconciles against — `nil` means the
    /// process-wide one, resolved only if a registry folder actually exists, so
    /// a project that never joined a chain touches neither the cache nor this
    /// machine's keys.
    private let registryCache: RegistryCache?

    /// Who this device trusts in this project, and the shape of the registry
    /// folder it was resolved from.
    ///
    /// Kept rather than resolved per file: re-reading the registry for every
    /// file of a thirty-file glob would cost a verified read of the whole
    /// folder thirty times over. Kept with a SIGNATURE rather than forever,
    /// because spec §4.1 promises that admitting a device applies its held ops
    /// on the next read — not on the next store — and a table cached for the
    /// life of a window would make the admission sheet quietly do nothing.
    private var resolvedTrust: (signature: String, table: TrustTable)?

    /// The table, re-resolving it whenever the registry folder has changed
    /// since the one in hand was built.
    ///
    /// **Resolved off the main actor.** This class is `@MainActor` and the
    /// resolution is a folder read plus a P256 verification per record, so it
    /// goes to a detached task; the comparison that usually makes it
    /// unnecessary is a few stats and stays here. The presenter is deliberately
    /// not carried across: it presents this document's own files, and no
    /// registry record is one of them.
    ///
    /// Throws what the resolution throws: a registry record that is present and
    /// unreadable refuses the load rather than quietly un-admitting whoever it
    /// names (RULING-54).
    func trust() async throws -> TrustTable {
        let signature = TrustResolution.signature(of: projectURL)
        if let resolvedTrust, resolvedTrust.signature == signature {
            return resolvedTrust.table
        }
        let projectURL = self.projectURL
        let identities = self.identities
        let cache = self.registryCache
        let table = try await Task.detached(priority: .userInitiated) {
            try TrustResolution.resolve(
                projectURL: projectURL, identities: identities, cache: cache)
        }.value
        resolvedTrust = (signature, table)
        return table
    }

    /// **The same table, resolved ON this actor rather than off it** (P3a
    /// Task 8).
    ///
    /// `trust()`'s detached hop is the right shape for a READ, which is already
    /// deep in file I/O and has a suspension either way. It is the wrong shape
    /// for a question asked BEFORE the load's first write: an added suspension
    /// point in `Document.load` is a behaviour change on every document open —
    /// `ProjectStore.withStatementDocument`'s own comment is about a pane
    /// binding mid-load, and a bare `await Task.yield()` inserted there fails
    /// `PromotionPerformerTests.test_promotingWhileTheIntentPaneIsOpen…` with
    /// nothing else changed. `ProjectStore+Annotations` resolves on the main
    /// actor for the same kind of reason, and states it.
    ///
    /// The cost is a folder read plus a P256 verify per record, once per store
    /// — **which in production is once per document OPEN**, because
    /// `Document.makeLoadOpStore` builds a store per load. It is stored under
    /// the same signature `trust()` compares, so the read that follows finds it
    /// warm and does not resolve again; the caller that wants only a permit
    /// (`localWritePermit`) asks nothing at all of a project with no register.
    /// Pre-warming it somewhere longer-lived is deliberately NOT done here —
    /// the cost is Task 10's to measure before anybody moves it.
    func trustOnThisActor() throws -> TrustTable {
        let signature = TrustResolution.signature(of: projectURL)
        if let resolvedTrust, resolvedTrust.signature == signature {
            return resolvedTrust.table
        }
        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: identities, cache: registryCache)
        resolvedTrust = (signature, table)
        return table
    }

    /// Forget the resolved table, so the next read builds a fresh one.
    ///
    /// The signature check above catches a registry that changed on disk, but a
    /// caller that JUST changed it — the admission sheet writing a person
    /// record — should say so rather than hope a modification time moved far
    /// enough to be seen.
    public func invalidateTrust() { resolvedTrust = nil }

    /// **May this device's own hand write here, and what?** — the ONE question
    /// asked before a line exists (P3a Task 8).
    ///
    /// The load seam asks it of `.bootstrap`, of the pending-recovery burst and
    /// of a task anchor; P3c's membrane will ask it of a keystroke. One
    /// function so the two cannot answer differently, and on this store because
    /// this is where the verified table already is — resolving a second one per
    /// document would be a folder read and a P256 verify per record, per open.
    ///
    /// **It never throws, and that is the point.** `trust()` refuses on a
    /// registry record that is present and unreadable (RULING-54), and a load
    /// that asks this question must not start refusing over one where it did
    /// not before (constitution must #1). The fallback is the keyless table,
    /// which is P1's behaviour exactly — this device's own keys, nobody else's,
    /// no events, so the answer is *yes* — and the caller that goes on to READ
    /// will meet the same refusal through its own door with its own sentence.
    ///
    /// `documentClass` is a CLOSURE because resolving one means decoding a
    /// manifest, and the neutral case never needs it: a permit that covers the
    /// whole book answers `.yes` in the hardest class there is, so the closure
    /// is not called at all. `PermitPartition`'s `unowned` is the same shape
    /// for the same reason.
    public func localWritePermit(
        as actor: DeviceActor = .author,
        documentClass: () -> DocumentClass
    ) -> LocalWritePermit {
        // **A project that has never had a register pays nothing at all** — not
        // a folder read, not a verify, not a question. The test is
        // `verifiedRegistry`'s own first one, asked through its own spelling:
        // the FOLDER or this device's MEMORY of one, because a register deleted
        // wholesale is restored from that memory and treating its absence as
        // *no register* would make deleting one an escape from a demotion.
        let permit = registerTable().map(\.myTimeline.current) ?? .bookAuthor
        if LocalWritePermit.answersWithoutTheClass(permit, as: actor) {
            return LocalWritePermit(permit: permit, actor: actor, documentClass: nil)
        }
        return LocalWritePermit(
            permit: permit, actor: actor, documentClass: documentClass())
    }

    /// **The verified table, or nil where this project has never had a
    /// register at all** — the one question `localWritePermit` and
    /// `annotationAmendments` both open with, spelled once (P3a Task 6).
    ///
    /// A project with no register pays nothing — not a folder read, not a
    /// verify, not a question. The test is `verifiedRegistry`'s own first one,
    /// asked through its own spelling: the FOLDER or this device's MEMORY of
    /// one, because a register deleted wholesale is restored from that memory
    /// and treating its absence as *no register* would make deleting one an
    /// escape from a demotion.
    ///
    /// **It never throws, and that is the point.** `trust()` refuses on a
    /// registry record that is present and unreadable (RULING-54), and a load
    /// that asks these questions must not start refusing over one where it did
    /// not before (constitution must #1). The caller that goes on to READ will
    /// meet the same refusal through its own door with its own sentence.
    private func registerTable() -> TrustTable? {
        guard TrustResolution.hasAnythingToResolve(
            in: projectURL, cache: registryCache) else { return nil }
        do { return try trustOnThisActor() }
        catch {
            // **Forget the folder, not this device** (fix round 1's I2), and
            // through the one spelling every reader shares since fix round 2's
            // minor 2 — `TrustResolution.rememberedOrKeyless`, which carries
            // the reasoning.
            return TrustResolution.rememberedOrKeyless(
                projectURL: projectURL, identities: identities,
                cache: registryCache)
        }
    }

    /// **Whose annotation it is, for this document** (P3a Task 6, spec §4.2's
    /// last paragraph) — `localWritePermit`'s sibling, and neutral in the same
    /// way.
    ///
    /// The deriver is pure and holds no register, so the rule is resolved here,
    /// once, where the verified table already is — resolving a second one per
    /// annotation-cache rebuild would be a folder read and a P256 verify per
    /// record on a keystroke-adjacent path.
    ///
    /// A project with no register answers `honourEverything`, which is the
    /// pre-P3a behaviour exactly.
    /// `permits` is what the LOAD collected — the permit each amendment line
    /// was judged under, as of that line (`AmendmentPermits`). Empty is the
    /// honest answer for a book with no events and for a caller that did not
    /// ask, and an amendment with no entry falls back to the signer's current
    /// permit, which is what those cases mean.
    public func annotationAmendments(
        permits: [String: Permit] = [:],
        documentClass: @escaping @Sendable () -> DocumentClass
    ) -> AnnotationAmendments {
        guard let table = registerTable() else { return .honourEverything }
        return .judged(by: table, permits: permits, class: documentClass)
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
    ///
    /// `amendmentPermits` is P3a Task 6's second product and is **opt-in**: a
    /// caller that means to judge annotation amendments as of their own line
    /// hands one over and reads it afterwards; everybody else passes nothing
    /// and nothing is recorded. See `AmendmentPermits`.
    public func loadDiagnosed(
        docId: String, amendmentPermits: AmendmentPermits? = nil
    ) async throws -> (ops: [Op], diagnostics: ParseDiagnostics, provenance: OpLogProvenance)
    {
        let urls = Self.opLogFileURLs(forDocId: docId, in: projectURL)
        guard !urls.isEmpty else { return ([], ParseDiagnostics(), OpLogProvenance()) }
        let table = try await trust()
        // **The permit partition's two document-level answers** (P3a Task 5).
        // One context for the whole document: its class is resolved at most
        // once however many per-actor files the history is spread across, and
        // not at all in a book with no permit events.
        let permit = Self.permitContext(
            forDocId: docId, in: projectURL, trust: table,
            amendments: amendmentPermits)
        var merged: [Op] = []
        var skipped: [ParseDiagnostics.SkippedLine] = []
        var files: [FileProvenance] = []
        // One watch for the whole document: a stream is a run of segments plus
        // a tail, and whether its remembered line is still anywhere in it can
        // only be asked once every file has been seen (P3a Task 9).
        let foreign = ForeignStreamWatch(
            projectURL: projectURL, state: deviceState,
            mine: ForeignStreamWatch.slugs(of: identities))
        for url in urls {
            let result = try await Self.loadFileDiagnosed(
                url: url, presenter: presenter,
                identities: identities, state: deviceState, trust: table,
                permit: permit, foreign: foreign)
            merged.append(contentsOf: result.ops)
            skipped.append(contentsOf: result.diagnostics.skipped)
            files.append(result.provenance)
        }
        foreign.settle()
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
    ///
    /// **It carries no `ForeignStreamWatch`, and that is deliberate** (P3a
    /// Task 9). This rung's whole purpose is to answer over the files that DID
    /// read, so a stream whose tail it could not open looks exactly like a
    /// stream whose tail is short — and the memory taken from it would record a
    /// truncation that is really a permissions error. A memory of where another
    /// device stood is taken from the STRICT load or not at all.
    public func loadDiagnosedPartial(docId: String) async -> PartialOpLogLoad {
        var all: [Op] = []
        var skipped: [ParseDiagnostics.SkippedLine] = []
        var unreadable: [CheckpointLoad.UnreadableFile] = []
        var files: [FileProvenance] = []
        // A resolution that throws is the registry being unreadable, which is a
        // fact about the PROJECT and not about one file — so this rung does not
        // refuse the whole document over it. It does not SWALLOW it either:
        // RULING-54's rule is that an unreadable file is named, and this is a
        // load rather than an integrity check, so the record joins the
        // unreadable list beside whatever op-log files could not be opened and
        // the read goes on judging nobody.
        let table: TrustTable
        do { table = try await trust() }
        catch {
            unreadable.append(.init(
                name: Self.unreadableName(error),
                reason: error.localizedDescription))
            table = TrustResolution.keyless(mine: identities)
        }
        let permit = Self.permitContext(
            forDocId: docId, in: projectURL, trust: table)
        for url in Self.opLogFileURLs(forDocId: docId, in: projectURL) {
            do {
                let result = try await Self.loadFileDiagnosed(
                    url: url, presenter: presenter,
                    identities: identities, state: deviceState, trust: table,
                    permit: permit)
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
        /// **Which durable store the file belongs to** (P2a D0). ONE error
        /// kind rather than one error type per store: a writer meeting the
        /// same condition twice must meet the same sentence, and the only
        /// things that legitimately differ are the noun for the file and what
        /// Maugham is refusing to do over it. A store that grows a chained
        /// JSONL of its own adds a case here rather than an error of its own.
        public enum FileKind: Equatable, Sendable {
            /// The per-device op log under `.maugham/ops/` — the manuscript
            /// itself, and the surface RULING-54 was named for.
            case history
            /// A per-(device, actor) translation sidecar under
            /// `.maugham/translations/`. Since P1b a document's translation is
            /// spread over several of these, which is why one that will not
            /// open cannot be stepped over.
            case translation
            /// A signed record under `.maugham/people/` or `.maugham/devices/`
            /// (P2a). The odd one out of the three: it holds none of the
            /// writer's words, it belongs to the PROJECT rather than to one
            /// manuscript, and what a half-read registry costs is not text but
            /// the answer to who wrote this book — so every clause below
            /// differs for it, not only the noun.
            case registry

            /// The writer's own word for the file.
            var noun: String {
                switch self {
                case .history: return "history file"
                case .translation: return "translation file"
                case .registry: return "registry record"
                }
            }

            /// Whose file it is — the phrase the sentence opens with.
            var owner: String {
                switch self {
                case .history, .translation: return "The manuscript's"
                case .registry: return "This project's"
                }
            }

            /// What is safe, said in the terms of what the file actually holds.
            var reassurance: String {
                switch self {
                case .history, .translation: return "Your words are intact inside it"
                case .registry: return "None of your writing is in it"
                }
            }

            /// What the writer reopens once they have fixed the file.
            var reopens: String {
                switch self {
                case .history, .translation: return "the document"
                case .registry: return "the project"
                }
            }

            /// What Maugham is refusing to do rather than read a short answer.
            var refusal: String {
                switch self {
                case .history:
                    return "Maugham won't open a shortened version over it."
                case .translation:
                    return "Maugham won't show or publish a partial translation over it."
                case .registry:
                    return "Maugham won't decide who may write in this book "
                         + "from records it could only half read."
                }
            }
        }

        /// `kind` defaults to `.history`, so every op-log throw site — the
        /// original ones and any added later — keeps its own wording without
        /// having to say so.
        case unreadableFile(name: String, underlying: String, kind: FileKind = .history)
        case unlistableOpsDirectory(underlying: String)
        /// **A directory the MARK sweep must see exists and will not list**
        /// (P3a Task 7, fix round 1). `.maugham/translations` and
        /// `.maugham/inbox` — the ops folder has its own case above, with its
        /// own sentence about a second parallel history.
        ///
        /// It is an error rather than an empty listing because of what an
        /// omission MEANS to a mark: a stream a mark does not name is judged
        /// wholly NEW, so a sweep that quietly saw nothing draws the line at
        /// the very beginning of everything it missed. For a revocation that
        /// sets aside words this Mac HAD applied — strictly more destructive
        /// than the opId path it replaced, in the one direction find-5's
        /// ruling forbids. For a demotion it reaches back through the whole
        /// stream.
        case unlistableStreamDirectory(name: String, underlying: String)
        /// **A stream the caller said must be found was not** (P3a Task 7's
        /// hook for Task 9). A file simply ABSENT at sweep time — evicted by
        /// iCloud, halfway through a sync — is indistinguishable from a stream
        /// that never existed unless somebody remembers it; the caller that
        /// remembers says so through `expectedStreams`, and this is the answer.
        case streamMissingFromSweep(streamKey: String)
        public var errorDescription: String? {
            switch self {
            case .unreadableFile(let name, let underlying, let kind):
                return "\(kind.owner) \(kind.noun) “\(name)” exists but can't be read (\(underlying)). "
                     + "\(kind.reassurance) — check the file's permissions or wait for "
                     + "iCloud to finish syncing, then reopen \(kind.reopens). \(kind.refusal)"
            case .unlistableOpsDirectory(let underlying):
                return "The manuscript's history folder (.maugham/ops) exists but can't be listed "
                     + "(\(underlying)). Check its permissions, then reopen — opening without it "
                     + "would start a second, parallel history."
            case .unlistableStreamDirectory(let name, let underlying):
                return "The folder “\(name)” exists but can't be listed (\(underlying)). "
                     + "Your words are intact inside it — check its permissions or wait for "
                     + "iCloud to finish syncing. Maugham won't decide what a device may "
                     + "write from a reading it knows is short."
            case .streamMissingFromSweep(let streamKey):
                return "Part of this device's history (“\(streamKey)”) is one Maugham has "
                     + "read before and can't find now — most often iCloud has moved it "
                     + "out of the way. Nothing was changed; try again once it is back."
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
    // `internal` rather than `private` since P3a Task 5: `unownedPiece`'s
    // second pass reads the document's other files through the same door, so
    // the coordination policy stays one decision.
    nonisolated static func readCoordinated(
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

    /// `trust` is who this device judges the file's seals by. Nil is the
    /// KEYLESS reader — `ProjectIntegrity.check`, and anything else that
    /// inspects a project without opening it — which holds no key and judges
    /// nobody, so every seal it meets is somebody's unsigned history.
    ///
    /// `foreign` is P3a Task 9's memory of where OTHER devices' streams stood,
    /// and it is the LOAD path's alone for `state`'s own reason: a check that
    /// classifies keylessly forms a weaker picture than a load, and a memory
    /// taken from it would be a memory of a reading nobody acted on. It is
    /// carried as a collector rather than returned, because the decision is
    /// about a STREAM and this function sees one FILE of one — the caller
    /// settles it once every file of the document has been observed.
    public static func loadFileDiagnosed(
        url: URL, presenter: NSFilePresenter?,
        identities: LocalIdentities? = nil, state: OpLogDeviceState? = nil,
        trust: TrustTable? = nil, permit: PermitContext? = nil,
        foreign: ForeignStreamWatch? = nil
    ) async throws -> (ops: [Op], diagnostics: ParseDiagnostics, provenance: FileProvenance) {
        guard let bytes = try readCoordinated(url: url, presenter: presenter) else {
            return ([], ParseDiagnostics(),
                    FileProvenance(name: url.lastPathComponent,
                                   isSealedSegment: url.pathExtension == OpLogSegment.fileExtension))
        }
        let classified = classify(
            url: url, bytes: bytes, state: state, trust: trust, permit: permit)

        // **Where another device's stream stood** (P3a Task 9). An observation
        // and not a write: the watch settles the whole document's worth at
        // once, so a chapter spread over four foreign files costs one rewrite
        // of the state file rather than four.
        foreign?.observe(
            url: url, verification: classified.verification,
            segmentDigest: classified.wholeSegmentDigest)

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
                    verification,
                    from: url, docId: docId,
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

    /// **The highest opId this project APPLIES from one device, anywhere in
    /// it** — the revocation mark, computed with no main-actor hop (find-5
    /// review, the two Mediums).
    ///
    /// Nil when this project applies nothing of theirs; it THROWS when a file
    /// is present and will not read, because a mark that silently came back
    /// short would quietly widen what a revocation takes back. The caller turns
    /// that into a refusal rather than into a number
    /// (`OpLogStore.unreadableName` names the file).
    ///
    /// **Applied, not merely present.** Each file is classified with the same
    /// trust table a load would use, so a line the reader refuses or holds is
    /// not counted as something this device had got to.
    ///
    /// **Read-only in fact, not merely in intent.** `state: nil` and
    /// `identities: nil` are both passed, which is what stops the walk writing
    /// forensic records, adopting heads or remembering segment digests over
    /// forty chapters nobody has opened as a side effect of asking a question
    /// about one device. The remembered head is not lost by it: this device
    /// keeps one only for files it has WRITTEN, and the files that matter here
    /// are the revoked device's.
    ///
    /// `nonisolated` and taking no presenter, so the whole sweep — the listing
    /// included — runs off the main actor. It only reads, so there is no write
    /// of this process's own for a presenter to keep from bouncing back.
    nonisolated public static func highestAppliedOpId(
        ofDeviceIds ids: Set<String>, in projectURL: URL, trust: TrustTable?
    ) throws -> String? {
        guard !ids.isEmpty else { return nil }
        let opsDir = projectURL.appendingPathComponent(".maugham/ops")
        let filenames = (try? FileManager.default
            .contentsOfDirectory(atPath: opsDir.path)) ?? []
        var docIds = docIds(inOpsDirectoryFilenames: filenames)
        // Named, because the manuscript reader excludes it by contract — the
        // same reason the project-open sweep names it when it rotates tails.
        docIds.insert("__project__")

        // **The permit partition runs here too** (P3a Task 5): a refused line
        // is not *applied*, and a mark that counted one would record a
        // position this Mac never reached. Resolved once for the whole sweep.
        let statements = manifestStatements(in: projectURL)
        var highest: String?
        for docId in docIds.sorted() {
            let permit = permitContext(
                forDocId: docId, in: projectURL, trust: trust,
                statements: statements)
            for url in opLogFileURLs(forDocId: docId, in: projectURL) {
                guard let bytes = try readCoordinated(url: url, presenter: nil)
                else { continue }
                let classified = classify(
                    url: url, bytes: bytes, state: nil, trust: trust,
                    permit: permit)
                for op in classified.ops where ids.contains(op.device) {
                    if highest == nil || op.opId > highest! { highest = op.opId }
                }
            }
        }
        return highest
    }

    /// **Where in each of this device's streams the reader had got to** — the
    /// P3 mark, and `highestAppliedOpId`'s sibling in every respect but what it
    /// answers (spec §3.3).
    ///
    /// Same listing, same `classify` with `state: nil` and `identities`
    /// unreachable, so it is read-only in fact and not merely in intent: it
    /// writes no forensic record, adopts no head, and remembers no segment
    /// digest over forty chapters nobody has opened. It THROWS for the same
    /// reason its sibling does — a mark that silently came back short would
    /// quietly move a permission boundary — and the caller turns that into a
    /// refusal rather than into a position.
    ///
    /// **What it records, per stream** (`PermitMark.stream(of:)` names them):
    ///
    /// - the digest of every SEGMENT the reader took in whole;
    /// - the `OpLogChain.lineHash` of the last APPLIED line of the live
    ///   `.jsonl` tail — never a held-back line, never a quarantined one,
    ///   never a torn one.
    ///
    /// **`applied` here is the word it says**, and that is what makes this the
    /// REVOCATION's question and not the permit's: *Revoke, keeping what this
    /// Mac already had* means the lines that are in the draft the writer has
    /// been reading. `seenPositions` is the other question — see it for why
    /// one answer cannot serve both acts.
    ///
    /// **The last line is taken from the TAIL and no other file, which is what
    /// keeps this free of any ordering.** A stream is a run of sealed segments
    /// plus one tail, and only the tail is still being appended to; the
    /// segments are whole and are named by digest. So nothing here has to
    /// decide which file came after which — and nothing may, because a segment
    /// index is part of a filename and a filename is the writer's to choose.
    ///
    /// **The known gap, stated rather than hidden:** a segment that neither
    /// settled nor could be walked through to its last line contributes no
    /// digest, so lines inside it judge as *new* later. That is the strict
    /// side of the format the spec fixes — a mark can say *this whole segment*
    /// or *up to this line*, and such a segment is neither.
    ///
    /// `nonisolated` and presenter-free, so the whole sweep runs off the main
    /// actor; it only reads, so there is no write of this process's own for a
    /// presenter to keep from bouncing back.
    nonisolated public static func appliedPositions(
        ofDeviceIds ids: Set<String>, in projectURL: URL, trust: TrustTable?,
        expectedStreams: Set<String> = []
    ) throws -> PermitMark {
        try positions(
            ofDeviceIds: ids, in: projectURL, trust: trust,
            expectedStreams: expectedStreams
        ) { line in
            !line.state.isHeldBack && line.state != .tornTail
        }
    }

    /// **Where in each of this device's streams the reader had READ TO** — the
    /// position a PERMIT event records (spec §3.3, corrected in P3a Task 5's
    /// fix round 2).
    ///
    /// **A mark does not bless lines; it selects which PERMIT judges them.**
    /// At or before the position the OLD permit decides, after it the NEW one.
    /// Once that is the rule, *the last line the root APPLIED* is the wrong
    /// position, and it is wrong in both directions whenever refused or held
    /// lines sit at the END of what the root had read:
    ///
    /// - **A promotion becomes a pardon.** Sam is a reviewer and the tail of
    ///   her file ends in manuscript text this Mac refused. The root promotes
    ///   her. The last APPLIED line is before that text, so the text judges
    ///   NEW — under her new author permit — and is applied. Spec §5 forbids
    ///   exactly that.
    /// - **A demotion reaches back.** A segment holding a thousand honestly
    ///   applied lines and one refused line is not *wholly applied*, so it
    ///   would go unlisted, so all thousand judge NEW — under the demoted
    ///   permit — and are refused retroactively.
    ///
    /// So the position is the last line the root **saw and judged**: the last
    /// line the chain verified, whatever the partition then did with it —
    /// applied, refused by the permit, or held. Lines the root refused under
    /// the old permit stay under the old permit and stay refused; lines it
    /// applied stay applied. Nothing is blessed either way, because the
    /// refusal is re-derived from the permit rather than read off the mark.
    ///
    /// **Two things are not *seen*.** A torn tail line is a write that stopped
    /// mid-line — bytes nobody finished, let alone judged. And everything a
    /// broken chain quarantined: the root never trusted those bytes, so it
    /// never formed an opinion about what they said.
    ///
    /// A SEGMENT the reader took in whole is listed by digest **whether or not
    /// any of its lines were refused**, for the same reason: the digest says
    /// *the root read this whole file*, not *the root applied all of it*.
    nonisolated public static func seenPositions(
        ofDeviceIds ids: Set<String>, in projectURL: URL, trust: TrustTable?,
        expectedStreams: Set<String> = []
    ) throws -> PermitMark {
        try positions(
            ofDeviceIds: ids, in: projectURL, trust: trust,
            expectedStreams: expectedStreams, lastLine: wasSeen)
    }

    /// Did the reader see and JUDGE this line? — `seenPositions`' predicate,
    /// and the one place the two exclusions are spelled.
    nonisolated static func wasSeen(_ line: OpLogChain.Line) -> Bool {
        if line.state == .tornTail { return false }
        if case .chainBroke = line.refusal { return false }
        return true
    }

    /// **The walk both position sweeps share.** They differ in one thing and
    /// it is the `lastLine` predicate: what counts as the last line of a tail.
    /// Everything else — the listing, the classification, the segment rule,
    /// the read-only guarantee, the throw — is one implementation, because two
    /// copies of it would be two answers to *which files are this device's*.
    ///
    /// **Three families of stream, not one** (P3a Task 6). A mark names a
    /// person's `<docId>.<slug>` op streams, their `translation:…` sidecars and
    /// their `inbox:<slug>` manifests, because those last two answer to the
    /// same permit and `PermitMark.judge` asks the mark by stream key: a stream
    /// the mark does not name is judged wholly NEW, so leaving the translation
    /// and inbox families out would make every demotion reach back through
    /// every translation and every capture the subject had ever written. The
    /// families share the predicate and the read-only guarantee; they differ in
    /// how a file is walked, which is what `verificationForPositions` holds.
    ///
    /// **A short answer is a refusal, never a shorter mark** (fix round 1, I2).
    /// A stream the mark does not name is judged wholly NEW, so every way of
    /// failing to SEE a stream is a way of drawing the line at the beginning
    /// of it — which for a revocation sets aside words this Mac had applied
    /// and for a demotion reaches back through the whole file. So: a directory
    /// that exists and will not list throws (`listing(of:naming:)` tells that
    /// from a directory that is simply not there), a file that is present and
    /// will not read throws (`readCoordinated`, RULING-54), and every verb
    /// that marks turns either into its own *nothing was changed* refusal.
    ///
    /// **`expectedStreams` is the third way, and it is a caller's to supply.**
    /// A file that is simply ABSENT — evicted by iCloud, halfway through a
    /// sync — looks exactly like a stream that never existed, and nothing in
    /// this function can tell them apart. A caller that REMEMBERS which
    /// streams it has applied says so here and gets
    /// `ReadError.streamMissingFromSweep` naming the first one missing. P3a
    /// supplies nothing (the memory is Task 9's), and the default is empty, so
    /// this costs today's callers a set comparison over an empty set.
    private nonisolated static func positions(
        ofDeviceIds ids: Set<String>, in projectURL: URL, trust: TrustTable?,
        expectedStreams: Set<String> = [],
        lastLine: (OpLogChain.Line) -> Bool
    ) throws -> PermitMark {
        guard !ids.isEmpty else { return .nothingApplied }
        // A device's files are named for its SLUG, and `DeviceSlug.make` is
        // deterministic, so which files are the subject's is decided here
        // rather than by reading ops out of them — a file whose every line is
        // held back still has a position, and a legacy shared file has none.
        let slugs = Set(ids.map { DeviceSlug.make(from: $0).raw })
        let opsDir = projectURL.appendingPathComponent(".maugham/ops")
        // **Listed ONCE** (fix round 2, minor D). This used to call
        // `verifyOpsDirectoryListable` and then list the folder again for the
        // names, which is two directory reads per sweep for one question — and
        // the sentence that came with the first is about a LOAD starting a
        // second parallel history, which is not what a mark sweep is doing.
        // `listing` answers both halves: empty where the folder is not there,
        // a throw where it is there and will not read.
        let filenames = try listing(of: opsDir, naming: ".maugham/ops")
        try refuseAnyPlaceholder(
            among: filenames, in: opsDir, forSlugs: slugs, kind: .history)
        var docIds = docIds(inOpsDirectoryFilenames: filenames)
        // Named, because the manuscript reader excludes it by contract — the
        // same reason the project-open sweep names it when it rotates tails.
        docIds.insert("__project__")

        let statements = manifestStatements(in: projectURL)
        var segments: [String: Set<String>] = [:]
        var lastKnownLine: [String: String] = [:]
        for docId in docIds.sorted() {
            let permit = permitContext(
                forDocId: docId, in: projectURL, trust: trust,
                statements: statements)
            for url in opLogFileURLs(forDocId: docId, in: projectURL) {
                guard let stream = PermitMark.stream(of: url),
                      let slug = stream.deviceSlug, slugs.contains(slug)
                else { continue }
                guard let bytes = try readCoordinated(url: url, presenter: nil)
                else { continue }
                let classified = classify(
                    url: url, bytes: bytes, state: nil, trust: trust,
                    permit: permit)
                if url.pathExtension == OpLogSegment.fileExtension {
                    // **The one answer to *did this reader take the segment in
                    // whole*** (Task 9's fix round 1). It used to be computed
                    // here, by a SECOND decode of a container `classify` had
                    // already decoded; it is now the classification's own
                    // `wholeSegmentDigest`, which is also what the foreign
                    // stream memory records — and two spellings of it would be
                    // a stream that memory expects and this mark can never
                    // name, which is a root's verb refusing for ever.
                    if let digest = classified.wholeSegmentDigest {
                        segments[stream.key, default: []].insert(digest)
                    }
                    continue
                }
                guard let verification = classified.verification,
                      let last = verification.lines.last(where: lastLine)
                else { continue }
                lastKnownLine[stream.key] = OpLogChain.lineHash(last.bytes)
            }
        }

        // The other two families. Neither rotates — `sealTailIfNeeded` is the
        // op log's alone — so there is no segment rule here and no digest to
        // record, only the last line the reader got to in each file.
        for url in try otherStreamFileURLs(in: projectURL, forSlugs: slugs) {
            guard let stream = PermitMark.stream(of: url),
                  let slug = stream.deviceSlug, slugs.contains(slug),
                  let bytes = try readCoordinated(url: url, presenter: nil)
            else { continue }
            let verification = verificationForPositions(
                at: url, bytes: bytes, stream: stream, trust: trust)
            guard let last = verification.lines.last(where: lastLine) else { continue }
            lastKnownLine[stream.key] = OpLogChain.lineHash(last.bytes)
        }

        var marks: [String: PermitMark.StreamMark] = [:]
        for key in Set(segments.keys).union(lastKnownLine.keys) {
            // Sorted, because `opLogFileURLs` is UNSORTED and a mark two
            // devices compare byte for byte must not depend on what
            // `contentsOfDirectory` felt like saying.
            marks[key] = .init(
                segments: segments[key].map { $0.sorted() } ?? [],
                line: lastKnownLine[key])
        }
        // Sorted, so a sweep missing two streams refuses over the same one
        // twice running and the writer is not chasing a different name each
        // time they press.
        if let missing = expectedStreams.subtracting(marks.keys).sorted().first {
            throw ReadError.streamMissingFromSweep(streamKey: missing)
        }
        return PermitMark(marks)
    }

    /// Every translation sidecar and inbox manifest in this project, in a
    /// stable order (P3a Task 6). Whose they are is decided by the caller off
    /// `PermitMark.stream(of:)`'s slug, exactly as it is for the op streams.
    ///
    /// A directory that is NOT THERE answers empty — a book with no
    /// translations has no such folder and there is nothing to mark. A
    /// directory that exists and **will not list** throws (fix round 1, I2):
    /// the two used to be one `try?`, and the second of them produced a mark
    /// that silently omitted every stream in the folder, which is a mark that
    /// judges every line of them NEW.
    private nonisolated static func otherStreamFileURLs(
        in projectURL: URL, forSlugs slugs: Set<String>
    ) throws -> [URL] {
        var out: [URL] = []
        for (directory, name, kind) in [
            (TranslationStore.directoryURL(in: projectURL),
             ".maugham/translations", ReadError.FileKind.translation),
            (projectURL.appendingPathComponent(".maugham/inbox"),
             ".maugham/inbox", ReadError.FileKind.history),
        ] {
            let names = try listing(of: directory, naming: name)
            try refuseAnyPlaceholder(
                among: names, in: directory, forSlugs: slugs, kind: kind)
            out.append(contentsOf: names.sorted()
                .filter { $0.hasSuffix(".jsonl") }
                .map { directory.appendingPathComponent($0) })
        }
        return out
    }

    /// **The real name an old-style iCloud placeholder stands in for**, or nil
    /// where the name is not one (P3a Task 7, fix round 2, minor B).
    ///
    /// macOS evicts a file's contents and leaves `.<name>.icloud` beside it —
    /// dot-prefixed, `.icloud`-suffixed, and named for nothing this app's own
    /// filename rules recognise. The sweep's suffix filters
    /// (`hasSuffix(".jsonl")`, `docIds(inOpsDirectoryFilenames:)`) therefore
    /// drop it, and a dropped stream is an ABSENT stream, which a mark does
    /// not name, which judges every line of it NEW. It is I2's hole with no
    /// unreadable folder needed — an evicted chapter is enough.
    ///
    /// A dataless file under its REAL name is already caught, by
    /// `readCoordinated` throwing when the bytes will not come; this is the
    /// shape that has no real name to throw over.
    nonisolated static func nameBehindICloudPlaceholder(_ filename: String) -> String? {
        let placeholder = ".icloud"
        guard filename.hasPrefix("."), filename.hasSuffix(placeholder) else { return nil }
        let real = filename.dropFirst().dropLast(placeholder.count)
        return real.isEmpty ? nil : String(real)
    }

    /// **A placeholder standing in for one of these devices' streams is
    /// present-but-unreadable**, and refuses the sweep by the real file's name.
    ///
    /// It is the same ruling as an unreadable file and the same refusal
    /// (RULING-54: present and unreadable is never silently skipped). The
    /// writer's next move is the same too — wait for iCloud, or open the
    /// document to pull it down.
    ///
    /// **This is the SWEEP's rule and nothing else's.** What a LOAD does with
    /// a placeholder is `RecoveryCause`'s and is untouched: a load can offer to
    /// wait and download, where a sweep has only the choice between refusing
    /// and signing a boundary over a reading it knows is short.
    ///
    /// Sorted, so a folder holding two refuses over the same name twice
    /// running and the writer is not chasing a different file each press.
    private nonisolated static func refuseAnyPlaceholder(
        among names: [String], in directory: URL,
        forSlugs slugs: Set<String>, kind: ReadError.FileKind
    ) throws {
        for name in names.sorted() {
            guard let real = nameBehindICloudPlaceholder(name),
                  let stream = PermitMark.stream(of: directory.appendingPathComponent(real)),
                  let slug = stream.deviceSlug, slugs.contains(slug)
            else { continue }
            throw ReadError.unreadableFile(
                name: real,
                underlying: "it hasn’t been downloaded from iCloud yet",
                kind: kind)
        }
    }

    /// One translation sidecar or inbox manifest, walked exactly as its own
    /// READER walks it — verify, resolve the absent head, then the permit.
    ///
    /// The same three steps `TranslationStore.loadMerged` and
    /// `JSONLAppendStore.loadVerifiedStrict` take, with ONE difference and it
    /// is deliberate: the remembered head is not consulted (`rememberedHead:
    /// nil`). A mark has to be computable from the shared bytes alone — that is
    /// the whole of spec §3.3, and the reason a mark is not an opId — so a
    /// position that moved with what THIS device happened to remember would
    /// make two Macs cut the same file in two places. `state: nil` throughout
    /// for the same reason and one more: this remembers nothing and writes
    /// nothing.
    private nonisolated static func verificationForPositions(
        at url: URL, bytes: Data, stream: PermitMark.Stream, trust: TrustTable?
    ) -> OpLogChain.Verification {
        let walked = trust.map { table in
            OpLogChain.verify(
                bytes: bytes, trust: { table.verdict(forSealKey: $0) },
                rememberedHead: nil,
                // Arm 2 here too, so both sweeps judge a file the way the LOAD
                // judges it. **It moves `appliedPositions` and not
                // `seenPositions`**: a held or verdict-refused line was seen
                // and judged — `wasSeen` excludes only a torn tail and what a
                // broken chain quarantined — so a mark recording where the
                // root had READ TO is unchanged, while one recording what it
                // APPLIED correctly stops counting a span this device holds.
                // The lookup is over the shared REGISTER, so it moves with the
                // bytes and not with what this Mac happens to remember, which
                // is the whole of spec §3.3 and the reason the remembered head
                // is skipped just above.
                keyOfAnUnsealedFile: { PermitMark.keyNaming(url, in: table) })
        } ?? OpLogChain.verify(
            bytes: bytes, trusted: { _ in false }, rememberedHead: nil)
        let (resolved, _) = OpLogChain.resolveAbsentHead(
            walked, rememberedHead: nil, previousHead: nil)
        guard let trust else { return resolved }
        let judge: PermitJudge
        switch stream.kind {
        case .translation: judge = .translation(ofPiece: stream.docId, trust: trust)
        case .inbox: judge = .inbox(trust: trust)
        case .ops: return resolved
        }
        return PermitPartition.partition(of: resolved, file: url, judging: judge)
    }

    /// **A foreign stream this device has found shorter than it remembered
    /// it**, with the device named the way every other finding names one
    /// (P3a Task 9, spec §4.7).
    public struct TruncatedStream: Equatable, Sendable {
        public let truncation: OpLogDeviceState.StreamTruncation
        /// The writer's word for whose stream it was: the label the root gave
        /// them, else their four-character code, else — with no table to ask —
        /// the slug their files are named for.
        public let label: String

        public var streamKey: String { truncation.streamKey }
        public var deviceSlug: String { truncation.deviceSlug }
        public var noticedAt: Date { truncation.noticedAt }

        /// **What went missing, in the writer's words** — and the two losses
        /// are different enough to say apart (fix round 1, minor 1).
        ///
        /// A LINE loss is the live tail having been cut back; a SEGMENT loss
        /// is a whole sealed span of history that is not in the folder any
        /// more. Neither takes a word out of the draft — what was applied
        /// stays applied — so both sentences end the same way, pointing at the
        /// one place a writer can get the lost history back from.
        public var sentence: String {
            let what = truncation.loss == .segment
                ? "part of \(label)’s sealed history is missing from this book"
                : "\(label)’s history here is shorter than it was"
            return "\(what.prefix(1).uppercased())\(what.dropFirst()). "
                + "Nothing has left the draft — every word Maugham had already "
                + "applied is still in it — but what is gone is gone from the "
                + "folder. A backup is where it can be got back from."
        }

        public init(truncation: OpLogDeviceState.StreamTruncation, label: String) {
            self.truncation = truncation
            self.label = label
        }
    }

    /// **What this device has noticed going missing from other devices'
    /// streams**, oldest first — P3b's History entry and the integrity
    /// report's own finding, read from one place.
    ///
    /// It reads a memory and touches no file of the project: the finding was
    /// recorded at the load that met it, because a load is the only reader
    /// that ever held both the remembered line and the bytes that no longer
    /// carry it.
    ///
    /// `trust` is optional for the reason the keyless readers exist: a caller
    /// that already holds a verified table names the device, and one that
    /// holds none — `ProjectIntegrity.check` — still names the stream, which is
    /// the fact the writer acts on.
    nonisolated public static func truncatedStreams(
        in projectURL: URL, state: OpLogDeviceState, trust: TrustTable? = nil
    ) -> [TruncatedStream] {
        state.truncations(inRoot: projectURL).map { truncation in
            TruncatedStream(
                truncation: truncation,
                label: trust?.label(forDeviceSlug: truncation.deviceSlug)
                    ?? truncation.deviceSlug)
        }
    }

    /// The file a `ReadError` names, for a caller that reports unreadable
    /// files by name and has caught something that might not be one.
    nonisolated public static func unreadableName(_ error: Error) -> String {
        if case let ReadError.unreadableFile(name, _, _) = error { return name }
        // A DIRECTORY that would not list, and a stream that was there before
        // and is not now, are both things a verb refuses over (P3a Task 7's
        // fix round 1) — and the writer's next move turns on which file it
        // was, so each names itself rather than falling through to the
        // registry.
        if case let ReadError.unlistableStreamDirectory(name, _) = error { return name }
        if case ReadError.unlistableOpsDirectory = error { return ".maugham/ops" }
        if case let ReadError.streamMissingFromSweep(streamKey) = error { return streamKey }
        return "the project's registry"
    }

    /// **Every name in a directory — or nothing, where the directory is not
    /// there** (P3a Task 7, fix round 1).
    ///
    /// The distinction is the whole of it. A book with no translations has no
    /// `.maugham/translations`, and that is not a failure: there is nothing to
    /// mark. A directory that EXISTS and will not list is a short answer
    /// wearing the same clothes, and `(try? …) ?? []` cannot tell them apart —
    /// which is how a mark came to omit a stream and, by omitting it, judge
    /// every line of it NEW.
    ///
    /// The existence check runs AFTER the failure rather than before it, so an
    /// ordinary listing costs one syscall and the discriminator is paid only
    /// where something has already gone wrong.
    private nonisolated static func listing(
        of directory: URL, naming name: String
    ) throws -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch {
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            throw ReadError.unlistableStreamDirectory(
                name: name, underlying: error.localizedDescription)
        }
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
        /// **The digest of a segment this reader took in WHOLE** — P3a Task
        /// 9's fix round 1, and the ONE answer to that question.
        ///
        /// Whole means every line of it reached a verdict, not that every line
        /// was applied: a mark's `segments` list says *the root read this whole
        /// file*, and a later reader uses it to decide which PERMIT judges the
        /// lines inside, never to decide that they were allowed.
        ///
        /// Two ways in. A container that SETTLED was taken in whole by
        /// definition — that is the claim a segment signature makes, and it is
        /// the same claim this device's memory of the digest makes one load
        /// later. One that did not settle is walked instead, and counts only
        /// if the walk reached the END of it: a chain that broke inside means
        /// the reader never trusted the bytes after the break, so it did not
        /// read the file whole and must not say it did. A container that did
        /// not verify is nil, because the digest a file CARRIES is the digest
        /// a tamperer leaves alone.
        ///
        /// It lives here rather than beside each caller because there are two
        /// of them — the mark sweep and the foreign-stream memory — and a
        /// disagreement between them is a stream the memory expects and the
        /// mark can never name, which is a root's verb refusing for ever.
        let wholeSegmentDigest: String?
    }

    /// `permit` is the P3a partition's two document-level answers (spec §4.1,
    /// §4.5). **Nil is the explicit *do not judge*** — the keyless readers,
    /// which pass no table either, and `unownedPiece`'s own second pass, which
    /// is what stops it recursing.
    nonisolated static func classify(
        url: URL, bytes: Data,
        state: OpLogDeviceState?, trust: TrustTable? = nil,
        permit: PermitContext? = nil
    ) -> FileClassification {
        url.pathExtension == OpLogSegment.fileExtension
            ? classifySegment(
                url: url, container: bytes, state: state,
                trust: trust, permit: permit)
            : classifyTail(
                url: url, bytes: bytes, state: state,
                trust: trust, permit: permit)
    }

    /// **The permit partition, in the one place both classify paths reach it**
    /// (P3a Task 5, spec §4.3) — `readmittingWhatWasAlreadyApplied`'s sibling,
    /// and run immediately after it.
    ///
    /// The order is verify → revocation split → permit partition → parse, and
    /// every step of it has to be before the parse: a line this refuses must
    /// never reach the element decoder, and a line it holds must never reach
    /// the document.
    ///
    /// The two are never folded. A revocation is a verdict about a whole KEY,
    /// cut on a mark the root recorded; a permit is about one LINE, judged
    /// against the history its signer had when the line was written. Running
    /// this second means it judges what the revocation left applied, which is
    /// the only order in which both answers survive.
    ///
    /// With no table or no context there is nothing to ask, so a keyless
    /// reader is unchanged — P1's behaviour exactly.
    private nonisolated static func partitioningByPermit(
        _ verification: OpLogChain.Verification,
        url: URL, trust: TrustTable?, permit: PermitContext?,
        fileSegmentDigest: String? = nil, settledByKey: String? = nil
    ) -> OpLogChain.Verification {
        guard let trust, let permit else { return verification }
        // **The class travels as the CLOSURE it is** (fix round 1, I1), inside
        // the `PermitJudge`. Calling it here would make it an argument,
        // evaluated before the partition's own first guard — a manifest read
        // and decode for every op-log file of every book, including a
        // registerless one that then judges nothing.
        return PermitPartition.partition(
            of: verification, file: url,
            judging: PermitJudge(trust: trust, context: permit),
            fileSegmentDigest: fileSegmentDigest, settledByKey: settledByKey)
    }

    /// A live `.jsonl` tail: verified against this device's remembered head,
    /// with everything the walk quarantined held back.
    ///
    /// It takes no `identities`, for the same reason `classifySegment` does not:
    /// the only question it ever asked of them — is this key ours — is the
    /// table's. A parameter still here would let a future caller pass keys and
    /// no table and silently judge nobody where P1 judged its own.
    private nonisolated static func classifyTail(
        url: URL, bytes: Data,
        state: OpLogDeviceState?, trust: TrustTable?,
        permit: PermitContext? = nil
    ) -> FileClassification {
        let fileKey = OpLogDeviceState.fileKey(url)
        // The table answers `.mine` for EVERY actor on this device — the
        // assistant's seal over the assistant's own file is this device's word,
        // and a trust set of one fingerprint would file the writer's own MCP
        // history under "another device's unsigned history" in the History
        // pane — and, since P2a, `.admitted` for the devices this device's root
        // took in, `.stranger` for a key it can say nothing about (held), and
        // `.revoked`/`.otherRoot` for a key it refuses.
        //
        // With no identities there is no table to build: that reader holds no
        // key, judges nobody, and every seal it meets is unsigned history.
        let walked = trust.map {
            table in
            OpLogChain.verify(
                bytes: bytes,
                trust: { table.verdict(forSealKey: $0) },
                rememberedHead: state?.head(for: fileKey),
                // **Arm 2 of *the file's key*** (Task 11). A file with no
                // usable seal still has a name, and the name's slug is the one
                // thing about it this device can match against a signed
                // record. Lazy: `verify` asks only when something is unsealed
                // and no seal in the file named it first.
                keyOfAnUnsealedFile: { PermitMark.keyNaming(url, in: table) })
        } ?? OpLogChain.verify(
            bytes: bytes,
            trusted: { _ in false },
            rememberedHead: state?.head(for: fileKey))

        // The adopt rule (spec §4.2's crash window) and its converse, both in
        // `OpLogChain.resolveAbsentHead` — the one place that decides what a
        // missing remembered head means, shared with the chained WRITE so a
        // load cannot hold back lines the next append would chain onto.
        let (verification, adopted) = OpLogChain.resolveAbsentHead(
            walked,
            rememberedHead: state?.head(for: fileKey),
            previousHead: state?.previousHead(for: fileKey))

        // **The revocation cut, BEFORE the parse** (find 5, ruled 2026-09-18).
        // The walk refuses a revoked key's span whole and says why; which of
        // those lines this Mac had already applied is told by opId, a number
        // the ROOT recorded when it revoked somebody and which the walk — seals
        // and chains, never ops — is deliberately ignorant of. Here is where
        // both are in hand, and it has to happen before `applied` builds the
        // bytes the parser sees, or a line the revocation keeps never reaches
        // the document.
        let readmitted = readmittingWhatWasAlreadyApplied(
            verification, url: url, trust: trust)
        // **Then the permit, line by line** (P3a Task 5). It judges what the
        // revocation left applied; see `partitioningByPermit`.
        let settled = partitioningByPermit(
            readmitted, url: url, trust: trust, permit: permit)

        let parsed = JSONLAppendStore<Op>.parse(
            bytes: JSONLAppendStore<Op>.applied(settled, whole: bytes),
            dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })

        return FileClassification(
            ops: parsed.elements,
            diagnostics: parsed.diagnostics,
            provenance: provenance(
                name: url.lastPathComponent, lines: settled.lines,
                isSealedSegment: false, segmentVerified: nil, trust: trust),
            verification: settled,
            adoptedHead: adopted,
            verifiedSegmentDigest: nil,
            // A live tail is not a segment and carries no digest at all.
            wholeSegmentDigest: nil)
    }

    /// **What a revocation keeps** — `RevocationSplit`'s answer applied to a
    /// walk, and the one place the two classify paths ask it (find 5).
    ///
    /// A live tail and a rotated segment must agree about what a revocation
    /// costs. Before this, only the tail was split at all, so the same
    /// device's history read one way in `.jsonl` and another in `.mzseg` —
    /// the live-tail-versus-segment asymmetry P2b Task 10 closed for the
    /// keyless walk, re-opened one rule along.
    ///
    /// With no table there is no mark and nothing to ask, so a keyless reader
    /// is unchanged: it holds no key, judges nobody, and never meets
    /// `.afterRevocation` at all.
    ///
    /// **Two forms of the same line** (P3a Task 7). Where the register holds a
    /// revocation EVENT for that person, the cut is by chain POSITION —
    /// tamper-proof, because an opId carries a timestamp its own writer chose
    /// and a device shut out could stamp new text with an old one. Where it
    /// does not — every revocation on disk before P3 — the opId path is
    /// untouched, which is what keeps the P2 suite passing without an edit.
    ///
    /// The judgement is computed **once per person** and only for a person
    /// whose revocation carries a map, so a book with no events hashes nothing
    /// here and a book with one hashes a file's lines once, not once per line.
    private nonisolated static func readmittingWhatWasAlreadyApplied(
        _ verification: OpLogChain.Verification,
        url: URL, trust: TrustTable?, fileSegmentDigest: String? = nil
    ) -> OpLogChain.Verification {
        // **The quarantine short-circuit, restated here as a COST guard** (fix
        // round 1, minor 4). `RevocationSplit.partition` makes the same check
        // first, but it makes it after this function has already parsed the
        // file's name into a stream key — on every file of every load, for a
        // question that only arises where something was refused.
        guard let trust, !verification.quarantined.isEmpty else { return verification }
        let streamKey = PermitMark.stream(of: url)?.key
        var judged: [String: PermitMark.Judgement] = [:]
        let split = RevocationSplit.partition(of: verification) { person in
            if let streamKey, let mark = trust.revocationMark(forPerson: person) {
                if let already = judged[person] { return .byPosition(already) }
                let judgement = mark.judge(
                    streamKey: streamKey,
                    fileIsSegmentWithDigest: fileSegmentDigest,
                    lines: verification.lines.map(\.bytes))
                judged[person] = judgement
                return .byPosition(judgement)
            }
            return trust.highestOpIdSeen(forPerson: person).map(RevocationSplit.Cut.byOpId)
        }
        guard let split else { return verification }
        return OpLogChain.readmitting(verification, lines: split.readmitted)
    }

    /// A sealed `.mzseg` segment. Immutable bytes with a digest already inside
    /// them, so the question is asked once and then remembered: does a
    /// signature this device trusts name this digest? If so the segment's lines
    /// are settled WHOLE and never walked again. If not — a foreign signature,
    /// no signature at all, a segment minted before this milestone — the lines
    /// are walked keylessly, which still catches a break.
    ///
    /// It takes no `identities`: the two questions it once asked of them — is
    /// this signature ours, and is this key trusted — are both the table's now.
    private nonisolated static func classifySegment(
        url: URL, container: Data,
        state: OpLogDeviceState?, trust: TrustTable?,
        permit: PermitContext? = nil
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
                adoptedHead: nil, verifiedSegmentDigest: nil,
                // The container did not decode, so there is no digest to
                // believe and nothing to say this file was read whole.
                wholeSegmentDigest: nil)
        }

        // Only a container that verified may be keyed on: the digest a file
        // CARRIES is the digest a tamperer would leave alone.
        let digest = decoded.isVerified ? decoded.digest : nil
        var settled = false
        var toRemember: String?
        if let digest {
            if state?.isVerified(segmentDigest: digest) == true {
                settled = true
            } else if let trust,
                      let signature = SegmentSignature.read(
                          at: segmentSignatureURL(for: url)),
                      signature.digest == digest,
                      // A segment is settled WHOLE, so the only verdicts that
                      // can settle one are the two that are a word this device
                      // stands behind. A stranger's segment falls through to
                      // the keyless walk below rather than being held: holding
                      // is a per-SPAN decision the walk makes, and a segment
                      // that never settled is walked line by line anyway.
                      trust.verdict(forSealKey: signature.key)
                          .isOurWord(sealedAt: signature.at),
                      signature.verifies() {
                settled = true
                toRemember = digest
            }
        }

        // **What the partition would judge this settled segment by** — built
        // once, and only where a partition is actually due (fix round 1, I4).
        // A container whose signature settled it is never walked, so the lines
        // have to be constructed and the signing key read back off the `.sig`
        // beside it; `settledSegmentVerification` does both or answers nil.
        // **And only where the partition could refuse something in a file
        // named like this one** (fix round 3, minor 1). The gate used to be
        // *a permit context exists*, which is every load: a no-events book's
        // author segment whose `.sig` had gone missing was walked for nothing,
        // and a walk can reach answers the fast path never would.
        let mayJudge = permit != nil && trust.map {
            PermitPartition.couldJudge(
                aFileNamedBy: PermitMark.stream(of: url)?.deviceSlug, trust: $0)
        } ?? false
        let attributable = (settled && mayJudge)
            ? settledSegmentVerification(at: url, bytes: container) : nil
        // **A digest this device remembers, with the `.sig` beside it since
        // DELETED, does not get the fast path.** It used to fall through and
        // apply the whole segment unjudged: demote Sam with a mark inside her
        // rotated segment, let this Mac load once so the digest is remembered,
        // then delete her `.mzseg.sig` in the shared folder, and her post-mark
        // manuscript text comes back. Walking instead costs a walk — for a
        // file whose signature has gone missing — and the walk's own inner
        // seals attribute every span correctly, which is the answer that needs
        // no memory at all.
        if settled, mayJudge, attributable == nil { settled = false }

        let parsedAll = JSONLAppendStore<Op>.parse(
            bytes: jsonl, dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
        if settled {
            // Per-line skips inside a segment only matter when the container
            // itself verified (otherwise the container record covers it) — and
            // a settled segment always verified.
            skipped.append(contentsOf: parsedAll.diagnostics.skipped)
            // **A settled segment is partitioned too** (P3a Task 5). The
            // container's signature settles the whole file at once, so there
            // are no inner seals to read a verdict off and the key that signed
            // it is the key every line is under. Skipping this would let a
            // demoted device escape the partition by ROTATING — maintenance a
            // device performs on itself, silently pardoning it, which is P2b
            // Task 10's asymmetry one rule along.
            //
            // The lines are built (and the bytes split) only where a permit
            // context was supplied; the neutral fast path is untouched, and
            // `AREA.md`'s performance note 2 still holds for it.
            //
            // The signing key comes from `settledSegmentVerification`'s own
            // read of the sidecar rather than from the branch above, because
            // this file may have settled from MEMORY
            // (`isVerified(segmentDigest:)`) on a second load, and a remembered
            // digest carries no key.
            //
            // Where that read cannot be made, `settled` was cleared above and
            // this branch is not reached at all (fix round 1, I4).
            if let trust, permit != nil, let digest, let built = attributable {
                let partitioned = partitioningByPermit(
                    built.verification, url: url, trust: trust, permit: permit,
                    fileSegmentDigest: digest, settledByKey: built.key)
                if partitioned != built.verification {
                    let read = JSONLAppendStore<Op>.parse(
                        bytes: JSONLAppendStore<Op>.applied(partitioned, whole: jsonl),
                        dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
                    return FileClassification(
                        ops: read.elements,
                        diagnostics: ParseDiagnostics(skipped: skipped),
                        provenance: provenance(
                            name: url.lastPathComponent, lines: partitioned.lines,
                            isSealedSegment: true, segmentVerified: true,
                            trust: trust),
                        verification: partitioned,
                        adoptedHead: nil, verifiedSegmentDigest: toRemember,
                        wholeSegmentDigest: digest)
                }
            }
            let lines = nonEmptyLineCount(jsonl)
            return FileClassification(
                ops: parsedAll.elements,
                diagnostics: ParseDiagnostics(skipped: skipped),
                provenance: FileProvenance(
                    name: url.lastPathComponent, verified: lines,
                    isSealedSegment: true, segmentVerified: true),
                verification: nil,
                adoptedHead: nil, verifiedSegmentDigest: toRemember,
                // A segment that settled was taken in whole by definition —
                // whether by its own signature or by this device's memory of
                // its digest, which is the SAME claim one load later. Under
                // the mark sweep, which passes no state, the two coincide.
                wholeSegmentDigest: digest)
        }

        // **The fallback walk judges by the TABLE too** (P2b Task 10).
        //
        // A segment that did not settle whole is walked line by line, and until
        // now that walk was keyless — every seal inside it answered `.noChain`
        // and its span was applied as unsigned history. That made a device's
        // ROTATED history a different thing from its live tail: a stranger's
        // `.jsonl` is held and the same stranger's `.mzseg`, once its container
        // signature failed to settle, was applied unread. Rotation is not an
        // admission, so the two must agree — and this device's own inner seals,
        // which the keyless walk could not recognise either, settle `verified`
        // rather than being filed under somebody else's unsigned history.
        //
        // With no table there is still nothing to ask, and the keyless walk is
        // P1's behaviour exactly (ADR 0032 §6).
        // Walked, then cut, then parsed — the tail's own order, spelled out
        // here rather than delegated to `verifiedParse`, because a revocation
        // must cost a rotated segment exactly what it costs a live tail
        // (find 5's fourth carry). A keyless walk meets no `.afterRevocation`
        // and is returned untouched.
        let walked = trust.map { table in
            OpLogChain.verify(
                bytes: jsonl, trust: { table.verdict(forSealKey: $0) },
                rememberedHead: nil,
                // A segment that did not settle is walked exactly as a tail is,
                // arm 2 included: rotation is maintenance a device performs on
                // itself and must pardon nothing (P2b Task 10's rule, one rule
                // along).
                keyOfAnUnsealedFile: { PermitMark.keyNaming(url, in: table) })
        } ?? OpLogChain.verify(
            bytes: jsonl, trusted: { _ in false }, rememberedHead: nil)
        let readmitted = readmittingWhatWasAlreadyApplied(
            walked, url: url, trust: trust, fileSegmentDigest: digest)
        let verification = partitioningByPermit(
            readmitted, url: url, trust: trust, permit: permit,
            fileSegmentDigest: digest)
        let read = JSONLAppendStore<Op>.parse(
            bytes: JSONLAppendStore<Op>.applied(verification, whole: jsonl),
            dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
        if decoded.isVerified {
            skipped.append(contentsOf: read.diagnostics.skipped)
        }
        return FileClassification(
            ops: read.elements,
            diagnostics: ParseDiagnostics(skipped: skipped),
            provenance: provenance(
                name: url.lastPathComponent, lines: verification.lines,
                isSealedSegment: true, segmentVerified: false, trust: trust),
            verification: verification,
            adoptedHead: nil, verifiedSegmentDigest: nil,
            // Walked rather than settled, so it counts only where the walk
            // reached the END: a chain that broke inside means this reader
            // never trusted the bytes after the break.
            wholeSegmentDigest: digest.flatMap {
                !verification.lines.isEmpty && verification.lines.allSatisfy(wasSeen)
                    ? $0 : nil
            })
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
        isSealedSegment: Bool, segmentVerified: Bool?,
        trust: TrustTable? = nil
    ) -> FileProvenance {
        var legacy = 0, verified = 0, unsealed = 0, unsignedHistory = 0, quarantined = 0
        var pending = 0
        // The split by device is `OpLogChain`'s own derivation, asked for here
        // rather than repeated: the inbox's pending banner asks the same
        // question of a different stream, and two spellings of one count is how
        // two surfaces come to disagree about who is waiting.
        let pendingByDevice = OpLogChain.pendingByDevice(of: lines)
        for line in lines {
            switch line.state {
            case .legacy: legacy += 1
            case .verified: verified += 1
            case .unsealed: unsealed += 1
            case .unsignedHistory: unsignedHistory += 1
            case .pending:
                pending += 1
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
            pending: pending, pendingByDevice: pendingByDevice,
            // **Which of them the writer can be asked to ADMIT** (Task 5's D5).
            // The permit partition holds a line it cannot judge under the same
            // `.pending` state a stranger's seal does, and only the table can
            // tell the two apart. With no table nothing is pending at all, so
            // the `?? []` arm is unreachable rather than lenient.
            pendingStrangerDevices: trust.map { table in
                Set(pendingByDevice.keys.filter(table.isStrangerDevice))
            },
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
        // The WRITE path asks one question of the table and it is not a trust
        // question: which keys are this device's own. A stranger's line in MY
        // file is a quarantine whatever the registry says, because ADR 0012
        // gives this file one writer and the rewrite that follows assumes it.
        // So the KEYLESS table — the registry is not read on a write path.
        let mine = TrustResolution.keyless(mine: identities)
        return JSONLAppendStore<Op>(
            fileURL: Self.opLogFileURL(forDocId: docId, deviceSlug: deviceSlug, in: projectURL),
            presenter: presenter,
            dedupKey: { $0.opId },
            sortedBy: { $0.opId < $1.opId },
            chain: signer.map {
                ChainPolicy(
                    identity: $0, state: deviceState,
                    docId: docId, projectURL: projectURL,
                    trust: { mine.verdict(forSealKey: $0) })
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
    /// `statements` is the manifest's, for a caller LOOPING over a book: the
    /// permit partition resolves a `DocumentClass` per document, and a caller
    /// that already holds a manifest must not make this decode one per chapter
    /// (P3a Task 5). Nil reads it off disk, lazily, and only where some line's
    /// permit makes the answer turn on it.
    public nonisolated static func loadSyncMerged(
        forDocId docId: String, in projectURL: URL,
        identities: LocalIdentities? = .current,
        state: OpLogDeviceState? = .shared,
        trust: TrustTable? = nil,
        statements: [Statement]? = nil,
        amendmentPermits: AmendmentPermits? = nil
    ) throws -> [Op] {
        // Resolved here when the caller did not hand one over, so this reader
        // and the coordinated one hold a document to be made of the same ops.
        // A caller in a loop over a book's chapters should resolve ONCE and
        // pass it: the resolution is a verified read of the registry folder.
        let table = try trust ?? identities.map {
            try TrustResolution.resolve(projectURL: projectURL, identities: $0)
        }
        // **The permit partition, in the second read path** (P3a Task 5). One
        // context for the document, so its class is resolved at most once
        // however many files its history is spread over.
        let permit = permitContext(
            forDocId: docId, in: projectURL, trust: table, statements: statements,
            amendments: amendmentPermits)
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
                url: url, bytes: data, state: state, trust: table,
                permit: permit).ops)
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
