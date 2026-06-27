import AppKit
import MaughamCore

/// Presents the macOS "share for review" affordance for a project folder.
///
/// Approach + rationale: we use `NSSharingServicePicker` anchored to the project
/// window, seeded with the project's folder URL. When that folder lives in
/// iCloud Drive the picker includes the system **"Collaborate"** (iCloud shared
/// item) service, which opens Apple's native share-people sheet — the same flow
/// Finder offers. This is the robust, crash-free path: it needs no programmatic
/// `CKShare` plumbing (which is brittle to wire without on-device testing and is
/// a reasonable follow-up if a fully bespoke flow is ever wanted). If the folder
/// is NOT in iCloud Drive, Collaborate can't appear, so instead of presenting a
/// near-useless picker we show a clear explanation telling the writer to move
/// the project to iCloud Drive first.
///
/// The ubiquity check is split from the pure `ProjectShareEligibility` decision
/// (MaughamCore) so the branch logic stays unit-tested; only the OS probe and
/// the AppKit presentation live here.
@MainActor
enum ProjectShareSheetPresenter {

    /// Present the share sheet for `projectURL`, anchored to `window`. Uses the
    /// already-resolved `snapshot` (from `ProjectWindow`) only to phrase the
    /// "already shared" case; the share/explain branch is decided by ubiquity.
    static func present(
        projectURL: URL,
        snapshot: ShareMetadata?,
        in window: NSWindow?
    ) {
        let outcome = ProjectShareEligibility.evaluate(
            isInICloudDrive: isInICloudDrive(projectURL),
            metadata: snapshot)

        switch outcome {
        case .notInICloud:
            presentMoveToICloudAlert(in: window)
        case .shareable:
            presentSharePicker(for: projectURL, in: window)
        }
    }

    /// Whether `url` is a ubiquitous (iCloud Drive) item. `isUbiquitousItem` is
    /// the documented, side-effect-free probe; a non-iCloud path returns false.
    static func isInICloudDrive(_ url: URL) -> Bool {
        FileManager.default.isUbiquitousItem(at: url)
    }

    // MARK: - Share picker

    private static func presentSharePicker(for url: URL, in window: NSWindow?) {
        let picker = NSSharingServicePicker(items: [url])
        guard let contentView = window?.contentView else {
            // No anchor view (shouldn't happen for a focused project window).
            // Fall back to the key window's content view if available.
            if let fallback = NSApp.keyWindow?.contentView {
                picker.show(
                    relativeTo: .zero, of: fallback, preferredEdge: .minY)
            }
            return
        }
        // Anchor near the top-trailing of the content view (under the toolbar,
        // where the menu lives) — a stable, visible anchor rect.
        let bounds = contentView.bounds
        let anchor = NSRect(
            x: bounds.maxX - 1, y: bounds.maxY - 1, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
    }

    // MARK: - Move-to-iCloud explanation

    private static func presentMoveToICloudAlert(in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Move this project to iCloud Drive to share it"
        alert.informativeText = """
            To review with others, this project needs to be in iCloud Drive. \
            Move the project folder to iCloud Drive, then use Share → \
            Collaborate to invite reviewers.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
