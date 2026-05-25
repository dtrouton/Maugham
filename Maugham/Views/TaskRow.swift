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
        // Double-click to jump to the source paragraph. Single-click is
        // reserved for row selection / drag initiation — SwiftUI's
        // `.onMove` gesture (wired on the List in TasksPane) requires
        // the press-and-move sequence to start cleanly from the row;
        // an `.onTapGesture` with count=1 here ate the press and forced
        // the writer to grab the row's padding margin to drag, which
        // was confusing. Double-click is the standard macOS "open this"
        // gesture and composes correctly with `.onMove`.
        .onTapGesture(count: 2) { onJump() }
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
