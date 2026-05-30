import Foundation

/// Mints and persists a stable per-install device identifier for the phone.
///
/// The op-log / inbox `deviceId` convention is `phone:<uuid>` (spec §3.9), the
/// counterpart to the Mac's hostname identity. We persist a single UUID per
/// install in `UserDefaults` so every capture from this device partitions to the
/// same per-device JSONL stream (`DeviceSlug.make` is deterministic over this
/// string), and so reinstalling — not relaunching — is what changes identity.
enum PhoneDeviceID {
    private static let defaultsKey = "maughamPhoneDeviceId"

    /// The stable id for this install, minting + persisting a `phone:<uuid>` on
    /// first use. `defaults` is injectable so tests can isolate persistence.
    static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let minted = "phone:\(UUID().uuidString)"
        defaults.set(minted, forKey: defaultsKey)
        return minted
    }
}
