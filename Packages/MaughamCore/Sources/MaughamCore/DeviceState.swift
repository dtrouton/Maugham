import Foundation

/// Where this device's own key material lives:
/// `~/Library/Application Support/<supportFolderName>/device`.
///
/// A path, not a store — `DeviceIdentity` is what reads and writes inside it.
/// The blob under here is the app's OWN file (spec §4.1): no keychain item, no
/// entitlement, nothing an installer or a profile can revoke. Its protection is
/// the enclave, not the filesystem — the bytes are useless off this machine.
public enum DeviceState {
    /// The device directory, plus a per-process leaf under XCTest and ONLY
    /// under XCTest — the `TestWorkspace.root` idiom verbatim, and for the same
    /// reason: the Mac suite runs classes across worker PROCESSES, so a shared
    /// directory would have one worker's fresh mint answering another worker's
    /// `current`. The live app is one process and keeps the bare path.
    public static var directory: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let base = lib
            .appendingPathComponent("Application Support")
            .appendingPathComponent(BuildVariant.current.supportFolderName)
            .appendingPathComponent("device")
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return base
        }
        if sweepFlag.claim() { sweepDeadWorkerLeaves(in: base) }
        return base.appendingPathComponent(
            "xctest-worker-\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// Create `url` and every parent it needs. Idempotent.
    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Housekeeping for the per-process leaves

    /// Once per process, on the first `directory` access under XCTest. The
    /// base is the same on every call by construction.
    private static let sweepFlag = SweepFlag()

    private final class SweepFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var swept = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if swept { return false }
            swept = true
            return true
        }
    }

    /// Remove the `xctest-worker-<pid>` leaves whose process is gone.
    ///
    /// Seven workers a gate, dozens of gates a day, each leaving a key blob and
    /// a state file under Application Support forever (the whole-branch review's
    /// M2). The isolation is right and stays — what was missing is anyone
    /// clearing up after it.
    ///
    /// Only ever a `xctest-worker-<pid>` LEAF, never the bare production path
    /// beside them, and never a leaf whose pid is still alive: another worker of
    /// this same gate is running out of one.
    ///
    /// `isAlive` is injected so the decision is testable without spawning a
    /// process. Production asks the kernel: `kill(pid, 0)` fails with `ESRCH`
    /// exactly when no such process exists (`EPERM` means it exists and is
    /// somebody else's, which is still alive).
    static func sweepDeadWorkerLeaves(
        in base: URL,
        isAlive: (Int32) -> Bool = { pid in kill(pid, 0) == 0 || errno != ESRCH }
    ) {
        let prefix = "xctest-worker-"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { return }
        for name in names {
            guard name.hasPrefix(prefix),
                  let pid = Int32(name.dropFirst(prefix.count)),
                  !isAlive(pid)
            else { continue }
            try? fm.removeItem(at: base.appendingPathComponent(name))
        }
    }
}
