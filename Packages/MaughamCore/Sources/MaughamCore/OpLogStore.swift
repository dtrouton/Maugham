// Maugham/OpLog/OpLogStore.swift  (now in MaughamCore)
import Foundation
import os

/// Diagnostic channel for the two things a LOAD can fail at without failing:
/// recording the lines it set aside, and signing a segment it just minted
/// (`SegmentSealer`). Neither may cost the writer their manuscript, so neither
/// throws — and a silent best-effort is only honest if it says so somewhere.
/// `internal` because the op log's other files (`OpLogPermitContext`'s
/// unreadable manifest among them) report through the same channel.
let opLogLoadLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.core",
    category: "OpLogStore")

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
///
/// **What lives here** (since foundations plan 6): the per-store trust cache
/// and the write-permit door (tripwire 46); the document loads, which take the
/// table and the permit context here and hand each file to `OpLogClassifier`;
/// the append and its chain seal (`sealChain`, signing lines in place); and a
/// forwarding surface for the rules that moved out — file names
/// (`OpLogFiles`), classification (`OpLogClassifier`), marks
/// (`StreamPositions`), the missing-history census (`StreamCensus`), permit
/// construction (`LocalWritePermitBuilder`) and the segment seal
/// (`SegmentSealer`).
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

    // MARK: - Trust cache and the write-permit door

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

    /// How many times this store has actually RESOLVED its table (a folder
    /// read plus a verify per record), as opposed to answering from the one in
    /// hand. Read by tests that pin *one table per load* on real disk — the
    /// phone's `PhonePosture` asks `prepareTrust` on every re-ask and leaves the
    /// signature comparison to this store (P3 plan 3 Task 7).
    private(set) var trustResolutionCount = 0

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
        // The registry is not what this store last saw: any actor it asked
        // about may be due again (whole-branch review M2).
        declaredActors.removeAll()
        let table = try await Task.detached(priority: .userInitiated) {
            try TrustResolution.resolve(
                projectURL: projectURL, identities: identities, cache: cache)
        }.value
        resolvedTrust = (signature, table)
        trustResolutionCount += 1
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
        declaredActors.removeAll()
        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: identities, cache: registryCache)
        resolvedTrust = (signature, table)
        trustResolutionCount += 1
        return table
    }

    /// Forget the resolved table, so the next read builds a fresh one.
    ///
    /// The signature check above catches a registry that changed on disk, but a
    /// caller that JUST changed it — the admission sheet writing a person
    /// record — should say so rather than hope a modification time moved far
    /// enough to be seen.
    ///
    /// It also forgets which actors this store has asked about declaring
    /// (`declaredActors`): a changed registry is exactly the state in which an
    /// answer of *not due* — or a refused attempt — may have stopped being true.
    public func invalidateTrust() {
        resolvedTrust = nil
        declaredActors.removeAll()
    }

    /// **Resolve the table OFF this actor, ahead of a question asked on it**
    /// (P3c Task 2).
    ///
    /// `localWritePermit` is synchronous, and where the table is cold it
    /// resolves it right here (`trustOnThisActor`) — the right shape inside
    /// `Document.load`, whose suspension points are part of its contract, and
    /// the wrong one for the Mac's posture door, which a view asks from its
    /// `body`. The door warms the table through this first: `trust()`'s
    /// detached hop, stored under the same signature, so the permit question
    /// that follows costs a few stats and no verification.
    ///
    /// A project with no register asks nothing, exactly as `localWritePermit`
    /// does. Answers whether a table is now in hand; a registry record that is
    /// present and unreadable answers false, and the caller's own permit
    /// question then meets `localWritePermit`'s never-throwing fallback.
    @discardableResult
    public func prepareTrust() async -> Bool {
        guard TrustResolution.hasAnythingToResolve(
            in: projectURL, cache: registryCache) else { return true }
        return (try? await trust()) != nil
    }

    /// The same question through ONE manifest read — the class and the
    /// starter both from `placement` (P3 plan 3 Task 6). Forwards to
    /// `LocalWritePermitBuilder.permit(as:placement:table:in:)`, which carries
    /// the rule.
    public func localWritePermit(
        as actor: DeviceActor = .author,
        placement: ManifestPlacement
    ) -> LocalWritePermit {
        LocalWritePermitBuilder.permit(
            as: actor, placement: placement,
            table: registerTable(), in: projectURL)
    }

    /// **May this device's own hand write here, and what?** — the ONE question
    /// asked before a line exists (P3a Task 8).
    ///
    /// The load seam asks it of `.bootstrap`, of the pending-recovery burst and
    /// of a task anchor; P3c's membrane will ask it of a keystroke. One
    /// function so the two cannot answer differently, and on this store because
    /// this is where the verified table already is — resolving a second one per
    /// document would be a folder read and a P256 verify per record, per open.
    ///
    /// **It never throws, and that is the point**: a load that asks this
    /// question must not start refusing where it did not before (constitution
    /// must #1). `registerTable` carries the fallback and its reasoning.
    ///
    /// **Synchronous, and that is load-bearing**: the table is resolved here,
    /// on this actor (`registerTable` → `trustOnThisActor`), because a
    /// suspension point added to `Document.load` is a behaviour change on
    /// every open. The permit itself — the class closure, the starter rule
    /// (Option A) and `startedBy`'s default disk read — is
    /// `LocalWritePermitBuilder.permit`'s; this forwards to it (CLAUDE.md
    /// tripwire 46).
    public func localWritePermit(
        as actor: DeviceActor = .author,
        documentClass: () -> DocumentClass,
        startedBy: ((String) -> String?)? = nil
    ) -> LocalWritePermit {
        LocalWritePermitBuilder.permit(
            as: actor, documentClass: documentClass, startedBy: startedBy,
            table: registerTable(), in: projectURL)
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
    /// Built by `LocalWritePermitBuilder.annotationAmendments`, which carries
    /// the rule; `registerTable` is the table, as for `localWritePermit`.
    public func annotationAmendments(
        from amendments: AmendmentPermits? = nil,
        documentClass: @escaping @Sendable () -> DocumentClass
    ) -> AnnotationAmendments {
        LocalWritePermitBuilder.annotationAmendments(
            table: registerTable(), from: amendments,
            documentClass: documentClass)
    }

    // MARK: - Append state

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

    /// Test-only: when non-nil, every seal that goes through
    /// `sealChain(docId:by:)` (all seal paths share it) throws this, so a test
    /// can prove a failed seal never fails the append whose op had already
    /// landed (#75). Default nil.
    var sealFailureForTesting: Error?

    /// Test-only observation seam: called in `append` after the actor's key is
    /// declared and before the line is written, so a test can see the order.
    var beforeChainedAppendForTesting: (() -> Void)?

    /// The actors this store has asked about since it last saw the registry
    /// change — whatever the answer was, because asking per line would be a
    /// folder listing on every append (and a failing registry would pay a write
    /// attempt too). Asking is `RegistryPresence.declarationIsDue`, which
    /// answers yes again only if the registry has changed since the last
    /// attempt ANY store made.
    ///
    /// **Forgotten whenever this store learns the registry changed** (whole-
    /// branch review M2): `invalidateTrust()`, which `DocumentStore` sends every
    /// open document on a registry arrival and after its own registry writes,
    /// and `trust()`/`trustOnThisActor()` re-resolving over a new signature.
    /// Before that, an open document's store whose first non-author line met a
    /// *not due* or a refusal never asked again for its life.
    private var declaredActors: Set<DeviceActor> = []
    var declaredActorsForTesting: Set<DeviceActor> { declaredActors }

    /// `RegistryPresence.declareActorOnce`, BEFORE the line is written — and
    /// never at the cost of the line: a declaration that fails is logged and
    /// the append goes on. The line is then held on other Macs until the
    /// record catches up — the behaviour before F6, and no worse.
    ///
    /// **Synchronous, on this actor, and deliberately so.** A detached hop
    /// would take the registry read off the main thread, but it is a
    /// suspension point on the append path, and that was measured to reorder
    /// what callers observe: three `CompilerRunCommandTests` lost a minted
    /// note to it. So the cheap question — is a declaration due at all? — is
    /// asked first without reading a record, and the verified read runs on
    /// this actor only when the answer is yes: at most once per actor per
    /// registry state per process.
    private func declareBeforeFirstLine(as actor: DeviceActor) {
        guard declaredActors.insert(actor).inserted,
              RegistryPresence.declarationIsDue(
                actor, in: projectURL, identities: identities)
        else { return }
        do {
            try RegistryPresence.declareActorOnce(
                actor, in: projectURL, identities: identities, presenter: presenter)
        } catch {
            opLogLoadLog.error("""
                Could not put this device's \(actor.rawValue, privacy: .public) \
                key on its record in \
                \(self.projectURL.lastPathComponent, privacy: .public): \
                \(String(describing: error), privacy: .public). The line is \
                written; other devices hold it until the record catches up.
                """)
        }
    }

    // MARK: - Loads

    /// Glob every file for `docId` (legacy `<docId>.jsonl` + per-device
    /// `<docId>.<slug>.jsonl`; `OpLogFiles.opLogFileURLs` owns the glob), load
    /// each (coordinated), and merge: dedupe by opId, sort by opId.
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
        let mine = ForeignStreamWatch.slugs(of: identities)
        let foreign = ForeignStreamWatch(
            projectURL: projectURL, state: deviceState, mine: mine)
        for url in urls {
            let result = try await OpLogClassifier.loadFileDiagnosed(
                url: url, presenter: presenter,
                identities: identities, state: deviceState, trust: table,
                permit: permit, foreign: foreign)
            merged.append(contentsOf: result.ops)
            skipped.append(contentsOf: result.diagnostics.skipped)
            files.append(result.provenance)
        }
        foreign.settle()
        return (OpLogClassifier.mergeSortedDedup(merged),
                ParseDiagnostics(skipped: skipped),
                OpLogProvenance(files: files, ownStreams: mine))
    }

    /// **The lines one holder is waiting under, as the walk itself answers
    /// them** (P3b Task 8 fix round 1, spec §7.4).
    ///
    /// A held line is neither applied nor refused, so it is in the file and in
    /// nothing else: no `.lines` record is written for one, and a load returns
    /// the ops it APPLIED. This is what lets §7.4's way back reach a held
    /// line — it asks the same question the load asks, of the same files, and
    /// reads the answer off the walk's own `Verification` rather than deciding
    /// anything of its own.
    ///
    /// **One classifier, and this is not a second one.** The trust table is
    /// this store's and the permit context is built exactly as `loadDiagnosed`
    /// builds it; the walk is `OpLogClassifier.heldLines`, which carries what
    /// it may decide (nothing of its own), that it never writes, and that it
    /// throws rather than coming back short (RULING-54).
    ///
    /// **The walk itself runs OFF this actor** (fix round 2, I3). This class is
    /// `@MainActor`, and the walk is a coordinated read plus a P256
    /// verification per seal, per file — once per holder, on a History reload.
    /// So the two things that need the actor are taken here (the trust table,
    /// and the permit context built from it) and the reading is handed to a
    /// detached task, the way `DocumentStore`'s own sweeps hand theirs over.
    /// The presenter travels with it exactly as it does into
    /// `loadFileDiagnosed`, so the coordinated read still declines to bounce
    /// this process's own writes back at it.
    ///
    /// Answers the raw LINE BYTES, in file order, per file in listing order;
    /// what they MEAN is the caller's (`OpLogQuarantine.recoverableWords`).
    public func heldLines(
        forDocId docId: String, heldBy holder: String
    ) async throws -> [Data] {
        let urls = Self.opLogFileURLs(forDocId: docId, in: projectURL)
        guard !urls.isEmpty else { return [] }
        let table = try await trust()
        let permit = Self.permitContext(
            forDocId: docId, in: projectURL, trust: table)
        let presenter = self.presenter
        let state = deviceState
        return try await Task.detached(priority: .userInitiated) {
            try OpLogClassifier.heldLines(
                in: urls, heldBy: holder, presenter: presenter,
                state: state, trust: table, permit: permit)
        }.value
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
                let result = try await OpLogClassifier.loadFileDiagnosed(
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
            ops: OpLogClassifier.mergeSortedDedup(all),
            diagnostics: ParseDiagnostics(skipped: skipped),
            unreadableFiles: unreadable.sorted { $0.name < $1.name },
            provenance: OpLogProvenance(
                files: files, ownStreams: ForeignStreamWatch.slugs(of: identities)))
    }

    // MARK: - Read errors, and the doors that raise them

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
    // `internal` rather than `private`: the op log's other readers
    // (`OpLogClassifier`, `StreamPositions`, `LocalWritePermitBuilder`'s
    // `unownedPiece`) read through the same door, so the coordination policy
    // stays one decision.
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
    nonisolated static func listing(
        of directory: URL, naming name: String
    ) throws -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch {
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            throw ReadError.unlistableStreamDirectory(
                name: name, underlying: error.localizedDescription)
        }
    }

    // MARK: - Append and chain seal

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
        // A key this device named after the book was opened goes on its record
        // BEFORE the first line it signs, or every other Mac holds that line as
        // a stranger's until this one reopens the book (P3b smoke find F6).
        // The AUTHOR is the device and was declared at open, so the writer's
        // own lines ask nothing at all.
        if let signer, signer.actor != .author {
            declareBeforeFirstLine(as: signer.actor)
        }
        beforeChainedAppendForTesting?()
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
        // Best-effort, like every other seal site: the op is already durable,
        // so a failure here is LOGGED and dropped; sealing is maintenance, and
        // it must never cost the caller the op that has already landed (a
        // retry would mint a duplicate). The counter resets only on success,
        // so the next append asks again.
        do {
            if try await sealChain(docId: op.docId, by: signer) { linesSinceSeal[url] = 0 }
        } catch {
            opLogLoadLog.error("""
                interval seal failed for \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public). The op is on disk; \
                sealing is maintenance and will be retried on the next append.
                """)
        }
    }

    /// How many chained lines this device writes into a file before it seals
    /// them. A seal is one signature over the whole run, so the interval trades
    /// signing cost against how much of the tail is merely chained (tamper-
    /// EVIDENT) rather than sealed (tamper-evident and signed).
    ///
    /// `nonisolated` for `segmentSealThreshold`'s reason (below): an immutable
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
    ///
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
        if let injected = sealFailureForTesting { throw injected }
        return try await store(
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

    // MARK: - Segment seal (tail → immutable segment)

    /// `SegmentSealer.threshold`, under the name its callers use.
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
    public nonisolated static let segmentSealThreshold = SegmentSealer.threshold

    /// Seal THIS device's live tail for `docId` into the next segment, iff it
    /// exceeds `threshold` bytes. See `SegmentSealer.sealTail`, which carries
    /// the scope rules (tripwire 17), the two callers and the crash contract.
    @discardableResult
    public func sealTailIfNeeded(
        docId: String, deviceSlug: DeviceSlug, threshold: Int = OpLogStore.segmentSealThreshold
    ) async throws -> URL? { try SegmentSealer.sealTail(
        docId: docId, deviceSlug: deviceSlug, threshold: threshold,
        projectURL: projectURL, presenter: presenter, identities: identities) }

    // MARK: - Forwarders
    // One statement each, calling the type that owns the rule and documents
    // its contract. Kept so callers are unchanged; nothing here decides.

    // File names and globs — `OpLogFiles`.

    public nonisolated static func opLogFileURL(
        forDocId docId: String, deviceSlug: DeviceSlug, in projectURL: URL
    ) -> URL { OpLogFiles.opLogFileURL(forDocId: docId, deviceSlug: deviceSlug, in: projectURL) }

    public nonisolated static func docId(
        fromOpLogFilename name: String
    ) -> String? { OpLogFiles.docId(fromOpLogFilename: name) }

    public nonisolated static func docIds(
        inOpsDirectoryFilenames filenames: [String]
    ) -> Set<String> { OpLogFiles.docIds(inOpsDirectoryFilenames: filenames) }

    public nonisolated static func opLogFileURLs(
        forDocId docId: String, in projectURL: URL
    ) -> [URL] { OpLogFiles.opLogFileURLs(forDocId: docId, in: projectURL) }

    public nonisolated static func segmentFileURL(
        forDocId docId: String, deviceSlug: DeviceSlug, index: Int, in projectURL: URL
    ) -> URL { OpLogFiles.segmentFileURL(
        forDocId: docId, deviceSlug: deviceSlug, index: index, in: projectURL) }

    public nonisolated static func segmentSignatureURL(
        for segmentURL: URL
    ) -> URL { OpLogFiles.segmentSignatureURL(for: segmentURL) }

    nonisolated static func segmentIndex(
        fromFilename name: String, docId: String, deviceSlug: DeviceSlug
    ) -> Int? { OpLogFiles.segmentIndex(fromFilename: name, docId: docId, deviceSlug: deviceSlug) }

    // The per-file read and the merge — `OpLogClassifier`.

    public static func loadFileDiagnosed(
        url: URL, presenter: NSFilePresenter?,
        identities: LocalIdentities? = nil, state: OpLogDeviceState? = nil,
        trust: TrustTable? = nil, permit: PermitContext? = nil,
        foreign: ForeignStreamWatch? = nil
    ) async throws -> (ops: [Op], diagnostics: ParseDiagnostics, provenance: FileProvenance) {
        try await OpLogClassifier.loadFileDiagnosed(
            url: url, presenter: presenter, identities: identities, state: state,
            trust: trust, permit: permit, foreign: foreign)
    }

    public nonisolated static func provenance(
        forDocId docId: String, in projectURL: URL,
        trust: TrustTable, state: OpLogDeviceState?
    ) throws -> OpLogProvenance { try OpLogClassifier.provenance(
        forDocId: docId, in: projectURL, trust: trust, state: state) }

    public nonisolated static func loadSyncMerged(
        forDocId docId: String, in projectURL: URL,
        identities: LocalIdentities? = .current, state: OpLogDeviceState? = .shared,
        trust: TrustTable? = nil, statements: [Statement]? = nil,
        amendmentPermits: AmendmentPermits? = nil
    ) throws -> [Op] { try OpLogClassifier.loadSyncMerged(
        forDocId: docId, in: projectURL, identities: identities, state: state,
        trust: trust, statements: statements, amendmentPermits: amendmentPermits) }

    nonisolated static func mergeSortedDedup(
        _ ops: [Op]
    ) -> [Op] { OpLogClassifier.mergeSortedDedup(ops) }

    // Marks and positions — `StreamPositions`.

    public nonisolated static func highestAppliedOpId(
        ofDeviceIds ids: Set<String>, in projectURL: URL, trust: TrustTable?
    ) throws -> String? { try StreamPositions.highestAppliedOpId(
        ofDeviceIds: ids, in: projectURL, trust: trust) }

    public nonisolated static func appliedPositions(
        ofDeviceIds ids: Set<String>, in projectURL: URL, trust: TrustTable?,
        expecting: [String: OpLogDeviceState.ForeignStreamMemory] = [:]
    ) throws -> PermitMark { try StreamPositions.appliedPositions(
        ofDeviceIds: ids, in: projectURL, trust: trust, expecting: expecting) }

    public nonisolated static func seenPositions(
        ofDeviceIds ids: Set<String>, in projectURL: URL, trust: TrustTable?,
        expecting: [String: OpLogDeviceState.ForeignStreamMemory] = [:]
    ) throws -> PermitMark { try StreamPositions.seenPositions(
        ofDeviceIds: ids, in: projectURL, trust: trust, expecting: expecting) }

    public nonisolated static func unattributablePositions(
        in projectURL: URL, trust: TrustTable,
        expecting: [String: OpLogDeviceState.ForeignStreamMemory] = [:]
    ) throws -> PermitMark { try StreamPositions.unattributablePositions(
        in: projectURL, trust: trust, expecting: expecting) }

    nonisolated static func nameBehindICloudPlaceholder(
        _ filename: String
    ) -> String? { StreamPositions.nameBehindICloudPlaceholder(filename) }

    // The census of missing history — `StreamCensus`.

    public typealias TruncatedStream = StreamCensus.TruncatedStream
    public typealias LostHistory = StreamCensus.LostHistory

    public nonisolated static func truncatedStreams(
        in projectURL: URL, state: OpLogDeviceState, trust: TrustTable? = nil
    ) -> [TruncatedStream] { StreamCensus.truncatedStreams(
        in: projectURL, state: state, trust: trust) }

    public nonisolated static func lostHistory(
        in projectURL: URL, state: OpLogDeviceState, trust: TrustTable? = nil
    ) -> [LostHistory] { StreamCensus.lostHistory(in: projectURL, state: state, trust: trust) }

    public nonisolated static func unreadableName(
        _ error: Error
    ) -> String { StreamCensus.unreadableName(error) }
}
