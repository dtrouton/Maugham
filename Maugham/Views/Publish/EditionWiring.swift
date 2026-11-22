import SwiftUI
import MaughamCore

/// **The window's two edition doors** (shell p4 Task 7): the Add Language
/// sheet (`.maughamAddLanguage`, from the Editions `+`, the Source row's menu
/// and a proposed brief's Add) and ⌘⌥K (`.maughamShowEditionResolve`), with
/// the View menu's title for ⌘⌥K published as a focused value.
///
/// One presenter for the sheet, so a new edition lands the same way from
/// every door: it is selected, and its To resolve says the next step (Run
/// Whole Book under the translator just named).
struct EditionWiring: ViewModifier {
    let store: ProjectStore?
    let documentStore: DocumentStore?
    let window: NSWindow?
    @Binding var subject: WindowSubject
    @Binding var showInspector: Bool
    @Binding var position: RightColumnPosition
    /// The tree's edition rows (`BinderTreeSectionsState.editionRows`), the
    /// Source first.
    let editions: [TreeEditionRows.Row]
    /// The language the centre's piece is read in, if any.
    let readingLanguage: String?
    /// A click on a tree row, through the click rule.
    let select: (BinderSubject) -> Void

    @State private var addPrompt: EditionCastPrompt?
    @State private var refusal: String?

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamAddLanguage, window: window) { note in
                guard let documentStore,
                      EditionCastVerbs.mayAddLanguage(documentStore: documentStore) else { return }
                addPrompt = EditionCastVerbs.addPrompt(
                    proposing: note.userInfo?[MaughamEvent.proposedLanguageKey] as? String)
            }
            .onKeyWindowCommand(.maughamShowEditionResolve, window: window) { _ in
                guard let row = Self.editionForTheKey(
                    subject: subject, readingLanguage: readingLanguage, editions: editions) else { return }
                subject = ProjectWindow.facesForABrief(.edition(language: row.language), subject: subject)
                showToResolve()
            }
            .focusedSceneValue(\.editionKeyTitle, Self.keyTitle(Self.editionForTheKey(
                subject: subject, readingLanguage: readingLanguage, editions: editions)))
            .sheet(item: $addPrompt) { prompt in
                EditionCastSheet(
                    prompt: prompt,
                    onConfirm: { answer in
                        addPrompt = nil
                        guard let store, let documentStore else { return }
                        Task { landed(await EditionCastVerbs.addLanguage(
                            answer: answer, store: store, documentStore: documentStore)) }
                    },
                    onCancel: { addPrompt = nil })
            }
            .alert(EditionCastCopy.addLanguageTitle, isPresented: Binding(
                get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
                Button("OK") { refusal = nil }
            } message: {
                Text(refusal ?? "")
            }
    }

    /// The edition selected, and To resolve showing what it needs next.
    private func landed(_ added: EditionCastVerbs.Added) {
        switch added {
        case .added(let language):
            select(.edition(language: language))
            showToResolve()
        case .refused(let sentence):
            refusal = sentence
        }
    }

    /// To resolve, through the one position-selection act.
    private func showToResolve() {
        ProjectWindow.selectPosition(.resolve, showInspector: $showInspector, position: $position)
    }

    // MARK: - ⌘⌥K, pure

    /// **Which edition ⌘⌥K shows**: the edition open in the centre, else the
    /// language the centre's piece is read in, else the edition the right
    /// column is already about, else the Source. nil where the book has no
    /// editions (the menu item is then disabled).
    static func editionForTheKey(subject: WindowSubject, readingLanguage: String?,
                                 editions: [TreeEditionRows.Row]) -> TreeEditionRows.Row? {
        func row(_ language: String) -> TreeEditionRows.Row? {
            editions.first { $0.language.caseInsensitiveCompare(language) == .orderedSame }
        }
        if case .edition(let language) = subject.open, let found = row(language) { return found }
        if let readingLanguage, let found = row(readingLanguage) { return found }
        if case .edition(let language) = subject.faces, let found = row(language) { return found }
        return editions.first(where: \.isSource)
    }

    /// The View menu's title for ⌘⌥K: the edition it would show, by name.
    static func keyTitle(_ row: TreeEditionRows.Row?) -> String? {
        row.map { "To Resolve: \($0.title) Edition" }
    }

    /// The title while the focused window has no edition to show.
    static let keyTitleWithNoEdition = "To Resolve: An Edition"
}

/// ⌘⌥K's title in the focused window, or nil where it has no edition
/// (`EditionWiring.keyTitle`). Read only by the View menu's item.
struct FocusedEditionKeyTitleKey: FocusedValueKey { typealias Value = String }
extension FocusedValues {
    var editionKeyTitle: String? {
        get { self[FocusedEditionKeyTitleKey.self] }
        set { self[FocusedEditionKeyTitleKey.self] = newValue }
    }
}
