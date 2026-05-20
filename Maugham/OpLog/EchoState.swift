import Foundation

/// Snapshot of "the last bytes we know are on disk." Used by
/// `Document.handleExternalDiskChange` to short-circuit presenter callbacks
/// that arrive in response to our own writes (autosave + external-ingest).
///
/// Type-level contract:
///
/// - `bytes` is read by exactly one consumer: the echo guard in
///   `handleExternalDiskChange`.
/// - Construction is restricted to three named call sites — `initialLoad`,
///   `afterWrite`, `afterIngest`. Other code can't assign a fresh `EchoState`
///   into `Document.lastDiskEcho` without going through one of these,
///   which makes the writer surface auditable. A raw `String` field doesn't
///   give you that.
/// - `writtenAt` is informational (diagnostics + future telemetry). The
///   echo guard uses byte-equality only; timestamps drift across NSFileCoordinator
///   round-trips and aren't reliable to compare.
internal struct EchoState: Equatable {
    let bytes: String
    let writtenAt: Date

    /// The initial snapshot read at `Document.load` time. The bytes are
    /// whatever was on disk when the document opened; if the user externally
    /// edits the file between two app launches without typing in Maugham,
    /// the first presenter callback after open won't be an echo and will
    /// take the real-external-edit branch.
    static func initialLoad(bytes: String) -> EchoState {
        EchoState(bytes: bytes, writtenAt: Date())
    }

    /// Recorded inside the autosave's coordinated write block (synchronous).
    /// Pairs with `Document.performAutosave`'s `coord.coordinate(writingItemAt:)`.
    static func afterWrite(bytes: String) -> EchoState {
        EchoState(bytes: bytes, writtenAt: Date())
    }

    /// Recorded after a successful external-ingest (silent-ingest branch
    /// of handleExternalDiskChange, or `handleExternalDiskChangeForceIngest`
    /// for `Use cloud` conflict resolution). The bytes we record are the
    /// disk bytes — the next presenter callback for the same bytes is an
    /// echo of our own ingest, not a re-external-edit.
    static func afterIngest(bytes: String) -> EchoState {
        EchoState(bytes: bytes, writtenAt: Date())
    }
}
