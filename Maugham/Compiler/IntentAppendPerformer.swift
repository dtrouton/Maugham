import Foundation
import MaughamCore

/// **Superseded, and kept only until the pane that calls it is rewritten**
/// (declared-world Task 4).
///
/// M2 shipped an answered diagnostic as a free paragraph appended verbatim to
/// the piece's intent essay. The second-draft spec calls that out by name as the
/// membrane's loosest point (§3.4: *"stricter than the shipped answer flow,
/// which appended a chat reply verbatim"*) and replaces it: the writer's answer
/// is a **ruling** — an itemized, dated line in the statement's `## Rulings`
/// stratum, with provenance saying where it came from — written by
/// `RulingPerformer`, which is now the one door into the writer-owned layer.
///
/// Stage 2 removes this file. The declared-world stage does not touch the run or
/// the Diagnostics pane's answer flow (plan §Task 4; the pane's reply field is
/// Stage 2's concern), so deleting the shim here would mean rewriting that flow
/// inside a stage that was scoped not to. What is left is one call and no logic:
/// the validation, the mint, the op-logged write and the refusals all live in
/// `RulingPerformer` and are tested there.
///
/// Two consequences of the routing, recorded rather than hidden:
///
/// - **`world` is `nil`.** `DiagnosticsPane` holds no `DeclaredWorldStore` —
///   `ProjectWindow` does not construct one until Task 6 — so an answer through
///   this shim does not drop the scope's cached derivation. Harmless today
///   (nothing consumes a derivation yet) and Stage 2's rewrite of the flow is
///   where the pane gets the store; a shim that reached for a global to avoid
///   writing `nil` would be worse than the gap it hid.
/// - **The answer no longer lands in the essay**, so a piece whose statement had
///   no prose gains a ruling and still has no essay line for `IntentStrip` to
///   draw. That is the intended tightening, not a regression to fix here.
@MainActor
enum IntentAppendPerformer {

    /// Stage 2 removes: `DiagnosticsPane.commitAnswer` is the one caller.
    static func append(answer: String, forDocId docId: String,
                       store: ProjectStore) async throws {
        try await RulingPerformer.rule(
            answer, provenance: Self.answeredNoteProvenance,
            forScope: .document(docId), store: store, world: nil)
    }

    /// What the ruling's line says about where it came from. Deliberately does
    /// not name the ¶ the note was anchored to — the shim's signature never
    /// carried it, and inventing a reference the record cannot support is worse
    /// than a general one. Stage 2's flow has the diagnostic in hand and can say
    /// *"from a run on ¶wnse"* the way spec §3.2 writes it.
    private static let answeredNoteProvenance = "answered a compiler note"
}
