import SwiftUI
import MaughamCore

/// **A Part's Brief**: a Part has no intent and no line of its own, so its
/// Brief gathers its chapters' decisions, one section per chapter that has
/// any, titled with the chapter (a button to that chapter's Brief), newest
/// first; then From the book (spec "Brief"; plan 3 Task 4).
struct BriefPartView: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let docIds: [String]
    let contents: BriefContents
    let world: DeclaredWorldStore?
    let onOpenBrief: (BinderSubject) -> Void

    @State private var showsBook = false

    /// One chapter's decisions, in the Part's manuscript order. Pure.
    struct Section: Equatable, Identifiable {
        let docId: String
        let title: String
        let decisions: [Ruling]
        var id: String { docId }
    }

    /// The chapters with decisions, in manuscript order, each newest first;
    /// a chapter with none has no section.
    static func sections(docIds: [String], decisions: [BriefDecision],
                         structure: [StructureItem]) -> [Section] {
        docIds.compactMap { docId in
            let mine = decisions.filter { $0.origin == .piece(docId: docId) }.map(\.ruling)
            guard !mine.isEmpty else { return nil }
            return Section(docId: docId,
                           title: TreeWalk.find(id: docId, in: structure)?.title ?? docId,
                           decisions: BriefDecisions.newestFirst(mine))
        }
    }

    static let emptyLine = "No chapter in this Part has decided anything yet."

    var body: some View {
        let sections = Self.sections(docIds: docIds, decisions: contents.snapshot.decisions,
                                     structure: store.manifest.structure)
        VStack(alignment: .leading, spacing: 14) {
            if sections.isEmpty {
                Text(Self.emptyLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Button { onOpenBrief(.item(section.docId)) } label: {
                        Text(section.title)
                            .font(.caption).bold()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Open this chapter's Brief")
                    BriefDecidedSection(
                        fileOrder: contents.fileOrder[section.docId] ?? [],
                        decisions: section.decisions,
                        kind: .intent, scope: .document(section.docId), store: store, world: world,
                        posture: posture(of: section.docId), liveParagraphIds: nil,
                        showsHeading: false)
                }
            }
            if BriefPane.quietLines(contents.snapshot).fromTheBook {
                VStack(alignment: .leading, spacing: 6) {
                    BriefPane.disclosure(BriefPieceView.fromTheBook, isOpen: $showsBook)
                    if showsBook {
                        BriefPane.FromTheBook(essay: contents.snapshot.bookIntentEssay,
                                              decisions: contents.snapshot.bookDecisions)
                    }
                }
            }
        }
    }

    private func posture(of docId: String) -> Posture {
        documentStore.posture(forDocId: StatementEditorHost.postureDocId(
            kind: .intent, scope: .document(docId), statements: store.manifest.statements))
    }
}
