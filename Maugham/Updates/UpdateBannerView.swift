import SwiftUI
import AppKit

public struct UpdateBannerView: View {
    @ObservedObject var checker: UpdateChecker
    @AppStorage("UpdateBanner.dismissedVersions") private var dismissedCSV: String = ""

    public init(checker: UpdateChecker = .shared) {
        self.checker = checker
    }

    public var body: some View {
        if case .ready(let v, let dmg, _) = checker.state,
           Self.shouldShow(state: checker.state, dismissed: dismissedSet) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                Text("Maugham \(v) is ready to install")
                    .font(.callout)
                Spacer()
                Button("Later") { dismiss(version: v) }
                    .buttonStyle(.borderless)
                Button("Install") {
                    NSWorkspace.shared.activateFileViewerSelecting([dmg])
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
    /// `.ready` and the version hasn't been dismissed.
    public static func shouldShow(state: UpdateState, dismissed: Set<String>) -> Bool {
        if case .ready(let v, _, _) = state, !dismissed.contains(v) { return true }
        return false
    }
}
