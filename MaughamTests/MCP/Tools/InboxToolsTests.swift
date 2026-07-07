import XCTest
import MaughamCore
@testable import Maugham

/// `promote_inbox_entry` with the optional `target_document_id` scope
/// (spec 2026-07-07). The tool resolves the live inbox via
/// store.documentStore.inboxStore, so tests wire a real DocumentStore.
@MainActor
final class InboxToolsTests: XCTestCase {

    private func openNovelWithRegistry() async throws
        -> (URL, ProjectStore, DocumentStore, ProjectRegistry, String) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("inboxtool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createNovelProject(named: "IT", in: parent)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg, ProjectIdentifier.id(for: url))
    }

    private func seed(_ url: URL, _ entries: [InboxEntry]) async throws {
        let file = url.appendingPathComponent(".maugham/inbox/inbox.seed.jsonl")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        let s = JSONLAppendStore<InboxEntry>(fileURL: file)
        for e in entries { try await s.append(e) }
    }

    func test_promote_withTargetDocumentId_linksToChapter() async throws {
        let (url, store, ds, reg, projectId) = try await openNovelWithRegistry()
        let chapterId = try XCTUnwrap(
            TreeWalk.collect(in: store.manifest.structure,
                             where: { $0.type == .document }).first?.id)
        try await seed(url, [InboxEntry(
            id: "e1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Scoped capture.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e1","target_document_id":"\#(chapterId)"}"#
        let data = try await PromoteInboxEntryTool.handle(
            paramsJSON: Data(params.utf8), registry: reg)
        let result = try JSONDecoder().decode(
            PromoteInboxEntryTool.Result.self, from: data)

        XCTAssertTrue(store.linkedResearchIds(forDocumentId: chapterId)
            .contains(result.research_id))
        withExtendedLifetime(ds) {}
    }

    func test_promote_withoutTarget_isSharedAndUnlinked() async throws {
        let (url, store, ds, reg, projectId) = try await openNovelWithRegistry()
        try await seed(url, [InboxEntry(
            id: "e2", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Plain capture.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e2"}"#
        let data = try await PromoteInboxEntryTool.handle(
            paramsJSON: Data(params.utf8), registry: reg)
        let result = try JSONDecoder().decode(
            PromoteInboxEntryTool.Result.self, from: data)

        XCTAssertTrue(result.path.hasPrefix("research/"))
        withExtendedLifetime(ds) {}
    }

    func test_promote_unknownTargetDocumentId_failsLoudly() async throws {
        let (url, _, ds, reg, projectId) = try await openNovelWithRegistry()
        try await seed(url, [InboxEntry(
            id: "e3", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Doomed capture.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e3","target_document_id":"doc-nope"}"#
        do {
            _ = try await PromoteInboxEntryTool.handle(
                paramsJSON: Data(params.utf8), registry: reg)
            XCTFail("expected throw for unknown target_document_id")
        } catch { /* expected */ }
        withExtendedLifetime(ds) {}
    }
}
