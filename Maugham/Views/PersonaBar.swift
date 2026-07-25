import SwiftUI

/// The four-persona switcher. Lives in the window's top safe-area inset via
/// TopChromeModifier, so ProjectWindow.body's modifier chain is untouched.
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
                Button {
                    onSelect(candidate)
                } label: {
                    Label(candidate.displayName, systemImage: candidate.systemImageName)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: candidate == persona ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(candidate == persona
                                      ? Color.accentColor.opacity(0.18)
                                      : Color.clear))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("\(candidate.displayName) (⌘\(candidate.shortcutKey))")
                .accessibilityLabel(Self.accessibilityLabel(for: candidate))
                .accessibilityAddTraits(candidate == persona ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
