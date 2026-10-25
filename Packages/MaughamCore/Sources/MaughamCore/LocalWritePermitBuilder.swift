// Packages/MaughamCore/Sources/MaughamCore/LocalWritePermitBuilder.swift
import Foundation

/// **The write side's one question, built** — the permit a device's own hand
/// writes under (`LocalWritePermit`), the annotation-ownership rule beside it,
/// and the Option-A starter facts both consult (`startedBy`, `unownedPiece`).
/// Pure over the table it is handed plus the reads the doc comments name.
/// Split out of `OpLogStore` (foundations plan 6).
///
/// **Not a door.** `OpLogStore.localWritePermit(as:documentClass:)` stays the
/// ONE question (tripwire 46): it resolves the table on its own actor,
/// synchronously (`trustOnThisActor`, through `registerTable`'s remembered-
/// then-keyless fallback), and forwards here. The construction entries are
/// `internal` so no app can hand this a table of its own and skip the door;
/// `TripwireGrepTests.localWritePermitAllowed` admits `LocalWritePermit(`
/// here and in `LocalWritePermit.swift` only, counted by `typeAllowanceBounds`.
public enum LocalWritePermitBuilder {

    /// **The same builder, asked through ONE manifest read** (P3 plan 3 Task
    /// 6) — the class and the starter both from `placement`, so a narrowed
    /// book decodes its manifest once per ask rather than once per question,
    /// and a book that never needs either decodes nothing. Every caller that
    /// resolves both off a manifest comes here; a caller that CONSTRUCTS its
    /// class (the translation pipeline's `.translation(piece:)`) keeps the
    /// closure form below.
    ///
    /// `table` is the door's resolved register (`OpLogStore.registerTable`).
    static func permit(
        as actor: DeviceActor,
        placement: ManifestPlacement,
        table: TrustTable?,
        in projectURL: URL
    ) -> LocalWritePermit {
        permit(
            as: actor,
            documentClass: { placement.documentClass },
            startedBy: { placement.startedBy(ofPiece: $0) },
            figuresOfPiece: { placement.figureIds(ofPiece: $0) },
            table: table, in: projectURL)
    }

    /// **The permit `OpLogStore.localWritePermit` answers with** (P3a Task 8),
    /// from the table the door resolved — nil where this project has never
    /// had a register.
    ///
    /// `documentClass` is a CLOSURE because resolving one means decoding a
    /// manifest, and the neutral case never needs it: a permit that covers the
    /// whole book answers `.yes` in the hardest class there is, so the closure
    /// is not called at all. `PermitPartition`'s `unowned` is the same shape
    /// for the same reason.
    ///
    /// **And who started the piece** (P3c plan 2, Option A). In a book in
    /// which somebody is narrowed, a piece's recorded starter decides two
    /// things: which Mac mints its opening (`LocalWritePermit.startedHere`,
    /// OA-1/OA-2), and whether an author of some pieces may write it before
    /// the root has said whose it is (`writesAsItsStarter`, OA-3). `startedBy`
    /// answers the starter for a piece id; nil reads it off the manifest on
    /// disk, and a caller holding a live manifest passes its own. It is asked
    /// only in a narrowed book and only for a piece, so a book that has
    /// narrowed nobody — every book on disk before P3 — pays for none of it
    /// and answers exactly as before.
    static func permit(
        as actor: DeviceActor,
        documentClass: () -> DocumentClass,
        startedBy: ((String) -> String?)?,
        figuresOfPiece: ((String) -> [String])? = nil,
        table: TrustTable?,
        in projectURL: URL
    ) -> LocalWritePermit {
        // **A project that has never had a register pays nothing at all** — not
        // a folder read, not a verify, not a question. The test is
        // `verifiedRegistry`'s own first one, asked through its own spelling:
        // the FOLDER or this device's MEMORY of one, because a register deleted
        // wholesale is restored from that memory and treating its absence as
        // *no register* would make deleting one an escape from a demotion.
        // `table` is that answer, asked by the door (`OpLogStore.registerTable`).
        let permit = table.map(\.myTimeline.current) ?? .bookAuthor
        guard let table, table.hasNarrowingPermits else {
            if LocalWritePermit.answersWithoutTheClass(permit, as: actor) {
                return LocalWritePermit(permit: permit, actor: actor, documentClass: nil)
            }
            return LocalWritePermit(
                permit: permit, actor: actor, documentClass: documentClass())
        }
        // **A narrowed book: the starter rule binds** — the root's Mac too
        // (OA-2), which is why the class is resolved here even under a permit
        // that could otherwise skip it: the piece id is what the starter is
        // recorded against. A figure asks its PIECE's starter (Denver's ruling
        // R-D4, closing R-6a-10): both arms below — hers and a book author's
        // yield — reach it exactly as they reach the piece's text
        // (`Permit.startersPiece(of:)`).
        let cls = documentClass()
        // The disk's answers, where the caller handed none, from ONE
        // manifest read for both (the starter, the piece's figures).
        let onDisk = Permit.startersPiece(of: cls).map { ManifestPlacement(docId: $0, in: projectURL) }
        guard let piece = Permit.startersPiece(of: cls),
              let starterId = (startedBy ?? { onDisk?.startedBy(ofPiece: $0) })(piece)
        else {
            return LocalWritePermit(permit: permit, actor: actor, documentClass: cls)
        }
        // **A starter that is GONE binds nothing** (Rulings L (b), M, N): a
        // device the register shows revoked or retired will never mint this
        // piece's opening, so today's rule applies and the piece is not left
        // unopenable. Every other starter — unknown, a stranger, another
        // root's member, a Mac on no chain — binds: this Mac waits.
        guard table.starterStanding(starterId) != .gone else {
            return LocalWritePermit(permit: permit, actor: actor, documentClass: cls)
        }
        let starter = table.starter(ofPieceStartedBy: starterId)
        // A figure edit claims the piece as a text edit does (ruling R-D4):
        // `unownedPiece` reads the piece's figure streams too.
        let pieceFigures = { (figuresOfPiece ?? { onDisk?.figureIds(ofPiece: $0) ?? [] })(piece) }
        // **Option A's arm** — the same three facts the partition's own arm
        // asks (`PermitPartition.appliesOnItsWritersOwnMac`), on the write
        // side: her own device started it, it was not taken from her, and no
        // book author has written a word of it. `unownedPiece` classifies the
        // document's files, so it is asked last and only where the permit
        // layer's §4.5 shape already holds for her words.
        let mine = starter != .somebodyElse
            && permit.startsAPieceNobodyHasClaimed(
                .op(.typingBurst), in: cls, actor: actor)
            && !table.myTimeline.wasTakenFromThem(piece: piece)
            && unownedPiece(
                forDocId: piece, in: projectURL, trust: table, startedBy: starterId,
                figures: pieceFigures())
                == .nobodyHasWrittenItsText
        // **The same fact from the other side** (fix wave, Ruling U): a book
        // author's hand in a piece somebody else started and nobody has
        // claimed. Her arm and this one cannot both hold (hers needs a starter
        // that is not somebody else), and the cheap questions come first:
        // `unownedPiece` classifies the document's files and is asked last.
        let unsettled: LocalWritePermit.UnsettledStarter?
        if starter == .somebodyElse,
           permit.claimsAPieceByWritingItsText(actor: actor),
           !table.starterAuthors(starterId, cls),
           unownedPiece(
               forDocId: piece, in: projectURL, trust: table, startedBy: starterId,
               figures: pieceFigures())
               == .nobodyHasWrittenItsText {
            unsettled = .init(
                deviceId: starterId,
                name: table.label(forDeviceSlug: DeviceSlug.make(from: starterId).raw))
        } else {
            unsettled = nil
        }
        // `startedHere` is about the piece's OPENING (`mayMintOpening`), and a
        // figure has none — its load emits nothing — so a figure keeps nil,
        // today's rule.
        let startedHere: Bool? = {
            if case .piece = cls { return starter == .thisDevice }
            return nil
        }()
        return LocalWritePermit(
            permit: permit, actor: actor, documentClass: cls,
            startedHere: startedHere,
            writesAsItsStarter: mine,
            unsettledStarter: unsettled)
    }

    /// **Whose annotation it is, for this document** — the rule
    /// `OpLogStore.annotationAmendments` resolves once, from the table the
    /// door resolved (`registerTable`); nil is a project with no register.
    ///
    /// A project with no register answers `honourEverything`, which is the
    /// pre-P3a behaviour exactly.
    /// `permits` is what the LOAD collected — the permit each amendment line
    /// was judged under, as of that line (`AmendmentPermits`). Empty is the
    /// honest answer for a book with no events and for a caller that did not
    /// ask, and an amendment with no entry falls back to the signer's current
    /// permit, which is what those cases mean.
    ///
    /// **It takes the CARRIER, not one of its products** (P3b Task 2). The
    /// partition fills two maps now — the permit each amendment line was
    /// written under, and which lines the unsigned door found inside the
    /// book's photograph — and a door that took one of them by value is a door
    /// the next product has to be remembered at. `AmendmentPermits` is what
    /// travels through `PermitContext`; this reads it whole.
    static func annotationAmendments(
        table: TrustTable?,
        from amendments: AmendmentPermits?,
        documentClass: @escaping @Sendable () -> DocumentClass
    ) -> AnnotationAmendments {
        guard let table else { return .honourEverything }
        return .judged(
            by: table,
            permits: amendments?.resolved ?? [:],
            insideTheUnsignedSnapshot:
                amendments?.resolvedInsideTheUnsignedSnapshot ?? [],
            class: documentClass)
    }

    // MARK: - The Option-A starter facts

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
        ManifestPlacement(docId: docId, in: projectURL).startedBy(ofPiece: docId)
    }

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
        let placement = ManifestPlacement(docId: docId, in: projectURL)
        return unownedPiece(
            forDocId: docId, in: projectURL, trust: trust,
            startedBy: placement.startedBy(ofPiece: docId),
            figures: placement.figureIds(ofPiece: docId))
    }

    /// The same question, for a caller that already holds the piece's
    /// recorded starter (ruling G: a book author's `bootstrap` claims the
    /// piece unless somebody else started it) and the figures the registry
    /// gives it. **A figure's lines count as the piece's text** (Denver's
    /// revised ruling R-D4): a figure belongs to its piece and its ops sit on
    /// the manuscript-text rung (ruling D-c), so a book author who edits only
    /// a figure claims the piece exactly as a keystroke in its text would —
    /// and the read side, which asks this same function, sets the starter's
    /// held lines aside at the same moment.
    nonisolated public static func unownedPiece(
        forDocId docId: String, in projectURL: URL, trust: TrustTable,
        startedBy: String?, figures: [String] = []
    ) -> PermitPartition.UnownedPiece {
        let urls = ([docId] + figures).flatMap { OpLogStore.opLogFileURLs(forDocId: $0, in: projectURL) }
        for url in urls {
            guard let bytes = (try? OpLogStore.readCoordinated(url: url, presenter: nil)) ?? nil,
                  let stream = PermitMark.stream(of: url)
            else { continue }
            let classified = OpLogClassifier.classify(
                url: url, bytes: bytes, state: nil, trust: trust)
            guard let verification = classified.verification else {
                // A settled segment was never walked, so there is no
                // `Verification` to read — but its lines ARE this document's
                // history, so the question has to reach them. The lines are the
                // decompressed JSONL, every one of them applied, under the key
                // that settled the container.
                guard let settled = OpLogStore.settledSegmentVerification(
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
}
