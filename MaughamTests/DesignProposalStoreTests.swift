import XCTest
@testable import Maugham

@MainActor
final class DesignProposalStoreTests: XCTestCase {

    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesignProposalStore-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeReport(
        spec: String = "# Dropcaps\nA drop cap on every chapter opener.",
        files: [DesignerReport.ProposedFile] = [
            .init(path: "template.tex", content: "\\documentclass{book}"),
            .init(path: "partials/dropcaps.tex", content: ""),
        ]
    ) -> DesignerReport {
        DesignerReport(specMarkdown: spec, files: files)
    }

    // MARK: - Stage / load round-trip

    func test_stage_writesSpecFilesAndMetadata_roundTripsViaLoad() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let report = makeReport()

        let staged = try store.stage(report: report, round: 1, designerName: "Tschichold", language: nil)

        XCTAssertTrue(staged.id.hasPrefix("prop-"))
        XCTAssertEqual(staged.designerName, "Tschichold")
        XCTAssertEqual(staged.round, 1)
        XCTAssertEqual(staged.status, .pending)
        XCTAssertEqual(staged.specMarkdown, report.specMarkdown)
        XCTAssertEqual(Set(staged.filePaths), ["template.tex", "partials/dropcaps.tex"])
        XCTAssertNil(staged.sampleResult)

        // The files actually landed on disk under files/<relative path>.
        let filesDir = project
            .appendingPathComponent(".maugham/design/proposals/\(staged.id)/files")
        XCTAssertEqual(
            try String(contentsOf: filesDir.appendingPathComponent("template.tex"), encoding: .utf8),
            "\\documentclass{book}")
        XCTAssertEqual(
            try String(contentsOf: filesDir.appendingPathComponent("partials/dropcaps.tex"), encoding: .utf8),
            "")
        let specURL = project
            .appendingPathComponent(".maugham/design/proposals/\(staged.id)/spec.md")
        XCTAssertEqual(try String(contentsOf: specURL, encoding: .utf8), report.specMarkdown)

        let loaded = try store.load(id: staged.id)
        XCTAssertEqual(loaded.id, staged.id)
        XCTAssertEqual(loaded.designerName, staged.designerName)
        XCTAssertEqual(loaded.round, staged.round)
        XCTAssertEqual(loaded.status, staged.status)
        XCTAssertEqual(loaded.specMarkdown, staged.specMarkdown)
        XCTAssertEqual(Set(loaded.filePaths), Set(staged.filePaths))
        // ISO8601 round-trips to whole-second precision (CLAUDE.md's manifest
        // `modified` discipline) — compare with tolerance, not equality.
        XCTAssertEqual(loaded.created.timeIntervalSince1970,
                        staged.created.timeIntervalSince1970, accuracy: 1.0)
    }

    func test_stage_emptyFiles_isValid() throws {
        // A words-only round — DesignerReport's own contract (a question for
        // the writer, nothing to show yet) must stage cleanly.
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let report = makeReport(spec: "Before I propose anything: square or portrait?", files: [])

        let staged = try store.stage(report: report, round: 1, designerName: "Tschichold", language: nil)
        XCTAssertTrue(staged.filePaths.isEmpty)

        let loaded = try store.load(id: staged.id)
        XCTAssertTrue(loaded.filePaths.isEmpty)
    }

    func test_load_unknownId_throwsNotFound() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        XCTAssertThrowsError(try store.load(id: "prop-doesnotexist")) { error in
            XCTAssertEqual(error as? DesignProposalStore.StoreError,
                            .notFound(id: "prop-doesnotexist"))
        }
    }

    // MARK: - List

    func test_list_emptyProject_returnsEmpty() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func test_list_returnsNewestFirst() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)

        let first = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)
        try store.updateStatus(id: first.id, .approved)
        Thread.sleep(forTimeInterval: 1.1) // ISO8601 whole-second precision
        let second = try store.stage(report: makeReport(), round: 2, designerName: "Tschichold", language: nil)

        let listed = try store.list()
        XCTAssertEqual(listed.map(\.id), [second.id, first.id])
    }

    // MARK: - Supersede

    func test_stage_secondPendingSupersedesTheFirst_withoutDeletingIt() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)

        let first = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)
        XCTAssertEqual(first.status, .pending)

        let second = try store.stage(report: makeReport(), round: 2, designerName: "Tschichold", language: nil)
        XCTAssertEqual(second.status, .pending)

        let reloadedFirst = try store.load(id: first.id)
        XCTAssertEqual(reloadedFirst.status, .superseded)
        // Superseded, never deleted: its content is still on disk.
        XCTAssertEqual(reloadedFirst.specMarkdown, first.specMarkdown)
        let filesDir = project
            .appendingPathComponent(".maugham/design/proposals/\(first.id)/files")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: filesDir.appendingPathComponent("template.tex").path))

        let listed = try store.list()
        XCTAssertEqual(listed.count, 2)
    }

    func test_stage_afterApproval_doesNotSupersedeTheApprovedOne() throws {
        // Only a PENDING proposal is at risk of supersession — an approved
        // one is history, not a competing round.
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)

        let first = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)
        try store.updateStatus(id: first.id, .approved)

        let second = try store.stage(report: makeReport(), round: 2, designerName: "Tschichold", language: nil)
        XCTAssertEqual(second.status, .pending)

        let reloadedFirst = try store.load(id: first.id)
        XCTAssertEqual(reloadedFirst.status, .approved)
    }

    // MARK: - updateStatus

    func test_updateStatus_persists() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)

        try store.updateStatus(id: staged.id, .rejected)

        XCTAssertEqual(try store.load(id: staged.id).status, .rejected)
    }

    func test_updateStatus_unknownId_throwsNotFound() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        XCTAssertThrowsError(try store.updateStatus(id: "prop-nope", .approved)) { error in
            XCTAssertEqual(error as? DesignProposalStore.StoreError, .notFound(id: "prop-nope"))
        }
    }

    // MARK: - ADR-0015 tolerant status decoding

    func test_load_unrecognizedStatus_preservesRawVerbatim() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)

        // Hand-write a status a newer build might have written.
        try Self.rewriteStatusField(
            "in_review", forProposal: staged.id, in: project)

        let loaded = try store.load(id: staged.id)
        XCTAssertEqual(loaded.status, .unknown("in_review"))
    }

    func test_updateStatus_unrelatedField_reencodesUnknownStatusLosslessly() throws {
        // The lossless pattern (PassState's, not SynthesisSource's): touching
        // ANY field of a proposal carrying a future status must not clobber
        // that status down to a generic literal on the rewrite.
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)
        try Self.rewriteStatusField("in_review", forProposal: staged.id, in: project)

        try store.recordSampleResult(id: staged.id, .pages(path: "sample.pdf", demonstrates: [], fallbackPieces: 0))

        let loaded = try store.load(id: staged.id)
        XCTAssertEqual(loaded.status, .unknown("in_review"))
        XCTAssertEqual(loaded.sampleResult, .pages(path: "sample.pdf", demonstrates: [], fallbackPieces: 0))
    }

    private static func rewriteStatusField(
        _ raw: String, forProposal id: String, in project: URL
    ) throws {
        let url = project.appendingPathComponent(".maugham/design/proposals/\(id)/proposal.json")
        let data = try Data(contentsOf: url)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["status"] = raw
        let rewritten = try JSONSerialization.data(withJSONObject: object)
        try rewritten.write(to: url, options: .atomic)
    }

    // MARK: - Sample result

    func test_sampleResult_nilUntilRecorded() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)
        XCTAssertNil(try store.sampleResult(id: staged.id))
    }

    func test_recordSampleResult_pages_roundTrips() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)

        try store.recordSampleResult(id: staged.id, .pages(path: "scratch/sample.pdf", demonstrates: [], fallbackPieces: 0))

        XCTAssertEqual(try store.sampleResult(id: staged.id), .pages(path: "scratch/sample.pdf", demonstrates: [], fallbackPieces: 0))
        XCTAssertEqual(try store.load(id: staged.id).sampleResult, .pages(path: "scratch/sample.pdf", demonstrates: [], fallbackPieces: 0))
    }

    func test_recordSampleResult_failed_carriesTheErrorText() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)

        try store.recordSampleResult(id: staged.id, .failed(error: "! Undefined control sequence."))

        XCTAssertEqual(try store.sampleResult(id: staged.id),
                        .failed(error: "! Undefined control sequence."))
    }

    // MARK: - Delete

    func test_delete_removesTheProposalFolder() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)
        let dir = project.appendingPathComponent(".maugham/design/proposals/\(staged.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        try store.delete(id: staged.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertThrowsError(try store.load(id: staged.id))
        XCTAssertTrue(try store.list().isEmpty)
    }

    /// **The one window in which a proposal folder is not merely derived.**
    /// Between `ProposalPromotion.approve` and its `revert`/`finalize`, this
    /// proposal's `backup/` holds the ONLY copy of the live templates the
    /// promotion displaced — they are not in the proposal (which holds the new
    /// ones), not in the live tree (which now has the new ones), and nowhere
    /// else on disk. Deleting the folder then does not discard a design round
    /// the writer turned down; it destroys their originals while the new design
    /// is still shipping.
    ///
    /// Built by hand rather than through a real promotion: what `delete` reads
    /// is the presence of that directory, and this suite is the store's, not the
    /// promotion's. `ProposalPromotionTests` owns the promotion end.
    ///
    /// Disable experiment: drop the `backupDir` guard in `delete` and this fails
    /// on the missing throw, with the folder — originals and all — gone.
    func test_delete_refusesWhileAPromotionsBackupStands() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)
        let held = store.backupDir(id: staged.id).appendingPathComponent("files")
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        try "LIVE ORIGINAL".write(
            to: held.appendingPathComponent("template.tex"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.delete(id: staged.id)) { error in
            XCTAssertEqual(error as? DesignProposalStore.StoreError,
                           .promotionBackupStands(id: staged.id))
        }
        XCTAssertEqual(
            try String(contentsOf: held.appendingPathComponent("template.tex"), encoding: .utf8),
            "LIVE ORIGINAL", "the writer's originals survive the ask")
        XCTAssertNoThrow(try store.load(id: staged.id), "and so does the proposal")
    }

    /// The complement: with the backup gone — reverted or finalized — the folder
    /// is derived again and deletes like any other.
    func test_delete_proceedsOnceTheBackupIsGone() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)
        let backup = store.backupDir(id: staged.id)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.delete(id: staged.id), "fixture: the guard is live")

        try FileManager.default.removeItem(at: backup)

        try store.delete(id: staged.id)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func test_delete_unknownId_throwsNotFound() throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        XCTAssertThrowsError(try store.delete(id: "prop-nope")) { error in
            XCTAssertEqual(error as? DesignProposalStore.StoreError, .notFound(id: "prop-nope"))
        }
    }

    // MARK: - Derived-and-deletable

    func test_deletingTheWholeDesignDirectory_costsNoContentElsewhere() throws {
        // The type's own contract: `.maugham/design/` is derived. Nothing
        // outside it is touched by wiping it.
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        _ = try store.stage(report: makeReport(), round: 1, designerName: "Tschichold", language: nil)

        let manuscriptMarker = project.appendingPathComponent("chapter-one.md")
        try "Once upon a time.".write(to: manuscriptMarker, atomically: true, encoding: .utf8)

        try FileManager.default.removeItem(
            at: project.appendingPathComponent(".maugham/design"))

        XCTAssertEqual(try String(contentsOf: manuscriptMarker, encoding: .utf8), "Once upon a time.")
        XCTAssertTrue(try store.list().isEmpty)
    }
}
