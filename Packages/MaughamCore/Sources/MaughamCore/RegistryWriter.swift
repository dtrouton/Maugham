import Foundation

/// The one production writer of `.maugham/devices/`, `.maugham/people/` and
/// `.maugham/people/claims/` — and the one place those three paths are spelled.
///
/// It exists as a single door for one reason: **every record is signed**. A
/// record written any other way is a record no reader can vouch for, and the
/// reader's honest answer to one is to list it as malformed and ignore it — so
/// an unsigned write is a silent way to lose a device's whole history to the
/// pending state. A device with no key writes NOTHING here (spec §2, and
/// `DeviceIdentityError.unsigned` is a first-class condition, never a trap).
/// The writer's own refusal: an identity that is not the one the record names.
/// Separate from `DeviceIdentityError.unsigned`, which is a fact about the
/// DEVICE rather than about this record.
public enum RegistryWriteError: Error, Equatable {
    case wrongSigner(expected: String, found: String)
}

public enum RegistryWriter {

    /// The registry's directories, relative to the project root. The single
    /// source of truth for the three paths.
    nonisolated public static func directoryURL(
        _ directory: RegistryDirectory, in projectURL: URL
    ) -> URL {
        switch directory {
        case .devices:
            return projectURL.appendingPathComponent(".maugham/devices", isDirectory: true)
        case .people:
            return projectURL.appendingPathComponent(".maugham/people", isDirectory: true)
        case .claims:
            return projectURL
                .appendingPathComponent(".maugham/people", isDirectory: true)
                .appendingPathComponent("claims", isDirectory: true)
        }
    }

    /// Where a record with this fingerprint lives.
    nonisolated public static func url(
        _ directory: RegistryDirectory, fingerprint: String, in projectURL: URL
    ) -> URL {
        directoryURL(directory, in: projectURL)
            .appendingPathComponent("\(fingerprint).json")
    }

    /// Sign `record` with `identity` and write it, replacing any earlier record
    /// with the same fingerprint (a device re-signs its own record whenever it
    /// mints an actor key; a root re-signs a person record to revoke them).
    ///
    /// **The identity must be the one the record names** — its own `device`, the
    /// root it says admitted it, the new root of a claim. A caller handing the
    /// wrong actor's identity would otherwise write a perfectly valid file that
    /// every reader lists as malformed, and a device un-admitted that way is
    /// un-admitted silently. `RegistryWriteError.wrongSigner` says so at the
    /// door instead; `writeUnchecked` is the test-only way past it.
    ///
    /// Throws `DeviceIdentityError.unsigned` on a device with no key. Both
    /// refusals happen before anything is created, so a refusing path leaves no
    /// directory behind.
    @discardableResult
    nonisolated public static func write(
        _ record: some RegistryRecordProtocol,
        signedBy identity: DeviceIdentity,
        in projectURL: URL,
        presenter: NSFilePresenter? = nil
    ) throws -> URL {
        guard identity.fingerprint == record.expectedSigner else {
            throw RegistryWriteError.wrongSigner(
                expected: record.expectedSigner, found: identity.fingerprint)
        }
        return try writeUnchecked(
            record, signedBy: identity, in: projectURL, presenter: presenter)
    }

    /// `write` without the signer check — the door a TEST uses to plant the
    /// records the reader has to refuse (a person admitted by an impostor, a
    /// device record signed by another device). `internal`, so nothing outside
    /// `@testable import MaughamCore` can reach it, and production has one door.
    @discardableResult
    nonisolated static func writeUnchecked(
        _ record: some RegistryRecordProtocol,
        signedBy identity: DeviceIdentity,
        in projectURL: URL,
        presenter: NSFilePresenter? = nil
    ) throws -> URL {
        var signed = record
        signed.sig = nil
        let credentials = try OpLogChain.credentials(
            signing: try RegistryCanonical.digestHex(ofRecord: signed), identity: identity)
        signed.sig = credentials

        let url = url(type(of: record).directory,
                      fingerprint: record.fingerprint, in: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let bytes = try RegistryCanonical.bytes(of: signed)
        try writeCoordinated(bytes, to: url, presenter: presenter)
        return url
    }

    /// A coordinated atomic write — the store's own idiom, so a record landing
    /// while iCloud is reading the folder is a whole file or the old one, never
    /// half of either.
    nonisolated internal static func writeCoordinated(
        _ bytes: Data, to url: URL, presenter: NSFilePresenter?
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { target in
            do { try bytes.write(to: target, options: .atomic) }
            catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}
