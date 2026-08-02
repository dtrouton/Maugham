import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// **Where a screenplay's parsed script comes from when no editor is mounted.**
///
/// Slice 2 gave Plan's Structure tab a screenplay's `SceneNavigatorPane`, and
/// Plan centres the canvas — so the one producer of `ProjectWindow`'s
/// `lastParsedScript` (a mounted `EditorCoordinator`, reachable only through
/// `EditorHost`, mounted only when the centre column is a document) does not
/// exist there. The pane got `nil` and drew "No scenes yet" over a script full
/// of them.
///
/// These are the rules of the second producer: what it reads (tripwire 20), when
/// it runs (tripwires 4 and 6), and what it must never do.
@MainActor
final class ScreenplayScriptSourceTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        temp.cleanup()
        temp = nil
    }

    private static let twoScenes =
        "INT. KITCHEN - DAY\n\nLarry sits.\n\nEXT. ROOF - NIGHT\n\nHe climbs.\n"

    // MARK: - When it runs

    /// **The precedence rule, and the whole of why this is a second PRODUCER
    /// rather than a second value** (tripwire 6). A mounted editor's parse is
    /// fresher by construction — it sees keystrokes the op log has not absorbed
    /// yet — so once anything has produced one, the derivation is off. There is
    /// no state in which both write.
    func test_theDerivationIsOffTheMomentAnythingHasProducedAParse() throws {
        let already = FountainTokenizer().parse(Self.twoScenes)
        XCTAssertFalse(
            ScreenplayScriptSource.needsDerivation(
                binderSegment: .tree, projectType: .screenplay, existing: already),
            "an editor's parse must never be overwritten by an op-log derive — "
            + "that is two producers of one value disagreeing, which is the "
            + "shape tripwire 6 exists for")
        XCTAssertTrue(
            ScreenplayScriptSource.needsDerivation(
                binderSegment: .tree, projectType: .screenplay, existing: nil),
            "control: with nothing produced, Plan's tree must derive")
    }

    /// **Exactly one (segment, project type) pair derives, and the census says
    /// which** — asked over every pair rather than the one the fix was written
    /// against, because that is how the original defect got in: `.tree` was a new
    /// member of a set nobody re-enumerated.
    ///
    /// `.scenes` is the interesting NO. It shows the same navigator, but it
    /// mounts `EditorHost` beside it, so the coordinator posts within a frame —
    /// a derive there would be a duplicate op-log decode racing a fresher value.
    func test_onlySluglineSurfacesWithNoEditorBehindThemDerive() throws {
        var derives: [String] = []
        for segment in BinderSegment.allCases {
            for type in ProjectType.allCases {
                guard ScreenplayScriptSource.needsDerivation(
                    binderSegment: segment, projectType: type, existing: nil)
                else { continue }
                derives.append("\(segment.rawValue)×\(type.rawValue)")
            }
        }
        XCTAssertEqual(derives, ["tree×screenplay"],
                       "Plan's tree on a screenplay is the one surface that "
                       + "lists sluglines with no editor behind it. Anything "
                       + "else here is either an op-log decode nobody reads or "
                       + "a race with the editor's own parse")
    }

    /// The registry predicate the rule above is built from, over every pair —
    /// so a future project type whose tree is the scene navigator, or a future
    /// segment that mounts it, is answered here rather than inheriting a `false`.
    func test_theSceneNavigatorSegmentsAreTreeOnAScreenplayAndScenes() throws {
        var shows: [String] = []
        for segment in BinderSegment.allCases {
            for type in ProjectType.allCases
            where segment.showsSceneNavigator(for: type) {
                shows.append("\(segment.rawValue)×\(type.rawValue)")
            }
        }
        XCTAssertEqual(
            shows.sorted(),
            ProjectType.allCases.map { "scenes×\($0.rawValue)" }.sorted()
                + ["tree×screenplay"],
            "`.scenes` is a screenplay's document home and is never offered for "
            + "another type, so it answers yes unconditionally; `.tree` defers "
            + "to `treePane(for:)` rather than re-deriving `== .screenplay`")
    }

    // MARK: - What it reads

    /// **Tripwire 20 / ADR 0018: the derivation reads the OP LOG, never the
    /// `.fountain`.**
    ///
    /// Driven the only way that can tell them apart — the two disagree. The op
    /// log holds the writer's two scenes; the file on disk is then overwritten
    /// with a third that was never typed in Maugham, which is what an external
    /// edit, a stale autosave or a half-written sync leaves behind. A derivation
    /// that read the file would list `INT. NOWHERE`.
    func test_theScenesComeFromTheOpLogAndNotFromTheFountainOnDisk() async throws {
        let store = try await screenplay()
        let url = try await seed(store: store, text: Self.twoScenes)

        try "INT. NOWHERE - NEVER\n\nNobody.\n"
            .write(to: url, atomically: true, encoding: .utf8)  // adr-0018-ok: planting a divergent .md is the point of the test

        let script = try XCTUnwrap(ScreenplayScriptSource.derive(store: store))
        XCTAssertEqual(script.sceneSummaries().map(\.line.content),
                       ["INT. KITCHEN - DAY", "EXT. ROOF - NIGHT"],
                       "the `.md`/`.fountain` is derived output — reading it as "
                       + "truth is the disagreement ADR 0018 closed")
    }

    /// An OPEN document answers from its live text, not from the log behind it.
    /// The op log lags an actively-edited doc by the burst window, so a writer
    /// who typed a scene heading in Author and pressed ⌘1 must see it in Plan.
    func test_anOpenDocumentAnswersFromItsLiveTextAndNotTheLogBehindIt() async throws {
        let store = try await screenplay()
        let url = try await seed(store: store, text: Self.twoScenes)
        let item = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure,
                           where: { $0.type == .document }))
        let path = try XCTUnwrap(item.path)

        let documentStore = try await DocumentStore.open(url: store.url)
        let doc = try await Document.load(
            url: url, device: "test", session: "s", presenter: nil)
        documentStore.register(document: doc, for: path)
        store.documentStore = documentStore
        defer { store.documentStore = nil }

        try await doc.setFullText(
            Self.twoScenes + "\nINT. CELLAR - LATER\n\nShe waits.\n")

        let script = try XCTUnwrap(ScreenplayScriptSource.derive(store: store))
        XCTAssertEqual(script.sceneSummaries().count, 3,
                       "the live Document is fresher than its own op log — a "
                       + "derive that skipped it would show the writer a script "
                       + "one burst window out of date")

        await doc.close()
        await documentStore.close()
    }

    /// A project with no document at all derives nothing rather than an empty
    /// script — `SceneNavigatorPane` already draws that state (no script row),
    /// and a `.empty` parse would tell the window it had a script to show.
    func test_aProjectWithNoDocumentDerivesNothing() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "empty-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        for item in store.manifest.structure where item.type == .document {
            try await store.deleteStructureItem(id: item.id)
        }
        XCTAssertNil(ScreenplayScriptSource.derive(store: store))
    }

    // MARK: - Fixtures

    private func screenplay() async throws -> ProjectStore {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "sp-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    /// Writes `text` into the screenplay's one document and mints its ops, the
    /// way an import does. Returns the document's URL so a test can diverge it.
    @discardableResult
    private func seed(store: ProjectStore, text: String) async throws -> URL {
        let item = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure,
                           where: { $0.type == .document }))
        let url = store.url.appendingPathComponent(try XCTUnwrap(item.path))
        try text.write(to: url, atomically: true, encoding: .utf8)
        let doc = try await Document.load(
            url: url, device: "test", session: "s", presenter: nil)
        await doc.close()
        return url
    }
}
