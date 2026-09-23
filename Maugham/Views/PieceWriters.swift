import Foundation
import MaughamCore

/// **Whose piece is whose** (signed op log P3b Task 9, spec §7.5).
///
/// P3a made a permit that can name PIECES; nothing on screen said so. This is
/// the one decision behind the two places that now do: the Inspector's
/// *Written by* row and the altitude table's **Writer** column. Both read this
/// value, so they cannot name different people for one chapter.
///
/// **A book with one writer in it draws nothing at all** — no row, no column.
/// That is the point rather than an omission: a field reading *Written by
/// Denver* on every chapter of a book Denver wrote alone is noise, and noise on
/// every row is what trains an eye past the one row that matters. A book of
/// whole-book co-authors draws nothing for the same reason, which is the
/// judgement this file makes and states: **only a permit whose scope NAMES
/// pieces puts a name anywhere**. The cost is real and accepted — three people
/// who may each write the whole book get no reminder here of who the other two
/// are. People & Devices is the surface that lists them, and it lists them
/// whatever their permit.
///
/// **It asks the permit layer and nothing else.** *Does this permit author
/// this piece* is `Permit.authors(.piece(id))`; *does its scope name pieces at
/// all* is `PermitControl.pieces(displaying:)`, the accessor the People &
/// Devices row already draws from. No rung is compared here (tripwire 47), and
/// no `PersonRecord.role`/`.scope`/`.pieces` is read (tripwire 43): the permit
/// in force is `PermitTimeline.current`, because a record is re-signed in
/// place and forgets its own past — read the field instead and a person
/// narrowed this morning keeps a name on chapters she was widened off.
///
/// **The tree is untouched** (parent spec §5). The binder says what a piece is
/// called and where it sits; who may write in it is a question for the place
/// the writer has already gone to ask about that piece.
///
/// **It lives beside `PeopleAndDevicesModel` rather than in MaughamCore** for
/// two reasons, in this order: it reads `PermitControl`, a Mac view-layer
/// display helper, and it must answer *who is in this book* with the same rule
/// the People & Devices pane lists its rows by (`table.myRoot` →
/// `Registry.chain(underRoot:)`) — a copy in Core would be a second answer to
/// that question, sitting one module away from the first. Nothing on the phone
/// asks it; P3c decides what the phone shows.
struct PieceWriters: Equatable, Sendable {

    /// Document id → the labels whose permit names that piece, sorted and
    /// de-duplicated. A piece nobody's scope names has no entry at all, so an
    /// empty dictionary is exactly *this book says nothing about authorship*.
    private let byPiece: [String: [String]]

    /// A book that names nobody — the one-author book, the book of whole-book
    /// co-authors, and the state a surface holds before its read comes back.
    static let none = PieceWriters(byPiece: [:])

    private init(byPiece: [String: [String]]) {
        self.byPiece = byPiece
    }

    /// True when nothing is drawn anywhere: no Inspector row, no Writer
    /// column. Asked of the BOOK, once, so a column does not appear over a
    /// table of blanks because one chapter in forty has a scoped author —
    /// that is the column doing its job, and the blanks are the answer for the
    /// rest.
    var isEmpty: Bool { byPiece.isEmpty }

    /// The labels naming this piece, in alphabetical order.
    func writers(of pieceID: String) -> [String] { byPiece[pieceID] ?? [] }

    /// *Sam* · *Ada and Sam* · *Ada, Jo and Sam* — nil where nobody's scope
    /// names the piece, which is what a surface draws nothing for.
    func sentence(for pieceID: String) -> String? {
        Self.sentence(naming: writers(of: pieceID))
    }

    /// The list, in English. Kept static and separate from the lookup so the
    /// wording is assertable on its own.
    static func sentence(naming names: [String]) -> String? {
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ")
                + " and \(names[names.count - 1])"
        }
    }

    // MARK: - What the two surfaces call it

    /// The Inspector row's label. One spelling, two inspectors — the document
    /// arm in the right column and the Collection's loose-piece arm.
    static let rowTitle = "Written by"

    /// The row's accessibility identifier. A `LabeledContent` in a `Form`
    /// publishes no `NSTextField` on this SDK, so *is the row drawn* is asked
    /// of the identifier rather than of a string (the same instrument
    /// `PassLadder.identifier(forPass:)` gave the ladder rows).
    static let rowIdentifier = "inspector.writtenBy"

    /// The altitude table's column header.
    static let columnTitle = "Writer"

    // MARK: - The decision

    /// Who writes which piece, from a verified registry and the table it was
    /// resolved with.
    ///
    /// - Parameters:
    ///   - registry: the verified records, as `TrustResolution` resolved them.
    ///   - table: the trust table from that same resolve — never a second
    ///     read, so the permits and the records describe one folder.
    ///   - pieces: this book's own documents. A scope naming a piece that is
    ///     not here names nothing: a document id is not a row, and a chapter
    ///     that has been deleted is not one either.
    static func resolve(
        registry: Registry, table: TrustTable, pieces: [PermitControl.Piece]
    ) -> PieceWriters {
        // The chain this device judges by, and nobody else — the rule the
        // People & Devices pane lists its rows by. A Mac that judges by no
        // root at all (keyless, or a registry it could not read) knows of
        // nobody, and says so rather than guessing.
        guard let root = table.myRoot else { return .none }
        let members = registry.chain(underRoot: root)

        var byPiece: [String: Set<String>] = [:]
        for record in registry.people
        where members.contains(record.person) && !record.isRevoked {
            // The permit in force NOW, from the timeline. A revoked person is
            // already gone above: this row answers *who writes this piece*,
            // and somebody the writer has removed writes nothing anywhere.
            // What she already wrote stays in the manuscript, and History is
            // where it is accounted for.
            let permit = table.timeline(forPerson: record.person).current
            // Only a scope that NAMES pieces puts a name on a row. An author
            // of the whole book authors every piece and would otherwise land
            // on all of them; a reviewer names nothing and would land on none.
            guard !PermitControl.pieces(displaying: permit).isEmpty else { continue }
            for piece in pieces where permit.authors(.piece(piece.id)) {
                byPiece[piece.id, default: []].insert(record.label)
            }
        }
        return PieceWriters(
            byPiece: byPiece.compactMapValues { $0.isEmpty ? nil : $0.sorted() })
    }

    // MARK: - Reading the folder

    /// **One registry read, off the main actor** — the shape
    /// `ProjectSettingsSheet` and `HistoryPane` already use, for its reason:
    /// the registry read and the trust table are one act
    /// (`TrustResolution.resolveVerified`), because a surface that read the
    /// folder twice would describe a permit off a registry the verdicts were
    /// not taken from.
    ///
    /// A caller holds the answer in `@State` and looks a row up in it; nothing
    /// reads the folder from `body` and nothing resolves per row (tripwire 4).
    ///
    /// **A registry this Mac cannot read draws nothing**, exactly as a
    /// one-author book does. That is a deliberate narrowing of RULING-54's
    /// *refuse out loud* to the surfaces that can act on it: People & Devices
    /// names the file and says what Maugham will not do over it
    /// (`DeviceStanding.refused`), and History dates it. An adornment beside a
    /// chapter title has no verb to offer and nowhere to put a file path, so
    /// the honest thing it can do is not put a name on a piece it cannot
    /// vouch for. The cost, stated: a co-written book with one damaged record
    /// loses the column until the record is restored — a missing adornment,
    /// never a wrong name.
    @MainActor
    static func read(
        projectURL: URL, pieces: [PermitControl.Piece]
    ) async -> PieceWriters {
        // `Document.loadIdentities` / `.loadRegistryCache` rather than
        // `LocalIdentities.current` and `.shared` — `NewPieceModifier`'s own
        // reach, for its reason: this Mac has ONE set of keys and one memory
        // of what it has verified, and a surface that asked a second source
        // would answer off a registry the loads were not judged by.
        let mine = Document.loadIdentities
        let cache = Document.loadRegistryCache
        return await Task.detached(priority: .utility) {
            guard let resolved = try? TrustResolution.resolveVerified(
                projectURL: projectURL, identities: mine, cache: cache)
            else { return PieceWriters.none }
            return resolve(
                registry: resolved.registry, table: resolved.table, pieces: pieces)
        }.value
    }
}
