import SwiftUI
import MaughamCore

/// A piece's format's Mac-only strings and ranges — UI copy, so it stays out of
/// Core. Exhaustive: a new format answers each. Moved here from
/// `PieceInspector` (shell p3 Task 8), whose arm still reads them until the
/// inspector goes.
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

    enum Write: Equatable {
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
    /// by 100 (both inspectors); a Collection script's 0…500 by 1
    /// (`PieceInspector`); a screenplay's project target 0…500 by 5
    /// (`InspectorView`).
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
}

/// The small target field the status line's menu opens: the old inspector's
/// field and stepper, with Set.
struct PieceTargetField: View {
    let menu: PieceTargetMenu
    let onSet: (Int) -> Void

    @State private var draft: Int

    init(menu: PieceTargetMenu, onSet: @escaping (Int) -> Void) {
        self.menu = menu
        self.onSet = onSet
        _draft = State(initialValue: menu.current ?? 0)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(menu.fieldLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("", value: $draft, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .onSubmit { onSet(menu.clamped(draft)) }
            Stepper("", value: $draft, in: menu.range, step: menu.step)
                .labelsHidden()
            Button("Set") { onSet(menu.clamped(draft)) }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}
