import Foundation

/// **What kind of thing a stream holds** (P3 spec §4.1).
///
/// A permit is a sentence about *places* — "inside their pieces", "project
/// statements", "on the project stream: task ops" — and a stream on disk is a
/// document id. This enum is the one translation between the two, so that
/// `Permit.allows` can be a table over classes rather than a table over ids
/// with a lookup folded into every row.
///
/// **Six classes, and two of them are not `Op` streams.** A translation lives in
/// its own `TranslationStore` file and an inbox row in `InboxStore`'s; neither
/// is reachable from a manuscript document id, which is why `resolve` never
/// returns them. Their callers (P3a Task 6) construct `.translation(piece:)` and
/// `.inbox` directly, because they already know which stream they are reading.
///
/// **An id nothing knows is a piece in nobody's scope** (spec §4.1). That is the
/// safe answer and not a shrug: a document id this manifest does not carry is
/// either a piece that has not synced yet or a piece that was trashed, and in
/// both cases the honest reading of an author-of-some-pieces' permit is *this
/// is not one of hers*. Her own new piece is not refused on that account — §4.5
/// holds it PENDING, which is the load seam's decision and not this table's.
public enum DocumentClass: Equatable, Hashable, Sendable {

    /// A manuscript document: a chapter, a scene, a loose piece. The associated
    /// value is the document id, which is what an author-of-some-pieces' scope
    /// list holds.
    case piece(String)

    /// A statement *about one piece* — today only a per-document craft intent.
    /// **The associated value is the PIECE's id, never the statement's**: the
    /// scope test is on what the statement is about, because that is what the
    /// permit's `pieces` list names. A statement has an id of its own and it
    /// appears in nobody's scope.
    case pieceStatement(piece: String)

    /// A statement about the whole book — intent, visual language, lessons,
    /// first reader, an edition brief. The book author's alone (spec §2).
    case projectStatement

    /// `__project__`, the synthetic stream carrying project-scope task ops.
    case projectStream

    /// One language's translation of a piece. Not an `Op` stream; the value is
    /// the PIECE's id, for the same reason `pieceStatement` carries one.
    case translation(piece: String)

    /// The capture inbox. Not an `Op` stream, and the one class whose whole
    /// content is the reviewer row.
    case inbox

    /// The synthetic document id of the project stream.
    ///
    /// Spelled here because this is the one type whose job is to say what a
    /// stream IS; `OpLogStore` and `ProjectStore+Tasks` each carry their own
    /// copy for their own reasons (a filename filter and a task anchor) and are
    /// deliberately left alone — this task does not refactor them.
    public static let projectStreamDocId = "__project__"

    // MARK: - Resolving one

    /// The class of the stream with this document id.
    ///
    /// **Statements first, then everything else is a piece.** A manuscript
    /// document and an id the manifest has never heard of reach the same answer
    /// — `.piece(docId)` — so the walk of `structure` that would tell them apart
    /// buys nothing and is not performed. The only thing this needs from a
    /// manifest is its statements, which is what `resolve(docId:statements:)`
    /// takes; this overload is the spec's spelling of it.
    public static func resolve(docId: String, manifest: ProjectManifest) -> DocumentClass {
        resolve(docId: docId, statements: manifest.statements)
    }

    /// The narrow form: the only manifest fact this decision uses.
    ///
    /// **A statement whose scope this build does not recognise reads as a
    /// project statement.** It is the most restrictive of the two statement
    /// classes, and it is the one whose refusal word is right whatever the
    /// statement turns out to be about — `.statement` rather than a sentence
    /// about somebody's manuscript. Resolving it as `.piece(docId)` instead
    /// would hang the answer on whether a statement's own id happened to appear
    /// in somebody's scope list, which is a coincidence and not a permission.
    public static func resolve(docId: String, statements: [Statement]) -> DocumentClass {
        if docId == projectStreamDocId { return .projectStream }
        if let statement = statements.first(where: { $0.id == docId }) {
            switch statement.scope {
            case .project:
                return .projectStatement
            case .document(let pieceId):
                return .pieceStatement(piece: pieceId)
            case .unknown:
                return .projectStatement
            }
        }
        return .piece(docId)
    }

    /// The piece this class is about, when it is about one.
    ///
    /// The three classes that carry a piece id carry it for one reason — the
    /// scope test — so the test asks once, here, rather than three times in a
    /// switch that could grow a fourth arm and forget.
    public var piece: String? {
        switch self {
        case .piece(let id): return id
        case .pieceStatement(let piece): return piece
        case .translation(let piece): return piece
        case .projectStatement, .projectStream, .inbox: return nil
        }
    }
}
