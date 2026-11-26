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
    /// The triage choice, or nil when no note in scope carries a mark — the
    /// control is then not drawn at all (Task 7b).
    var triage: ResolveTriageChoice? = nil
    var onTriage: (ResolveTriageChoice) -> Void = { _ in }
    let onToggle: (ResolveSource) -> Void
    let onToggleSelectionMode: () -> Void
    let onNewTodo: () -> Void

    var body: some View {
        // One row when it fits; else the triage control wraps beneath the
        // chips — never clipped, never a bare icon while a choice narrows the
        // list (Task 7b fix). The chips scroll, so how many there are never
        // decides it: the chips ask only `chipsIdealWidth` of the row, and the
        // bare All flag (or a short choice) stays at the row's end however
        // wide the chip set is (review minor).
        ViewThatFits(in: .horizontal) {
            row(includesTriage: true)
            wrapped
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    /// What the chips' scroller asks of the row when the bar is sized: room
    /// for about one chip. They take whatever the row offers past that.
    static let chipsIdealWidth: CGFloat = 72

    /// The wrapped arm: the chips' row, then the triage control beneath.
    /// Internal so a test measures it on its own.
    var wrapped: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(includesTriage: false)
            if let triage { triageMenu(triage) }
        }
    }

    private func row(includesTriage: Bool) -> some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(chips, id: \.self) { chip in
                        chipButton(chip)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(minWidth: 0, idealWidth: Self.chipsIdealWidth, maxWidth: .infinity,
                   alignment: .leading)
            if includesTriage, let triage {
                triageMenu(triage)
            }
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
                .help(NewTaskSheet.title)
                .accessibilityLabel(NewTaskSheet.title)
            }
        }
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

    /// **The triage control** (Task 7b): a menu behind one icon, so it fits
    /// the column's floor beside the chips whatever the choice is called; the
    /// icon fills when a choice narrows the list, and the choice's word is in
    /// its help and its accessibility label.
    private func triageMenu(_ choice: ResolveTriageChoice) -> some View {
        Menu {
            ForEach(ResolveTriageChoice.allCases) { option in
                Button {
                    onTriage(option)
                } label: {
                    if option == choice {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            if let word = Self.triageWord(choice) {
                Label(word, systemImage: Self.triageSymbol(choice))
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            } else {
                Image(systemName: Self.triageSymbol(choice))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Self.triageHelp(choice))
        .accessibilityLabel(Self.triageHelp(choice))
    }

    /// **The active choice is named on the control** (Task 7b fix): the
    /// word beside the filled flag while a choice narrows the list; nil —
    /// the bare flag — under All.
    static func triageWord(_ choice: ResolveTriageChoice) -> String? {
        choice == .all ? nil : choice.label
    }

    static func triageSymbol(_ choice: ResolveTriageChoice) -> String {
        choice == .all ? "flag" : "flag.fill"
    }

    static func triageHelp(_ choice: ResolveTriageChoice) -> String {
        "Triage: \(choice.label)"
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
        case .changes: return TranslationVocabulary.toLookAt
        case .design: return "Design"
        case .compile: return "Compile"
        }
    }
}

// MARK: - The unread dot

/// **The unread signal** (shell plan 2 Task 7): a small accent dot, on To
/// resolve's position in the right column's picker and on its Checks chip.
/// A dot and never a count — how many is the list's to say.
struct UnreadDot: View {
    /// **A dot, never a number**: shown for any unread note.
    static func shows(unreadChecks: Int) -> Bool { unreadChecks > 0 }

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .accessibilityLabel("Unread")
    }
}
