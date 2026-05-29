import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ProjectRegistryTests: XCTestCase {
    private func makeStore() async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reg-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let item = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "Reg", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        return (tmp, store)
    }

    func test_register_lookupReturnsStore() async throws {
        let (url, store) = try await makeStore()
        let reg = ProjectRegistry()
        let id = ProjectIdentifier.id(for: url)
        reg.register(url: url, store: store)
        XCTAssertNotNil(reg.lookup(id: id))
        XCTAssertEqual(reg.lookup(id: id)?.store.manifest.title, "Reg")
    }

    func test_unregister_removesEntry() async throws {
        let (url, store) = try await makeStore()
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        reg.unregister(url: url)
        XCTAssertNil(reg.lookup(id: ProjectIdentifier.id(for: url)))
    }

    func test_list_returnsAllRegistered() async throws {
        let (u1, s1) = try await makeStore()
        let (u2, s2) = try await makeStore()
        let reg = ProjectRegistry()
        reg.register(url: u1, store: s1)
        reg.register(url: u2, store: s2)
        XCTAssertEqual(reg.list().count, 2)
    }

    func test_register_replacesPreviousByPath() async throws {
        let (url, store1) = try await makeStore()
        let reg = ProjectRegistry()
        reg.register(url: url, store: store1)
        // Same URL, simulated reload
        let store2 = try await ProjectStore.load(from: url)
        reg.register(url: url, store: store2)
        XCTAssertEqual(reg.list().count, 1)
        XCTAssertTrue(reg.lookup(id: ProjectIdentifier.id(for: url))?.store === store2)
    }
}
