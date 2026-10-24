import Foundation

/// **One figure in the manifest's `figures` registry** (report plan 6a,
/// ruling D-e) — the truth for a figure's name, kind, piece and path.
///
/// A figure's CONTENT and its lifecycle (created, parked, resumed) are its own
/// op-log stream, keyed by `id`; this record is the identity the stream does
/// not carry. It is the statements' shape (`Statement`): the registry entry
/// says what the thing is, what it belongs to and where its render sits, and
/// the op log holds everything that changes as it is edited. A rename is a
/// change to this record, never an op.
///
/// **`piece` is whose figure it is** (Denver's ruling, 2026-10-24): the piece
/// it was created in. That piece's author may edit it, and so may anybody who
/// may write the whole book. A figure created with no piece (`nil`) is the
/// whole-book authors' alone. `DocumentClass.resolve` reads this field into
/// `.figure(id:piece:)`, and the permit's scope test reads it from there.
public struct FigureRecord: Codable, Equatable, Sendable {

    /// The figure's document id — `fig-<8 lowercase hex>`, the stream's docId.
    /// Never the name: a name is renameable and may contain a dot, and an op
    /// log's filename takes its doc id as the text before the first dot.
    public var id: String

    /// The name the writer and formulas call it by (`cashflow`).
    public var name: String

    /// A table or an image.
    public var kind: FigureKind

    /// The piece it belongs to, or nil for a figure of the whole book.
    public var piece: String?

    /// Project-relative: `figures/<name>.csv` for a table, `figures/<file>`
    /// for an image. A derived render, never read as truth (tripwire 20).
    public var path: String

    public init(id: String, name: String, kind: FigureKind, piece: String?, path: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.piece = piece
        self.path = path
    }
}
