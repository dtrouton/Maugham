import SwiftUI

public struct UpdateMenuCommand: Commands {
    @ObservedObject var checker: UpdateChecker
    @State private var sheetPresented = false

    public init(checker: UpdateChecker = .shared) {
        self.checker = checker
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            if BuildVariant.current.updaterEnabled {
                Button(Self.menuTitle(for: checker.state)) {
                    sheetPresented = true
                }
                .sheet(isPresented: $sheetPresented) {
                    UpdateSheet(checker: checker, dismiss: { sheetPresented = false })
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
        case .ready: return "Install Update…"
        }
    }
}
