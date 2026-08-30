import SwiftUI
import AppKit
import MaughamCore

/// **What the round report needs from the disk, fetched once, off a body path**
/// (translation pipeline P4 Task 3).
///
/// `DepartmentPaneHost`'s shape and its reason: `TranslationRoundReportView`
/// reads no store at all (tripwire 4), so everything it draws that is not in the
/// `TranslationRound` itself is resolved here in a `.task` and handed down as a
/// value.
///
/// Four things, and each is a fact the round cannot carry:
///
/// - **The sources.** A round records paragraph IDs; the author's own words for
///   them live in the document and may have changed — or gone — since. Read
///   through `currentParagraphState`, which is tripwire 20's one spelling of
///   "open doc → live `Document`, closed doc → derived", never the `.md`.
/// - **The chapter's title**, for the header.
/// - **The two names**, through `EditionStatus` — the same derivation the desk
///   and `translation_status` use, so no third answer about who is on this book.
/// - **The queries this round left open**, which is the only one of the four
///   that moves while the report is up: answering one settles it, and the
///   section must empty. `.maughamAnnotationsChanged` is the project-scoped post
///   that says so (ADR 0021, with the closed-window liveness guard).
///
/// **The window is a parameter** because ADR 0021's receive helper drops every
/// post for a nil window: without one the annotations refresh would be wired and
/// dead, which is worse than absent.
@MainActor
struct TranslationRoundReportHost: View {
    let round: TranslationRound
    let store: ProjectStore
    let documentStore: DocumentStore?
    let projectURL: URL
    /// The hosting window, for the project-scope filter and the liveness guard.
    let window: NSWindow?
    var actions: TranslationRoundActions = TranslationRoundActions()
    var onClose: () -> Void = { }
    var onRoundChanged: (TranslationRound) -> Void = { _ in }
    var onReveal: (String) -> Void = { _ in }

    @State private var sources: [String: String] = [:]
    @State private var chapterTitle: String?
    @State private var queries: [Annotation] = []
    /// The read's own failure sentence, when it failed. Kept apart from
    /// `queries` because "none" and "unreadable" are different facts and the
    /// section says each in its own words (RULING-7).
    @State private var queriesFailure: String?
    @State private var translatorName = ""
    @State private var collatorName = ""

    var body: some View {
        TranslationRoundReportView(
            round: round, chapterTitle: chapterTitle, sources: sources,
            queries: queries, queriesFailure: queriesFailure,
            translatorName: translatorName,
            collatorName: collatorName, actions: actions,
            onClose: onClose, onRoundChanged: onRoundChanged, onReveal: onReveal)
            // Keyed on the round's identity rather than the value: a verb's
            // write-back changes the value, and re-reading the whole document
            // on every "Fine" would put file I/O on the writer's click.
            .task(id: roundIdentity) { await load() }
            .onProjectEvent(.maughamAnnotationsChanged,
                            url: projectURL, window: window) { _ in
                Task { await loadQueries() }
            }
    }

    private var roundIdentity: String { "\(round.language)#\(round.number)" }

    private func load() async {
        translatorName = EditionStatus.translatorName(
            for: round.language, in: store.manifest) ?? round.language.uppercased()
        collatorName = EditionStatus.collatorName(
            for: round.language, in: store.manifest) ?? round.language.uppercased()
        chapterTitle = TreeWalk.find(id: round.docId, in: store.manifest.structure)?.title
        loadSources()
        await loadQueries()
    }

    /// The live text of every paragraph this round names — departures and notes
    /// alike, because the Disagreements section quotes a note's paragraph too.
    ///
    /// Anchors stripped (`MarkdownDisplayFilter`, the one spelling), because the
    /// author is reading their own sentence and a `<!-- ¶id -->` comment in the
    /// middle of it is the op log leaking onto a surface.
    private func loadSources() {
        let wanted = Set(round.departures.map(\.paragraphId)
                         + round.notes.map(\.paragraphId))
        guard !wanted.isEmpty else {
            sources = [:]
            return
        }
        guard let state = try? currentParagraphState(
            documentId: round.docId, store: store,
            documentStore: documentStore, projectURL: projectURL)
        else {
            sources = [:]
            return
        }
        var resolved: [String: String] = [:]
        for id in wanted {
            guard let raw = state.paragraphs[id] else { continue }
            let text = MarkdownDisplayFilter.stripAnchors(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { resolved[id] = text }
        }
        sources = resolved
    }

    /// The translator's open questions from this round's own window.
    ///
    /// **Bounded by the round's clock** rather than by a stamp on the annotation:
    /// a query carries its language and its status, not the round that raised
    /// it, and a report that showed every open question of the edition would put
    /// round 1's unanswered question under round 3's summary. `distantFuture`
    /// for a round still running, so its questions arrive as they are minted.
    ///
    /// **A read that throws is said, never swallowed** (RULING-7): the document
    /// can be missing from the manifest, or unloadable, and collapsing that into
    /// an empty array would draw "No open questions from this edition." over a
    /// queue nobody could open — the one degrade this app is not allowed to make
    /// look like good news.
    private func loadQueries() async {
        let end = round.endedAt ?? .distantFuture
        do {
            let found = try await withAnnotationDocument(
                store: store, projectURL: projectURL, documentId: round.docId
            ) { document in
                TranslationReviewPaneLogic.openQueries(
                    document.annotations(filter: AnnotationFilter(
                        kinds: [.query], statuses: [.open])),
                    language: round.language)
            }
            queries = found.filter {
                $0.createdAt >= round.startedAt && $0.createdAt <= end
            }
            queriesFailure = nil
        } catch {
            queries = []
            queriesFailure = TranslationRoundReport.questionsUnreadable(
                reason: error.localizedDescription)
        }
    }
}
