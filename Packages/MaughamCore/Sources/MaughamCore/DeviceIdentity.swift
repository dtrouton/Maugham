import CryptoKit
import Foundation
import os

/// Diagnostic channel for the one failure the writer must never feel: no key
/// and no token could be written, so this launch's device id is not stable.
/// Mirrors `Deriver.swift`'s `deriverLog`.
private let deviceLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.core",
    category: "DeviceIdentity")

public enum DeviceIdentityError: Error, Equatable {
    /// `sign` was called on a device that has no key — the enclave was
    /// unavailable, so this device writes unsigned ops.
    case unsigned
}

/// This device, as the op log will name it: an id, a key fingerprint, and
/// (where an enclave exists) the ability to sign.
///
/// **The app persists the key itself.** `SecureEnclave.P256.Signing.PrivateKey`
/// hands back a `dataRepresentation` — an enclave-wrapped blob that is useless
/// on any other machine — which we write as a plain file under
/// `DeviceState.directory`. That is the whole storage story: no keychain item,
/// no `kSecAttrIsPermanent`, no entitlement. The spike (§7, 2026-09-07)
/// measured both halves: minting and reloading work from an entitlement-less
/// binary, while `SecKeyCreateRandomKey` with `kSecAttrIsPermanent` does not
/// and must never be used here.
///
/// **Unsigned is a first-class state, not a failure.** Where there is no
/// enclave — a VM, CI's runner, an Intel Mac — the device still needs a stable
/// name, so it mints 32 random bytes once, persists them, and takes its
/// fingerprint from their SHA-256. Everything downstream reads `canSign` and
/// carries on; nothing here ever traps.
///
/// The signing key is held inside a closure rather than as a stored property so
/// an enclave key and the test signer produce the SAME type — no protocol, no
/// generic parameter, and no way for a caller to tell which one it holds beyond
/// asking `canSign`.
public struct DeviceIdentity: Sendable {
    /// 16 hex characters — the fingerprint's own prefix, so an id and a
    /// fingerprint can never disagree about which device they name.
    public let deviceId: String

    /// 64 hex characters: SHA-256 of the public key (or of the token, unsigned).
    public let fingerprint: String

    /// `nil` on a device with no enclave — this device writes unsigned ops.
    public let publicKey: P256.Signing.PublicKey?

    private let signer: @Sendable (Data) throws -> Data

    /// The filename-safe partition slug (tripwire 24). Derived, never stored.
    public var slug: DeviceSlug { DeviceSlug.make(from: deviceId) }

    public var canSign: Bool { publicKey != nil }

    private init(
        fingerprint: String,
        publicKey: P256.Signing.PublicKey?,
        signer: @escaping @Sendable (Data) throws -> Data
    ) {
        self.fingerprint = fingerprint
        self.deviceId = String(fingerprint.prefix(16))
        self.publicKey = publicKey
        self.signer = signer
    }

    /// Sign a 32-byte digest, answering the 64-byte **raw** representation of
    /// the P256 signature (`r || s`) — the form the op log stores and
    /// `P256.Signing.ECDSASignature(rawRepresentation:)` reads back.
    ///
    /// Throws `.unsigned` when this device has no key. That is a condition the
    /// caller decides about, never a trap here.
    public func sign(_ digest: Data) throws -> Data {
        guard canSign else { throw DeviceIdentityError.unsigned }
        return try signer(digest)
    }

    // MARK: - Fingerprints

    /// SHA-256 hex over the key's X9.63 representation. The one place a device
    /// fingerprint is derived from a public key, so a P2 certificate names a
    /// device by the same string this identity answers.
    public static func fingerprint(of publicKey: P256.Signing.PublicKey) -> String {
        hex(SHA256.hash(data: publicKey.x963Representation))
    }

    /// The unsigned twin of the above: SHA-256 hex over the persisted token.
    /// Lives here so both derivations are in one file and can never drift.
    static func fingerprint(ofToken token: Data) -> String {
        hex(SHA256.hash(data: token))
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Construction

    static func signed(
        publicKey: P256.Signing.PublicKey,
        signer: @escaping @Sendable (Data) throws -> Data
    ) -> DeviceIdentity {
        DeviceIdentity(
            fingerprint: fingerprint(of: publicKey),
            publicKey: publicKey,
            signer: signer)
    }

    static func unsigned(token: Data) -> DeviceIdentity {
        DeviceIdentity(
            fingerprint: fingerprint(ofToken: token),
            publicKey: nil,
            signer: { _ in throw DeviceIdentityError.unsigned })
    }

    // MARK: - Loading

    static let blobFilename = "device-key.blob"
    static let tokenFilename = "device-token"
    private static let tokenByteCount = 32

    /// Read this device's identity out of `directory`, minting it on first run.
    ///
    /// The order is: an existing blob (reload it); no blob and an enclave (mint
    /// one, persist it); anything else (the token). A blob that will not load
    /// on THIS enclave — a restored Mac, a cloned disk — is renamed aside
    /// rather than deleted: a new key would be a new device anyway (spec §4.8),
    /// and the old file is history worth keeping.
    public static func load(from directory: URL) throws -> DeviceIdentity {
        try DeviceState.ensureDirectory(directory)
        let fm = FileManager.default
        let blobURL = directory.appendingPathComponent(blobFilename)

        if fm.fileExists(atPath: blobURL.path) {
            if let identity = enclaveIdentity(fromBlobAt: blobURL) { return identity }
            setAside(blobURL)
        } else if SecureEnclave.isAvailable {
            if let identity = mintEnclaveIdentity(writingTo: blobURL) { return identity }
        }

        return try tokenIdentity(in: directory)
    }

    /// The process-wide identity. Falls back to an in-memory token if even that
    /// cannot be written — the writer keeps typing; only the id stops being
    /// stable across launches, and the log says so.
    public static let current: DeviceIdentity = {
        do {
            return try load(from: DeviceState.directory)
        } catch {
            deviceLog.error("""
                Could not persist a device identity at \
                \(DeviceState.directory.path, privacy: .public): \
                \(String(describing: error), privacy: .public). \
                Using an in-memory token — this launch's device id is not stable.
                """)
            return unsigned(token: randomToken())
        }
    }()

    // MARK: - The enclave path

    private static func enclaveIdentity(fromBlobAt url: URL) -> DeviceIdentity? {
        let blob = try? Data(contentsOf: url)  // adr-0018-ok: this device's own key blob
        guard let blob,
              let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        else { return nil }
        return identity(for: key)
    }

    private static func mintEnclaveIdentity(writingTo url: URL) -> DeviceIdentity? {
        // No access-control flags (the spike's A1 shape): the blob is already
        // useless off this device's enclave, and a biometric/passcode gate would
        // put a prompt between the writer and their own autosave.
        guard let key = try? SecureEnclave.P256.Signing.PrivateKey() else { return nil }
        do {
            try key.dataRepresentation.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return identity(for: key)
    }

    /// The enclave key is captured by the signing closure and never stored on
    /// the struct — that is what lets one type stand for both signers.
    private static func identity(for key: SecureEnclave.P256.Signing.PrivateKey) -> DeviceIdentity {
        signed(publicKey: key.publicKey) { digest in
            try key.signature(for: digest).rawRepresentation
        }
    }

    private static func setAside(_ url: URL) {
        // Fractional seconds so a second failure in the same second gets its own
        // name rather than colliding and leaving the bad blob in place.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).unloadable-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    // MARK: - The token path

    private static func tokenIdentity(in directory: URL) throws -> DeviceIdentity {
        let url = directory.appendingPathComponent(tokenFilename)
        let stored = try? Data(contentsOf: url)  // adr-0018-ok: this device's own random token
        if let stored, stored.count == tokenByteCount {
            return unsigned(token: stored)
        }
        let token = randomToken()
        try token.write(to: url, options: .atomic)
        return unsigned(token: token)
    }

    private static func randomToken() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}
