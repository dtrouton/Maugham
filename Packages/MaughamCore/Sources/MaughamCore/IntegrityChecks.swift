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
}
