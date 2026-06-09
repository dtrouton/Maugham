import Foundation

public struct Checkpoint: Codable, Equatable, Hashable, Sendable {
    public let checkpointId: String
    public let label: String
    public let labelSource: LabelSource
    public let at: Date
    public let device: String
    public let activeDoc: String
    public let docPointers: [String: String]   // doc_id -> op_id
    public let manuscriptWordCount: Int

    public enum LabelSource: String, Codable, Hashable, Sendable {
        case user, auto

        /// Cross-version forward-tolerance (ADR 0015): an unknown label source
        /// from a newer build decodes to `.auto` rather than throwing (which
        /// would quarantine the whole checkpoint row). `.auto` is the benign
        /// default — checkpoints are forensic; the only consumer distinction is
        /// a cosmetic label.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = LabelSource(rawValue: raw) ?? .auto
        }
    }

    enum CodingKeys: String, CodingKey {
        case checkpointId = "checkpoint_id"
        case label
        case labelSource = "label_source"
        case at, device
        case activeDoc = "active_doc"
        case docPointers = "doc_pointers"
        case manuscriptWordCount = "manuscript_word_count"
    }

    public init(
        checkpointId: String, label: String, labelSource: LabelSource,
        at: Date, device: String, activeDoc: String,
        docPointers: [String: String], manuscriptWordCount: Int
    ) {
        self.checkpointId = checkpointId
        self.label = label
        self.labelSource = labelSource
        self.at = at
        self.device = device
        self.activeDoc = activeDoc
        self.docPointers = docPointers
        self.manuscriptWordCount = manuscriptWordCount
    }
}
