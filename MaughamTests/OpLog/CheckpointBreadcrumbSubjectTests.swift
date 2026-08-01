// MaughamTests/OpLog/CheckpointBreadcrumbSubjectTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// **⌘S must not mint an op-log stream named after something that is not a
/// manuscript document.**
///
/// The defect these pin shipped: `CheckpointCapture.run` took an `activeDocId`,
/// wrote a `checkpoint` breadcrumb op against it, and tested it against nothing.
/// Select a *group* in the binder and press ⌘S and
/// `.maugham/ops/<groupId>.<slug>.jsonl` appeared, holding one op; with nothing
/// selected the same happened for `BinderSubject.noDocumentSubject`.
///
/// **Why that is not cosmetic.** `OpLogStore.docId(fromOpLogFilename:)` excludes
/// exactly one synthetic stream — `__project__` — so a file named after a group
/// parses as a *real doc id* from then on: `DocumentStore` seals it on every
/// project open, and on the phone `AnnotationsStore` and `ColdLaunchDownloader`
/// enumerate and download it. The binder's project row turns what used to be an
/// edge case (occupiable only between deleting the selected document and
/// clicking another row) into the default outcome of *"select the project, press
/// ⌘S"*.
///
/// **What must survive the refusal**, and each has an assertion below: the
/// project-wide `checkpoints.jsonl` entry, the doc pointers, the word count —
/// and, upstream of this type where no unit test reaches, the pending-burst
/// force-flush and the ⌘S flash, which both sit outside `run` and are untouched.
@MainActor
final class CheckpointBreadcrumbSubjectTests: XCTestCase {

    private var tmp: URL!
    private var seedOpId: String!

    /// `<project>/.maugham/ops`. Named once so a test asserting *"no new file"*
    /// and a test asserting *"this file"* cannot disagree about where to look.
    private var opsDir: URL { tmp.appendingPathComponent(".maugham/ops") }

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CBST-\(UUID())")
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

        // One content op, so `doc-1` has a stream and a pointer to keep.
        let seed = Op(
            opId: ULID.generate(), docId: "doc-1", at: Date(),
            device: "m", session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "aaaa", prior: nil, next: "Hello.")])
        try await OpLogStore(projectURL: tmp).append(seed)
        seedOpId = seed.opId
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - The refusals

    /// A **group** is the reproduction the binder has always been able to
    /// produce: click a Part, press ⌘S.
    func test_aGroupSubjectMintsNoOpLogStreamOfItsOwn() async throws {
        let before = opLogFilenames()

        _ = try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: "grp-1",
            allDocIds: ["doc-1"],
            device: "m", session: "s", label: nil)

        XCTAssertEqual(
            opLogFilenames(), before,
            "⌘S on a group must add no file under .maugham/ops — a stream named "
            + "after a group parses as a real doc id everywhere downstream")
    }

    /// The **project** subject, which the binder's project row makes the common
    /// case rather than a transient one.
    func test_theProjectSubjectMintsNoOpLogStreamOfItsOwn() async throws {
        let before = opLogFilenames()

        _ = try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: BinderSubject.noDocumentSubject,
            allDocIds: ["doc-1"],
            device: "m", session: "s", label: nil)

        XCTAssertEqual(
            opLogFilenames(), before,
            "⌘S with the project as the subject must add no file under "
            + ".maugham/ops")
    }

    /// **Not routed to `__project__` either.** That stream carries project-scope
    /// *task* ops and is read by `TaskDeriver`, `TasksPane.ownerDoc` and
    /// `ProjectStore.projectTasksOpLog()`; a checkpoint breadcrumb landing in it
    /// would be a second kind of op in a log those three walk.
    func test_theRefusedBreadcrumbIsNotRedirectedToTheProjectStream() async throws {
        _ = try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: BinderSubject.noDocumentSubject,
            allDocIds: ["doc-1"],
            device: "m", session: "s", label: nil)

        let projectOps = try await OpLogStore(projectURL: tmp).load(docId: "__project__")
        XCTAssertTrue(
            projectOps.isEmpty,
            "the breadcrumb must be dropped, not re-homed onto the project task "
            + "stream — TaskDeriver walks that log")
    }

    // MARK: - What the refusal must not cost

    /// The checkpoint itself is a project-wide artefact and is still written:
    /// the writer pressed ⌘S and a checkpoint is what ⌘S makes.
    func test_theProjectWideCheckpointIsStillWrittenWithItsPointersAndWordCount() async throws {
        let cp = try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: "grp-1",
            allDocIds: ["doc-1"],
            device: "m", session: "s", label: "part one done")

        let stored = try await CheckpointStore(projectURL: tmp).load()
        XCTAssertEqual(stored.count, 1, "checkpoints.jsonl must still get its entry")
        XCTAssertEqual(stored.first?.checkpointId, cp.checkpointId)
        XCTAssertEqual(cp.label, "part one done")
        XCTAssertEqual(cp.labelSource, .user)
        XCTAssertEqual(cp.docPointers["doc-1"], seedOpId,
                       "the pointers are computed over allDocIds and are "
                       + "unaffected by what the subject is")
        XCTAssertEqual(cp.manuscriptWordCount, 1,
                       "and so is the word count")
    }

    // MARK: - The control

    /// **The good path, unchanged.** Without this the two refusals above would
    /// still pass if `run` stopped writing breadcrumbs altogether.
    func test_aDocumentSubjectStillGetsItsBreadcrumb() async throws {
        _ = try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: "doc-1",
            allDocIds: ["doc-1"],
            device: "m", session: "s", label: nil)

        let ops = try await OpLogStore(projectURL: tmp).load(docId: "doc-1")
        XCTAssertTrue(ops.contains { $0.kind == .checkpoint },
                      "a real document must still get its breadcrumb op")
    }

    // MARK: - The guard is at the one place the decision is made

    /// **A census, not a comment.** The guard lives inside `CheckpointCapture.run`
    /// rather than at either ⌘S call site because there are *two* call sites —
    /// `ProjectWindow`'s Shift-⌘S label sheet and `CheckpointModifier`'s ⌘S key
    /// command — and a guard at one of them fixes half the defect. This holds
    /// that property: `run` is the only code in the app that appends a
    /// `.checkpoint` op, so there is nothing for a third site to route around.
    ///
    /// `.checkpointRestore` is a different op kind with four emit sites of its
    /// own; the trailing comma in the token is what keeps them out.
    func test_onlyCheckpointCaptureAppendsACheckpointOp() throws {
        let offenders = try Self.filesAppendingACheckpointOp(in: Self.appSourceDir)
        XCTAssertEqual(
            offenders, ["CheckpointCapture.swift"],
            "the checkpoint breadcrumb has exactly one emit site, so the "
            + "not-a-document guard inside it cannot be bypassed. A new emit "
            + "site needs its own guard — or, better, to call run()")
    }

    /// **The planted offender.** Same scan, over a corpus carrying a second emit
    /// site. Without this the census above could be reading nothing at all and
    /// would look identical.
    func test_theCensusCatchesASecondEmitSite() throws {
        let planted = try Self.filesAppendingACheckpointOp(
            in: Self.appSourceDir,
            plus: ["PlantedOffender.swift": "let op = Op(kind: .checkpoint, changes: [])"])
        XCTAssertEqual(
            planted.sorted(), ["CheckpointCapture.swift", "PlantedOffender.swift"],
            "the census must see a planted second emit site — if it does not, "
            + "the census is the thing that is broken")
    }

    /// **The control on the control.** `SourceScan` strips comments, and this
    /// repo's house style quotes call shapes verbatim in doc comments — including
    /// in the file above this one. A commented emit site must NOT count.
    func test_theCensusDoesNotCountACommentedEmitSite() throws {
        let planted = try Self.filesAppendingACheckpointOp(
            in: Self.appSourceDir,
            plus: ["CommentedOnly.swift": "// let op = Op(kind: .checkpoint, changes: [])"])
        XCTAssertEqual(
            planted, ["CheckpointCapture.swift"],
            "a token in a comment is prose, not an emit site")
    }

    // MARK: - Helpers

    /// Filenames directly under `.maugham/ops`. A set rather than a count so a
    /// failure says *which* file appeared.
    private func opLogFilenames() -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: opsDir.path)) ?? []
        return Set(contents)
    }

    /// `Maugham/` — the app target's sources, reached the way every census in
    /// this suite reaches them.
    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpLog/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    /// Every `.swift` file under `dir` that appends an `Op` of kind
    /// `.checkpoint`, by `lastPathComponent`, comments stripped.
    ///
    /// `plus` injects synthetic (name, source) pairs through the identical
    /// predicate, which is what lets the planted-offender companion above be a
    /// test of *this scan* rather than of a second one written to agree with it.
    private static func filesAppendingACheckpointOp(
        in dir: URL,
        plus injected: [String: String] = [:]
    ) throws -> [String] {
        var sources: [(name: String, text: String)] = []
        let fm = FileManager.default
        let walker = try XCTUnwrap(fm.enumerator(at: dir, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            sources.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        sources.append(contentsOf: injected.map { ($0.key, $0.value) })

        return sources
            .filter { SourceScan.namesInCode("kind: .checkpoint,", in: $0.text) }
            .map(\.name)
            .sorted()
    }
}
