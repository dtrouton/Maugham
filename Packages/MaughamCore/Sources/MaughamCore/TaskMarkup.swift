import Foundation

/// Single source of truth for "does this text contain inline-task markup".
///
/// Three call sites independently re-implemented this substring test and
/// drifted: the OpLog cache-invalidation gate
/// (`Document.changeTouchesTaskMarkup`) and the anchor-alignment
/// move-detector (`TaskAnchorAlignment.lineCarriesTaskMarker`) only
/// recognized lowercase `- [x]`, while `TasksPane`'s inline-checkbox flip
/// helper already treated `- [X]` (uppercase) as a valid checked marker. The
/// result: a writer's `- [X]` didn't trip the tasks-cache invalidation fast
/// path even though the pane could flip it. All three sites — plus any
/// future one — should consume this predicate rather than re-deriving it.
///
/// Recognizes:
/// - Markdown checkbox `- [ ]` / `- [x]` / `- [X]` (3-char bracket glyph)
/// - Fountain boneyard `[[todo: …]]` / `[[done: …]]`
///
/// This is a cheap presence test, not a parser — it doesn't validate
/// position or well-formedness. Callers that need structured extraction
/// (checked state, body, anchor id, ranges for click-routing) use
/// `MarkdownCheckboxScanner` / `FountainBoneyardScanner` instead; those
/// return match data this boolean can't express, so they keep their own
/// regexes rather than being force-fit onto this predicate.
/// `MarkdownCheckboxScanner`'s regex accepts `- [x]` and `- [X]` alike, so
/// detection here and derivation there agree on the uppercase form (Task 22b).
public enum TaskMarkup {
    public static func lineContainsTaskMarker(_ line: String) -> Bool {
        return line.contains("- [ ]") || line.contains("- [x]") || line.contains("- [X]")
            || line.contains("[[todo:") || line.contains("[[done:")
    }
}
