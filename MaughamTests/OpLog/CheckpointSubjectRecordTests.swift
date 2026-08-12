// MaughamTests/OpLog/CheckpointSubjectRecordTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// **A checkpoint must not carry a non-document where a document goes** — not
/// in the label the writer reads, and not in the `active_doc` the restore
/// picker seeds itself from.
///
/// The sibling of `CheckpointBreadcrumbSubjectTests`, and the same id
/// travelling one hop further. That file stopped a group id / the project
/// reaching a **filename** under `.maugham/ops`. These stop the same id
/// reaching the **writer's eye** (`"09:14 — 1 words (grp-1)"`, and with the
/// binder's project row, `"(__no-selection__)"`) and the **restore picker**,
/// which seeded `_scope = .document(checkpoint.activeDoc)` — a scope naming a
/// document that does not exist.
///
/// **The two are one decision.** The label is derived from the same value the
/// record carries, so `test_theLabelAndTheRecordCannotDisagree` drives every
/// subject shape through both at once: fixing one and not the other is the
/// failure mode these are shaped around.
@MainActor
final class CheckpointSubjectRecordTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CSRT-\(UUID())")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-1", title: "Chapter One",
                              type: .document, path: "manuscript/01.md"),
                StructureItem(id: "grp-1", title: "Part One",
                              type: .group, children: []),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let seed = Op(
            opId: ULID.generate(), docId: "doc-1", at: Date(),
            device: "m", session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "aaaa", prior: nil, next: "Hello.")])
        try await OpLogStore(projectURL: tmp).append(seed)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func capture(subject: String, label: String? = nil) async throws -> Checkpoint {
        try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: subject,
            allDocIds: ["doc-1"],
            device: "m", session: "s", label: label)
    }

    // MARK: - The label

    /// **No parenthetical at all**, rather than the project's title. The slot
    /// otherwise always holds a document name, so a title in it would read as
    /// though a document by that name existed (Denver's ruling).
    func test_aGroupSubjectLeavesNoParentheticalOnTheAutoLabel() async throws {
        let cp = try await capture(subject: "grp-1")

        XCTAssertFalse(
            cp.label.contains("("),
            "the auto-label's parenthetical says which document you were in; "
            + "when you were in none it must say nothing — got \(cp.label)")
        XCTAssertTrue(
            cp.label.hasSuffix("words"),
            "and it must not leave the trailing space the removed parenthetical "
            + "used to sit after — got \(cp.label)")
    }

    /// The project row makes the sentinel case common rather than transient.
    func test_theProjectSubjectLeavesNoParentheticalOnTheAutoLabel() async throws {
        let cp = try await capture(subject: BinderSubject.noDocumentSubject)

        XCTAssertFalse(
            cp.label.contains(BinderSubject.noDocumentSubject),
            "the writer must never be shown the sentinel — got \(cp.label)")
        XCTAssertFalse(cp.label.contains("("), "got \(cp.label)")
    }

    /// **The control.** Without it the two refusals above would still pass if
    /// the parenthetical were deleted outright.
    func test_aDocumentSubjectStillNamesItselfInTheAutoLabel() async throws {
        let cp = try await capture(subject: "doc-1")

        XCTAssertTrue(
            cp.label.hasSuffix("(doc-1)"),
            "a real document must still be named in the label — got \(cp.label)")
    }

    /// A user's own label never carried a parenthetical and must not gain or
    /// lose anything here.
    func test_aUserLabelIsUntouchedByTheSubject() async throws {
        let onDoc = try await capture(subject: "doc-1", label: "part one done")
        let onGroup = try await capture(subject: "grp-1", label: "part one done")

        XCTAssertEqual(onDoc.label, "part one done")
        XCTAssertEqual(onGroup.label, "part one done")
        XCTAssertEqual(onDoc.labelSource, .user)
        XCTAssertEqual(onGroup.labelSource, .user)
    }

    // MARK: - The record

    func test_aGroupSubjectIsNotRecordedAsTheCheckpointsActiveDocument() async throws {
        let cp = try await capture(subject: "grp-1")

        XCTAssertNil(
            cp.activeDoc,
            "`active_doc` is where a document goes; a group id in it is what "
            + "`PartialRestorePicker` seeds `.document(...)` from")
    }

    func test_theProjectSubjectIsNotRecordedAsTheCheckpointsActiveDocument() async throws {
        let cp = try await capture(subject: BinderSubject.noDocumentSubject)

        XCTAssertNil(cp.activeDoc)
    }

    /// And it survives the round trip to `checkpoints.jsonl` — the record is
    /// what a later session reads, not the returned value.
    func test_theAbsentActiveDocumentSurvivesTheRoundTripToDisk() async throws {
        _ = try await capture(subject: "grp-1")

        let stored = await CheckpointStore(projectURL: tmp).load().checkpoints
        XCTAssertEqual(stored.count, 1, "the checkpoint itself is still written")
        XCTAssertNil(stored.first?.activeDoc)
    }

    /// **The control.**
    func test_aDocumentSubjectIsStillRecorded() async throws {
        let cp = try await capture(subject: "doc-1")

        XCTAssertEqual(cp.activeDoc, "doc-1")
        let stored = await CheckpointStore(projectURL: tmp).load().checkpoints
        XCTAssertEqual(stored.first?.activeDoc, "doc-1")
    }

    // MARK: - The two are one decision

    /// **The contract that keeps them from drifting.** The parenthetical is
    /// present exactly when a document is recorded, across every subject shape
    /// the binder can produce. Fix one of the two and not the other and this
    /// goes red even though both single-sided tests above still pass.
    func test_theLabelAndTheRecordCannotDisagree() async throws {
        for subject in ["doc-1", "grp-1", BinderSubject.noDocumentSubject] {
            let cp = try await capture(subject: subject)
            XCTAssertEqual(
                cp.label.contains("("), cp.activeDoc != nil,
                "label and record disagree for subject \(subject): "
                + "label=\(cp.label) activeDoc=\(String(describing: cp.activeDoc))")
        }
    }

    // MARK: - Who is allowed to build a `Checkpoint` at all

    /// **The census, and it guards the record rather than the op.**
    ///
    /// `CheckpointBreadcrumbSubjectTests` censuses the one place a `.checkpoint`
    /// *op* is appended. This is the other half: the places a `Checkpoint`
    /// *record* is constructed, which is where `activeDoc` gets its value.
    /// **Read the expected array below rather than a number here** — that is
    /// this repo's own rule about prose counts over lists. Of its members, only
    /// `CheckpointCapture` is fed the window's raw subject; the rest are
    /// per-document by construction and could not name a group if they tried —
    /// `RewindWindow`'s Snapshot-here is scoped to the document being rewound,
    /// and `Bootstrap`'s initial checkpoint is about the document it just minted.
    ///
    /// **Why a new site would be silent.** One fed from the binder's selection
    /// would put a group id or the project back into `active_doc`, and nothing
    /// would go red — `PartialRestorePicker.initialScope` absorbs it on the way
    /// out, which is exactly what makes the write side's mistake invisible. A
    /// read fallback that covers the write side's bugs is a good fallback and a
    /// bad alarm; this is the alarm.
    ///
    /// Both trees, because one member is in MaughamCore and is the one furthest
    /// from anybody's mind when they touch this file.
    func test_everyPlaceThatBuildsACheckpointIsAccountedFor() throws {
        XCTAssertEqual(
            try Self.filesConstructingACheckpoint(in: Self.checkpointSourceDirs),
            ["Bootstrap.swift", "CheckpointCapture.swift", "RewindWindow.swift"],
            "a new place builds a `Checkpoint`. If its `activeDoc` comes from the "
            + "window's subject it must go through "
            + "`CheckpointCapture.documentSubject(of:in:)` first — a group id or "
            + "`BinderSubject.noDocumentSubject` in that field is what the restore "
            + "picker used to seed `.document(...)` from")
    }

    /// **The planted offender.** Same scan, over a corpus carrying one more
    /// site. Without it the census could be walking nothing.
    func test_theCheckpointConstructionCensusCatchesAnUnaccountedSite() throws {
        XCTAssertEqual(
            try Self.filesConstructingACheckpoint(
                Self.checkpointSourceDirs,
                plus: ["SomeNewPane.swift":
                        "let cp = Checkpoint(checkpointId: id, activeDoc: selectedItemId)"]),
            ["Bootstrap.swift", "CheckpointCapture.swift", "RewindWindow.swift",
             "SomeNewPane.swift"],
            "the census must see a planted extra construction site")
    }

    /// **The control on the control.** This suite's own doc comments name the
    /// call shape verbatim; a token in a comment is prose, not a call site.
    func test_theCheckpointConstructionCensusDoesNotCountAComment() throws {
        XCTAssertEqual(
            try Self.filesConstructingACheckpoint(
                Self.checkpointSourceDirs,
                plus: ["CommentedOnly.swift": "/// built with Checkpoint( … )"]),
            ["Bootstrap.swift", "CheckpointCapture.swift", "RewindWindow.swift"],
            "a commented call shape must not count")
    }

    // MARK: - Census helpers

    /// The app target and the shared package — the two trees a `Checkpoint` can
    /// be built in. `Checkpoint` itself declares `init`, never `Checkpoint(`, so
    /// its own file is not a member and does not need excusing.
    private static var checkpointSourceDirs: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpLog/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
        return [
            root.appendingPathComponent("Maugham", isDirectory: true),
            root.appendingPathComponent(
                "Packages/MaughamCore/Sources/MaughamCore", isDirectory: true),
        ]
    }

    private static func filesConstructingACheckpoint(
        in dirs: [URL]
    ) throws -> [String] {
        try filesConstructingACheckpoint(dirs)
    }

    /// `plus` injects synthetic (name, source) pairs through the identical
    /// predicate, which is what makes the two companions above tests of *this*
    /// scan rather than of a second one written to agree with it.
    private static func filesConstructingACheckpoint(
        _ dirs: [URL],
        plus injected: [String: String] = [:]
    ) throws -> [String] {
        var sources: [(name: String, text: String)] = []
        let fm = FileManager.default
        for dir in dirs {
            let walker = try XCTUnwrap(
                fm.enumerator(at: dir, includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" {
                sources.append((url.lastPathComponent,
                                try String(contentsOf: url, encoding: .utf8)))
            }
        }
        sources.append(contentsOf: injected.map { ($0.key, $0.value) })

        return sources
            .filter { SourceScan.namesInCode("Checkpoint(", in: $0.text) }
            .map(\.name)
            .sorted()
    }
}
