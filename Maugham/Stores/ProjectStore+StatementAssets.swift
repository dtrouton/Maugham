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
/// `ImagePasteHandler.wellURL(forNoteAt:in:)` derives `<slug>_assets` from the
/// file's own name, so handing it a `Statement.path` yields the well for free. Move a statement and the well follows it.
///
/// **The ref this returns is the caller's to insert, and it must go in through
/// the `Document`.** A statement's `.md` is derived output (hard invariant), so
/// writing the ref into the file would be discarded on the next re-materialize.
/// Nothing here touches the statement's text.
extension ProjectStore {

    /// Save `image` into the statement's well and return where it landed.
    ///
    /// **Find-or-create, because the well cannot be known before the file
    /// exists.** `vacantStatementPath` steers around an occupied
    /// `visual-language.md`, so the path is `createStatement`'s answer rather
    /// than a constant — there is no deriving the well from the convention
    /// alone. `createStatement` is idempotent, so a pane that mints on the same
    /// turn gets the same statement and no second file.
    ///
    /// It opens no `Document` and so takes no `lockStatementOpen` of its own —
    /// that gate is over the *opening*. Putting the ref into the text is the
    /// caller's next act, and `ProjectStore.appendToStatement` is what takes the
    /// gate when nobody has the statement open. **That is also what leaves it
    /// free to roll back below**: `rollbackUnusedStatement` takes the same gate
    /// unconditionally and it is not reentrant, so a lock taken here would hang
    /// on the failure path rather than clean up on it.
    ///
    /// **Nothing is left behind by a refusal, in either order it can fail**
    /// (issue #29, S6). The encode comes first, so the writer's own bad bitmap
    /// refuses before there is a statement — the file-URL twin's ordering. What
    /// is left after that is the disk's refusal, which can only happen after the
    /// mint, and that is rolled back.
    public func addImage(
        toStatement kind: Statement.Kind, scope: Statement.Scope, image: NSImage
    ) async throws -> StatementPicture {
        let png = try ImagePasteHandler.encodePNG(image)
        let mintedHere = statement(kind: kind, scope: scope) == nil
        let statement = try await createStatement(kind: kind, scope: scope)
        do {
            return StatementPicture(
                statement: statement,
                ref: try ImagePasteHandler.saveAndReferenceData(
                    png, ext: "png", forNoteAt: statement.path, in: url))
        } catch {
            await rollBack(statement, ifMintedHere: mintedHere)
            throw error
        }
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
    /// language to exist. **And a save that fails after the mint rolls the mint
    /// back**, so the guarantee holds for the disk's refusals too (issue #29,
    /// S6) — the copy below can throw with the statement already committed, and
    /// until then that was an empty visual language the writer never declared.
    public func addImage(
        toStatement kind: Statement.Kind, scope: Statement.Scope, fileURL: URL
    ) async throws -> StatementPicture {
        guard ImagePasteHandler.isIngestableImage(fileURL) else {
            throw ImagePasteHandler.ImagePasteError.notAnImage(
                filename: fileURL.lastPathComponent)
        }
        let mintedHere = statement(kind: kind, scope: scope) == nil
        let statement = try await createStatement(kind: kind, scope: scope)
        do {
            return StatementPicture(
                statement: statement,
                ref: try ImagePasteHandler.saveAndReferenceFile(
                    from: fileURL, forNoteAt: statement.path, in: url))
        } catch {
            await rollBack(statement, ifMintedHere: mintedHere)
            throw error
        }
    }

    /// Undo the mint an ingest made for a picture that never arrived.
    ///
    /// **`mintedHere` is the whole guard, and it cannot be recovered after the
    /// fact.** `createStatement` is find-or-create, so both arms above are
    /// holding a statement that is either this call's mint or the writer's
    /// existing declaration — and at the moment of failure the two are
    /// indistinguishable from disk: a statement whose only content is picture
    /// refs has an empty file and an op log with no words either way, because
    /// the ref goes in through the caller's own append. Only the question asked
    /// BEFORE `createStatement` tells them apart, which is why each arm asks it
    /// and passes the answer here.
    ///
    /// **Both callers roll back only where the save threw before anything
    /// landed**, which in both arms is true because the save is the final act:
    /// the well's own `createDirectory` and the copy/write are inside it, and a
    /// picture already in the well must never have its statement removed — an
    /// orphaned photograph is worse than an empty statement.
    ///
    /// `rollbackUnusedStatement` refuses on its own account too (an open pane,
    /// words in the derivation, a non-empty file, a picture already in the well,
    /// an unknown row), so this is the *first* of two questions rather than the
    /// only one. The well refusal is the one that covers what `mintedHere`
    /// cannot: a *different* drop's photograph landing beside this statement
    /// while this one's save was failing (issue #35).
    ///
    /// **What it deliberately does not undo: the well itself.** A save that gets
    /// past `createDirectory` and fails on the write leaves an empty
    /// `<slug>_assets/` behind. That is the exact inverse of `createStatement`'s
    /// two commits and no more, on purpose — an empty directory holds nothing,
    /// is invisible in the binder, and the next mint of the same statement takes
    /// the same path and reuses it. Removing it would mean deciding it was ours
    /// to remove, which for a well the writer may have put a photograph in a
    /// second earlier is not a thing this failure path can know.
    private func rollBack(_ statement: Statement, ifMintedHere mintedHere: Bool) async {
        guard mintedHere else { return }
        await rollbackUnusedStatement(statement)
    }
}

/// Where a picture landed.
///
/// **The pair travels together, and that is the M1A Task 12 review's I1.** The
/// ref is a path relative to one particular document, and an async ingest can
/// outlive the surface that started it — the writer drops a picture on Visual
/// Language and presses `⌘⌥N` while the file is being copied, which tears that
/// pane down rather than reconciling it. A caller holding only the ref has to
/// ask "which document is this for?" of whatever is on screen *now*, and every
/// answer available there is a proxy that can be stale. The honest answer is the
/// statement the picture was saved beside, so it is returned rather than
/// inferred.
public struct StatementPicture {
    /// The statement the picture was saved beside, found-or-created.
    public let statement: Statement
    /// The Markdown ref to put into **that statement's** text.
    public let ref: String
}
