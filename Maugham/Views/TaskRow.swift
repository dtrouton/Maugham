import SwiftUI

/// A single row in `TasksPane`. Renders the checkbox toggle, body text,
/// source-kind badge, and a kebab menu (Archive + Delete for pane-created).
/// Click anywhere on the row dispatches `onJump` for navigation (a NOP for
/// pane-created project tasks that have no paragraph anchor).
///
/// Inline tasks (markdown `- [ ]` and Fountain `[[todo:]]`) deliberately
/// expose no body-edit affordance — their source of truth is the document
/// text. A `.help(...)` tooltip on the body Text directs the writer back to
/// the manuscript. See spec §11.
@MainActor
struct TaskRow: View {
    let task: WriterTask
    let onToggle: () -> Void
    let onJump: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle(
                "",
                isOn: Binding(
                    get: { task.status == .done },
                    set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            body_

            Spacer()
            sourceBadge
            kebabMenu
        }
        .contentShape(Rectangle())
        // Double-click to jump to the source paragraph. `.onTapGesture`
        // claims exclusivity over the click, so even
        // `.onTapGesture(count: 2)` ate single clicks (waiting for a
        // possible second tap before forwarding) — that blocked List's
        // selection binding AND `.onMove`'s drag initiation.
        // `.simultaneousGesture` lets the click reach both the gesture
        // recognizer and the List, so single-click selects the row
        // (and starts a drag if the user moves), double-click jumps.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onJump() }
        )
    }

    @ViewBuilder
    private var body_: some View {
        let text = Text(task.body)
            .strikethrough(task.status == .done)
            .lineLimit(2)
        switch task.kind {
        case .inlineMarkdown, .fountainBoneyard:
            text.help("Edit the document text to change this task.")
        case .paneCreated:
            text
        }
    }

    @ViewBuilder
    private var sourceBadge: some View {
        switch task.kind {
        case .inlineMarkdown:
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .help("Inline markdown task")
        case .fountainBoneyard:
            Image(systemName: "film")
                .foregroundStyle(.secondary)
                .help("Fountain boneyard task")
        case .paneCreated:
            Image(systemName: "square.dashed")
                .foregroundStyle(.secondary)
                .help("Pane-created task")
        }
    }

    @ViewBuilder
    private var kebabMenu: some View {
        Menu {
            Button("Archive", action: onArchive)
            if task.kind == .paneCreated {
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
