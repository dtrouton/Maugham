import Foundation
import MaughamCore

/// The Annotations tab's global scope toggle. `open` (default) drives triage;
/// `all` reveals fully-triaged chapters/projects for review.
enum AnnotationsMode: String, CaseIterable {
    case open, all
    var title: String { self == .open ? "Open" : "All" }
}

/// One annotation plus the docId it came from. Promoted to top-level (was nested
/// in AnnotationsListView) so the store, the grouping function, and the three
/// drill-down views share one type.
struct LoadedAnnotation: Identifiable {
    let annotation: Annotation
    let docId: String
    var id: String { annotation.id }
}

/// One document's (chapter/piece's) annotations, split by status, tagged with its
/// binder title and immediate parent-group title (the drill-down section header).
struct ChapterAnnotations: Identifiable {
    let docId: String            // == StructureItem.id
    let chapterTitle: String
    let groupTitle: String?      // immediate parent group's title, or nil / "Research" / "Other"
    let open: [LoadedAnnotation]
    let resolved: [LoadedAnnotation]
    var id: String { docId }
    var openCount: Int { open.count }
    var resolvedCount: Int { resolved.count }
}

/// One project's annotations, broken down by chapter. `chapters` holds every
/// chapter with any note; the view filters by Open/All mode.
struct ProjectAnnotations: Identifiable {
    let id: ProjectId
    let projectName: String
    let projectURL: URL
    let chapters: [ChapterAnnotations]
    var openCount: Int { chapters.reduce(0) { $0 + $1.openCount } }
    var resolvedCount: Int { chapters.reduce(0) { $0 + $1.resolvedCount } }
}

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

    /// One document's merged op stream, and **whose annotation it is** in it
    /// (signed op log P3c plan 2, Task 5) — the two things every phone derive
    /// needs, carried together so a caller cannot hold the ops without the
    /// judgement they are to be read under.
    struct JudgedOps: Sendable {
        let ops: [Op]
        let amendments: AnnotationAmendments

        /// What a view holds before its first read: no ops, so there is
        /// nothing for a judgement to decide.
        static let nothingLoaded = JudgedOps(ops: [], amendments: .honourEverything)
    }

    /// **The phone's one op-log read for annotations** — the Mac's own two
    /// Core calls, in the Mac's own order (`Document+Load`'s load, then its
    /// `annotationAmendments`), restating nothing (tripwire 19).
    ///
    /// The load collects the permit each amendment line was written under
    /// (`AmendmentPermits`); `annotationAmendments` builds the ownership rule
    /// from the table that load already warmed. Before this the phone derived
    /// with `.honourEverything`, so in a narrowed book a reviewer's edit or
    /// withdrawal of somebody else's note — refused on every Mac — was
    /// honoured on the phone, and the phone's accept guard read a note as
    /// deleted that no Mac had deleted. A book with no register answers
    /// `.honourEverything` from inside `annotationAmendments`, so an
    /// un-narrowed book reads exactly as it did.
    ///
    /// It constructs no trust table and names no actor: the store's own
    /// `trust()` is the one the partition already ran on, and the phone's
    /// store is built with its default identities, which mint nothing on a
    /// read (`PhoneOneKeyTests`).
    @MainActor
    static func loadJudged(docId: String, from store: OpLogStore) async throws -> JudgedOps {
        let permits = AmendmentPermits()
        let loaded = try await store.loadDiagnosed(docId: docId, amendmentPermits: permits)
        // Bound out here: the class closure is `@Sendable` and may not reach
        // the main-actor store.
        let projectURL = store.projectURL
        let amendments = store.annotationAmendments(from: permits) {
            OpLogStore.documentClass(forDocId: docId, in: projectURL)
        }
        return JudgedOps(ops: loaded.ops, amendments: amendments)
    }

    /// Every derived annotation for one document's merged op stream (all
    /// statuses), in `AnnotationDeriver`'s newest-first order. The show-resolved
    /// (All) mode needs resolved annotations too, so we derive the full set once
    /// and let callers partition by `.status`.
    ///
    /// `amendments` is REQUIRED (fix round 1): a caller holding bare ops says
    /// which judgement it means — `.honourEverything` by name where the
    /// un-narrowed answer is genuinely wanted. Every production read goes
    /// through `loadJudged` and the `JudgedOps` overloads below.
    static func allAnnotations(
        ops: [Op], amendments: AnnotationAmendments
    ) -> [Annotation] {
        // Single source of truth lives in MaughamCore (tripwire 19) — the Mac's
        // project-wide walk derives through the same pair. Do NOT reimplement.
        AnnotationAggregation.allAnnotations(ops: ops, amendments: amendments)
    }

    /// Every annotation in a judged read — the production spelling.
    static func allAnnotations(_ judged: JudgedOps) -> [Annotation] {
        allAnnotations(ops: judged.ops, amendments: judged.amendments)
    }

    /// Every annotation in a judged read, anchored against a paragraph map the
    /// caller already derived (the detail view's re-derive).
    static func allAnnotations(
        _ judged: JudgedOps, paragraphs: [String: String]
    ) -> [Annotation] {
        AnnotationAggregation.allAnnotations(
            ops: judged.ops, paragraphs: paragraphs, amendments: judged.amendments)
    }

    /// Open annotations only — the triage subset. Kept as the thin filter over
    /// `allAnnotations` so the two never drift.
    static func openAnnotations(
        ops: [Op], amendments: AnnotationAmendments
    ) -> [Annotation] {
        AnnotationAggregation.openAnnotations(ops: ops, amendments: amendments)
    }

    /// Group a project's annotations (ALL statuses) by document, in binder order,
    /// each tagged with its chapter title + immediate parent-group title.
    ///
    /// docId → chapter is `StructureItem.id == docId` (the same id the op-log
    /// filename carries). A docId not in `structure` falls back to the `research`
    /// tree ("Research" header); a docId in neither is surfaced under "Other"
    /// with a docId-stub title (never dropped — fail-visible). Mapped chapters
    /// sort by binder pre-order; unmapped/Other sort last.
    static func groupByChapter(
        _ annotations: [LoadedAnnotation],
        structure: [StructureItem],
        research: [ResearchItem]
    ) -> [ChapterAnnotations] {
        // 1. docId -> (title, parentGroupTitle) + a binder-order index.
        var meta: [String: (title: String, group: String?)] = [:]
        var order: [String: Int] = [:]
        var counter = 0

        func walk(_ items: [StructureItem], parentGroup: String?) {
            for item in items {
                switch item.type {
                case .group:
                    walk(item.children ?? [], parentGroup: item.title)
                case .document:
                    if meta[item.id] == nil {
                        meta[item.id] = (item.title, parentGroup)
                        order[item.id] = counter; counter += 1
                    }
                }
            }
        }
        walk(structure, parentGroup: nil)

        // Research leaves as a fallback locus, ordered after the manuscript.
        for item in TreeWalk.leaves(in: research) where meta[item.id] == nil {
            meta[item.id] = (item.title, "Research")
            order[item.id] = counter; counter += 1
        }

        // 2. Bucket by docId.
        var byDoc: [String: [LoadedAnnotation]] = [:]
        for a in annotations { byDoc[a.docId, default: []].append(a) }

        // 3. Build chapters (open/resolved partition preserves derive order).
        var chapters: [ChapterAnnotations] = byDoc.map { docId, anns in
            let m = meta[docId]
            let title = m?.title ?? "Other (\(docIdStub(docId)))"
            let group = m?.group ?? (m == nil ? "Other" : nil)
            return ChapterAnnotations(
                docId: docId,
                chapterTitle: title,
                groupTitle: group,
                open: anns.filter { $0.annotation.status == .open },
                resolved: anns.filter { $0.annotation.status != .open })
        }
        chapters.sort { a, b in
            let oa = order[a.docId] ?? Int.max
            let ob = order[b.docId] ?? Int.max
            if oa != ob { return oa < ob }
            return a.docId < b.docId    // stable tie-break for two unmapped docs
        }
        return chapters
    }

    /// Short, human-readable stub of an unmapped docId for the "Other" fallback.
    static func docIdStub(_ docId: String) -> String {
        String(docId.prefix(16))
    }

    /// Chapters visible in a mode: `open` keeps only chapters with ≥1 open note;
    /// `all` keeps any chapter with a note at all.
    static func visibleChapters(_ chapters: [ChapterAnnotations], mode: AnnotationsMode) -> [ChapterAnnotations] {
        switch mode {
        case .open: return chapters.filter { $0.openCount > 0 }
        case .all:  return chapters.filter { $0.openCount > 0 || $0.resolvedCount > 0 }
        }
    }

    /// Projects visible in a mode, each rebuilt with only its mode-visible
    /// chapters. A project left with no visible chapter is dropped.
    static func visibleProjects(_ projects: [ProjectAnnotations], mode: AnnotationsMode) -> [ProjectAnnotations] {
        projects.compactMap { p in
            let vis = visibleChapters(p.chapters, mode: mode)
            guard !vis.isEmpty else { return nil }
            return ProjectAnnotations(
                id: p.id, projectName: p.projectName, projectURL: p.projectURL, chapters: vis)
        }
    }
}
