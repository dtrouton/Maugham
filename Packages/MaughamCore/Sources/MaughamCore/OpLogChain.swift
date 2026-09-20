import CryptoKit
import Foundation

/// The op log's wire format and its verifier — pure, so it can be reasoned
/// about and tested without a file, a clock or a store anywhere near it.
///
/// **The format** (the plan's global constraint 4, verbatim). An op line is the
/// existing `.sortedKeys` JSON object with one additive key inserted as the
/// FIRST key: `{"prev":"<64 hex>",` then the rest of the object. The position is
/// fixed so the bytes are deterministic and the hash is over the bytes as
/// written — which is also why `prev` is never a field on `Op` or `InboxEntry`:
/// an op re-appended somewhere else can never carry a stale prev. A legacy line
/// (anything Maugham wrote before this milestone) has no `prev` at all, and
/// every existing `Codable` decoder ignores the key, so an older reader still
/// decodes a chained line unchanged.
///
/// A **seal line** is a line of its own kind — one top-level key, recognised by
/// the prefix `{"seal":` — carrying a signature over the chain head at the
/// moment it was written, plus the public key that verifies it. It is
/// self-contained on purpose: P2 adds a trust decision without a format change.
///
/// The line hash is SHA-256 over the line's bytes **without** the trailing
/// newline, because the newline is the file's separator and not the line's
/// content.
///
/// **What the verifier does and does not do.** It classifies; it never refuses
/// (spec §3). Every line comes back as `.legacy`, `.verified`, `.unsealed`,
/// `.unsignedHistory`, `.pending` or `.quarantined`, and the caller decides
/// what to apply. It holds no policy about WHO is trusted — that is the `trust`
/// closure, which a store builds from one `TrustTable` — and no memory of its
/// own; the remembered head is a parameter.
/// Lowercase hex, table-driven.
///
/// It has a type of its own because the obvious spelling —
/// `bytes.map { String(format: "%02x", $0) }.joined()` — is roughly a hundred
/// times slower, and this runs once per LINE on every load: `lineHash` is called
/// for all 50,000 lines of a long novel's history. Measured on that fixture, the
/// `String(format:)` version cost **107 ms** of a 109 ms `lineHash` total (the
/// SHA-256 itself was 3.5 ms); the table below costs about 1 ms. One spelling,
/// shared by the chain, the segment container and the device fingerprint, so
/// they cannot disagree about what a digest looks like — always lowercase,
/// always two characters per byte, which is what `hexDecode` reads back and what
/// a stored `digest`/`head`/`key` string is compared against.
enum Hex {
    private static let digits: [UInt8] = Array("0123456789abcdef".utf8)

    static func encode<Bytes: Sequence>(_ bytes: Bytes) -> String
    where Bytes.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

public enum OpLogChain {

    // MARK: - Hashing

    /// SHA-256 hex over the line's bytes, ignoring exactly ONE trailing
    /// newline. A second newline is content and changes the hash.
    public nonisolated static func lineHash(_ line: Data) -> String {
        let body = line.last == 0x0A ? line.dropLast() : line
        return hex(SHA256.hash(data: body))
    }

    /// The `prev` of the first line a device writes into an empty file: the
    /// hash of no bytes at all.
    ///
    /// A file has to start somewhere, and saying so explicitly is what lets a
    /// seal cover the first line. Without it the first line carries no `prev`,
    /// which is indistinguishable from a line written before this milestone —
    /// so it would read as legacy forever and no seal would ever settle it,
    /// even though the seal commits to it cryptographically.
    public nonisolated static let genesis: String = lineHash(Data())

    private nonisolated static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String
    where Bytes.Element == UInt8 {
        Hex.encode(bytes)
    }

    /// The inverse of `hex` for an even-length hex string; nil for anything else.
    nonisolated static func hexDecode(_ string: String) -> Data? {
        let characters = Array(string.utf8)
        guard !characters.isEmpty, characters.count % 2 == 0 else { return nil }
        var out = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = nibble(characters[index]),
                  let low = nibble(characters[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private nonisolated static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: - Building a line

    /// The element's own JSON with `"prev":"<prev>",` inserted after the leading
    /// `{`. No trailing newline: the caller writes the separator.
    ///
    /// A nil `prev` answers the element unchanged — an UNCHAINED line, which is
    /// the shape every pre-P1 file is made of. A device writing into an empty
    /// file passes `genesis`, not nil.
    public nonisolated static func chainedLine(elementJSON: Data, prev: String?) -> Data {
        precondition(elementJSON.first == UInt8(ascii: "{"),
                     "a chained line is built from a JSON object")
        guard let prev else { return elementJSON }
        let rest = elementJSON.dropFirst()
        var out = Data(capacity: elementJSON.count + prev.count + 10)
        out.append(UInt8(ascii: "{"))
        out.append(contentsOf: Array("\"prev\":\"\(prev)\"".utf8))
        // `{}` has no first key to separate from; every real element does.
        if rest.drop(while: isWhitespace).first != UInt8(ascii: "}") {
            out.append(UInt8(ascii: ","))
        }
        out.append(rest)
        return out
    }

    /// The seal line's one top-level key, as bytes.
    private nonisolated static let sealPrefix = Data("{\"seal\":".utf8)

    public nonisolated static func isSealLine(_ line: Data) -> Bool {
        line.starts(with: sealPrefix)
    }

    private nonisolated static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }

    /// Do these bytes fail to close as a JSON object? A whole line always ends
    /// in `}`; a line a crash stopped in the middle of does not.
    ///
    /// Deliberately a shape test rather than a parse: the walk runs once per
    /// line on every load, and the question here is only ever asked of the last
    /// line. It is a heuristic in one direction — a tear that happens to land
    /// just after a nested `}` still reads as whole and fails in the element
    /// decoder, which is where a torn line ended up before this branch existed.
    nonisolated static func isIncompleteObject(_ line: Data) -> Bool {
        var index = line.endIndex
        while index > line.startIndex {
            let before = line.index(before: index)
            if !isWhitespace(line[before]) {
                return line[before] != UInt8(ascii: "}")
            }
            index = before
        }
        return true
    }

    // MARK: - Reading a line's prev

    /// The line's `prev`, read TEXTUALLY off the first key — the format fixes
    /// its position, so a full JSON decode would be both slower and wrong
    /// (a legacy line carrying a `prev` further in is still unchained).
    ///
    /// The double optional is two different answers: the outer `nil` means this
    /// is not a JSON object we can read at all, the inner `nil` means it is an
    /// object whose first key is not `prev`. Both are unchained to the walk;
    /// the distinction is for callers that want to say which.
    ///
    /// `fastPrev` answers the one shape Maugham writes without accumulating a
    /// byte; everything else falls through to the reader below, whose answers
    /// are the contract (`OpLogChainTests.test_prevAnswersWhatTheTextualReaderAnsweredForEveryShape`).
    public nonisolated static func prev(ofLine line: Data) -> String?? {
        if let fast = fastPrev(ofLine: line) { return .some(fast) }

        var index = line.startIndex
        func skipWhitespace() {
            while index < line.endIndex, isWhitespace(line[index]) { index = line.index(after: index) }
        }

        skipWhitespace()
        guard index < line.endIndex, line[index] == UInt8(ascii: "{") else { return .none }
        index = line.index(after: index)
        skipWhitespace()
        guard index < line.endIndex, line[index] == UInt8(ascii: "\"") else { return .some(nil) }
        index = line.index(after: index)

        var key = Data()
        var escaped = false
        while index < line.endIndex {
            let byte = line[index]
            if escaped {
                key.append(byte)
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                break
            } else {
                key.append(byte)
            }
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return .none }  // an unterminated string
        guard key == Data("prev".utf8) else { return .some(nil) }

        index = line.index(after: index)
        skipWhitespace()
        guard index < line.endIndex, line[index] == UInt8(ascii: ":") else { return .none }
        index = line.index(after: index)
        skipWhitespace()
        guard index < line.endIndex, line[index] == UInt8(ascii: "\"") else { return .none }
        index = line.index(after: index)

        var value = Data()
        while index < line.endIndex, line[index] != UInt8(ascii: "\"") {
            value.append(line[index])
            index = line.index(after: index)
        }
        guard index < line.endIndex, let text = String(data: value, encoding: .utf8) else {
            return .none
        }
        return .some(text)
    }

    /// The one shape this app writes: the exact nine bytes `{"prev":"`, then 64
    /// hex, then a closing quote. Nil means "not that shape", and the textual
    /// reader answers instead — this path only ever READS, so the wire format
    /// is untouched.
    ///
    /// Worth a function of its own because it is the whole per-line cost of a
    /// walk: the textual reader accumulates the key and the value into two
    /// `Data`s a byte at a time, about 11 ms per 6,000 lines. The 64 bytes are
    /// checked for hex rather than merely counted, and that is what makes this
    /// an equivalence rather than a second opinion: neither `"` nor `\` is hex,
    /// so the quote at offset 73 is necessarily the FIRST one, which is exactly
    /// where the textual reader would have stopped.
    ///
    /// A `Data` slice does not start at index 0 — the verifier hands this
    /// function slices of a whole file — so every offset is off `startIndex`.
    private nonisolated static func fastPrev(ofLine line: Data) -> String? {
        let start = line.startIndex
        guard line.count >= 74, line[start + 73] == UInt8(ascii: "\"") else { return nil }
        for offset in 0..<prevPrefix.count where line[start + offset] != prevPrefix[offset] {
            return nil
        }
        let value = line[(start + prevPrefix.count)..<(start + 73)]
        guard value.allSatisfy(isHex) else { return nil }
        return String(decoding: value, as: UTF8.self)
    }

    /// `{"prev":"` — the fixed opening of a chained line, as bytes.
    private nonisolated static let prevPrefix = Array("{\"prev\":\"".utf8)

    private nonisolated static func isHex(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "a")...UInt8(ascii: "f"),
             UInt8(ascii: "A")...UInt8(ascii: "F"): return true
        default: return false
        }
    }

    // MARK: - Signing a digest

    /// The three fields a signature over a 32-byte digest carries. One shape,
    /// used by the seal INSIDE a file and by the signature BESIDE a sealed
    /// segment, so the base64/X9.63 dance is written once and the two can never
    /// disagree about what a signature is.
    /// `Codable` and public because P2's registry records carry one as a
    /// FIELD (`RegistryRecord`'s `sig`): the seal inside a file, the signature
    /// beside a segment and the signature on a person record are the same
    /// three fields, and a second spelling of them would be a second opinion
    /// about what a signature is.
    public struct Credentials: Codable, Equatable, Hashable, Sendable {
        public let key: String
        public let pub: String
        public let sig: String

        public init(key: String, pub: String, sig: String) {
            self.key = key
            self.pub = pub
            self.sig = sig
        }
    }

    /// Sign `digestHex`'s 32 bytes with `identity`.
    ///
    /// Throws `DeviceIdentityError.unsigned` when this device has no key — the
    /// condition is first-class (spec §4.1), never a trap.
    static func credentials(
        signing digestHex: String, identity: DeviceIdentity
    ) throws -> Credentials {
        guard let publicKey = identity.publicKey else { throw DeviceIdentityError.unsigned }
        guard let digestBytes = hexDecode(digestHex) else {
            preconditionFailure("a signed digest is hex — got \(digestHex)")
        }
        return Credentials(
            key: DeviceIdentity.fingerprint(of: publicKey),
            pub: publicKey.x963Representation.base64EncodedString(),
            sig: try identity.sign(digestBytes).base64EncodedString())
    }

    /// Do these credentials hold together over `digestHex`? Three questions,
    /// and all three must answer yes: the carried public key parses, its
    /// fingerprint IS the `key` named (otherwise the signature claims another
    /// device's word), and the signature is over these digest bytes.
    ///
    /// Whether that key is TRUSTED is a separate question, and not one this
    /// function is allowed to have an opinion about.
    static func credentialsVerify(
        _ credentials: Credentials, over digestHex: String
    ) -> Bool {
        guard let publicKeyBytes = Data(base64Encoded: credentials.pub),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyBytes)
        else { return false }
        guard DeviceIdentity.fingerprint(of: publicKey) == credentials.key else { return false }
        guard let signatureBytes = Data(base64Encoded: credentials.sig),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
        else { return false }
        guard let digestBytes = hexDecode(digestHex) else { return false }
        return publicKey.isValidSignature(signature, for: digestBytes)
    }

    // MARK: - The seal

    /// One device's signature over the chain head at a moment: what it signed,
    /// which key signed it, and the key itself. Self-contained by design — a
    /// seal carries what verifies it, so P2's registry adds a TRUST decision
    /// without touching the format.
    public struct Seal: Codable, Equatable, Sendable {
        public let at: Date
        public let head: String
        /// The signing key's fingerprint (`DeviceIdentity.fingerprint(of:)`).
        public let key: String
        /// Base64 of the public key's X9.63 representation.
        public let pub: String
        /// Base64 of the 64-byte raw P256 signature over the head's 32 bytes.
        public let sig: String

        public init(at: Date, head: String, key: String, pub: String, sig: String) {
            self.at = at
            self.head = head
            self.key = key
            self.pub = pub
            self.sig = sig
        }

        /// The one top-level key the wire format fixes.
        private struct Envelope: Codable {
            let seal: Seal
        }

        /// A seal line over `head`, signed by `identity`.
        ///
        /// Throws `DeviceIdentityError.unsigned` when this device has no key —
        /// the condition is first-class (spec §4.1): such a device writes
        /// chained lines that nothing seals, and the caller decides about it.
        public static func line(head: String, identity: DeviceIdentity, at: Date) throws -> Data {
            let credentials = try OpLogChain.credentials(signing: head, identity: identity)
            let seal = Seal(
                at: at, head: head,
                key: credentials.key, pub: credentials.pub, sig: credentials.sig)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = JSONLAppendStore<Seal>.dateEncoding
            return try encoder.encode(Envelope(seal: seal))
        }

        /// The seal a line carries, or nil when the line is not one.
        public static func parse(_ line: Data) -> Seal? {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = JSONLAppendStore<Seal>.dateDecoding
            return (try? decoder.decode(Envelope.self, from: line))?.seal
        }

        /// Does this seal hold together on its own terms? Three questions, and
        /// all three must answer yes: the carried public key parses, its
        /// fingerprint IS the `key` this seal names (otherwise the seal claims
        /// another device's word), and the signature is over this head.
        ///
        /// Whether that key is TRUSTED is a separate question, and not one this
        /// type is allowed to have an opinion about.
        public func verifies() -> Bool {
            OpLogChain.credentialsVerify(
                .init(key: key, pub: pub, sig: sig), over: head)
        }
    }

    // MARK: - The verdict

    /// One line of a file, as the walk found it.
    public struct Line: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case op
            case seal
        }

        public enum State: Equatable, Sendable {
            /// Written before this milestone: no `prev`, no seal, applied.
            case legacy
            /// Covered by a seal whose key the caller trusts.
            case verified
            /// Chained, and no seal covers it yet.
            case unsealed
            /// Covered by a seal from a key the caller cannot judge, because it
            /// belongs to no chain here. Applied — that is decision B3, and P1's
            /// whole world — but never claimed as this device's word.
            case unsignedHistory
            /// Covered by a seal that HOLDS, made by a key this device's chain
            /// says nothing about: **held** (spec §3). Not applied, and not
            /// quarantined either — nothing broke, and nothing is recorded.
            /// The writer admits the device or does not, and admitting is a
            /// re-read: no line of the file is rewritten to make it apply.
            ///
            /// It carries the DEVICE the sealing key belongs to — not the key
            /// — because the one question a surface asks about held lines is
            /// *whose*, and a device holds four actor keys: a phone that wrote
            /// as both its author and its assistant is one device waiting for
            /// admission, not two. The key stands for itself when no device
            /// record names it, which is `TrustVerdict.stranger`'s own rule.
            /// A line that had to be matched back to its seal to answer this
            /// would be a second walk.
            case pending(device: String)
            /// Never applied: the chain broke at or before this line, or the
            /// key that sealed it was revoked or belongs to another claimant.
            case quarantined
            /// The FILE'S LAST line, whose bytes do not form a complete JSON
            /// object: a write interrupted mid-line, which is the one thing a
            /// crash can leave behind that is nobody's forgery.
            ///
            /// It is excluded from the walk entirely — not a break, not
            /// quarantined, and the running head does not move onto it — and
            /// its bytes are handed on to the element decoder, which reports
            /// them in `diagnostics.skipped` exactly as a torn line was
            /// reported before the chain existed. Without this the tear read as
            /// `unchainedAfterChain` and the writer was told their own
            /// half-written op was "written by something that is not Maugham",
            /// in a record that never clears (the whole-branch review's L62).
            case tornTail

            /// Whether the reader keeps this line OUT of what it applies.
            ///
            /// Two states, one question, and the two are held back for
            /// opposite reasons: a quarantined line is refused, a pending one
            /// is merely not judged yet. A `.tornTail` is deliberately NOT
            /// here — its bytes go on to the element decoder, which reports
            /// them in `diagnostics.skipped` exactly as a torn line was
            /// reported before the chain existed.
            public var isHeldBack: Bool {
                switch self {
                case .quarantined, .pending: true
                case .legacy, .verified, .unsealed, .unsignedHistory, .tornTail: false
                }
            }

            /// The device whose seal is holding this line, when it is held.
            public var pendingDevice: String? {
                if case let .pending(device) = self { return device }
                return nil
            }
        }

        public let bytes: Data
        public let kind: Kind
        public private(set) var state: State
        /// **Why THIS line was refused** — nil unless it is `.quarantined`
        /// (find-5 review, the Critical).
        ///
        /// `Verification.quarantineCause` is one cause for a whole file, and it
        /// is the FIRST one the walk met: a `broke(_:)` after a revoked seal
        /// leaves the revocation standing as the file's cause while every line
        /// after the splice is refused for the break. Any rule that reads the
        /// file's cause and then decides about a LINE is therefore reading an
        /// answer to a different question — which is how a spliced line came to
        /// be re-admitted into a manuscript on the strength of an op id its own
        /// forger chose, `highestOpIdSeen` being a number every device can read
        /// out of a signed record.
        ///
        /// So the reason travels with the line. A line refused for a chain
        /// fault, a truncation, another claimant's root or a retirement is
        /// never a candidate for anything a revocation may keep, whatever its
        /// op id says.
        public private(set) var refusal: QuarantineCause?

        /// **Did a seal ever close the span this line is in?** (Task 11, fix
        /// round 1.)
        ///
        /// Set by the walk when a seal settles a span, and left false for a
        /// line the FILE'S KEY judged instead — the unsealed remainder, which
        /// no signature covers.
        ///
        /// The one reader is `readmitting`, which puts a refused line back into
        /// the state it would have had if nothing had refused it: `.verified`
        /// where a seal covers it, `.unsealed` where none ever did. Without
        /// this it called every re-admitted line `.verified`, which for an
        /// unsealed one is the same misstatement `settlingAnUnsealedSpan`'s
        /// `.mine` arm exists to avoid — telling the writer's History pane that
        /// bytes nobody signed are verified. It is a fact the walk has in hand
        /// and nothing downstream can re-derive: *covered by a seal* is not
        /// *has a seal after it in the file* (a span stranded below a seal that
        /// failed to parse has one and was never settled by it).
        public private(set) var coveredByASeal: Bool

        public init(
            bytes: Data, kind: Kind, state: State, refusal: QuarantineCause? = nil,
            coveredByASeal: Bool = false
        ) {
            self.bytes = bytes
            self.kind = kind
            self.state = state
            self.refusal = refusal
            self.coveredByASeal = coveredByASeal
        }

        /// Only the walk in this file promotes a span when its seal arrives,
        /// and only it re-admits one. `because` is the refusal the new state
        /// carries: a line that stops being quarantined stops having a reason.
        fileprivate mutating func settle(_ state: State, because cause: QuarantineCause? = nil) {
            self.state = state
            self.refusal = state == .quarantined ? cause : nil
        }

        /// A seal has closed the span this line is in. Recorded beside the
        /// state rather than inferred from it, because every state a seal can
        /// settle a span to is also reachable without one.
        fileprivate mutating func markCoveredByASeal() {
            coveredByASeal = true
        }

        /// The state this line would be in if nothing had refused it —
        /// `readmitting`'s one question.
        fileprivate var stateIfNothingHadRefusedIt: State {
            coveredByASeal ? .verified : .unsealed
        }
    }

    /// Why the walk stopped. `lineIndex` indexes `Verification.lines` — blank
    /// lines are not lines, so it is not a file line number.
    public enum BreakReason: Equatable, Sendable {
        /// A chained line named a `prev` that is not the running head.
        case prevMismatch(lineIndex: Int)
        /// A line with no `prev` arrived after the chain had begun.
        case unchainedAfterChain(lineIndex: Int)
        /// A seal named a head that is not the running head.
        case sealHeadMismatch(lineIndex: Int)
        /// A seal did not hold together: unparseable, forged, or naming a key
        /// it does not carry.
        case sealSignatureInvalid(lineIndex: Int)
        /// The line chains correctly and this device did not write it — it
        /// arrived after the head this device remembers.
        case afterRememberedHead(lineIndex: Int)
        /// The head this device remembers is nowhere in the file, and the head
        /// the file DOES have is not the one the crash window would leave
        /// (`previousHead`). Something cut the file short and wrote its own
        /// correctly-chained lines onto what was left; everything after the
        /// last seal this device trusts is held back.
        case cutShortBeforeRememberedHead(lineIndex: Int)
    }

    /// Why a walk held lines back, in the walk's own terms.
    ///
    /// The reason a `.lines` record carries is DERIVED from this and never
    /// passed in (ADR 0032 §6), which is what stops two callers filing the same
    /// event under different words. Before P2a a broken chain was the only way
    /// to be refused, so `BreakReason` was the whole answer; a verdict can now
    /// refuse a span that chains perfectly, and those two are different events
    /// with different sentences for the writer.
    ///
    /// One cause per verification, and it is the FIRST one the walk met: a
    /// break stops the walk outright, so a break is always the last word, and a
    /// verdict that refused an earlier span is the one the writer needs to see.
    public enum QuarantineCause: Equatable, Sendable {
        /// The chain did not hold together.
        case chainBroke(BreakReason)
        /// A seal made by a key this device's root admitted and then revoked.
        /// A seal made by a key this device's root admitted and then revoked.
        ///
        /// `keptNothing` is the writer's CHOICE, read off the revocation record
        /// itself: a revocation carrying no mark is *set aside everything it
        /// wrote* (`RevocationScope.nothing`), and under it a line written long
        /// before the door closed is refused too. It rides on the cause because
        /// the sentence the writer reads differs — telling them a paragraph
        /// from last June was *written after this device's access was
        /// withdrawn* is false, and it is the kind of false that makes a writer
        /// doubt the machine rather than the paragraph (Denver's re-smoke,
        /// 2026-09-19).
        case afterRevocation(person: String, keptNothing: Bool)
        /// A seal from a second self-signed root's chain: listed, never merged.
        case anotherClaimants(root: String)
        /// A seal made at or after the moment that DEVICE said it had stopped
        /// writing (spec §5). Its earlier spans are untouched — this is the one
        /// cause whose subject is a date rather than a key.
        case afterRetirement(device: String)
        /// **A line its signer's permit does not allow** (P3 spec §4.4).
        ///
        /// The one cause that is about a LINE rather than about a key: the
        /// chain held, the seal verified, the device is admitted and in good
        /// standing — and what the line says is not something that person, or
        /// that one of their four keys, may write here. Its neighbours under
        /// the same seal are applied.
        ///
        /// - `person` is who the key resolves to (`TrustTable.person`). A
        ///   surface turns it into a label; nothing here does, for the reason
        ///   `afterRevocation` carries a person and no name either — the words
        ///   in `JSONLAppendStore.quarantineReason` are one clause about the
        ///   event, and the writer's own name for a machine belongs to the
        ///   pane that draws it.
        /// - `what` is the noun: manuscript text, a disposition, a pass state,
        ///   a statement, a task, a translation.
        /// - `afterMark` is whether the governing permit was installed by an
        ///   EVENT rather than being the one this person has always had —
        ///   spec §4.4's *…after it stopped being hers*.
        /// - `actor` is the raw actor word when the refusal is one of the four
        ///   keys narrowing within the person's permit (the assistant never
        ///   changes the manuscript, whoever holds it), and nil when the
        ///   person's own permit is what refused.
        case notPermitted(
            person: String, what: RefusedWhat, afterMark: Bool, actor: String?)

        // **There is no `revocationLate` any more** (find 5, ruled 2026-09-18).
        // A line from a revoked key whose opId is at or below the mark the root
        // recorded is not refused under a gentler sentence — it is APPLIED,
        // because this Mac had already applied it while that device was
        // admitted. `RevocationSplit.partition` makes that cut before the parse
        // and `readmitting` re-settles the lines; nothing is left to say a
        // second thing about. The *may be late sync, or may be backdated*
        // distinction wants a durable per-span exception with a real Apply
        // behind it, and returns in P3 with one.
    }

    /// **Held lines counted by the DEVICE whose seal holds them** — the one
    /// derivation of that split, so every reader that asks *who is waiting*
    /// gets the same answer.
    ///
    /// The op log's provenance (`OpLogStore.provenance`) and the inbox's
    /// pending banner both ask it, of different streams, and two spellings of
    /// the same count is how one surface comes to say a phone is waiting while
    /// the other says nobody is. Keyed the way `Line.State.pending` is keyed:
    /// on the device record's fingerprint, with a key no record names standing
    /// for itself.
    ///
    /// **OP lines only.** A seal is held back with the span it closes, and it
    /// is counted nowhere: every reader of this number puts a NOUN after it —
    /// *3 captures waiting*, *2 notes from this iPhone* — and a seal is neither
    /// a capture nor a note. Two ops under one seal read *3* before P2b's final
    /// wave, which is a pane telling the writer they have something they have
    /// not got (Task 6's review, ruling a).
    nonisolated public static func pendingByDevice(of lines: [Line]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in lines where line.kind == .op {
            guard let device = line.state.pendingDevice else { continue }
            counts[device, default: 0] += 1
        }
        return counts
    }

    public struct Verification: Equatable, Sendable {
        /// Every non-blank line, in file order, classified.
        public let lines: [Line]
        /// The hash of the last line that was applied — what the next append
        /// chains onto. Nil for an empty file.
        public let head: String?
        public let legacyCount: Int
        public let verifiedCount: Int
        public let unsealedCount: Int
        /// Lines held under a seal whose key belongs to no chain here — not
        /// applied, not refused (spec §3).
        public let pendingCount: Int
        /// Seals that held together under a key the caller does not call its
        /// own. Every verdict but `.mine` counts here, because the one reader
        /// of this number (`resolveAbsentHead`'s crash window) asks whether
        /// every seal in the file is this device's.
        public let foreignSealCount: Int
        /// The raw bytes of every quarantined line, in file order.
        public let quarantined: [Data]
        public let breakReason: BreakReason?
        /// Why the quarantined lines were held back, when any were.
        public let quarantineCause: QuarantineCause?

        public init(
            lines: [Line],
            head: String?,
            legacyCount: Int,
            verifiedCount: Int,
            unsealedCount: Int,
            pendingCount: Int = 0,
            foreignSealCount: Int,
            quarantined: [Data],
            breakReason: BreakReason?,
            quarantineCause: QuarantineCause? = nil
        ) {
            self.lines = lines
            self.head = head
            self.legacyCount = legacyCount
            self.verifiedCount = verifiedCount
            self.unsealedCount = unsealedCount
            self.pendingCount = pendingCount
            self.foreignSealCount = foreignSealCount
            self.quarantined = quarantined
            self.breakReason = breakReason
            self.quarantineCause = quarantineCause
        }
    }

    /// Test-only counting seam: called once at the top of every `verify`.
    ///
    /// The verify CACHE is invisible from outside — a remembered segment and a
    /// walked one answer the same ops, which is the whole point — so the only
    /// way to pin "this segment was not walked" is to watch the verifier
    /// itself. `nonisolated(unsafe)` because it is a test's own variable set
    /// and cleared on one thread; production never assigns it.
    nonisolated(unsafe) static var verifyObserverForTesting: (@Sendable () -> Void)?

    // MARK: - The walk

    /// Classify every line of `bytes`.
    ///
    /// The rules, in the order they bite:
    ///
    /// 1. A blank line is skipped — never counted, never a break.
    /// 2. Once the walk has broken, every later line is `.quarantined`,
    ///    seals included. The chain is a chain: nothing after a break can be
    ///    shown to follow from what came before it.
    /// 3. `rememberedHead`: when some line hashes to it, everything AFTER that
    ///    line is quarantined **even though it chains** — that is the case an
    ///    agent computing `prev` correctly is caught by. When NO line hashes to
    ///    it (the crash window, or a file this device has not seen), the walk
    ///    proceeds as if it were nil and the caller decides whether to adopt.
    /// 4. An op line with `prev` must name the running head — or, when nothing
    ///    has been seen yet, `genesis`. One WITHOUT a `prev` is `.legacy`, and
    ///    only while nothing chained or sealed has been seen yet in these bytes:
    ///    legacy is a prefix, never a suffix.
    /// 5. A seal must name the running head and hold together, and it settles
    ///    every `.unsealed` line since the last seal to whatever `trust`
    ///    answers about the key that made it — `.verified`, `.pending`,
    ///    `.unsignedHistory` or `.quarantined`, per `TrustVerdict.settling`.
    /// 6. **And what NO seal has closed answers to the file's own key** (Task
    ///    11, audit PR #65's F1 + F2). See `judgingWhatNoSealHasClosed`.
    ///
    /// **A refused span does not break the chain.** A verdict is about WHOSE
    /// word a span is, not about whether the bytes follow from each other, so
    /// the walk goes on and a later span from an admitted key still applies.
    /// That is also why quarantined lines are no longer necessarily a suffix on
    /// this path — `applied` filters by state and never by position, and the
    /// chained WRITE (whose rewrite does assume a prefix) judges by `.mine`
    /// alone, so it cannot produce one of these.
    ///
    /// - Parameter keyOfAnUnsealedFile: **arm 2 of *the file's key*** — the key
    ///   this device can NAME for a file that holds no usable seal at all,
    ///   asked at most once and only when there is something unsealed to judge.
    ///   It is a closure rather than a value so this type stays ignorant of
    ///   device records and filenames: the caller that can join a slug to a key
    ///   supplies one, and every other caller — the keyless walks, the chained
    ///   write, the tests that pin the chain's own rules — takes the default
    ///   and behaves exactly as it did.
    public nonisolated static func verify(
        bytes: Data,
        trust: (String) -> TrustVerdict,
        rememberedHead: String?,
        keyOfAnUnsealedFile: () -> String? = { nil }
    ) -> Verification {
        verifyObserverForTesting?()
        var lines: [Line] = []
        var head: String?
        var sawChainOrSeal = false
        var spanStart = 0
        var breakReason: BreakReason?
        var cause: QuarantineCause?
        var foreignSealCount = 0
        var reachedRememberedHead = false
        // Arm 1 of *the file's key*: the LAST seal in the file that parsed and
        // chain-verified, whatever this device makes of its key. Set past all
        // three of the seal guards, so a forged or misplaced seal names nothing.
        var lastSealKey: String?

        // One cause per verification, and it is the first one met.
        func broke(_ reason: BreakReason) {
            breakReason = reason
            if cause == nil { cause = .chainBroke(reason) }
        }

        let lineData = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map { Data($0) }

        for (index, line) in lineData.enumerated() {
            let kind: Line.Kind = isSealLine(line) ? .seal : .op

            if let breakReason {
                // Everything after a break is refused for that break, whatever
                // the file's own first cause was.
                lines.append(Line(bytes: line, kind: kind, state: .quarantined,
                                  refusal: .chainBroke(breakReason)))
                continue
            }
            if reachedRememberedHead {
                let reason = BreakReason.afterRememberedHead(lineIndex: index)
                broke(reason)
                lines.append(Line(bytes: line, kind: kind, state: .quarantined,
                                  refusal: .chainBroke(reason)))
                continue
            }
            // A tear is only ever the LAST line — a write that stopped
            // mid-line. An incomplete line anywhere else has something after
            // it, which means the write finished and the damage is not a tear.
            if index == lineData.count - 1, isIncompleteObject(line) {
                lines.append(Line(bytes: line, kind: kind, state: .tornTail))
                continue
            }

            switch kind {
            case .op:
                // An unreadable line has no prev, the same as a legacy one.
                let declared = prev(ofLine: line) ?? nil
                if let declared {
                    // Nothing seen yet? The only prev that can be right is the
                    // sentinel. A `genesis` anywhere else is a wrong prev like
                    // any other, and breaks.
                    let expected = head ?? genesis
                    guard declared == expected else {
                        let reason = BreakReason.prevMismatch(lineIndex: index)
                        broke(reason)
                        lines.append(Line(bytes: line, kind: kind, state: .quarantined,
                                          refusal: .chainBroke(reason)))
                        continue
                    }
                    sawChainOrSeal = true
                    lines.append(Line(bytes: line, kind: kind, state: .unsealed))
                } else {
                    guard !sawChainOrSeal else {
                        let reason = BreakReason.unchainedAfterChain(lineIndex: index)
                        broke(reason)
                        lines.append(Line(bytes: line, kind: kind, state: .quarantined,
                                          refusal: .chainBroke(reason)))
                        continue
                    }
                    lines.append(Line(bytes: line, kind: kind, state: .legacy))
                }

            case .seal:
                guard let seal = Seal.parse(line) else {
                    let reason = BreakReason.sealSignatureInvalid(lineIndex: index)
                    broke(reason)
                    lines.append(Line(bytes: line, kind: kind, state: .quarantined,
                                      refusal: .chainBroke(reason)))
                    continue
                }
                // Deliberately NOT `head ?? genesis`: a seal must follow at
                // least one line, so a seal as the first line of a file has
                // nothing to seal and names a head that was never reached.
                guard seal.head == head else {
                    let reason = BreakReason.sealHeadMismatch(lineIndex: index)
                    broke(reason)
                    lines.append(Line(bytes: line, kind: kind, state: .quarantined,
                                      refusal: .chainBroke(reason)))
                    continue
                }
                guard seal.verifies() else {
                    let reason = BreakReason.sealSignatureInvalid(lineIndex: index)
                    broke(reason)
                    lines.append(Line(bytes: line, kind: kind, state: .quarantined,
                                      refusal: .chainBroke(reason)))
                    continue
                }
                lastSealKey = seal.key
                let verdict = trust(seal.key)
                if verdict != .mine { foreignSealCount += 1 }
                // The seal's own moment, because one verdict — `.retired` —
                // answers differently before and after a date, and this is the
                // only place that knows when a seal was made.
                let settled = verdict.settling(sealKey: seal.key, sealedAt: seal.at)
                if settled == .quarantined, cause == nil {
                    cause = verdict.refusal
                }
                // The verdict's own words, on every line the seal covers AND
                // on the seal itself: what refused them is the key, not a break.
                let sealRefusal = settled == .quarantined ? verdict.refusal : nil
                for covered in spanStart..<index where lines[covered].state == .unsealed {
                    lines[covered].markCoveredByASeal()
                    lines[covered].settle(settled, because: sealRefusal)
                }
                // The seal is covered by itself: it is the signature over the
                // span, so a re-admission puts it back verified with the lines
                // it closed.
                lines.append(Line(bytes: line, kind: kind, state: settled,
                                  refusal: sealRefusal, coveredByASeal: true))
                sawChainOrSeal = true
                spanStart = index + 1
            }

            head = lineHash(line)
            if let rememberedHead, head == rememberedHead { reachedRememberedHead = true }
        }

        // **Rule 6, after the walk, because only here has every seal been
        // seen.** What no seal closed is judged by the file's own key.
        if let judged = judgingWhatNoSealHasClosed(
            &lines, trust: trust,
            lastSealKey: lastSealKey, keyNamingTheFile: keyOfAnUnsealedFile),
           cause == nil {
            cause = judged
        }

        // One pass, not five. The tallies used to be four `filter`s and a `map`
        // over the same array, which on a long novel's tail is five extra walks
        // of every line for numbers a single loop already has in hand.
        var legacyCount = 0, verifiedCount = 0, unsealedCount = 0, pendingCount = 0
        var quarantined: [Data] = []
        for line in lines {
            switch line.state {
            case .legacy: legacyCount += 1
            case .verified: verifiedCount += 1
            case .unsealed: unsealedCount += 1
            case .pending: pendingCount += 1
            case .unsignedHistory: break
            case .tornTail: break
            case .quarantined: quarantined.append(line.bytes)
            }
        }
        return Verification(
            lines: lines,
            head: head,
            legacyCount: legacyCount,
            verifiedCount: verifiedCount,
            unsealedCount: unsealedCount,
            pendingCount: pendingCount,
            foreignSealCount: foreignSealCount,
            quarantined: quarantined,
            breakReason: breakReason,
            quarantineCause: quarantined.isEmpty ? nil : cause)
    }

    /// **A span no seal has closed answers to the verdict of its FILE** (Task
    /// 11, audit PR #65's F1 + F2) — the rule that stops *never seal again*
    /// being a way past admission, revocation and the claim alike.
    ///
    /// Before this, trust was consulted at `case .seal` and nowhere else. A
    /// chained op line with a good `prev` was `.unsealed`, `isHeldBack` false,
    /// and applied — so everything a SIGNED foreign device had written since
    /// its last seal (up to `OpLogStore.chainSealInterval − 1` ops, or its whole
    /// file before its first one) entered the book whatever the register said
    /// about it. A stranger's text was in the manuscript unadmitted; a revoked
    /// device's post-revocation tail leaked. Every P2 fixture sealed before it
    /// asserted, which is why it shipped green in v0.39.0/v0.40.0.
    ///
    /// **The file's key, in three arms**, and the third one is a door left open
    /// on purpose:
    ///
    /// 1. the key of the LAST seal in the file that parsed and chain-verified,
    ///    **whatever this device's register makes of it** — a stranger's, a
    ///    revoked device's or a retired device's seal names the file just as
    ///    this device's own does, because ADR 0012 gives a file one writer and
    ///    the question here is whose file this is, not whose word to take;
    /// 2. where there is no such seal, **or where that seal's key is one this
    ///    register has never heard of** (`.noChain`), whatever
    ///    `keyOfAnUnsealedFile` can name for the file — in production the key
    ///    this device's register holds under the device id the filename's slug
    ///    is made from;
    /// 3. **neither ⇒ the span is what it was: `.unsealed`, and applied.** That
    ///    residue IS the unsigned door (P1's decision B3, ADR 0032 §3): a device
    ///    with no enclave — a VM, CI's runner — writes chained lines nothing
    ///    seals and reports nothing wrong, and pre-signing legacy history sits
    ///    in the same arm. Closing it is Denver's to rule when P3b is planned;
    ///    it is not closed here.
    ///
    /// **Why arm 1 falls THROUGH when it cannot be attributed** (fix round 1's
    /// ruling). An unconditional arm 1 makes one seal under a throwaway key a
    /// way to buy the whole unsealed remainder a gentler answer: a revoked
    /// device seals its tail with a key nothing here names, arm 1 answers about
    /// THAT key, and the span this rule exists to refuse is merely held —
    /// offered to the writer for admission under a code that is not the
    /// revoked device's — while the file's own NAME still carries that
    /// device's slug, which arm 2 resolves to `.revoked`.
    ///
    /// *Unattributable* is `.noChain` — which only a reader with no root of
    /// its own ever sees (`TrustTable.verdict` guards on `myRoot`) — **or
    /// `.stranger` with no device**, which is what a rooted book actually
    /// answers for a key no record mentions. Both are *the register has
    /// nothing to say about this key*.
    ///
    /// **The fall-through cannot WIDEN, and that is structural rather than
    /// guarded.** A filename must never buy a span a gentler answer than its
    /// seal got, and here it cannot: the fall-through is reached only where arm
    /// 1 is unattributable, an unattributable arm 1 settles to nil or
    /// `.pending` (`TrustVerdict.isUnattributable`'s two verdicts against
    /// `settlingAnUnsealedSpan`'s arms), and arm 2 is taken only when it
    /// answers a STATE — so a `.mine`/`.admitted`/`.retired` filename answers
    /// nil, the `if let` declines it, and arm 1's hold stands. The property is
    /// pinned by `OpLogChainTests
    /// .test_anUnattributableVerdictCanOnlyHoldOrLeaveASpanAlone`, which is
    /// what goes red if a later arm makes an unattributable verdict refuse, or
    /// makes an attributable one settle where it used to answer nil. A severity
    /// comparison was written here first and removed: it could not be made to
    /// fail, because the `if let` already is it.
    ///
    /// The fall-through costs an honest unsigned device nothing: it has no
    /// record for arm 2 to find either, so it lands in arm 3 and is applied
    /// exactly as P1 applied it.
    ///
    /// **And the span an unattributable seal COVERS is untouched.** The walk
    /// settles it at `case .seal` — `.unsignedHistory` for `.noChain`,
    /// `.pending` for a stranger — and this rule never looks at it. Those bytes
    /// are the unsigned door; widening into them would start refusing history
    /// P1 applies. This is about the unsealed remainder and nothing else.
    ///
    /// What the span then becomes is `settlingAnUnsealedSpan`'s, which is
    /// `settling`'s sibling and defers to it arm for arm.
    ///
    /// Every line still `.unsealed` is judged, not only the trailing span: a
    /// seal that failed to parse or verify breaks the walk WITHOUT settling the
    /// lines below it, so those are unsealed too, and they are no more this
    /// device's word than the tail is.
    ///
    /// Answers the cause when it refused something, so the walk can keep its
    /// one-cause-per-verification rule — and nil when it held, applied or left
    /// everything alone, because holding names no reason for holding.
    private nonisolated static func judgingWhatNoSealHasClosed(
        _ lines: inout [Line],
        trust: (String) -> TrustVerdict,
        lastSealKey: String?,
        keyNamingTheFile: () -> String?
    ) -> QuarantineCause? {
        // Asked before either key is, so a file whose every line a seal already
        // settled never pays for the lookup arm 2 would do.
        guard lines.contains(where: { $0.state == .unsealed }) else { return nil }

        // Arm 1.
        let armOne = lastSealKey.map { ($0, trust($0)) }
        var chosen = armOne.flatMap { key, verdict in
            verdict.settlingAnUnsealedSpan(sealKey: key).map { ($0, verdict) }
        }
        // Arm 2, where arm 1 named nothing or named a key this register cannot
        // attribute — and then only where it judges the span more strictly, so
        // a filename can never buy a gentler answer than the seal's own.
        if armOne == nil || armOne.map({ $0.1.isUnattributable }) == true,
           let named = keyNamingTheFile() {
            let verdict = trust(named)
            // Only where arm 2 answers a STATE. A filename naming a device
            // this book trusts answers nil, and arm 1's hold stands — see the
            // narrowing argument above.
            if let settled = verdict.settlingAnUnsealedSpan(sealKey: named) {
                chosen = (settled, verdict)
            }
        }
        // Arm 3 is either answer being nothing at all.
        guard let (settled, verdict) = chosen else { return nil }
        let refusal = settled == .quarantined ? verdict.refusal : nil
        for index in lines.indices where lines[index].state == .unsealed {
            lines[index].settle(settled, because: refusal)
        }
        return refusal
    }

    /// The keyless walk: `true` is this device's own key, `false` is a key it
    /// has no chain to judge by.
    ///
    /// It exists for the two readers that genuinely have no registry in hand —
    /// `ProjectIntegrity.check`, which inspects a project without opening it,
    /// and the fallback walk inside an unsettled segment — plus the tests that
    /// pin the chain's own rules without a trust table. Every other production
    /// caller builds a `TrustTable` and calls `verify(bytes:trust:)`.
    public nonisolated static func verify(
        bytes: Data,
        trusted: (String) -> Bool,
        rememberedHead: String?
    ) -> Verification {
        verify(
            bytes: bytes,
            trust: { trusted($0) ? .mine : .noChain },
            rememberedHead: rememberedHead)
    }
}

// MARK: - What a verdict does to a span

extension TrustVerdict {

    /// The state this verdict settles a sealed span to. The spec's §3 table,
    /// as one switch: it is the only place a verdict becomes a line state, so
    /// a seventh verdict is a compile error here rather than a silent
    /// `unsignedHistory`.
    nonisolated func settling(sealKey: String, sealedAt: Date) -> OpLogChain.Line.State {
        switch self {
        case .mine, .admitted: .verified
        // The device the registry names for this key, and the key itself only
        // when no device record does.
        case let .stranger(device): .pending(device: device ?? sealKey)
        case .revoked, .otherRoot: .quarantined
        // Spec §5: its past stays verified, its future is quarantined. AT the
        // moment counts as after it — the device said it was done, and a seal
        // bearing that same instant is not something it was still owed.
        case let .retired(_, retiredAt):
            sealedAt < retiredAt ? .verified : .quarantined
        case .noChain: .unsignedHistory
        }
    }

    /// **The same table, for a span NO seal has closed** (Task 11) — the state
    /// such a span settles to, or **nil for *leave it exactly as the walk found
    /// it***, which is `.unsealed` and applied.
    ///
    /// It is a sibling of `settling` rather than a call into it, because two of
    /// the seven arms cannot be answered the same way and the difference is the
    /// whole of this function. Arm by arm, against `settling`'s own line:
    ///
    /// - `.mine`, `.admitted` — `settling` says `.verified`; here, nil.
    ///   `.verified` means *covered by a seal whose key the caller trusts*, and
    ///   these bytes are covered by no seal at all, so claiming it would be a
    ///   lie about provenance in the writer's own History pane. Nothing is held
    ///   either way, which is what matters: **this device's own unsealed tail
    ///   is never held and never refused**, because typing appends unsealed
    ///   lines all day and a writer whose words waited for a seal would be
    ///   watching their sentence disappear between bursts.
    /// - `.stranger` — `.pending(device: device ?? sealKey)`, the SAME device
    ///   string the sealed case uses. The admission union keys on it, so a
    ///   different string here would ask the writer about one device twice.
    /// - `.revoked`, `.otherRoot` — `.quarantined`, in the verdict's own words,
    ///   exactly as `settling` refuses them. A revoked span then travels
    ///   through `RevocationSplit` like any other refused one, so *keep what
    ///   this Mac had already applied* still keeps it: the lines carry
    ///   `.afterRevocation` as their OWN refusal, which is what makes them
    ///   candidates for the cut.
    /// - `.retired` — nil, and this is the one arm `settling` cannot be matched
    ///   on. Its answer turns on `sealedAt`, and a span no seal has closed has
    ///   no sealed-at: the only two readings are *before it retired* (keep) and
    ///   *at or after it* (refuse). Refusing would set aside the last tail of
    ///   every device that ever retired — the words it wrote while it was still
    ///   in use, since nothing in `RegistryAdmission.retire` seals an op log —
    ///   under a sentence (*written after this device was retired*) that is
    ///   false about them. The arm that cannot lose the retired device's own
    ///   view is therefore to keep. The residue is bounded and stated in
    ///   `AREA.md`: a retired device that goes on writing keeps at most
    ///   `chainSealInterval − 1` ops applied, because the app seals after every
    ///   burst and at every close, and any span it seals after `retiredAt` is
    ///   refused exactly as P2b refuses it.
    /// - `.noChain` — nil, NOT `settling`'s `.unsignedHistory`. Both are
    ///   applied, so nothing about the book changes; what changes is the
    ///   sentence History draws off the count, and a live tail is partly
    ///   unsealed by construction. Calling it unsigned history would put a
    ///   standing notice on every ordinary file. Arm 3's door is this one and
    ///   it stays open.
    ///
    /// A seventh verdict is a compile error here, as it is in `settling`.
    nonisolated func settlingAnUnsealedSpan(sealKey: String) -> OpLogChain.Line.State? {
        switch self {
        case .mine, .admitted: nil
        case let .stranger(device): .pending(device: device ?? sealKey)
        case .revoked, .otherRoot: .quarantined
        case .retired: nil
        case .noChain: nil
        }
    }

    /// **Has this register nothing to say about the key?** (Task 11, fix
    /// round 1.)
    ///
    /// Two verdicts mean it, and which one a reader meets depends on something
    /// other than the key: `.noChain` is what a device with no root of its own
    /// answers about everybody (`TrustTable.verdict` guards on `myRoot` before
    /// it looks anything up), and `.stranger` **with no device** is what a
    /// ROOTED book answers for a key no device record names — which is every
    /// book since P2a, and therefore the one that matters in practice.
    ///
    /// A `.stranger` that DOES name a device is attributable: the register
    /// knows whose key it is and is merely waiting to be told whether to admit
    /// it.
    ///
    /// Its one reader is the arm-2 fall-through, which is why this is a
    /// question about the REGISTER's knowledge rather than about trust.
    nonisolated var isUnattributable: Bool {
        switch self {
        case .noChain: true
        case let .stranger(device): device == nil
        case .mine, .admitted, .revoked, .retired, .otherRoot: false
        }
    }

    /// The words for a refusal, when this verdict is one.
    nonisolated var refusal: OpLogChain.QuarantineCause? {
        switch self {
        case let .revoked(person, mark):
            .afterRevocation(person: person, keptNothing: mark == nil)
        case let .otherRoot(root): .anotherClaimants(root: root)
        case let .retired(device, _): .afterRetirement(device: device)
        case .mine, .admitted, .stranger, .noChain: nil
        }
    }

    /// Whether a signature made under this verdict is a word this device stands
    /// behind — its own, or one its root admitted.
    /// **The only form of this question, and it takes a moment** (fix round 1,
    /// Minor 3). An undated twin stood beside it for one commit with no
    /// production caller, and the next caller to reach for it would have
    /// silently refused a retired device's pre-retirement segment — a signature
    /// that IS that device's word, read as though it were nobody's. A `Date` is
    /// always in hand where this is asked: a segment signature carries `at`,
    /// and so does a seal.
    ///
    /// `sealedAt` is what makes `.retired` answerable at all: a segment signed
    /// before its device stopped is still that device's word, and one signed
    /// after it is not.
    nonisolated public func isOurWord(sealedAt: Date) -> Bool {
        switch self {
        case .mine, .admitted: true
        case let .retired(_, retiredAt): sealedAt < retiredAt
        case .stranger, .revoked, .otherRoot, .noChain: false
        }
    }
}

// MARK: - The absent remembered head

extension OpLogChain {

    /// What a walk that finished clean should be treated as when the head this
    /// device REMEMBERS is nowhere in the file.
    ///
    /// The remembered head is the extra fact only this device has: a line that
    /// chains perfectly is still a stranger if it arrived after it. But the head
    /// can also go missing, and then the walk has nothing to check the file
    /// against — which is the hole the whole-branch review found (I2). An agent
    /// that TRUNCATES the file back to a seal line and appends its own
    /// correctly-chained lines leaves exactly that state: no break, our own
    /// seals, and a head we have never seen. Before this rule the load adopted
    /// that head and remembered it, so the next append chained onto the forgery.
    ///
    /// There is one innocent way to reach the same state, and it is the reason
    /// adoption exists at all: the crash window. `chainedAppend` persists the
    /// new head BEFORE writing the line that hashes to it, so dying between the
    /// two leaves a remembered head no line carries — and the file's own head is
    /// then the one we remembered LAST TIME (`previousHead`). That is the only
    /// signature this rule adopts on.
    ///
    /// Everything else is a file cut short by something that is not this device.
    /// The answer is the last thing this device actually SIGNED: every line
    /// after the last seal whose key we trust is held back, and everything up to
    /// and including that seal applies, because the seal is a signature over the
    /// chain head at that point and nothing before it can have been changed
    /// without breaking the walk. The state is NOT updated — this device does
    /// not take a forged head as its own word.
    ///
    /// **What this does not catch, deliberately.** A device with no key signs
    /// nothing, so there is no trusted seal to fall back to and the rule has
    /// nothing to anchor on; its tail is unsigned history by definition, and
    /// quarantining a whole unsigned file over a missing head would cost the
    /// writer their manuscript to catch nobody. Such a file is left exactly as
    /// the walk found it (ADR 0032 §3).
    ///
    /// Called by BOTH the read (`OpLogStore.classifyTail`) and the write
    /// (`JSONLAppendStore.chainedAppend`), because they have to agree: a load
    /// that holds lines back while the next append chains onto them would leave
    /// the writer's own new ops stranded on the far side of a break forever.
    nonisolated static func resolveAbsentHead(
        _ verification: Verification,
        rememberedHead: String?,
        previousHead: String?
    ) -> (verification: Verification, adoptedHead: String?) {
        guard let rememberedHead,
              let fileHead = verification.head,
              verification.breakReason == nil,
              fileHead != rememberedHead
        else { return (verification, nil) }

        // The crash window, and only it.
        if fileHead == previousHead, verification.foreignSealCount == 0 {
            return (verification, fileHead)
        }

        // Cut short by something else. Fall back to the last thing this device
        // signed; with nothing signed there is nothing to fall back to.
        guard let anchor = lastTrustedSealIndex(verification.lines),
              anchor < verification.lines.count - 1
        else { return (verification, nil) }
        return (quarantining(verification, after: anchor), nil)
    }

    /// The index of the last line that is a seal whose key this device stands
    /// behind — `.verified` is exactly "covered by a seal the caller calls its
    /// own or its root's", and a seal line settles to its own span's state.
    ///
    /// Reachable only for a file this device remembers a head for, which is one
    /// of its own, so in practice the seal it finds is this device's; an
    /// admitted device's seal would anchor here too, and that is right — the
    /// question is what the chain can be trusted back to, not who typed it.
    private nonisolated static func lastTrustedSealIndex(_ lines: [Line]) -> Int? {
        lines.lastIndex { $0.kind == .seal && $0.state == .verified }
    }

    /// **Put back the refused lines a revocation had already applied** — the
    /// mirror of `quarantining(_:after:)`, and the one place a quarantined line
    /// becomes an applied one (find 5, ruled 2026-09-18).
    ///
    /// Every `.quarantined` line whose bytes appear in `lines` is re-settled to
    /// **the state it would have had if nothing had refused it** — `.verified`
    /// where a seal covers it, `.unsealed` where none ever did (Task 11's fix
    /// round 1; `Line.coveredByASeal`). Re-admitting an unsealed line as
    /// `.verified` would tell the writer's History pane that bytes no signature
    /// covers are verified, which is the same misstatement
    /// `settlingAnUnsealedSpan` refuses to make in the other direction. The
    /// tallies and `quarantined` are rebuilt off the states, and the cause is
    /// dropped when nothing is refused any more — a verification that holds
    /// nothing back must not go on naming a reason for holding it.
    ///
    /// **The head does not move**, and that is deliberate rather than an
    /// oversight. `Verification.head` is what the next chained APPEND builds
    /// on, and it is shared with the write through `resolveAbsentHead`; a
    /// re-admitted line is not a suffix, so moving the head onto one would put
    /// the writer's next op behind lines this device will never append after.
    /// Re-admission decides what the DOCUMENT is made of, not what the file's
    /// next line chains onto — and this device never appends to another
    /// device's file (ADR 0012).
    ///
    /// **Nothing is newly trusted.** The lines named here are ones the caller
    /// established this Mac had already applied while their device was
    /// admitted. See `RevocationSplit`.
    nonisolated static func readmitting(
        _ verification: Verification, lines readmitted: [Data]
    ) -> Verification {
        guard !readmitted.isEmpty else { return verification }
        let keep = Set(readmitted)
        var lines = verification.lines
        for index in lines.indices
        where lines[index].state == .quarantined && keep.contains(lines[index].bytes) {
            lines[index].settle(lines[index].stateIfNothingHadRefusedIt)
        }
        let counted = tallies(of: lines)
        return Verification(
            lines: lines,
            // Unmoved, on purpose — see above.
            head: verification.head,
            legacyCount: counted.legacy,
            verifiedCount: counted.verified,
            unsealedCount: counted.unsealed,
            pendingCount: counted.pending,
            foreignSealCount: verification.foreignSealCount,
            quarantined: counted.quarantined,
            breakReason: verification.breakReason,
            // A verification holding nothing back names no reason for holding
            // it: `quarantineReason` would otherwise put a sentence on a file
            // that kept every line.
            quarantineCause: counted.quarantined.isEmpty
                ? nil : verification.quarantineCause)
    }

    /// **Take applied lines OUT of the book, one by one** — `readmitting`'s
    /// mirror, and the one door the permit partition re-settles through
    /// (P3 spec §4.3). `Line.settle` is `fileprivate`, so a partition living
    /// anywhere else has to come here, which is what keeps the states this
    /// file defines decided in this file.
    ///
    /// Keyed by INDEX rather than by bytes, unlike `readmitting`: two
    /// identical lines in one file are not a shape the chain can produce, but
    /// a rule that refuses one line and not the other is a rule that has to be
    /// able to say which, and an index can while a byte set cannot.
    ///
    /// - `refusing` quarantines a line with its OWN cause, because a permit
    ///   partition can refuse two lines of one file for two different reasons
    ///   (a manuscript line and a task, or the same line before and after a
    ///   mark) and `setAside` files one record per cause.
    /// - `holding` holds a line PENDING under a device — an unjudgeable kind,
    ///   an unreadable role, a piece nobody has claimed yet. Held, never
    ///   recorded: nothing is wrong with it.
    ///
    /// **The head does not move**, for `readmitting`'s reason exactly:
    /// `Verification.head` is what the next chained append builds on and is
    /// shared with the write through `resolveAbsentHead`. Refusing a line
    /// decides what the DOCUMENT is made of, not what the file's next line
    /// chains onto — and the bytes on disk are untouched by any of this.
    nonisolated static func repartitioned(
        _ verification: Verification,
        refusing: [Int: QuarantineCause],
        holding: [Int: String]
    ) -> Verification {
        guard !refusing.isEmpty || !holding.isEmpty else { return verification }
        var lines = verification.lines
        for (index, cause) in refusing where lines.indices.contains(index) {
            lines[index].settle(.quarantined, because: cause)
        }
        for (index, device) in holding
        where lines.indices.contains(index) && refusing[index] == nil {
            lines[index].settle(.pending(device: device))
        }
        let counted = tallies(of: lines)
        return Verification(
            lines: lines,
            // Unmoved, on purpose — see above.
            head: verification.head,
            legacyCount: counted.legacy,
            verifiedCount: counted.verified,
            unsealedCount: counted.unsealed,
            pendingCount: counted.pending,
            foreignSealCount: verification.foreignSealCount,
            quarantined: counted.quarantined,
            breakReason: verification.breakReason,
            // One cause per verification and it is the FIRST one met — the
            // walk's own, where it had one, else the earliest line this
            // partition refused. It is only ever a fallback for a line with no
            // refusal of its own; `setAside` reads the LINE's cause first.
            quarantineCause: counted.quarantined.isEmpty
                ? nil
                : (verification.quarantineCause
                    ?? refusing.min(by: { $0.key < $1.key })?.value))
    }

    /// The four counts and the refused bytes, taken off the line states — one
    /// derivation, shared by the two functions that re-settle lines, so a new
    /// `Line.State` is a compile error in one place rather than a silent zero
    /// in two.
    private nonisolated static func tallies(
        of lines: [Line]
    ) -> (legacy: Int, verified: Int, unsealed: Int, pending: Int, quarantined: [Data]) {
        var legacy = 0, verified = 0, unsealed = 0, pending = 0
        var quarantined: [Data] = []
        for line in lines {
            switch line.state {
            case .legacy: legacy += 1
            case .verified: verified += 1
            case .unsealed: unsealed += 1
            case .pending: pending += 1
            case .unsignedHistory: break
            case .tornTail: break
            case .quarantined: quarantined.append(line.bytes)
            }
        }
        return (legacy, verified, unsealed, pending, quarantined)
    }

    /// Rebuild the verdict with every line after `anchor` quarantined. The head
    /// becomes the anchor's own hash, which keeps `Verification.head`'s one
    /// invariant true: it is the hash of the last line that was APPLIED.
    private nonisolated static func quarantining(
        _ verification: Verification, after anchor: Int
    ) -> Verification {
        let cutShort = BreakReason.cutShortBeforeRememberedHead(lineIndex: anchor + 1)
        var lines = verification.lines
        for index in (anchor + 1)..<lines.count {
            // Refused by the TRUNCATION, not by whatever the file's first cause
            // was: these lines are held back because this device cannot vouch
            // for anything past the last seal it trusts, and no op id talks one
            // of them back in (find-5 review, the Critical's second route).
            lines[index].settle(.quarantined, because: .chainBroke(cutShort))
        }

        let counted = tallies(of: lines)
        return Verification(
            lines: lines,
            head: lineHash(lines[anchor].bytes),
            legacyCount: counted.legacy,
            verifiedCount: counted.verified,
            unsealedCount: counted.unsealed,
            pendingCount: counted.pending,
            // Carried, never recounted. `foreignSealCount` is a fact about the
            // SEALS in the file — how many were made by a key this device does
            // not call its own — and holding lines back does not change who
            // signed them. Recounting it off the states would also be a second
            // definition of the word, and a quieter one: `.verified` covers an
            // admitted device's seal, which the walk counts as foreign.
            foreignSealCount: verification.foreignSealCount,
            quarantined: counted.quarantined,
            breakReason: cutShort,
            // A cause the walk already found stands: it happened first, and it
            // is the one that explains lines this truncation did not touch.
            quarantineCause: verification.quarantineCause ?? .chainBroke(cutShort))
    }
}
