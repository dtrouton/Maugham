import Foundation

/// A record on disk that this device cannot vouch for, and why.
///
/// It is **listed, never read**. A malformed record contributes nothing to the
/// registry — no person, no device, no claim — because the alternative is to
/// let anybody who can write the folder decide who is admitted. It is carried
/// out of the read so Integrity can show it (spec §6): a record silently
/// dropped is a trust decision nobody made.
public struct MalformedRecord: Equatable, Hashable, Sendable {
    public enum Reason: Equatable, Hashable, Sendable {
        /// The bytes are not a record of the shape this directory holds.
        case undecodable(String)
        /// A record with no signature at all is not a record (spec §2).
        case unsigned
        /// The file was renamed: its name is not the fingerprint it carries.
        /// The payload is the fingerprint the RECORD holds — the name on disk
        /// is the `url` beside it.
        case filenameMismatch(recordFingerprint: String)
        /// The signature does not hold together over these bytes — a flipped
        /// byte, or a record edited after it was signed.
        case signatureDoesNotVerify
        /// A valid signature, from the wrong key: not the device's own author
        /// key, not the root the record names.
        case signerIsNotTheExpectedKey(expected: String, found: String)
        /// A person admitted by someone who is not a root of this registry.
        /// Anybody can sign; only a root can admit.
        case signerIsNotARoot(named: String)
        /// A device record whose `actors["author"]` is not the device itself
        /// (`nil` when it lists no author at all). The author key's fingerprint
        /// IS the device's identity, so a record naming another key there asks
        /// a reader to trust an actor the signer never vouched for as itself —
        /// and admitting a device admits every actor its record lists (spec
        /// §4.4), which is what makes this worth refusing rather than ignoring.
        case authorActorIsNotTheDevice(named: String?)
        /// A record for a fingerprint this device already verified, signed by
        /// a DIFFERENT key than the one that signed the copy it remembers.
        ///
        /// Not a fault in the file — it is a well-formed record on its own
        /// terms, which is precisely the danger. A person record's expected
        /// signer is the root it NAMES, so another root can write a valid
        /// admission of somebody this device already knows and, on the folder's
        /// word alone, take over their record and the whole chain hanging off
        /// it. A record changes hands only under the same key; anything else is
        /// a claim, and a claim is listed (`RegistryCache.reconcile`, spec §2.4
        /// P4, B1).
        case signerChanged(expected: String, found: String)

        /// One sentence a surface can print.
        public var sentence: String {
            switch self {
            case .undecodable(let underlying):
                return "isn't a record Maugham can read (\(underlying))"
            case .unsigned:
                return "carries no signature, so nothing vouches for it"
            case .filenameMismatch(let recordFingerprint):
                return "was renamed — it carries the fingerprint \(recordFingerprint)"
            case .signatureDoesNotVerify:
                return "was changed after it was signed"
            case .signerIsNotTheExpectedKey(let expected, let found):
                return "was signed by \(found), not by \(expected)"
            case .signerIsNotARoot(let named):
                return "was signed by \(named), who admits nobody here"
            case .authorActorIsNotTheDevice(let named):
                return named.map { "names \($0) as its own author key, which is another device" }
                    ?? "names no author key of its own"
            case .signerChanged(let expected, let found):
                return "is now signed by \(found), where this device verified \(expected)"
            }
        }
    }

    public let url: URL
    public let reason: Reason

    public init(url: URL, reason: Reason) {
        self.url = url
        self.reason = reason
    }

    /// Which record this FILE stands in the place of — where it sits and what
    /// it is named — or nil when it is not in one of the registry's three
    /// directories at all.
    ///
    /// The one thing a malformed listing still says for certain is that a file
    /// is THERE. `RegistryCache.reconcile` asks it for exactly that: a record
    /// it remembers and the folder no longer verifies must be left alone,
    /// because a device cannot tell *tampered with* from *written by a later
    /// build*, and restoring over it would silently downgrade a newer device's
    /// signed record. Only an ABSENT file is restored.
    ///
    /// Named by the FILE rather than by what the bytes claim: a renamed record
    /// (`.filenameMismatch`) occupies the name on disk, and the fingerprint it
    /// carries has no file of its own.
    ///
    /// The directory is read off the path rather than re-spelled: the three
    /// `RegistryDirectory` cases are named exactly as their folders are, so
    /// this asks the same enum `RegistryWriter.directoryURL` builds from and
    /// cannot become a second opinion about where a record lives.
    public var ref: RecordRef? {
        guard let directory = RegistryDirectory(
            rawValue: url.deletingLastPathComponent().lastPathComponent)
        else { return nil }
        return RecordRef(
            directory: directory,
            fingerprint: url.deletingPathExtension().lastPathComponent)
    }
}

extension MalformedRecord {

    /// The listing for a record whose file is PRESENT and whose signature holds
    /// — but under a key other than the one that signed the copy this device
    /// verified (`RegistryCache.reconcile`, spec §2.4 P4).
    ///
    /// It is minted here rather than at the point that decides it, because
    /// naming a record's file is `RegistryWriter`'s one spelling and this is the
    /// file that may ask for it (tripwire 40). The cache decides WHETHER; where
    /// the file is stays one answer.
    nonisolated static func signerChanged(
        _ ref: RecordRef, expected: String, found: String, in projectURL: URL
    ) -> MalformedRecord {
        MalformedRecord(
            url: RegistryWriter.url(
                ref.directory, fingerprint: ref.fingerprint, in: projectURL),
            reason: .signerChanged(expected: expected, found: found))
    }
}

/// Everything a project's registry says, once every signature has been checked:
/// the devices, the people, the claims — and, separately, what could not be
/// vouched for.
///
/// It holds FACTS, not trust. Which root is this device's, who is pending and
/// who is revoked are `TrustTable`'s questions; this value is what it asks them
/// of.
public struct Registry: Equatable, Sendable {
    public let devices: [DeviceRecord]
    public let people: [PersonRecord]
    public let claims: [ClaimRecord]
    public let malformed: [MalformedRecord]
    /// Each verified record's own bytes as they were on disk, by ref.
    ///
    /// Present because a record is not always something this build can write
    /// back: one from a later build carries a field it has no property for, and
    /// re-encoding it would rewrite another build's record into this one's
    /// vocabulary and break the signature it was passing through. The bytes are
    /// what was signed, so they are what a memory of this registry keeps
    /// (`RegistryCache`) and what a restore puts down.
    ///
    /// Empty on a registry built in memory rather than read from disk; a caller
    /// that finds no entry falls back to encoding the record it holds.
    public let sourceBytes: [RecordRef: Data]

    public init(
        devices: [DeviceRecord] = [], people: [PersonRecord] = [],
        claims: [ClaimRecord] = [], malformed: [MalformedRecord] = [],
        sourceBytes: [RecordRef: Data] = [:]
    ) {
        self.devices = devices
        self.people = people
        self.claims = claims
        self.malformed = malformed
        self.sourceBytes = sourceBytes
    }

    /// The self-signed person records: everyone who admitted themselves. More
    /// than one means more than one claimant — they are listed, never merged
    /// (decision B1).
    public var roots: [PersonRecord] { people.filter(\.isRoot) }

    /// Every person admitted under this root, transitively, the root included.
    ///
    /// A revoked person is still IN the chain: revocation is a state of a
    /// member, not an absence, and the distinction is what lets the reader say
    /// *after revocation* about a late-arriving op instead of *a stranger's*.
    public func chain(under root: PersonRecord) -> Set<String> {
        chain(underRoot: root.person)
    }

    /// The same answer from a fingerprint, for a caller holding one. An
    /// unknown fingerprint has an empty chain — it is nobody's root here.
    public func chain(underRoot fingerprint: String) -> Set<String> {
        guard people.contains(where: { $0.person == fingerprint && $0.isRoot })
        else { return [] }

        var reached: Set<String> = [fingerprint]
        var frontier: [String] = [fingerprint]
        while let admitter = frontier.popLast() {
            for person in people
            where person.admittedBy == admitter && !person.isRoot {
                if reached.insert(person.person).inserted {
                    frontier.append(person.person)
                }
            }
        }
        return reached
    }

    /// Every key fingerprint that belongs to this device — its author key and
    /// each actor its record lists. Admitting a device admits all of them,
    /// because they ARE that device (spec §4.4); a device with no record has
    /// none we can vouch for.
    public func actorFingerprints(ofDevice fingerprint: String) -> Set<String> {
        guard let record = devices.first(where: { $0.device == fingerprint })
        else { return [] }
        return record.actorFingerprints
    }

    /// The device record naming this key among its actors, if any — how a seal
    /// finds the device it was written on.
    public func device(withActorFingerprint fingerprint: String) -> DeviceRecord? {
        devices.first { $0.actorFingerprints.contains(fingerprint) }
    }

    /// The person record for a fingerprint, if this registry holds one.
    public func person(_ fingerprint: String) -> PersonRecord? {
        people.first { $0.person == fingerprint }
    }
}

/// The one reader of the registry's three directories.
///
/// **What it refuses and what it merely lists.** A file it cannot verify is
/// listed in `Registry.malformed` and contributes nothing — the read carries
/// on, because one bad file must not cost a project its people. A file that is
/// PRESENT but cannot be READ throws (RULING-54): a permissions error or a
/// half-downloaded iCloud file would otherwise silently shrink the registry,
/// and a registry that shrinks silently is admission decided by accident.
public enum RegistryReader {

    nonisolated public static func load(
        projectURL: URL, presenter: NSFilePresenter? = nil
    ) throws -> Registry {
        var malformed: [MalformedRecord] = []
        // Every verified record's own file bytes, carried out with it. What
        // was signed and what a memory of this registry must restore are the
        // same bytes, and neither is anything this build could re-encode.
        var sourceBytes: [RecordRef: Data] = [:]
        func keep(_ record: some RegistryRecordProtocol, _ bytes: Data) {
            sourceBytes[RecordRef(directory: type(of: record).directory,
                                  fingerprint: record.fingerprint)] = bytes
        }

        // Devices vouch for themselves: each is signed by its own author key.
        var devices: [DeviceRecord] = []
        for url in try files(in: .devices, projectURL: projectURL) {
            let record: DeviceRecord
            let bytes: Data
            switch try decode(DeviceRecord.self, at: url, presenter: presenter) {
            case .malformed(let fault): malformed.append(fault); continue
            case .record(let decoded, let read): record = decoded; bytes = read
            }
            if let fault = verify(record, bytes: bytes, at: url) {
                malformed.append(fault); continue
            }
            devices.append(record)
            keep(record, bytes)
        }

        // People are read in two passes, because a non-root record is only a
        // record if a ROOT signed it — and which fingerprints are roots is not
        // known until every self-signed record has been verified.
        var candidates: [(url: URL, record: PersonRecord, bytes: Data)] = []
        for url in try files(in: .people, projectURL: projectURL) {
            switch try decode(PersonRecord.self, at: url, presenter: presenter) {
            case .malformed(let fault): malformed.append(fault)
            case .record(let decoded, let bytes): candidates.append((url, decoded, bytes))
            }
        }
        var people: [PersonRecord] = []
        var rootFingerprints: Set<String> = []
        for (url, record, bytes) in candidates where record.isRoot {
            if let fault = verify(record, bytes: bytes, at: url) {
                malformed.append(fault); continue
            }
            people.append(record)
            keep(record, bytes)
            rootFingerprints.insert(record.person)
        }
        for (url, record, bytes) in candidates where !record.isRoot {
            if let fault = verify(record, bytes: bytes, at: url) {
                malformed.append(fault); continue
            }
            guard rootFingerprints.contains(record.admittedBy) else {
                malformed.append(.init(
                    url: url, reason: .signerIsNotARoot(named: record.admittedBy)))
                continue
            }
            people.append(record)
            keep(record, bytes)
        }

        var claims: [ClaimRecord] = []
        for url in try files(in: .claims, projectURL: projectURL) {
            let record: ClaimRecord
            let bytes: Data
            switch try decode(ClaimRecord.self, at: url, presenter: presenter) {
            case .malformed(let fault): malformed.append(fault); continue
            case .record(let decoded, let read): record = decoded; bytes = read
            }
            if let fault = verify(record, bytes: bytes, at: url) {
                malformed.append(fault); continue
            }
            claims.append(record)
            keep(record, bytes)
        }

        return Registry(
            devices: devices.sorted { $0.device < $1.device },
            people: people.sorted { $0.person < $1.person },
            claims: claims.sorted { $0.newRoot < $1.newRoot },
            malformed: malformed.sorted { $0.url.path < $1.url.path },
            sourceBytes: sourceBytes)
    }

    // MARK: - One record

    /// The three checks every record answers on its own terms: it is named by
    /// the fingerprint it carries, it is signed, and the signature holds
    /// together over these exact bytes — the FILE's, canonicalized — under the
    /// key the record's own shape expects. Whether that key is TRUSTED is not
    /// asked here.
    nonisolated private static func verify(
        _ record: some RegistryRecordProtocol, bytes: Data, at url: URL
    ) -> MalformedRecord? {
        let named = url.deletingPathExtension().lastPathComponent
        guard named == record.fingerprint else {
            return .init(url: url,
                         reason: .filenameMismatch(recordFingerprint: record.fingerprint))
        }
        guard let credentials = record.sig else {
            return .init(url: url, reason: .unsigned)
        }
        // Over the FILE's bytes, never over a re-encode of what was decoded: a
        // record from a later build carries a field this one has no property
        // for, and hashing this build's vocabulary of it would refuse an honest
        // record (P2b Task 1).
        guard let digest = try? RegistryCanonical.digestHex(ofJSON: bytes),
              OpLogChain.credentialsVerify(credentials, over: digest) else {
            return .init(url: url, reason: .signatureDoesNotVerify)
        }
        guard credentials.key == record.expectedSigner else {
            return .init(url: url, reason: .signerIsNotTheExpectedKey(
                expected: record.expectedSigner, found: credentials.key))
        }
        // A device is the one record that vouches for OTHER keys, and the
        // author entry is the one it cannot be wrong about: it is the key that
        // just signed. A record listing another device there would have a
        // reader trust actors on the strength of a signature that never
        // claimed them.
        if let device = record as? DeviceRecord,
           device.actors[DeviceActor.author.rawValue] != device.device {
            return .init(url: url, reason: .authorActorIsNotTheDevice(
                named: device.actors[DeviceActor.author.rawValue]))
        }
        return nil
    }

    /// Bytes → record, or the malformed listing that replaces it.
    ///
    /// The READ throws out of here rather than becoming a malformed listing:
    /// a file that cannot be read is not a file that says something wrong, and
    /// treating one as the other is exactly how a permissions error would
    /// quietly un-admit a device (RULING-54).
    nonisolated private static func decode<R: RegistryRecordProtocol>(
        _ type: R.Type, at url: URL, presenter: NSFilePresenter?
    ) throws -> Decoded<R> {
        let bytes = try readCoordinated(url: url, presenter: presenter)
        do {
            return .record(try RegistryCanonical.decoder().decode(R.self, from: bytes),
                           bytes: bytes)
        } catch {
            return .malformed(.init(url: url, reason: .undecodable(shortReason(error))))
        }
    }

    /// A record — **with the bytes it was read from** — or the listing that
    /// stands in for it. Not a `Result`, because a malformed record is not an
    /// error: it is a fact the registry carries.
    ///
    /// The bytes travel with the record for two reasons and both are about
    /// losing nothing. The signature is checked over them, so a field this
    /// build has no property for is still part of what was signed; and they are
    /// what `RegistryCache` remembers, so a record this build could not
    /// re-encode faithfully is still restored faithfully.
    private enum Decoded<R: RegistryRecordProtocol> {
        case record(R, bytes: Data)
        case malformed(MalformedRecord)
    }

    nonisolated private static func shortReason(_ error: Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _): return "no “\(key.stringValue)”"
        case .typeMismatch, .valueNotFound: return "a field is the wrong shape"
        case .dataCorrupted: return "the bytes aren't JSON"
        default: return error.localizedDescription
        }
    }

    // MARK: - Files

    /// The `.json` files in one registry directory, by name. An absent
    /// directory is not a failure (there is no registry yet); a directory that
    /// EXISTS and cannot be listed is, for RULING-54's reason.
    ///
    /// Skips by NAME only (`DotfileScan`) — the BSD hidden flag is not a fact
    /// about a file under `.maugham/` — and skips directories, which is how
    /// `people/claims/` survives being inside `people/`.
    nonisolated private static func files(
        in directory: RegistryDirectory, projectURL: URL
    ) throws -> [URL] {
        let dir = RegistryWriter.directoryURL(directory, in: projectURL)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        } catch {
            throw OpLogStore.ReadError.unreadableFile(
                name: dir.lastPathComponent, underlying: error.localizedDescription,
                kind: .registry)
        }
        return entries
            .filter { !DotfileScan.isDotfile($0) }
            .filter { $0.pathExtension == "json" }
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The coordinated read of one record's exact bytes. A present-but-
    /// unreadable file throws, by name — the op log's own rule and its own
    /// error, so the writer meets one sentence for one condition wherever
    /// Maugham reads a file it must not read only half of.
    nonisolated private static func readCoordinated(
        url: URL, presenter: NSFilePresenter?
    ) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var readError: Error?
        var bytes: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            do { bytes = try Data(contentsOf: target) }  // adr-0018-ok: a signed registry record, never manuscript text
            catch { readError = error }
        }
        return try resolveRead(
            bytes: bytes, coordinationError: coordinationError,
            readError: readError, name: url.lastPathComponent)
    }

    /// What the coordinator's outcomes mean, as a decision with no file in it.
    ///
    /// Three of them, not two. The third — no bytes, no error, because the
    /// block never ran — is the one worth naming: answering it with empty bytes
    /// would make the record read as MALFORMED, and a device silently
    /// un-admitted by an accident is exactly the shape RULING-54 exists to
    /// forbid. A file that is there is read whole or refused by name.
    nonisolated static func resolveRead(
        bytes: Data?, coordinationError: NSError?, readError: Error?, name: String
    ) throws -> Data {
        if let failure = (coordinationError as Error?) ?? readError {
            throw OpLogStore.ReadError.unreadableFile(
                name: name, underlying: failure.localizedDescription, kind: .registry)
        }
        guard let bytes else {
            throw OpLogStore.ReadError.unreadableFile(
                name: name, underlying: "the read never ran", kind: .registry)
        }
        return bytes
    }
}
