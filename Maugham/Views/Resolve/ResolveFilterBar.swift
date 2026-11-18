import SwiftUI
import MaughamCore

/// **To resolve's filter bar** — one chip per source with items in scope
/// (`ResolveFilter.chips`), selection mode's door, and New To-do.
///
/// Built from values so a test can measure it against the column's floor with
/// no store. The chips scroll sideways rather than wrap or push the trailing
/// controls off the column: a project may name any number of passes, and the
/// column's floor is narrow.
@MainActor
struct ResolveFilterBar: View {
    /// The chips, in the column's order.
    let chips: [ResolveSource]
    /// The selection as it stands (`ResolveFilter.normalized`); empty is all.
    let selection: Set<ResolveSource>
    /// The project's passes, for a pass chip's name.
    let passes: [ReviewPass]
    /// Selection mode's door: the open piece's notes, where a bulk verb is
    /// left to press. Hidden otherwise.
    let showsSelectionMode: Bool
    let selectionModeOn: Bool
    /// New To-do, where `TaskCreationScopes` files one anywhere.
    let showsNewTodo: Bool
    /// A check landed notes the writer has not had in front of them: the
    /// Checks chip wears the unread dot (shell plan 2 Task 7). The list
    /// clears it the moment it shows the checks' items, so the dot stands
    /// only while another filter hides them.
    var checksUnread: Bool = false
    let onToggle: (ResolveSource) -> Void
    let onToggleSelectionMode: () -> Void
    let onNewTodo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(chips, id: \.self) { chip in
                        chipButton(chip)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsSelectionMode {
                Button(action: onToggleSelectionMode) {
                    Image(systemName: selectionModeOn
                          ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .help(selectionModeOn ? "Done selecting" : "Select notes")
                .accessibilityLabel(selectionModeOn ? "Done selecting" : "Select notes")
            }
            if showsNewTodo {
                Button(action: onNewTodo) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New To-do")
                .accessibilityLabel("New To-do")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func chipButton(_ chip: ResolveSource) -> some View {
        let on = selection.contains(chip)
        return Button { onToggle(chip) } label: {
            Text(Self.label(chip, passes: passes))
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                .overlay(alignment: .topTrailing) {
                    if Self.wearsUnreadDot(chip, checksUnread: checksUnread) {
                        UnreadDot().offset(x: 2, y: -2)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Whether `chip` wears the unread dot: the Checks chip, while a check's
    /// notes are unread. A dot, never a number.
    static func wearsUnreadDot(_ chip: ResolveSource, checksUnread: Bool) -> Bool {
        chip == .checks && checksUnread
    }

    /// A chip's word. A pass the manifest no longer lists keeps a chip
    /// (`ResolveFilter.chips`) and is named as a pass.
    static func label(_ chip: ResolveSource, passes: [ReviewPass]) -> String {
        switch chip {
        case .pass(let id): return passes.first { $0.id == id }?.name ?? "Earlier pass"
        case .mine: return "Mine"
        case .checks: return "Checks"
        case .questions: return "Questions"
        case .others: return "Others"
        }
    }
}

// MARK: - The unread dot

/// **The unread signal** (shell plan 2 Task 7): a small accent dot, on To
/// resolve's position in the right column's picker and on its Checks chip.
/// A dot and never a count — how many is the list's to say.
struct UnreadDot: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .accessibilityLabel("Unread")
    }
}
