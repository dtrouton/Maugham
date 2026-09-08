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

/// One of this device's writers, as the op log will name it: an actor, an id,
/// a key fingerprint, and (where an enclave exists) the ability to sign.
///
/// A device holds one of these per `DeviceActor` — four keys under one
/// `device/` folder, each minted on first ask. `LocalIdentities` is all four
/// in one value.
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
    /// Which of this device's four writers this identity is (`DeviceActor`).
    /// A device holds one key per actor, so the role is proved by the
    /// signature rather than asserted by a field beside it.
    public let actor: DeviceActor

    /// `<actor>-<16 hex>` — the actor's name and the fingerprint's own prefix,
    /// so an id, a fingerprint and a role can never disagree about who wrote
    /// an op. The author's id carries its prefix too, so a per-device file
    /// reads as itself.
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
        actor: DeviceActor,
        fingerprint: String,
        publicKey: P256.Signing.PublicKey?,
        signer: @escaping @Sendable (Data) throws -> Data
    ) {
        self.actor = actor
        self.fingerprint = fingerprint
        self.deviceId = "\(actor.rawValue)-\(fingerprint.prefix(16))"
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

    private static func hex(_ digest: SHA256Digest) -> String { Hex.encode(digest) }

    // MARK: - Construction

    static func signed(
        actor: DeviceActor,
        publicKey: P256.Signing.PublicKey,
        signer: @escaping @Sendable (Data) throws -> Data
    ) -> DeviceIdentity {
        DeviceIdentity(
            actor: actor,
            fingerprint: fingerprint(of: publicKey),
            publicKey: publicKey,
            signer: signer)
    }

    static func unsigned(actor: DeviceActor, token: Data) -> DeviceIdentity {
        DeviceIdentity(
            actor: actor,
            fingerprint: fingerprint(ofToken: token),
            publicKey: nil,
            signer: { _ in throw DeviceIdentityError.unsigned })
    }

    // MARK: - Loading

    /// The author keeps the names P1 shipped; the other three suffix theirs,
    /// so one `device/` folder holds four keys that cannot be confused and a
    /// device that has only ever been the author looks exactly as it did.
    static func blobFilename(for actor: DeviceActor) -> String {
        actor == .author ? "device-key.blob" : "device-key.\(actor.rawValue).blob"
    }

    static func tokenFilename(for actor: DeviceActor) -> String {
        actor == .author ? "device-token" : "device-token.\(actor.rawValue)"
    }

    private static let tokenByteCount = 32

    /// Read this device's identity out of `directory`, minting it on first run.
    ///
    /// The order is: an existing blob (reload it); an enclave (mint one,
    /// persist it); anything else (the token). A blob that will not load on
    /// THIS enclave — a restored Mac, a cloned disk — is renamed aside rather
    /// than deleted: a new key would be a new device anyway (spec §4.8), and
    /// the old file is history worth keeping.
    ///
    /// **A set-aside blob is followed by a fresh MINT, not by the token** (the
    /// whole-branch review's M1). Both paths give this Mac a new device id, so
    /// re-minting costs nothing extra — and falling to the token instead would
    /// cost the machine its ability to sign anything, permanently, for the rest
    /// of its life, over one restore.
    public static func load(from directory: URL, actor: DeviceActor) throws -> DeviceIdentity {
        try DeviceState.ensureDirectory(directory)
        let fm = FileManager.default
        let blobURL = directory.appendingPathComponent(blobFilename(for: actor))

        if fm.fileExists(atPath: blobURL.path) {
            if let identity = enclaveIdentity(actor: actor, fromBlobAt: blobURL) { return identity }
            setAside(blobURL)
        }
        if SecureEnclave.isAvailable,
           let identity = mintEnclaveIdentity(actor: actor, writingTo: blobURL) {
            return identity
        }

        return try tokenIdentity(actor: actor, in: directory)
    }

    /// The process-wide identity for one actor, minted on first ask and
    /// remembered for the life of the process.
    ///
    /// **Lazy per actor, never eager.** Four `static let`s would mint four
    /// enclave keys the first time anything read any of them — and the phone is
    /// the `author` and nothing else (constraint 7), so three of those four
    /// would be work the writer waits for, for nothing. The cache is
    /// lock-guarded rather than four stored properties for exactly that reason.
    ///
    /// Falls back to an in-memory token if even that cannot be written — the
    /// writer keeps typing; only the id stops being stable across launches, and
    /// the log says so.
    public static func identity(for actor: DeviceActor) -> DeviceIdentity {
        identityCache.identity(for: actor) { actor in
            identity(for: actor, in: DeviceState.directory)
        }
    }

    /// `identity(for:)` over a directory of the caller's choosing, and its
    /// whole body — the process path is this plus the memo. Unmemoized, so a
    /// test directory never poisons the cache the app reads.
    static func identity(for actor: DeviceActor, in directory: URL) -> DeviceIdentity {
        do {
            return try load(from: directory, actor: actor)
        } catch {
            deviceLog.error("""
                Could not persist a device identity for \
                \(actor.rawValue, privacy: .public) at \
                \(directory.path, privacy: .public): \
                \(String(describing: error), privacy: .public). \
                Using an in-memory token — this launch's device id is not stable.
                """)
            return unsigned(actor: actor, token: randomToken())
        }
    }

    /// Does this device already hold a key for `actor` — WITHOUT minting one?
    ///
    /// The question every read path asks, and the reason it cannot be answered
    /// by calling `identity(for:)`: that call mints. What counts as holding a
    /// key is either persisted file (the enclave blob or the unsigned token),
    /// or an identity this process has already resolved — which covers the one
    /// case with nothing on disk, the in-memory token above.
    public static func hasPersistedIdentity(for actor: DeviceActor) -> Bool {
        if identityCache.holds(actor) { return true }
        guard hasPersistedIdentity(for: actor, in: DeviceState.directory) else {
            return false
        }
        identityCache.markExisting(actor)
        return true
    }

    /// The disk half, over a given directory. A key file is never removed in
    /// production (a blob that will not load is set aside and immediately
    /// re-minted), so the process may remember a `true` and never re-stat —
    /// which is what keeps this off the cost of every append.
    static func hasPersistedIdentity(for actor: DeviceActor, in directory: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(
            atPath: directory.appendingPathComponent(blobFilename(for: actor)).path)
            || fm.fileExists(
                atPath: directory.appendingPathComponent(tokenFilename(for: actor)).path)
    }

    /// The writer's own identity — this device's default, and the phone's only
    /// one. `OpLogDeviceState` takes its fingerprint as the DEVICE's.
    public static var author: DeviceIdentity { identity(for: .author) }

    private static let identityCache = IdentityCache()

    /// Memoization for `identity(for:)`. A class behind a lock rather than a
    /// `static var` dictionary, so it is `Sendable` under Swift 6 without
    /// making the mutable state global.
    private final class IdentityCache: @unchecked Sendable {
        private let lock = NSLock()
        private var identities: [DeviceActor: DeviceIdentity] = [:]

        /// Actors known to have a key, whether or not this process resolved
        /// one. Positive only: existence never goes away, and a `false` is
        /// re-checked because an actor can be named at any time.
        private var existing: Set<DeviceActor> = []

        func identity(
            for actor: DeviceActor,
            mint: (DeviceActor) -> DeviceIdentity
        ) -> DeviceIdentity {
            lock.lock()
            defer { lock.unlock() }
            if let held = identities[actor] { return held }
            let minted = mint(actor)
            identities[actor] = minted
            existing.insert(actor)
            return minted
        }

        func holds(_ actor: DeviceActor) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return existing.contains(actor)
        }

        func markExisting(_ actor: DeviceActor) {
            lock.lock(); defer { lock.unlock() }
            existing.insert(actor)
        }
    }

    // MARK: - The enclave path

    private static func enclaveIdentity(
        actor: DeviceActor, fromBlobAt url: URL
    ) -> DeviceIdentity? {
        let blob = try? Data(contentsOf: url)  // adr-0018-ok: this device's own key blob
        guard let blob,
              let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        else { return nil }
        return identity(actor: actor, for: key)
    }

    private static func mintEnclaveIdentity(
        actor: DeviceActor, writingTo url: URL
    ) -> DeviceIdentity? {
        // No access-control flags (the spike's A1 shape): the blob is already
        // useless off this device's enclave, and a biometric/passcode gate would
        // put a prompt between the writer and their own autosave.
        guard let key = try? SecureEnclave.P256.Signing.PrivateKey() else { return nil }
        do {
            try key.dataRepresentation.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return identity(actor: actor, for: key)
    }

    /// The enclave key is captured by the signing closure and never stored on
    /// the struct — that is what lets one type stand for both signers.
    private static func identity(
        actor: DeviceActor, for key: SecureEnclave.P256.Signing.PrivateKey
    ) -> DeviceIdentity {
        signed(actor: actor, publicKey: key.publicKey) { digest in
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

    private static func tokenIdentity(
        actor: DeviceActor, in directory: URL
    ) throws -> DeviceIdentity {
        let url = directory.appendingPathComponent(tokenFilename(for: actor))
        let stored = try? Data(contentsOf: url)  // adr-0018-ok: this device's own random token
        if let stored, stored.count == tokenByteCount {
            return unsigned(actor: actor, token: stored)
        }
        let token = randomToken()
        try token.write(to: url, options: .atomic)
        return unsigned(actor: actor, token: token)
    }

    private static func randomToken() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}
