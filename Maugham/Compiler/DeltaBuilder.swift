import Foundation
import MaughamCore

/// What the compiler is being asked to look at this run: the paragraphs that
/// appeared since the last run's marker, and the ones whose prose moved —
/// each carrying what it said AT the marker, so the prompt can show a real
/// before and after.
///
/// Both lists are in `sequence` order (the manuscript's order), never op
/// arrival order, so a run reads the way the writer reads.
struct CompilerDelta: Equatable, Sendable {
    struct NewParagraph: Equatable, Sendable {
        let paragraphId: String
        let text: String
    }
    struct RevisedParagraph: Equatable, Sendable {
        let paragraphId: String
        let prior: String
        let text: String
    }

    let new: [NewParagraph]
    let revised: [RevisedParagraph]

    /// The op-log position this delta was built as of — the marker the NEXT
    /// run diffs from. `nil` when no op stands after the marker it was given.
    ///
    /// This is a log position, not a prose position: it advances past ops that
    /// changed no manuscript text (a checkpoint, a task, an annotation) so a
    /// later run does not re-read them, which is why it can be non-`nil` on an
    /// otherwise empty delta.
    let newestOpId: String?

    var isEmpty: Bool { new.isEmpty && revised.isEmpty }
}

/// The op log → delta fold. A pure function: no I/O, no clock, no state.
/// Current text is passed in rather than derived here, because the live
/// `Document` already holds it — and `sequence` is authoritative for order
/// (a paragraph absent from it appears nowhere, however many ops touched it).
enum DeltaBuilder {

    /// - Parameters:
    ///   - ops: the document's ops, in any order. Sorted here by `opId`
    ///     (ULID string order is op order — `Deriver.opOrder`), so a caller
    ///     that forgets to pre-sort still gets the documented result.
    ///   - markerOpId: the previous run's `lastOpId`. `nil` means no run has
    ///     happened yet, and the whole standing manuscript is new.
    ///   - currentParagraphs: paragraph id → live text.
    ///   - sequence: the live paragraph order.
    static func delta(
        ops: [Op],
        since markerOpId: String?,
        currentParagraphs: [String: String],
        sequence: [String]
    ) -> CompilerDelta {
        // Tie on opId keeps input order, so the result is a function of the
        // input alone (Swift's sort is not stable).
        let ordered = ops.enumerated()
            .sorted { a, b in
                a.element.opId == b.element.opId
                    ? a.offset < b.offset
                    : a.element.opId < b.element.opId
            }
            .map(\.element)
        let afterMarker = markerOpId.map { marker in
            ordered.filter { $0.opId > marker }
        } ?? ordered
        let newestOpId = afterMarker.last?.opId

        guard markerOpId != nil else {
            // First run: nothing has been checked, so everything standing is
            // new. Walked by `sequence`, so a stray paragraph in the map that
            // the manuscript no longer orders stays out.
            let new = sequence.compactMap { pid in
                currentParagraphs[pid].map {
                    CompilerDelta.NewParagraph(paragraphId: pid, text: $0)
                }
            }
            return CompilerDelta(new: new, revised: [], newestOpId: newestOpId)
        }

        // The text each paragraph had AS OF THE MARKER — the prior of the
        // FIRST post-marker op to touch it, not the last. A paragraph whose
        // first post-marker prior is nil was minted since the marker, and is
        // new however many times it was rewritten afterwards.
        var textAtMarker: [String: String] = [:]
        var mintedSinceMarker: Set<String> = []
        var seen: Set<String> = []
        for op in afterMarker where Deriver.appliesToManuscript(op.kind) {
            // A non-manuscript op's change entry is an ANCHOR plus a snapshot
            // (an annotation pinned to a paragraph), never an edit. Diffing one
            // reports a revision the writer never made — and cross-device the
            // snapshot can be stale, so it would report the wrong prior too.
            for change in op.changes {
                guard seen.insert(change.paragraphId).inserted else { continue }
                if let prior = change.prior {
                    textAtMarker[change.paragraphId] = prior
                } else {
                    mintedSinceMarker.insert(change.paragraphId)
                }
            }
        }

        var new: [CompilerDelta.NewParagraph] = []
        var revised: [CompilerDelta.RevisedParagraph] = []
        for pid in sequence {
            // Absent from the live text = deleted since the marker. There is
            // nothing to ask the compiler about prose that is gone.
            guard let text = currentParagraphs[pid] else { continue }
            if mintedSinceMarker.contains(pid) {
                new.append(.init(paragraphId: pid, text: text))
            } else if let prior = textAtMarker[pid], prior != text {
                // prior == text means typed and untyped back: a before/after
                // with identical halves is noise in the prompt.
                revised.append(.init(paragraphId: pid, prior: prior, text: text))
            }
        }

        return CompilerDelta(new: new, revised: revised, newestOpId: newestOpId)
    }
}
