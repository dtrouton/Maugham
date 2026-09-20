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
public struct PermitContext: Sendable {

    /// Where this stream sits. Called at most once per file, and only where
    /// some line's (permit, actor) pair makes the answer turn on it.
    public let documentClass: @Sendable () -> DocumentClass

    /// §4.5's document-level fact. Called at most once per file, and only where
    /// an author of some pieces has written manuscript text with her own hand
    /// in a piece outside her scope.
    public let unowned: @Sendable () -> PermitPartition.UnownedPiece

    public init(
        documentClass: @escaping @Sendable () -> DocumentClass,
        unowned: @escaping @Sendable () -> PermitPartition.UnownedPiece
    ) {
        self.documentClass = documentClass
        self.unowned = unowned
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
        guard let data = try? Data(  // adr-0018-ok: project manifest JSON read, not manuscript
            contentsOf: projectURL.appendingPathComponent(ProjectManifest.fileName)),
              let manifest = try? ProjectManifest.makeDecoder()
                .decode(ProjectManifest.self, from: data)
        else { return [] }
        return manifest.statements
    }

    /// **§4.5's pass 1, over every file of one document**: has any key holding
    /// an author-of-the-whole-book permit applied a manuscript-text line here?
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
        for url in opLogFileURLs(forDocId: docId, in: projectURL) {
            guard let bytes = (try? readCoordinated(url: url, presenter: nil)) ?? nil,
                  let streamKey = PermitMark.streamKey(of: url)
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
                    in: settled.verification, streamKey: streamKey,
                    fileSegmentDigest: settled.digest, trust: trust,
                    settledByKey: settled.key) { return .aBookAuthorHasWrittenItsText }
                continue
            }
            if PermitPartition.bookAuthorWroteManuscriptText(
                in: verification, streamKey: streamKey,
                fileSegmentDigest: classified.verifiedSegmentDigest,
                trust: trust) { return .aBookAuthorHasWrittenItsText }
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
        let lines = jsonl
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { raw -> OpLogChain.Line in
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
        statements: [Statement]? = nil
    ) -> PermitContext {
        PermitContext(
            documentClass: {
                if let statements {
                    return DocumentClass.resolve(docId: docId, statements: statements)
                }
                return documentClass(forDocId: docId, in: projectURL)
            },
            unowned: {
                unownedPiece(forDocId: docId, in: projectURL, trust: trust)
            })
    }
}
