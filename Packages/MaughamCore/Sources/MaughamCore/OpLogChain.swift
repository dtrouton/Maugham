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
/// `.unsignedHistory` or `.quarantined`, and the caller decides what to apply.
/// It holds no policy about WHO is trusted — that is the `trusted` closure —
/// and no memory of its own; the remembered head is a parameter.
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
        bytes.map { String(format: "%02x", $0) }.joined()
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

    // MARK: - Reading a line's prev

    /// The line's `prev`, read TEXTUALLY off the first key — the format fixes
    /// its position, so a full JSON decode would be both slower and wrong
    /// (a legacy line carrying a `prev` further in is still unchained).
    ///
    /// The double optional is two different answers: the outer `nil` means this
    /// is not a JSON object we can read at all, the inner `nil` means it is an
    /// object whose first key is not `prev`. Both are unchained to the walk;
    /// the distinction is for callers that want to say which.
    public nonisolated static func prev(ofLine line: Data) -> String?? {
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
            guard let publicKey = identity.publicKey else { throw DeviceIdentityError.unsigned }
            guard let headBytes = OpLogChain.hexDecode(head) else {
                preconditionFailure("a chain head is a hex digest — got \(head)")
            }
            let seal = Seal(
                at: at,
                head: head,
                key: DeviceIdentity.fingerprint(of: publicKey),
                pub: publicKey.x963Representation.base64EncodedString(),
                sig: try identity.sign(headBytes).base64EncodedString())

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
            guard let publicKeyBytes = Data(base64Encoded: pub),
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyBytes)
            else { return false }
            guard DeviceIdentity.fingerprint(of: publicKey) == key else { return false }
            guard let signatureBytes = Data(base64Encoded: sig),
                  let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
            else { return false }
            guard let headBytes = OpLogChain.hexDecode(head) else { return false }
            return publicKey.isValidSignature(signature, for: headBytes)
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
            /// Covered by a seal from a key the caller does not trust. Applied
            /// (P1 has no registry) — but never claimed as this device's word.
            case unsignedHistory
            /// Never applied: the chain broke at or before this line.
            case quarantined
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
        /// Seals that held together under a key the caller does not trust.
        public let foreignSealCount: Int
        /// The raw bytes of every quarantined line, in file order.
        public let quarantined: [Data]
        public let breakReason: BreakReason?
    }

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
    ///    every `.unsealed` line since the last seal: `.verified` when
    ///    `trusted(seal.key)`, `.unsignedHistory` when not.
    public nonisolated static func verify(
        bytes: Data,
        trusted: (String) -> Bool,
        rememberedHead: String?
    ) -> Verification {
        var lines: [Line] = []
        var head: String?
        var sawChainOrSeal = false
        var spanStart = 0
        var breakReason: BreakReason?
        var foreignSealCount = 0
        var reachedRememberedHead = false

        for raw in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if raw.isEmpty { continue }
            let line = Data(raw)
            let index = lines.count
            let kind: Line.Kind = isSealLine(line) ? .seal : .op

            if breakReason != nil {
                lines.append(Line(bytes: line, kind: kind, state: .quarantined))
                continue
            }
            if reachedRememberedHead {
                breakReason = .afterRememberedHead(lineIndex: index)
                lines.append(Line(bytes: line, kind: kind, state: .quarantined))
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
                        breakReason = .prevMismatch(lineIndex: index)
                        lines.append(Line(bytes: line, kind: kind, state: .quarantined))
                        continue
                    }
                    sawChainOrSeal = true
                    lines.append(Line(bytes: line, kind: kind, state: .unsealed))
                } else {
                    guard !sawChainOrSeal else {
                        breakReason = .unchainedAfterChain(lineIndex: index)
                        lines.append(Line(bytes: line, kind: kind, state: .quarantined))
                        continue
                    }
                    lines.append(Line(bytes: line, kind: kind, state: .legacy))
                }

            case .seal:
                guard let seal = Seal.parse(line) else {
                    breakReason = .sealSignatureInvalid(lineIndex: index)
                    lines.append(Line(bytes: line, kind: kind, state: .quarantined))
                    continue
                }
                // Deliberately NOT `head ?? genesis`: a seal must follow at
                // least one line, so a seal as the first line of a file has
                // nothing to seal and names a head that was never reached.
                guard seal.head == head else {
                    breakReason = .sealHeadMismatch(lineIndex: index)
                    lines.append(Line(bytes: line, kind: kind, state: .quarantined))
                    continue
                }
                guard seal.verifies() else {
                    breakReason = .sealSignatureInvalid(lineIndex: index)
                    lines.append(Line(bytes: line, kind: kind, state: .quarantined))
                    continue
                }
                let isTrusted = trusted(seal.key)
                if !isTrusted { foreignSealCount += 1 }
                let settled: Line.State = isTrusted ? .verified : .unsignedHistory
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

        return Verification(
            lines: lines,
            head: head,
            legacyCount: lines.filter { $0.state == .legacy }.count,
            verifiedCount: lines.filter { $0.state == .verified }.count,
            unsealedCount: lines.filter { $0.state == .unsealed }.count,
            foreignSealCount: foreignSealCount,
            quarantined: lines.filter { $0.state == .quarantined }.map(\.bytes),
            breakReason: breakReason)
    }
}
