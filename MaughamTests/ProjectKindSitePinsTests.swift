import XCTest
import MaughamCore
@testable import Maugham

/// **What each site that asks a project's kind answers, for every
/// `ProjectType` — `.unknown` included (ADR 0015).**
///
/// Plan 7 Task 8 rewrote every `type == .collection` as `holdsPieces` and every
/// `type == .screenplay` as `primaryFormat.isScreenplay`. These pins were run
/// green on the equality spelling first, then kept green across the rewrite:
/// each table is spelled per case, never as the predicate it pins. The census
/// `TripwireGrepTests.test_projectKindAndFormatAreAskedByCapabilityNotByEquality`
/// keeps the equality spelling from returning; Core's
/// `ProjectTypeCapabilityTests` pins the predicates themselves.
@MainActor
final class ProjectKindSitePinsTests: XCTestCase {

    /// Every kind a manifest can decode to, `.unknown` last.
    private let everyKind: [ProjectType] = ProjectType.allCases + [.unknown]

    /// The one kind that holds pieces.
    private func holdsPiecesExpected(_ type: ProjectType) -> Bool {
        switch type {
        case .collection: return true
        case .shortStory, .novel, .screenplay, .unknown: return false
        }
    }

    /// The one kind written in the screenplay family.
    private func screenplayExpected(_ type: ProjectType) -> Bool {
        switch type {
        case .screenplay: return true
        case .shortStory, .novel, .collection, .unknown: return false
        }
    }

    // MARK: - ProjectWindow's routes

    func test_binderShell_isCollectionForACollectionOnly() {
        for type in everyKind {
            XCTAssertEqual(ProjectWindow.BinderShell.shell(for: type),
                           holdsPiecesExpected(type) ? .collection : .standard, "\(type)")
        }
    }

    func test_inspectorRoute_offCanvas_isThePieceInspectorForACollectionOnly() {
        for type in everyKind {
            XCTAssertEqual(ProjectWindow.inspectorRoute(persona: .author, projectType: type),
                           holdsPiecesExpected(type) ? .collectionPiece : .document, "\(type)")
        }
    }

    func test_editorRoute_offCanvas_showsTheReferencePlaceholderForACollectionOnly() {
        for type in everyKind {
            XCTAssertEqual(
                ProjectWindow.editorRoute(persona: .author, projectType: type,
                                          selectedPieceIsReference: true),
                holdsPiecesExpected(type) ? .collectionReference : .editor, "\(type)")
            XCTAssertEqual(
                ProjectWindow.editorRoute(persona: .author, projectType: type,
                                          selectedPieceIsReference: false),
                .editor, "\(type)")
        }
    }

    // MARK: - Research scoping

    private let piece = StructureItem(id: "p1", title: "Alpha", type: .document,
                                      path: "pieces/01-alpha/alpha.md", pieceKind: .loose)
    private let pieceNote = ResearchItem(id: "res-piece", title: "Piece Note", type: .asset,
                                         kind: .document,
                                         path: "pieces/01-alpha/research/note.md")
    private let sharedNote = ResearchItem(id: "res-shared", title: "Shared", type: .asset,
                                          kind: .document)

    func test_pieceResearchSectionRoots_existInACollectionOnly() {
        for type in everyKind {
            let roots = ProjectStore.pieceResearchSectionRoots(
                forDocumentId: "p1", structure: [piece], research: [pieceNote, sharedNote],
                projectType: type)
            XCTAssertEqual(roots.map(\.id), holdsPiecesExpected(type) ? ["res-piece"] : [],
                           "\(type)")
        }
    }

    func test_sharedResearchRoots_dropPieceScopedRootsInACollectionOnly() {
        for type in everyKind {
            let roots = TreeSectionDerivation.sharedResearchRoots(
                research: [pieceNote, sharedNote], projectType: type)
            XCTAssertEqual(roots.map(\.id),
                           holdsPiecesExpected(type) ? ["res-shared"] : ["res-piece", "res-shared"],
                           "\(type)")
        }
    }

    func test_researchMoveTargets_offerLoosePiecesInACollectionOnly() {
        for type in everyKind {
            let manifest = ProjectManifest(
                type: type, title: "T", author: "A", created: Date(), modified: Date(),
                structure: [piece], research: [sharedNote])
            let targets = ResearchSelectionSync.moveTargets(
                forIds: ["res-shared"], manifest: manifest)
            XCTAssertEqual(targets.contains { $0.id == "piece-p1" }, holdsPiecesExpected(type),
                           "\(type)")
        }
    }

    // MARK: - Screenplay-family surfaces

    func test_settingsSheet_screenplayFontsAndSectionForAScreenplayOnly() {
        for type in everyKind {
            let screenplay = screenplayExpected(type)
            XCTAssertEqual(ProjectSettingsSheet.curatedFonts(for: type),
                           screenplay ? TypographySettings.curatedScreenplayFonts
                                      : TypographySettings.curatedFonts, "\(type)")
            XCTAssertEqual(ProjectSettingsSheet.showsScreenplaySection(for: type), screenplay,
                           "\(type)")
        }
    }

    func test_scenePosition_withNoClause_isStrongByFormForAScreenplayOnly() {
        for type in everyKind {
            XCTAssertEqual(ScenePosition.derive(projectType: type, statement: nil, passBrief: nil),
                           screenplayExpected(type) ? .strongDefault : .weak, "\(type)")
        }
        XCTAssertEqual(ScenePosition.derive(projectType: nil, statement: nil, passBrief: nil),
                       .weak, "an absent kind is not a screenplay")
    }

    // MARK: - Store-backed sites

    /// A project of `type` whose one document is a Fountain scene with a slugline,
    /// so `list_scenes` has something to find exactly when it looks.
    private func makeProject(type: ProjectType) async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = TestTemp.root.appendingPathComponent("KSP-\(type)-\(UUID())")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let docURL = tmp.appendingPathComponent("manuscript/s1.fountain")
        try "INT. KITCHEN - DAY\n\nSarah pours coffee.\n".write(
            to: docURL, atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: type, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-1", title: "Scene 1", type: .document,
                                      path: "manuscript/s1.fountain")],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        _ = try await Document.load(url: docURL, device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        XCTAssertEqual(store.manifest.type, type, "the fixture decodes to the kind it was written as")
        let registry = ProjectRegistry()
        registry.register(url: tmp, store: store)
        return (tmp, store, registry)
    }

    func test_listScenes_andPracticePlan_treatAScreenplayOnlyAsScenes() async throws {
        for type in everyKind {
            let (url, store, registry) = try await makeProject(type: type)
            let req = "{\"project_id\":\"\(ProjectIdentifier.id(for: url))\"}"
            let json = try await ListScenesTool.handle(paramsJSON: Data(req.utf8),
                                                       registry: registry)
            let scenes = try JSONDecoder().decode([ListScenesTool.Scene].self, from: json)
            XCTAssertEqual(scenes.count, screenplayExpected(type) ? 1 : 0, "\(type)")

            XCTAssertEqual(ProjectPractice.Plan(store: store).isScreenplay,
                           screenplayExpected(type), "\(type)")
        }
    }

    /// The six collection-only store verbs share one guard; outside a
    /// collection each refuses with its own "only valid for Collection" error
    /// before touching anything, and inside one the guard lets it through.
    func test_collectionOnlyStoreVerbs_refuseOutsideACollection() async throws {
        for type in everyKind {
            let (url, store, _) = try await makeProject(type: type)
            let elsewhere = url.deletingLastPathComponent()
                .appendingPathComponent("KSP-dest-\(UUID())")
            let verbs: [(String, () async throws -> Void)] = [
                ("addLoosePiece", { _ = try await store.addLoosePiece(title: "X", format: .markdown) }),
                ("addProjectReference", { _ = try await store.addProjectReference(targetURL: elsewhere) }),
                ("promotePieceToProject", {
                    _ = try await store.promotePieceToProject(pieceId: "nope", destination: elsewhere)
                }),
                ("resolveLoosePiece", { _ = try store.resolveLoosePiece("nope") }),
                ("movePiece", { try await store.movePiece(pieceId: "nope", toIndex: 0) }),
                ("renamePiece", { try await store.renamePiece(pieceId: "nope", newTitle: "Y") }),
            ]
            for (name, verb) in verbs {
                var refusedByTheGuard = false
                do {
                    try await verb()
                } catch let ProjectStoreError.fileSystemError(message) {
                    refusedByTheGuard = message.contains("only valid for Collection projects")
                } catch {}
                XCTAssertEqual(refusedByTheGuard, !holdsPiecesExpected(type), "\(type) \(name)")
            }
        }
    }
}
