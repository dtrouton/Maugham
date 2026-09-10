import CryptoKit
import Foundation

/// The bytes a registry record's signature is made over, and the digest of
/// them. One spelling, used by the writer when it signs and by the reader when
/// it verifies, so the two can never disagree about what was signed.
///
/// **Sorted keys and the store's own date encoding.** Sorted, because a
/// dictionary's insertion order is not a fact about the record and two devices
/// must produce the same bytes for the same record (`actors` is a dictionary).
/// The store's date encoding, because every other date this app writes to disk
/// is written that way, and a date that changed shape between the encoder that
/// signed it and the one that wrote the file would produce a record whose
/// signature verified nowhere.
///
/// **`sig` is excluded by being absent.** The signature slot is an Optional the
/// encoder omits when nil (`encodeIfPresent`, which the synthesised `Codable`
/// conformance uses for an optional property), so the canonical form is the
/// record as it was before it was signed. Verification nils the slot and
/// re-encodes; the bytes come back identical.
public enum RegistryCanonical {

    /// The canonical encoder: sorted keys, the store's ISO8601 dates.
    nonisolated public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<PersonRecord>.dateEncoding
        return encoder
    }

    /// Its inverse — the one decoder every registry read goes through.
    nonisolated public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = JSONLAppendStore<PersonRecord>.dateDecoding
        return decoder
    }

    /// The canonical bytes of anything encodable.
    nonisolated public static func bytes(of value: some Encodable) throws -> Data {
        try encoder().encode(value)
    }

    /// SHA-256 over those bytes. Pass a record whose `sig` is nil — or use
    /// `digestHex(ofRecord:)`, which guarantees it.
    nonisolated public static func digest(of value: some Encodable) throws -> Data {
        Data(SHA256.hash(data: try bytes(of: value)))
    }

    /// The hex digest a signature is made over: the record with its signature
    /// slot emptied first, so signing and verifying cannot ask different
    /// questions. Hex, because that is the form
    /// `OpLogChain.credentials(signing:identity:)` and `credentialsVerify` take.
    nonisolated public static func digestHex(
        ofRecord record: some RegistryRecordProtocol
    ) throws -> String {
        var unsigned = record
        unsigned.sig = nil
        return Hex.encode(try digest(of: unsigned))
    }
}
