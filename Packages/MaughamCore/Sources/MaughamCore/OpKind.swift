import Foundation

public enum OpKind: String, Codable, Equatable, Sendable {
    case typingBurst = "typing_burst"
    case claudeSuggestion = "claude_suggestion"
    case claudeAccept = "claude_accept"
    case claudeReject = "claude_reject"
    case externalEdit = "external_edit"
    case checkpoint
    case checkpointRestore = "checkpoint_restore"
    case bootstrap

    // Annotation creation kinds
    case claudeComment = "claude_comment"
    case claudeQuery = "claude_query"
    case claudeCraftNote = "claude_craft_note"

    // Annotation lifecycle (claudeAccept/claudeReject already exist above)
    case claudeArchive = "claude_archive"

    // Task lifecycle (pane-created tasks; inline status changes use .typingBurst)
    case taskCreate         = "task_create"
    case taskStatusChange   = "task_status_change"
    case taskPriorityChange = "task_priority_change"
    case taskParentChange   = "task_parent_change"
    case taskBodyEdit       = "task_body_edit"
    case taskArchive        = "task_archive"

    /// Cross-version forward-tolerance: an op kind written by a *newer* build
    /// decodes to `.unknown` instead of throwing (which would quarantine the
    /// whole op line and silently drop the edits it carried). The op is kept,
    /// inert — `Deriver.appliesToManuscript` treats `.unknown` as
    /// non-manuscript, so it never corrupts derived text. The app never
    /// *creates* an `.unknown` op (it only arises on decode of a
    /// newer-build raw value), so the degrade-and-resave round-trip can't
    /// manufacture one; a future real kind must be a named case, and the
    /// exhaustive switch over `OpKind` (`Deriver.appliesToManuscript`) then
    /// becomes a compile error forcing the dev to classify it. See ADR 0014.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OpKind(rawValue: raw) ?? .unknown
    }
}
