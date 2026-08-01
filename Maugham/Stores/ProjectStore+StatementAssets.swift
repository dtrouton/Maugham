import Foundation
import AppKit
import MaughamCore

/// A statement's own asset well: `<slug>_assets/` beside the statement's file,
/// so `visual-language.md` is served by `visual-language_assets/` (M1A Task 12,
/// spec §7).
///
/// **Why visual language holds files at all.** Spec §3.2 of the umbrella calls
/// visual language *mixed — images, references and prose*, and a mood board you
/// cannot put a picture into is the wrong shape for the one artifact whose
/// subject is how the book looks. A reference photograph the writer drags in
/// from Pictures exists nowhere else in the project, so — exactly as for a
/// canvas capture — ingesting is what gives it a home.
///
/// **A seam of its own rather than a caller of an existing one.** The canvas
/// pair and the palette pair each put images beside a file of their own, and a
/// statement is a file of its own; routing visual language's pictures into
/// `canvas_assets/` would file them beside a document they have nothing to do
/// with, and would tie a statement's pictures to a sidecar the writer may
/// delete. `TripwireGrepTests.test_theSharedImageSaverIsCalledFromTheSeamsThatOwnAWell`
/// records that decision.
///
/// **No naming, dedupe or timestamp scheme of its own**, and no literal:
/// `ImagePasteHandler.destination(forNoteAt:in:ext:)` derives `<slug>_assets`
/// from the file's own name, so handing it a `Statement.path` yields the well
/// for free. Move a statement and the well follows it.
///
/// **The ref this returns is the caller's to insert, and it must go in through
/// the `Document`.** A statement's `.md` is derived output (hard invariant), so
/// writing the ref into the file would be discarded on the next re-materialize.
/// Nothing here touches the statement's text.
extension ProjectStore {

    /// Save `image` into the statement's well and return the Markdown ref.
    ///
    /// **Find-or-create, because the well cannot be known before the file
    /// exists.** `vacantStatementPath` steers around an occupied
    /// `visual-language.md`, so the path is `createStatement`'s answer rather
    /// than a constant — there is no deriving the well from the convention
    /// alone. `createStatement` is idempotent, so a pane that mints on the same
    /// turn gets the same statement and no second file.
    ///
    /// It does **not** open a `Document`, and so deliberately does not take
    /// `lockStatementOpen` — that gate is over the opening, and the ref reaches
    /// the text through whichever `Document` the pane already has (or the one
    /// its own first-keystroke mint opens under the gate).
    public func addImage(
        toStatement kind: Statement.Kind, scope: Statement.Scope, image: NSImage
    ) async throws -> String {
        try addImage(to: try await createStatement(kind: kind, scope: scope), image: image)
    }

    /// Save `image` beside a statement that **already exists**, synchronously.
    ///
    /// For the caller that has found one and needs the ref back on the same turn:
    /// `MaughamTextView.paste(_:)` inserts what its handler returns at the caret,
    /// and a handler that suspends has no caret left to insert at.
    ///
    /// It exists so that `StatementEditorHost` is a *caller* of this seam rather
    /// than a second one — where a statement's pictures live is decided here,
    /// once, and `TripwireGrepTests.test_theSharedImageSaverIsCalledFromTheSeamsThatOwnAWell`
    /// is what noticed the first cut reaching around it.
    public func addImage(to statement: Statement, image: NSImage) throws -> String {
        try ImagePasteHandler.saveAndReference(
            image: image, forNoteAt: statement.path, in: url)
    }

    /// File-URL twin: **copy** an existing picture into the statement's well,
    /// extension preserved, and return the Markdown ref.
    ///
    /// A copy, not a move — the source is the writer's own file and ingesting
    /// must not take it away.
    ///
    /// **Validated before the statement is minted**, so a refused file leaves
    /// nothing behind — not even the empty statement it would have gone into.
    /// That ordering is why the guard is asked here rather than left to the
    /// saver: `createStatement` writes a file and a manifest entry, and a `.txt`
    /// dropped by mistake must not be what declares the writer's visual
    /// language to exist.
    public func addImage(
        toStatement kind: Statement.Kind, scope: Statement.Scope, fileURL: URL
    ) async throws -> String {
        guard ImagePasteHandler.isIngestableImage(fileURL) else {
            throw ImagePasteHandler.ImagePasteError.notAnImage(
                filename: fileURL.lastPathComponent)
        }
        let statement = try await createStatement(kind: kind, scope: scope)
        return try ImagePasteHandler.saveAndReferenceFile(
            from: fileURL, forNoteAt: statement.path, in: url)
    }
}
