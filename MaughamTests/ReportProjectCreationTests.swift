import XCTest
import CryptoKit
import MaughamCore
@testable import Maugham

/// Report plan 4, Task 7 (R-4-6): a Report in New Project, in two shapes, with
/// its own PDF starter.
///
/// - **Single document** is the short-story shape with its root file named
///   `report.md`; **Sections** is the novel shape whose first section is
///   "Introduction". Both write `profile: .report` and nothing else (the
///   switches default from the profile), and install the Report starter.
/// - The starter's `report/` variant overrides template, frontmatter, prose
///   and the default config (`formats_enabled: ["pdf","docx"]`); everything
///   else is the book starter's own file.
/// - A screenplay with a profile is refused before anything is written.
/// - A new Novel's files are pinned byte for byte (review focus 3).
final class ReportProjectCreationTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() {
        super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    // MARK: - helpers

    private func manifest(at url: URL) throws -> ProjectManifest {
        let data = try Data(contentsOf: url.appendingPathComponent(ProjectManifest.fileName))
        return try ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: data)
    }

    private func rawManifest(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url.appendingPathComponent(ProjectManifest.fileName))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func installed(_ name: String, in url: URL) throws -> Data {
        try Data(contentsOf: url.appendingPathComponent(".maugham/publish/\(name)"))
    }

    private func bundled(_ name: String, variant: String? = nil) throws -> Data {
        let sub = variant.map { "PublishStarter/\($0)" } ?? "PublishStarter"
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: nil, subdirectory: sub),
                                "the app bundle ships \(sub)/\(name)")
        return try Data(contentsOf: url)
    }

    private func text(_ name: String, in url: URL) throws -> String {
        String(decoding: try installed(name, in: url), as: UTF8.self)
    }

    /// The files every variant takes from the book starter unchanged.
    private static let sharedFiles = ["preamble.tex", "screenplay.tex", "backmatter.tex",
                                      "styles.css", "EMISSION.md"]

    private func assertReportStarter(_ url: URL, prose: String, name: String,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        for shared in Self.sharedFiles {
            XCTAssertEqual(try installed(shared, in: url), try bundled(shared),
                           "\(shared) is the book starter's", file: file, line: line)
        }
        XCTAssertEqual(try installed("frontmatter.tex", in: url), try bundled("frontmatter.tex", variant: "report"),
                       file: file, line: line)
        XCTAssertEqual(try installed("prose.tex", in: url), try bundled(prose, variant: "report"),
                       file: file, line: line)
        // Installed as bundled: the paper and the title are decided at each
        // compile (R-S7, M2), never written in at install.
        XCTAssertEqual(try installed("template.tex", in: url), try bundled("template.tex", variant: "report"),
                       file: file, line: line)
        XCTAssertEqual(try installed("config.json", in: url), try bundled("default-config.json", variant: "report"),
                       file: file, line: line)
        let template = try text("template.tex", in: url)
        XCTAssertTrue(template.contains("Report starter"), "the Report template", file: file, line: line)
        XCTAssertTrue(template.contains("\\documentclass[11pt]{article}"), file: file, line: line)
        XCTAssertTrue(template.contains("\\providecommand{\\MaughamPaper}{a4paper}"),
                      "the fallback for a compile by hand", file: file, line: line)
        let config = try XCTUnwrap(try PublishConfigStore.read(in: url))
        XCTAssertEqual(config.outputs.formatsEnabled, [.pdf, .docx], file: file, line: line)
        XCTAssertEqual(config.nextVersion, "0.1", file: file, line: line)
    }

    // MARK: - the two shapes

    func test_aSingleDocumentReport_isTheShortStoryShape_withReportMd_andTheReportStarter() async throws {
        let url = try await ProjectFactory.createReportProject(
            named: "Quarterly", in: temp.url, shape: .singleDocument)

        let m = try manifest(at: url)
        XCTAssertEqual(m.type, .shortStory)
        XCTAssertEqual(m.profile, .report)
        XCTAssertEqual(m.structure.map(\.path), ["report.md"])
        XCTAssertEqual(m.structure.first?.title, "Quarterly")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("report.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("story.md").path))

        // Only the profile is written: the switches are its defaults.
        let raw = try rawManifest(at: url)
        XCTAssertEqual(raw["profile"] as? String, "report")
        XCTAssertNil(raw["switches"], "the switches are never seeded")
        XCTAssertEqual(raw["schemaVersion"] as? Int, 10)
        XCTAssertEqual(m.effectiveSwitches.numberSections, true)

        try assertReportStarter(url, prose: "prose-single.tex", name: "Quarterly")
        XCTAssertEqual(ProjectKindName.of(m), "Report")
    }

    func test_aSectionsReport_isTheNovelShape_withAnIntroduction_andTheReportStarter() async throws {
        let url = try await ProjectFactory.createReportProject(
            named: "Annual", in: temp.url, shape: .sections)

        let m = try manifest(at: url)
        XCTAssertEqual(m.type, .novel)
        XCTAssertEqual(m.profile, .report)
        XCTAssertEqual(m.structure.map(\.title), ["Introduction"])
        let path = try XCTUnwrap(m.structure.first?.path)
        XCTAssertTrue(path.hasPrefix("manuscript/") && path.hasSuffix("introduction.md"), path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path))
        XCTAssertNil(try rawManifest(at: url)["switches"])

        try assertReportStarter(url, prose: "prose.tex", name: "Annual")
    }

    /// The starter takes the shape from the manifest, so a re-install (MCP
    /// `initialize_publish_template`'s force) restores the Report files.
    func test_aForcedReinstall_restoresTheReportStarterFromTheManifest() async throws {
        let url = try await ProjectFactory.createReportProject(
            named: "Again", in: temp.url, shape: .singleDocument)
        let template = url.appendingPathComponent(".maugham/publish/template.tex")
        try "% mutated".write(to: template, atomically: true, encoding: .utf8)
        try await PublishStarter.install(into: url, force: true)
        try assertReportStarter(url, prose: "prose-single.tex", name: "Again")
    }

    // MARK: - the variant and the paper

    func test_theVariantComesFromTheProfileAndTheShape() {
        func m(_ type: ProjectType, _ profile: ProjectProfile?) -> ProjectManifest {
            ProjectManifest(type: type, title: "T", author: "", created: Date(), modified: Date(),
                            structure: [], research: [], profile: profile)
        }
        XCTAssertEqual(PublishStarter.variant(for: nil), .book, "no manifest yet: the book starter")
        XCTAssertEqual(PublishStarter.variant(for: m(.novel, nil)), .book)
        XCTAssertEqual(PublishStarter.variant(for: m(.shortStory, nil)), .book)
        XCTAssertEqual(PublishStarter.variant(for: m(.novel, .unknown("essay"))), .book)
        XCTAssertEqual(PublishStarter.variant(for: m(.shortStory, .report)), .report(singleDocument: true))
        XCTAssertEqual(PublishStarter.variant(for: m(.novel, .report)), .report(singleDocument: false))
        XCTAssertEqual(PublishStarter.variant(for: m(.screenplay, .report)), .book,
                       "a hand-made screenplay Report keeps the book starter")
    }

    private func context(_ profile: ProjectProfile?, title: String? = "Quarterly") -> PublishContext {
        PublishContext(library: CitationLibrary(items: []), profile: profile,
                       switches: (numberSections: false, listOfFigures: false, listOfTables: false),
                       projectURL: nil, piecePaths: [:], projectTitle: title)
    }

    /// R-S7: a Report's paper is decided at every compile — A4 unless the
    /// region is the US or Canada, the Word export's own rule — and a book
    /// without the profile gets none, so its `metadata.tex` keeps its bytes.
    func test_aReportsPaperFollowsTheRegion_andNoOtherBookHasOne() {
        let report = context(.report)
        XCTAssertEqual(PDFCompiler.reportPaper(context: report, language: "en", fallbackRegion: "US"), "letterpaper")
        XCTAssertEqual(PDFCompiler.reportPaper(context: report, language: "en", fallbackRegion: "CA"), "letterpaper")
        XCTAssertEqual(PDFCompiler.reportPaper(context: report, language: "en", fallbackRegion: "GB"), "a4paper")
        XCTAssertEqual(PDFCompiler.reportPaper(context: report, language: "en", fallbackRegion: nil), "a4paper")
        XCTAssertEqual(PDFCompiler.reportPaper(context: report, language: "en-GB", fallbackRegion: "US"), "a4paper",
                       "a tagged region wins")
        for page in [("en", "US"), ("en-GB", nil), ("fr-CA", "FR")] {
            XCTAssertEqual(PDFCompiler.reportPaper(context: report, language: page.0, fallbackRegion: page.1) == "letterpaper",
                           DOCXCompiler.page(forLanguage: page.0, fallbackRegion: page.1) == .letter,
                           "the PDF and the .docx agree for \(page)")
        }
        XCTAssertNil(PDFCompiler.reportPaper(context: context(nil), language: "en", fallbackRegion: "US"))
        XCTAssertNil(PDFCompiler.reportPaper(context: context(.unknown("essay")), language: "en", fallbackRegion: "US"))
        XCTAssertNil(PDFCompiler.reportPaper(context: .empty, language: "en", fallbackRegion: "US"))

        let cfg = PublishConfig()
        XCTAssertEqual(PDFCompiler.documentMetadata(config: cfg, label: nil, resolutions: [], paper: nil),
                       PDFCompiler.metadataBlock(config: cfg, label: nil), "no paper, no line")
        XCTAssertTrue(PDFCompiler.documentMetadata(config: cfg, label: nil, resolutions: [], paper: "letterpaper")
            .hasSuffix("\n\\def\\MaughamPaper{letterpaper}"))
    }

    /// M2: a Report's title page names the project while the config's title
    /// is the starter's "Untitled" (or empty); a title the writer set wins;
    /// every other book's config is untouched.
    func test_aReportsUntitledConfig_takesTheProjectsTitle_andNothingElseChanges() {
        var untitled = PublishConfig()
        XCTAssertEqual(untitled.metadata.title, "Untitled", "premise: the starter's title")
        XCTAssertEqual(PDFCompiler.reportConfig(untitled, context: context(.report)).metadata.title, "Quarterly")
        untitled.metadata.title = "  "
        XCTAssertEqual(PDFCompiler.reportConfig(untitled, context: context(.report)).metadata.title, "Quarterly")
        var named = PublishConfig()
        named.metadata.title = "Q3 Review"
        XCTAssertEqual(PDFCompiler.reportConfig(named, context: context(.report)).metadata.title, "Q3 Review")
        XCTAssertEqual(PDFCompiler.reportConfig(PublishConfig(), context: context(nil)).metadata.title, "Untitled")
        XCTAssertEqual(PDFCompiler.reportConfig(PublishConfig(), context: context(.report, title: nil)).metadata.title,
                       "Untitled")
    }

    // MARK: - refusals

    func test_aScreenplayWithAProfile_isRefused_andNothingIsWritten() async throws {
        do {
            _ = try await ProjectFactory.createScreenplayProject(
                named: "Script", in: temp.url, profile: .report)
            XCTFail("a screenplay with a profile must be refused")
        } catch let error as ProjectFactoryError {
            XCTAssertEqual(error, .profileNotOffered(.report, on: .screenplay))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("Script").path))
    }

    func test_anUnknownProfile_isRefused() async throws {
        do {
            _ = try await ProjectFactory.createNovelProject(
                named: "Odd", in: temp.url, profile: .unknown("essay"))
            XCTFail("an unknown profile must be refused")
        } catch let error as ProjectFactoryError {
            XCTAssertEqual(error, .profileNotOffered(.unknown("essay"), on: .novel))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("Odd").path))
    }

    // MARK: - old kinds unchanged (review focus 3)

    /// The golden: a new Novel's starter is byte-identical to the book starter
    /// as it stood before the Report variant (SHA-256 of each installed file,
    /// captured at 231e080c), and its manifest carries no profile.
    func test_aNewNovel_isByteIdenticalToBefore() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "Golden", in: temp.url)
        let golden: [String: String] = [
            "backmatter.tex": "f9e196a3871432d8e28dd1079a432d4474f6494c76b5089588df289892128e89",
            "config.json": "85dfc7c2b44b1457704bb965e0ebb682723ab7c1be132daaa3539f8caccb1c6a",
            "EMISSION.md": "f2d5d7e409d9e78333e9c61951388300d4fa613f069b544e89ed80be06b6fa35",
            "frontmatter.tex": "0537b0bf87fd28119e7c55134f786e95ed0ea5a6bdf972210f5b62521312390b",
            "preamble.tex": "6d6e044b7729318a1c25b75f0793e70124c9c1521f6faf2b6f27f31bb75525cc",
            "prose.tex": "233eea1e200b03d427a0bfc236138790d4b46b2be3d26654559ee6013e4f239d",
            "screenplay.tex": "1e64bde54f8b534ad8957637a3c2db7a6b9a209677a8f3231b3e25e0eea187bf",
            "styles.css": "08a12f8801573fb0b8fbf3c17679613b51acf724663b060da3488f7d4efaa0df",
            "template.tex": "08decc2f49fedaca9a193ac4db0025d3ef77b09d0274a45cbfc0b71c48685463",
        ]
        let publish = url.appendingPathComponent(".maugham/publish")
        let names = try FileManager.default.contentsOfDirectory(atPath: publish.path).sorted()
        XCTAssertEqual(names, golden.keys.sorted(), "exactly the book starter's files")
        for (name, hash) in golden {
            let digest = SHA256.hash(data: try installed(name, in: url))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, hash, "\(name) changed")
        }
        let m = try manifest(at: url)
        XCTAssertNil(m.profile)
        XCTAssertNil(try rawManifest(at: url)["profile"])
        XCTAssertEqual(m.structure.map(\.title), ["Chapter 1"])
        XCTAssertEqual(PublishStarter.variant(for: m), .book)
    }

    func test_aNewShortStory_keepsStoryMd_andTheBookStarter() async throws {
        let url = try await ProjectFactory.createShortStoryProject(named: "Tale", in: temp.url)
        XCTAssertEqual(try manifest(at: url).structure.map(\.path), ["story.md"])
        XCTAssertNil(try manifest(at: url).profile)
        XCTAssertEqual(try installed("template.tex", in: url), try bundled("template.tex"))
        XCTAssertEqual(try installed("prose.tex", in: url), try bundled("prose.tex"))
        XCTAssertEqual(try installed("config.json", in: url), try bundled("default-config.json"))
    }

    // MARK: - New Project's choices

    func test_newProjectOffersTheFourTypesAndReport_eachNamedByProjectKindName() {
        XCTAssertEqual(NewProjectChoice.all.map(\.name),
                       ProjectType.allCases.map { ProjectKindName.of($0) } + [ProjectKindName.of(ProjectProfile.report)])
        XCTAssertEqual(NewProjectChoice.all.last, .report)
        XCTAssertTrue(NewProjectChoice.report.asksForAShape)
        XCTAssertFalse(NewProjectChoice.all.dropLast().contains { $0.asksForAShape })
    }

    func test_newProjectsReportChoice_createsEachShape() async throws {
        let single = try await NewProjectChoice.report.create(named: "One", in: temp.url, shape: .singleDocument)
        XCTAssertEqual(try manifest(at: single).type, .shortStory)
        XCTAssertEqual(try manifest(at: single).profile, .report)
        let sections = try await NewProjectChoice.report.create(named: "Many", in: temp.url, shape: .sections)
        XCTAssertEqual(try manifest(at: sections).type, .novel)
        XCTAssertEqual(try manifest(at: sections).profile, .report)
        let novel = try await NewProjectChoice.kind(.novel).create(named: "Book", in: temp.url, shape: .sections)
        XCTAssertNil(try manifest(at: novel).profile, "the shape is asked of a Report only")
    }
}
