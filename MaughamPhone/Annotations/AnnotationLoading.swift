import Foundation
import MaughamCore

/// Pure, testable core of the Annotations tab's per-project load (Task F.4).
///
/// The view drives the I/O (enumerate filenames, `ensureDownloaded`, `OpLogStore.load`);
/// these two functions hold the only non-trivial logic — which doc ids a project
/// has, and which annotations from a doc's op stream are still open — so they can
/// be unit-tested without touching the filesystem or the actor-backed downloader.
enum AnnotationLoading {

    /// Distinct doc ids present in a project's `.maugham/ops/` directory, given
    /// the bare filenames in that directory. Delegates to `OpLogStore` — single
    /// source of truth for op-log filename parsing lives in MaughamCore.
    static func docIds(inOpsDirectoryFilenames filenames: [String]) -> Set<String> {
        // Single source of truth lives in MaughamCore. Do NOT reimplement the
        // predicate here (a stricter local copy shipped the phone-v0.1.1 bug).
        OpLogStore.docIds(inOpsDirectoryFilenames: filenames)
    }

    /// Every derived annotation for one document's merged op stream (all
    /// statuses), in `AnnotationDeriver`'s newest-first order. The show-resolved
    /// (All) mode needs resolved annotations too, so we derive the full set once
    /// and let callers partition by `.status`.
    static func allAnnotations(ops: [Op]) -> [Annotation] {
        let paragraphs = Deriver.derive(ops: ops).paragraphs
        return AnnotationDeriver.derive(ops: ops, paragraphs: paragraphs)
    }

    /// Open annotations only — the triage subset. Kept as the thin filter over
    /// `allAnnotations` so the two never drift.
    static func openAnnotations(ops: [Op]) -> [Annotation] {
        allAnnotations(ops: ops).filter { $0.status == .open }
    }
}
