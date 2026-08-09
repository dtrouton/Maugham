import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ListAllLinksToolTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LAL-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        // ch-1 wiki-links to "Sarah" and "Ch 2"; ch-2 has no wiki links.
        try "Sarah arrives. See [[Sarah]] for backstory. Also [[Ch 2]].".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        try "Continued.".write(
            to: tmp.appendingPathComponent("manuscript/c2.md"),
            atomically: true, encoding: .utf8)
        try "Sarah profile.".write(
            to: tmp.appendingPathComponent("research/sarah.md"),
            atomically: true, encoding: .utf8)
        let ch1 = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                 path: "manuscript/c1.md")
        let ch2 = StructureItem(id: "ch-2", title: "Ch 2", type: .document,
                                 path: "manuscript/c2.md")
        let sarah = ResearchItem(id: "res-sarah", title: "Sarah", type: .asset,
                                  kind: .document, path: "research/sarah.md",
                                  addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1, ch2], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        // ADR 0018: seed the op log before any wiki-scan MCP call.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c2.md"),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    func test_listAllLinks_emitsLinkedResearchEdges() async throws {
        let (url, store, reg) = try await makeProject()
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let edges = try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self, from: json)
        XCTAssertTrue(edges.contains {
            $0.from_id == "ch-1" && $0.to_id == "res-sarah" && $0.kind == "linked_research"
        })
    }

    func test_listAllLinks_emitsWikiEdges_resolvedAndUnresolved() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let edges = try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self, from: json)
        // ch-1's body contains [[Sarah]] (resolves to res-sarah) and [[Ch 2]] (resolves to ch-2).
        XCTAssertTrue(edges.contains {
            $0.from_id == "ch-1" && $0.to_id == "res-sarah" && $0.kind == "wiki"
        }, "expected wiki edge ch-1 → res-sarah")
        XCTAssertTrue(edges.contains {
            $0.from_id == "ch-1" && $0.to_id == "ch-2" && $0.kind == "wiki"
        }, "expected wiki edge ch-1 → ch-2")
    }

    func test_listAllLinks_unresolvedWikiLink_emittedAsUnresolved() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LALU-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "References to [[Nonexistent]] linger here.".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let ch1 = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                 path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        // ADR 0018: seed the op log before any wiki-scan MCP call.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let edges = try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self, from: json)
        // An unresolved wiki target is reported with kind "wiki_unresolved"
        // and the literal target title in to_title; to_id is null.
        XCTAssertTrue(edges.contains {
            $0.from_id == "ch-1" &&
            $0.to_id == nil &&
            $0.to_title == "Nonexistent" &&
            $0.kind == "wiki_unresolved"
        }, "expected unresolved wiki edge for [[Nonexistent]], got: \(edges)")
    }

    /// Smoke caught a chapter linked to a research GROUP returning the group's
    /// id as to_title (group titles weren't indexed). Resolve via group title.
    func test_listAllLinks_linkToResearchGroup_resolvesGroupTitle() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LALG-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        let ch1 = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                 path: "manuscript/c1.md")
        let location = ResearchItem(id: "res-grp-loc", title: "Location",
                                     type: .group, kind: nil,
                                     path: nil, addedAt: Date(),
                                     children: nil)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1], research: [location])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        try await store.linkResearch(researchId: "res-grp-loc", toDocumentId: "ch-1")
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let edges = try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self, from: json)
        let groupEdge = try XCTUnwrap(edges.first { $0.to_id == "res-grp-loc" })
        XCTAssertEqual(groupEdge.to_title, "Location",
            "group link should resolve to group title, not raw id")
        XCTAssertEqual(groupEdge.kind, "linked_research")
    }

    func test_listAllLinks_emitsPieceResearchEdges_forCollections() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LAL-PR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Owned Note")
        _ = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")
        // A group moved into the piece: its nested asset must surface as a
        // piece_research edge (containment is flattened to contained assets).
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let group = try await store.addResearchItem(
            parentId: nil, title: "Setting", kind: nil)
        let nested = try await store.addResearchTextNote(
            parentId: group.id, title: "Harbor")
        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let projectId = ProjectIdentifier.id(for: url)

        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(projectId)\"}".utf8), registry: reg)
        let edges = try JSONDecoder().decode([ListAllLinksTool.Edge].self, from: json)

        XCTAssertTrue(edges.contains {
            $0.kind == "piece_research" && $0.from_id == piece.id && $0.to_id == owned.id
        }, "containment must surface as a piece_research edge; edges: \(edges)")
        XCTAssertFalse(edges.contains {
            $0.kind == "piece_research" && $0.to_title == "Shared Note"
        }, "shared research must not appear as piece_research")
        XCTAssertTrue(edges.contains {
            $0.kind == "piece_research" && $0.from_id == piece.id && $0.to_id == nested.id
        }, "a nested asset of a group moved into the piece is contained; edges: \(edges)")
        XCTAssertFalse(edges.contains {
            $0.kind == "piece_research" && $0.to_id == group.id
        }, "the group node itself is not an asset edge")
        await ds.close()
    }

    /// A dormant manual link (a hand-added link that was then moved into the
    /// piece, so containment now covers it too) must NOT emit both a
    /// `linked_research` AND a `piece_research` edge for the same (piece,
    /// research) pair. Mirror the UI redundancy rule: containment wins, the
    /// linked_research edge is skipped.
    func test_listAllLinks_dormantManualLink_emitsOnlyPieceResearch() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LAL-DORM-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")
        // Hand-add a manual link, THEN move the note into the piece so
        // containment now covers the same association (link goes dormant).
        try await store.linkResearch(researchId: note.id, toDocumentId: piece.id)
        try await store.moveResearchItems(ids: [note.id], to: .piece(piece.id))
        // Sanity: the dormant manual link is still recorded on the piece.
        XCTAssertTrue(store.linkedResearchIds(forDocumentId: piece.id).contains(note.id))

        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let projectId = ProjectIdentifier.id(for: url)
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(projectId)\"}".utf8), registry: reg)
        let edges = try JSONDecoder().decode([ListAllLinksTool.Edge].self, from: json)

        let pairEdges = edges.filter { $0.from_id == piece.id && $0.to_id == note.id }
        XCTAssertEqual(pairEdges.count, 1,
            "exactly one edge for the (piece, research) pair; edges: \(edges)")
        XCTAssertEqual(pairEdges.first?.kind, "piece_research",
            "containment wins — the redundant linked_research edge is skipped")
        await ds.close()
    }

    /// A project whose links live in RESEARCH notes rather than in the
    /// manuscript — which is the only shape canvas promotion can produce.
    private func makeResearchLinkedProject() async throws -> (URL, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LALR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "The falls at night.\n\n[[October's doctor]] — because of the ponchos\n".write(
            to: tmp.appendingPathComponent("research/falls.md"),
            atomically: true, encoding: .utf8)
        try "October's doctor was kind about it.\n\n[[Nobody]]\n".write(
            to: tmp.appendingPathComponent("research/doctor.md"),
            atomically: true, encoding: .utf8)
        // Names itself: the only fixture shape that can actually falsify the
        // self-edge guard — a note whose body wiki-links its OWN title.
        try "This place always echoes back. [[Echo Chamber]] never really left.\n".write(
            to: tmp.appendingPathComponent("research/echo.md"),
            atomically: true, encoding: .utf8)
        let falls = ResearchItem(id: "res-falls", title: "The falls at night", type: .asset,
                                 kind: .document, path: "research/falls.md", addedAt: Date())
        let doctor = ResearchItem(id: "res-doctor", title: "October's doctor", type: .asset,
                                  kind: .document, path: "research/doctor.md", addedAt: Date())
        let echo = ResearchItem(id: "res-echo", title: "Echo Chamber", type: .asset,
                                kind: .document, path: "research/echo.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [falls, doctor, echo])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: try await ProjectStore.load(from: tmp))
        return (tmp, reg)
    }

    private func edges(_ url: URL, _ reg: ProjectRegistry) async throws -> [ListAllLinksTool.Edge] {
        let req = "{\"project_id\":\"\(ProjectIdentifier.id(for: url))\"}"
        return try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self,
            from: try await ListAllLinksTool.handle(paramsJSON: Data(req.utf8), registry: reg))
    }

    /// The whole reason this exists: canvas promotion writes `[[…]]` into a
    /// research note and never into a manuscript document, so a scan that only
    /// reads documents cannot see a single link it produces.
    func test_aWikiLinkInsideAResearchNoteIsAnEdge() async throws {
        let (url, reg) = try await makeResearchLinkedProject()
        let all = try await edges(url, reg)
        XCTAssertTrue(all.contains {
            $0.from_id == "res-falls" && $0.to_id == "res-doctor" && $0.kind == "wiki"
        })
    }

    func test_anUnresolvedLinkInsideAResearchNoteIsStillReported() async throws {
        let (url, reg) = try await makeResearchLinkedProject()
        let all = try await edges(url, reg)
        XCTAssertTrue(all.contains {
            $0.from_id == "res-doctor" && $0.to_id == nil
                && $0.to_title == "Nobody" && $0.kind == "wiki_unresolved"
        })
    }

    func test_aNoteThatNamesItselfIsNotAnEdgeToItself() async throws {
        let (url, reg) = try await makeResearchLinkedProject()
        let all = try await edges(url, reg)
        XCTAssertFalse(all.contains { $0.from_id == $0.to_id })
        // Falsifiable: "res-echo" (Echo Chamber) wiki-links its own title, so
        // this fixture is the one that can actually exercise the guard above —
        // without it the generic assertion is vacuously true.
        XCTAssertFalse(all.contains { $0.from_id == "res-echo" && $0.to_id == "res-echo" })
    }

    /// The existing fixture's research note has no links in it, so the new loop
    /// must add nothing there — a control, so "it found something" means
    /// something.
    func test_aResearchNoteWithNoLinksAddsNoEdges() async throws {
        let (url, _, reg) = try await makeProject()
        let all = try await edges(url, reg)
        XCTAssertFalse(all.contains { $0.from_id == "res-sarah" })
    }

    // MARK: - Statements (whole-branch review, I1)

    /// Seed one statement with a body, through the op log — a statement IS a
    /// `Document`, so writing its `.md` would be writing derived output.
    @discardableResult
    private func seedStatement(
        _ store: ProjectStore, in url: URL,
        kind: Statement.Kind, scope: Statement.Scope, body: String
    ) async throws -> Statement {
        let statement = try await store.createStatement(kind: kind, scope: scope)
        let doc = try await Document.load(
            url: url.appendingPathComponent(statement.path),
            device: "test", session: "s", presenter: nil)
        doc.setFullText(body)
        try await doc.flushBurstNow()
        await doc.close()
        return statement
    }

    /// The capability adoption would otherwise have taken away silently: a
    /// `[[…]]` written into a craft-intent RESEARCH NOTE was an edge here, and
    /// adoption carries that body verbatim into a statement.
    func test_aWikiLinkInsideAStatementIsAnEdge() async throws {
        let (url, store, reg) = try await makeProject()
        let intent = try await seedStatement(
            store, in: url, kind: .intent, scope: .document("ch-1"),
            body: "This chapter answers [[Ch 2]].")
        let all = try await edges(url, reg)
        XCTAssertTrue(all.contains {
            $0.from_id == intent.id && $0.to_id == "ch-2" && $0.kind == "wiki"
        }, "a link written into a chapter's intent is invisible to the link "
            + "graph, which is where adoption put every link a legacy "
            + "craft-intent note held")
    }

    /// The edge has to be readable: `Craft Intent · Ch 1`, not a bare id, and
    /// not the project's name on a chapter's statement.
    func test_aStatementEdgeNamesTheDocumentItIsAbout() async throws {
        let (url, store, reg) = try await makeProject()
        let intent = try await seedStatement(
            store, in: url, kind: .intent, scope: .document("ch-1"),
            body: "This chapter answers [[Ch 2]].")
        let all = try await edges(url, reg)
        XCTAssertEqual(all.first { $0.from_id == intent.id }?.from_title,
                       "Craft Intent · Ch 1")
    }

    /// Visual language is a statement too, and it is the kind
    /// `ArtifactIndex.statementTitle` used to answer for with the wrong word.
    func test_aWikiLinkInsideVisualLanguageIsAnEdgeAndIsNamedAsOne() async throws {
        let (url, store, reg) = try await makeProject()
        let look = try await seedStatement(
            store, in: url, kind: .visualLanguage, scope: .project,
            body: "The look of [[Ch 2]] sets it, and [[Nobody]] does not.")
        let all = try await edges(url, reg)
        XCTAssertEqual(all.first { $0.from_id == look.id }?.from_title,
                       "Visual Language",
                       "the book's visual language was reported under the "
                       + "craft-intent name")
        XCTAssertTrue(all.contains {
            $0.from_id == look.id && $0.to_id == "ch-2" && $0.kind == "wiki"
        })
        XCTAssertTrue(all.contains {
            $0.from_id == look.id && $0.to_id == nil
                && $0.to_title == "Nobody" && $0.kind == "wiki_unresolved"
        })
    }

    /// The control: an EMPTY statement — the ordinary state of one the writer
    /// has opened and not typed into — must add nothing, so "it found an edge"
    /// above means the body was read rather than the registry walked.
    func test_aStatementWithNoLinksAddsNoEdges() async throws {
        let (url, store, reg) = try await makeProject()
        let empty = try await store.createStatement(kind: .intent, scope: .project)
        let prose = try await seedStatement(
            store, in: url, kind: .intent, scope: .document("ch-1"),
            body: "No references at all in here.")
        let all = try await edges(url, reg)
        XCTAssertFalse(all.contains { $0.from_id == empty.id })
        XCTAssertFalse(all.contains { $0.from_id == prose.id })
    }

    // MARK: - Statements as resolution TARGETS (link-machinery, T5)

    /// A line drawn TO a craft-intent card writes `[[Craft Intent · Chapter
    /// 1]]` into a research note. Before this widening a statement's composed
    /// title was never in `titleIndex`, so the link stayed `wiki_unresolved`
    /// forever (issue #24).
    func test_aLinkToAStatementComposedTitleResolves() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LAL-STMT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "Chapter one prose.".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        try "A note referencing [[Craft Intent · Chapter 1]].".write(
            to: tmp.appendingPathComponent("research/note.md"),
            atomically: true, encoding: .utf8)
        let ch1 = StructureItem(id: "ch-1", title: "Chapter 1", type: .document,
                                 path: "manuscript/c1.md")
        let note = ResearchItem(id: "res-note", title: "Note", type: .asset,
                                 kind: .document, path: "research/note.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1], research: [note])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        // ADR 0018: seed the op log before any wiki-scan MCP call.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        let intent = try await store.createStatement(kind: .intent, scope: .document("ch-1"))
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let all = try await edges(tmp, reg)
        XCTAssertTrue(all.contains {
            $0.from_id == "res-note" && $0.to_id == intent.id && $0.kind == "wiki"
        }, "expected a resolved wiki edge from res-note to statement \(intent.id); edges: \(all)")
    }

    /// Docs and research keep beating a statement on a title collision — the
    /// writer-named artifact wins over the composed name. Statements are
    /// inserted into `titleIndex` first (lowest precedence) precisely so this
    /// holds.
    func test_titleCollisionPrefersResearchAndDocsOverStatements() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LAL-COLLIDE-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "Some prose. [[Craft Intent]] mentioned here.".write(
            to: tmp.appendingPathComponent("research/other.md"),
            atomically: true, encoding: .utf8)
        try "This note is literally named Craft Intent.".write(
            to: tmp.appendingPathComponent("research/craft-intent.md"),
            atomically: true, encoding: .utf8)
        let named = ResearchItem(id: "res-craft-intent", title: "Craft Intent", type: .asset,
                                  kind: .document, path: "research/craft-intent.md", addedAt: Date())
        let other = ResearchItem(id: "res-other", title: "Other", type: .asset,
                                  kind: .document, path: "research/other.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [named, other])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        // A project-scope intent statement composes to the bare kind name —
        // "Craft Intent" — with no document suffix, the exact collision shape.
        _ = try await store.createStatement(kind: .intent, scope: .project)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let all = try await edges(tmp, reg)
        XCTAssertTrue(all.contains {
            $0.from_id == "res-other" && $0.to_id == "res-craft-intent" && $0.kind == "wiki"
        }, "a title collision must resolve to the writer-named research note, not the statement; edges: \(all)")
    }

    /// A statement whose body contains its own composed title is not a
    /// self-link — the research-note rule (line 144), applied to the third
    /// source loop.
    func test_aStatementNamingItselfEmitsNoSelfEdge() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LAL-STMTSELF-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let intent = try await store.createStatement(kind: .intent, scope: .project)
        try await store.appendToStatement(
            "This intent names itself: [[Craft Intent]].", to: intent, session: "s")
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let all = try await edges(tmp, reg)
        XCTAssertFalse(all.contains { $0.from_id == intent.id && $0.to_id == intent.id },
            "a statement naming its own composed title must not emit a self-edge")
    }
}
