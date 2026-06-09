import Foundation
import MaughamCore

/// Content-signature snapshot of "the manifest bytes we last know are on disk."
///
/// Mirrors `EchoState` (the manuscript `.md` echo guard) for the project
/// manifest. The project-root `NSFilePresenter` fires `handleManifestChanged`
/// after *our own* coordinated `writeManifest`; without an echo the handler
/// re-reads disk, sees a newer `modified` timestamp than it last observed, and
/// archives a `.maugham/conflicts/manifest-*.json` for our own write on every
/// structural edit (finding 1.2). The timestamp compare also had a whole-second
/// truncation hole: a genuinely-different external manifest written in the same
/// whole second was silently accepted (finding O2).
///
/// The guard here is a content hash (SHA-256 over the exact bytes), not a
/// timestamp — so a self-write is recognized exactly and a same-second external
/// change is still detected.
///
/// Type-level contract (mirrors `EchoState`):
/// - `hash` is read by exactly one consumer: the echo guard in
///   `DocumentStore.handleManifestChanged`.
/// - Construction is restricted to the two named factories, so no code can
///   assign an arbitrary signature into `DocumentStore.lastWrittenManifest`.
///   A bare reassignable `Date?`/`String?` wouldn't give that auditability.
struct ManifestEcho: Equatable {
    /// SHA-256 hex of the manifest bytes we last know are on disk.
    let hash: String

    private init(hash: String) {
        self.hash = hash
    }

    /// Seeded at `DocumentStore.open` from the manifest bytes present on disk
    /// at open time. If the user edits the manifest externally between two app
    /// launches without an own-write in between, the first presenter callback
    /// hashes different bytes and takes the real-external-change branch.
    static func initialLoad(bytes: Data) -> ManifestEcho {
        ManifestEcho(hash: MerkleBuilder.sha256Hex(bytes))
    }

    /// Recorded inside `writeManifest`'s coordinated write block (synchronous,
    /// relative to the write) so a concurrent presenter callback can't observe a
    /// half-updated state. The bytes are exactly what we wrote to disk.
    static func afterWrite(bytes: Data) -> ManifestEcho {
        ManifestEcho(hash: MerkleBuilder.sha256Hex(bytes))
    }
}
