import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class DocumentTaskAnchorPersistTests: XCTestCase {

    // MARK: - Fixture (mirrors DocumentTasksTests).

    private func makeProject(initialMd: String = "Hello.") throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ANCHOR-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document,
                path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    private func makeDocument(initialMd: String = "Hello.") async throws -> Document {
        let (project, path) = try makeProject(initialMd: initialMd)
        return try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
    }

    private func firstParagraphId(of doc: Document) async throws -> String {
        let log = try await doc.opLog()
        guard let bootstrap = log.first(where: { $0.kind == .bootstrap }),
              let pid = bootstrap.changes.first?.paragraphId else {
            XCTFail("no bootstrap paragraph")
            throw NSError(domain: "test", code: 0)
        }
        return pid
    }

    /// Helper: count `<!--t-XXXXXX-->` anchor spans in a paragraph.
    private func anchorCount(_ s: String) -> Int {
        let pattern = #"<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->"#
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        return regex.numberOfMatches(
            in: s, range: NSRange(location: 0, length: ns.length))
    }

    // MARK: - Tests

    func test_writingUnanchoredCheckbox_persistsAnchor() async throws {
        let doc = try await makeDocument()
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: "- [ ] foo")
        // Read tasks once to trigger derive + persistence.
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let para = doc.paragraph(id: pid)!
        XCTAssertTrue(para.contains("<!--t-"),
            "paragraph text should now carry the minted anchor (got: \(para))")
        XCTAssertEqual(anchorCount(para), 1)
    }

    func test_writingTwoUnanchoredCheckboxes_persistsTwoAnchors() async throws {
        let doc = try await makeDocument()
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: """
        - [ ] foo
        - [ ] bar
        """)
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let para = doc.paragraph(id: pid)!
        XCTAssertEqual(anchorCount(para), 2)
    }

    func test_anchoredCheckbox_isLeftAlone() async throws {
        let doc = try await makeDocument()
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: "- [ ] foo <!--t-aaaaaa-->")
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let para = doc.paragraph(id: pid)!
        XCTAssertTrue(para.contains("<!--t-aaaaaa-->"),
            "existing anchor must be preserved verbatim")
        XCTAssertEqual(anchorCount(para), 1, "no new anchor minted")
    }

    func test_mintEmitsTaskCreateOp() async throws {
        let doc = try await makeDocument()
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: "- [ ] write the synopsis")
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        // Allow the async opStore.append in appendTaskOpInternal to settle
        // — we read the in-memory mirror, not disk, so the append is
        // already reflected synchronously, but yield to make this explicit.
        await Task.yield()
        let creates = doc.opLogSnapshot.filter { $0.kind == .taskCreate }
        XCTAssertEqual(creates.count, 1)
        let create = creates[0]
        XCTAssertEqual(create.provenance?.taskBody, "write the synopsis")
        XCTAssertEqual(create.provenance?.taskKind, "inline_markdown")
    }

    func test_mintingNonReentrant_singleDeriveRun() async throws {
        let doc = try await makeDocument()
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: "- [ ] foo")
        // Run derive twice; second run must NOT add a new anchor or a
        // second .taskCreate op.
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let para = doc.paragraph(id: pid)!
        XCTAssertEqual(anchorCount(para), 1, "second derive must not re-mint")
        let creates = doc.opLogSnapshot.filter { $0.kind == .taskCreate }
        XCTAssertEqual(creates.count, 1)
    }

    func test_mintedAnchorMatchesTaskId() async throws {
        let doc = try await makeDocument()
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: "- [ ] foo")
        let tasks = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        XCTAssertEqual(tasks.count, 1)
        let synthId = tasks[0].id
        // synthId has the form "inline:<docId>:<anchorId>". The anchor in
        // the paragraph must contain the same anchorId.
        XCTAssertTrue(synthId.hasPrefix("inline:\(doc.docId):"))
        let suffix = String(synthId.dropFirst("inline:\(doc.docId):".count))
        let para = doc.paragraph(id: pid)!
        XCTAssertTrue(para.contains("<!--t-\(suffix)-->"))
    }

    func test_anchorPersistsAcrossReload() async throws {
        let (project, path) = try makeProject()
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: "- [ ] outline chapter")
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let para1 = doc.paragraph(id: pid)!
        XCTAssertEqual(anchorCount(para1), 1)
        let anchorMatch = para1.range(
            of: #"<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->"#,
            options: .regularExpression)!
        let anchorSpan = String(para1[anchorMatch])

        await doc.close()
        // Reload from disk + log; the anchor should still be present.
        let doc2 = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let para2 = doc2.paragraph(id: pid)
        XCTAssertNotNil(para2)
        XCTAssertTrue(para2!.contains(anchorSpan),
            "reloaded paragraph must keep the minted anchor: got \(para2 ?? "")")
    }
}
