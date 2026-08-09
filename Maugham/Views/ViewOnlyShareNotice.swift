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
    /// The notice's one sentence, `static` so the test that measures how wide
    /// it is asks production for the words rather than quoting them.
    static let sentence =
        "This share is view-only — ask the owner for edit access to leave comments."

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            // **No `fixedSize(horizontal: false, vertical: true)`, and the
            // absence is load-bearing.** This banner is a
            // `safeAreaInset(edge: .top)` on the window's WRITING column, so an
            // unbreakable minimum height here grows that column, and
            // `NSSplitView` then grows the binder and the right column with it
            // — the whole window laid out taller than the window, which is what
            // Denver's 2026-08-08 smoke found on the two `DiagnosticsPane`
            // sites. Measured with the modifier restored, this banner alone
            // took the split view to 866pt inside a 732pt window.
            //
            // **And it was protecting nothing**: the sentence is one 404pt line
            // at 11pt against a writing column whose floor is 480, so the width
            // at which the modifier would have done anything cannot occur. Both
            // facts are pinned in `DetailPaneColumnHeightCensusTests`.
            Text(Self.sentence)
                .font(.system(size: 11, weight: .medium))
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
