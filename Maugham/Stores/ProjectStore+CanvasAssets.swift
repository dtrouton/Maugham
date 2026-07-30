import Foundation
import AppKit

/// The canvas's asset well: `canvas_assets/`, at the project root, beside
/// `canvas.md`.
///
/// **Why the canvas owns a file at all.** Every other thing on the canvas
/// points at something that already exists — a research item, a palette card, a
/// scrap whose words live in `canvas.md`. A photograph from the phone's capture
/// inbox or from a Finder drop exists nowhere else in the project, and the
/// inbox is a queue the writer *clears*, so a node pointing into it is a card
/// that disappears the day they tidy up. Ingesting gives it a home first, and
/// `CanvasItemReference.owned(path:)` holds the result.
///
/// **This pair is the only writer of `canvas_assets/`.** Every route — the
/// research drag, the Finder drop, the browser bitmap, the inbox promotion — is
/// a *caller*, never a storage decision of its own; where an image lands is
/// decided here once. `TripwireGrepTests.test_canvasAssetsHaveExactlyOneWriter`
/// is the census that keeps it that way.
///
/// **No naming, dedupe or timestamp scheme of its own.**
/// `ImagePasteHandler.destination(forNoteAt:in:ext:)` derives `<slug>_assets`
/// from the note's own filename, so handing it `canvas.md` yields
/// `canvas_assets/` for free — the same saver, the same `image-yyyyMMdd-HHmmss`
/// names and the same same-second dedupe that research notes and palette cards
/// have used since v0.x. The well's name is therefore *derived* from
/// `CanvasStore.scrapsRelativePath` and is deliberately not spelled anywhere in
/// this file: move `canvas.md` and the well follows it.
extension ProjectStore {

    /// Ingest a bitmap the canvas was handed (a browser drag, a pasteboard
    /// image, a phone capture) as a PNG in the well. Returns its
    /// **project-relative** path — the string `CanvasItemReference.owned(path:)`
    /// requires.
    ///
    /// `async` with nothing to await, mirroring its palette twins
    /// (`addImage(toPaletteCard:image:)`) deliberately: the five callers in
    /// 1C-d's drop/inbox routes are all async, and a synchronous signature here
    /// would have to break all five the first time this needs to touch the
    /// manifest or a coordinated write.
    public func ingestCanvasAsset(image: NSImage) async throws -> String {
        let ref = try ImagePasteHandler.saveAndReference(
            image: image, forNoteAt: CanvasStore.scrapsRelativePath, in: url)
        return canvasAssetPath(fromRef: ref)
    }

    /// File-URL twin: **copy** an existing image into the well, extension
    /// preserved. A copy, not a move — the source is the writer's own file
    /// (a photo in Pictures, an inbox capture that is still the inbox's until
    /// it is promoted), and ingesting must not take it away.
    public func ingestCanvasAsset(fileURL: URL) async throws -> String {
        let ref = try ImagePasteHandler.saveAndReferenceFile(
            from: fileURL, forNoteAt: CanvasStore.scrapsRelativePath, in: url)
        return canvasAssetPath(fromRef: ref)
    }

    // MARK: - Helpers

    /// Resolve the saver's `![](./canvas_assets/…)` to a project-relative path
    /// through the SAME resolution the palette uses
    /// (`ProjectStore.resolveImageRef`) — a second spelling of ref→path is the
    /// drift, and the failure mode of getting it wrong is silent: an absolute
    /// path, a `file://` URL or the ref itself each renders nothing, keys the
    /// thumbnail cache on a string that differs between Macs, and breaks the
    /// moment the project is moved or synced.
    ///
    /// The directory is `canvas.md`'s own, so the well is located wherever the
    /// scraps file is rather than at a hardcoded root.
    private func canvasAssetPath(fromRef ref: String) -> String {
        let scrapsDirectory =
            (CanvasStore.scrapsRelativePath as NSString).deletingLastPathComponent
        return Self.resolveImageRef(ref, relativeTo: scrapsDirectory)
    }
}
