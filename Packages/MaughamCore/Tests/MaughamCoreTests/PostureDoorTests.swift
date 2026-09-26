import Foundation
import XCTest
@testable import MaughamCore

/// **The one door a surface builds a `Posture` through** (signed op log P3c
/// plan 2, Task 1). The Mac's window door, its two windowless callers and the
/// phone all build through `PostureDoor`; these pin that it asks the ONE
/// builder (`OpLogStore.localWritePermit`) for the actor it was given, over a
/// real registry folder with real signed events, and wraps the answer and
/// nothing else.
@MainActor
final class PostureDoorTests: XCTestCase {

    private let docId = "doc-door"
    private let otherDocId = "doc-door-other"
    private var projectURL: URL!

    /// The book's root, which signs every record and event.
    private var root: LocalIdentities!
    /// THIS device: admitted by the root, and the one asking.
    private var me: LocalIdentities!
    private var cache: RegistryCache!

    override func setUp() async throws {
        projectURL = TestTemp.root
            .appendingPathComponent("posture-door-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        root = .softwareForTesting()
        me = .softwareForTesting()
        cache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: me.author.fingerprint)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixtures

    private func store() -> OpLogStore {
        OpLogStore(
            projectURL: projectURL, identities: me,
            state: OpLogDeviceState(
                fileURL: projectURL.appendingPathComponent("state-me.json")),
            cache: cache)
    }

    private func posture(
        _ docId: String? = nil, as actor: DeviceActor = .author
    ) -> Posture {
        PostureDoor.posture(
            forDocId: docId ?? self.docId, in: projectURL, as: actor, using: store())
    }

    /// The root's own records, and this device admitted by it with `role`/`scope`.
    private func admitMe(
        role: String, scope: String = Permit.bookScope, pieces: [String] = []
    ) throws {
        let rootPerson = root.author.fingerprint
        let mePerson = me.author.fingerprint
        try RegistryWriter.write(
            PersonRecord(
                person: rootPerson, label: "Denver", ownName: "Denver\u{2019}s MacBook",
                admittedAt: Date(timeIntervalSince1970: 10), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: rootPerson, name: "Denver\u{2019}s MacBook", kind: .mac,
                actors: [DeviceActor.author.rawValue: rootPerson],
                madeAt: Date(timeIntervalSince1970: 1)),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: mePerson, label: "Sam", ownName: "Sam\u{2019}s Mac",
                admittedAt: Date(timeIntervalSince1970: 20), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: mePerson, name: "Sam\u{2019}s Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, me[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: me.author, in: projectURL)
        try RegistryWriter.write(
            PermitEvent(
                event: "\(mePerson).a", kind: .admitted, subject: mePerson,
                role: role, scope: scope, pieces: pieces,
                at: Date(timeIntervalSince1970: 40), by: rootPerson),
            signedBy: root.author, in: projectURL)
    }

    // MARK: - No register: the writer's own hand, the whole book

    func test_aBookWithNoRegisterIsTheAuthorsPosture() {
        XCTAssertEqual(posture(), .author,
                       "no register is P1's posture exactly: every verb")
        for verb in Posture.Verb.allCases {
            XCTAssertTrue(posture().allows(verb), "\(verb)")
        }
        XCTAssertNil(posture().reason)
    }

    // MARK: - The actor the door was asked for is the actor judged

    /// The same book, the same piece, the TRANSLATOR's key: it may not write
    /// the piece's text, which the writer's hand may. A door that dropped the
    /// actor would answer the writer's posture here.
    func test_theTranslatorsKeyIsJudgedAsTheTranslator() {
        let translator = posture(as: .translator)
        XCTAssertFalse(translator.allows(.writeText),
                       "the translator never writes the source piece's text")
        XCTAssertTrue(posture(as: .author).allows(.writeText))
        XCTAssertNotEqual(translator, posture(as: .author))
    }

    /// The class-naming entry: the translator in the class the pipeline
    /// constructs, `.translation(piece:)`, may translate.
    func test_theCallerNamedClassIsTheClassJudged() {
        let asked = PostureDoor.posture(as: .translator, using: store()) {
            .translation(piece: docId)
        }
        XCTAssertTrue(asked.allows(.translate))
        XCTAssertFalse(asked.allows(.writeText))
    }

    // MARK: - A narrowed register

    func test_aReviewerMayAnnotateAndMayNotWrite() throws {
        try admitMe(role: Permit.reviewerRole)
        let answered = posture()
        XCTAssertFalse(answered.allows(.writeText))
        XCTAssertFalse(answered.allows(.acceptOrReject))
        XCTAssertTrue(answered.allows(.annotate), "the reviewer row stays")
        XCTAssertEqual(answered.reason, .reviewer)
    }

    func test_anAuthorOfSomePiecesWritesHersAndNotAnotherOne() throws {
        try admitMe(role: Permit.authorRole, scope: Permit.piecesScope, pieces: [docId])
        let hers = posture(docId)
        XCTAssertTrue(hers.allows(.writeText), "in: her piece")
        XCTAssertNil(hers.reason)

        let theirs = posture(otherDocId)
        XCTAssertFalse(theirs.allows(.writeText), "out: somebody else's piece")
        XCTAssertTrue(theirs.allows(.annotate))
        XCTAssertEqual(theirs.reason, .notYourPiece)
    }

    /// The whole-book author the root admitted answers exactly as no register.
    func test_aWholeBookAuthorIsTheAuthorsPosture() throws {
        try admitMe(role: Permit.authorRole)
        XCTAssertTrue(posture().allows(.writeText))
        XCTAssertTrue(posture(otherDocId).allows(.writeText))
        XCTAssertNil(posture().reason)
    }

    // MARK: - The permit entry is the one wrap

    func test_thePermitEntryWrapsThePermitAndTheYieldAndNothingElse() {
        let permit = LocalWritePermit(
            permit: .reviewer, actor: .author, documentClass: .piece(docId))
        XCTAssertEqual(PostureDoor.posture(permit: permit), Posture(permit))

        let yielded = PostureDoor.posture(permit: .unrestricted, yieldingTo: "Sam")
        XCTAssertEqual(yielded, Posture(.unrestricted, yieldingTo: "Sam"))
        XCTAssertEqual(yielded.yieldingTo, "Sam")
        XCTAssertFalse(yielded.allows(.writeText))
        XCTAssertTrue(yielded.allows(.annotate))
        XCTAssertEqual(PostureDoor.posture(permit: .unrestricted), .author)
    }
}
