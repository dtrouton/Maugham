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

    // MARK: - Palette destination (Task 8)

    func test_promote_withPaletteCardId_landsNoteOnCard() async throws {
        let (url, store, ds, reg, projectId) = try await openNovelWithRegistry()
        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try await seed(url, [InboxEntry(
            id: "e4", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Damp plaster smell.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e4","palette_card_id":"\#(item.id)"}"#
        let data = try await PromoteInboxEntryTool.handle(
            paramsJSON: Data(params.utf8), registry: reg)
        let result = try JSONDecoder().decode(PromoteInboxEntryTool.Result.self, from: data)

        XCTAssertEqual(result.research_id, item.id)
        XCTAssertEqual(result.title, "The Flat")
        XCTAssertTrue(result.path.hasPrefix("research/"))
        let card = store.loadPaletteCards().first(where: { $0.researchItemId == item.id })
        XCTAssertEqual(card?.notes.map(\.text), ["Damp plaster smell."])
        withExtendedLifetime(ds) {}
    }

    func test_promote_withPaletteSubject_caseInsensitiveMatch() async throws {
        let (url, store, ds, reg, projectId) = try await openNovelWithRegistry()
        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try await seed(url, [InboxEntry(
            id: "e5", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Creaky floorboard.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e5","palette_subject":"the flat"}"#
        let data = try await PromoteInboxEntryTool.handle(
            paramsJSON: Data(params.utf8), registry: reg)
        let result = try JSONDecoder().decode(PromoteInboxEntryTool.Result.self, from: data)

        XCTAssertEqual(result.research_id, item.id)
        let card = store.loadPaletteCards().first(where: { $0.researchItemId == item.id })
        XCTAssertEqual(card?.notes.map(\.text), ["Creaky floorboard."])
        withExtendedLifetime(ds) {}
    }

    func test_promote_paletteSubjectNoMatch_failsWithExistingTitlesListed() async throws {
        let (url, store, ds, reg, projectId) = try await openNovelWithRegistry()
        _ = try await store.addPaletteCard(title: "The Flat", kind: .location)
        _ = try await store.addPaletteCard(title: "Marlowe", kind: .character)
        try await seed(url, [InboxEntry(
            id: "e6", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Orphan note.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e6","palette_subject":"Nonexistent"}"#
        do {
            _ = try await PromoteInboxEntryTool.handle(
                paramsJSON: Data(params.utf8), registry: reg)
            XCTFail("expected throw for unmatched palette_subject")
        } catch let MCPError.invalidArgument(message) {
            XCTAssertTrue(message.contains("The Flat"))
            XCTAssertTrue(message.contains("Marlowe"))
        } catch {
            XCTFail("expected MCPError.invalidArgument, got \(error)")
        }
        // The tool must not have minted a new card for the unmatched subject.
        XCTAssertEqual(store.paletteCardItems().count, 2)
        withExtendedLifetime(ds) {}
    }

    func test_promote_targetDocumentIdAndPaletteCardId_areMutuallyExclusive() async throws {
        let (url, store, ds, reg, projectId) = try await openNovelWithRegistry()
        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        let chapterId = try XCTUnwrap(
            TreeWalk.collect(in: store.manifest.structure,
                             where: { $0.type == .document }).first?.id)
        try await seed(url, [InboxEntry(
            id: "e7", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Ambiguous capture.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e7","target_document_id":"\#(chapterId)","palette_card_id":"\#(item.id)"}"#
        do {
            _ = try await PromoteInboxEntryTool.handle(
                paramsJSON: Data(params.utf8), registry: reg)
            XCTFail("expected throw for conflicting destinations")
        } catch let MCPError.invalidArgument(message) {
            XCTAssertTrue(message.contains("target_document_id"))
            XCTAssertTrue(message.contains("palette_card_id"))
        } catch {
            XCTFail("expected MCPError.invalidArgument, got \(error)")
        }
        withExtendedLifetime(ds) {}
    }

    func test_promote_targetDocumentIdAndPaletteSubject_areMutuallyExclusive() async throws {
        let (url, store, ds, reg, projectId) = try await openNovelWithRegistry()
        _ = try await store.addPaletteCard(title: "The Flat", kind: .location)
        let chapterId = try XCTUnwrap(
            TreeWalk.collect(in: store.manifest.structure,
                             where: { $0.type == .document }).first?.id)
        try await seed(url, [InboxEntry(
            id: "e8", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Ambiguous capture.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e8","target_document_id":"\#(chapterId)","palette_subject":"The Flat"}"#
        do {
            _ = try await PromoteInboxEntryTool.handle(
                paramsJSON: Data(params.utf8), registry: reg)
            XCTFail("expected throw for conflicting destinations")
        } catch let MCPError.invalidArgument(message) {
            XCTAssertTrue(message.contains("target_document_id"))
            XCTAssertTrue(message.contains("palette_subject"))
        } catch {
            XCTFail("expected MCPError.invalidArgument, got \(error)")
        }
        withExtendedLifetime(ds) {}
    }

    func test_promote_paletteCardIdAndPaletteSubject_areMutuallyExclusive() async throws {
        let (url, store, ds, reg, projectId) = try await openNovelWithRegistry()
        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try await seed(url, [InboxEntry(
            id: "e9", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Ambiguous capture.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e9","palette_card_id":"\#(item.id)","palette_subject":"The Flat"}"#
        do {
            _ = try await PromoteInboxEntryTool.handle(
                paramsJSON: Data(params.utf8), registry: reg)
            XCTFail("expected throw for conflicting destinations")
        } catch let MCPError.invalidArgument(message) {
            XCTAssertTrue(message.contains("palette_card_id"))
            XCTAssertTrue(message.contains("palette_subject"))
        } catch {
            XCTFail("expected MCPError.invalidArgument, got \(error)")
        }
        withExtendedLifetime(ds) {}
    }

    // MARK: - title ignored for palette promotes (S11)

    /// `title` is honored for research promotes only; a palette-card promote
    /// must leave the card's own title untouched. Pinned so a future
    /// title→caption edit can't silently start honoring the ignored param.
    func test_promote_titleIgnoredForPalettePromote() async throws {
        let (url, store, ds, reg, projectId) = try await openNovelWithRegistry()
        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try await seed(url, [InboxEntry(
            id: "e11", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Damp plaster smell.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e11","title":"Renamed By Caller","palette_card_id":"\#(item.id)"}"#
        let data = try await PromoteInboxEntryTool.handle(
            paramsJSON: Data(params.utf8), registry: reg)
        let result = try JSONDecoder().decode(PromoteInboxEntryTool.Result.self, from: data)

        // The passed title was ignored — the card keeps its own title.
        XCTAssertEqual(result.title, "The Flat")
        let card = store.loadPaletteCards().first(where: { $0.researchItemId == item.id })
        XCTAssertEqual(card?.title, "The Flat")
        withExtendedLifetime(ds) {}
    }

    // MARK: - date serialization (S9)

    /// `read_inbox_entry` must emit its Date fields as ISO8601 strings —
    /// consistent with `list_inbox`'s `created_at` — not raw reference-date
    /// Doubles (the bug: a bare JSONEncoder with no dateEncodingStrategy).
    func test_readInboxEntry_datesAreISO8601Strings() async throws {
        let (url, _, ds, reg, projectId) = try await openNovelWithRegistry()
        try await seed(url, [InboxEntry(
            id: "e12", createdAt: Date(timeIntervalSince1970: 100),
            writtenAt: Date(timeIntervalSince1970: 200),
            deviceId: "phone", kind: .text, inlineText: "Dated capture.",
            paletteSubject: "The Flat", sense: "smell")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e12"}"#
        let data = try await ReadInboxEntryTool.handle(
            paramsJSON: Data(params.utf8), registry: reg)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Date fields are ISO8601 strings, not numbers.
        XCTAssertNotNil(json["created_at"] as? String,
                        "created_at should be an ISO8601 string, got \(String(describing: json["created_at"]))")
        XCTAssertNil(json["created_at"] as? NSNumber,
                     "created_at must not be a raw reference-date Double")
        XCTAssertNotNil(json["written_at"] as? String,
                        "written_at should be an ISO8601 string, got \(String(describing: json["written_at"]))")

        // The string round-trips to the seeded instant.
        let iso = ISO8601DateFormatter()
        let created = try XCTUnwrap(json["created_at"] as? String)
        XCTAssertEqual(iso.date(from: created), Date(timeIntervalSince1970: 100))

        // Palette fields riding the same tool still serialize correctly.
        XCTAssertEqual(json["palette_subject"] as? String, "The Flat")
        XCTAssertEqual(json["sense"] as? String, "smell")
        withExtendedLifetime(ds) {}
    }

    func test_listInbox_passesThroughPaletteSubjectAndSense() async throws {
        let (url, _, ds, reg, projectId) = try await openNovelWithRegistry()
        try await seed(url, [InboxEntry(
            id: "e10", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Aimed capture.",
            paletteSubject: "The Flat", sense: "smell")])

        let params = #"{"project_id":"\#(projectId)"}"#
        let data = try await ListInboxTool.handle(
            paramsJSON: Data(params.utf8), registry: reg)
        let result = try JSONDecoder().decode(ListInboxTool.Result.self, from: data)

        let summary = try XCTUnwrap(result.entries.first(where: { $0.id == "e10" }))
        XCTAssertEqual(summary.palette_subject, "The Flat")
        XCTAssertEqual(summary.sense, "smell")
        withExtendedLifetime(ds) {}
    }
}
