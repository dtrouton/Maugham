import XCTest
import MaughamCore
@testable import Maugham

/// Regression tests for tripwire 14 (research-note half):
/// `movePiece` and `renamePiece` must flush `DocumentStore.scheduleFileSave`
/// pending saves BEFORE the folder move.
///
/// Bug class: research notes are saved via `DocumentStore.scheduleFileSave`
/// on a 750ms debounce — NOT via `Document` (which closes automatically).
/// If a save is pending when the piece folder is moved/renamed, the debounce
/// fires at the OLD path after the directory has been renamed. The write fails
/// silently (NSFileCoordinator: "folder doesn't exist"), so the last-edited
/// content is silently dropped — data loss.
///
/// Fix: call `flushPendingSave()` on the DocumentStore AFTER closing any open
/// Document for the piece and BEFORE the `fm.moveItem` folder rename.
///
/// Test strategy: schedule a research-note save via `scheduleFileSave` (putting
/// content in the pending queue), then call `movePiece`/`renamePiece`. After the
/// operation returns, call `flushPendingSave()` to simulate the 750ms timer
/// firing. In the UNFIXED version, the scheduler still holds the OLD path and
/// the write silently fails — so the content at the NEW path is empty (as
/// written during setup) rather than the "pending" string. In the FIXED version,
/// movePiece/renamePiece flushed the scheduler internally, the write landed at
/// the old-then-moved path before the rename, and the content is in the moved
/// file.
///
/// Both tests are RED against unfixed code and GREEN after the fix.

@MainActor
final class PieceResearchFlushTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        temp.cleanup()
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeCollectionWithDocumentStore() async throws
        -> (URL, ProjectStore, DocumentStore)
    {
        let url = try await ProjectFactory.createCollectionProject(
            named: "FlushTest", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    // MARK: - movePiece flush test

    /// RED until fix: `movePiece` must flush pending research-note saves before
    /// renaming the piece folder. Without the flush, the debounced write fires
    /// at the OLD folder path after it has been renamed, fails silently, and
    /// the last-edited content is lost.
    func test_movePiece_flushesResearchNoteSaveBeforeMove() async throws {
        let (projectURL, store, ds) = try await makeCollectionWithDocumentStore()
        defer { Task { await ds.close() } }

        // Add two pieces so movePiece actually renumbers folders.
        let p1 = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        _ = try await store.addLoosePiece(title: "Beta", mode: .prose)

        // Add a research note to p1.
        let note = try await store.addPieceResearchNote(
            pieceId: p1.id, title: "Alpha Notes")
        let oldNotePath = note.path!
        // e.g. "pieces/01-alpha/research/alpha-notes.md"

        // Write the committed (already-saved) content to disk.
        let savedContent = "saved content — already on disk"
        let oldNoteURL = projectURL.appendingPathComponent(oldNotePath)
        try savedContent.data(using: .utf8)!.write(to: oldNoteURL)

        // Schedule a pending save with NEWER content at the same path. This
        // simulates the user having edited the note 400ms ago — the 750ms
        // debounce has not fired yet.
        let pendingContent = "pending content — edited AFTER last flush, must not be lost"
        ds.scheduleFileSave(for: oldNotePath, text: pendingContent)

        // Move Alpha (p1) to position 1 → folder renumbers from 01-alpha to 02-alpha.
        // BEFORE THE FIX: movePiece does NOT flush the scheduler. The pending
        // payload still references the OLD path. The folder rename below happens,
        // and the old directory is gone.
        try await store.movePiece(pieceId: p1.id, toIndex: 1)

        // Simulate the 750ms timer firing AFTER the move.
        // UNFIXED: scheduler still has oldNotePath → performFileSave tries to
        //   write to old path → directory no longer exists → silent data loss.
        // FIXED: movePiece already flushed → scheduler empty → no-op here.
        try? await ds.flushPendingSave()

        // Find the moved research note in the manifest.
        guard let updatedNote = store.manifest.research.first(where: { $0.id == note.id }) else {
            XCTFail("research note missing from manifest after movePiece"); return
        }
        let newNotePath = updatedNote.path!
        let newNoteURL = projectURL.appendingPathComponent(newNotePath)

        // Confirm the folder was actually renumbered (guard against no-op move).
        XCTAssertNotEqual(oldNotePath, newNotePath,
            "piece folder should have been renumbered by movePiece; "
            + "if old == new the test does not exercise the race")

        // The key assertion: the NEW path must contain the PENDING content.
        // UNFIXED: the flush happened AFTER the rename, the write failed, so the
        //   file at newNotePath still has `savedContent` (or nothing if the
        //   coordinator recreated a fresh file). Either way, pendingContent is lost.
        // FIXED: movePiece flushed to oldNotePath while the folder still existed,
        //   then moved the folder, so the file at newNotePath has pendingContent.
        XCTAssertTrue(FileManager.default.fileExists(atPath: newNoteURL.path),
            "research note should exist at new path '\(newNotePath)' after movePiece")

        let contentAtNewPath = try String(contentsOf: newNoteURL, encoding: .utf8)
        XCTAssertEqual(contentAtNewPath, pendingContent,
            "pending research-note content must survive movePiece; got '\(contentAtNewPath)'. "
            + "The debounced save fired at the OLD path after the folder rename (data loss). "
            + "Fix: add flushPendingSave() in movePiece before the folder move (tripwire 14).")
    }

    // MARK: - renamePiece flush test

    /// RED until fix: `renamePiece` must flush pending research-note saves before
    /// renaming the piece folder. Same data-loss race class as movePiece.
    func test_renamePiece_flushesResearchNoteSaveBeforeMove() async throws {
        let (projectURL, store, ds) = try await makeCollectionWithDocumentStore()
        defer { Task { await ds.close() } }

        // Add a piece and a research note.
        let piece = try await store.addLoosePiece(title: "Lighthouse", mode: .prose)
        let note = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Sarah Notes")
        let oldNotePath = note.path!
        // e.g. "pieces/01-lighthouse/research/sarah-notes.md"

        // Write committed content to disk.
        let savedContent = "saved content — already on disk"
        let oldNoteURL = projectURL.appendingPathComponent(oldNotePath)
        try savedContent.data(using: .utf8)!.write(to: oldNoteURL)

        // Schedule a pending save with newer content.
        let pendingContent = "pending content — edited AFTER last flush, must not be lost"
        ds.scheduleFileSave(for: oldNotePath, text: pendingContent)

        // Rename the piece to a new slug. Folder renames from
        // "01-lighthouse" to "01-the-beacon".
        // BEFORE THE FIX: renamePiece does NOT flush → pending payload has old path.
        try await store.renamePiece(pieceId: piece.id, newTitle: "The Beacon")

        // Simulate the 750ms timer firing AFTER the rename.
        try? await ds.flushPendingSave()

        // Find the renamed note in the manifest.
        guard let updatedNote = store.manifest.research.first(where: { $0.id == note.id }) else {
            XCTFail("research note missing from manifest after renamePiece"); return
        }
        let newNotePath = updatedNote.path!
        let newNoteURL = projectURL.appendingPathComponent(newNotePath)

        // Confirm the folder was actually renamed.
        XCTAssertTrue(newNotePath.contains("the-beacon"),
            "renamed piece folder slug should contain 'the-beacon'; got '\(newNotePath)'")
        XCTAssertNotEqual(oldNotePath, newNotePath,
            "piece folder should have been renamed; if old == new the test does not exercise the race")

        XCTAssertTrue(FileManager.default.fileExists(atPath: newNoteURL.path),
            "research note should exist at new path '\(newNotePath)' after renamePiece")

        let contentAtNewPath = try String(contentsOf: newNoteURL, encoding: .utf8)
        XCTAssertEqual(contentAtNewPath, pendingContent,
            "pending research-note content must survive renamePiece; got '\(contentAtNewPath)'. "
            + "The debounced save fired at the OLD path after the folder rename (data loss). "
            + "Fix: add flushPendingSave() in renamePiece before the folder move (tripwire 14).")
    }
}
