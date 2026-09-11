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

        public init(bytes: Data, kind: Kind, state: State) {
            self.bytes = bytes
            self.kind = kind
            self.state = state
        }

        /// Only the walk in this file promotes a span when its seal arrives.
        fileprivate mutating func settle(_ state: State) { self.state = state }
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
        case afterRevocation(person: String)
        /// A seal from a second self-signed root's chain: listed, never merged.
        case anotherClaimants(root: String)
        /// A seal made at or after the moment that DEVICE said it had stopped
        /// writing (spec §5). Its earlier spans are untouched — this is the one
        /// cause whose subject is a date rather than a key.
        case afterRetirement(device: String)
        /// A line from a revoked key that the revocation had ALREADY applied —
        /// its opId is at or below the `highestOpIdSeen` the root recorded. It
        /// is refused like everything else that key sealed, and it is not the
        /// same accusation: it may be late sync, or it may be backdated, and
        /// the writer is owed the difference.
        ///
        /// Produced by `OpLogStore`'s tail classification and never by the walk
        /// below, which sees seals and not opIds — the split is made from the
        /// number the revocation recorded, one layer up (ADR 0032 §6).
        case revocationLate(person: String)
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
    ///
    /// **A refused span does not break the chain.** A verdict is about WHOSE
    /// word a span is, not about whether the bytes follow from each other, so
    /// the walk goes on and a later span from an admitted key still applies.
    /// That is also why quarantined lines are no longer necessarily a suffix on
    /// this path — `applied` filters by state and never by position, and the
    /// chained WRITE (whose rewrite does assume a prefix) judges by `.mine`
    /// alone, so it cannot produce one of these.
    public nonisolated static func verify(
        bytes: Data,
        trust: (String) -> TrustVerdict,
        rememberedHead: String?
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

            if breakReason != nil {
                lines.append(Line(bytes: line, kind: kind, state: .quarantined))
                continue
            }
            if reachedRememberedHead {
                broke(.afterRememberedHead(lineIndex: index))
                lines.append(Line(bytes: line, kind: kind, state: .quarantined))
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
                        broke(.prevMismatch(lineIndex: index))
                        lines.append(Line(bytes: line, kind: kind, state: .quarantined))
                        continue
                    }
                    sawChainOrSeal = true
                    lines.append(Line(bytes: line, kind: kind, state: .unsealed))
                } else {
                    guard !sawChainOrSeal else {
                        broke(.unchainedAfterChain(lineIndex: index))
                        lines.append(Line(bytes: line, kind: kind, state: .quarantined))
                        continue
                    }
                    lines.append(Line(bytes: line, kind: kind, state: .legacy))
                }

            case .seal:
                guard let seal = Seal.parse(line) else {
                    broke(.sealSignatureInvalid(lineIndex: index))
                    lines.append(Line(bytes: line, kind: kind, state: .quarantined))
                    continue
                }
                // Deliberately NOT `head ?? genesis`: a seal must follow at
                // least one line, so a seal as the first line of a file has
                // nothing to seal and names a head that was never reached.
                guard seal.head == head else {
                    broke(.sealHeadMismatch(lineIndex: index))
                    lines.append(Line(bytes: line, kind: kind, state: .quarantined))
                    continue
                }
                guard seal.verifies() else {
                    broke(.sealSignatureInvalid(lineIndex: index))
                    lines.append(Line(bytes: line, kind: kind, state: .quarantined))
                    continue
                }
                let verdict = trust(seal.key)
                if verdict != .mine { foreignSealCount += 1 }
                // The seal's own moment, because one verdict — `.retired` —
                // answers differently before and after a date, and this is the
                // only place that knows when a seal was made.
                let settled = verdict.settling(sealKey: seal.key, sealedAt: seal.at)
                if settled == .quarantined, cause == nil {
                    cause = verdict.refusal
                }
                for covered in spanStart..<index where lines[covered].state == .unsealed {
                    lines[covered].settle(settled)
                }
                lines.append(Line(bytes: line, kind: kind, state: settled))
                sawChainOrSeal = true
                spanStart = index + 1
            }

            head = lineHash(line)
            if let rememberedHead, head == rememberedHead { reachedRememberedHead = true }
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

    /// The words for a refusal, when this verdict is one.
    nonisolated var refusal: OpLogChain.QuarantineCause? {
        switch self {
        case let .revoked(person, _): .afterRevocation(person: person)
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

    /// Rebuild the verdict with every line after `anchor` quarantined. The head
    /// becomes the anchor's own hash, which keeps `Verification.head`'s one
    /// invariant true: it is the hash of the last line that was APPLIED.
    private nonisolated static func quarantining(
        _ verification: Verification, after anchor: Int
    ) -> Verification {
        var lines = verification.lines
        for index in (anchor + 1)..<lines.count {
            lines[index].settle(.quarantined)
        }

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

        let cutShort = BreakReason.cutShortBeforeRememberedHead(lineIndex: anchor + 1)
        return Verification(
            lines: lines,
            head: lineHash(lines[anchor].bytes),
            legacyCount: legacyCount,
            verifiedCount: verifiedCount,
            unsealedCount: unsealedCount,
            pendingCount: pendingCount,
            // Carried, never recounted. `foreignSealCount` is a fact about the
            // SEALS in the file — how many were made by a key this device does
            // not call its own — and holding lines back does not change who
            // signed them. Recounting it off the states would also be a second
            // definition of the word, and a quieter one: `.verified` covers an
            // admitted device's seal, which the walk counts as foreign.
            foreignSealCount: verification.foreignSealCount,
            quarantined: quarantined,
            breakReason: cutShort,
            // A cause the walk already found stands: it happened first, and it
            // is the one that explains lines this truncation did not touch.
            quarantineCause: verification.quarantineCause ?? .chainBroke(cutShort))
    }
}
