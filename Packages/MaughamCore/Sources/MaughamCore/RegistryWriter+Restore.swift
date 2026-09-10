import Foundation

/// The one door for putting a record BACK.
///
/// It is a door of its own because it is the only write here that does not
/// sign: the bytes handed to it were signed when they were first written and
/// verified when they were read, and re-signing them would be this device
/// asserting something about a record another device wrote. So the bytes go
/// down exactly as they came up, by the same coordinated atomic write every
/// other record takes.
///
/// **Why restoring is safe at all.** A signature protects AUTHORSHIP, not
/// existence: anyone with the folder can delete a file, and nothing
/// cryptographic can stop them. Putting a signed record back forges nothing —
/// the very next read verifies it like any other, and a record whose bytes were
/// tampered with in the cache is listed malformed there and contributes
/// nothing. What restoring buys is that a device does not silently lose its own
/// admission to a sync accident or a tidy-up.
extension RegistryWriter {

    /// Write already-signed bytes to the record `fingerprint` names in
    /// `directory`, replacing whatever is there.
    ///
    /// No signing, no re-encoding, no inspection of the bytes: `RegistryReader`
    /// is the one opinion in this app about whether a record is a record, and
    /// it gets to hold that opinion about these bytes the next time it reads
    /// the folder.
    @discardableResult
    nonisolated public static func restore(
        rawBytes: Data,
        to directory: RegistryDirectory,
        fingerprint: String,
        in projectURL: URL,
        presenter: NSFilePresenter? = nil
    ) throws -> URL {
        let url = url(directory, fingerprint: fingerprint, in: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeCoordinated(rawBytes, to: url, presenter: presenter)
        return url
    }
}
