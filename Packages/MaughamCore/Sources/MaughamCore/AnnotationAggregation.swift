import Foundation

/// The pure ops→annotations derivation both surfaces read through (tripwire 19).
///
/// This pair lived only in the phone's `AnnotationLoading` until M3 P2 Task 6
/// gave the Mac a project-wide annotation walk that needs exactly the same
/// derivation. Rather than let the Mac grow a second copy — the shape that
/// shipped the phone-v0.1.1 doc-id bug — the pair moved here and the phone's
/// two functions became one-line delegates.
///
/// Nothing here touches the filesystem: callers bring the merged op stream
/// (the phone from `OpLogStore.load`, the Mac from `loadSyncMerged` or a live
/// `Document`'s mirror) and get the projection back.
public enum AnnotationAggregation {

    /// Every derived annotation for one document's merged op stream (all
    /// statuses), in `AnnotationDeriver`'s newest-first order. Withdrawn notes
    /// are absent from the projection by the deriver's own rule.
    ///
    /// Derives the paragraph text itself and, on a figure's stream, the
    /// figure's table its notes' cell anchors resolve against
    /// (`figureTable(in:)`). A caller that already has the derived paragraphs
    /// in hand should use the overload below rather than pay for a second
    /// walk of the stream.
    public static func allAnnotations(
        ops: [Op], amendments: AnnotationAmendments = .honourEverything
    ) -> [Annotation] {
        allAnnotations(
            ops: ops, paragraphs: Deriver.derive(ops: ops).paragraphs,
            amendments: amendments, figureTable: figureTable(in: ops))
    }

    /// Same projection, over paragraphs the caller already derived.
    ///
    /// The Mac's project-wide walk needs each closed doc's `sequence` as well
    /// (to sort notes in document order), so it runs
    /// `Deriver.deriveWithSequenceFallback` once and hands the paragraphs in.
    /// The two derives differ only in how they recover a missing `sequence`;
    /// `paragraphs` is identical, so both spellings of `allAnnotations` agree.
    ///
    /// `figureTable` is the figure's table when `ops` is a figure's stream
    /// (report plan 9c-1): the caller derives it from the same ops with
    /// `figureTable(in:)`, and a figure note's anchor resolves against it.
    public static func allAnnotations(
        ops: [Op], paragraphs: [String: String],
        amendments: AnnotationAmendments = .honourEverything,
        figureTable: FigureTable? = nil
    ) -> [Annotation] {
        AnnotationDeriver.derive(
            ops: ops, paragraphs: paragraphs, amendments: amendments,
            figureTable: figureTable)
    }

    /// **The figure table a stream's figure ops fold to** (report plan 9c-1),
    /// for resolving its notes' cell anchors — nil when the stream holds no
    /// figure op (a manuscript's, a research note's). Folds the figure kinds
    /// only, as `FigureDocument` does, so the stream's annotation ops add no
    /// diagnostics.
    public static func figureTable(in ops: [Op]) -> FigureTable? {
        let figureOps = ops.filter { FigureOpPayload.kinds.contains($0.kind) }
        guard !figureOps.isEmpty else { return nil }
        return FigureDeriver.derive(figureOps).table
    }

    /// Open annotations only — the triage subset. Kept as the thin filter over
    /// `allAnnotations` so the two never drift; `.stetted` resolves like an
    /// accept or a reject and is not open.
    public static func openAnnotations(
        ops: [Op], amendments: AnnotationAmendments = .honourEverything
    ) -> [Annotation] {
        allAnnotations(ops: ops, amendments: amendments)
            .filter { $0.status == .open }
    }
}
