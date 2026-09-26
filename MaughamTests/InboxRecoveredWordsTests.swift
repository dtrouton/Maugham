import XCTest
@testable import Maugham
@testable import MaughamCore

/// **What the door actually does** (signed op log P3b Task 8, spec §7.4).
///
/// The decision is `SetAsideDoorTests`'; this is the act. A set-aside
/// paragraph comes back as an ordinary capture on THIS Mac's own manifest,
/// signed by this Mac's own author actor and sealed like any other — and the
/// op log hears nothing about it, which is the half that matters: a refusal is
/// not undone by reading it, and the only route from a refused line into the
/// manuscript is the writer moving it.
@MainActor
final class InboxRecoveredWordsTests: XCTestCase {

    private var projectURL: URL!
    private var identity: DeviceIdentity!
    private var cacheURL: URL!
    private var cache: RegistryCache!

    override func setUp() async throws {
        projectURL = TestTemp.root
            .appendingPathComponent("inbox-recovered-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        identity = .softwareForTesting()
        cacheURL = TestTemp.root
            .appendingPathComponent("inbox-recovered-cache-\(UUID().uuidString).json")
        cache = RegistryCache(fileURL: cacheURL, identity: identity.fingerprint)
    }

    override func tearDown() async throws {
        openTheManifest()
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func makeInbox() -> InboxStore {
        InboxStore(projectURL: projectURL, deviceId: "mac", identity: identity,
                   identities: .forTesting(author: identity), cache: cache)
    }

    // MARK: - The act

    func test_eachParagraphBecomesOneCaptureCarryingWhoWroteIt() async throws {
        let store = makeInbox()

        let landed = try await store.captureRecoveredWords([
            SetAsideDoor.Capture(id: "op-\(#line)#p", text: "The tide went out and stayed out.",
                                 attribution: "Set aside — the assistant on Sam"),
            SetAsideDoor.Capture(id: "op-\(#line)#p", text: "She counted the boats twice.",
                                 attribution: "Set aside — the assistant on Sam"),
        ])

        XCTAssertEqual(landed, 2)
        XCTAssertEqual(store.entries.count, 2,
                       "and they are in the pane, waiting for the writer")
        XCTAssertEqual(
            Set(store.entries.compactMap(\.inlineText)),
            ["The tide went out and stayed out.", "She counted the boats twice."],
            "the words come back alone — promoting one writes the paragraph "
            + "and nothing the writer has to delete")
        XCTAssertEqual(
            Set(store.entries.compactMap(\.title)),
            ["Set aside — the assistant on Sam"],
            "with the line naming whoever wrote them")
        XCTAssertEqual(Set(store.entries.map(\.deviceId)), ["mac"],
                       "signed by THIS Mac — it is this writer's own hand that "
                       + "brought them back")
        XCTAssertEqual(Set(store.entries.map(\.kind)), [.text])
        XCTAssertEqual(Set(store.entries.map(\.status)), [.new])
    }

    /// **Nothing reaches the op log.** The whole promise of the door is that a
    /// refusal is not softened by using it.
    func test_theOpLogIsNotTouched() async throws {
        let store = makeInbox()
        let ops = projectURL.appendingPathComponent(".maugham/ops")
        let before = try FileManager.default
            .contentsOfDirectory(atPath: ops.path).sorted()

        _ = try await store.captureRecoveredWords([
            SetAsideDoor.Capture(id: "op-\(#line)#p", text: "A paragraph.", attribution: "Set aside — Sam")
        ])

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: ops.path).sorted(),
            before,
            "not one op-log file is written, created or grown")
    }

    /// The archives are evidence and stay exactly where they were: the door
    /// COPIES words out, it never moves them back.
    func test_theArchiveIsNotTouched() async throws {
        let store = makeInbox()
        let record = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [Data(#"{"op_id":"01M2RMZS8S08J1MKA7CPTFK4MS","doc_id":"doc-1","at":"2026-09-20T10:00:00.000Z","device":"author-abcdef0123456789","session":"s","kind":"typing_burst","changes":[{"paragraph_id":"p1ab","next":"A paragraph."}]}"#.utf8)],
            from: projectURL.appendingPathComponent(".maugham/ops/doc-1.macb.jsonl"),
            docId: "doc-1", reason: "written after this device was retired",
            in: projectURL))
        let archive = OpLogQuarantine.quarantinedFileURL(for: record, in: projectURL)
        let before = try Data(contentsOf: archive)

        let captures = SetAsideDoor.captures(
            forRecord: record, in: projectURL, attribution: { _ in "Set aside — Sam" })
        _ = try await store.captureRecoveredWords(captures)

        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertEqual(
            OpLogQuarantine.records(forDocId: "doc-1", in: projectURL).first?.status,
            .held,
            "the record is still held — the refusal has not been softened")
        XCTAssertEqual(store.entries.first?.inlineText, "A paragraph.",
                       "and the words are in the writer's hands")
    }

    /// **A send that fails halfway remembers what landed** (fix round 2, M2).
    ///
    /// Without it the writer's one way to get the rest is a press that files
    /// the ones they already have a second time — the door's whole promise
    /// inverted by a manifest that stopped being writable.
    ///
    /// The failure is forced through `onLanded` itself, which is also what
    /// pins its ORDERING: it fires per capture, after that capture is on disk
    /// and before anything later can throw.
    func test_aSendThatFailsHalfwayRemembersWhatLanded() async throws {
        let store = makeInbox()
        let captures = (1...3).map {
            SetAsideDoor.Capture(
                id: "op-\($0)#p1ab", text: "Paragraph \($0).",
                attribution: "Set aside — Sam")
        }
        var remembered: [String] = []

        do {
            _ = try await store.captureRecoveredWords(captures) { landed in
                remembered.append(landed.id)
                if remembered.count == 1 { self.sealTheManifestShut() }
            }
            XCTFail("premise: the second write must fail")
        } catch {
            // The manifest stopped being writable, which is the case.
        }

        XCTAssertEqual(remembered, ["op-1#p1ab"],
                       "exactly what landed — not the whole batch, and not "
                       + "nothing")
        openTheManifest()
        await store.refresh()
        XCTAssertEqual(store.entries.compactMap(\.inlineText), ["Paragraph 1."],
                       "…and what landed is what the writer has")
    }

    /// Make this Mac's own manifest unwritable, the way a permissions change
    /// or a read-only volume would.
    private func sealTheManifestShut() {
        for url in manifestURLs() {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o444], ofItemAtPath: url.path)
        }
    }

    private func openTheManifest() {
        for url in manifestURLs() {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
    }

    private func manifestURLs() -> [URL] {
        let dir = projectURL.appendingPathComponent(".maugham/inbox")
        return ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
    }

    /// Nothing to send is not an error and writes nothing.
    func test_nothingToSendWritesNothing() async throws {
        let store = makeInbox()
        let inbox = projectURL.appendingPathComponent(".maugham/inbox")

        let landed = try await store.captureRecoveredWords([])
        XCTAssertEqual(landed, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
    }

    /// Two paragraphs are two rows, and the last-wins merge keeps both: each
    /// capture is minted with its own id and its own monotonic `writtenAt`
    /// (tripwire 17), so one does not supersede the other.
    func test_twoRecoveredParagraphsAreTwoRowsAndNeitherSupersedesTheOther() async throws {
        let store = makeInbox()

        _ = try await store.captureRecoveredWords([
            SetAsideDoor.Capture(id: "op-\(#line)#p", text: "First.", attribution: "Set aside — Sam"),
            SetAsideDoor.Capture(id: "op-\(#line)#p", text: "Second.", attribution: "Set aside — Sam"),
        ])
        await store.refresh()

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(Set(store.entries.map(\.id)).count, 2)
    }
}
