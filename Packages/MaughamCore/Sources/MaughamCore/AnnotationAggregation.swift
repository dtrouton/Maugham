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
    /// Derives the paragraph text itself. A caller that already has the
    /// derived paragraphs in hand should use the overload below rather than
    /// pay for a second walk of the stream.
    public static func allAnnotations(ops: [Op]) -> [Annotation] {
        allAnnotations(ops: ops, paragraphs: Deriver.derive(ops: ops).paragraphs)
    }

    /// Same projection, over paragraphs the caller already derived.
    ///
    /// The Mac's project-wide walk needs each closed doc's `sequence` as well
    /// (to sort notes in document order), so it runs
    /// `Deriver.deriveWithSequenceFallback` once and hands the paragraphs in.
    /// The two derives differ only in how they recover a missing `sequence`;
    /// `paragraphs` is identical, so both spellings of `allAnnotations` agree.
    public static func allAnnotations(
        ops: [Op], paragraphs: [String: String]
    ) -> [Annotation] {
        AnnotationDeriver.derive(ops: ops, paragraphs: paragraphs)
    }

    /// Open annotations only — the triage subset. Kept as the thin filter over
    /// `allAnnotations` so the two never drift; `.stetted` resolves like an
    /// accept or a reject and is not open.
    public static func openAnnotations(ops: [Op]) -> [Annotation] {
        allAnnotations(ops: ops).filter { $0.status == .open }
    }
}
