import XCTest
import MaughamCore
@testable import Maugham

/// Tests that EPUBCompiler persists build/body.xhtml for inspection via
/// `read_publish_file build/body.xhtml` (open-loop iteration workflow).
@MainActor
final class EPUBBodyArtifactTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBBodyArtifactTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_epubCompile_persistsBodyXhtml() async throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "Chapter One",
                       mode: .prose, displayText: "The quick brown fox.")]
            }
        }
        let cfg = PublishConfig(metadata: .init(title: "ArtifactSmoke", author: "T"))
        let mgr = CompileJobManager()
        let compiler = try EPUBCompiler(
            projectURL: tmp, astSource: Src(), config: cfg,
            jobManager: mgr, maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a")

        _ = try await compiler.compile(label: nil)

        let bodyXhtml = tmp
            .appendingPathComponent(".maugham/publish/build/body.xhtml")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bodyXhtml.path),
            "build/body.xhtml not found at \(bodyXhtml.path)")

        let contents = try String(contentsOf: bodyXhtml, encoding: .utf8)
        XCTAssertTrue(
            contents.contains("<section"),
            "build/body.xhtml does not contain <section — contents: \(contents.prefix(500))")
    }

    /// P2 Task 4. With more than one body the joined artifact is written PER
    /// BODY as `build/body.<tag>.xhtml`, and `build/body.xhtml` stays the
    /// FIRST body's — the same spelling `PDFCompiler` uses for
    /// `build/metadata.<tag>.tex` beside `build/metadata.tex`, so a writer
    /// inspecting either pipeline reads the same filenames.
    func test_eachBodyPersistsItsOwnBodyXhtml() async throws {
        struct PerLanguage: LanguageRebindableSource {
            let tag: String?
            static let source = "Sourcelanguageparagraphone."
            static let translated = "Prevedeniparagrafjedan."
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "Opening", mode: .prose,
                       displayText: tag == nil ? Self.source : Self.translated)]
            }
            func rebound(toLanguage tag: String?) -> ProjectASTBuilder.Source {
                PerLanguage(tag: tag)
            }
        }
        var cfg = PublishConfig(metadata: .init(title: "ArtifactSmoke", author: "T"))
        cfg.metadata.language = "en"
        let publish = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        let set = try LanguageSet(language: nil, languages: ["source", "sr"], sourceTag: "en")
        let plan = try BodyPlan.make(
            set: set, resolved: cfg, source: PerLanguage(tag: nil),
            publishDir: publish, wrap: { $0 })
        let compiler = try EPUBCompiler(
            projectURL: tmp, bodies: plan.bodies, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a")

        _ = try await compiler.compile(label: nil)

        let build = publish.appendingPathComponent("build", isDirectory: true)
        func read(_ name: String) throws -> String {
            try String(contentsOf: build.appendingPathComponent(name), encoding: .utf8)
        }
        let listing = ((try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? [])
            .sorted().joined(separator: ", ")
        XCTAssertTrue(try read("body.en.xhtml").contains(PerLanguage.source),
                      "build/ held: \(listing)")
        XCTAssertTrue(try read("body.sr.xhtml").contains(PerLanguage.translated),
                      "build/ held: \(listing)")
        XCTAssertFalse(try read("body.sr.xhtml").contains(PerLanguage.source),
                       "the sr artifact carries the source text")
        XCTAssertEqual(try read("body.xhtml"), try read("body.en.xhtml"),
                       "build/body.xhtml is the FIRST body's, as build/metadata.tex is")
    }
}
