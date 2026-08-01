import Foundation
import MaughamCore

/// Statement store seam (M1A). A statement — the writer's intent, or the book's
/// visual language — is found by **scope, in the manifest**, and its content is
/// an ordinary `Document` living in the open at the project root.
///
/// This is the seam that replaces `ProjectStore+CraftIntent.swift`, and the
/// replacement is what kills that seam's defect rather than fixing it: craft
/// intent was located by the piece's research PATH PREFIX
/// (`ResearchScope.pieceResearchPrefix`, `guard piece.pieceKind == .loose`), so
/// a novel chapter's intent was created into shared `research/` where the lookup
/// never looked, and the next create minted a second copy of the writer's prose.
/// There is no prefix here, so there is nothing to be nil.
extension ProjectStore {

    // MARK: - The one live Document per statement

    /// Record that a pane has this statement's `Document` open.
    ///
    /// Called by `StatementEditorHost` the moment it binds one. Everything else
    /// that writes into a statement asks `openStatementDocument(id:)` FIRST and
    /// only loads its own when the answer is nil — see that property's storage
    /// on `ProjectStore` for what two live `Document`s on one path cost.
    func noteStatementDocumentOpened(_ document: Document, id: String) {
        openStatementDocuments[id] = OpenStatementDocument(document)
    }

    /// Drop a pane's registration. Hygiene rather than correctness — the entry
    /// is weak and the read below refuses a closed `Document` — but a registry
    /// that is only ever added to is one nobody can reason about.
    func forgetStatementDocument(id: String) {
        openStatementDocuments[id] = nil
    }

    /// The live `Document` for a statement, or nil.
    ///
    /// **Nil for a CLOSED one, and that is the load-bearing half.** A pane that
    /// has gone away closes its `Document` and may still hold the reference
    /// (`.onDisappear` closes but does not release), so a registry that answered
    /// with a husk would send an append into `setFullText`'s closed-doc no-op.
    /// Nil sends the caller down its own transient-load path, which is correct
    /// because there is no longer a second live `Document` to collide with.
    func openStatementDocument(id: String) -> Document? {
        guard let document = openStatementDocuments[id]?.document else {
            openStatementDocuments[id] = nil
            return nil
        }
        guard !document.isClosed else { return nil }
        return document
    }

    /// The statement for a scope, or nil. **Absence is valid**: this mints
    /// nothing, stamps nothing and logs nothing — unlike `craftIntentItem`,
    /// which lazily healed a legacy identity on read, a statement's identity is
    /// its manifest entry and there is nothing to heal.
    public func statement(kind: Statement.Kind, scope: Statement.Scope) -> Statement? {
        StatementLookup.statement(in: manifest.statements, kind: kind, scope: scope)
    }

    /// Find-or-create the statement for a scope. **Idempotent**: called twice
    /// for the same `(kind, scope)` it returns the same statement and creates no
    /// second file.
    ///
    /// Throws — never silently falls back to project scope — when the scope
    /// names something that is not a manuscript document in this project
    /// (`.structureMissing`), and when the `(kind, scope)` pair has no row in
    /// the §2.2 storage table (`.statementHasNoStorage`). The old seam kept the
    /// same discipline (`ProjectStore+CraftIntent.swift`) and it is worth
    /// keeping: a chapter's intent quietly written into the book's file is the
    /// same class of loss as writing it into a second file nobody reads.
    @discardableResult
    public func createStatement(
        kind: Statement.Kind, scope: Statement.Scope
    ) async throws -> Statement {
        if let existing = statement(kind: kind, scope: scope) { return existing }

        let slug = try documentSlug(for: scope)
        guard let candidate = StatementConvention.newPath(
            kind: kind, scope: scope, documentSlug: slug) else {
            throw ProjectStoreError.statementHasNoStorage(
                kind: kind.rawValue, scope: scope.rawValue)
        }
        let relativePath = vacantStatementPath(basedOn: candidate)

        let fileURL = url.appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Empty scaffolding, as every other creator in this store writes it
            // (`addStructureItem`, `addResearchTextNote`): a brand-new file with
            // no second writer for NSFileCoordinator to arbitrate. Content
            // arrives through the op log from here on.
            try Data().write(to: fileURL)
        } catch {
            throw ProjectStoreError.fileSystemError(error.localizedDescription)
        }

        let created = Statement(
            id: Self.newId(prefix: "stmt"), kind: kind, scope: scope, path: relativePath)
        manifest.statements.append(created)
        manifest.modified = Date()
        try await saveManifest()
        return created
    }

    // MARK: - Path minting

    /// The slug a new document-scoped statement's filename is built from, or nil
    /// for a scope that needs none. Derived from the document's title **once, at
    /// creation** — identity is the manifest `id` (tripwire 22), so a later
    /// rename moves the title and leaves the path where it is.
    ///
    /// Throws for a scope that names anything other than a manuscript document
    /// in this project: an unknown id, or a group. A statement is about a
    /// document the writer writes in.
    private func documentSlug(for scope: Statement.Scope) throws -> String? {
        guard case .document(let docId) = scope else { return nil }
        guard let item = findItem(id: docId, in: manifest.structure),
              item.type == .document else {
            throw ProjectStoreError.structureMissing
        }
        return Slugifier.slug(from: item.title)
    }

    /// `candidate` if nothing holds it, else the same name with a `-2`, `-3`, …
    /// inserted before the extension.
    ///
    /// **Two things can hold a path, and both matter.** Another statement can
    /// (two documents may share a title, so their slugs collide) — and so can an
    /// **untracked file the project knows nothing about**. The manifest is the
    /// only authority on a statement's identity, so registering one at an
    /// occupied path would point `resolveDocId` at that file, bootstrap the
    /// statement from its bytes, and then own it: a file the writer put there
    /// eaten by a registry entry they never made. Steering around is
    /// non-destructive and recoverable; taking the path is neither.
    private func vacantStatementPath(basedOn candidate: String) -> String {
        let ns = candidate as NSString
        let ext = ns.pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let claimed = Set(manifest.statements.map(\.path))
        let root = url
        let free = Self.dedupedName(ns.deletingPathExtension) { stem in
            let relative = stem + suffix
            return claimed.contains(relative)
                || FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(relative).path)
        }
        return free + suffix
    }
}

/// A **weak** handle to the `Document` a statement pane has open.
///
/// Weak because the PANE owns it: `StatementEditorHost` holds the strong
/// reference for as long as it is showing that scope, closes it on the way out,
/// and an entry outliving that would hand a writer's promotion a husk to write
/// into — `Document.setFullText` no-ops on a closed doc, so the words would go
/// nowhere and nothing would be red.
@MainActor
final class OpenStatementDocument {
    weak var document: Document?
    init(_ document: Document) { self.document = document }
}
