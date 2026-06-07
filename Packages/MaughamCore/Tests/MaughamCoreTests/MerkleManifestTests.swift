import XCTest
@testable import MaughamCore

final class MerkleManifestTests: XCTestCase {
    private func tempRoot(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mk-\(UUID().uuidString)")
        for (rel, body) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    func test_build_isDeterministicAndOrderIndependent() throws {
        let root = try tempRoot(["a.txt": "alpha", "sub/b.txt": "beta"])
        defer { try? FileManager.default.removeItem(at: root) }
        let m1 = try MerkleBuilder.build(root: root, relativePaths: ["a.txt", "sub/b.txt"], at: when)
        let m2 = try MerkleBuilder.build(root: root, relativePaths: ["sub/b.txt", "a.txt"], at: when)
        XCTAssertEqual(m1.rootHash, m2.rootHash)
        XCTAssertEqual(m1.entries.map(\.relativePath), ["a.txt", "sub/b.txt"])
    }

    func test_verify_detectsTamperAndMissing() throws {
        let root = try tempRoot(["a.txt": "alpha", "b.txt": "beta"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try MerkleBuilder.build(root: root, relativePaths: ["a.txt", "b.txt"], at: when)
        XCTAssertEqual(MerkleBuilder.verify(manifest: manifest, root: root), [])
        try "TAMPERED".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
        XCTAssertEqual(Set(MerkleBuilder.verify(manifest: manifest, root: root)), ["a.txt", "b.txt"])
    }

    func test_manifest_isCodableRoundTrip() throws {
        let root = try tempRoot(["a.txt": "alpha"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try MerkleBuilder.build(root: root, relativePaths: ["a.txt"], at: when)
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(MerkleManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }
}
