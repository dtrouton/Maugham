import CryptoKit
import Foundation

/// Bytes that are not a JSON object are not a record, and cannot be
/// canonicalized into one. Named rather than answered with empty bytes: a
/// digest over something arbitrary would verify nowhere and say nothing about
/// why.
public enum RegistryCanonicalError: Error, Equatable {
    case notAJSONObject
}

/// The bytes a registry record's signature is made over, and the digest of
/// them. One spelling, used by the writer when it signs and by the reader when
/// it verifies, so the two can never disagree about what was signed.
///
/// **The canonical form is over the JSON OBJECT, not over a re-encode of a
/// decoded record** (P2b Task 1, amending P2a). A record written by a later
/// build carries a field this one has no property for. A digest taken over
/// what this build *decoded* would drop that field, and the record would fail
/// to verify on every older device that read it — a silent, permanent
/// un-admission the moment anybody upgrades, and the exact shape spec §2 exists
/// to forbid. So `canonicalBytes(ofJSON:)` parses the bytes that are there,
/// removes the signature slot by name, and re-serializes: an unknown field is
/// part of the object, so it is part of what was signed, and this build passes
/// it through without ever having a name for it.
///
/// **Sorted keys.** A dictionary's insertion order is not a fact about the
/// record, and two devices must produce the same bytes for the same record
/// (`actors` is a dictionary).
///
/// **Slashes are not escaped.** JSON permits `/` and `\/` for the same
/// character, so a canonicalization that did not decide would give two devices
/// two digests for one record — and a device name or a label may hold a slash.
/// `withoutEscapingSlashes` is the pinned choice, made in the encoder that
/// writes the file and in the canonicalization that hashes it, so the bytes on
/// disk and the bytes that were signed differ in the signature alone. Pinned by
/// `RegistryRecordTests.test_theCanonicalFormLeavesAForwardSlashUnescaped`.
///
/// **The store's own date encoding**, because every other date this app writes
/// to disk is written that way — and dates are already ISO STRINGS in the JSON,
/// so the canonical path never reformats one. It moves strings.
///
/// **`sig` is excluded by name**, not by being absent: the file being verified
/// carries its signature, and removing the key is what makes signing and
/// verifying ask the same question of it.
public enum RegistryCanonical {

    /// The canonical encoder: sorted keys, unescaped slashes, the store's
    /// ISO8601 dates. What writes a record's file.
    nonisolated public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = JSONLAppendStore<PersonRecord>.dateEncoding
        return encoder
    }

    /// Its inverse — the one decoder every registry read goes through.
    nonisolated public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = JSONLAppendStore<PersonRecord>.dateDecoding
        return decoder
    }

    /// The file bytes of anything encodable: what `RegistryWriter` lays down.
    /// Not itself the signed form — `canonicalBytes(ofJSON:)` is.
    nonisolated public static func bytes(of value: some Encodable) throws -> Data {
        try encoder().encode(value)
    }

    /// **The one canonicalization.** A record's JSON object, minus its
    /// signature slot, with sorted keys and unescaped slashes.
    ///
    /// It takes BYTES rather than a record because that is the whole point: on
    /// the way in it is handed the file, so nothing the file carries is lost on
    /// the way to the digest.
    nonisolated public static func canonicalBytes(ofJSON bytes: Data) throws -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        else { throw RegistryCanonicalError.notAJSONObject }
        object.removeValue(forKey: "sig")
        return try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The hex digest a signature is made over, from a record's own file bytes.
    /// Hex, because that is the form `OpLogChain.credentials(signing:identity:)`
    /// and `credentialsVerify` take.
    nonisolated public static func digestHex(ofJSON bytes: Data) throws -> String {
        Hex.encode(Data(SHA256.hash(data: try canonicalBytes(ofJSON: bytes))))
    }

    /// **A record's file bytes, edited and re-signed** — the canonicalization's
    /// own answer to *change one field and sign what is actually there*.
    ///
    /// It lives here rather than in the writer because everything it does is
    /// this type's decision: which bytes a signature covers, what the signature
    /// slot is called, and how an object becomes a file. A second spelling of
    /// any of the three, anywhere, is a second opinion about what was signed —
    /// and it fails in the direction that costs a device its admission rather
    /// than the direction that shouts (`RegistryCanonicalCensusTests`).
    ///
    /// The edit is handed the OBJECT the file holds, not a decoded record, so a
    /// field a later build wrote survives into the digest and into the file.
    /// The signing is a closure because the identity belongs to the writer:
    /// this function decides what is signed, never who signs.
    nonisolated public static func resigned(
        fileBytes: Data,
        editing edit: (inout [String: Any]) throws -> Void,
        signing sign: (_ digestHex: String) throws -> OpLogChain.Credentials
    ) throws -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: fileBytes))
                as? [String: Any] else { throw RegistryCanonicalError.notAJSONObject }
        try edit(&object)
        // Removed by name, exactly as `canonicalBytes` removes it: the digest
        // is over the record WITHOUT its signature slot, and the signature the
        // file arrived with is not what the new one is made over.
        object.removeValue(forKey: "sig")
        // The digest is taken by the function the READER will use on this very
        // file, over the bytes that are about to be in it — not by a hash
        // spelled here that happens to agree today.
        let credentials = try sign(try digestHex(ofJSON: try serialize(object)))
        // The credentials' own wire form, asked of the encoder rather than
        // spelled as three keys: a hand-written `sig` is a record no reader can
        // verify, written by the one type whose job is that they can.
        object["sig"] = try JSONSerialization.jsonObject(with: try bytes(of: credentials))
        return try serialize(object)
    }

    /// The one serialization of a record's object: sorted keys, unescaped
    /// slashes — `canonicalBytes`' own two choices, so the file a re-sign
    /// writes and the bytes its signature covers differ in the signature alone.
    nonisolated private static func serialize(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// One date, in the form every registry record already writes: the store's
    /// own ISO8601 string.
    ///
    /// It exists for the RE-SIGN path, which edits a record's JSON OBJECT
    /// rather than a decoded copy (`RegistryWriter.resign`) and so needs the
    /// string a `Date` would have become had the encoder written it. Made BY
    /// that encoder — a second formatter here would be a second answer to what
    /// a date looks like on disk, and the two would diverge at exactly the
    /// fractional second nobody looks at.
    nonisolated public static func dateString(_ date: Date) throws -> String {
        let encoded = try encoder().encode([date])
        let decoded = (try? JSONSerialization.jsonObject(with: encoded)) as? [String]
        guard let string = decoded?.first else {
            throw RegistryCanonicalError.notAJSONObject
        }
        return string
    }

    /// The same digest for a record in hand — the writer's side of it. The
    /// record is encoded once and then canonicalized, so the writer signs
    /// exactly what the reader will hash out of the file it is about to write.
    ///
    /// The signature slot needs no emptying: `canonicalBytes` removes it.
    nonisolated public static func digestHex(
        ofRecord record: some RegistryRecordProtocol
    ) throws -> String {
        try digestHex(ofJSON: try bytes(of: record))
    }
}
