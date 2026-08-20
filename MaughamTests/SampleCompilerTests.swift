import XCTest
import MaughamCore
@testable import Maugham

/// Task 7. The sample compile runs against a SCRATCH copy of the publish tree
/// with the proposal's staged files laid on top — so a design round can be
/// looked at without a single byte of the live templates moving.
///
/// Every test here but `test_endToEnd_…` is tectonic-free: the scratch
/// assembly, the overlay and the live-bytes-untouched contract are all
/// file-system facts, and pinning them behind a real LaTeX compile would make
/// the branch's most load-bearing guarantee skippable on a cold bundle cache.
@MainActor
final class SampleCompilerTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SampleCompilerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixtures

    /// A project with the starter publish tree installed and a saved config.
    private func makeProject(named name: String = "P") async throws -> URL {
        let projectURL = tmp.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        try await PublishStarter.install(into: projectURL, force: false)
        try await PublishConfigStore(projectURL: projectURL).save(
            PublishConfig(metadata: .init(title: "Sample", author: "A")))
        return projectURL
    }

    /// Stage a proposal carrying `files` (path → content) through the real
    /// store, so the scratch overlay reads exactly what staging wrote.
    private func stage(
        _ files: [(path: String, content: String)], in projectURL: URL
    ) throws -> DesignProposalStore.Proposal {
        let report = DesignerReport(
            specMarkdown: "# a design",
            files: files.map { .init(path: $0.path, content: $0.content) })
        return try DesignProposalStore(projectURL: projectURL)
            .stage(report: report, round: 1, designerName: "Tschichold")
    }

    private func livePublishDir(_ projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham/publish", isDirectory: true)
    }

    /// relative path → bytes, for every regular file under `dir`.
    private func snapshot(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let base = dir.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            out[rel] = try Data(contentsOf: url)  // adr-0018-ok: publish templates, not manuscript
        }
        return out
    }

    private struct TwoPieceSource: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "Opening", mode: .prose,
                   displayText: "The first page of the sample."),
             .init(pieceID: "p2", title: "Second", mode: .prose,
                   displayText: "A second piece, not in the sample.")]
        }
    }

    private func selection(_ ids: [String]) -> SamplePageSelection.Selection {
        SamplePageSelection.Selection(
            pieceIds: ids, maxPages: SamplePageSelection.maxPages,
            demonstrates: ids.map { "chapter opener — ‘\($0)’" })
    }

    // MARK: - scratch assembly

    func test_assemble_copiesTheLivePublishTreeIntoTheScratch() async throws {
        let projectURL = try await makeProject()
        let proposal = try stage([], in: projectURL)

        let scratch = try SampleCompiler.assembleScratch(
            proposal: proposal, projectURL: projectURL)

        let live = try snapshot(livePublishDir(projectURL))
        let staged = try snapshot(
            scratch.appendingPathComponent(".maugham/publish", isDirectory: true))
        XCTAssertFalse(live.isEmpty, "fixture: the starter installs real files")
        for (path, bytes) in live {
            XCTAssertEqual(staged[path], bytes,
                           "the scratch must carry the live \(path) byte-for-byte")
        }
    }

    func test_assemble_overlaysTheProposalsFilesOnTopOfTheCopy() async throws {
        let projectURL = try await makeProject()
        let liveTemplate = try String(
            contentsOf: livePublishDir(projectURL).appendingPathComponent("template.tex"),
            encoding: .utf8)
        let proposal = try stage(
            [(path: "template.tex", content: "% STAGED TEMPLATE\n\\documentclass{article}\n")],
            in: projectURL)

        let scratch = try SampleCompiler.assembleScratch(
            proposal: proposal, projectURL: projectURL)

        let scratched = try String(
            contentsOf: scratch.appendingPathComponent(".maugham/publish/template.tex"),
            encoding: .utf8)
        XCTAssertEqual(scratched, "% STAGED TEMPLATE\n\\documentclass{article}\n",
                       "the staged file wins over the live copy")
        XCTAssertNotEqual(scratched, liveTemplate, "fixture: the two differ")
    }

    /// A staged partial with no live counterpart (a proposal may add files, not
    /// only replace them) lands in the scratch with its parent directory made.
    func test_assemble_overlaysAStagedFileThatHasNoLiveCounterpart() async throws {
        let projectURL = try await makeProject()
        let proposal = try stage(
            [(path: "partials/ornaments.tex", content: "% new partial\n")], in: projectURL)

        let scratch = try SampleCompiler.assembleScratch(
            proposal: proposal, projectURL: projectURL)

        let added = scratch.appendingPathComponent(".maugham/publish/partials/ornaments.tex")
        XCTAssertEqual(try String(contentsOf: added, encoding: .utf8), "% new partial\n")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: livePublishDir(projectURL)
                    .appendingPathComponent("partials/ornaments.tex").path),
            "and the live tree gains nothing")
    }

    /// Files-on-top, never a symlink: a symlinked overlay would make a write
    /// through the scratch land in the proposal's own staged copy (and a
    /// symlinked *tree* would put it in the live templates).
    func test_assemble_overlaysRealFilesNeverSymlinks() async throws {
        let projectURL = try await makeProject()
        let proposal = try stage(
            [(path: "template.tex", content: "% staged\n")], in: projectURL)

        let scratch = try SampleCompiler.assembleScratch(
            proposal: proposal, projectURL: projectURL)

        for rel in ["template.tex", "preamble.tex"] {
            let url = scratch.appendingPathComponent(".maugham/publish/\(rel)")
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            XCTAssertEqual(values.isSymbolicLink, false, "\(rel) must be a real file")
        }
    }

    /// THE DISABLE EXPERIMENT TARGET. Assembling a scratch — copy plus overlay —
    /// leaves the live publish tree byte-identical, with no file added and none
    /// removed. Point the overlay at the live dir and this goes red.
    func test_assemble_leavesTheLivePublishTreeUntouched() async throws {
        let projectURL = try await makeProject()
        let before = try snapshot(livePublishDir(projectURL))
        let proposal = try stage([
            (path: "template.tex", content: "% STAGED, must never reach live\n"),
            (path: "preamble.tex", content: "% STAGED PREAMBLE\n"),
            (path: "partials/new.tex", content: "% STAGED NEW FILE\n"),
        ], in: projectURL)

        _ = try SampleCompiler.assembleScratch(proposal: proposal, projectURL: projectURL)

        let after = try snapshot(livePublishDir(projectURL))
        XCTAssertEqual(Set(before.keys), Set(after.keys),
                       "no file added to or removed from the live publish tree")
        XCTAssertEqual(before, after, "the live publish tree's bytes are untouched")
        let liveTemplate = try String(
            contentsOf: livePublishDir(projectURL).appendingPathComponent("template.tex"),
            encoding: .utf8)
        XCTAssertFalse(liveTemplate.contains("STAGED"),
                       "the staged template must not have been written over the live one")
    }

    /// The compiler's own output directory is not copied: everything under
    /// `build/` is written by the compile that is about to run, so copying it
    /// duplicates every prior artifact into every proposal for nothing.
    func test_assemble_doesNotCopyTheLiveBuildDirectory() async throws {
        let projectURL = try await makeProject()
        let buildDir = livePublishDir(projectURL).appendingPathComponent("build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try "stale".write(to: buildDir.appendingPathComponent("compile.log"),
                          atomically: true, encoding: .utf8)
        let proposal = try stage([], in: projectURL)

        let scratch = try SampleCompiler.assembleScratch(
            proposal: proposal, projectURL: projectURL)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent(
                    ".maugham/publish/build/compile.log").path),
            "a stale live artifact must not be copied into the scratch")
    }

    /// A second round in the same proposal folder starts from the live tree
    /// again — a file left by the previous assembly is gone, or a template the
    /// designer has since dropped would keep haunting the sample.
    func test_assemble_startsFromScratchEachTime() async throws {
        let projectURL = try await makeProject()
        let proposal = try stage([], in: projectURL)
        let first = try SampleCompiler.assembleScratch(
            proposal: proposal, projectURL: projectURL)
        let leftover = first.appendingPathComponent(".maugham/publish/leftover.tex")
        try "% from a previous round".write(to: leftover, atomically: true, encoding: .utf8)

        _ = try SampleCompiler.assembleScratch(proposal: proposal, projectURL: projectURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path),
                       "the scratch is rebuilt, not accumulated")
    }

    /// Defence in depth behind Task 3's parse-time path guard: `proposal.json`
    /// is a file on disk, so a hand-edited traversal path must be refused HERE
    /// too — this is the one place an escaping path could write into the live
    /// templates.
    func test_assemble_refusesAStagedPathThatEscapesTheScratch() async throws {
        let projectURL = try await makeProject()
        var proposal = try stage([(path: "template.tex", content: "% ok\n")], in: projectURL)
        proposal = DesignProposalStore.Proposal(
            id: proposal.id, designerName: proposal.designerName, round: proposal.round,
            created: proposal.created, status: proposal.status,
            specMarkdown: proposal.specMarkdown,
            filePaths: ["../../../../publish/template.tex"], sampleResult: nil)
        let before = try snapshot(livePublishDir(projectURL))

        XCTAssertThrowsError(
            try SampleCompiler.assembleScratch(proposal: proposal, projectURL: projectURL),
            "an escaping staged path must be refused, not written")

        XCTAssertEqual(try snapshot(livePublishDir(projectURL)), before,
                       "and nothing outside the scratch is written")
    }

    func test_assemble_failsLoudlyWhenTheProjectHasNoPublishTree() async throws {
        let bare = tmp.appendingPathComponent("bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        let proposal = try stage([], in: bare)

        XCTAssertThrowsError(
            try SampleCompiler.assembleScratch(proposal: proposal, projectURL: bare))
    }

    // MARK: - the compile's refusals (no tectonic)

    /// An empty selection is nothing to demonstrate — and it must never fall
    /// through to `FilteredASTSource`, whose empty-allowlist arm means "all
    /// pieces": a sample that quietly compiled the whole book would be a second
    /// compile wearing a sample's name.
    func test_compile_refusesAnEmptySelectionRatherThanCompilingTheWholeBook() async throws {
        let projectURL = try await makeProject()
        let proposal = try stage([], in: projectURL)

        let outcome = try await SampleCompiler.compile(
            proposal: proposal, selection: selection([]), projectURL: projectURL,
            astSource: TwoPieceSource(), jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")

        guard case .failed(_, let excerpt) = outcome else {
            return XCTFail("an empty selection must fail, got \(outcome)")
        }
        XCTAssertFalse(SampleCompiler.failureSentence(outcome).isEmpty,
                       "the cause rides the result — \(excerpt)")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: SampleCompiler.scratchURL(
                    proposal: proposal, projectURL: projectURL).path),
            "and it refuses before assembling anything")
    }

    /// RULING-7's shape: a failure is recorded ON the proposal, with the cause,
    /// rather than leaving the proposal looking un-sampled.
    func test_compile_recordsAFailureOnTheProposalWithItsCause() async throws {
        let projectURL = try await makeProject()
        let proposal = try stage([], in: projectURL)

        _ = try await SampleCompiler.compile(
            proposal: proposal, selection: selection([]), projectURL: projectURL,
            astSource: TwoPieceSource(), jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")

        let recorded = try DesignProposalStore(projectURL: projectURL)
            .sampleResult(id: proposal.id)
        guard case .failed(let error)? = recorded else {
            return XCTFail("the failure must be recorded, got \(String(describing: recorded))")
        }
        XCTAssertFalse(error.isEmpty, "and it must say why")
    }

    /// A project with no publish tree cannot be sampled — and that is a value on
    /// the result, not a thrown error the caller has to catch to keep the run
    /// alive (spec §6: a sample failure ends the design round clean).
    func test_compile_turnsAnAssemblyFailureIntoTheResultsCause() async throws {
        let bare = tmp.appendingPathComponent("bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        let proposal = try stage([], in: bare)

        let outcome = try await SampleCompiler.compile(
            proposal: proposal, selection: selection(["p1"]), projectURL: bare,
            astSource: TwoPieceSource(), jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")

        guard case .failed = outcome else {
            return XCTFail("a project with no publish tree must fail, got \(outcome)")
        }
        XCTAssertTrue(SampleCompiler.failureSentence(outcome).lowercased().contains("publish"),
                      "the sentence names the real cause: "
                      + SampleCompiler.failureSentence(outcome))
    }

    // MARK: - end to end (real tectonic)

    /// The whole act: stage a template tweak, compile real sample pages against
    /// the staged set, and confirm the tweak was what the compiler read — while
    /// the live publish tree comes out byte-identical.
    func test_endToEnd_compilesSamplePagesAgainstTheStagedTemplateAndTouchesNothingLive() async throws {
        try await TectonicProbe.requireReady()

        let projectURL = try await makeProject()
        let marker = "MAUGHAM-SAMPLE-MARKER-ZQX7"
        let livePreamble = try String(
            contentsOf: livePublishDir(projectURL).appendingPathComponent("preamble.tex"),
            encoding: .utf8)
        // The staged preamble is the live one plus a line that only a compiler
        // reading THIS file could act on — it lands in tectonic's own log.
        let stagedPreamble = livePreamble + "\n\\typeout{\(marker)}\n"
        let proposal = try stage(
            [(path: "preamble.tex", content: stagedPreamble)], in: projectURL)
        let before = try snapshot(livePublishDir(projectURL))

        let outcome = try await SampleCompiler.compile(
            proposal: proposal, selection: selection(["p1"]), projectURL: projectURL,
            astSource: TwoPieceSource(), jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")

        guard case .pages(let path, let demonstrates) = outcome else {
            return XCTFail("the sample compile must produce pages: "
                           + SampleCompiler.failureSentence(outcome))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "the pages PDF must exist at \(path)")
        XCTAssertEqual(demonstrates, selection(["p1"]).demonstrates,
                       "the selection's writer-facing lines ride the outcome")

        let scratch = SampleCompiler.scratchURL(proposal: proposal, projectURL: projectURL)
        XCTAssertTrue(path.hasPrefix(scratch.standardizedFileURL.path),
                      "the PDF is written inside the scratch, never the live tree: \(path)")

        // The staged tweak is what the compiler read.
        let scratchPreamble = try String(
            contentsOf: scratch.appendingPathComponent(".maugham/publish/preamble.tex"),
            encoding: .utf8)
        XCTAssertTrue(scratchPreamble.contains(marker), "the scratch carries the staged tweak")
        let logs = ["build/template.log", "build/compile.log"].compactMap {
            try? String(contentsOf: scratch.appendingPathComponent(".maugham/publish/\($0)"),
                        encoding: .utf8)
        }.joined(separator: "\n")
        XCTAssertTrue(logs.contains(marker),
                      "tectonic's own log must show it read the staged preamble — "
                      + "otherwise the compile ran against something else")

        // …and the live tree never moved.
        let liveNow = try String(
            contentsOf: livePublishDir(projectURL).appendingPathComponent("preamble.tex"),
            encoding: .utf8)
        XCTAssertFalse(liveNow.contains(marker), "the live preamble must not carry the tweak")
        let after = try snapshot(livePublishDir(projectURL))
        XCTAssertEqual(Set(before.keys), Set(after.keys),
                       "a full sample compile adds no file to the live publish tree")
        XCTAssertEqual(before, after,
                       "a full sample compile leaves the live publish tree byte-identical")

        // …and the pages are recorded on the proposal.
        let recorded = try DesignProposalStore(projectURL: projectURL)
            .sampleResult(id: proposal.id)
        XCTAssertEqual(recorded, .pages(path: path))
    }
}
