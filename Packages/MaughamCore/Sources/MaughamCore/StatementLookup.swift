import Foundation

/// Where a statement's content lives — the spec's §2.2 storage table, in code,
/// once. Content sits in the OPEN at the project root (`canvas.md`'s precedent);
/// only derived state goes under `.maugham/`.
///
/// | Path | Statement |
/// |---|---|
/// | `intent.md` | project intent |
/// | `intent/<slug>.md` | one per manuscript document |
/// | `visual-language.md` | project visual language |
/// | `editions/<lang>.md` | one per edition brief language |
/// | `lessons.md` | the project's lessons ledger |
///
/// Shared rather than Mac-local (tripwire 19): the Mac mints these paths and the
/// phone reads statements, and a table with two spellings is a table that drifts.
public enum StatementConvention {

    /// Project intent.
    public static let projectIntentPath = "intent.md"
    /// The folder per-document intent files live in.
    public static let documentIntentFolder = "intent"
    /// Project visual language.
    public static let visualLanguagePath = "visual-language.md"
    /// The folder edition brief files live in.
    public static let editionsFolder = "editions"
    /// The project's lessons ledger.
    public static let lessonsPath = "lessons.md"

    /// The project-relative path a NEW statement of this `kind` and `scope`
    /// takes, or **nil when the pair has no row in the table**.
    ///
    /// Nil is not a failure to compute — it is the table saying the pair has no
    /// storage: every kind but intent is project-scope only (§2.1), and a
    /// `kind` or `scope` written by a newer build (ADR 0015's `.unknown`) is
    /// something this build retains and ignores, never mints a file for.
    ///
    /// `documentSlug` is derived from the document's title **at creation and
    /// never re-derived** — identity is the manifest `id`, so the path is free
    /// to drift from the title after a rename. The caller supplies it because
    /// only the caller holds the structure. The result is a *candidate*: a
    /// caller that can collide (the Mac's `createStatement`) steers around an
    /// occupied path rather than taking it.
    public static func newPath(
        kind: Statement.Kind, scope: Statement.Scope, documentSlug: String?
    ) -> String? {
        switch (kind, scope) {
        case (.intent, .project):
            return projectIntentPath
        case (.intent, .document):
            guard let documentSlug, !documentSlug.isEmpty else { return nil }
            return "\(documentIntentFolder)/\(documentSlug).md"
        case (.visualLanguage, .project):
            return visualLanguagePath
        case (.editionBrief(let lang), .project):
            guard !lang.isEmpty else { return nil }
            return "\(editionsFolder)/\(lang).md"
        // Project scope only, and deliberately: what the writer has learned
        // about their own writing is one ledger for the book, not a fact a
        // chapter can hold a private copy of.
        case (.lessons, .project):
            return lessonsPath
        default:
            return nil
        }
    }
}

/// Pure lookups over `ProjectManifest.statements` — no stamping, no side
/// effects, exactly `PaletteLookup`'s shape. The Mac wraps these with creation
/// (`ProjectStore+Statements.swift`); the phone uses them read-only.
public enum StatementLookup {

    /// The statement for a `(kind, scope)` pair, or nil.
    ///
    /// **Lookup is by scope, in the manifest** — there is no path prefix and no
    /// filename convention in the read path. That is what kills the defect the
    /// craft-intent seam carried rather than fixing it: its lookup went through
    /// `ResearchScope.pieceResearchPrefix`, which is nil for anything that is
    /// not a collection loose piece, so a novel chapter's intent could be
    /// created and then never found, and the next create minted a second copy of
    /// the writer's prose.
    ///
    /// **Absence is valid** and returns nil with no side effect. Nothing here
    /// mints, stamps or logs — `read_craft_intent`'s shipped description already
    /// promises Claude that absence is "a valid, deliberate state", and the
    /// store must not contradict its own MCP surface.
    public static func statement(
        in statements: [Statement], kind: Statement.Kind, scope: Statement.Scope
    ) -> Statement? {
        statements.first { $0.kind == kind && $0.scope == scope }
    }
}
