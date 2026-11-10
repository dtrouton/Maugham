import Foundation

/// Snapshot of "the bytes we know are on disk, or are putting there." Used by
/// `Document.handleExternalDiskChange` to short-circuit presenter callbacks
/// that arrive in response to our own writes (autosave + external-ingest).
///
/// Type-level contract:
///
/// - `isOurOwn(_:)` is read by exactly one consumer: the echo guard in
///   `handleExternalDiskChange`. `bytes` (the landed bytes) is otherwise read
///   only by tests and the dev inspector.
/// - A fresh `EchoState` is built at two named call sites — `initialLoad` and
///   `afterWrite` — and an existing one moves only through `writing(_:)` and
///   `writeFailed()`. Other code can't assign an arbitrary `EchoState` into
///   `Document.lastDiskEcho`, which makes the writer surface auditable. A raw
///   `String` field doesn't give you that.
/// - **The bytes in flight are ours too** (typing loop plan 1, Task 2). The
///   autosave writes off the main actor, so between `writing(_:)` and
///   `afterWrite` disk bytes equal to EITHER the landed bytes (a callback for
///   the previous write, arriving late) or the in-flight bytes (a callback
///   for this one, beating the landing hop) are an echo. A failed write drops
///   the in-flight bytes and leaves the landed ones: an atomic write that
///   failed changed nothing on disk.
/// - `writtenAt` is informational (diagnostics + future telemetry). The
///   echo guard uses byte-equality only; timestamps drift across NSFileCoordinator
///   round-trips and aren't reliable to compare.
internal struct EchoState: Equatable {
    /// The bytes that last landed (or that the load found).
    let bytes: String
    /// The bytes an autosave is writing right now, if one is.
    let inFlight: String?
    let writtenAt: Date

    private init(bytes: String, inFlight: String?, writtenAt: Date) {
        self.bytes = bytes
        self.inFlight = inFlight
        self.writtenAt = writtenAt
    }

    /// The initial snapshot read at `Document.load` time. The bytes are
    /// whatever was on disk when the document opened; if the user externally
    /// edits the file between two app launches without typing in Maugham,
    /// the first presenter callback after open won't be an echo and will
    /// take the real-external-edit branch.
    static func initialLoad(bytes: String) -> EchoState {
        EchoState(bytes: bytes, inFlight: nil, writtenAt: Date())
    }

    /// Recorded when the autosave's coordinated write has landed. Pairs with
    /// `Document.runAutosave`.
    static func afterWrite(bytes: String) -> EchoState {
        EchoState(bytes: bytes, inFlight: nil, writtenAt: Date())
    }

    /// The autosave is about to write `inFlight`; the landed bytes stay ours.
    func writing(_ inFlight: String) -> EchoState {
        EchoState(bytes: bytes, inFlight: inFlight, writtenAt: writtenAt)
    }

    /// The write in flight failed: drop it; the landed bytes are unchanged.
    func writeFailed() -> EchoState {
        EchoState(bytes: bytes, inFlight: nil, writtenAt: writtenAt)
    }

    /// Whether `disk` is bytes we put there, or are putting there.
    func isOurOwn(_ disk: String) -> Bool {
        disk == bytes || disk == inFlight
    }
}
