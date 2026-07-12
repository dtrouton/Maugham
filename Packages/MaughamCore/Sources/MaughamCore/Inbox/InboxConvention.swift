import Foundation

/// Canonical inbox asset-subdir conventions shared by Mac and phone
/// (tripwire 19; mirrors `PaletteConvention`, the in-repo template).
/// Kind-scoped asset subdirs live under `.maugham/inbox/`: `images/`,
/// `audio/` (`.text` is inline-only — no asset, no subdir). SINGLE SOURCE OF
/// TRUTH for the subdir names and the (kind, filename) → URL mapping — the
/// phone writer (`InboxCaptureWriter`) and the Mac reader
/// (`InboxStore.assetURL(for:)`) both resolve through this, so a given
/// (kind, filename) pair always lands on the same URL on both surfaces.
public enum InboxConvention {
    public static let imagesSubdir = "images"
    public static let audioSubdir = "audio"

    /// The asset subdir for `kind`, or nil for `.text` (inline-only, no asset).
    public static func assetSubdir(for kind: InboxEntry.Kind) -> String? {
        switch kind {
        case .image: return imagesSubdir
        case .audio: return audioSubdir
        case .text: return nil
        }
    }

    /// The asset subdirectory for `kind` under `inboxDir` (`.maugham/inbox/`),
    /// or nil for `.text`. Writers `ensureDirectory` here before writing.
    public static func assetDir(for kind: InboxEntry.Kind, inboxDir: URL) -> URL? {
        guard let subdir = assetSubdir(for: kind) else { return nil }
        return inboxDir.appendingPathComponent(subdir, isDirectory: true)
    }

    /// Absolute file URL for `kind`'s asset named `filename` under `inboxDir`,
    /// or nil for `.text`.
    public static func assetURL(kind: InboxEntry.Kind, filename: String, inboxDir: URL) -> URL? {
        assetDir(for: kind, inboxDir: inboxDir)?.appendingPathComponent(filename)
    }
}
