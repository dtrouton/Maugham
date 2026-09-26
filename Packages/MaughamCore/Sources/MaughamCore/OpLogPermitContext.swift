import Foundation

/// **What a reader has to know before it can ask the permit table anything**
/// (P3a Task 5, spec §4.1 and §4.5).
///
/// `OpLogStore.classify` works per FILE and holds no project: it has a URL, the
/// bytes, this device's remembered head and the trust table. Two of the
/// partition's four questions are about the DOCUMENT rather than the file —
/// *where does this stream sit* and *has a book author written this piece's
/// text* — so they are resolved once, by a caller that has the project, and
/// passed down together.
///
/// **Together, and as one optional value, on purpose.** Two independent
/// parameters would let a reader pass one and forget the other, and a
/// half-supplied context is a partition that silently judges nothing. `nil` is
/// the explicit *do not judge* — the keyless readers (`ProjectIntegrity.check`,
/// which passes no table either) and anything inspecting a project without
/// opening it.
///
/// **Both halves are CLOSURES, and both are lazy for the same reason.**
/// Resolving the class decodes a manifest; answering `unowned` classifies every
/// other file of the document a second time. Neither is needed by a book with
/// no permit events, which is every book on disk today, so neither runs there.
/// `LocalWritePermit.answersWithoutTheClass` is the write side's spelling of
/// the same idea and was built for the same reason (Task 8).
/// **One answer, computed at most once, however many files ask for it.**
///
/// Both halves of a `PermitContext` are expensive and both are asked per FILE,
/// while their answers are facts about the DOCUMENT — so without this a
/// document spread over four actor files decodes four manifests, and
/// `unownedPiece` (which itself classifies every file) becomes quadratic
/// (fix round 1, I1 and minor (d)).
///
/// A class with a lock rather than a captured `var`, because the closures are
/// `@Sendable`: they are handed to `classify`, which is `nonisolated` and
/// called from both an `async` reader and a synchronous one. `@unchecked
/// Sendable` is honest here — the one piece of state is behind the one lock,
/// and `make` runs inside it, so a second caller waits rather than duplicating
/// the work.
final class PermitMemo<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Value?

    func callAsFunction(_ make: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let answer { return answer }
        let made = make()
        answer = made
        return made
    }
}

public struct PermitContext: Sendable {

    /// Where this stream sits. Called at most once per file, and only where
    /// some line's (permit, actor) pair makes the answer turn on it.
    public let documentClass: @Sendable () -> DocumentClass

    /// §4.5's document-level fact. Called at most once per file, and only where
    /// an author of some pieces has written manuscript text with her own hand
    /// in a piece outside her scope.
    public let unowned: @Sendable () -> PermitPartition.UnownedPiece

    /// **Where the governing permit of each amendment line is written down**
    /// (P3a Task 6, fix round 1), or nil where no caller asked for it.
    ///
    /// It rides in the context rather than beside it because the context is
    /// already threaded through `classify` to every file of a document, and the
    /// answer is a fact about the DOCUMENT gathered file by file — the same
    /// reason the other two halves are here.
    public let amendments: AmendmentPermits?

    /// **Who started this piece** — its manifest item's `startedBy` (P3c
    /// plan 2, Option A), for §4.5's arm: a starter the register knows is
    /// somebody other than the line's writer refuses her line outright (P3
    /// closing smoke F1), and her own starter applies it on her own Mac.
    /// Called at most once per file, and only where a scoped author's own
    /// manuscript line reached §4.5's shape, so no book that has narrowed
    /// nobody ever reads it.
    ///
    /// Defaults to *no starter recorded*, which is today's rule: a reader that
    /// builds a context for a stream that is not a piece (a translation, the
    /// inbox) has nothing to answer, and §4.5 cannot reach such a stream.
    public let startedBy: @Sendable () -> String?

    public init(
        documentClass: @escaping @Sendable () -> DocumentClass,
        unowned: @escaping @Sendable () -> PermitPartition.UnownedPiece,
        amendments: AmendmentPermits? = nil,
        startedBy: @escaping @Sendable () -> String? = { nil }
    ) {
        self.documentClass = documentClass
        self.unowned = unowned
        self.amendments = amendments
        self.startedBy = startedBy
    }
}

/// **The permit each own-annotation amendment was written under** — the
/// partition's second product (P3a Task 6, fix round 1).
///
/// *A reviewer may edit or withdraw their OWN annotations* is judged where the
/// annotations are derived, long after the bytes have been parsed and the
/// partition's per-line judgements thrown away. Asking the signer's permit
/// again at that point means asking today's, and this milestone has tripped on
/// that twice already: by today's permit a **demotion reaches back** (an author
/// edits a reviewer's note body, is later demoted, and her honest edit is
/// silently un-done on every device) and a **promotion pardons** (a reviewer's
/// ignored withdrawal of somebody else's note becomes honoured the day she is
/// promoted).
///
/// So the permit travels. The partition already computes the governing entry
/// for every line it judges; where that line is an `annotationEdit` or an
/// `annotationWithdraw`, its op id and its permit are written here, and the
/// load hands the merged map to `AnnotationAmendments.judged`.
///
/// **Empty for every existing book**, because nothing is recorded unless the
/// book has permit events at all — and an amendment with no entry falls back to
/// exactly what it did before, so an unjudged file (legacy, unsigned, a book
/// with no register) is untouched.
///
/// A class because it is filled by a `classify` per file and read once by the
/// load; `@unchecked Sendable` over one lock, which is `PermitMemo`'s own shape
/// in this file and is honest for the same reason — the one piece of state is
/// behind the one lock.
public final class AmendmentPermits: @unchecked Sendable {
    private let lock = NSLock()
    private var byOpId: [String: Permit] = [:]
    private var insideTheUnsignedSnapshot: Set<String> = []
    private var startedAPiece: Set<String> = []
    private var keptWritingInATakenPiece: Set<String> = []

    public init() {}

    /// **This piece-start was really a piece TAKEN from them** (P3b smoke
    /// F9, Q1). Recorded beside `recordStartedAPiece` by the same arm, from
    /// `PermitTimeline.wasTakenFromThem`, so the surfaces that tell the writer
    /// about a held line can say the truth without re-reading a registry.
    func recordKeptWritingInATakenPiece(_ holder: String) {
        lock.lock()
        defer { lock.unlock() }
        keptWritingInATakenPiece.insert(holder)
    }

    /// The holders among `whoStartedAPiece` whose piece had been taken from
    /// them — a subset of it, never a second list of who is waiting.
    public var whoKeptWritingInATakenPiece: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return keptWritingInATakenPiece
    }

    // MARK: - Who started a piece nobody has claimed (P3b Task 7)

    /// **This held line was §4.5's question, not §4.2's.**
    ///
    /// Two arms of the partition hold a line under the very same holder
    /// string, `trust.person(forSealKey:)`: a line this BUILD cannot judge
    /// (`Permit.Allowed.cannotJudge`) and a scoped author's own hand opening a
    /// piece nobody has claimed. They want opposite sentences — *a newer
    /// version of Maugham will know* against *is this piece hers?* — and the
    /// second is a question the writer can answer today.
    ///
    /// Nothing downstream can tell them apart from the holder, and nothing
    /// downstream can re-derive it either: `startsAPieceNobodyHasClaimed`
    /// needs the governing permit, the signing actor, the document class AND
    /// the op's `Written`, which is the whole partition again — a second
    /// classifier, and exactly what tripwires 39 and 44 are about. So the
    /// partition that already decided it writes it down here.
    ///
    /// **The same carrier as the governing permit and the snapshot side**, for
    /// the reason those two are here: the fact is known only inside the
    /// partition, it is needed a long way downstream where the bytes are gone,
    /// and a second carrier would be a second opinion about which line was
    /// which. Keyed by HOLDER rather than by op id because every surface that
    /// reads it asks *who*, and one writer opening six paragraphs of a new
    /// piece is one question.
    ///
    /// **Empty for every book that has narrowed nobody**, because §4.5 cannot
    /// fire where every permit is author-of-the-whole-book.
    func recordStartedAPiece(_ holder: String) {
        lock.lock()
        defer { lock.unlock() }
        startedAPiece.insert(holder)
    }

    /// The holders whose held lines opened a piece nobody has claimed, over
    /// every file of the document this carrier was handed to.
    public var whoStartedAPiece: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return startedAPiece
    }

    /// **This amendment line was inside the unsigned photograph** (P3b Task 2,
    /// ruling 1's second direction).
    ///
    /// The same carrier as the governing permit, for the same reason: the fact
    /// is about ONE LINE, it is known only inside the partition that judged
    /// it, and it is needed a long way downstream where the bytes are gone. A
    /// second carrier would be a second opinion about which line was which.
    ///
    /// Recorded by the unsigned door alone, and only for a line it judged OLD
    /// in a file no key can name. An op id that is not here is not evidence of
    /// anything — it is the ordinary case, every line of every attributable
    /// file — so `AnnotationOwnership.unplaced` reads this only after it has
    /// already decided the id is one it cannot place.
    func recordInsideTheUnsignedSnapshot(_ opId: String) {
        lock.lock()
        defer { lock.unlock() }
        insideTheUnsignedSnapshot.insert(opId)
    }

    /// Record one amendment line's governing permit.
    ///
    /// **A collision keeps the MORE RESTRICTIVE permit, by a total order.**
    /// One op id can reach this twice: the same line can sit in the legacy
    /// unsuffixed file and in a per-device one (ADR 0012's own case), and those
    /// are two STREAMS, so a mark can cut them differently and the two copies
    /// can be governed by different permits.
    ///
    /// First-wins would be wrong here, and the reason is worth stating because
    /// the first cut of this comment got it backwards: `opLogFileURLs` is
    /// UNSORTED, so *first* is whatever `contentsOfDirectory` felt like saying
    /// — and `mergeSortedDedup` is not a precedent for it either, since that
    /// function picks by `(opId, canonicalJSON)` precisely so enumeration order
    /// cannot decide. So the rule here is its own: the permit that withholds
    /// more wins, and equal ranks break on a canonical string, which makes the
    /// answer a function of the two permits alone.
    func record(_ opId: String, _ permit: Permit) {
        lock.lock()
        defer { lock.unlock() }
        guard let standing = byOpId[opId] else {
            byOpId[opId] = permit
            return
        }
        if Self.restriction(permit) > Self.restriction(standing) {
            byOpId[opId] = permit
        }
    }

    /// **How much a permit withholds**, as a total order.
    ///
    /// Total on purpose: a collision must have one answer whatever order the
    /// files were enumerated in, so equal ranks are broken on a canonical
    /// string rather than left to arrive-first. The string is not a claim about
    /// which of two piece-lists is narrower — there is no such fact — it is
    /// only what makes the tie deterministic.
    ///
    /// `.unjudgeable` ranks highest because it decides nothing, and an
    /// amendment whose permit decides nothing is not honoured on the strength
    /// of author rights.
    private static func restriction(_ permit: Permit) -> (Int, String) {
        switch permit {
        case .author(.book): return (0, "")
        case .author(.pieces(let ids)): return (1, ids.sorted().joined(separator: ","))
        case .reviewer: return (2, "")
        case .unjudgeable(let raw): return (3, raw)
        }
    }

    /// What was gathered, across every file of the document.
    public var resolved: [String: Permit] {
        lock.lock()
        defer { lock.unlock() }
        return byOpId
    }

    /// The amendment lines the unsigned door found at or before the
    /// photograph, across every file of the document.
    public var resolvedInsideTheUnsignedSnapshot: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return insideTheUnsignedSnapshot
    }
}

/// **Everything a reader needs to run the permit partition over one file**
/// (P3a Task 6): the table, the document-level answers, and how to read what a
/// line was.
///
/// Three streams answer to one permit and each of them reaches it from a
/// different reader — the op log's two classify paths, `TranslationStore
/// .loadMerged`, `JSONLAppendStore.loadVerifiedStrict` for the inbox — so the
/// apparatus travels as ONE value for `PermitContext`'s own reason: a reader
/// that could pass a table and forget the decoder would silently judge every
/// line of a translation file as an op with no `kind`, which is *nothing to
/// decide*.
public struct PermitJudge: Sendable {

    /// The one table (tripwire 39: no parallel trust table).
    public let trust: TrustTable
    /// Where this stream sits, and §4.5's document-level fact.
    public let context: PermitContext
    /// What a line of THIS stream was — see `PermitPartition.WrittenDecoder`.
    public let decoding: @Sendable (Data) -> Written?

    /// **What every line of this stream is**, where a stream has one answer —
    /// the translation sidecars and the inbox manifests do, the op log does
    /// not (its lines are a dozen kinds and the actor rows narrow several).
    ///
    /// It is what lets the file-level door answer a whole file at once without
    /// walking it (fix round 2's R3, narrowed in fix round 3). Set only by
    /// `oneKind` below, which builds the DECODER from the same value, so the
    /// two cannot come to disagree about what this stream holds.
    public let everyLineIs: Written?

    public init(
        trust: TrustTable, context: PermitContext,
        decoding: @escaping @Sendable (Data) -> Written? = PermitPartition.writtenOp,
        everyLineIs: Written? = nil
    ) {
        self.trust = trust
        self.context = context
        self.decoding = decoding
        self.everyLineIs = everyLineIs
    }

    /// A stream whose every line is one thing: the decoder and the claim from
    /// one value.
    ///
    /// Nothing is parsed by such a decoder, and nothing needs to be — the
    /// directory holds one element type and the table's only question about a
    /// line is *what was it*. A line that does not decode is
    /// `JSONLAppendStore.parse`'s to report, exactly as it is for an op whose
    /// `kind` the op decoder never reads either.
    public static func oneKind(
        _ what: Written, trust: TrustTable, context: PermitContext
    ) -> PermitJudge {
        PermitJudge(
            trust: trust, context: context,
            decoding: { _ in what }, everyLineIs: what)
    }

    /// One language's translation sidecar for one piece.
    ///
    /// The class is CONSTRUCTED rather than resolved from the manifest, because
    /// the reader already knows what it is reading: a translation stream's
    /// document id is the piece's own, which is exactly what
    /// `DocumentClass.translation(piece:)` carries and what an
    /// author-of-some-pieces' scope list names. So this pays no manifest read
    /// at all, on any book.
    ///
    /// `unowned` is never asked: §4.5 is about MANUSCRIPT text in a piece
    /// nobody has claimed, and `Permit.startsAPieceNobodyHasClaimed`
    /// requires both a `.piece` class and the manuscript-text group, so a
    /// translation line can never reach it.
    public static func translation(
        ofPiece piece: String, trust: TrustTable
    ) -> PermitJudge {
        oneKind(
            .translationRecord, trust: trust,
            context: PermitContext(
                documentClass: { .translation(piece: piece) },
                unowned: { .nobodyHasWrittenItsText }))
    }

    /// The capture inbox — one class for the whole stream, and the one class
    /// whose entire content is the reviewer row.
    public static func inbox(trust: TrustTable) -> PermitJudge {
        oneKind(
            .inboxRow, trust: trust,
            context: PermitContext(
                documentClass: { .inbox },
                unowned: { .nobodyHasWrittenItsText }))
    }
}

extension OpLogStore {

    /// **Where a document's stream sits, from the manifest on disk** (spec
    /// §4.1) — the one place a read path asks that question with only a project
    /// URL in hand.
    ///
    /// **A manifest that will not read must never make a load THROW that did
    /// not throw before** (constitution must #1). `try?` throughout: a nil
    /// manifest is no statements, and no statements resolves every id to
    /// `.piece(docId)`, which is the WIDENING direction — a piece is the class
    /// an author of some pieces can actually hold, where `.projectStatement`
    /// would refuse her. The load is not the right place to discover a broken
    /// manifest; `ProjectStore.load` is, and it says so in its own words.
    ///
    /// A caller that already HOLDS a manifest must not come here — it calls
    /// `DocumentClass.resolve(docId:statements:)`, which is pure and free.
    /// This door is for the readers that have a URL and nothing else.
    nonisolated public static func documentClass(
        forDocId docId: String, in projectURL: URL
    ) -> DocumentClass {
        DocumentClass.resolve(
            docId: docId, statements: manifestStatements(in: projectURL))
    }

    /// The manifest's statements, or none where it cannot be read — the read
    /// half of `documentClass(forDocId:in:)`, separate so a caller looping over
    /// a whole book decodes once rather than once per chapter.
    nonisolated public static func manifestStatements(
        in projectURL: URL
    ) -> [Statement] {
        decodedManifest(in: projectURL)?.statements ?? []
    }

    /// **The one manifest read these doors make** — the file, decoded, or nil
    /// where it is missing or will not read. Every read ticks
    /// `manifestReadObserverForTesting` once, which is what lets a test count
    /// the decodes an ask makes (P3 plan 3 Task 6).
    nonisolated static func decodedManifest(in projectURL: URL) -> ProjectManifest? {
        manifestReadObserverForTesting?()
        let url = projectURL.appendingPathComponent(ProjectManifest.fileName)
        guard let data = try? Data(contentsOf: url)  // adr-0018-ok: project manifest JSON read, not manuscript
        else { return nil }
        do {
            return try ProjectManifest.makeDecoder()
                .decode(ProjectManifest.self, from: data)
        } catch {
            // **Reported, never thrown** (fix round 1, minor (a), and R2's
            // other half). A manifest this build cannot read WIDENS the permit
            // rather than narrowing it — every stream then reads as a
            // manuscript piece — and the writer learns about a broken manifest
            // from `ProjectStore.load`, which is the right door for it. But a
            // widening that happens in silence is a widening nobody can find,
            // so it says so once, here, where it happened.
            opLogLoadLog.error(
                """
                Could not read the project manifest while placing a stream for \
                the permit check: \(String(describing: error), privacy: .public). \
                Every stream in this project is judged as a manuscript piece \
                until it reads.
                """)
            return nil
        }
    }

    /// **Who started a piece, from the manifest on disk** (P3c plan 2, Option
    /// A) — `StructureItem.startedBy` for the item whose id is `docId`, the
    /// one door a reader holding only a project URL reads it through.
    ///
    /// Nil where the manifest will not read, where no item has that id, and
    /// where the item records no starter — all three are *today's rule*, which
    /// is the direction that changes nothing: a line §4.5 holds stays held,
    /// and a Mac that may write the piece's text still mints its opening.
    nonisolated public static func startedBy(
        ofPiece docId: String, in projectURL: URL
    ) -> String? {
        decodedManifest(in: projectURL)?.startedBy(ofPiece: docId)
    }

    /// Test-only counting seam: called once per manifest READ this path makes.
    ///
    /// It exists to pin the cost claim rather than argue it: **a book with no
    /// permit events reads no manifest at all**, because every line in it is
    /// under a permit that can refuse nothing and the class is never asked for
    /// (`Permit.allowsEverything`). A regression that made the class an
    /// ARGUMENT again would put a file read and a JSON decode on every op-log
    /// file of every load, and nothing else would go red.
    ///
    /// `nonisolated(unsafe)` because it is a test's own variable, set and
    /// cleared on one thread; production never assigns it.
    nonisolated(unsafe) public static var manifestReadObserverForTesting:
        (@Sendable () -> Void)?

    /// **§4.5's pass 1, over every file of one document**: has any key holding
    /// an author-of-the-whole-book permit applied a manuscript-text line here?
    /// A book author's opening of a piece somebody ELSE started is not one
    /// (ruling G): the rule is `PermitPartition.bookAuthorWroteManuscriptText`'s,
    /// asked per file. Since Option A the WRITE side asks this too
    /// (`localWritePermit`, for an author of some pieces in a piece she
    /// started). The answer is a fact about the document's LINES, so a stamp
    /// taken from it goes stale when lines arrive: the Mac re-stamps a
    /// Document carrying `writesAsItsStarter` on every external re-read
    /// (ruling H, `Document.handleExternalLogChange`), which is when her read
    /// sets her lines aside — so her editor locks at that same re-read.
    ///
    /// Classified with **no permit context of its own**, which is what stops
    /// this recursing, and with `state: nil`, so it adopts no head, remembers
    /// no digest and writes no record — it is a question, not a load.
    ///
    /// **It is asked at most once per file that reaches §4.5**, not memoised
    /// across a document's files: memoising wants shared mutable state inside a
    /// `@Sendable` closure, and the condition that reaches here — a scoped
    /// author's own hand, in a piece outside her scope, in a book that has
    /// permit events — is rare enough that a handful of repeats is the cheaper
    /// of the two risks.
    nonisolated public static func unownedPiece(
        forDocId docId: String, in projectURL: URL, trust: TrustTable?
    ) -> PermitPartition.UnownedPiece {
        guard let trust else { return .nobodyHasWrittenItsText }
        return unownedPiece(
            forDocId: docId, in: projectURL, trust: trust,
            startedBy: startedBy(ofPiece: docId, in: projectURL))
    }

    /// The same question, for a caller that already holds the piece's
    /// recorded starter (ruling G: a book author's `bootstrap` claims the
    /// piece unless somebody else started it).
    nonisolated public static func unownedPiece(
        forDocId docId: String, in projectURL: URL, trust: TrustTable,
        startedBy: String?
    ) -> PermitPartition.UnownedPiece {
        for url in opLogFileURLs(forDocId: docId, in: projectURL) {
            guard let bytes = (try? readCoordinated(url: url, presenter: nil)) ?? nil,
                  let stream = PermitMark.stream(of: url)
            else { continue }
            let classified = classify(
                url: url, bytes: bytes, state: nil, trust: trust)
            guard let verification = classified.verification else {
                // A settled segment was never walked, so there is no
                // `Verification` to read — but its lines ARE this document's
                // history, so the question has to reach them. The lines are the
                // decompressed JSONL, every one of them applied, under the key
                // that settled the container.
                guard let settled = settledSegmentVerification(
                    at: url, bytes: bytes) else { continue }
                if PermitPartition.bookAuthorWroteManuscriptText(
                    in: settled.verification, streamKey: stream.key,
                    deviceSlug: stream.deviceSlug,
                    fileSegmentDigest: settled.digest, trust: trust,
                    settledByKey: settled.key,
                    startedBy: startedBy) { return .aBookAuthorHasWrittenItsText }
                continue
            }
            if PermitPartition.bookAuthorWroteManuscriptText(
                in: verification, streamKey: stream.key,
                deviceSlug: stream.deviceSlug,
                fileSegmentDigest: classified.verifiedSegmentDigest,
                trust: trust, startedBy: startedBy) { return .aBookAuthorHasWrittenItsText }
        }
        return .nobodyHasWrittenItsText
    }

    /// **A settled segment, as the partition needs to see it.**
    ///
    /// A container whose signature settled it is never WALKED — that is the
    /// whole point of the fast path, and `OpLog/AREA.md`'s performance note 2
    /// is about not splitting it. But a permit judges lines, so where a
    /// partition is going to run the lines have to exist: every one of them
    /// `.verified` (the signature covers the whole file, which is the claim a
    /// segment signature makes), under the key that made that signature.
    ///
    /// The extra split is one more pass over bytes `JSONLAppendStore.parse`
    /// already walks and slices on this same branch, so it is a constant
    /// factor and not a new order of cost — and it is paid only where a permit
    /// context was supplied, i.e. on a real load of a real document.
    ///
    /// Nil where the container did not verify, where there is no signature
    /// beside it, or where the signature does not hold together or does not
    /// name this digest — every one of which means the segment did not settle,
    /// and a segment that did not settle is walked line by line by the fallback
    /// instead.
    nonisolated static func settledSegmentVerification(
        at url: URL, bytes: Data
    ) -> (verification: OpLogChain.Verification, digest: String, key: String)? {
        let decoded = OpLogSegment.decodeVerifying(bytes)
        guard decoded.isVerified, let digest = decoded.digest,
              let jsonl = decoded.jsonl,
              let signature = SegmentSignature.read(at: segmentSignatureURL(for: url)),
              signature.digest == digest, signature.verifies()
        else { return nil }
        let slices: [Data] = jsonl.split(omittingEmptySubsequences: true, whereSeparator: { (byte: UInt8) in byte == 0x0A })
        let lines: [OpLogChain.Line] = slices
            .map { (raw: Data) -> OpLogChain.Line in
                let data = Data(raw)
                return OpLogChain.Line(
                    bytes: data,
                    kind: OpLogChain.isSealLine(data) ? .seal : .op,
                    state: .verified)
            }
        return (
            OpLogChain.Verification(
                lines: lines, head: lines.last.map { OpLogChain.lineHash($0.bytes) },
                legacyCount: 0, verifiedCount: lines.count, unsealedCount: 0,
                foreignSealCount: 0, quarantined: [], breakReason: nil),
            digest, signature.key)
    }

    /// The context a reader holding a project URL builds for one document.
    ///
    /// Both halves capture the URL, the id and the table — all values — so the
    /// closures carry no shared mutable state and nothing has to be reasoned
    /// about across isolation.
    nonisolated public static func permitContext(
        forDocId docId: String, in projectURL: URL, trust: TrustTable?,
        statements: [Statement]? = nil,
        amendments: AmendmentPermits? = nil
    ) -> PermitContext {
        // One memo each, so a document spread over four actor files resolves
        // its class once and answers §4.5 once (fix round 1, I1 / minor (d)).
        //
        // And ONE manifest read for both disk questions (P3 plan 3 Task 6):
        // the class, where no statements were handed in, and the starter are
        // two answers about one file, so `ManifestPlacement` decodes it once
        // (and only if either is asked).
        let classMemo = PermitMemo<DocumentClass>()
        let unownedMemo = PermitMemo<PermitPartition.UnownedPiece>()
        let placement = ManifestPlacement(docId: docId, in: projectURL)
        return PermitContext(
            documentClass: {
                classMemo {
                    if let statements {
                        return DocumentClass.resolve(docId: docId, statements: statements)
                    }
                    return placement.documentClass
                }
            },
            unowned: {
                unownedMemo {
                    guard let trust else { return .nobodyHasWrittenItsText }
                    return unownedPiece(
                        forDocId: docId, in: projectURL, trust: trust,
                        startedBy: placement.startedBy(ofPiece: docId))
                }
            },
            amendments: amendments,
            startedBy: { placement.startedBy(ofPiece: docId) })
    }
}

/// **Where a document sits and who started its piece, from ONE manifest**
/// (P3 plan 3 Task 6).
///
/// The write side asks two questions of the manifest in a narrowed book —
/// the document's CLASS (`DocumentClass.resolve`) and the piece's recorded
/// STARTER (`StructureItem.startedBy`, Option A) — and each used to decode
/// the file on its own, so every ask read it twice. This answers both from
/// one value, read at most once and only if either is asked: a book that has
/// narrowed nobody, under a permit that never needs the class, reads nothing
/// (`LocalWritePermit.answersWithoutTheClass`), exactly as before.
///
/// **One value, both answers, always** — never the class from one manifest
/// and the starter from another. A caller that HOLDS a manifest (the Mac's
/// door, from the window's live copy — ruling AD) passes it with
/// `init(docId:manifest:)` and the disk is never read; one holding only a
/// project URL uses `init(docId:in:)`, and the disk is read once, with
/// `OpLogStore.manifestStatements`' own rules: a manifest that will not read
/// is no statements and no starter, which WIDENS (every id a piece, today's
/// rule for the opening) and is reported, never thrown.
///
/// `@unchecked Sendable` for `PermitMemo`'s reason: its answers are handed to
/// `@Sendable` closures, and the one piece of state is behind its lock.
public final class ManifestPlacement: @unchecked Sendable {

    /// The document asked about.
    public let docId: String

    private let read: @Sendable () -> ProjectManifest?
    private let memo = PermitMemo<ProjectManifest?>()

    /// Read off the manifest on disk, once, when first asked.
    public init(docId: String, in projectURL: URL) {
        self.docId = docId
        self.read = { OpLogStore.decodedManifest(in: projectURL) }
    }

    /// Answered from a manifest the caller already holds; the disk is never
    /// read. Nil is a manifest nobody could read: no statements, no starter.
    public init(docId: String, manifest: ProjectManifest?) {
        self.docId = docId
        self.read = { manifest }
    }

    private var manifest: ProjectManifest? { memo(read) }

    /// Where `docId`'s stream sits — `OpLogStore.documentClass(forDocId:in:)`'s
    /// answer, from this placement's one manifest.
    public var documentClass: DocumentClass {
        DocumentClass.resolve(docId: docId, statements: manifest?.statements ?? [])
    }

    /// Who started `piece`, from the same manifest — nil where it records
    /// nobody, names no such item, or will not read.
    public func startedBy(ofPiece piece: String) -> String? {
        manifest?.startedBy(ofPiece: piece)
    }
}
