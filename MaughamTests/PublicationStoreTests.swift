import XCTest
import MaughamCore
@testable import Maugham

final class PublicationStoreTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicationStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".maugham"),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLoad_emptyReturnsEmpty() async throws {
        let store = await PublicationStore(projectURL: tmp)
        let pubs = try await store.load()
        XCTAssertTrue(pubs.isEmpty)
    }

    func testAppend_thenLoad_roundTrips() async throws {
        let store = await PublicationStore(projectURL: tmp)
        let pub = Publication(
            publicationID: "pub_a", version: "0.1", label: nil,
            format: .pdf, outputPath: "Exports/x-v0.1.pdf",
            snapshotID: "snap_a", checkpointID: "chk", republishedFrom: nil,
            compiledAt: Date(timeIntervalSince1970: 1_750_000_000), maughamVersion: "0.0.0",
            tectonicVersion: "0.15.0")
        try await store.append(pub)
        let pubs = try await store.load()
        XCTAssertEqual(pubs, [pub])
    }

    /// Task 9 F1 round 3: `Publication.allowStale` is an ADR-0015-additive
    /// field. A record written before it existed (no `allow_stale` key at
    /// all) must decode as `false`, not throw.
    func testLoad_decodesRecordWithoutAllowStaleField_asFalse() async throws {
        let line = """
        {"publication_id":"pub_old","version":"0.1","label":null,"format":"pdf","output_path":"x.pdf","snapshot_id":"s","checkpoint_id":"c","republished_from":null,"compiled_at":"2026-01-01T00:00:00Z","maugham_version":"0","tectonic_version":"0.15.0"}
        """
        let fileURL = tmp.appendingPathComponent(".maugham/publications.jsonl")
        try (line + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let store = await PublicationStore(projectURL: tmp)
        let pubs = try await store.load()
        XCTAssertEqual(pubs.count, 1)
        XCTAssertEqual(pubs.first?.allowStale, false,
            "a publication record written before allow_stale existed must decode to false")
    }

    /// Companion: a record that DOES carry `allow_stale: true` must round-trip
    /// through append/load unchanged.
    func testAppend_thenLoad_roundTripsAllowStaleTrue() async throws {
        let store = await PublicationStore(projectURL: tmp)
        let pub = Publication(
            publicationID: "pub_b", version: "0.1", label: nil,
            format: .pdf, outputPath: "Exports/x-v0.1.pdf",
            snapshotID: "snap_b", checkpointID: "chk", republishedFrom: nil,
            compiledAt: Date(timeIntervalSince1970: 1_750_000_000), maughamVersion: "0.0.0",
            tectonicVersion: "0.15.0", allowStale: true)
        try await store.append(pub)
        let pubs = try await store.load()
        XCTAssertEqual(pubs, [pub])
        XCTAssertEqual(pubs.first?.allowStale, true)
    }

    func testAppend_preservesOrder() async throws {
        let store = await PublicationStore(projectURL: tmp)
        for (idx, v) in ["0.1", "0.2", "0.3"].enumerated() {
            try await store.append(Publication(
                publicationID: "pub_\(v)", version: v, label: nil,
                format: .pdf, outputPath: "x.pdf", snapshotID: "s",
                checkpointID: "c", republishedFrom: nil,
                compiledAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(idx)), maughamVersion: "0",
                tectonicVersion: "0.15.0"))
        }
        let pubs = try await store.load()
        XCTAssertEqual(pubs.map(\.version), ["0.1", "0.2", "0.3"])
    }

    // MARK: - RULING-54: an unreadable catalog file REFUSES, never shortens

    /// An UNREADABLE-yet-present publications device file (a directory
    /// squatting on its path — the permissions-break / dataless-stub shape)
    /// must THROW naming the file, never read as a shorter catalog: every
    /// substantive consumer is write-adjacent (the occupied-destination
    /// refusal, republish's prior-edition lookup, the starter's version
    /// high-water mark), so a silently missing row arms a version collision
    /// or an overwrite of an edition the writer already shipped.
    func testLoad_unreadableDeviceFile_throwsNamingTheFile() async throws {
        let store = await PublicationStore(projectURL: tmp)
        try await store.append(Publication(
            publicationID: "pub_ok", version: "0.1", label: nil,
            format: .pdf, outputPath: "x.pdf", snapshotID: "s",
            checkpointID: "c", republishedFrom: nil,
            compiledAt: Date(timeIntervalSince1970: 1_750_000_000),
            maughamVersion: "0", tectonicVersion: "0.15.0"))
        let badURL = PublicationStore.fileURL(
            deviceSlug: DeviceSlug.make(from: "bad"), in: tmp)
        try FileManager.default.createDirectory(
            at: badURL, withIntermediateDirectories: true)

        do {
            _ = try await store.load()
            XCTFail("an unreadable catalog file must throw, not read as a shorter catalog")
        } catch let error as PublicationStore.ReadError {
            guard case .unreadableFile(let name, _) = error else {
                XCTFail("unexpected case: \(error)"); return
            }
            XCTAssertEqual(name, badURL.lastPathComponent, "the file is named")
        }
    }
}
