import XCTest
@testable import Maugham
@testable import MaughamCore

/// **One figure line pointed at its figure** (report plan 8b Task 1): what
/// *Move into Figures* writes after it makes the figure — the line in one
/// piece whose path names a Research file is retargeted at the figure's own
/// file, through the door-checked route (`holdManuscriptsForFigureText` with
/// `FigureTextChange.retargetLine`), in that piece alone. A piece this Mac
/// may not write, or a line that moved, refuses and nothing is written.
@MainActor
final class FigureLineRetargetTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figretarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        ProjectStore.figureRelabelReadFailsForTesting = []
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private static let legacy = "../research/q3.csv"
    private static let moved = "../figures/q3.csv"
    private static let bodyA = "Intro.\n\n![Revenue](../research/q3.csv){#tbl:q3}\n\nAfter.\n"

    /// Chapters A and B, bootstrapped by this Mac's hand, and a window.
    private func openBook(a: String = bodyA, b: String = "More words.\n") async throws -> (DocumentStore, ProjectStore) {
        for (slug, body) in [("a", a), ("b", b)] {
            try body.write(to: chapter(slug), atomically: true, encoding: .utf8)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: ["a", "b"].map {
                StructureItem(id: "doc-\($0)", title: $0.uppercased(), type: .document,
                              path: "manuscript/\($0).md")
            },
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        for slug in ["a", "b"] {
            let doc = try await Document.load(url: chapter(slug), actor: .author, session: "boot", presenter: nil)
            await doc.close()
        }
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func chapter(_ slug: String) -> URL {
        projectURL.appendingPathComponent("manuscript/\(slug).md")
    }

    /// What a chapter says now, derived from its op log.
    private func text(_ slug: String) async throws -> String {
        let doc = try await Document.load(url: chapter(slug), actor: .author, session: "read", presenter: nil)
        let text = doc.displayText
        await doc.close()
        return text
    }

    private func retarget(_ piece: String = "doc-a", line: Int = 2, from old: String = legacy)
        -> ProjectStore.FigureTextChange {
        .retargetLine(piece: piece, lineIndex: line, oldPath: old, newPath: Self.moved)
    }

    /// The whole verb: hold, write, release.
    private func apply(_ change: ProjectStore.FigureTextChange, _ projectStore: ProjectStore) async throws {
        let held = try await projectStore.holdManuscriptsForFigureText(change)
        do { _ = try held.write() } catch { await held.release(); throw error }
        await held.release()
    }

    // MARK: - The edit

    /// Only the path of the line found there changes — caption and label kept;
    /// a line index or path that no longer matches, or a line inside a code
    /// fence, is no site.
    func test_theEditRewritesOnlyThatLinesPath() {
        let edited = ProjectStore.edited(Self.bodyA, retarget())
        XCTAssertEqual(edited, "Intro.\n\n![Revenue](../figures/q3.csv){#tbl:q3}\n\nAfter.\n")
        XCTAssertNil(ProjectStore.edited(Self.bodyA, retarget(line: 0)), "no figure line starts there")
        XCTAssertNil(ProjectStore.edited(Self.bodyA, retarget(from: "../research/other.csv")),
                     "the line's path is not the one found")
        let fenced = "```\n![Revenue](../research/q3.csv){#tbl:q3}\n```\n"
        XCTAssertNil(ProjectStore.edited(fenced, retarget(line: 1)), "a fence holds no figure line")
        let twice = "![A](../research/q3.csv)\n\n![B](../research/q3.csv)\n"
        XCTAssertEqual(ProjectStore.edited(twice, retarget(line: 2)),
                       "![A](../research/q3.csv)\n\n![B](../figures/q3.csv)\n",
                       "the same path on another line is left alone")
    }

    // MARK: - Through the door

    /// **A closed piece**: loaded for the write, retargeted in its op log.
    func test_aClosedPieceIsRetargeted() async throws {
        let (store, projectStore) = try await openBook()
        XCTAssertNil(store.document(for: "manuscript/a.md"), "precondition: A is closed")
        try await apply(retarget(), projectStore)
        let a = try await text("a")
        XCTAssertEqual(a, "Intro.\n\n![Revenue](../figures/q3.csv){#tbl:q3}\n\nAfter.")
    }

    /// **An open piece**: the window's live document takes the edit.
    func test_anOpenPieceIsRetargetedInItsLiveDocument() async throws {
        let (store, projectStore) = try await openBook()
        let live = try await Document.load(url: chapter("a"), actor: .author, session: "live", presenter: nil)
        store.register(document: live, for: "manuscript/a.md")
        try await apply(retarget(), projectStore)
        XCTAssertEqual(live.displayText, "Intro.\n\n![Revenue](../figures/q3.csv){#tbl:q3}\n\nAfter.")
        XCTAssertFalse(live.isClosed, "the window's document stays open")
        store.unregister(path: "manuscript/a.md")
        await live.close()
    }

    /// **Only the chosen piece**: B's text that cannot be read does not refuse
    /// a retarget in A, and B holds the same line untouched.
    func test_onlyTheChosenPieceIsReadAndHeld() async throws {
        let (_, projectStore) = try await openBook(b: Self.bodyA)
        ProjectStore.figureRelabelReadFailsForTesting = ["doc-b"]
        let held = try await projectStore.holdManuscriptsForFigureText(retarget())
        XCTAssertEqual(held.manuscripts.map(\.title), ["A"])
        _ = try held.write()
        await held.release()
        ProjectStore.figureRelabelReadFailsForTesting = []
        let b = try await text("b")
        XCTAssertEqual(b, "Intro.\n\n![Revenue](../research/q3.csv){#tbl:q3}\n\nAfter.", "B is untouched")
    }

    /// **A piece this Mac may not write refuses, naming it, and nothing is
    /// written**; after *Edit Anyway* the same retarget goes through.
    func test_aPieceThisMacMayNotWriteIsRefusedAndNothingIsWritten() async throws {
        let (store, projectStore) = try await openBook(b: Self.bodyA)
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces(["doc-b"])))
        await store.postureSettled()
        XCTAssertEqual(store.posture(forDocId: "doc-b").yieldingTo, "Sam", "precondition: this Mac yields on B")

        do {
            try await apply(retarget("doc-b"), projectStore)
            XCTFail("the retarget was not refused")
        } catch let refused as FigureLineRetargetRefused {
            XCTAssertEqual(refused.reason, .pieceNotWritable("B"))
            XCTAssertTrue(refused.localizedDescription.contains("B"))
        }
        let b = try await text("b")
        XCTAssertEqual(b, "Intro.\n\n![Revenue](../research/q3.csv){#tbl:q3}\n\nAfter.", "nothing written")

        store.overrideYield(docId: "doc-b")
        try await apply(retarget("doc-b"), projectStore)
        let after = try await text("b")
        XCTAssertEqual(after, "Intro.\n\n![Revenue](../figures/q3.csv){#tbl:q3}\n\nAfter.")
    }

    /// **A line that moved since it was found** is not guessed at: refused,
    /// at the hold, and at the write when it moves after the hold.
    func test_aLineThatMovedIsRefusedAndNothingIsWritten() async throws {
        let (store, projectStore) = try await openBook()
        do {
            _ = try await projectStore.holdManuscriptsForFigureText(retarget(line: 3))
            XCTFail("a line that is not there was held")
        } catch let refused as FigureLineRetargetRefused {
            XCTAssertEqual(refused.reason, .lineNotFound)
        }

        let live = try await Document.load(url: chapter("a"), actor: .author, session: "live", presenter: nil)
        store.register(document: live, for: "manuscript/a.md")
        let held = try await projectStore.holdManuscriptsForFigureText(retarget())
        live.setFullText("New first line.\n" + live.displayText)
        let moved = live.displayText
        XCTAssertThrowsError(try held.write()) { error in
            XCTAssertEqual((error as? FigureLineRetargetRefused)?.reason, .lineNotFound)
        }
        XCTAssertEqual(live.displayText, moved, "nothing written")
        await held.release()
        store.unregister(path: "manuscript/a.md")
        await live.close()
    }
}
