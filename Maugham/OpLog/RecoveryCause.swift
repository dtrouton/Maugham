import Foundation
import MaughamCore

/// Why a document refused to open, classified for the recovery ladder
/// (spec §3). The classifier looks at the REFUSAL error — never at partial
/// content — so classification itself can't leak partial state.
enum RecoveryCause: Equatable {
    /// A dataless iCloud stub: transient. The pane waits, downloads, and
    /// auto-opens editable. Never offers read-only or (Plan B) quarantine.
    case icloudNotDownloaded(fileName: String, fileURL: URL)
    /// Unreadable for a non-stub reason (permissions break, squatting entry).
    case unreadableFile(fileName: String, fileURL: URL, reason: String)
    /// The ops directory itself can't be listed — nothing enumerable, so no
    /// partial view is possible (spec §3).
    case unlistableOpsDirectory(reason: String)

    /// Classify a `Document.load` refusal. Returns nil for errors the ladder
    /// doesn't own (they keep today's bare-message rendering).
    static func classify(
        loadError: Error,
        projectURL: URL,
        isDatalessStub: (URL) -> Bool = RecoveryCause.defaultStubProbe
    ) -> RecoveryCause? {
        guard let readError = loadError as? OpLogStore.ReadError else { return nil }
        switch readError {
        case .unreadableFile(let name, let underlying):
            let url = projectURL
                .appendingPathComponent(".maugham/ops", isDirectory: true)
                .appendingPathComponent(name)
            return isDatalessStub(url)
                ? .icloudNotDownloaded(fileName: name, fileURL: url)
                : .unreadableFile(fileName: name, fileURL: url, reason: underlying)
        case .unlistableOpsDirectory(let underlying):
            return .unlistableOpsDirectory(reason: underlying)
        }
    }

    /// Production stub probe: an item iCloud knows about whose content isn't
    /// current on this machine. Any resource-read failure answers false —
    /// misclassifying a stub as unreadable degrades to the honest generic
    /// message; the reverse (waiting forever on a permissions break) is worse.
    static func defaultStubProbe(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys:
            [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }
}
