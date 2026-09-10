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

    /// The digest is SHA-256 over exactly the canonical bytes — spelled out
    /// once, so a later reader of another language could recompute it.
    ///
    /// The expectation moved with the lossless digest (P2b Task 1): the bytes
    /// hashed are no longer the encoder's output but that output put through
    /// `canonicalBytes(ofJSON:)`, which is the one form both the writer and the
    /// reader hash. For a record with nothing unknown in it the two spell the
    /// same object; the function named here is the one that is authoritative.
    func test_theDigestIsSha256OverTheCanonicalBytes() throws {
        let record = ClaimRecord(
            newRoot: "new", adopted: ["old"], claimedAt: Date(timeIntervalSince1970: 0))
        let canonical = try RegistryCanonical.canonicalBytes(
            ofJSON: try RegistryCanonical.bytes(of: record))

        XCTAssertEqual(try RegistryCanonical.digestHex(ofRecord: record),
                       Hex.encode(Data(SHA256.hash(data: canonical))))
    }

    // MARK: - The canonical form is lossless (P2b Task 1)

    /// **The canonicalization is over the JSON OBJECT, not over a re-encode of
    /// a decoded record.** A record written by a later build carries a field
    /// this one has no property for; a digest taken over what this build
    /// decoded would drop it, and the record would fail to verify on every
    /// older device that read it — a silent, permanent un-admission the moment
    /// anybody upgrades. So the bytes that were signed are the bytes that are
    /// there, minus the signature slot.
    func test_aFieldThisBuildDoesNotKnowSurvivesIntoTheDigest() throws {
        let plain = Data(#"{"adopted":[],"claimedAt":"1970-01-01T00:00:00.000Z","newRoot":"n"}"#.utf8)
        let later = Data(#"{"adopted":[],"claimedAt":"1970-01-01T00:00:00.000Z","future":1,"newRoot":"n"}"#.utf8)

        XCTAssertNotEqual(try RegistryCanonical.digestHex(ofJSON: plain),
                          try RegistryCanonical.digestHex(ofJSON: later),
                          "the unknown field is part of what was signed")

        let decoded = try RegistryCanonical.decoder().decode(ClaimRecord.self, from: later)
        XCTAssertEqual(decoded.newRoot, "n", "and this build still reads what it knows")
        XCTAssertNotEqual(try RegistryCanonical.digestHex(ofRecord: decoded),
                          try RegistryCanonical.digestHex(ofJSON: later),
                          "a digest over the DECODED record is exactly the one that loses it")
    }

    /// The signature slot is removed by name, so signing and verifying ask the
    /// same question of a file that already carries one.
    func test_theCanonicalFormDropsTheSignatureSlotAndSortsTheKeys() throws {
        let signed = Data(#"{"newRoot":"n","sig":{"key":"k","pub":"p","sig":"s"},"adopted":[],"claimedAt":"1970-01-01T00:00:00.000Z"}"#.utf8)

        XCTAssertEqual(
            String(decoding: try RegistryCanonical.canonicalBytes(ofJSON: signed), as: UTF8.self),
            #"{"adopted":[],"claimedAt":"1970-01-01T00:00:00.000Z","newRoot":"n"}"#)
    }

    /// Two spellings of the same object — different key order, whitespace —
    /// canonicalize to one byte string. Two devices writing the same record
    /// must sign the same bytes.
    func test_theCanonicalFormIsTheSameForTwoSpellingsOfTheSameObject() throws {
        let one = Data(#"{"b":2,"a":"x","c":[1,2]}"#.utf8)
        let other = Data("""
            {
              "c" : [1, 2],
              "a" : "x",
              "b" : 2
            }
            """.utf8)

        XCTAssertEqual(try RegistryCanonical.canonicalBytes(ofJSON: one),
                       try RegistryCanonical.canonicalBytes(ofJSON: other))
    }

    /// **The pinned escaping choice: a forward slash is written as itself.**
    /// JSON permits `/` and `\/` for the same character, so a canonicalization
    /// that did not decide would give two devices two digests for one record —
    /// and a label or a device name may hold a slash. `withoutEscapingSlashes`
    /// is the choice, on both sides of the write, and it is the form a writer
    /// reading the file sees.
    func test_theCanonicalFormLeavesAForwardSlashUnescaped() throws {
        let json = Data(#"{"name":"Denver/spare"}"#.utf8)

        XCTAssertEqual(
            String(decoding: try RegistryCanonical.canonicalBytes(ofJSON: json), as: UTF8.self),
            #"{"name":"Denver/spare"}"#)

        // And the file the writer lays down is spelled the same way, so the
        // bytes on disk and the bytes that were signed differ in the signature
        // alone.
        let record = DeviceRecord(
            device: "aaaa", name: "Denver/spare", kind: .mac,
            actors: ["author": "aaaa"], madeAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(
            String(decoding: try RegistryCanonical.bytes(of: record), as: UTF8.self)
                .contains("Denver/spare"),
            "the encoder makes the same choice the canonical form does")
    }

    /// Anything that is not a JSON object is not a record, and says so rather
    /// than hashing something arbitrary.
    func test_bytesThatAreNotAJsonObjectCannotBeCanonicalized() {
        XCTAssertThrowsError(
            try RegistryCanonical.canonicalBytes(ofJSON: Data("[1,2,3]".utf8)))
        XCTAssertThrowsError(
            try RegistryCanonical.canonicalBytes(ofJSON: Data("not json".utf8)))
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
