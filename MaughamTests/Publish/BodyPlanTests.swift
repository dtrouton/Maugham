import XCTest
import MaughamCore
@testable import Maugham

/// TDD tests for `BodyPlan` — the value that binds each body tag of a
/// `LanguageSet` to its own AST source and its own effective config, so the
/// compilers and the orchestrator never learn the word "languages".
///
/// `@MainActor` because `BodyPlan.make` is: `ProjectStoreASTSource`'s
/// conformance to `ProjectASTBuilder.Source` is main-actor-isolated
/// (SE-0470), so the `LanguageRebindableSource` conformance that refines it
/// is too, and the `as?` that reaches `rebound(toLanguage:)` has to run on
/// that actor.
@MainActor
final class BodyPlanTests: XCTestCase {

    // MARK: - test doubles

    /// A plain, NON-rebindable source with object identity — constraint 2's
    /// subject: a test source that knows nothing about languages must keep
    /// working for a single-body compile.
    private final class MarkerSource: ProjectASTBuilder.Source {
        let name: String
        init(name: String) { self.name = name }
        func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] { [] }
    }

    /// Records, in order, every tag `BodyPlan.make` asked to bind to.
    private final class RebindLog {
        var requested: [String?] = []
        var wrapCalls = 0
    }

    private final class RecordingSource: LanguageRebindableSource {
        let log: RebindLog
        let boundTag: String?
        init(log: RebindLog, boundTag: String? = nil) {
            self.log = log
            self.boundTag = boundTag
        }
        func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] { [] }
        func rebound(toLanguage tag: String?) -> ProjectASTBuilder.Source {
            log.requested.append(tag)
            return RecordingSource(log: log, boundTag: tag)
        }
    }

    /// The include-filter stand-in: whatever `wrap` a caller passes is applied
    /// to every body, so the plan can't hand an unfiltered source to one body.
    private final class WrappedSource: ProjectASTBuilder.Source {
        let base: ProjectASTBuilder.Source
        init(base: ProjectASTBuilder.Source) { self.base = base }
        func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] { try base.orderedPieces() }
    }

    private func tempDir(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BodyPlan-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - one body uses the given source AS GIVEN

    func test_singleSourceBody_usesTheGivenSourceUnrebound() throws {
        let set = try LanguageSet(language: nil, languages: nil, sourceTag: "en")
        let marker = MarkerSource(name: "given")
        let plan = try BodyPlan.make(
            set: set, resolved: PublishConfig(), source: marker,
            publishDir: try tempDir("single"), wrap: { $0 })

        XCTAssertEqual(plan.bodies.count, 1)
        XCTAssertNil(plan.first.tag)
        XCTAssertEqual(plan.first.displayTag, "en")
        XCTAssertTrue(
            (plan.first.source as AnyObject) === marker,
            "a one-body plan must carry the source it was given, not a rebound copy")
    }

    func test_singleTranslatedBody_alsoUsesTheGivenSourceUnrebound() throws {
        // Constraint 2 in its sharper form: even a TRANSLATED single body
        // takes the source as given, because today's single-language callers
        // pass a source already bound to that language.
        let set = try LanguageSet(language: nil, languages: ["sr"], sourceTag: "en")
        let marker = MarkerSource(name: "given")
        let plan = try BodyPlan.make(
            set: set, resolved: PublishConfig(), source: marker,
            publishDir: try tempDir("single-tr"), wrap: { $0 })

        XCTAssertEqual(plan.bodies.count, 1)
        XCTAssertEqual(plan.first.tag, "sr")
        XCTAssertEqual(plan.first.displayTag, "sr")
        XCTAssertTrue((plan.first.source as AnyObject) === marker)
    }

    // MARK: - two or more bodies rebind, in order

    func test_twoBodies_rebindEachTagInOrder() throws {
        let set = try LanguageSet(language: nil, languages: ["source", "sr"], sourceTag: "en")
        let log = RebindLog()
        let plan = try BodyPlan.make(
            set: set, resolved: PublishConfig(), source: RecordingSource(log: log),
            publishDir: try tempDir("two"), wrap: { $0 })

        XCTAssertEqual(log.requested, [nil, "sr"],
                       "every body binds its own tag, in the set's order")
        XCTAssertEqual(plan.bodies.map(\.tag), [nil, "sr"])
        XCTAssertEqual(plan.bodies.map(\.displayTag), ["en", "sr"])
        XCTAssertEqual((plan.bodies[0].source as? RecordingSource)?.boundTag, nil)
        XCTAssertEqual((plan.bodies[1].source as? RecordingSource)?.boundTag, "sr")
        XCTAssertTrue(plan.first.tag == plan.bodies[0].tag, "`first` is body zero")
    }

    func test_threeBodies_keepTheSetsOrder() throws {
        let set = try LanguageSet(
            language: nil, languages: ["sr", "source", "fr"], sourceTag: "en")
        let log = RebindLog()
        let plan = try BodyPlan.make(
            set: set, resolved: PublishConfig(), source: RecordingSource(log: log),
            publishDir: try tempDir("three"), wrap: { $0 })

        XCTAssertEqual(plan.bodies.map(\.tag), set.bodies)
        XCTAssertEqual(log.requested, ["sr", nil, "fr"])
        XCTAssertEqual(plan.bodies.map(\.displayTag), ["sr", "en", "fr"])
    }

    // MARK: - a non-rebindable source with more than one body refuses

    func test_nonRebindableSourceWithTwoBodies_throwsNamingTheProblem() throws {
        let set = try LanguageSet(language: nil, languages: ["source", "sr"], sourceTag: "en")
        XCTAssertThrowsError(
            try BodyPlan.make(
                set: set, resolved: PublishConfig(), source: MarkerSource(name: "given"),
                publishDir: try tempDir("refuse"), wrap: { $0 })
        ) { error in
            let sentence = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(sentence.lowercased().contains("language"),
                          "the refusal must name the problem; got: \(sentence)")
            XCTAssertFalse(sentence.isEmpty)
        }
    }

    func test_nonRebindableSourceWithOneBody_doesNotThrow() throws {
        // The converse of the guard above: one body must NOT be refused.
        let set = try LanguageSet(language: nil, languages: ["sr"], sourceTag: "en")
        XCTAssertNoThrow(
            try BodyPlan.make(
                set: set, resolved: PublishConfig(), source: MarkerSource(name: "given"),
                publishDir: try tempDir("allow"), wrap: { $0 }))
    }

    // MARK: - per-body config: the two folds, applied once each

    func test_perBodyConfig_foldsTheLanguageOverrides() throws {
        // The "en" override is the falsifier: the SOURCE body is `nil`, not
        // `"en"`, so folding it by its display tag would pick this up.
        var config = PublishConfig(
            metadata: .init(title: "The Book", author: "A", language: "en"),
            languageOverrides: [
                "sr": .init(metadata: ["title": "Књига"]),
                "en": .init(metadata: ["title": "NOT the source body's title"])])
        config.nextVersion = "1.0"
        let set = try LanguageSet(language: nil, languages: ["source", "sr"], sourceTag: "en")
        let plan = try BodyPlan.make(
            set: set, resolved: config, source: RecordingSource(log: RebindLog()),
            publishDir: try tempDir("meta"), wrap: { $0 })

        XCTAssertEqual(plan.bodies[0].config.metadata.title, "The Book",
                       "the source body is nil, not `sourceTag` — no override applies to it")
        XCTAssertEqual(plan.bodies[0].config.metadata.language, "en")
        XCTAssertEqual(plan.bodies[1].config.metadata.title, "Књига")
        XCTAssertEqual(plan.bodies[1].config.metadata.language, "sr")
        // Everything outside metadata rides through untouched.
        XCTAssertEqual(plan.bodies[1].config.nextVersion, "1.0")
    }

    func test_perBodyConfig_resolvesLanguageSuffixedStyleFiles() throws {
        let publishDir = try tempDir("styles")
        let pieces = publishDir.appendingPathComponent("pieces", isDirectory: true)
        try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: true)
        try "% sr".write(to: pieces.appendingPathComponent("chapter.sr.tex"),
                         atomically: true, encoding: .utf8)
        // Same falsifier on this side: an `en` variant exists on disk, so a
        // source body folded by its display tag would take it.
        try "% en".write(to: pieces.appendingPathComponent("chapter.en.tex"),
                         atomically: true, encoding: .utf8)

        let config = PublishConfig(
            metadata: .init(title: "T", language: "en"),
            sections: ["p1": .init(styleFile: "chapter.tex")])
        let set = try LanguageSet(language: nil, languages: ["source", "sr"], sourceTag: "en")
        let plan = try BodyPlan.make(
            set: set, resolved: config, source: RecordingSource(log: RebindLog()),
            publishDir: publishDir, wrap: { $0 })

        XCTAssertEqual(plan.bodies[0].config.sections["p1"]?.styleFile, "chapter.tex",
                       "the source body keeps the base style file even though chapter.en.tex exists")
        XCTAssertEqual(plan.bodies[1].config.sections["p1"]?.styleFile, "chapter.sr.tex",
                       "the sr body picks up the suffixed variant that exists on disk")
    }

    // MARK: - wrap reaches every body

    func test_wrapIsAppliedToEveryBody() throws {
        let set = try LanguageSet(
            language: nil, languages: ["source", "sr", "fr"], sourceTag: "en")
        let log = RebindLog()
        let plan = try BodyPlan.make(
            set: set, resolved: PublishConfig(), source: RecordingSource(log: log),
            publishDir: try tempDir("wrap"),
            wrap: { base in
                log.wrapCalls += 1
                return WrappedSource(base: base)
            })

        XCTAssertEqual(log.wrapCalls, 3, "one wrap per body")
        for body in plan.bodies {
            XCTAssertTrue(body.source is WrappedSource,
                          "body \(body.displayTag) must carry the wrapped source")
        }
        // And each wrapper wraps its OWN bound source, not a shared one.
        XCTAssertEqual(
            plan.bodies.compactMap { ($0.source as? WrappedSource)?.base as? RecordingSource }
                .map(\.boundTag),
            [nil, "sr", "fr"])
    }

    func test_wrapIsAppliedToTheSingleGivenSourceToo() throws {
        let set = try LanguageSet(language: nil, languages: nil, sourceTag: "en")
        let log = RebindLog()
        let marker = MarkerSource(name: "given")
        let plan = try BodyPlan.make(
            set: set, resolved: PublishConfig(), source: marker,
            publishDir: try tempDir("wrap1"),
            wrap: { base in
                log.wrapCalls += 1
                return WrappedSource(base: base)
            })

        XCTAssertEqual(log.wrapCalls, 1)
        let wrapped = try XCTUnwrap(plan.first.source as? WrappedSource)
        XCTAssertTrue((wrapped.base as AnyObject) === marker)
    }

    // MARK: - the production source is the rebindable one

    func test_projectStoreASTSourceRebindsToTheAskedLanguage() async throws {
        let tmp = try tempDir("store")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "Body.".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                          atomically: true, encoding: .utf8)
        let item = StructureItem(id: "d-bp1", title: "Ch 1", type: .document,
                                 path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)

        let source = ProjectStoreASTSource(projectStore: store)
        XCTAssertNil(source.language)

        let set = try LanguageSet(language: nil, languages: ["source", "sr"], sourceTag: "en")
        let plan = try BodyPlan.make(
            set: set, resolved: PublishConfig(), source: source,
            publishDir: tmp, wrap: { $0 })

        XCTAssertNil((plan.bodies[0].source as? ProjectStoreASTSource)?.language)
        XCTAssertEqual((plan.bodies[1].source as? ProjectStoreASTSource)?.language, "sr")
        XCTAssertTrue(
            (plan.bodies[1].source as? ProjectStoreASTSource)?.projectStore === store,
            "a rebound source keeps the same live ProjectStore")
    }
}
