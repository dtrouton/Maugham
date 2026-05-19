// MaughamTests/OpLog/DocumentAnnotationCacheTests.swift
import XCTest
@testable import Maugham

@MainActor
final class DocumentAnnotationCacheTests: XCTestCase {

    private func makeProject(initialMd: String = "") throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CACHE-\(UUID().uuidString)")
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

    func test_initially_no_annotations() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        XCTAssertEqual(doc.annotations(), [])
    }

    func test_annotationsVersion_startsAtZero() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        XCTAssertEqual(doc.annotationsVersion, 0)
    }
}
