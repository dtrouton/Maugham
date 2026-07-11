import Foundation

/// Path helpers for the per-device inbox manifest stream. Mirrors the shape of
/// `OpLogStore`'s static path builders — callers apply `DeviceSlug.make(from:)`
/// to obtain the slug, then hand it here.
///
/// Both surfaces that write the manifest must call `inboxManifestURL` — no
/// hand-rolling `"inbox.\(slug).jsonl"` in surface code. The phone construction
/// tripwire (`TripwirePhoneGrepTest`) enforces this.
public enum InboxManifest {

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
