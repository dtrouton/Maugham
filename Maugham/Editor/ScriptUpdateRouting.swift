import Foundation
import MaughamCore

/// Origin-scoping for the `.maughamScriptDidUpdate` notification (Channel A).
///
/// The post carries the parsed `FountainScript` as its `object` and the
/// originating project's identity in `userInfo` under `projectIdKey`. A
/// `ProjectWindow` receiver adopts the script ONLY when the origin matches its
/// own project — otherwise an unrelated window flipping to a screenplay piece
/// would invalidate this window's editor (a whole-doc NavigationStack relayout
/// of the bound editor) AND clobber its scene-navigator payload. The scope is
/// the project id (`ProjectIdentifier.id(for:)`), NOT a key-window guard: a
/// background window's own MCP-driven re-parse must still update its navigator.
///
/// See ADR 0017 addendum and `Maugham/Editor/AREA.md`.
enum ScriptUpdateRouting {
    /// `userInfo` key carrying the origin project id (`ProjectIdentifier.id`).
    static let projectIdKey = "project_id"

    /// Returns the notification's `FountainScript` iff it originated from
    /// `projectId`; `nil` for a foreign or unscoped post.
    static func acceptedScript(
        from note: Notification, forProjectId projectId: String
    ) -> FountainScript? {
        guard let script = note.object as? FountainScript,
              let originId = note.userInfo?[projectIdKey] as? String,
              originId == projectId
        else { return nil }
        return script
    }
}
