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
}
