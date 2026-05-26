import SwiftUI
import AppKit

public struct UpdateSheet: View {
    @ObservedObject var checker: UpdateChecker
    let dismiss: () -> Void

    public init(checker: UpdateChecker = .shared, dismiss: @escaping () -> Void) {
        self.checker = checker
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Self.title(for: checker.state))
                .font(.headline)

            content
                .frame(minWidth: 380)

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .task {
            // Run a fresh check whenever the sheet opens, unless an active
            // download/install is mid-flight. Earlier code gated on
            // `state == .idle`, but after the first background poll the
            // state becomes `.upToDate(currentVersion: …)` and stays
            // there — so manual "Check for Updates" would just show the
            // cached up-to-date message and never re-fetch. v0.3.1's
            // URLCache-bypass fix was correct but irrelevant because the
            // fetch wasn't being invoked at all.
            switch checker.state {
            case .idle, .upToDate, .error:
                await checker.checkNow()
            case .checking, .downloading, .ready:
                break  // already doing something; don't restart it
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch checker.state {
        case .idle, .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Contacting GitHub…")
            }
        case .downloading(_, let progress):
            ProgressView(value: progress).progressViewStyle(.linear)
        case .ready(_, _, let notes):
            ScrollView {
                Text(notes)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        case .error(let msg):
            Text(msg).foregroundColor(.secondary)
        case .upToDate:
            Text("You're running the latest version.")
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch checker.state {
        case .idle, .checking, .downloading:
            Button("Close", action: dismiss)
        case .ready(_, let dmg, _):
            Button("Later", action: dismiss)
            Button("Install") {
                NSWorkspace.shared.activateFileViewerSelecting([dmg])
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        case .error:
            Button("Close", action: dismiss)
            Button("Retry") {
                Task { await checker.checkNow() }
            }
            .keyboardShortcut(.defaultAction)
        case .upToDate:
            Button("Done", action: dismiss)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Title for a given state. Exposed as a static for testability.
    public static func title(for state: UpdateState) -> String {
        switch state {
        case .idle: return "Check for Updates"
        case .checking: return "Checking for Updates…"
        case .downloading(let v, _): return "Downloading Maugham \(v)…"
        case .ready(let v, _, _): return "Maugham \(v) is Ready to Install"
        case .error: return "Couldn't Check for Updates"
        case .upToDate(let v): return "Maugham \(v) is Up to Date"
        }
    }
}
