import Foundation

/// Who, on this device, wrote an op.
///
/// A device is not one writer. The person types; Claude answers through MCP;
/// the translation pipeline files a round; the app rebalances task priorities
/// on nobody's instruction. Before this, all four appended under one device key
/// and the role — where it was recorded at all — was a label beside the op that
/// anything could have written.
///
/// So the role lives in the KEY. Each actor holds its own Secure Enclave key
/// under `DeviceState.directory`, and its own device id `<actor>-<16 hex>`; an
/// op signed by the translator's key was written by the translator, and no
/// string in the record can claim otherwise. The author's id carries its prefix
/// too, so a per-device file reads as itself: `<doc>.author-<16hex>-<8hex>.jsonl`.
///
/// **Closed, and exhaustively switched over.** The raw value is both the id
/// prefix and the key-file suffix, so a fifth actor is a spec amendment (and a
/// new file on disk) rather than a case added in passing. Nothing switches over
/// this enum with a `default`.
///
/// Ruled by Denver 2026-09-08 on the P1 handoff's decision #7: *"lets use the
/// terminology 'assistant' for anything through the mcp … translations get a
/// special role of 'translator' … optimisations should be signed as Maugham
/// itself … search and replace is an automation of the writer."*
public enum DeviceActor: String, CaseIterable, Sendable, Codable {
    /// The writer's own acts — the editor, checkpoints, statements, and the
    /// automations of their hand (wiki-rename, search-and-replace). The phone
    /// is this and nothing else.
    case author

    /// Anything arriving through MCP: Claude's annotations, tasks, notes.
    case assistant

    /// The translation pipeline and `write_translation`. Not the Translation
    /// Review pane's own edits — those are the writer's, and sign as `author`.
    case translator

    /// The app acting on its own behalf, on nobody's instruction: the task
    /// priority rebalance.
    case maugham
}
