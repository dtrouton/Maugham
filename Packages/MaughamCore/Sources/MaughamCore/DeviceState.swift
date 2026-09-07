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
        return base.appendingPathComponent(
            "xctest-worker-\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// Create `url` and every parent it needs. Idempotent.
    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
