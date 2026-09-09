import CryptoKit
import Foundation
import XCTest
@testable import MaughamCore

/// `OpLogChain` — the wire format and the verifier. Every test here is the spec
/// of the walk: bytes in, a classification per line out, no I/O and no clock.
///
/// The identities are the software signer (`DeviceIdentity.softwareForTesting`)
/// because CI's runner has no enclave and the sign/verify contract is the same
/// either way — constraint 2 of the plan.
final class OpLogChainTests: XCTestCase {

    private let at = Date(timeIntervalSince1970: 1_757_000_000)

    // MARK: - Fixtures

    /// One element of a manuscript op log, near enough: a sorted-keys JSON
    /// object on one line, exactly what `JSONLAppendStore.encode` produces.
    private func element(_ i: Int, text: String = "x") -> Data {
        Data("{\"opId\":\"op-\(i)\",\"text\":\"\(text)\"}".utf8)
    }

    private func joined(_ lines: [Data]) -> Data {
        var out = Data()
        for line in lines {
            out.append(line)
            out.append(0x0A)
        }
        return out
    }

    /// Builds a file the way the writer will: a legacy prefix has no `prev`, a
    /// chained line carries the previous line's hash, a seal signs the head.
    private struct Builder {
        var lines: [Data] = []
        var head: String?

        /// A line as an older Maugham wrote it — no `prev` key at all.
        mutating func legacy(_ line: Data) {
            lines.append(line)
            head = OpLogChain.lineHash(line)
        }

        /// A chained line, exactly as the writer will build one: `prev` is the
        /// running head, or the genesis sentinel when this is the first line.
        mutating func chained(_ elementJSON: Data) {
            let line = OpLogChain.chainedLine(
                elementJSON: elementJSON, prev: head ?? OpLogChain.genesis)
            lines.append(line)
            head = OpLogChain.lineHash(line)
        }

        mutating func seal(_ identity: DeviceIdentity, at: Date, over: String? = nil) throws {
            let line = try OpLogChain.Seal.line(head: over ?? head!, identity: identity, at: at)
            lines.append(line)
            head = OpLogChain.lineHash(line)
        }
    }

    private func trusting(_ identity: DeviceIdentity) -> (String) -> Bool {
        { $0 == identity.fingerprint }
    }

    private func states(_ verification: OpLogChain.Verification) -> [OpLogChain.Line.State] {
        verification.lines.map(\.state)
    }

    // MARK: - lineHash

    func test_lineHashIgnoresExactlyOneTrailingNewline() {
        let line = Data("{\"a\":1}".utf8)
        var once = line
        once.append(0x0A)
        var twice = once
        twice.append(0x0A)

        XCTAssertEqual(OpLogChain.lineHash(once), OpLogChain.lineHash(line),
                       "one trailing newline is the file's separator, not the line's content")
        XCTAssertNotEqual(OpLogChain.lineHash(twice), OpLogChain.lineHash(line),
                          "a SECOND newline is content and must change the hash")
        XCTAssertEqual(OpLogChain.lineHash(line).count, 64)
    }

    // MARK: - chainedLine / prev

    func test_chainedLineRoundTripsThroughPrev() {
        let head = OpLogChain.lineHash(element(0))
        let line = OpLogChain.chainedLine(elementJSON: element(1), prev: head)

        XCTAssertEqual(OpLogChain.prev(ofLine: line), .some(.some(head)))
        XCTAssertTrue(String(data: line, encoding: .utf8)!.hasPrefix("{\"prev\":\"\(head)\","),
                      "the format fixes prev as the first key")
        XCTAssertFalse(line.contains(0x0A), "a chained line carries no newline of its own")
    }

    func test_chainedLineWithNoPrevIsTheElementUnchanged() {
        let json = element(7)
        XCTAssertEqual(OpLogChain.chainedLine(elementJSON: json, prev: nil), json)
        XCTAssertEqual(OpLogChain.prev(ofLine: json), .some(nil))
    }

    func test_prevAnswersOuterNilForSomethingThatIsNotAnObject() {
        XCTAssertEqual(OpLogChain.prev(ofLine: Data("not json at all".utf8)), .none)
        XCTAssertEqual(OpLogChain.prev(ofLine: Data("[1,2]".utf8)), .none)
        XCTAssertEqual(OpLogChain.prev(ofLine: Data()), .none)
    }

    func test_prevAnswersInnerNilWhenTheFirstKeyIsNotPrev() {
        // A legacy line whose object HAPPENS to carry a prev later on is still
        // unchained: the format fixes the position, and only the first key counts.
        let line = Data("{\"opId\":\"a\",\"prev\":\"deadbeef\"}".utf8)
        XCTAssertEqual(OpLogChain.prev(ofLine: line), .some(nil))
        XCTAssertEqual(OpLogChain.prev(ofLine: Data("{}".utf8)), .some(nil))
    }

    // MARK: - Seal lines

    func test_aSealLineIsRecognisedByItsPrefixAndRoundTrips() throws {
        let identity = DeviceIdentity.softwareForTesting()
        let head = OpLogChain.lineHash(element(0))
        let line = try OpLogChain.Seal.line(head: head, identity: identity, at: at)

        XCTAssertTrue(OpLogChain.isSealLine(line))
        XCTAssertFalse(OpLogChain.isSealLine(element(0)))
        XCTAssertTrue(String(data: line, encoding: .utf8)!.hasPrefix("{\"seal\":{\"at\":"),
                      "one top-level key, sorted keys")

        let seal = try XCTUnwrap(OpLogChain.Seal.parse(line))
        XCTAssertEqual(seal.head, head)
        XCTAssertEqual(seal.key, identity.fingerprint)
        XCTAssertEqual(seal.at.timeIntervalSince1970, at.timeIntervalSince1970, accuracy: 0.001,
                       "the seal's date uses the store's own strategy, so it round-trips")
        XCTAssertTrue(seal.verifies())
    }

    func test_aSealFromADeviceThatCannotSignThrows() {
        let unsigned = DeviceIdentity.unsignedForTesting(token: Data(repeating: 7, count: 32))
        XCTAssertThrowsError(
            try OpLogChain.Seal.line(head: OpLogChain.lineHash(element(0)), identity: unsigned, at: at)
        ) { error in
            XCTAssertEqual(error as? DeviceIdentityError, .unsigned)
        }
    }

    func test_aSealDoesNotVerifyForAnotherDevicesHead() throws {
        let identity = DeviceIdentity.softwareForTesting()
        let line = try OpLogChain.Seal.line(
            head: OpLogChain.lineHash(element(0)), identity: identity, at: at)
        let seal = try XCTUnwrap(OpLogChain.Seal.parse(line))
        let forged = OpLogChain.Seal(
            at: seal.at, head: OpLogChain.lineHash(element(1)),
            key: seal.key, pub: seal.pub, sig: seal.sig)
        XCTAssertFalse(forged.verifies(), "the signature is over the head's own bytes")
    }

    // MARK: - The walk

    func test_aLegacyOnlyFileIsAllLegacyWithAHead() {
        var b = Builder()
        b.legacy(element(0))
        b.legacy(element(1))
        b.legacy(element(2))

        let v = OpLogChain.verify(bytes: joined(b.lines), trusted: { _ in true }, rememberedHead: nil)

        XCTAssertEqual(states(v), [.legacy, .legacy, .legacy])
        XCTAssertEqual(v.legacyCount, 3)
        XCTAssertEqual(v.head, b.head)
        XCTAssertNil(v.breakReason)
        XCTAssertTrue(v.quarantined.isEmpty)
    }

    func test_legacyThenChainedThenATrustedSealVerifiesTheChainedSpan() throws {
        let identity = DeviceIdentity.softwareForTesting()
        var b = Builder()
        b.legacy(element(0))
        b.legacy(element(1))
        b.chained(element(2))
        b.chained(element(3))
        try b.seal(identity, at: at)

        let v = OpLogChain.verify(
            bytes: joined(b.lines), trusted: trusting(identity), rememberedHead: nil)

        XCTAssertEqual(states(v), [.legacy, .legacy, .verified, .verified, .verified])
        XCTAssertEqual(v.legacyCount, 2)
        XCTAssertEqual(v.verifiedCount, 3, "the two chained lines and the seal that covers them")
        XCTAssertEqual(v.unsealedCount, 0)
        XCTAssertEqual(v.foreignSealCount, 0)
        XCTAssertNil(v.breakReason)
        XCTAssertEqual(v.head, b.head)
    }

    func test_anUntrustedSealMakesItsSpanUnsignedHistory() throws {
        let identity = DeviceIdentity.softwareForTesting()
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))
        try b.seal(identity, at: at)

        let v = OpLogChain.verify(bytes: joined(b.lines), trusted: { _ in false }, rememberedHead: nil)

        XCTAssertEqual(states(v), [.legacy, .unsignedHistory, .unsignedHistory])
        XCTAssertEqual(v.verifiedCount, 0)
        XCTAssertEqual(v.foreignSealCount, 1, "a seal whose key this device does not trust")
        XCTAssertNil(v.breakReason, "a foreign seal is history, not a break")
    }

    func test_linesAfterTheLastSealAreUnsealed() throws {
        let identity = DeviceIdentity.softwareForTesting()
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))
        try b.seal(identity, at: at)
        b.chained(element(2))
        b.chained(element(3))

        let v = OpLogChain.verify(
            bytes: joined(b.lines), trusted: trusting(identity), rememberedHead: nil)

        XCTAssertEqual(states(v), [.legacy, .verified, .verified, .unsealed, .unsealed])
        XCTAssertEqual(v.unsealedCount, 2)
        XCTAssertNil(v.breakReason)
    }

    func test_blankLinesAreSkippedAndNeverCounted() {
        var b = Builder()
        b.legacy(element(0))
        b.legacy(element(1))

        var bytes = Data()
        bytes.append(0x0A)
        bytes.append(b.lines[0])
        bytes.append(0x0A)
        bytes.append(0x0A)
        bytes.append(b.lines[1])
        bytes.append(0x0A)

        let v = OpLogChain.verify(bytes: bytes, trusted: { _ in true }, rememberedHead: nil)

        XCTAssertEqual(v.lines.count, 2, "a blank line is not a line")
        XCTAssertEqual(v.legacyCount, 2)
        XCTAssertNil(v.breakReason)
        XCTAssertEqual(v.head, b.head)
    }

    /// A fresh file starts at the sentinel, so its first line is chained like
    /// any other and the seal that follows covers it. Nothing reads as legacy.
    func test_aFreshFilesChainStartsAtGenesisAndTheSealCoversItsFirstLine() throws {
        let identity = DeviceIdentity.softwareForTesting()
        var b = Builder()
        b.chained(element(0))
        b.chained(element(1))
        try b.seal(identity, at: at)

        XCTAssertEqual(OpLogChain.prev(ofLine: b.lines[0]), .some(.some(OpLogChain.genesis)))
        XCTAssertEqual(OpLogChain.genesis, OpLogChain.lineHash(Data()),
                       "the sentinel is the hash of no bytes at all")

        let v = OpLogChain.verify(
            bytes: joined(b.lines), trusted: trusting(identity), rememberedHead: nil)

        XCTAssertEqual(states(v), [.verified, .verified, .verified])
        XCTAssertEqual(v.legacyCount, 0)
        XCTAssertEqual(v.verifiedCount, 3)
        XCTAssertNil(v.breakReason)
    }

    /// The shape a pre-P1 file is made of stays legal: a first line with NO
    /// prev is still legacy, and still carries the file to a head.
    func test_aFirstLineWithNoPrevAtAllIsStillLegacy() {
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))

        let v = OpLogChain.verify(bytes: joined(b.lines), trusted: { _ in true }, rememberedHead: nil)

        XCTAssertEqual(states(v), [.legacy, .unsealed])
        XCTAssertEqual(v.legacyCount, 1)
        XCTAssertNil(v.breakReason)
    }

    /// The sentinel means "nothing came before me". A line claiming it after a
    /// line HAS come before is a wrong prev, and breaks like any other.
    func test_genesisAfterALineThatCameBeforeIsAWrongPrev() {
        var b = Builder()
        b.legacy(element(0))
        b.lines.append(OpLogChain.chainedLine(elementJSON: element(1), prev: OpLogChain.genesis))

        let v = OpLogChain.verify(bytes: joined(b.lines), trusted: { _ in true }, rememberedHead: nil)

        XCTAssertEqual(v.breakReason, .prevMismatch(lineIndex: 1))
        XCTAssertEqual(states(v), [.legacy, .quarantined])
    }

    /// A seal must follow at least one line: it names the head it seals, and
    /// before the first line there is no head, not the sentinel.
    func test_aSealAsTheVeryFirstLineIsQuarantined() throws {
        let identity = DeviceIdentity.softwareForTesting()
        let seal = try OpLogChain.Seal.line(head: OpLogChain.genesis, identity: identity, at: at)
        let follower = OpLogChain.chainedLine(
            elementJSON: element(0), prev: OpLogChain.lineHash(seal))

        let v = OpLogChain.verify(
            bytes: joined([seal, follower]), trusted: trusting(identity), rememberedHead: nil)

        XCTAssertEqual(v.breakReason, .sealHeadMismatch(lineIndex: 0))
        XCTAssertEqual(states(v), [.quarantined, .quarantined])
        XCTAssertNil(v.head)
    }

    func test_anEmptyObjectTakesAPrevWithoutAStrayComma() {
        let head = OpLogChain.lineHash(element(0))
        let line = OpLogChain.chainedLine(elementJSON: Data("{}".utf8), prev: head)

        XCTAssertEqual(String(data: line, encoding: .utf8), "{\"prev\":\"\(head)\"}")
        XCTAssertEqual(OpLogChain.prev(ofLine: line), .some(.some(head)))
    }

    func test_anEmptyFileHasNoHeadAndNoLines() {
        let v = OpLogChain.verify(bytes: Data(), trusted: { _ in true }, rememberedHead: nil)

        XCTAssertTrue(v.lines.isEmpty)
        XCTAssertNil(v.head)
        XCTAssertNil(v.breakReason)
    }

    // MARK: - The breaks

    func test_aWrongPrevQuarantinesFromThatLineOn() {
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))
        let liar = OpLogChain.chainedLine(elementJSON: element(2), prev: String(repeating: "a", count: 64))
        b.lines.append(liar)
        b.chained(element(3))  // chains onto the liar, but the walk stopped

        let v = OpLogChain.verify(bytes: joined(b.lines), trusted: { _ in true }, rememberedHead: nil)

        XCTAssertEqual(v.breakReason, .prevMismatch(lineIndex: 2))
        XCTAssertEqual(states(v), [.legacy, .unsealed, .quarantined, .quarantined])
        XCTAssertEqual(v.quarantined, [b.lines[2], b.lines[3]],
                       "the raw bytes, in file order")
        XCTAssertEqual(v.head, OpLogChain.lineHash(b.lines[1]),
                       "the head is the last line that was applied")
    }

    func test_anUnchainedLineAfterTheChainBeganIsQuarantined() {
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))
        b.lines.append(element(2))  // no prev, after the chain began

        let v = OpLogChain.verify(bytes: joined(b.lines), trusted: { _ in true }, rememberedHead: nil)

        XCTAssertEqual(v.breakReason, .unchainedAfterChain(lineIndex: 2))
        XCTAssertEqual(states(v), [.legacy, .unsealed, .quarantined])
        XCTAssertEqual(v.legacyCount, 1, "legacy is a prefix, never a suffix")
    }

    func test_aSealWhoseHeadIsOffByOneLineIsQuarantined() throws {
        let identity = DeviceIdentity.softwareForTesting()
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))
        let stale = OpLogChain.lineHash(b.lines[0])
        try b.seal(identity, at: at, over: stale)

        let v = OpLogChain.verify(
            bytes: joined(b.lines), trusted: trusting(identity), rememberedHead: nil)

        XCTAssertEqual(v.breakReason, .sealHeadMismatch(lineIndex: 2))
        XCTAssertEqual(states(v), [.legacy, .unsealed, .quarantined])
        XCTAssertEqual(v.verifiedCount, 0, "a seal that does not name this head seals nothing")
    }

    func test_aSealWithAFlippedSignatureByteIsQuarantined() throws {
        let identity = DeviceIdentity.softwareForTesting()
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))
        try b.seal(identity, at: at)

        let seal = try XCTUnwrap(OpLogChain.Seal.parse(b.lines[2]))
        var signature = try XCTUnwrap(Data(base64Encoded: seal.sig))
        signature[signature.startIndex + 5] ^= 0x01
        b.lines[2] = replacing(
            "\"sig\":\"\(seal.sig)\"",
            with: "\"sig\":\"\(signature.base64EncodedString())\"",
            in: b.lines[2])

        let v = OpLogChain.verify(
            bytes: joined(b.lines), trusted: trusting(identity), rememberedHead: nil)

        XCTAssertEqual(v.breakReason, .sealSignatureInvalid(lineIndex: 2))
        XCTAssertEqual(states(v), [.legacy, .unsealed, .quarantined])
    }

    func test_aSealWhoseKeyDoesNotMatchItsPublicKeyIsQuarantined() throws {
        let identity = DeviceIdentity.softwareForTesting()
        let other = DeviceIdentity.softwareForTesting()
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))
        try b.seal(identity, at: at)

        b.lines[2] = replacing(
            "\"key\":\"\(identity.fingerprint)\"",
            with: "\"key\":\"\(other.fingerprint)\"",
            in: b.lines[2])

        let v = OpLogChain.verify(bytes: joined(b.lines), trusted: { _ in true }, rememberedHead: nil)

        XCTAssertEqual(v.breakReason, .sealSignatureInvalid(lineIndex: 2),
                       "a seal must name the key it carries — otherwise it claims another device's word")
        XCTAssertEqual(states(v), [.legacy, .unsealed, .quarantined])
    }

    func test_alteringALinesBytesBreaksTheNextLinesPrev() {
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))
        b.chained(element(2))

        // The tamper: line 1's TEXT is rewritten in place, long after it was
        // written. Its own prev still matches; the line after it does not.
        b.lines[1] = replacing("\"text\":\"x\"", with: "\"text\":\"y\"", in: b.lines[1])

        let v = OpLogChain.verify(bytes: joined(b.lines), trusted: { _ in true }, rememberedHead: nil)

        XCTAssertEqual(v.breakReason, .prevMismatch(lineIndex: 2))
        XCTAssertEqual(states(v), [.legacy, .unsealed, .quarantined])
    }

    func test_aSealLineThatDoesNotParseIsQuarantinedAsAnInvalidSignature() {
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))
        // The prefix says seal; the rest is not one. There is no signature to
        // check, which is precisely the point: it does not hold together.
        b.lines.append(Data("{\"seal\":{\"at\":\"nonsense\"}}".utf8))

        let v = OpLogChain.verify(bytes: joined(b.lines), trusted: { _ in true }, rememberedHead: nil)

        XCTAssertEqual(v.breakReason, .sealSignatureInvalid(lineIndex: 2))
        XCTAssertEqual(states(v), [.legacy, .unsealed, .quarantined])
    }

    // MARK: - The remembered head

    func test_aRememberedHeadMidFileQuarantinesTheCorrectlyChainedTail() {
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))
        let remembered = OpLogChain.lineHash(b.lines[1])
        b.chained(element(2))
        b.chained(element(3))

        let v = OpLogChain.verify(
            bytes: joined(b.lines), trusted: { _ in true }, rememberedHead: remembered)

        XCTAssertEqual(v.breakReason, .afterRememberedHead(lineIndex: 2))
        XCTAssertEqual(states(v), [.legacy, .unsealed, .quarantined, .quarantined],
                       "the tail chains perfectly — and this device did not write it")
        XCTAssertEqual(v.quarantined, [b.lines[2], b.lines[3]])
        XCTAssertEqual(v.head, remembered)
    }

    func test_aRememberedHeadAbsentFromTheFileChangesNothing() {
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))
        b.chained(element(2))

        let stranger = String(repeating: "b", count: 64)
        let v = OpLogChain.verify(
            bytes: joined(b.lines), trusted: { _ in true }, rememberedHead: stranger)
        let asIfNil = OpLogChain.verify(
            bytes: joined(b.lines), trusted: { _ in true }, rememberedHead: nil)

        XCTAssertEqual(v, asIfNil, "no line hashes to it, so the walk proceeds as if it were nil")
        XCTAssertNil(v.breakReason)
        XCTAssertEqual(v.head, b.head)
    }

    func test_aRememberedHeadAtTheLastLineBreaksNothing() {
        var b = Builder()
        b.legacy(element(0))
        b.chained(element(1))

        let v = OpLogChain.verify(
            bytes: joined(b.lines), trusted: { _ in true }, rememberedHead: b.head)

        XCTAssertNil(v.breakReason, "the device's own last line is not a stranger's")
        XCTAssertEqual(states(v), [.legacy, .unsealed])
    }

    // MARK: - The property

    /// 200 seeded trials. Two halves: a generated chain verifies whole, and
    /// flipping any one byte of any line but the last quarantines from that
    /// line (or the one after it, whose `prev` no longer matches) on.
    ///
    /// The last line is excluded deliberately: nothing chains onto it, so a
    /// flip there changes a hash no one reads — the file's head moves and no
    /// line breaks. Task 4's remembered head is what catches that case, and
    /// `test_aRememberedHeadMidFileQuarantinesTheCorrectlyChainedTail` pins it.
    func test_property_aChainVerifiesWholeAndAnyFlippedByteQuarantinesFromThere() throws {
        let identity = DeviceIdentity.softwareForTesting()
        let trusted = trusting(identity)
        var rng = SeededGenerator(seed: 0x5EED_0F10_9C06_C4A1)

        for trial in 0..<200 {
            let n = 3 + Int(rng.next() % 10)
            let k = 2 + Int(rng.next() % 3)
            var b = Builder()
            var sinceSeal = 0
            for i in 0..<n {
                b.chained(element(i, text: "t\(rng.next() % 1000)"))
                sinceSeal += 1
                if sinceSeal == k {
                    try b.seal(identity, at: at.addingTimeInterval(Double(i)))
                    sinceSeal = 0
                }
            }
            let lines = b.lines

            let whole = OpLogChain.verify(
                bytes: joined(lines), trusted: trusted, rememberedHead: nil)
            XCTAssertNil(whole.breakReason, "trial \(trial): a generated chain must verify whole")
            XCTAssertTrue(whole.quarantined.isEmpty, "trial \(trial)")
            XCTAssertEqual(whole.head, b.head, "trial \(trial)")
            XCTAssertEqual(whole.legacyCount, 0,
                           "trial \(trial): a fresh file chains from the sentinel, so nothing is legacy")
            XCTAssertFalse(states(whole).contains(.legacy), "trial \(trial)")

            guard lines.count >= 2 else { continue }
            let lineIndex = Int(rng.next() % UInt64(lines.count - 1))
            var flipped = lines
            var line = flipped[lineIndex]
            let byteIndex = Int(rng.next() % UInt64(line.count))
            line[line.index(line.startIndex, offsetBy: byteIndex)] ^= 0x01
            flipped[lineIndex] = line

            let after = OpLogChain.verify(
                bytes: joined(flipped), trusted: trusted, rememberedHead: nil)
            let reason = try XCTUnwrap(
                after.breakReason,
                "trial \(trial): flipping a byte of line \(lineIndex) of \(lines.count) must break the chain")
            let breakIndex = reason.lineIndex
            XCTAssertTrue(breakIndex == lineIndex || breakIndex == lineIndex + 1,
                          "trial \(trial): broke at \(breakIndex), flipped \(lineIndex)")
            XCTAssertEqual(after.quarantined.count, flipped.count - breakIndex, "trial \(trial)")
            for (i, l) in after.lines.enumerated() {
                XCTAssertEqual(l.state == .quarantined, i >= breakIndex,
                               "trial \(trial): line \(i) against a break at \(breakIndex)")
            }
        }
    }

    // MARK: - Reading a line's prev

    /// A 64-hex `prev` written as the first key — the only shape Maugham ever
    /// writes — is read by a byte-level fast path rather than by accumulating
    /// the key and the value a byte at a time. Every other shape falls through
    /// to the textual reader, so the two must agree everywhere.
    ///
    /// The expected values here were CAPTURED from the textual reader before
    /// the fast path existed: this corpus is what pins the refactor as an
    /// equivalence rather than a change of answer.
    func test_prevAnswersWhatTheTextualReaderAnsweredForEveryShape() {
        let hex = String(repeating: "ab", count: 32)
        let corpus: [(name: String, line: String, expected: String??)] = [
            ("the shape Maugham writes", "{\"prev\":\"\(hex)\",\"opId\":\"op-1\"}", .some(.some(hex))),
            ("the same with no second key", "{\"prev\":\"\(hex)\"}", .some(.some(hex))),
            ("a leading space", " {\"prev\":\"\(hex)\"}", .some(.some(hex))),
            ("spaces inside", "{ \"prev\" : \"\(hex)\" }", .some(.some(hex))),
            ("a value that is not 64 long", "{\"prev\":\"short\"}", .some(.some("short"))),
            ("63 hex", "{\"prev\":\"\(String(hex.dropLast()))\"}", .some(.some(String(hex.dropLast())))),
            ("65 hex", "{\"prev\":\"\(hex)c\"}", .some(.some(hex + "c"))),
            ("a short value whose 74th byte happens to be a quote",
             "{\"prev\":\"a\",\"x\":\"\(String(repeating: "a", count: 56))\"", .some(.some("a"))),
            ("unterminated", "{\"prev\":\"\(hex)", .none),
            ("an unquoted value", "{\"prev\":\(hex)}", .none),
            ("a first key that merely starts with prev", "{\"prevx\":\"\(hex)\"}", .some(nil)),
            ("prev as the second key", "{\"a\":1,\"prev\":\"\(hex)\"}", .some(nil)),
            ("an empty object", "{}", .some(nil)),
            ("not an object", "[1]", .none),
            ("no bytes at all", "", .none),
        ]

        for entry in corpus {
            XCTAssertEqual(OpLogChain.prev(ofLine: Data(entry.line.utf8)), entry.expected,
                           "\(entry.name): \(entry.line)")
        }
    }

    /// A `Data` slice does not start at index 0, and a fast path that assumes it
    /// does reads the wrong 64 bytes off every line the walk hands it — which is
    /// exactly how the verifier sees them, as slices of the whole file.
    func test_prevReadsASliceThatDoesNotStartAtZero() {
        let line = OpLogChain.chainedLine(elementJSON: element(1), prev: OpLogChain.genesis)
        var file = Data("nnnn".utf8)
        file.append(line)
        let slice = file.dropFirst(4)

        XCTAssertNotEqual(slice.startIndex, 0, "the fixture is only a fixture if the slice is offset")
        XCTAssertEqual(OpLogChain.prev(ofLine: slice), .some(.some(OpLogChain.genesis)))
    }

    /// A realistic tail's worth of lines, every one of them read back to the
    /// head it was chained on. This used to carry a wall-clock bound as well; it
    /// does not any more. A flaky test is worse than none in this suite
    /// (tripwire 33), the assertion's real protection was thin — a reverted fast
    /// path would have had to be 5× slower than the reader it replaced to trip
    /// it — and speed is measured by the fixtures in
    /// `docs/superpowers/notes/2026-09-09-perf-step-measurements.md`, not here.
    /// What is worth pinning at this size is that the answer stays right when
    /// there are thousands of lines rather than three.
    func test_sixThousandLinesEachReadBackTheHeadTheyWereChainedOn() {
        var heads: [String] = []
        var prev = OpLogChain.genesis
        let lines: [Data] = (0..<6_000).map { index in
            let line = OpLogChain.chainedLine(elementJSON: element(index), prev: prev)
            heads.append(prev)
            prev = OpLogChain.lineHash(line)
            return line
        }

        var read = 0
        for (index, line) in lines.enumerated() {
            XCTAssertEqual(
                OpLogChain.prev(ofLine: line), .some(.some(heads[index])),
                "line \(index) did not read back the head it was chained on")
            read += 1
        }

        XCTAssertEqual(read, 6_000)
    }

    // MARK: - Helpers

    /// Rewrites one substring of a line and answers the new bytes. Used to
    /// forge a seal in place without teaching production a forging verb.
    ///
    /// Both halves go through `escapingSlashes` because the store's encoder is
    /// `[.sortedKeys]` and nothing more, so Foundation writes base64's `/` as
    /// `\/` — the fixture must match the bytes on the wire, not the value.
    private func replacing(_ needle: String, with replacement: String, in line: Data) -> Data {
        let text = String(data: line, encoding: .utf8)!
        let from = escapingSlashes(needle)
        XCTAssertTrue(text.contains(from), "fixture expected \(from) in \(text)")
        return Data(text.replacingOccurrences(of: from, with: escapingSlashes(replacement)).utf8)
    }

    private func escapingSlashes(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "\\/")
    }
}

/// SplitMix64 — a seeded generator so a failing trial is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension OpLogChain.BreakReason {
    /// The index every case carries, for assertions that do not care which case.
    var lineIndex: Int {
        switch self {
        case .prevMismatch(let i), .unchainedAfterChain(let i), .sealHeadMismatch(let i),
             .sealSignatureInvalid(let i), .afterRememberedHead(let i),
             .cutShortBeforeRememberedHead(let i):
            return i
        }
    }
}
