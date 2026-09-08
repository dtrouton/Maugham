import XCTest
@testable import MaughamCore
@testable import Maugham

/// The project stream seals (the whole-branch review's I5).
///
/// `__project__.jsonl` was the one op log nothing ever sealed. `sealTailIfNeeded`
/// refuses it outright (segment rotation of the project stream is a recorded
/// Denver decision), `DocumentStore`'s maintenance loop never sees it, and
/// `appendProjectTaskOp` built a FRESH `OpLogStore` on every append — so the
/// every-`chainSealInterval` trigger, whose counter lives on the store instance,
/// started empty every time and could never fire. The tail therefore grew
/// chained-but-unsigned without limit, and the chained append re-verified all of
/// it before every write.
///
/// One store for the project store's lifetime is the whole fix.
@MainActor
final class ProjectStreamSealTests: XCTestCase {

    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PROJ-SEAL-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try Data("Hello.".utf8).write(to: tmp.appendingPathComponent("manuscript/c1.md"))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document, path: "manuscript/c1.md")],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    private func projectOp(_ index: Int, device: String) -> Op {
        Op(opId: String(format: "01PROJ%04d", index),
           docId: ProjectStore.projectTasksDocId,
           at: Date(timeIntervalSince1970: 0),
           device: device, session: "s", kind: .taskCreate,
           changes: [], sequence: [])
    }

    private func lines(of url: URL) throws -> [Data] {
        try Data(contentsOf: url)
            .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
            .map { Data($0) }
    }

    /// The project store hands out the SAME store every time, which is what
    /// makes the interval counter mean anything.
    func test_theProjectStreamHasOneStoreForTheStoresLifetime() async throws {
        let store = try await ProjectStore.load(from: try makeProject())
        XCTAssertTrue(store.projectOpLogStore === store.projectOpLogStore)
    }

    /// `chainSealInterval` appends through that one store put a seal line in
    /// `__project__`'s own file.
    func test_theIntervalSealsTheProjectStream() async throws {
        let url = try makeProject()
        let store = try await ProjectStore.load(from: url)

        // A signing identity, injected: the CI runner has no enclave, and a
        // device with no key writes chained lines that nothing seals (spec
        // §4.1). Both halves are set, because C1's rule is that a device
        // chains only ops carrying its own id.
        let signer = DeviceIdentity.softwareForTesting()
        let state = OpLogDeviceState(
            fileURL: url.appendingPathComponent("state.json"),
            identity: signer.fingerprint)
        store.projectOpDevice = signer.deviceId
        store._projectOpLogStore = OpLogStore(
            projectURL: url, identity: signer, state: state)

        for index in 1...OpLogStore.chainSealInterval {
            try await store.projectOpLogStore.append(
                projectOp(index, device: signer.deviceId))
        }

        let fileURL = OpLogStore.opLogFileURL(
            forDocId: ProjectStore.projectTasksDocId,
            deviceSlug: signer.slug, in: url)
        let written = try lines(of: fileURL)
        XCTAssertEqual(written.count, OpLogStore.chainSealInterval + 1,
            "the hundred ops plus the seal they earned")
        XCTAssertTrue(OpLogChain.isSealLine(written[written.count - 1]),
            "the project stream is signed history like every other tail")
    }

    /// `sealChain` never refused `__project__` — only `sealTailIfNeeded` does,
    /// and that refusal is about segment ROTATION, which is a different act.
    /// Pinned so the two are not confused for each other again.
    func test_sealChainDoesNotRefuseTheProjectStreamAndSealTailStillDoes() async throws {
        let url = try makeProject()
        let store = try await ProjectStore.load(from: url)
        let signer = DeviceIdentity.softwareForTesting()
        let state = OpLogDeviceState(
            fileURL: url.appendingPathComponent("state.json"),
            identity: signer.fingerprint)
        let opStore = OpLogStore(projectURL: url, identity: signer, state: state)
        store.projectOpDevice = signer.deviceId
        store._projectOpLogStore = opStore

        try await opStore.append(projectOp(1, device: signer.deviceId))
        let sealed = try await opStore.sealChain(docId: ProjectStore.projectTasksDocId)
        XCTAssertTrue(sealed, "sealChain signs the project stream")

        let rotated = try await opStore.sealTailIfNeeded(
            docId: ProjectStore.projectTasksDocId,
            deviceSlug: signer.slug, threshold: 0)
        XCTAssertNil(rotated, "segment rotation of the project stream still refuses")
    }
}
