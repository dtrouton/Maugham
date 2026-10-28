import SwiftUI

/// **The Tasks pane's toolbar, measured to fit its column** (#122).
///
/// Doc/Project, the status filter, New task (+) and the … menu. On one row
/// they want more than the right column's floor, and an over-wide row
/// inflated the pane, and `RightColumn` cropped it on both edges until #122
/// made its clip leading-aligned (Denver's smoke, the … menu half off screen).
///
/// So it is a `ViewThatFits` over three variants, widest first: one row with
/// worded filters, one row with icon filters, and two rows — Doc/Project, +
/// and … on top, the filter beneath. `ViewThatFits` draws its LAST child
/// whether it fits or not, so the two-row variant must fit the floor, and
/// `RightColumnPaneWidthTests` measures that it does. Every control is in every
/// variant.
///
/// Values in, closures out: no store, so a test can build it windowless.
struct TasksPaneToolbar: View {
    @Binding var scope: TasksPane.ScopeChoice
    @Binding var statusFilter: TaskStatusFilterItem
    /// Whether + is drawn — hidden where the posture offers no task anywhere
    /// (P3c Task 8), never greyed for that reason.
    let showsNewTask: Bool
    /// The "no document for Doc scope" disable, a different fact.
    let newTaskDisabled: Bool
    let showsBulkMenu: Bool
    let onNewTask: () -> Void
    let onArchiveAllDone: () -> Void

    /// The three shapes, widest first. Internal so the width test can measure
    /// each one; production always draws `nil`, the `ViewThatFits`.
    enum Variant: CaseIterable { case oneRowLabels, oneRowIcons, twoRows }
    var variant: Variant? = nil

    var body: some View {
        Group {
            if let variant {
                shape(variant)
            } else {
                ViewThatFits(in: .horizontal) {
                    shape(.oneRowLabels)
                    shape(.oneRowIcons)
                    shape(.twoRows)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func shape(_ variant: Variant) -> some View {
        switch variant {
        case .oneRowLabels: oneRow(filter: .labels)
        case .oneRowIcons: oneRow(filter: .icons)
        case .twoRows:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    scopePicker
                    Spacer(minLength: 4)
                    actions
                }
                filter(.adaptive)
            }
        }
    }

    private func oneRow(filter layout: AdaptiveFilterRow<TaskStatusFilterItem>.Layout) -> some View {
        HStack(spacing: 6) {
            scopePicker
            Spacer(minLength: 4)
            filter(layout)
            Spacer(minLength: 4)
            actions
        }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            Text("Doc").tag(TasksPane.ScopeChoice.document)
            Text("Project").tag(TasksPane.ScopeChoice.project)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .labelsHidden()
    }

    private func filter(_ layout: AdaptiveFilterRow<TaskStatusFilterItem>.Layout) -> some View {
        AdaptiveFilterRow(
            items: TaskStatusFilterItem.allCases,
            selection: $statusFilter,
            layout: layout)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if showsNewTask {
                Button(action: onNewTask) {
                    Image(systemName: "plus")
                }
                .help("New task")
                .disabled(newTaskDisabled)
            }

            if showsBulkMenu {
                Menu {
                    Button("Archive all done", action: onArchiveAllDone)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Bulk actions")
            }
        }
    }
}
