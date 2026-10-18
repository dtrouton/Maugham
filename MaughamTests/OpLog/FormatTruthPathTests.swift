// MaughamTests/OpLog/FormatTruthPathTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// Pins the held-blank rule on the op-log truth path, per extension: the three
/// sites that parse manuscript text into paragraphs (`Bootstrap.run`,
/// `Document.load`, `Document.setFullText`) must agree on the ¶ split for the
/// same file. Each asks `DocumentFormat.ofManuscript(url:)
/// .preservesHeldBlankLines` — a Fountain file (any extension case) keeps a
/// two-space held blank inside its dialogue paragraph (E1); a prose file
/// splits on it.
@MainActor
final class FormatTruthPathTests: XCTestCase {

    /// A dialogue block paused by a two-space held blank, between a slugline
    /// and an action line.
    private let body = """
    INT. KITCHEN - NIGHT

    ALICE
    I wrote you every day.
    \u{20}\u{20}
    You never answered.

    She leaves.

    """

    /// The paragraph texts each extension must split `body` into.
    private let fountainSplit = [
        "INT. KITCHEN - NIGHT",
        "ALICE\nI wrote you every day.\n  \nYou never answered.",
        "She leaves.",
    ]
    private let proseSplit = [
        "INT. KITCHEN - NIGHT",
        "ALICE\nI wrote you every day.",
        "You never answered.",
        "She leaves.",
    ]

    func test_md_splitsOnTheHeldBlank() async throws {
        try await assertTruthPath(fileName: "c1.md", expected: proseSplit)
    }

    func test_fountain_keepsTheHeldBlankInsideItsParagraph() async throws {
        try await assertTruthPath(fileName: "c1.fountain", expected: fountainSplit)
    }

    func test_uppercaseFOUNTAIN_keepsTheHeldBlankInsideItsParagraph() async throws {
        try await assertTruthPath(fileName: "c1.FOUNTAIN", expected: fountainSplit)
    }

    // MARK: - The three sites

    private func assertTruthPath(
        fileName: String, expected: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        // 1. Bootstrap.run mints one id per expected paragraph.
        let bareDir = TestTemp.root.appendingPathComponent("FTP-B-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bareDir, withIntermediateDirectories: true)
        let bareURL = bareDir.appendingPathComponent(fileName)
        try body.write(to: bareURL, atomically: true, encoding: .utf8)
        let result = try await Bootstrap.run(
            projectURL: bareDir, docId: "doc-ftp", mdURL: bareURL,
            device: "m", session: "s", opStore: OpLogStore(projectURL: bareDir))
        XCTAssertTrue(result.bootstrapped, file: file, line: line)
        XCTAssertEqual(result.paragraphIds.count, expected.count,
            "Bootstrap.run split for \(fileName)", file: file, line: line)
        let bootOps = try await OpLogStore(projectURL: bareDir).load(docId: "doc-ftp")
        XCTAssertEqual(bootOps.count, 1, file: file, line: line)
        XCTAssertEqual(bootOps.first?.sequence, result.paragraphIds, file: file, line: line)
        XCTAssertEqual(bootOps.first?.changes.map(\.next), expected.map { Optional($0) },
            "Bootstrap.run paragraph texts for \(fileName)", file: file, line: line)

        // 2. Document.load derives the same split from its own bootstrap.
        let project = try makeProject(fileName: fileName)
        let doc = try await Document.load(
            url: project, device: "m", session: "s", presenter: nil)
        XCTAssertEqual(doc.sequence.count, expected.count,
            "Document.load split for \(fileName)", file: file, line: line)
        XCTAssertEqual(doc.sequence.map { doc.paragraphs[$0] }, expected.map { Optional($0) },
            "Document.load paragraph texts for \(fileName)", file: file, line: line)
        XCTAssertEqual(Set(doc.sequence).count, expected.count, file: file, line: line)

        // 3. A setFullText edit keeps every id and the split.
        let idsBefore = doc.sequence
        let edited = doc.displayText.replacingOccurrences(
            of: "She leaves.", with: "She leaves quietly.")
        XCTAssertNotEqual(edited, doc.displayText, file: file, line: line)
        doc.setFullText(edited)
        XCTAssertEqual(doc.sequence, idsBefore,
            "setFullText must keep every id for \(fileName)", file: file, line: line)
        var expectedAfter = expected
        expectedAfter[expectedAfter.count - 1] = "She leaves quietly."
        XCTAssertEqual(doc.sequence.map { doc.paragraphs[$0] }, expectedAfter.map { Optional($0) },
            "setFullText paragraph texts for \(fileName)", file: file, line: line)
    }

    /// A one-document novel whose manuscript is `manuscript/<fileName>`.
    private func makeProject(fileName: String) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("FTP-L-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let docPath = "manuscript/\(fileName)"
        let docURL = dir.appendingPathComponent(docPath)
        try body.write(to: docURL, atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-ftp", title: "C1", type: .document, path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: dir.appendingPathComponent("project.maugham.json"))
        return docURL
    }
}
