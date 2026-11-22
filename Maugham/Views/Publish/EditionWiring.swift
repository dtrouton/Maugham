import SwiftUI
import MaughamCore

/// **The window's edition doors** (shell p4 Task 7): the Add Language
/// sheet (`.maughamAddLanguage`, from the Editions `+`, the Source row's menu
/// and a proposed brief's Add), Remove Edition (`.maughamRemoveEdition`, a
/// translated edition's row menu and File ▸ Remove Edition…; closing round)
/// and ⌘⌥K (`.maughamShowEditionResolve`), with the menus' titles and
/// enablement published as focused values.
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
    /// What stops removing an edition in this window now — a round into it,
    /// its compile (`EditionCastVerbs.removalBusy`); nil when nothing does.
    var busy: (String) -> String? = { _ in nil }

    @State private var addPrompt: EditionCastPrompt?
    @State private var refusal: String?
    /// The edition Remove Edition… is asking about.
    @State private var removing: String?

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamAddLanguage, window: window) { note in
                guard let documentStore,
                      EditionCastVerbs.mayAddLanguage(documentStore: documentStore) else { return }
                addPrompt = EditionCastVerbs.addPrompt(
                    proposing: note.userInfo?[MaughamEvent.proposedLanguageKey] as? String)
            }
            // Remove Edition…: asked first, the language named and what is kept.
            .onKeyWindowCommand(.maughamRemoveEdition, window: window) { note in
                guard let documentStore, EditionCastVerbs.mayAddLanguage(documentStore: documentStore),
                      let language = note.userInfo?[MaughamEvent.removeEditionLanguageKey] as? String,
                      let row = EditionCastVerbs.removable(language, editions: editions.map(\.language))
                else { return }
                removing = row
            }
            // **An edition gone from the list** — removed here or on another
            // window or Mac — is never left as the subject: the window goes to
            // the Book (`landing`).
            .onChange(of: editions) { old, new in
                if let landed = Self.landing(subject: subject, before: old, after: new) { subject = landed }
            }
            .onKeyWindowCommand(.maughamShowEditionResolve, window: window) { _ in
                guard let row = Self.editionForTheKey(
                    subject: subject, readingLanguage: readingLanguage, editions: editions) else { return }
                subject = ProjectWindow.facesForABrief(.edition(language: row.language), subject: subject)
                showToResolve()
            }
            .focusedSceneValue(\.editionKeyTitle, Self.keyTitle(Self.editionForTheKey(
                subject: subject, readingLanguage: readingLanguage, editions: editions)))
            .focusedSceneValue(\.mayAddLanguage, documentStore.map {
                EditionCastVerbs.mayAddLanguage(documentStore: $0) } ?? false)
            // File ▸ Remove Edition…: the translated edition selected, where
            // this Mac may add one.
            .focusedSceneValue(\.removableEdition, documentStore.flatMap {
                EditionCastVerbs.mayAddLanguage(documentStore: $0)
                    ? Self.editionToRemove(subject: subject, editions: editions) : nil })
            .sheet(item: $addPrompt) { prompt in
                EditionCastSheet(
                    prompt: prompt,
                    onConfirm: { answer in
                        addPrompt = nil
                        guard let store, let documentStore else { return }
                        let proposed = !prompt.proposedTag.isEmpty
                        Task { landed(EditionCastVerbs.landing(await EditionCastVerbs.addLanguage(
                            answer: answer, store: store, documentStore: documentStore),
                            proposed: proposed)) }
                    },
                    onCancel: { addPrompt = nil })
            }
            .alert(EditionCastCopy.removeEditionTitle(language: removing ?? ""), isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button(EditionCastCopy.removeEditionConfirm, role: .destructive) {
                    let language = removing
                    removing = nil
                    guard let language, let store, let documentStore else { return }
                    let busy = busy
                    Task {
                        if case .refused(let sentence) = await EditionCastVerbs.removeEdition(
                            language: language, store: store, documentStore: documentStore, busy: busy) {
                            refusal = sentence
                        }
                    }
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: {
                Text(EditionCastCopy.removeEditionMessage(language: removing ?? ""))
            }
            .alert(EditionCastCopy.addLanguageTitle, isPresented: Binding(
                get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
                Button("OK") { refusal = nil }
            } message: {
                Text(refusal ?? "")
            }
    }

    /// Where Add Language lands (`EditionCastVerbs.landing`).
    private func landed(_ landing: EditionCastVerbs.Landing) {
        if let target = landing.select { select(target) }
        if let shown = landing.position { show(shown) }
        refusal = landing.alert
    }

    /// To resolve.
    private func showToResolve() { show(.resolve) }

    /// A position, through the one position-selection act.
    private func show(_ shown: RightColumnPosition) {
        ProjectWindow.selectPosition(shown, showInspector: $showInspector, position: $position)
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

    /// **The edition File ▸ Remove Edition… is about**: the translated
    /// edition the faces or the centre are on, if the book lists it. Never
    /// the Source. Pure.
    static func editionToRemove(subject: WindowSubject, editions: [TreeEditionRows.Row]) -> String? {
        for side in [subject.faces, subject.open] {
            if case .edition(let language) = side,
               let tag = EditionCastVerbs.removable(language, editions: editions.map(\.language)) {
                return tag
            }
        }
        return nil
    }

    /// **Where the window goes when an edition leaves the list**: the Book,
    /// when the centre or the faces were on it; nil (stay) otherwise. Only a
    /// language that WAS listed and is no longer — never the first read of
    /// the rows. Pure.
    static func landing(subject: WindowSubject, before: [TreeEditionRows.Row],
                        after: [TreeEditionRows.Row]) -> WindowSubject? {
        let gone = before.map(\.language).filter { tag in
            !after.contains { $0.language.caseInsensitiveCompare(tag) == .orderedSame }
        }
        func isGone(_ side: BinderSubject) -> Bool {
            guard case .edition(let language) = side else { return false }
            return gone.contains { $0.caseInsensitiveCompare(language) == .orderedSame }
        }
        guard isGone(subject.open) || isGone(subject.faces) else { return nil }
        var next = subject
        next.open = .project
        next.faces = .project
        return next
    }

    /// The View menu's title for ⌘⌥K: the edition it would show, by name.
    static func keyTitle(_ row: TreeEditionRows.Row?) -> String? {
        row.map { "To Resolve: \($0.title) Edition" }
    }

    /// The title while the focused window has no edition to show.
    static let keyTitleWithNoEdition = "To Resolve: An Edition"
}

/// Whether the focused window may add a language (File ▸ Add Language…).
struct FocusedMayAddLanguageKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var mayAddLanguage: Bool? {
        get { self[FocusedMayAddLanguageKey.self] }
        set { self[FocusedMayAddLanguageKey.self] = newValue }
    }
}

/// The translated edition File ▸ Remove Edition… would remove in the focused
/// window, or nil (the item is then disabled).
struct FocusedRemovableEditionKey: FocusedValueKey { typealias Value = String }
extension FocusedValues {
    var removableEdition: String? {
        get { self[FocusedRemovableEditionKey.self] }
        set { self[FocusedRemovableEditionKey.self] = newValue }
    }
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
