import Foundation

/// Classifies a file under `.maugham/inbox/` by which subtree it lives in.
/// Used by `MaughamSidecarPath`'s classifier (Mac) and the iOS capture writer.
/// `manifest` is the `inbox.<deviceSlug>.jsonl` stream itself; the other three
/// match the kind-scoped asset subdirs (`text/`, `images/`, `audio/`).
public enum InboxFileKind: String, Codable, Equatable, Sendable {
    case manifest
    case text
    case image
    case audio
}
