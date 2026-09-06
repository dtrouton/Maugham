import Foundation

/// **What the File menu calls each of the compiler's two keys, in the key
/// window's own persona.**
///
/// Two loops P1 split one trigger into two verbs ([ADR 0031](../../docs/adr/0031-the-persona-is-an-input-to-the-run.md)):
/// Author's ⌘R is a *check* over what changed since its own last one, Review's
/// is a numbered *round* over the piece whole, and the cold read is *Reread* in
/// Author against *Fresh Eyes* in Review. The keys and the two events they post
/// did not move — the receiver mints the `RunKind` from the persona — so this
/// is the menu's own vocabulary and nothing else: a title, never a decision.
///
/// **`nil` is Author's wording, and that is not a fallback.** A ⌘R with no
/// project window in front is already a no-op at the receiver, so what the item
/// reads while nothing is focused is the wording the writer will act under the
/// moment a window is — and `Persona.default` is `.author`.
///
/// Both switches are exhaustive over `Persona?` with no `default`, so a fifth
/// persona fails to compile HERE, where somebody has to decide what its ⌘R is
/// called, rather than silently inheriting Author's words.
enum RunMenuTitles {
    /// ⌘R — the warm run.
    static func check(for persona: Persona?) -> String {
        switch persona {
        case .author, .plan, .publish, nil: return "Check Writing"
        case .review: return "Run Round"
        }
    }

    /// ⌘⇧R — the cold read: the warm session ends and the piece is read whole.
    static func cold(for persona: Persona?) -> String {
        switch persona {
        case .author, .plan, .publish, nil: return "Reread"
        case .review: return "Fresh Eyes"
        }
    }
}
