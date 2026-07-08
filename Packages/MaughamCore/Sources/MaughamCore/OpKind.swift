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

    // Inverse of claudeAccept's "two effects, one op": restores the pre-accept
    // paragraph text (when `changes` is populated — the Mac ⌘Z path) and
    // returns the annotation's derived status to `.open`. The rewind path
    // appends it with EMPTY changes (status-only reopen: the checkpointRestore
    // already reverted the text; a second text-apply would fight it). The
    // derive loop only folds `op.changes`, so the empty-changes variant is
    // inherently a manuscript no-op despite the `appliesToManuscript` yes.
    case claudeAcceptRevert = "claude_accept_revert"

    // Author self-service lifecycle: a reviewer editing or withdrawing THEIR
    // OWN annotation. Both reference `provenance.sourceAnnotationId` = the
    // creation op id. `annotationEdit` carries the new `annotationBody` (and,
    // for a suggestedChange, the new replacement in `changes.first.next` —
    // mirroring how the original suggestion stores its replacement). The op
    // log stays append-only; the creation op is never mutated. `.unknown`
    // decode fallback means older builds tolerate these inertly.
    case annotationEdit     = "annotation_edit"
    case annotationWithdraw = "annotation_withdraw"

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
    /// becomes a compile error forcing the dev to classify it. See ADR 0015.
    ///
    /// SCHEMA CONTRACT (ADR 0015, audit N4): **adding a case ⇒ bump
    /// `ProjectManifest.currentSchemaVersion`.** `decodeGuardingSchema` is the
    /// real protection (it refuses a genuinely-newer-schema file up front); this
    /// `.unknown` tolerance is only the within-version safety net. `.unknown`
    /// re-encodes LOSSILY as the literal `"unknown"` (the synthesized String-raw
    /// encoder has no memory of the original raw value) — harmless for the
    /// append-only op log (ops aren't rewritten), but the bump is what guarantees
    /// an old build never silently degrades a newer file it then re-saves.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OpKind(rawValue: raw) ?? .unknown
    }
}
