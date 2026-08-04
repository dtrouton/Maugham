import SwiftUI
import MaughamCore

/// Identifier for the "Check for Updates…" Window scene declared in `MaughamApp`.
/// The menu item opens it via `@Environment(\.openWindow)` rather than presenting
/// a `.sheet` — `.sheet` on a Commands Button has no host view to render into.
public let updateWindowID = "update-check"

/// `@MainActor` + nil-default-then-fallback-in-body: same shape and same
/// reason as `UpdateBannerView`'s doc comment — a default-argument
/// expression referencing `.shared` (a `@MainActor`-isolated static) warns
/// regardless of the enclosing type's isolation, at this project's
/// concurrency-checking level.
@MainActor
public struct UpdateMenuCommand: Commands {
    @ObservedObject var checker: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    public init(checker: UpdateChecker? = nil) {
        self.checker = checker ?? .shared
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            if BuildVariant.current.updaterEnabled {
                Button(Self.menuTitle(for: checker.state)) {
                    openWindow(id: updateWindowID)
                }
            }
        }
    }

    /// Menu item title for a given state. Exposed as static for reuse + testing.
    public static func menuTitle(for state: UpdateState) -> String {
        switch state {
        case .idle, .upToDate, .error: return "Check for Updates…"
        case .checking: return "Checking for Updates…"
        case .downloading: return "Downloading Update…"
        case .readyToInstall: return "Install Update…"
        case .installing: return "Installing…"
        }
    }
}

/// Window content for the "Check for Updates…" scene. Wraps `UpdateSheet` and
/// supplies a `dismiss` that closes the hosting window.
public struct UpdateWindowContent: View {
    @Environment(\.dismissWindow) private var dismissWindow

    public init() {}

    public var body: some View {
        UpdateSheet(
            checker: .shared,
            dismiss: { dismissWindow(id: updateWindowID) })
    }
}
