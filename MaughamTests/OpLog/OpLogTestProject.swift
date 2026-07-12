// MaughamTests/OpLog/OpLogTestProject.swift
//
// Shared fixture builder for OpLog tests. Matches the majority shape found
// across 10 hand-rolled `makeProject(initialMd:)` duplicates: a temp project
// root with a single novel chapter ("manuscript/c1.md", structure id
// "doc-test") and a project.maugham.json manifest, ready for
// `Document.load`. Files whose fixture genuinely differs semantically
// (parameterized docId/docPath/type, no manuscript at all, etc.) keep their
// local variant — see task-3-report.md for the full list.
import Foundation
import MaughamCore

@discardableResult
func makeTestProject(prefix: String, initialMd: String) throws -> (dir: URL, docURL: URL) {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tmp, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: tmp.appendingPathComponent("manuscript"),
        withIntermediateDirectories: true)
    let docPath = "manuscript/c1.md"
    let docURL = tmp.appendingPathComponent(docPath)
    try initialMd.data(using: .utf8)!.write(to: docURL)
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
    return (tmp, docURL)
}
