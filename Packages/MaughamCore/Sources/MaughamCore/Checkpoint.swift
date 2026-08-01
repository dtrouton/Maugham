import Foundation

public struct Checkpoint: Codable, Equatable, Hashable, Sendable {
    public let checkpointId: String
    public let label: String
    public let labelSource: LabelSource
    public let at: Date
    public let device: String

    /// The manuscript document the writer was in when the checkpoint was taken,
    /// or `nil` when they were in none.
    ///
    /// **Optional because the window's subject is not always a document.** A
    /// group, and — since the binder gained a project row — the project itself
    /// can be what the tree names, and ⌘S records whatever that was. The value
    /// reaches the writer's eye through the auto-label's parenthetical and
    /// `PartialRestorePicker`, which seeds its scope from it; a group id or a
    /// `"__no-selection__"` in this slot made both of those name a document that
    /// does not exist. `CheckpointCapture.documentSubject(of:in:)` is where the
    /// write side decides.
    ///
    /// **Reading one is not the same as trusting one.** Older records on disk
    /// still hold a group id or the sentinel (tripwire 11: no migration), and a
    /// document recorded honestly may since have been deleted. Any consumer
    /// treating this as a document must test it against the project's document
    /// census — this type has never seen the structure and cannot.
    public let activeDoc: String?
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

    /// **`active_doc` is optional in memory and always present on the wire, and
    /// the asymmetry is deliberate.**
    ///
    /// Decoding is tolerant three ways: a missing key, an empty string and a
    /// JSON `null` all mean *no document*. Encoding writes `""` for `nil`
    /// rather than omitting the key, because a project folder is routinely
    /// touched by two app versions at once (ADR 0015's premise) and an older
    /// build's synthesized decoder reads `active_doc` **non-optionally** — a
    /// missing key throws there, `JSONLAppendStore.parse` quarantines the line,
    /// and the whole checkpoint vanishes from that build's History. `""`
    /// decodes on the older build as an id matching no document, which is
    /// precisely what the sentinel it replaces already did, so nothing about
    /// that build gets worse.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkpointId = try c.decode(String.self, forKey: .checkpointId)
        label = try c.decode(String.self, forKey: .label)
        labelSource = try c.decode(LabelSource.self, forKey: .labelSource)
        at = try c.decode(Date.self, forKey: .at)
        device = try c.decode(String.self, forKey: .device)
        let rawActiveDoc = try c.decodeIfPresent(String.self, forKey: .activeDoc)
        activeDoc = (rawActiveDoc?.isEmpty == true) ? nil : rawActiveDoc
        docPointers = try c.decode([String: String].self, forKey: .docPointers)
        manuscriptWordCount = try c.decode(Int.self, forKey: .manuscriptWordCount)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(checkpointId, forKey: .checkpointId)
        try c.encode(label, forKey: .label)
        try c.encode(labelSource, forKey: .labelSource)
        try c.encode(at, forKey: .at)
        try c.encode(device, forKey: .device)
        try c.encode(activeDoc ?? "", forKey: .activeDoc)
        try c.encode(docPointers, forKey: .docPointers)
        try c.encode(manuscriptWordCount, forKey: .manuscriptWordCount)
    }

    public init(
        checkpointId: String, label: String, labelSource: LabelSource,
        at: Date, device: String, activeDoc: String?,
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
