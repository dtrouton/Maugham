import SwiftUI
import AppKit

/// `@MainActor` explicit on the type: `init` is not a `View` protocol
/// requirement (only `body` is), so nothing else isolates it, and the
/// `checker` default below needs `.shared` reachable from init's body.
@MainActor
public struct UpdateBannerView: View {
    @ObservedObject var checker: UpdateChecker
    @AppStorage("UpdateBanner.dismissedVersions") private var dismissedCSV: String = ""

    /// The parameter defaults to `nil`, not `.shared`, and the fallback lives
    /// in the init body instead. A default-argument *expression* is
    /// evaluated in a nonisolated context regardless of the enclosing type's
    /// declared isolation — confirmed by a minimal repro (`@MainActor` on
    /// both the type and a singleton `static let`, default arg still warns)
    /// against this project's concurrency-checking level (`minimal`, since
    /// `project.yml` sets no `SWIFT_STRICT_CONCURRENCY`; only
    /// `-strict-concurrency=complete` — a wider build-setting change, not a
    /// fix to this file — resolves it at the default-arg site). Moving the
    /// `.shared` read into the body makes it ordinary MainActor-isolated init
    /// code, sidestepping the default-argument slot entirely.
    /// `UpdateMenuCommand`/`UpdateSheet` share the same shape and the same
    /// fix.
    public init(checker: UpdateChecker? = nil) {
        self.checker = checker ?? .shared
    }

    public var body: some View {
        if case .readyToInstall(let bundle, let v, _) = checker.state,
           Self.shouldShow(state: checker.state, dismissed: dismissedSet) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                Text("Maugham \(v) is ready")
                    .font(.callout)
                Spacer()
                Button("Dismiss") { dismiss(version: v) }
                    .buttonStyle(.borderless)
                Button("Restart & Update") {
                    Task { await checker.installNow(bundleURL: bundle, version: v) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
            .overlay(Divider(), alignment: .bottom)
        }
    }

    private var dismissedSet: Set<String> {
        Set(dismissedCSV.split(separator: ",").map(String.init))
    }

    private func dismiss(version: String) {
        var s = dismissedSet
        s.insert(version)
        dismissedCSV = s.sorted().joined(separator: ",")
    }

    /// Pure decision function for testability. Banner shows iff state is
    /// `.readyToInstall` and the version hasn't been dismissed.
    public static func shouldShow(state: UpdateState, dismissed: Set<String>) -> Bool {
        if case .readyToInstall(_, let v, _) = state, !dismissed.contains(v) { return true }
        return false
    }
}
