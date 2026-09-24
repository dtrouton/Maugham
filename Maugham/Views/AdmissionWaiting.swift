// Maugham/Views/AdmissionWaiting.swift
import Foundation
import MaughamCore

/// **What a stranger has waiting, and where, in the writer's terms** (P3b
/// smoke find F2).
///
/// The admission sheet said *1 note waiting* about Kit's paragraph of prose,
/// with nothing but a four-character code to say who he was or what he had
/// written. This value says it the way a writer would: *1 paragraph waiting in
/// “Chapter 3”*, with the first words of it beneath.
///
/// Pure and folder-free, built from the counts the loads already produced
/// (`HeldLineUnion.waiting`/`.captures`) and the manifest's titles, so every
/// sentence is decidable with no window (tripwire 33). What a line IS was
/// decided by `HeldLines.Waiting` (which asks `Deriver.appliesToManuscript`);
/// nothing here restates it, and nothing here compares a permit (tripwire 47).
struct AdmissionWaiting: Equatable {
    /// One piece the stranger has written in, and what is waiting there.
    struct Piece: Equatable {
        let title: String
        let waiting: HeldLines.Waiting
    }

    /// In binder order, where the binder names them; a piece the manifest has
    /// no title for comes last, as *an untitled piece*.
    let pieces: [Piece]
    /// Held captures from the capture stream — never paragraphs or notes.
    let captures: Int

    /// How many piece titles the line names before it counts the rest.
    static let namedPieceLimit = 3
    /// How much of the first paragraph the sheet shows.
    static let peekLength = 120
    static let untitled = "an untitled piece"

    // MARK: - Building it

    /// The description of one holder's waiting lines, or nil when there is
    /// nothing to describe — the sheet then says the plain count, as before.
    ///
    /// `order` is the binder's documents as `(docId, title)`, in binder order:
    /// the same list the sheet's piece picker draws, so a title here is
    /// spelled the way the writer sees it there.
    static func describe(
        holder: String, waiting: [String: [String: HeldLines.Waiting]],
        captures: [String: Int], order: [(id: String, title: String)]
    ) -> AdmissionWaiting? {
        let byDoc = (waiting[holder] ?? [:]).filter { !$0.value.isEmpty }
        let captured = captures[holder] ?? 0
        guard !byDoc.isEmpty || captured > 0 else { return nil }
        var pieces: [Piece] = []
        var placed: Set<String> = []
        for entry in order {
            guard let what = byDoc[entry.id] else { continue }
            pieces.append(Piece(title: entry.title, waiting: what))
            placed.insert(entry.id)
        }
        for docId in byDoc.keys.sorted() where !placed.contains(docId) {
            pieces.append(Piece(title: untitled, waiting: byDoc[docId]!))
        }
        return AdmissionWaiting(pieces: pieces, captures: captured)
    }

    // MARK: - What the sheet says

    /// Every piece's lines as one — what the line counts. A paragraph id is
    /// unique within its piece and nowhere else, so each piece's ids are kept
    /// apart before the union: two pieces' paragraphs are never one paragraph.
    var total: HeldLines.Waiting {
        pieces.enumerated().reduce(HeldLines.Waiting()) { sum, entry in
            var own = entry.element.waiting
            own.paragraphIds = Set(own.paragraphIds.map { "\(entry.offset)/\($0)" })
            return sum.merged(with: own)
        }
    }

    /// ***1 paragraph waiting in “Chapter 3”*** — the kinds, then the pieces by
    /// title, then any captures. Nil only for a description of nothing.
    var line: String? {
        var clauses: [String] = []
        if let phrase = total.phrase {
            clauses.append("\(phrase.text) waiting in \(Self.places(pieces.map(\.title)))")
        }
        if captures > 0 {
            let noun = captures == 1 ? "1 capture" : "\(captures) captures"
            clauses.append(clauses.isEmpty
                ? "\(noun) waiting in the Inbox" : "\(noun) in the Inbox")
        }
        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: ", and ")
    }

    /// The first words of the first held paragraph, in quotation marks, cut
    /// at a word where it runs long. Nil where nothing held is prose.
    var peek: String? {
        guard let words = pieces.lazy.compactMap(\.waiting.peek).first else { return nil }
        return "\u{201C}\(Self.shortened(words))\u{201D}"
    }

    /// *“A”*, *“A” and “B”*, *“A”, “B” and “C”*, *“A”, “B”, “C” and 2 other
    /// pieces*. A title is quoted; the untitled placeholder is not, because it
    /// is not anybody's word for the piece.
    static func places(_ titles: [String]) -> String {
        let quoted = titles.map { $0 == untitled ? $0 : "\u{201C}\($0)\u{201D}" }
        let named = Array(quoted.prefix(namedPieceLimit))
        let rest = quoted.count - named.count
        var parts = named
        if rest > 0 {
            parts.append(rest == 1 ? "1 other piece" : "\(rest) other pieces")
        }
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    /// Cut at the last word boundary before `peekLength`, with an ellipsis;
    /// a paragraph that fits is left whole. Line breaks become spaces, so the
    /// peek stays one line on a sheet.
    static func shortened(_ words: String) -> String {
        let flat = words.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > peekLength else { return flat }
        let cut = flat.prefix(peekLength)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
