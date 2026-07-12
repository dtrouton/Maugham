import Foundation

/// Byte-budget guard for **text** MCP tool responses (ADR 0004 / tripwire 10).
///
/// The 1 MB cap is a property of the JSON-RPC *line* the socket writes, not of
/// any one tool. Image tools have enforced their own budget for a long time
/// (`ImageResponseBuilder`, 720 KB raw JPEG); text tools historically did not,
/// so `read_document` on a novel emitted the whole manuscript unbounded and the
/// transport silently choked (E4, 2026-07-11 maintainability review). This type
/// closes that gap: `enforce` fails loudly with a structured `payload_too_large`
/// error the caller can act on, instead of a truncated or dropped line.
///
/// **Why 900 KB and not 1 MB.** The enforced payload is the tool's raw result
/// `Data` (e.g. an encoded `DocumentContent`). Before it reaches the socket,
/// `MCPToolsCallHandler` embeds it as the *string* value of a `text` content
/// block — i.e. it is JSON-escaped a second time — and wraps it in the tool
/// result + JSON-RPC envelopes (~150 bytes of structure). Re-escaping expands
/// realistic manuscript/research text only marginally (a `\n` inside the inner
/// JSON becomes `\\n`, structural `"` become `\"`; prose carries few of either,
/// and curly quotes are multibyte and untouched), so a 900 KB payload lands
/// around 905–950 KB on the wire — comfortably under 1 MB with ~10% headroom.
/// The residual is escape-heavy content (a research note that is mostly literal
/// `"`/`\`, e.g. embedded JSON or code): that can inflate further, which is why
/// the budget sits at 900 KB rather than nearer the cap.
public enum MCPResponseBudget {

    /// Maximum size, in bytes, of a text tool's raw result payload. See the
    /// type doc for the envelope-overhead arithmetic behind the value.
    public static let maxTextBytes = 900_000

    /// Pass-through guard: return `payload` unchanged when it fits the text
    /// budget, otherwise throw a structured `payload_too_large` tool error
    /// carrying `hint` (which should name a section-scoped alternative, e.g.
    /// `search_text`, or point at reading the file directly). The machine-
    /// readable `fields` report the actual and maximum byte counts so a client
    /// can reason about how much to trim.
    ///
    /// Usage at an emit site: `return try MCPResponseBudget.enforce(data, hint: …)`.
    @discardableResult
    public static func enforce(_ payload: Data, hint: String) throws -> Data {
        guard payload.count > maxTextBytes else { return payload }
        throw MCPError.toolError(payload: .init(
            error: "payload_too_large",
            message: "Response is \(payload.count) bytes, over the \(maxTextBytes)-byte MCP text budget (the transport line is capped near 1 MB).",
            hint: hint,
            fields: [
                "byte_count": .int(payload.count),
                "max_bytes": .int(maxTextBytes),
            ]))
    }
}
