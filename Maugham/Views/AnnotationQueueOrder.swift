import Foundation
import MaughamCore

/// The order a writer works a queue in (M3 P2) — the pane's final pass over its
/// rows, after every filter has decided WHICH notes are on screen.
///
/// Two questions, in this order:
///
/// 1. **What did the writer say they would do?** Everything marked `do` leads.
///    That is the whole point of the mark: a pass over a pile begins by sorting
///    it, and the sorted-in pile has to come out first or the sorting bought
///    nothing. `decline`, `discuss` and untriaged are one group behind it —
///    only `do` is a commitment to act, and splitting the rest into three more
///    bands would put a note the writer means to talk about ahead of one they
///    have not looked at yet, which is a judgement they never made.
/// 2. **Where is it in the manuscript?** Within a group, document order, so
///    working the queue top to bottom is one pass down the text rather than a
///    scatter of jumps. A note with no paragraph (a craft note is about the
///    whole document) and a note whose paragraph has since left the sequence
///    both sit at the END of their own group — the tail is per-group, so a
///    floating `do` note still beats an anchored untriaged one.
///
/// Ties (two notes on one paragraph, two notes in the tail) break by `createdAt`
/// then id, both descending — newest first, matching the deriver's own habit —
/// and both keys together are a total order over distinct ids, so the result
/// never depends on `sorted`'s unspecified stability.
///
/// Pure and free of `@MainActor` so the truth table is testable without the
/// pane: `AnnotationQueueOrderTests`.
enum AnnotationQueueOrder {
    static func sorted(_ annotations: [Annotation], sequence: [String]) -> [Annotation] {
        // One pass to index the sequence: the pane re-sorts on every render and
        // a linear `firstIndex` per row would make that O(rows × paragraphs).
        var position: [String: Int] = [:]
        position.reserveCapacity(sequence.count)
        for (index, paragraphId) in sequence.enumerated() where position[paragraphId] == nil {
            position[paragraphId] = index
        }

        /// The tail slot. A paragraphId absent from `sequence` is a note whose
        /// anchor was deleted — it lands here with the unanchored notes rather
        /// than crashing on a missing index or, worse, taking position 0 and
        /// silently leading the queue.
        func slot(_ annotation: Annotation) -> Int {
            guard let paragraphId = annotation.paragraphId else { return .max }
            return position[paragraphId] ?? .max
        }

        func band(_ annotation: Annotation) -> Int {
            annotation.triage == .do ? 0 : 1
        }

        return annotations.sorted { lhs, rhs in
            let leftBand = band(lhs), rightBand = band(rhs)
            if leftBand != rightBand { return leftBand < rightBand }
            let leftSlot = slot(lhs), rightSlot = slot(rhs)
            if leftSlot != rightSlot { return leftSlot < rightSlot }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id > rhs.id
        }
    }
}

/// The queue's triage filter — a pane-side pass, deliberately NOT a widening of
/// `AnnotationFilter`. The core filter's shape reaches MCP, and the mark is a
/// working-surface concern: what the writer plans to do about a note is how they
/// steer their own pass, not a property another reader should be querying on.
///
/// Pure and nonisolated so the truth table is testable without the pane.
enum AnnotationTriageFilter: String, CaseIterable, Identifiable {
    case all
    /// Spelled out because `do` is a Swift keyword and a backticked case in a
    /// `ForEach` reads worse than one honest rename.
    case doThis
    case decline
    case discuss
    case untriaged

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .doThis: return TriageMark.do.queueLabel
        case .decline: return TriageMark.decline.queueLabel
        case .discuss: return TriageMark.discuss.queueLabel
        case .untriaged: return "Untriaged"
        }
    }

    func matches(_ annotation: Annotation) -> Bool {
        switch self {
        case .all: return true
        case .doThis: return annotation.triage == .do
        case .decline: return annotation.triage == .decline
        case .discuss: return annotation.triage == .discuss
        case .untriaged: return annotation.triage == nil
        }
    }
}

extension TriageMark {
    /// The one word the queue uses for each mark — the row's menu, the toolbar
    /// filter and anything else that names a mark to the writer read it here, so
    /// two surfaces cannot come to call the same mark different things.
    var queueLabel: String {
        switch self {
        case .do: return "Do"
        case .decline: return "Decline"
        case .discuss: return "Discuss"
        }
    }

    var symbolName: String {
        switch self {
        case .do: return "checklist"
        case .decline: return "hand.raised"
        case .discuss: return "bubble.left.and.bubble.right"
        }
    }
}
