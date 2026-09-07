import Foundation

/// Path helpers for the per-device inbox manifest stream. Mirrors the shape of
/// `OpLogStore`'s static path builders — callers apply `DeviceSlug.make(from:)`
/// to obtain the slug, then hand it here.
///
/// Both surfaces that write the manifest must call `inboxManifestURL` — no
/// hand-rolling `"inbox.\(slug).jsonl"` in surface code. The phone construction
/// tripwire (`TripwirePhoneGrepTest`) enforces this.
public enum InboxManifest {

    /// The stream name the inbox's chain files quarantined lines under, and the
    /// `docId` every inbox `ChainPolicy` carries. The inbox is not a document —
    /// its manifest holds captures for a whole project — so it has no docId of
    /// its own to borrow, and a set-aside record has to say WHICH history it
    /// came out of. One constant, used by the Mac's `InboxStore` and the
    /// phone's `InboxCaptureWriter` alike, so the two surfaces cannot file the
    /// same event under two spellings.
    public nonisolated static let chainDocId = "inbox"

    /// The inbox manifest file a writer on device `deviceSlug` appends to:
    /// `<projectURL>/.maugham/inbox/inbox.<deviceSlug>.jsonl`. SINGLE SOURCE OF
    /// TRUTH for inbox manifest filename construction (cross-surface: phone
    /// `InboxCaptureWriter` writes, Mac `InboxStore` reads/writes). Don't
    /// hand-roll the `"inbox.\(slug).jsonl"` template.
    public nonisolated static func inboxManifestURL(
        forDeviceSlug deviceSlug: DeviceSlug, in projectURL: URL
    ) -> URL {
        projectURL
            .appendingPathComponent(".maugham/inbox", isDirectory: true)
            .appendingPathComponent("inbox.\(deviceSlug.raw).jsonl")
    }
}
