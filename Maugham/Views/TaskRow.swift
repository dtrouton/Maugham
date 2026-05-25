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
        // No row-wide tap gesture. Earlier `.simultaneousGesture(TapGesture
        // (count: 2))` made SwiftUI wait to see if a press would resolve
        // as a double-click, eating drag initiation throughout the row
        // interior — the writer could only drag from the row padding
        // (above/below the body), not from the body text. Jump-to-source
        // moved to the source-badge icon (single click); double-click on
        // the body text also jumps as a redundant affordance via
        // `body_`'s own gesture.
    }

    @ViewBuilder
    private var body_: some View {
        let text = Text(task.body)
            .strikethrough(task.status == .done)
            .lineLimit(2)
        switch task.kind {
        case .inlineMarkdown, .fountainBoneyard:
            text
                .help("Edit the document text to change this task. Double-click to jump to source.")
                .onTapGesture(count: 2) { onJump() }
        case .paneCreated:
            text
        }
    }

    @ViewBuilder
    private var sourceBadge: some View {
        // Single-click jumps to the source paragraph. Pane-created tasks
        // have no paragraph anchor; the badge stays non-interactive for
        // them (clicking is a no-op via the disabled button style).
        switch task.kind {
        case .inlineMarkdown:
            Button {
                onJump()
            } label: {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Jump to source paragraph")
        case .fountainBoneyard:
            Button {
                onJump()
            } label: {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Jump to source paragraph")
        case .paneCreated:
            Image(systemName: "square.dashed")
                .foregroundStyle(.secondary)
                .help("Pane-created task — no source to jump to")
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
