import SwiftUI
import AppKit

/// The window's one line when the project's settings file was missing and
/// `ProjectStore.load` put it back from its safety copy (#92, Denver's
/// ruling). Sits in the top banner strip beside `BackupRecoveryBanner`;
/// zero-height unless the load restored the file, and its ✕ clears the
/// store's notice, so it is said once.
struct ManifestRestoredBanner: View {
    let store: ProjectStore?

    var body: some View {
        if let store, let notice = store.manifestRestoredNotice {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .foregroundStyle(.secondary)
                Text(notice).font(.callout)
                Spacer()
                Button {
                    store.manifestRestoredNotice = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
            .overlay(Divider(), alignment: .bottom)
        }
    }
}
