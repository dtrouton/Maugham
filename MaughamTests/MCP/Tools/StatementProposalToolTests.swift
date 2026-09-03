import XCTest
@testable import Maugham
import MaughamCore

/// `propose_edition_brief` / `propose_visual_language` STAGE a draft and write
/// nothing to a statement (spec §10; ADR 0030 §7). The write is the writer's
/// Adopt, one column away.
@MainActor
final class StatementProposalToolTests: XCTestCase {
    private var temp: TempDirectory!
    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeRegisteredNovel() async throws -> (URL, ProjectStore, DocumentStore, ProjectRegistry) {
        let url = try await ProjectFactory.createNovelProject(named: "ProposeMCP", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg)
    }

    private func proposeBrief(_ reg: ProjectRegistry, projectURL: URL, language: String,
                              markdown: String, rationale: String? = nil) async throws
        -> ProposeEditionBriefTool.Result {
        let id = ProjectIdentifier.id(for: projectURL)
        var params: [String: Any] = ["project_id": id, "language": language, "markdown": markdown]
        if let rationale { params["rationale"] = rationale }
        let json = try await ProposeEditionBriefTool.handle(
            paramsJSON: try JSONSerialization.data(withJSONObject: params), registry: reg)
        return try JSONDecoder().decode(ProposeEditionBriefTool.Result.self, from: json)
    }

    private func proposeLook(_ reg: ProjectRegistry, projectURL: URL, markdown: String) async throws
        -> ProposeVisualLanguageTool.Result {
        let id = ProjectIdentifier.id(for: projectURL)
        let json = try await ProposeVisualLanguageTool.handle(
            paramsJSON: try JSONSerialization.data(withJSONObject: ["project_id": id, "markdown": markdown]),
            registry: reg)
        return try JSONDecoder().decode(ProposeVisualLanguageTool.Result.self, from: json)
    }

    func test_proposingABriefStagesASlotAndCreatesNoStatement() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        defer { Task { await ds.close() } }
        let result = try await proposeBrief(reg, projectURL: url, language: "es",
                                            markdown: "Register: tú.\n\n## Rulings\n\n- «October» → «Octubre»\n",
                                            rationale: "the sample chapter is intimate")
        XCTAssertTrue(result.staged)
        XCTAssertEqual(result.key, "edition-brief-es")
        XCTAssertEqual(result.glossaryEntries, 1)
        XCTAssertFalse(result.supersededPending)
        XCTAssertNil(store.statement(kind: .editionBrief("es"), scope: .project),
                     "a proposal is not a write — no statement may exist until the writer adopts")
        let pending = StatementProposalStore(projectURL: url).pending(for: .editionBrief("es"))
        XCTAssertEqual(pending?.rationale, "the sample chapter is intimate")
        XCTAssertEqual(pending?.author, "Claude")
    }

    func test_aSecondProposalReportsThatItSuperseded() async throws {
        let (url, _, ds, reg) = try await makeRegisteredNovel()
        defer { Task { await ds.close() } }
        _ = try await proposeLook(reg, projectURL: url, markdown: "Serif.")
        let second = try await proposeLook(reg, projectURL: url, markdown: "Sans.")
        XCTAssertTrue(second.supersededPending)
        XCTAssertEqual(StatementProposalStore(projectURL: url).pending(for: .visualLanguage)?.markdown, "Sans.")
    }

    func test_theToolPostsTheProjectScopedChangedEvent() async throws {
        let (url, _, ds, reg) = try await makeRegisteredNovel()
        defer { Task { await ds.close() } }
        var received = 0
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamStatementProposalsChanged, object: nil, queue: nil) { _ in received += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = try await proposeLook(reg, projectURL: url, markdown: "Serif.")
        XCTAssertEqual(received, 1)
    }

    func test_aRefusedProposalIsAnInvalidArgumentAndStagesNothing() async throws {
        let (url, _, ds, reg) = try await makeRegisteredNovel()
        defer { Task { await ds.close() } }
        do {
            _ = try await proposeBrief(reg, projectURL: url, language: "es",
                                       markdown: "x\n\n## Rulings\n\n- ¶k7mq: a directive\n")
            XCTFail("a directive under a proposal's rulings must be refused")
        } catch let error as MCPError {
            guard case .invalidArgument(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("glossary"), message)
        }
        XCTAssertNil(StatementProposalStore(projectURL: url).pending(for: .editionBrief("es")))
        do {
            _ = try await proposeBrief(reg, projectURL: url, language: "ES-MX!", markdown: "x")
            XCTFail("a malformed tag must be refused")
        } catch let error as MCPError {
            guard case .invalidArgument = error else { return XCTFail("\(error)") }
        }
    }

    func test_bothToolsAreInTheCatalogueAndTheCountIs58() {
        let methods = MCPToolCatalog.all.map { $0.method }
        XCTAssertTrue(methods.contains("propose_edition_brief"))
        XCTAssertTrue(methods.contains("propose_visual_language"))
        XCTAssertEqual(MCPToolCatalog.all.count, 59)
    }

    func test_neitherToolIsInTheCompilerAllowlist() {
        let allowed = Set(CompilerAllowlist.tools.map { String($0.dropFirst("mcp__maugham__".count)) })
        XCTAssertFalse(allowed.contains("propose_edition_brief"))
        XCTAssertFalse(allowed.contains("propose_visual_language"))
    }
}
