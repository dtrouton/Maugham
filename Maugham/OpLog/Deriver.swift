// Maugham/OpLog/Deriver.swift
import Foundation

public enum Deriver {
    public struct DerivedState: Equatable, Sendable {
        public let paragraphs: [String: String]
        public let sequence: [String]
        public init(paragraphs: [String: String], sequence: [String]) {
            self.paragraphs = paragraphs
            self.sequence = sequence
        }
    }

    /// Fold ops in the given order into a paragraph_id → text map and the
    /// current sequence. Caller sorts by `op_id` first.
    public static func derive(ops: [Op]) -> DerivedState {
        var paragraphs: [String: String] = [:]
        var sequence: [String] = []
        for op in ops {
            for change in op.changes {
                paragraphs[change.paragraphId] = change.next
            }
            if let s = op.sequence {
                sequence = s
            }
        }
        return DerivedState(paragraphs: paragraphs, sequence: sequence)
    }
}
