import Foundation
import MaughamCore

/// A line diff of the proposal against what the statement says now (spec §10:
/// "a hand-tuned brief must not be clobbered blind"). Line-level on purpose —
/// a statement is short prose, and a word-level diff of two paragraphs that
/// share a topic and nothing else is noise.
enum StatementProposalDiff {
    struct Line: Equatable {
        enum Kind: Equatable { case same, added, removed }
        let kind: Kind
        let text: String
    }

    /// Swift's `CollectionDifference` over lines, replayed in order so a
    /// removal is drawn where it was and an insertion where it lands. At an
    /// index that carries both (a same-position replace), the removal is
    /// drawn first and the insertion right after it — deterministic, and
    /// what makes a one-line replace read as "old struck through, new
    /// underlined, in that order" rather than the reverse.
    static func lines(current: String, proposed: String) -> [Line] {
        let old = current.isEmpty ? [] : current.components(separatedBy: "\n")
        let new = proposed.isEmpty ? [] : proposed.components(separatedBy: "\n")
        let diff = new.difference(from: old)
        let removed = Set(diff.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset } else { return nil }
        })
        let inserted = Dictionary(uniqueKeysWithValues: diff.insertions.compactMap { change -> (Int, String)? in
            if case .insert(let offset, let element, _) = change { return (offset, element) } else { return nil }
        })
        var out: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removed.contains(oldIndex) {
                out.append(Line(kind: .removed, text: old[oldIndex])); oldIndex += 1; continue
            }
            if let text = inserted[newIndex] {
                out.append(Line(kind: .added, text: text)); newIndex += 1; continue
            }
            if oldIndex < old.count, newIndex < new.count {
                out.append(Line(kind: .same, text: new[newIndex])); oldIndex += 1; newIndex += 1; continue
            }
            break
        }
        return out
    }

    /// What is compared: the essay halves for a brief (Adopt never touches
    /// the rulings tail, so it is not on the table), the whole text for a
    /// visual language.
    static func compared(current: String, proposal: StatementProposalStore.Proposal)
        -> (current: String, proposed: String) {
        guard StatementEssay.carriesRulings(proposal.kind.statementKind) else {
            return (current, proposal.markdown)
        }
        return (StatementEssay.half(of: current), StatementEssay.half(of: proposal.markdown))
    }
}
