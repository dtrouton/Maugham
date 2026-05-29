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
}
