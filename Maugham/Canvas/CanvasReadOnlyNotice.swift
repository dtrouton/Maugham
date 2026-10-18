import SwiftUI

/// The banner over a canvas whose layout file this build refused (issue #44):
/// it says WHY the canvas takes no edits, and — for a damaged file, the one
/// case with a way out from here — offers **Start a Fresh Layout**.
///
/// `ViewOnlyShareNotice`'s look and rules: a lock glyph on a cool slate, not
/// dismissable (the fact holds for as long as the file does), mounted as a
/// `safeAreaInset(edge: .top)` OUTSIDE `CanvasView`'s layer stack so the
/// composition censuses and the frontmost-editor rule (tripwire 27) never see
/// it, and visible with the chrome hidden (⌘\) because it is a safety fact,
/// not chrome. And for the same measured reason as that notice, no
/// `fixedSize(horizontal: false, vertical: true)` — see its comment.
///
/// **Its words are the refusal's own** (`CanvasStore.SidecarRefused.Reason
/// .sentence`), so the notice, the inbox alert and the tool's refusal cannot
/// say different things. Every decision is a `static`, pinned windowlessly
/// (tripwire 33); the button's press is the model's verb, tested on the model.
struct CanvasReadOnlyNotice: View {
    let refusal: CanvasStore.SidecarRefused
    /// `CanvasModel.startFreshLayout`, handed in so this view names no model.
    let startFreshLayout: () throws -> Void

    @State private var failure: String?

    /// The notice's sentence for `reason` — the refusal's own words.
    static func sentence(for reason: CanvasStore.SidecarRefused.Reason) -> String {
        reason.sentence
    }

    /// The button's label. The MCP refusal for a damaged file tells Claude to
    /// ask the writer to press a button by THIS name, so it is spelled once.
    static let startFreshTitle = "Start a Fresh Layout"

    /// Whether the notice offers Start a Fresh Layout. Only a DAMAGED file: a
    /// newer build's file is somebody's real layout, and its way out is
    /// updating Maugham, never setting it aside.
    static func offersStartFresh(for reason: CanvasStore.SidecarRefused.Reason) -> Bool {
        reason == .damaged
    }

    static func accessibilityLabel(for reason: CanvasStore.SidecarRefused.Reason) -> String {
        "Read-only canvas. " + sentence(for: reason)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(Self.sentence(for: refusal.reason))
                .font(.system(size: 11, weight: .medium))
                .accessibilityLabel(Self.accessibilityLabel(for: refusal.reason))
            Spacer(minLength: 8)
            if Self.offersStartFresh(for: refusal.reason) {
                Button(Self.startFreshTitle) {
                    do {
                        try startFreshLayout()
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .controlSize(.small)
                .alert("Couldn't start a fresh layout",
                       isPresented: Binding(get: { failure != nil },
                                            set: { if !$0 { failure = nil } })) {
                    Button("OK", role: .cancel) { failure = nil }
                } message: {
                    Text(failure ?? "")
                }
            }
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
        .accessibilityElement(children: .contain)
    }

    private static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkForNotice
            ? NSColor(srgbRed: 0.18, green: 0.20, blue: 0.24, alpha: 1.0)
            : NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1.0)
    })

    private static let foreground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkForNotice
            ? NSColor(srgbRed: 0.82, green: 0.85, blue: 0.90, alpha: 1.0)
            : NSColor(srgbRed: 0.28, green: 0.32, blue: 0.40, alpha: 1.0)
    })

    private static let border = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkForNotice
            ? NSColor(srgbRed: 0.40, green: 0.44, blue: 0.50, alpha: 0.5)
            : NSColor(srgbRed: 0.65, green: 0.68, blue: 0.74, alpha: 0.6)
    })
}

private extension NSAppearance {
    var isDarkForNotice: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
