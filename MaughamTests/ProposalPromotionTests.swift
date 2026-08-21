import XCTest
@testable import Maugham

/// Task 8. The gate's two verbs: `approve` puts a staged design round onto the
/// live publish tree, and `revert` takes it back whole.
///
/// Every test here is a file-system fact — no LaTeX, no tectonic. What this
/// task guarantees is about BYTES (the writer's shipping templates), and a
/// guarantee pinned behind a real compile is a guarantee that skips itself on
/// a cold TeX bundle. `SampleCompilerTests` made the same choice for the same
/// reason.
@MainActor
final class ProposalPromotionTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProposalPromotionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixtures

    /// A project whose live publish tree carries `files` (relative path →
    /// content). Built by hand rather than through `PublishStarter`: what
    /// `approve` needs from the tree is that it EXISTS and holds the files it
    /// is about to overwrite, and a hand-built one says exactly which bytes
    /// are under test.
    private func makeProject(
        live: [(path: String, content: String)] = [("template.tex", "LIVE ORIGINAL")]
    ) throws -> URL {
        let projectURL = tmp.appendingPathComponent("P-\(UUID().uuidString)")
        let publish = projectURL.appendingPathComponent(".maugham/publish", isDirectory: true)
        try FileManager.default.createDirectory(at: publish, withIntermediateDirectories: true)
        for file in live {
            let url = publish.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: url, atomically: true, encoding: .utf8)
        }
        return projectURL
    }

    /// Stage a proposal through the real store, so promotion reads exactly
    /// what staging wrote.
    @discardableResult
    private func stage(
        _ files: [(path: String, content: String)], in projectURL: URL
    ) throws -> DesignProposalStore.Proposal {
        let report = DesignerReport(
            specMarkdown: "# a design",
            files: files.map { .init(path: $0.path, content: $0.content) })
        return try DesignProposalStore(projectURL: projectURL)
            .stage(report: report, round: 1, designerName: "Tschichold", language: nil)
    }

    private func livePublishDir(_ projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham/publish", isDirectory: true)
    }

    private func backupDir(_ projectURL: URL, _ id: String) -> URL {
        DesignProposalStore(projectURL: projectURL)
            .proposalDir(id: id)
            .appendingPathComponent("backup", isDirectory: true)
    }

    /// relative path → bytes, for every regular file under `dir`. The whole
    /// point of `revert` is that this value comes back identical.
    private func snapshot(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let base = dir.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            out[relative] = try Data(contentsOf: url)  // adr-0018-ok: publish templates, not manuscript
        }
        return out
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func readBackupManifest(
        _ projectURL: URL, _ id: String
    ) throws -> ProposalPromotion.Backup {
        let url = backupDir(projectURL, id).appendingPathComponent("manifest.json")
        return try JSONDecoder().decode(
            ProposalPromotion.Backup.self,
            from: Data(contentsOf: url))  // adr-0018-ok: promotion backup manifest, not manuscript
    }

    /// A job manager with one compile in flight — the state both verbs refuse.
    private func busyManager() async -> CompileJobManager {
        let manager = CompileJobManager()
        await manager.register(phase: .compiling)
        return manager
    }

    // MARK: - approve

    func test_approve_writesStagedOverLive_andBacksUpWhatItReplaced() async throws {
        let project = try makeProject(live: [("template.tex", "LIVE ORIGINAL")])
        let proposal = try stage([
            ("template.tex", "PROPOSED"),
            ("partials/dropcaps.tex", "FRESH"),
        ], in: project)

        try await ProposalPromotion.approve(
            proposal: proposal, projectURL: project, jobManager: CompileJobManager())

        let live = livePublishDir(project)
        XCTAssertEqual(try text(live.appendingPathComponent("template.tex")), "PROPOSED")
        XCTAssertEqual(try text(live.appendingPathComponent("partials/dropcaps.tex")), "FRESH")

        // The replaced file's ORIGINAL bytes are held.
        let held = backupDir(project, proposal.id).appendingPathComponent("files")
        XCTAssertEqual(try text(held.appendingPathComponent("template.tex")), "LIVE ORIGINAL")
        // The new file has no original to hold — nothing is stored for it.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: held.appendingPathComponent("partials/dropcaps.tex").path))

        // …but it is RECORDED as new, which is the only way revert can know to
        // delete it rather than leave the round's invention standing.
        let manifest = try readBackupManifest(project, proposal.id)
        XCTAssertEqual(manifest.replaced, ["template.tex"])
        XCTAssertEqual(manifest.created, ["partials/dropcaps.tex"])

        XCTAssertEqual(
            try DesignProposalStore(projectURL: project).load(id: proposal.id).status,
            .approved)
    }

    func test_approve_refusesWhenThereIsNoLivePublishTree() async throws {
        let projectURL = tmp.appendingPathComponent("NoTree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        let proposal = try stage([("template.tex", "PROPOSED")], in: projectURL)

        do {
            try await ProposalPromotion.approve(
                proposal: proposal, projectURL: projectURL, jobManager: CompileJobManager())
            XCTFail("expected a refusal — there is nothing to promote onto")
        } catch let error as ProposalPromotion.Error {
            XCTAssertEqual(error, .noLivePublishTree(projectURL.path))
        }
    }

    /// Defence in depth behind `DesignerReport`'s parse-time guard: a
    /// `proposal.json` is a file on disk, and this is the one place a path that
    /// escaped it would write OUTSIDE the publish tree. The vetting runs before
    /// anything is written, so a refused proposal leaves no backup either.
    func test_approve_refusesAStagedPathThatEscapesThePublishTree() async throws {
        let project = try makeProject()
        let forged = DesignProposalStore.Proposal(
            id: "prop-forged", designerName: "Tschichold", round: 1, language: nil,
            created: Date(), status: .pending, specMarkdown: "# a design",
            filePaths: ["../../escape.tex"], sampleResult: nil, revertNote: nil)

        do {
            try await ProposalPromotion.approve(
                proposal: forged, projectURL: project, jobManager: CompileJobManager())
            XCTFail("expected the escaping path to be refused")
        } catch let error as ProposalPromotion.Error {
            XCTAssertEqual(error, .stagedPathEscapesThePublishTree("../../escape.tex"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: backupDir(project, "prop-forged").path),
            "a refusal before the first write leaves no half-made backup")
    }

    /// A second approve over a standing backup would rebuild that backup from
    /// the already-promoted tree — overwriting the writer's true originals with
    /// the proposal's own bytes, and destroying the only way back.
    func test_approve_refusesWhileABackupAlreadyStands() async throws {
        let project = try makeProject(live: [("template.tex", "LIVE ORIGINAL")])
        let proposal = try stage([("template.tex", "PROPOSED")], in: project)
        try await ProposalPromotion.approve(
            proposal: proposal, projectURL: project, jobManager: CompileJobManager())

        do {
            try await ProposalPromotion.approve(
                proposal: proposal, projectURL: project, jobManager: CompileJobManager())
            XCTFail("expected the standing backup to refuse a second promotion")
        } catch let error as ProposalPromotion.Error {
            XCTAssertEqual(error, .backupAlreadyStands(id: proposal.id))
        }

        let held = backupDir(project, proposal.id).appendingPathComponent("files/template.tex")
        XCTAssertEqual(try text(held), "LIVE ORIGINAL",
                       "the original bytes must survive the second ask")
    }

    // MARK: - the single backup slot

    /// **The trace that names the bug.** With `approve` guarding only its OWN
    /// backup, promotions layer: B's backup captures A's promoted bytes as
    /// though they were the writer's originals, and unwinding both — revert A,
    /// then revert B — walks the tree to A's design and stops. The templates
    /// that were there before any of this exist in no file, no backup and no
    /// proposal, and every step reported success.
    ///
    /// So the slot is single. The refusal names who holds it and both ways out.
    ///
    /// Disable experiment, run 2026-08-20: narrow the guard back to the
    /// proposal's own backup — delete the `proposalHoldingTheBackupSlot` block
    /// in `approve` — and this test fails on the missing throw at approve(B) and
    /// on the live `template.tex` then reading `DESIGN B`, while the other
    /// sixteen tests in this class all still pass. Restored.
    func test_approve_refusesWhileAnotherProposalsBackupStands() async throws {
        let project = try makeProject(live: [("template.tex", "LIVE ORIGINAL")])
        let before = try snapshot(livePublishDir(project))
        let a = try stage([("template.tex", "DESIGN A")], in: project)
        // `stage` supersedes the pending proposal before it, which is the desk's
        // one-pending-slot rule and no obstacle here: promotion never reads a
        // proposal's status.
        let b = try stage([("template.tex", "DESIGN B")], in: project)

        try await ProposalPromotion.approve(
            proposal: a, projectURL: project, jobManager: CompileJobManager())

        do {
            try await ProposalPromotion.approve(
                proposal: b, projectURL: project, jobManager: CompileJobManager())
            XCTFail("expected the standing promotion of \(a.id) to refuse this one")
        } catch let error as ProposalPromotion.Error {
            XCTAssertEqual(error, .anotherProposalHoldsTheBackup(id: a.id),
                           "the refusal names the proposal holding the slot")
            XCTAssertTrue(error.description.contains("Revert"), "and one way out")
            XCTAssertTrue(error.description.contains("finalize"), "and the other")
        }

        // B moved nothing and holds nothing.
        XCTAssertEqual(
            try text(livePublishDir(project).appendingPathComponent("template.tex")),
            "DESIGN A", "a refused promotion moves no live byte")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDir(project, b.id).path),
                       "and makes no second backup to layer over the first")

        // And the way back still reaches the originals.
        try await ProposalPromotion.revert(
            proposal: a, projectURL: project, jobManager: CompileJobManager())
        XCTAssertEqual(try snapshot(livePublishDir(project)), before,
                       "the writer's own templates are still recoverable")
    }

    /// `finalize` is the other way out of the slot: keep this design, and let
    /// the templates it replaced go — deliberately, by name. Then the next
    /// round can be promoted.
    func test_finalize_discardsTheBackup_andFreesTheSlot() async throws {
        let project = try makeProject(live: [("template.tex", "LIVE ORIGINAL")])
        let a = try stage([("template.tex", "DESIGN A")], in: project)
        let b = try stage([("template.tex", "DESIGN B")], in: project)
        try await ProposalPromotion.approve(
            proposal: a, projectURL: project, jobManager: CompileJobManager())

        try ProposalPromotion.finalize(proposal: a, projectURL: project)

        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDir(project, a.id).path),
                       "finalize discards the backup — that is what makes it permanent")
        XCTAssertEqual(
            try DesignProposalStore(projectURL: project).load(id: a.id).status, .approved,
            "finalizing changes what can be undone, not what shipped")

        try await ProposalPromotion.approve(
            proposal: b, projectURL: project, jobManager: CompileJobManager())
        XCTAssertEqual(
            try text(livePublishDir(project).appendingPathComponent("template.tex")),
            "DESIGN B", "the slot is free and the next round promotes")
        // …and B's backup holds what B actually replaced, honestly.
        XCTAssertEqual(
            try text(backupDir(project, b.id).appendingPathComponent("files/template.tex")),
            "DESIGN A")
    }

    func test_finalize_refusesAProposalThatWasNeverPromoted() async throws {
        let project = try makeProject()
        let proposal = try stage([("template.tex", "PROPOSED")], in: project)

        XCTAssertThrowsError(
            try ProposalPromotion.finalize(proposal: proposal, projectURL: project)
        ) { error in
            XCTAssertEqual(error as? ProposalPromotion.Error,
                           .noBackupToFinalize(id: proposal.id))
        }
        XCTAssertEqual(
            try DesignProposalStore(projectURL: project).load(id: proposal.id).status, .pending,
            "a refused finalize changes no status")
    }

    /// A backup standing over a proposal that is NOT approved is the signature
    /// of a promotion that died mid-write (`test_aFailureMidWriteLeavesTheBackupWhole…`
    /// makes one for real): the live tree is half-swapped and that backup is the
    /// only way out. Finalizing it would strand the writer in a design nobody
    /// proposed. The status is put back by hand here because the point under
    /// test is the guard, not the disk failure that produces the state.
    func test_finalize_refusesAPromotionThatDidNotFinish() async throws {
        let project = try makeProject(live: [("template.tex", "LIVE ORIGINAL")])
        let proposal = try stage([("template.tex", "PROPOSED")], in: project)
        try await ProposalPromotion.approve(
            proposal: proposal, projectURL: project, jobManager: CompileJobManager())
        let store = DesignProposalStore(projectURL: project)
        try store.updateStatus(id: proposal.id, .pending)

        XCTAssertThrowsError(
            try ProposalPromotion.finalize(proposal: proposal, projectURL: project)
        ) { error in
            XCTAssertEqual(error as? ProposalPromotion.Error,
                           .notApprovedToFinalize(id: proposal.id, status: "pending"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDir(project, proposal.id).path),
                      "the only way back is still standing")
    }

    /// `finalize` reads the STORE's status, never the caller's copy: `approve`
    /// marks the proposal approved as its last step, so a caller holding the
    /// value it passed to `approve` still reads `.pending`, and a finalize that
    /// trusted it would refuse the ordinary case.
    func test_finalize_readsTheStoredStatusNotTheCallersCopy() async throws {
        let project = try makeProject(live: [("template.tex", "LIVE ORIGINAL")])
        let stale = try stage([("template.tex", "PROPOSED")], in: project)
        XCTAssertEqual(stale.status, .pending, "fixture: the caller's copy predates approve")
        try await ProposalPromotion.approve(
            proposal: stale, projectURL: project, jobManager: CompileJobManager())

        try ProposalPromotion.finalize(proposal: stale, projectURL: project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDir(project, stale.id).path))
    }

    // MARK: - revert

    func test_revert_restoresTheLiveTreeByteIdentically_andDeletesWhatWasNew() async throws {
        let project = try makeProject(live: [
            ("template.tex", "LIVE ORIGINAL"),
            ("styles/book.tex", "UNTOUCHED BY THIS ROUND"),
        ])
        let before = try snapshot(livePublishDir(project))
        let proposal = try stage([
            ("template.tex", "PROPOSED"),
            ("partials/dropcaps.tex", "FRESH"),
        ], in: project)

        try await ProposalPromotion.approve(
            proposal: proposal, projectURL: project, jobManager: CompileJobManager())
        XCTAssertNotEqual(try snapshot(livePublishDir(project)), before)

        try await ProposalPromotion.revert(
            proposal: proposal, projectURL: project, jobManager: CompileJobManager())

        XCTAssertEqual(try snapshot(livePublishDir(project)), before,
                       "revert restores the live tree byte for byte")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: livePublishDir(project).appendingPathComponent("partials/dropcaps.tex").path),
            "a file the round invented is deleted, not left standing")
        // …and so is the directory the round invented to hold it. The snapshot
        // above walks REGULAR FILES only, so an empty `partials/` left behind
        // is invisible to that byte comparison: `pruneEmptyDirectories` needs an
        // assertion that can actually see a directory.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: livePublishDir(project).appendingPathComponent("partials").path),
            "the empty directory the round invented goes with the file")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: livePublishDir(project).appendingPathComponent("styles").path),
            "and the writer's own directories are untouched — pruning stops at "
            + "the first directory with anything in it")

        let reloaded = try DesignProposalStore(projectURL: project).load(id: proposal.id)
        XCTAssertEqual(reloaded.status, .rejected)
        XCTAssertNotNil(reloaded.revertNote, "a reverted proposal says why it is rejected")

        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDir(project, proposal.id).path),
                       "a spent backup is not left to refuse the next promotion")
    }

    func test_revert_carriesTheWritersOwnNoteWhenGivenOne() async throws {
        let project = try makeProject()
        let proposal = try stage([("template.tex", "PROPOSED")], in: project)
        try await ProposalPromotion.approve(
            proposal: proposal, projectURL: project, jobManager: CompileJobManager())

        try await ProposalPromotion.revert(
            proposal: proposal, projectURL: project, jobManager: CompileJobManager(),
            note: "the dropcap fights the running head")

        XCTAssertEqual(
            try DesignProposalStore(projectURL: project).load(id: proposal.id).revertNote,
            "the dropcap fights the running head")
    }

    func test_revert_withNoBackup_refuses() async throws {
        let project = try makeProject()
        let proposal = try stage([("template.tex", "PROPOSED")], in: project)

        do {
            try await ProposalPromotion.revert(
                proposal: proposal, projectURL: project, jobManager: CompileJobManager())
            XCTFail("expected a refusal — nothing was ever promoted")
        } catch let error as ProposalPromotion.Error {
            XCTAssertEqual(error, .noBackupToRestore(id: proposal.id))
        }
        XCTAssertEqual(
            try DesignProposalStore(projectURL: project).load(id: proposal.id).status, .pending,
            "a refused revert changes no status")
    }

    // MARK: - the busy-compile guard

    /// **The failure this guard exists for.** A compile reads the publish tree
    /// file by file; promote into it mid-run and the book is typeset from half
    /// the old design and half the new — an artifact matching no proposal
    /// anyone approved, and no error anywhere to say so.
    ///
    /// Disable experiment: delete the `refuseWhileCompiling` call at the head of
    /// `approve` and this test fails on the missing throw (the promotion
    /// succeeds), not on an assertion downstream.
    func test_approve_refusesWhileACompileIsRunning() async throws {
        let project = try makeProject(live: [("template.tex", "LIVE ORIGINAL")])
        let proposal = try stage([("template.tex", "PROPOSED")], in: project)
        let manager = await busyManager()

        do {
            try await ProposalPromotion.approve(
                proposal: proposal, projectURL: project, jobManager: manager)
            XCTFail("expected the running compile to refuse the promotion")
        } catch let error as ProposalPromotion.Error {
            guard case .compileInProgress(let jobIDs) = error else {
                return XCTFail("expected .compileInProgress, got \(error)")
            }
            XCTAssertEqual(jobIDs.count, 1, "the refusal names what is in the way")
        }

        XCTAssertEqual(
            try text(livePublishDir(project).appendingPathComponent("template.tex")),
            "LIVE ORIGINAL", "a refused promotion moves no live byte")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDir(project, proposal.id).path),
                       "and makes no backup either")
        XCTAssertEqual(
            try DesignProposalStore(projectURL: project).load(id: proposal.id).status, .pending)
    }

    /// The same failure from the other side: revert swaps the tree back under a
    /// compile that is reading it.
    ///
    /// Disable experiment: delete the `refuseWhileCompiling` call at the head of
    /// `revert` and this test fails on the missing throw.
    func test_revert_refusesWhileACompileIsRunning() async throws {
        let project = try makeProject(live: [("template.tex", "LIVE ORIGINAL")])
        let proposal = try stage([("template.tex", "PROPOSED")], in: project)
        try await ProposalPromotion.approve(
            proposal: proposal, projectURL: project, jobManager: CompileJobManager())
        let manager = await busyManager()

        do {
            try await ProposalPromotion.revert(
                proposal: proposal, projectURL: project, jobManager: manager)
            XCTFail("expected the running compile to refuse the revert")
        } catch let error as ProposalPromotion.Error {
            guard case .compileInProgress = error else {
                return XCTFail("expected .compileInProgress, got \(error)")
            }
        }

        XCTAssertEqual(
            try text(livePublishDir(project).appendingPathComponent("template.tex")),
            "PROPOSED", "a refused revert moves no live byte back")
        XCTAssertEqual(
            try DesignProposalStore(projectURL: project).load(id: proposal.id).status, .approved)
    }

    /// A finished compile is not a running one — the guard must not seize on
    /// the job RECORD, or a project that has ever compiled could never promote.
    func test_aFinishedCompileDoesNotRefuseAnything() async throws {
        let project = try makeProject()
        let proposal = try stage([("template.tex", "PROPOSED")], in: project)
        let manager = CompileJobManager()
        let jobID = await manager.register(phase: .compiling)
        await manager.complete(jobID: jobID, outputPath: "/tmp/book.pdf", warnings: [], errors: [])

        try await ProposalPromotion.approve(
            proposal: proposal, projectURL: project, jobManager: manager)
        XCTAssertEqual(
            try text(livePublishDir(project).appendingPathComponent("template.tex")), "PROPOSED")
    }

    // MARK: - a failure mid-write

    /// **The contract's whole point.** The backup completes BEFORE the first
    /// live write, so a promotion that dies halfway — here, on a live directory
    /// the process may read but not write — still leaves a whole backup, and
    /// `revert` puts the tree back exactly as it was.
    ///
    /// The failure is made real (the P1 rollback idiom: chmod the directory to
    /// `0o500`) rather than injected through a seam. There is no seam here, and
    /// the failure under test is the disk's own.
    func test_aFailureMidWriteLeavesTheBackupWhole_andRevertRecovers() async throws {
        let project = try makeProject(live: [
            ("template.tex", "LIVE ORIGINAL"),
            ("locked/style.tex", "LOCKED ORIGINAL"),
        ])
        let before = try snapshot(livePublishDir(project))
        // Ordered so the first write lands and the second is refused: `stage`
        // keeps the report's order and promotion walks it.
        let proposal = try stage([
            ("template.tex", "PROPOSED"),
            ("locked/style.tex", "PROPOSED TOO"),
        ], in: project)

        let fm = FileManager.default
        let locked = livePublishDir(project).appendingPathComponent("locked", isDirectory: true)
        let original = try XCTUnwrap(
            fm.attributesOfItem(atPath: locked.path)[.posixPermissions] as? NSNumber)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: original], ofItemAtPath: locked.path) }

        do {
            try await ProposalPromotion.approve(
                proposal: proposal, projectURL: project, jobManager: CompileJobManager())
            XCTFail("expected the unwritable directory to refuse the second live write")
        } catch {
            // Whatever the disk raised — the point is what survives it.
        }

        // Half-swapped, honestly: the first file went, the second did not.
        let live = livePublishDir(project)
        XCTAssertEqual(try text(live.appendingPathComponent("template.tex")), "PROPOSED")
        XCTAssertEqual(try text(live.appendingPathComponent("locked/style.tex")), "LOCKED ORIGINAL")
        XCTAssertEqual(
            try DesignProposalStore(projectURL: project).load(id: proposal.id).status, .pending,
            "a promotion that did not finish is not approved")

        // The backup is WHOLE — both originals, both recorded — because it was
        // finished before the first live byte moved.
        let held = backupDir(project, proposal.id).appendingPathComponent("files")
        XCTAssertEqual(try text(held.appendingPathComponent("template.tex")), "LIVE ORIGINAL")
        XCTAssertEqual(try text(held.appendingPathComponent("locked/style.tex")), "LOCKED ORIGINAL")
        let manifest = try readBackupManifest(project, proposal.id)
        XCTAssertEqual(manifest.replaced, ["template.tex", "locked/style.tex"])
        XCTAssertTrue(manifest.created.isEmpty)

        // And the way back works.
        try fm.setAttributes([.posixPermissions: original], ofItemAtPath: locked.path)
        try await ProposalPromotion.revert(
            proposal: proposal, projectURL: project, jobManager: CompileJobManager())
        XCTAssertEqual(try snapshot(livePublishDir(project)), before,
                       "revert recovers a half-finished promotion byte for byte")
    }

    /// **The ordering claim, pinned.** The test above is satisfied by an
    /// implementation that backs each file up immediately before writing it —
    /// interleaved, every file's backup still precedes its own write — so it
    /// alone does not earn the sentence "the backup completes before the FIRST
    /// live write". This does: the failure is in the BACKUP phase, at the
    /// second file, and only a promotion that finishes backing up before it
    /// starts writing leaves the first file alone.
    ///
    /// The failure is again the disk's own (the P1 rollback idiom, applied to a
    /// file rather than a directory): a live template the process may not read
    /// cannot be copied into the backup.
    ///
    /// Disable experiment: interleave the two loops in `approve` — back up file
    /// N, write file N, move on — and this test fails on `a.tex` reading
    /// `PROPOSED`, while every other test in this class still passes.
    func test_aFailureDuringTheBackupMovesNoLiveByte() async throws {
        let project = try makeProject(live: [
            ("a.tex", "LIVE ORIGINAL"),
            ("unreadable.tex", "CANNOT BE HELD"),
        ])
        let before = try snapshot(livePublishDir(project))
        let proposal = try stage([
            ("a.tex", "PROPOSED"),
            ("unreadable.tex", "PROPOSED TOO"),
        ], in: project)

        let fm = FileManager.default
        let unreadable = livePublishDir(project).appendingPathComponent("unreadable.tex")
        let original = try XCTUnwrap(
            fm.attributesOfItem(atPath: unreadable.path)[.posixPermissions] as? NSNumber)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? fm.setAttributes([.posixPermissions: original], ofItemAtPath: unreadable.path) }

        do {
            try await ProposalPromotion.approve(
                proposal: proposal, projectURL: project, jobManager: CompileJobManager())
            XCTFail("expected the unreadable live file to refuse the backup")
        } catch {
            // Whatever the disk raised — the point is what did NOT happen.
        }

        try fm.setAttributes([.posixPermissions: original], ofItemAtPath: unreadable.path)
        XCTAssertEqual(try snapshot(livePublishDir(project)), before,
                       "a promotion that could not finish backing up wrote nothing")
        XCTAssertEqual(
            try DesignProposalStore(projectURL: project).load(id: proposal.id).status, .pending)
    }
}
