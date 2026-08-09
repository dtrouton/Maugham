import XCTest
@testable import MaughamCore
@testable import Maugham

/// FM-1 — `.maugham/checkpoints.jsonl` and `.maugham/publications.jsonl` were
/// UNPARTITIONED shared JSONL files: exactly the shape CLAUDE.md tripwire 17
/// forbids and ADR 0012 restructured the op log and the inbox manifest to fix.
/// Two Macs saving inside one iCloud sync window lost the loser's rows to a
/// whole-file replace, and losing a checkpoint destroys the very dangling
/// pointer whose presence would have signalled the loss.
///
/// Model-checked, against production constants: `OpLogSync_cpshared`
/// (`PerDeviceCheckpoints = FALSE`, the shipped configuration) violates
/// `CheckpointNoLoss`; its partner `OpLogSync_cppartitioned` is the same spec
/// with this pattern applied and is green. TLC verifies the DESIGN — these pins
/// are what says the Swift matches it.
@MainActor
final class CheckpointPartitioningTests: XCTestCase {

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cppart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".maugham"), withIntermediateDirectories: true)
        return root
    }

    private func checkpoint(_ id: String, device: String) -> Checkpoint {
        Checkpoint(
            checkpointId: id, label: "L", labelSource: .user,
            at: Date(timeIntervalSince1970: 0), device: device,
            activeDoc: "doc-0f0f0f0f", docPointers: ["doc-0f0f0f0f": "op-\(id)"],
            manuscriptWordCount: 1)
    }

    private func publication(_ id: String, at seconds: TimeInterval) -> Publication {
        Publication(
            publicationID: id, version: "0.1", label: nil, format: .pdf,
            outputPath: "Exports/\(id).pdf", snapshotID: "snap-\(id)",
            checkpointID: "chk", republishedFrom: nil,
            compiledAt: Date(timeIntervalSince1970: seconds),
            maughamVersion: "0", tectonicVersion: "0.15.0")
    }

    // MARK: - Checkpoints

    /// The defect itself: two devices must never contend for one path.
    func test_append_writesToThisDevicesFile_neverTheSharedOne() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckpointStore(projectURL: root)

        try await store.append(checkpoint("cp-1", device: "Denvers-Mac.local"))
        try await store.append(checkpoint("cp-2", device: "Studio-Mac.local"))

        let dir = root.appendingPathComponent(".maugham")
        let a = DeviceSlug.make(from: "Denvers-Mac.local")
        let b = DeviceSlug.make(from: "Studio-Mac.local")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("checkpoints.\(a.raw).jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("checkpoints.\(b.raw).jsonl").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("checkpoints.jsonl").path),
            "the shared path is what iCloud resolves by whole-file replace — nothing may write it")
    }

    /// **The write target comes from the checkpoint, not from the process.** A
    /// checkpoint self-describes the device that made it, exactly as an op does,
    /// so a row synced in from another Mac cannot be rewritten into this Mac's
    /// stream by a re-append.
    func test_theWriteTargetIsDerivedFromTheCheckpointsOwnDevice() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try await CheckpointStore(projectURL: root)
            .append(checkpoint("cp-1", device: "phone:D2A1F8B0"))

        let expected = CheckpointStore.fileURL(
            deviceSlug: DeviceSlug.make(from: "phone:D2A1F8B0"), in: root)
        XCTAssertEqual(CheckpointStore.fileURLs(in: root).map(\.lastPathComponent),
                       [expected.lastPathComponent])
    }

    /// Readers glob and merge every device's stream — the other half of the fix.
    /// Without it partitioning would trade a silent loss for a silent hiding.
    func test_load_mergesEveryDevicesStreamInCheckpointIdOrder() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckpointStore(projectURL: root)
        // Interleaved ids, written out of order and from different devices.
        try await store.append(checkpoint("cp-3", device: "macB"))
        try await store.append(checkpoint("cp-1", device: "macA"))
        try await store.append(checkpoint("cp-4", device: "macB"))
        try await store.append(checkpoint("cp-2", device: "macA"))

        let ids = try await store.load().map(\.checkpointId)
        XCTAssertEqual(ids, ["cp-1", "cp-2", "cp-3", "cp-4"])
    }

    /// The OpLogStore legacy rule, applied here: the pre-partition file stays a
    /// merge SOURCE forever and never becomes a write target again. A writer
    /// that appended to it would reopen the defect for anyone still holding one.
    func test_theLegacyFileIsReadAndNeverWritten() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent(".maugham/checkpoints.jsonl")
        try await JSONLAppendStore<Checkpoint>(fileURL: legacy)
            .append(checkpoint("cp-0", device: "OldMac.local"))
        let legacyBytesBefore = try Data(contentsOf: legacy)

        let store = CheckpointStore(projectURL: root)
        try await store.append(checkpoint("cp-1", device: "OldMac.local"))

        let merged = try await store.load().map(\.checkpointId)
        XCTAssertEqual(merged, ["cp-0", "cp-1"],
                       "the legacy file must still be a merge source")
        XCTAssertEqual(try Data(contentsOf: legacy), legacyBytesBefore,
                       "the legacy file must never be appended to again")
    }

    /// A row present in both the legacy file and a per-device one — the ordinary
    /// state during a rollout — is returned once.
    func test_load_dedupesARowThatExistsInBothTheLegacyAndPerDeviceFiles() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cp = checkpoint("cp-1", device: "macA")
        try await JSONLAppendStore<Checkpoint>(
            fileURL: root.appendingPathComponent(".maugham/checkpoints.jsonl")).append(cp)
        try await CheckpointStore(projectURL: root).append(cp)

        let loaded = try await CheckpointStore(projectURL: root).load()
        XCTAssertEqual(loaded, [cp])
    }

    /// Round-trip contract, `OpLogFilenameContractTests`-style: the name the
    /// writer builds is the name the reader's glob finds and the name the Mac's
    /// sidecar classifier routes — one template, three consumers, no hand-rolled
    /// copies.
    func test_theBuiltFilenameRoundTripsThroughTheGlobAndTheClassifier() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        for stemPath in [CheckpointStore.stemPath, PublicationStore.stemPath] {
            let stem = (stemPath as NSString).lastPathComponent
            let slug = DeviceSlug.make(from: "Denvers-Mac.local")
            let name = PartitionedJSONLFile.url(
                stem: stem, deviceSlug: slug,
                in: root.appendingPathComponent(".maugham")).lastPathComponent

            XCTAssertTrue(PartitionedJSONLFile.matches(filename: name, stem: stem))
            XCTAssertTrue(PartitionedJSONLFile.matches(filename: "\(stem).jsonl", stem: stem))
            XCTAssertTrue(PartitionedJSONLFile.matches(
                relativePath: ".maugham/\(name)", stemPath: stemPath))
            // A same-named file one directory down is a different thing.
            XCTAssertFalse(PartitionedJSONLFile.matches(
                relativePath: ".maugham/\(stem)/\(name)", stemPath: stemPath))
        }
    }

    // MARK: - Publications

    func test_publications_appendWritesPerDevice_andLoadMergesChronologically() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PublicationStore(projectURL: root)
        try await store.append(publication("pub_b", at: 200))
        try await store.append(publication("pub_a", at: 100))

        let dir = root.appendingPathComponent(".maugham")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("publications.jsonl").path),
            "the shared path is what iCloud resolves by whole-file replace — nothing may write it")
        XCTAssertEqual(PublicationStore.fileURLs(in: root).map(\.lastPathComponent),
                       [PublicationStore.fileURL(
                           deviceSlug: DeviceSlug.make(from: MacDeviceID.current),
                           in: root).lastPathComponent])

        // `publicationID` is a random `pub-<uuid>`, so chronology has to come
        // from `compiledAt` — `ListPublications` takes `suffix(limit)` for the
        // most recent and would otherwise return an arbitrary pair.
        let order = try await store.load().map(\.publicationID)
        XCTAssertEqual(order, ["pub_a", "pub_b"])
    }

    func test_publications_legacyFileIsReadAndNeverWritten() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent(".maugham/publications.jsonl")
        try await JSONLAppendStore<Publication>(fileURL: legacy)
            .append(publication("pub_old", at: 50))
        let legacyBytesBefore = try Data(contentsOf: legacy)

        let store = PublicationStore(projectURL: root)
        try await store.append(publication("pub_new", at: 150))

        let order = try await store.load().map(\.publicationID)
        XCTAssertEqual(order, ["pub_old", "pub_new"])
        XCTAssertEqual(try Data(contentsOf: legacy), legacyBytesBefore)
    }

    // MARK: - The surfaces that had to learn the new name

    /// Presenter routing keys on the path. A partitioned checkpoint file that
    /// classified as `.unknownSidecar` would silently stop refreshing the
    /// History pane when another Mac's checkpoint arrived.
    func test_partitionedFilesStillClassifyAsTheirOwnSidecar() {
        let root = URL(fileURLWithPath: "/tmp/test-project-fm1")
        let slug = DeviceSlug.make(from: "Denvers-Mac.local")
        XCTAssertEqual(
            MaughamSidecarPath.classify(
                url: CheckpointStore.fileURL(deviceSlug: slug, in: root), projectURL: root),
            .checkpoints)
        XCTAssertEqual(
            MaughamSidecarPath.classify(
                url: PublicationStore.fileURL(deviceSlug: slug, in: root), projectURL: root),
            .publicationsLog)
    }
}
