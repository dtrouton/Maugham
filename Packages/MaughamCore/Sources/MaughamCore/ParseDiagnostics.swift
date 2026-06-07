import Foundation

/// What a JSONL load skipped. A skipped line is one that failed to decode into
/// `Element` — historically dropped silently (`try? decode else continue`). This
/// turns that silent drop into reportable data so corruption can be surfaced and
/// quarantined instead of vanishing.
public struct ParseDiagnostics: Sendable, Equatable {
    public struct SkippedLine: Sendable, Equatable {
        /// Best-effort byte offset of the line start within the file. Assumes
        /// single `\n` separators; a forensic hint, not a guarantee.
        public let byteOffset: Int
        /// The raw line text (or "<non-utf8>" if it wasn't decodable as UTF-8).
        public let raw: String
        public init(byteOffset: Int, raw: String) {
            self.byteOffset = byteOffset
            self.raw = raw
        }
    }
    public var skipped: [SkippedLine]
    public init(skipped: [SkippedLine] = []) { self.skipped = skipped }
    public var isClean: Bool { skipped.isEmpty }
}
