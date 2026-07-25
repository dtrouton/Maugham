import SwiftUI

/// The four-persona switcher. Lives in the WINDOW TOOLBAR, mounted by
/// `TopChromeModifier`'s `.toolbar { ToolbarItem(placement: .navigation) }`.
///
/// It used to live in a `.safeAreaInset(edge: .top)` wrapped around the
/// `NavigationSplitView`, and that occluded the top of both columns: a
/// permanently non-zero top inset applied OUTSIDE a `NavigationSplitView` is
/// not propagated into the columns' own layout, so the binder's segmented
/// picker and the right pane's segment row were pushed under the strip and out
/// of sight (2026-07-25 smoke, defect A). The toolbar is also the Mac-native
/// shape the design asked for, so the control moved rather than the inset.
/// Because it is a toolbar item now it carries NO background/padding chrome of
/// its own — the toolbar supplies both.
///
/// Clicking a segment posts `.maughamSetPersona` exactly as ⌘1–4 do, so there
/// is ONE code path that changes persona and applies the segment coercions —
/// `PersonaModifier`. The bar deliberately holds no mutation logic of its own.
/// (The `.keyWindow` scope is safe here: the bar is window chrome, never
/// inside a sheet or confirmationDialog, so the receiving window is key.)
struct PersonaBar: View {
    let persona: Persona
    let onSelect: (Persona) -> Void

    static func isVisible(isNoChromeOn: Bool) -> Bool { !isNoChromeOn }

    static func accessibilityLabel(for persona: Persona) -> String {
        "\(persona.displayName) mode, Command \(persona.shortcutKey)"
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Persona.allCases, id: \.self) { candidate in
                PersonaBarButton(
                    candidate: candidate,
                    isSelected: candidate == persona,
                    onSelect: onSelect
                )
            }
        }
        .fixedSize()
    }
}

// MARK: - PersonaBarButton

private struct PersonaBarButton: View {
    let candidate: Persona
    let isSelected: Bool
    let onSelect: (Persona) -> Void

    private var fontWeight: Font.Weight {
        isSelected ? .semibold : .regular
    }

    private var backgroundColor: Color {
        isSelected ? Color.accentColor.opacity(0.18) : Color.clear
    }

    private var accessibilityTraits: AccessibilityTraits {
        isSelected ? [.isSelected] : []
    }

    var body: some View {
        Button {
            onSelect(candidate)
        } label: {
            Label(candidate.displayName, systemImage: candidate.systemImageName)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: fontWeight))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(backgroundColor)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("\(candidate.displayName) (⌘\(candidate.shortcutKey))")
        .accessibilityLabel(PersonaBar.accessibilityLabel(for: candidate))
        .accessibilityAddTraits(accessibilityTraits)
    }
}
