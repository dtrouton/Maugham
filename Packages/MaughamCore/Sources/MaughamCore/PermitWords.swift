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
}
