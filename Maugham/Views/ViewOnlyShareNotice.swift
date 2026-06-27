import SwiftUI

/// A non-dismissable banner shown at the top of the editor when the current
/// user is an iCloud reviewer on a READ-ONLY share. On such a share the reviewer
/// cannot append annotation ops (comments / queries / suggestions) at all, so
/// rather than letting a comment attempt fail silently we say so plainly and
/// point them at the fix: ask the owner for edit access.
///
/// Pure, one-way SwiftUI (reads nothing back). Visually distinct from the warm
/// terracotta `ReviewModeIndicator` — a cooler, cautionary slate so it reads as
/// "blocked", not "you are reviewing".
struct ViewOnlyShareNotice: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("This share is view-only — ask the owner for edit access to leave comments.")
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Self.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Self.border)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "View-only share. Ask the owner for edit access to leave comments.")
    }

    private static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.18, green: 0.20, blue: 0.24, alpha: 1.0)
            : NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1.0)
    })

    private static let foreground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.82, green: 0.85, blue: 0.90, alpha: 1.0)
            : NSColor(srgbRed: 0.28, green: 0.32, blue: 0.40, alpha: 1.0)
    })

    private static let border = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.40, green: 0.44, blue: 0.50, alpha: 0.5)
            : NSColor(srgbRed: 0.65, green: 0.68, blue: 0.74, alpha: 0.6)
    })
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
