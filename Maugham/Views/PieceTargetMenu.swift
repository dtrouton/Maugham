import SwiftUI
import AppKit
import MaughamCore

/// A piece's format's Mac-only strings and ranges — UI copy, so it stays out of
/// Core. Exhaustive: a new format answers each. Moved here from the old
/// piece inspector (shell p3 Task 8); `kindLabel` is the caption at the head
/// of a Collection piece's Brief (`BriefPane.formatCaption`).
extension DocumentFormat {
    var kindLabel: String {
        switch self {
        case .markdown: return "Prose"
        case .fountain: return "Screenplay"  // kind-name-ok: a piece's FORMAT label, not a project's kind
        }
    }

    var targetLabel: String {
        switch self {
        case .markdown: return "Word target"
        case .fountain: return "Page target"
        }
    }

    var targetRange: ClosedRange<Int> {
        switch self {
        case .markdown: return 0...100_000
        case .fountain: return 0...500
        }
    }

    var targetStep: Int {
        switch self {
        case .markdown: return 100
        case .fountain: return 1
        }
    }
}

/// **The open piece's target, set from the status line under the text** (shell
/// p3 Task 8) — where the old Inspector's word-target and page-target steppers
/// went. The right label of `EditorStatusFooter` becomes a menu: Set Word
/// Target… (prose) or Set Page Target… (a script), and Clear Target when one is
/// set. With nothing offered the label is the plain text it always was.
///
/// **Which target is the goal indicator's own rule** (`GoalIndicatorState`):
/// a Collection's piece measures in words or pages by its path, a reference
/// piece has none; elsewhere a screenplay's page target is the PROJECT's
/// (`ProjectManifest.targets.pageTarget`) and every other document's word
/// target is its own. Each write is the store call the inspector made.
///
/// **Offered where the piece may be restructured** — the question Rename,
/// Brief's line and the fold's Remove Link ask of a piece's manifest fields
/// (`TreeStructureVerbs.mayRestructure`); the project's page target asks it of
/// the project stream. Hidden, never disabled (tripwires 47, 51).
struct PieceTargetMenu: Equatable {

    enum Write: Hashable {
        /// `ProjectStore.updateInspector(id:wordTarget:)`.
        case pieceWords(String)
        /// `ProjectStore.updateInspector(id:pageTarget:)` — a Collection's script.
        case piecePages(String)
        /// `ProjectStore.updateProjectTargets(pageTarget:)` — a screenplay.
        case projectPages
    }

    let write: Write
    /// The target set now; nil is none.
    let current: Int?

    static let clearTitle = "Clear Target"

    var measuresPages: Bool {
        switch write {
        case .pieceWords: return false
        case .piecePages, .projectPages: return true
        }
    }

    var setTitle: String { measuresPages ? "Set Page Target…" : "Set Word Target…" }

    var fieldLabel: String {
        (measuresPages ? DocumentFormat.fountain : .markdown).targetLabel
    }

    var offersClear: Bool { current != nil }

    /// The old steppers' ranges and steps, each kept: a word target 0…100,000
    /// by 100; a Collection script's 0…500 by 1; a screenplay's project
    /// target 0…500 by 5.
    var range: ClosedRange<Int> {
        measuresPages ? DocumentFormat.fountain.targetRange : DocumentFormat.markdown.targetRange
    }

    var step: Int {
        switch write {
        case .pieceWords: return DocumentFormat.markdown.targetStep
        case .piecePages: return DocumentFormat.fountain.targetStep
        case .projectPages: return 5
        }
    }

    /// What the status line offers for `piece` (the piece open in the centre),
    /// or nil for the plain label.
    static func decide(piece: StructureItem?, projectType: ProjectType,
                       projectPageTarget: Int?,
                       postureOf: (String) -> Posture) -> PieceTargetMenu? {
        guard let piece, piece.type == .document else { return nil }
        if projectType.holdsPieces {
            if piece.pieceKind == .reference { return nil }
            guard TreeStructureVerbs.mayRestructure(piece, postureOf: postureOf) else { return nil }
            if DocumentFormat.ofManuscript(path: piece.path).isScreenplay {
                return PieceTargetMenu(write: .piecePages(piece.id), current: piece.pageTarget)
            }
            return PieceTargetMenu(write: .pieceWords(piece.id), current: piece.wordTarget)
        }
        if projectType.primaryFormat.isScreenplay {
            guard postureOf(DocumentClass.projectStreamDocId).allows(.restructure) else { return nil }
            return PieceTargetMenu(write: .projectPages, current: projectPageTarget)
        }
        guard TreeStructureVerbs.mayRestructure(piece, postureOf: postureOf) else { return nil }
        return PieceTargetMenu(write: .pieceWords(piece.id), current: piece.wordTarget)
    }

    /// The write, clamped to the range; 0 clears (the store stores nil).
    static func perform(_ write: Write, value: Int, store: ProjectStore) async throws {
        switch write {
        case .pieceWords(let id):
            try await store.updateInspector(id: id, wordTarget: value)
        case .piecePages(let id):
            try await store.updateInspector(id: id, pageTarget: value)
        case .projectPages:
            try await store.updateProjectTargets(pageTarget: value)
        }
    }

    func clamped(_ value: Int) -> Int { min(max(value, range.lowerBound), range.upperBound) }

    /// **What the writer typed, as a number** — digits, with the grouping
    /// marks a writer types in a large one ("3,000", "3 000", the locale's
    /// own). Anything else — empty, a sign, a decimal, a word — is nil: the
    /// entry is refused quietly and the stored target stands.
    static func parse(_ text: String, groupingSeparator: String? = Locale.current.groupingSeparator) -> Int? {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for mark in [",", " ", "\u{00A0}", "\u{202F}", "\u{2009}", groupingSeparator ?? ""] where !mark.isEmpty {
            // A decimal point is never a grouping mark here, whatever the
            // locale: "3.5" must not read as 35.
            guard mark != "." else { continue }
            digits = digits.replacingOccurrences(of: mark, with: "")
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// **The value a commit writes, or nil for no write** — on Set, on Return
    /// and on the field losing focus alike. Nil where the entry does not
    /// parse, and where it is the target already standing (`lastWritten`, the
    /// value this field wrote a moment ago, else the stored one), so the three
    /// commits of one edit write once.
    ///
    /// **Escape cancels** (`cancelled`): the macOS cancel gesture writes
    /// nothing, whatever was typed.
    func commitValue(text: String, lastWritten: Int? = nil, cancelled: Bool = false) -> Int? {
        guard !cancelled, let parsed = Self.parse(text) else { return nil }
        let value = clamped(parsed)
        return value == (lastWritten ?? current ?? 0) ? nil : value
    }
}

/// The small target field the status line's menu and a row's "Target…" open:
/// the old inspector's field and stepper, with Set.
///
/// **A `String`-backed field, parsed at the commit** (Task 8's review): a
/// `TextField(value:format:)` updates its binding only on Return or focus
/// loss, so Set pressed over freshly typed digits wrote the number from
/// before the edit. Here Set, Return and losing focus (the popover dismissed
/// by a click outside included) all commit what is in the field
/// (`PieceTargetMenu.commitValue`). **Escape cancels**: nothing is written.
struct PieceTargetField: View {
    let menu: PieceTargetMenu
    /// The write, with the clamped value.
    let onSet: (Int) -> Void
    /// Set or Return was pressed: the host closes its popover or sheet.
    var onDone: () -> Void = {}

    @State private var text: String
    @State private var lastWritten: Int?
    /// Escape was pressed: no later commit (the focus loss and the
    /// disappearance that follow it) writes.
    @State private var cancelled = false
    /// **Escape, noted before the popover acts on it** (shell p3 final
    /// wave). A popover's own Escape can close it before `onExitCommand`
    /// reaches the field, and the disappearance would then commit what was
    /// typed. The note watches key-downs while the field is up and only
    /// RECORDS an Escape — it never consumes one, so Escape still closes the
    /// popover, the sheet, or whatever the window's arbiter gives it to.
    @State private var escapeNote = EscapeNote()
    @FocusState private var focused: Bool

    init(menu: PieceTargetMenu, onSet: @escaping (Int) -> Void, onDone: @escaping () -> Void = {}) {
        self.menu = menu
        self.onSet = onSet
        self.onDone = onDone
        _text = State(initialValue: String(menu.current ?? 0))
    }

    /// The stepper steps the number in the field (the stored one while the
    /// field does not parse) and writes it back as text.
    private var stepped: Binding<Int> {
        Binding(get: { menu.clamped(PieceTargetMenu.parse(text) ?? lastWritten ?? menu.current ?? 0) },
                set: { text = String($0) })
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(menu.fieldLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .focused($focused)
                .onSubmit { commit(); onDone() }
                .onExitCommand { cancel() }
            Stepper("", value: stepped, in: menu.range, step: menu.step)
                .labelsHidden()
            Button("Set") { commit(); onDone() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .onExitCommand { cancel() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
        .onAppear { escapeNote.start() }
        // A click outside dismisses a popover without the field ever
        // reporting a focus change.
        .onDisappear {
            commit()
            escapeNote.stop()
        }
    }

    private func commit() {
        guard let value = menu.commitValue(text: text, lastWritten: lastWritten,
                                           cancelled: cancelled || escapeNote.pressed) else { return }
        lastWritten = value
        onSet(value)
    }

    private func cancel() {
        cancelled = true
        onDone()
    }
}

extension PieceTargetField {
    /// Records an Escape key-down while the field is up; never consumes it.
    @MainActor
    final class EscapeNote {
        private(set) var pressed = false
        private var token: Any?

        /// The key code AppKit gives Escape.
        static let escapeKeyCode: UInt16 = 53

        /// Pure: whether a key-down marks the edit cancelled.
        static func cancels(keyCode: UInt16) -> Bool { keyCode == escapeKeyCode }

        func note(keyCode: UInt16) {
            if Self.cancels(keyCode: keyCode) { pressed = true }
        }

        func start() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.note(keyCode: event.keyCode)
                return event   // observed, never consumed
            }
        }

        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }
    }
}
