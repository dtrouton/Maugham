import CryptoKit
import Foundation
import XCTest
@testable import MaughamCore

/// The three record shapes and the canonical bytes every signature is made
/// over. Pure: no file, no clock, no store.
///
/// The field names are the spec's (§2.1–2.3) and are asserted against JSON
/// literals rather than against the encoder's own output, because a record is
/// read by other devices — a renamed field is a wire-format change, and a
/// round-trip test through our own encoder cannot see one.
final class RegistryRecordTests: XCTestCase {

    // MARK: - The shapes (spec §2.1–2.3)

    func test_theDeviceRecordReadsTheSpecsFields() throws {
        let json = """
        {"actors":{"assistant":"bbbb","author":"aaaa"},"device":"aaaa",\
        "kind":"mac","madeAt":"2026-09-09T10:00:00.000Z","name":"Denver's MacBook"}
        """
        let record = try RegistryCanonical.decoder().decode(
            DeviceRecord.self, from: Data(json.utf8))

        XCTAssertEqual(record.device, "aaaa")
        XCTAssertEqual(record.name, "Denver's MacBook")
        XCTAssertEqual(record.kind, .mac)
        XCTAssertEqual(record.actors, ["author": "aaaa", "assistant": "bbbb"])
        XCTAssertNil(record.retiredAt, "a live device carries no retirement")
        XCTAssertNil(record.sig, "this literal is the unsigned form")
        XCTAssertEqual(record.fingerprint, record.device,
                       "the device's own fingerprint is what names its file")
    }

    /// An unrecognised kind survives a read AND a re-encode. A device record is
    /// re-signed by its own device when an actor key is minted (spec §2.1), so
    /// a kind this build does not know must not be silently rewritten into one
    /// it does — that would invalidate the signature of a record we merely
    /// passed through (ADR 0015's lossless rule).
    func test_anUnknownDeviceKindIsCarriedThroughLosslessly() throws {
        let json = """
        {"actors":{"author":"aaaa"},"device":"aaaa","kind":"watch",\
        "madeAt":"2026-09-09T10:00:00.000Z","name":"Something later"}
        """
        let record = try RegistryCanonical.decoder().decode(
            DeviceRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.kind, .unknown("watch"))

        let bytes = try RegistryCanonical.bytes(of: record)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), json)
    }

    func test_thePersonRecordReadsTheSpecsFields() throws {
        let json = """
        {"admittedAt":"2026-09-09T10:00:00.000Z","admittedBy":"root1",\
        "label":"Denver","ownName":"Denver's iPhone","person":"p1","role":"author"}
        """
        let record = try RegistryCanonical.decoder().decode(
            PersonRecord.self, from: Data(json.utf8))

        XCTAssertEqual(record.person, "p1")
        XCTAssertEqual(record.label, "Denver")
        XCTAssertEqual(record.ownName, "Denver's iPhone")
        XCTAssertEqual(record.role, "author", "written for everyone, read by nothing until P3")
        XCTAssertEqual(record.admittedBy, "root1")
        XCTAssertNil(record.revokedAt)
        XCTAssertNil(record.revokedBy)
        XCTAssertNil(record.highestOpIdSeen)
        XCTAssertEqual(record.fingerprint, record.person)
    }

    func test_aRootIsThePersonWhoAdmittedThemselves() {
        let root = PersonRecord(
            person: "r", label: "Denver", ownName: "Denver's MacBook",
            admittedAt: .distantPast, admittedBy: "r")
        let admitted = PersonRecord(
            person: "p", label: "Denver", ownName: "Denver's iPhone",
            admittedAt: .distantPast, admittedBy: "r")

        XCTAssertTrue(root.isRoot)
        XCTAssertFalse(admitted.isRoot)
    }

    func test_theClaimRecordReadsTheSpecsFields() throws {
        let json = """
        {"adopted":["old1","old2"],"claimedAt":"2026-09-09T10:00:00.000Z","newRoot":"new1"}
        """
        let record = try RegistryCanonical.decoder().decode(
            ClaimRecord.self, from: Data(json.utf8))

        XCTAssertEqual(record.newRoot, "new1")
        XCTAssertEqual(record.adopted, ["old1", "old2"])
        XCTAssertEqual(record.fingerprint, record.newRoot)
    }

    // MARK: - Canonical bytes

    /// Sorted keys, so the bytes a signature covers do not depend on the order
    /// a dictionary happened to be built in. Two dictionaries with the same
    /// pairs in opposite insertion order must encode identically, or a device
    /// record's `actors` map would sign differently on two machines.
    func test_canonicalBytesAreStableAcrossFieldOrder() throws {
        var first: [String: String] = [:]
        first["author"] = "aaaa"
        first["translator"] = "cccc"
        first["assistant"] = "bbbb"
        var second: [String: String] = [:]
        second["assistant"] = "bbbb"
        second["translator"] = "cccc"
        second["author"] = "aaaa"

        XCTAssertEqual(try RegistryCanonical.bytes(of: first),
                       try RegistryCanonical.bytes(of: second))
        XCTAssertEqual(
            String(decoding: try RegistryCanonical.bytes(of: first), as: UTF8.self),
            #"{"assistant":"bbbb","author":"aaaa","translator":"cccc"}"#)
    }

    /// The digest is over the record WITHOUT its signature, so signing does not
    /// change what was signed.
    func test_theDigestIgnoresTheSignatureItself() throws {
        let unsigned = PersonRecord(
            person: "p", label: "Denver", ownName: "iPhone",
            admittedAt: Date(timeIntervalSince1970: 1), admittedBy: "r")
        var signed = unsigned
        signed.sig = OpLogChain.Credentials(key: "k", pub: "p", sig: "s")

        XCTAssertEqual(try RegistryCanonical.digestHex(ofRecord: unsigned),
                       try RegistryCanonical.digestHex(ofRecord: signed))
        XCTAssertFalse(
            String(decoding: try RegistryCanonical.bytes(of: unsigned), as: UTF8.self)
                .contains("sig"),
            "an absent signature is omitted, not written as null")
    }

    func test_theDigestMovesWithEveryFieldTheRecordCarries() throws {
        let base = PersonRecord(
            person: "p", label: "Denver", ownName: "iPhone",
            admittedAt: Date(timeIntervalSince1970: 1), admittedBy: "r")
        let relabelled = PersonRecord(
            person: "p", label: "Someone else", ownName: "iPhone",
            admittedAt: Date(timeIntervalSince1970: 1), admittedBy: "r")

        XCTAssertNotEqual(try RegistryCanonical.digestHex(ofRecord: base),
                          try RegistryCanonical.digestHex(ofRecord: relabelled))
    }

    /// The digest is SHA-256 over exactly those bytes — spelled out once, so a
    /// later reader of another language could recompute it.
    func test_theDigestIsSha256OverTheCanonicalBytes() throws {
        let record = ClaimRecord(
            newRoot: "new", adopted: ["old"], claimedAt: Date(timeIntervalSince1970: 0))
        let bytes = try RegistryCanonical.bytes(of: record)

        XCTAssertEqual(try RegistryCanonical.digest(of: record),
                       Data(SHA256.hash(data: bytes)))
    }

    /// A date's precision must survive the encode → decode → encode trip, or a
    /// signature made before the write would not verify after the read.
    func test_aRecordsDateRoundTripsToTheSameBytes() throws {
        let record = ClaimRecord(newRoot: "new", adopted: [], claimedAt: Date())
        let bytes = try RegistryCanonical.bytes(of: record)
        let back = try RegistryCanonical.decoder().decode(ClaimRecord.self, from: bytes)

        XCTAssertEqual(try RegistryCanonical.bytes(of: back), bytes)
    }
}
