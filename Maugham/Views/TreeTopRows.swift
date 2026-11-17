import SwiftUI
import MaughamCore

/// **Where each kind of row stands in the tree** (shell p1 Task 3, spec "The
/// tree"): the Book; Inbox; Canvas; the manuscript; Figures; Research;
/// Palette; Editions; then the existing foot (Trash, Removed Elsewhere).
///
/// Every tree host draws its rows in this order — `BinderView`,
/// `CollectionPiecesPane` and `SceneNavigatorPane` each put up the Book row,
/// `TreeTopRows`, their manuscript, then `BinderTreeSections` (Figures,
/// Research, Palette, Editions). `TreeTopRowsTests` pins the order here and
/// reads it back off each host's source.
enum TreeRowSlot: CaseIterable, Equatable {
    case book, inbox, canvas, manuscript, figures, research, palette, editions

    /// The slots a tree draws: the Inbox only when the project has one, the
    /// Figures only when a figure is not parked, the Editions only when there
    /// is an edition to list (`TreeEditionRows.languages`).
    static func order(hasInbox: Bool, showsFigures: Bool,
                      showsEditions: Bool) -> [TreeRowSlot] {
        allCases.filter { slot in
            switch slot {
            case .inbox: return hasInbox
            case .figures: return showsFigures
            case .editions: return showsEditions
            case .book, .canvas, .manuscript, .research, .palette: return true
            }
        }
    }
}

/// **The Inbox and Canvas rows** — between the Book row and the manuscript.
///
/// Each is a row and a `.tag`, like the Book row: the tree's `List` selects
/// it, and the selection is a click through `ClickRule` (`BinderTreeSelection`)
/// — tripwire 9's reason a tree row is never an `.onTapGesture`. A selected
/// tag is what lets the open row draw the `List`'s own filled state, which a
/// row whose click was a `Button`'s action could not hold. Inset with the
/// manuscript: every place the project has stands under the Book.
///
/// No per-row work (tripwire 4): `hasInbox` is the host's cached answer.
struct TreeTopRows: View {
    let hasInbox: Bool

    var body: some View {
        if hasInbox {
            row("Inbox", systemImage: "tray", subject: .inbox)
        }
        row("Canvas", systemImage: "rectangle.on.rectangle.angled", subject: .canvas)
    }

    private func row(_ title: String, systemImage: String,
                     subject: BinderSubject) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            // The LABEL LEAF, before `.tag` (tripwire 9) — see TreeTravel.swift.
            .treeTravelOnDoubleClick(subject)
            .padding(.leading, ProjectRowLabel.childIndent)
            .tag(subject)
            .id(subject)
    }

    /// Whether the tree draws the Inbox row: the project has a capture
    /// manifest (`BinderTreeSectionsState.projectHasInbox`, cached), the
    /// window's inbox holds a capture, or the Inbox is what is open — a row
    /// that is open is always drawn.
    @MainActor
    static func hasInbox(state: BinderTreeSectionsState, store: ProjectStore,
                         subject: WindowSubject) -> Bool {
        if state.projectHasInbox || subject.open == .inbox { return true }
        guard let inbox = store.documentStore?.inboxStore else { return false }
        return !inbox.entries.isEmpty || !inbox.trashedEntries.isEmpty
    }
}

// MARK: - The row states

/// **What the tree marks besides the `List`'s own selection** (the row last
/// clicked): the open row when it is not that row, and the faces and what is
/// beside when they are neither. Worked out once per tree render at the
/// `List`, read by each row's mark.
struct TreeRowMarks: Equatable {
    var open: BinderSubject?
    var outlined: Set<BinderSubject> = []
}

private struct TreeRowMarksKey: EnvironmentKey {
    static let defaultValue = TreeRowMarks()
}

extension EnvironmentValues {
    var treeRowMarks: TreeRowMarks {
        get { self[TreeRowMarksKey.self] }
        set { self[TreeRowMarksKey.self] = newValue }
    }
}

/// **A row's state, drawn on its label leaf**: the open row a soft accent
/// fill, the faces or what is beside an accent outline. The `List`'s own
/// selection is the third, strongest state — the row last clicked. Takes no
/// hits.
struct TreeRowStateMark: ViewModifier {
    let subject: BinderSubject
    @Environment(\.treeRowMarks) private var marks

    func body(content: Content) -> some View {
        content.background {
            if marks.open == subject {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.22))
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if marks.outlined.contains(subject) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Hands every row in a tree its marks — once, at the `List`.
    @MainActor
    func treeRowStates(state: BinderTreeSectionsState,
                       subject: WindowSubject) -> some View {
        let shown = BinderTreeSelection.shown(state.selection, subject: subject,
                                              clickedAt: state.subjectAtLastClick)
        return environment(\.treeRowMarks, TreeRowMarks(
            open: BinderTreeSelection.openMark(shown: shown, subject: subject),
            outlined: BinderTreeSelection.outlined(shown: shown, subject: subject)))
    }
}
