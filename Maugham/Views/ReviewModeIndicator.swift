import SwiftUI

/// A small, tasteful pill shown at the top of the editor content column while
/// review mode (⌘⌥R) is engaged. It is the *only* visible feedback that the
/// writing surface has switched into the read-only annotation posture, so it
/// is shown even in no-chrome mode — it IS the chrome for review.
///
/// Pure, one-way SwiftUI: reads the collaborator name, writes nothing back.
/// The warm terracotta/amber tint mirrors `ReviewPalette`'s review accent so
/// the indicator reads as "you are reviewing" rather than a neutral status
/// chip. Colours are adaptive (asset-free, resolved per appearance) so the
/// pill stays legible in both light and dark mode.
struct ReviewModeIndicator: View {
    /// The reviewer's display name — the same string used to author
    /// annotations (`UserPreferences.collaboratorDisplayName`).
    let collaboratorName: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 11, weight: .semibold))
            Text("Reviewing · \(collaboratorName)")
                .font(.system(size: 11, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .foregroundStyle(Self.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Self.background)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Self.border, lineWidth: 0.5)
        )
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reviewing as \(collaboratorName)")
    }

    // Warm terracotta/amber, resolved adaptively. NSColor-backed dynamic
    // colours so they re-resolve per effective appearance (light/dark) rather
    // than being captured once.
    private static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.45, green: 0.27, blue: 0.18, alpha: 1.0)   // muted terracotta, dark
            : NSColor(srgbRed: 0.98, green: 0.90, blue: 0.80, alpha: 1.0)   // warm amber wash, light
    })

    private static let foreground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.98, green: 0.86, blue: 0.74, alpha: 1.0)   // light warm text on dark pill
            : NSColor(srgbRed: 0.52, green: 0.28, blue: 0.12, alpha: 1.0)   // deep terracotta text on light pill
    })

    private static let border = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.70, green: 0.45, blue: 0.30, alpha: 0.6)
            : NSColor(srgbRed: 0.80, green: 0.55, blue: 0.30, alpha: 0.6)
    })
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
