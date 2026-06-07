import Foundation

/// Pure, allocation-light consistency checks over already-loaded data. No file I/O
/// here (callers supply the loaded ops/checkpoints/filenames) so each check is a
/// trivially testable function.
public enum IntegrityChecks {
    public struct DanglingPointer: Equatable, Sendable {
        public let checkpointId: String
        public let docId: String
        public let opId: String
        public init(checkpointId: String, docId: String, opId: String) {
            self.checkpointId = checkpointId
            self.docId = docId
            self.opId = opId
        }
    }

    /// Checkpoint `docPointers` that reference an op id not present in that doc's
    /// known op set — evidence the op log lost ops (corruption or a dropped twin).
    public static func danglingCheckpointPointers(
        checkpoints: [Checkpoint], opsByDoc: [String: Set<String>]
    ) -> [DanglingPointer] {
        var result: [DanglingPointer] = []
        for cp in checkpoints {
            for (docId, opId) in cp.docPointers.sorted(by: { $0.key < $1.key }) {
                if !(opsByDoc[docId]?.contains(opId) ?? false) {
                    result.append(.init(checkpointId: cp.checkpointId, docId: docId, opId: opId))
                }
            }
        }
        return result
    }

    /// Filenames that look like iCloud conflict copies (`"... N.jsonl"`, a space +
    /// integer before the extension). Their presence means iCloud resolved a
    /// concurrent append by dropping a sibling — silent data loss (tripwire 17).
    public static func conflictTwins(inOpsDirectoryFilenames names: [String]) -> [String] {
        names.filter { name in
            guard name.hasSuffix(".jsonl") else { return false }
            let stem = name.dropLast(".jsonl".count)
            return stem.range(of: #" \d+$"#, options: .regularExpression) != nil
        }
    }

    public struct InvalidParagraphId: Equatable, Sendable {
        public let docId: String
        public let opId: String
        public let value: String
        public init(docId: String, opId: String, value: String) {
            self.docId = docId
            self.opId = opId
            self.value = value
        }
    }

    /// Ops carrying a paragraph id (in `changes` or `sequence`) that is empty or
    /// contains characters no real id can hold — whitespace, control characters, or
    /// markup (`<`/`>`). This is *semantic* corruption that still parses as valid
    /// JSON (e.g. a value emptied or truncated in the op log), which the JSON-decode
    /// check can't see.
    ///
    /// Deliberately conservative: it does NOT enforce the canonical 4-char alphabet,
    /// because the in-memory paragraph-id APIs are permissive by design (tripwire 8)
    /// and a stricter rule could false-positive and block every backup. It only
    /// flags ids that are unambiguously garbage.
    public static func invalidParagraphIds(inOps ops: [Op]) -> [InvalidParagraphId] {
        var result: [InvalidParagraphId] = []
        for op in ops {
            let ids = op.changes.map(\.paragraphId) + (op.sequence ?? [])
            for id in ids where !isPlausibleParagraphId(id) {
                result.append(.init(docId: op.docId, opId: op.opId, value: id))
            }
        }
        return result
    }

    /// A paragraph id is "plausible" if it's non-empty and contains no character a
    /// real id could never hold. Not a format check — a corruption smell test.
    static func isPlausibleParagraphId(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return !id.unicodeScalars.contains { s in
            s.value < 0x20 || s == " " || s == "<" || s == ">" || s.value == 0x7f
        }
    }
}
