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
        /// The chapter's intent would not read: its section says so
        /// (RULING-54; final wave, I2).
        var unreadable: Bool = false
        var id: String { docId }
    }

    /// The chapters with decisions, in manuscript order, each newest first;
    /// a chapter with none has no section — unless its intent would not read
    /// (`unreadable`), which keeps a section saying so.
    static func sections(docIds: [String], decisions: [BriefDecision],
                         structure: [StructureItem], unreadable: Set<String> = []) -> [Section] {
        docIds.compactMap { docId in
            let mine = decisions.filter { $0.origin == .piece(docId: docId) }.map(\.ruling)
            let unread = unreadable.contains(docId)
            guard !mine.isEmpty || unread else { return nil }
            return Section(docId: docId,
                           title: TreeWalk.find(id: docId, in: structure)?.title ?? docId,
                           decisions: BriefDecisions.newestFirst(mine), unreadable: unread)
        }
    }

    /// "No chapter in this Part has decided anything yet." — in the
    /// project's words for a piece and a group (`PieceNoun`).
    static func emptyLine(_ noun: PieceNoun) -> String {
        "No \(noun.singular) in this \(noun.group ?? "group") has decided anything yet."
    }

    /// "Open this chapter's Brief".
    static func openBriefHelp(_ noun: PieceNoun) -> String { "Open this \(noun.singular)\u{2019}s Brief" }

    var body: some View {
        let statements = store.manifest.statements
        let unreadable = Set(docIds.filter {
            BriefPane.statementIsUnreadable(kind: .intent, scope: .document($0),
                                            snapshot: contents.snapshot, statements: statements)
        })
        // Once per body, never per row (tripwire 4): a Part holds no
        // screenplay piece, so the project's own word serves every row.
        let noun = PieceNoun.of(nil, in: store.manifest)
        let sections = Self.sections(docIds: docIds, decisions: contents.snapshot.decisions,
                                     structure: store.manifest.structure, unreadable: unreadable)
        VStack(alignment: .leading, spacing: 14) {
            if sections.isEmpty {
                Text(Self.emptyLine(noun))
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
                    .help(Self.openBriefHelp(noun))
                    BriefDecidedSection(
                        fileOrder: contents.fileOrder[section.docId] ?? [],
                        decisions: section.decisions,
                        kind: .intent, scope: .document(section.docId), store: store, world: world,
                        posture: posture(of: section.docId), liveParagraphIds: nil,
                        showsHeading: false, isUnreadable: section.unreadable)
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
