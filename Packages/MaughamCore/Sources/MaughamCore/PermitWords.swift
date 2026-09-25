import Foundation

/// **The words the writer reads for each rung** — in Core so the Mac and the
/// phone say the same thing about the same permit (signed op log P3c plan 2,
/// Task 1; tripwire 19).
///
/// A rung is a storage fact (`Permit.Rung`); these are the app's sentences
/// about it. Nothing here decides what a rung MEANS — that is `Permit.allows`
/// (tripwire 47) — they only name it.
extension Permit.Rung {
    /// What the control calls it.
    public var title: String {
        switch self {
        case .reviewer: return "Reviewer"
        case .somePieces: return "Author of some pieces"
        case .wholeBook: return "Author of the whole book"
        }
    }

    /// One line under the control saying what the choice means in the
    /// manuscript, because *reviewer* is a word with a dozen meanings in this
    /// app and exactly one here.
    public var explanation: String {
        switch self {
        case .reviewer:
            return "Can leave notes and send captures. Anything they write "
                + "in the manuscript itself is set aside."
        case .somePieces:
            return "Can write anything in the pieces you choose, and leaves "
                + "notes everywhere else."
        case .wholeBook:
            return "Can write anywhere in the book, as you can."
        }
    }

    /// Does this choice need the piece picker?
    public var picksPieces: Bool { self == .somePieces }
}

/// The sentences built from a rung.
public enum PermitWords {

    /// **What somebody may write, in the writer's own words** — the rung's
    /// title, with the pieces where there are any.
    ///
    /// A rung this build cannot draw (`nil`) says so rather than guessing: the
    /// record carries a word a later Maugham wrote, and naming it *author*
    /// would be this device deciding something it does not know.
    public static func sentence(rung: Permit.Rung?, pieceTitles: [String]) -> String {
        guard let rung else {
            return "This book says something about what they may write that "
                + "this version of Maugham doesn\u{2019}t recognise."
        }
        guard rung.picksPieces else { return rung.title }
        guard !pieceTitles.isEmpty else {
            return "\(rung.title) \u{2014} none chosen yet"
        }
        return "\(rung.title): \(pieceTitles.joined(separator: ", "))"
    }

    /// **The titles of the pieces a permit names, in the binder's own order**,
    /// with an id this manifest does not carry drawn as `unknownPiece` — a
    /// document id is not a thing a writer has ever seen, so it is never shown
    /// raw (P3c plan 2, Task 6: moved from the Mac's People & Devices so the
    /// phone's Settings names the same pieces the same way, tripwire 19).
    ///
    /// `pieces` is every piece the manifest carries, as (id, title) pairs in
    /// binder order; `unknownPiece` is the surface's own noun for one it
    /// cannot find (*this Mac*, *this iPhone*).
    public static func pieceTitles(
        of chosen: Set<String>,
        among pieces: [(id: String, title: String)],
        unknownPiece: String
    ) -> [String] {
        guard !chosen.isEmpty else { return [] }
        let known = Set(pieces.map(\.id))
        return pieces.filter { chosen.contains($0.id) }.map(\.title)
            + chosen.subtracting(known).sorted().map { _ in unknownPiece }
    }

    /// Every piece a manifest's structure carries, in binder order. Groups are
    /// not pieces: a permit's scope names documents.
    public static func pieces(in structure: [StructureItem]) -> [(id: String, title: String)] {
        TreeWalk.collect(in: structure) { $0.type == .document }
            .map { (id: $0.id, title: $0.title) }
    }

    /// **What `permit` says somebody may write, in this book's own titles** —
    /// the rung read through `Permit.rung(of:)` (never compared to a literal,
    /// tripwire 47) and the pieces through `pieceTitles`.
    public static func sentence(
        for permit: Permit, in structure: [StructureItem], unknownPiece: String
    ) -> String {
        sentence(
            rung: Permit.rung(of: permit),
            pieceTitles: pieceTitles(
                of: Set(permit.wirePieces), among: pieces(in: structure),
                unknownPiece: unknownPiece))
    }
}
