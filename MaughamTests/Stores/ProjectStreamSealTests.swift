import XCTest
@testable import MaughamCore
@testable import Maugham

/// The project stream seals (the whole-branch review's I5) — and, since
/// 2026-09-09, rotates.
///
/// `__project__.jsonl` was the one op log nothing ever sealed. `sealTailIfNeeded`
/// refused it outright, `DocumentStore`'s maintenance loop never saw it, and
/// `appendProjectTaskOp` built a FRESH `OpLogStore` on every append — so the
/// every-`chainSealInterval` trigger, whose counter lives on the store instance,
/// started empty every time and could never fire. The tail therefore grew
/// chained-but-unsigned without limit, and the chained append re-verified all of
/// it before every write.
///
/// One store for the project store's lifetime was half the fix. The other half
/// is rotation: the stream now becomes a segment at the same
/// `segmentSealThreshold` as every other tail (Denver, 2026-09-09 — one
/// constant, not two), and the open sweep is where it happens, because a
/// project stream has no close to rotate at.
@MainActor
final class ProjectStreamSealTests: XCTestCase {

    override func tearDown() async throws {
        // Process-wide, so a leak would silently change what every later test's
        // load can vouch for — and what threshold its sweep rotates at.
        Document.segmentSealThresholdForTesting = nil
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
    }

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

    private func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    private func projectTailURL(in url: URL, slug: DeviceSlug) -> URL {
        OpLogStore.opLogFileURL(
            forDocId: ProjectStore.projectTasksDocId, deviceSlug: slug, in: url)
    }

    private func projectSegmentURLs(in url: URL) -> [URL] {
        OpLogStore.opLogFileURLs(
            forDocId: ProjectStore.projectTasksDocId, in: url)
            .filter { $0.pathExtension == OpLogSegment.fileExtension }
    }

    /// Grow the author's `__project__` tail past `threshold` bytes, answering
    /// the opIds it now holds, in order.
    @discardableResult
    private func growProjectTail(
        through opStore: OpLogStore, device: String, tailURL: URL, past threshold: Int
    ) async throws -> [String] {
        var appended: [String] = []
        while size(of: tailURL) <= threshold {
            let op = projectOp(appended.count + 1, device: device)
            try await opStore.append(op)
            appended.append(op.opId)
        }
        return appended
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

    /// The stream rotates like every other tail (Denver, 2026-09-09).
    ///
    /// The two verbs are still different acts, and this is the test that keeps
    /// them from being confused for each other: `sealChain` SIGNS a run of
    /// lines in place and never refused the project stream, while
    /// `sealTailIfNeeded` REWRITES the tail into an immutable segment and used
    /// to refuse it outright — which is what left the one op log with no
    /// ceiling, re-verified in full before every write.
    func test_theProjectStreamRotatesLikeEveryOtherTail() async throws {
        let url = try makeProject()
        let store = try await ProjectStore.load(from: url)
        let signer = DeviceIdentity.softwareForTesting()
        let identities = LocalIdentities.forTesting(author: signer)
        let state = OpLogDeviceState(
            fileURL: url.appendingPathComponent("state.json"),
            identity: signer.fingerprint)
        let opStore = OpLogStore(
            projectURL: url, identities: identities, state: state)
        store.projectOpDevice = signer.deviceId
        store._projectOpLogStore = opStore

        // A small threshold, passed explicitly: the point is the refusal that
        // is gone, not the 512 KB it would take to reach the real one.
        let threshold = 2048
        let tailURL = projectTailURL(in: url, slug: signer.slug)
        let appended = try await growProjectTail(
            through: opStore, device: signer.deviceId,
            tailURL: tailURL, past: threshold)
        XCTAssertGreaterThan(appended.count, 1,
                             "precondition: a tail with something in it to rotate")

        let segment = try await opStore.sealTailIfNeeded(
            docId: ProjectStore.projectTasksDocId,
            deviceSlug: signer.slug, threshold: threshold)
        XCTAssertEqual(
            segment?.lastPathComponent,
            "\(ProjectStore.projectTasksDocId).\(signer.slug.raw).seg0001.mzseg",
            "the project stream rotates into a numbered segment like any other tail")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tailURL.path),
                       "and the tail it was made from is gone")

        let sealed = try OpLogStore.loadSyncMerged(
            forDocId: ProjectStore.projectTasksDocId, in: url,
            identities: identities, state: state)
        XCTAssertEqual(sealed.map(\.opId), appended,
                       "every task op appended is still readable, out of the segment")

        // The next append recreates the tail, and the read is segment plus tail.
        let extra = projectOp(appended.count + 1, device: signer.deviceId)
        try await opStore.append(extra)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tailURL.path),
                      "the next append recreates the tail")
        let afterwards = try OpLogStore.loadSyncMerged(
            forDocId: ProjectStore.projectTasksDocId, in: url,
            identities: identities, state: state)
        XCTAssertEqual(afterwards.map(\.opId), appended + [extra.opId],
                       "and answers the segment's ops plus the new one")
    }

    /// The OPEN SWEEP is the project stream's rotation boundary, and its only
    /// one: a manuscript document rotates at close as well, and the project
    /// stream has no close. `OpLogStore.docIds(inOpsDirectoryFilenames:)`
    /// excludes `__project__` by contract (it answers MANUSCRIPT doc ids), so
    /// the sweep has to name the stream itself — this is the test that says it
    /// does.
    func test_theOpenSweepRotatesTheProjectStream() async throws {
        let url = try makeProject()
        let signer = DeviceIdentity.softwareForTesting()
        let identities = LocalIdentities.forTesting(author: signer)
        let state = OpLogDeviceState(
            fileURL: url.appendingPathComponent("op-log-state.json"))
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = state
        Document.segmentSealThresholdForTesting = 2048

        let store = try await ProjectStore.load(from: url)
        let opStore = OpLogStore(
            projectURL: url, identities: identities, state: state)
        store.projectOpDevice = signer.deviceId
        store._projectOpLogStore = opStore

        let tailURL = projectTailURL(in: url, slug: signer.slug)
        let appended = try await growProjectTail(
            through: opStore, device: signer.deviceId,
            tailURL: tailURL, past: 2048)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tailURL.path),
                      "precondition: an oversized project tail is waiting for the sweep")

        _ = try await DocumentStore.open(url: url)

        XCTAssertEqual(projectSegmentURLs(in: url).count, 1,
                       "opening the project rotates its oversized project stream")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tailURL.path),
                       "and the tail is gone, which is what bounds its growth")

        let reopened = try await ProjectStore.load(from: url)
        XCTAssertEqual(reopened.projectTasksOpLog().map(\.opId), appended,
                       "every task op survives the rotation")
    }
}
