import Foundation
import XCTest
@testable import MaughamCore

/// **Whose annotation it is** (P3a Task 6, spec §2's reviewer rung and §4.2's
/// last paragraph).
///
/// *A reviewer may edit or withdraw their OWN annotations* is a same-person
/// rule, so the per-line partition cannot see it: every rung may sign an
/// `annotationEdit`, and which note it is about is a fact about two devices
/// rather than about one file. `AnnotationOwnership.mayAmend` is the one Core
/// answer and `AnnotationDeriver` is where it lands.
///
/// Fixtures are real signed registry records and real software keys (tripwire
/// 36); every temp root is removed in `tearDown`.
@MainActor
final class AnnotationOwnershipTests: XCTestCase {

    private let docId = "doc-own"
    private var projectURL: URL!
    private var root: LocalIdentities!      // Denver's Mac — the root
    private var sam: LocalIdentities!       // Sam's Mac
    private var samPhone: LocalIdentities!  // Sam's phone — same person, two devices
    private var kim: LocalIdentities!       // Kim's Mac — another reviewer
    private var cache: RegistryCache!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ann-own-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        root = .softwareForTesting()
        sam = .softwareForTesting()
        samPhone = .softwareForTesting()
        kim = .softwareForTesting()
        cache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: root.author.fingerprint)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Registry

    private var rootPerson: String { root.author.fingerprint }

    private func writeRoot() throws {
        try RegistryWriter.write(
            PersonRecord(
                person: rootPerson, label: "Denver", ownName: "Denver’s MacBook",
                admittedAt: Date(timeIntervalSince1970: 10), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: rootPerson, name: "Denver’s MacBook", kind: .mac,
                actors: [
                    DeviceActor.author.rawValue: rootPerson,
                    DeviceActor.assistant.rawValue: root.assistant.fingerprint,
                ],
                madeAt: Date(timeIntervalSince1970: 1)),
            signedBy: root.author, in: projectURL)
    }

    /// Admit a device as a person of its own, with a device record naming its
    /// four keys.
    private func admit(
        _ who: LocalIdentities, label: String, kind: DeviceKind = .mac
    ) throws {
        try RegistryWriter.write(
            PersonRecord(
                person: who.author.fingerprint, label: label, ownName: label,
                admittedAt: Date(timeIntervalSince1970: 20), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: who.author.fingerprint, name: label, kind: kind,
                actors: [
                    DeviceActor.author.rawValue: who.author.fingerprint,
                    DeviceActor.assistant.rawValue: who.assistant.fingerprint,
                ],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: who.author, in: projectURL)
    }

    private func event(
        _ id: String, subject: String, kind: PermitEvent.Kind = .admitted,
        role: String = Permit.authorRole,
        scope: String = Permit.bookScope, pieces: [String] = []
    ) throws {
        try RegistryWriter.write(
            PermitEvent(
                event: "\(subject).\(id)", kind: kind, subject: subject,
                role: role, scope: scope, pieces: pieces, mark: [:],
                at: Date(timeIntervalSince1970: 40), by: rootPerson),
            signedBy: root.author, in: projectURL)
    }

    private func table() throws -> TrustTable {
        try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)
    }

    private func amendments() throws -> AnnotationAmendments {
        .judged(by: try table(), class: { .piece("doc-own") })
    }

    // MARK: - Ops

    private func creation(
        _ opId: String, by identity: DeviceIdentity, body: String = "a note"
    ) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 100),
           device: identity.deviceId, session: "s", kind: .claudeComment,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: "")],
           provenance: .init(annotationBody: body,
                             authorSourceKind: "human", authorDisplayName: "x"))
    }

    private func withdraw(_ opId: String, of target: String, by identity: DeviceIdentity) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 200),
           device: identity.deviceId, session: "s", kind: .annotationWithdraw,
           changes: [], provenance: .init(sourceAnnotationId: target))
    }

    private func edit(
        _ opId: String, of target: String, by identity: DeviceIdentity, body: String
    ) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 200),
           device: identity.deviceId, session: "s", kind: .annotationEdit,
           changes: [],
           provenance: .init(annotationBody: body, sourceAnnotationId: target))
    }

    private func derived(_ ops: [Op], _ policy: AnnotationAmendments) -> [Annotation] {
        AnnotationDeriver.derive(
            ops: ops, paragraphs: ["aaaa": "the paragraph"], amendments: policy)
    }

    // MARK: - Neutrality

    /// The default is the pre-P3a rule and every caller with no table keeps it.
    func test_withNoPolicyEveryAmendmentStandsExactlyAsBefore() throws {
        let note = creation("01", by: kim.author)
        let ops = [note, withdraw("02", of: "01", by: sam.author)]
        XCTAssertEqual(derived(ops, .honourEverything).count, 0,
                       "a withdraw is a withdraw when nobody is judging")
    }

    /// A book with no permit events judges nothing here either: everybody is
    /// an author of the whole book, and an author may amend anybody's note.
    func test_aBookWithNoEventsHonoursEveryAmendment() throws {
        try writeRoot()
        try admit(sam, label: "Sam")
        try admit(kim, label: "Kim")
        let note = creation("01", by: kim.author)
        let ops = [note, withdraw("02", of: "01", by: sam.author)]
        XCTAssertEqual(derived(ops, try amendments()).count, 0)
    }

    // MARK: - The rule

    /// A reviewer withdrawing ANOTHER reviewer's note is ignored — the note
    /// stands, and the withdrawing op stays in the log.
    func test_aReviewerWithdrawingAnotherReviewersNoteIsIgnored() throws {
        try writeRoot()
        try admit(sam, label: "Sam")
        try admit(kim, label: "Kim")
        try event("01", subject: sam.author.fingerprint, role: Permit.reviewerRole)
        try event("01", subject: kim.author.fingerprint, role: Permit.reviewerRole)

        let ops = [creation("01", by: kim.author),
                   withdraw("02", of: "01", by: sam.author)]
        XCTAssertEqual(derived(ops, try amendments()).map(\.id), ["01"],
                       "Kim's note is not Sam's to withdraw")
        XCTAssertEqual(
            AnnotationDeriver.deriveWithdrawn(
                ops: ops, amendments: try amendments()).count, 0,
            "and it is not in the Deleted view either")
    }

    /// Her own note, though, is hers to withdraw whatever her rung.
    func test_aReviewerWithdrawingHerOwnNoteIsHonoured() throws {
        try writeRoot()
        try admit(sam, label: "Sam")
        try event("01", subject: sam.author.fingerprint, role: Permit.reviewerRole)

        let ops = [creation("01", by: sam.author),
                   withdraw("02", of: "01", by: sam.author)]
        XCTAssertEqual(derived(ops, try amendments()).count, 0)
    }

    /// **Her phone may withdraw what her Mac wrote** — the join is the table's
    /// person and never string equality of device ids.
    func test_herSecondDeviceMayWithdrawWhatTheFirstWrote() throws {
        try writeRoot()
        try admit(sam, label: "Sam")
        // A second machine of hers: its own key, its own person record, the
        // SAME label — which is the one person-level identity this format has,
        // and the one the admission sheet asks the writer for.
        try admit(samPhone, label: "Sam", kind: .phone)
        try event("01", subject: sam.author.fingerprint, role: Permit.reviewerRole)
        try event("01", subject: samPhone.author.fingerprint, role: Permit.reviewerRole)

        let ops = [creation("01", by: sam.author),
                   withdraw("02", of: "01", by: samPhone.author)]
        XCTAssertNotEqual(
            try table().person(forSealKey: sam.author.fingerprint),
            try table().person(forSealKey: samPhone.author.fingerprint),
            "two machines")
        XCTAssertEqual(derived(ops, try amendments()).count, 0,
                       "one writer")
    }

    /// Its converse, so the label join is not simply *everybody*: two machines
    /// the writer labelled differently are two writers.
    func test_twoMachinesWithDifferentLabelsAreTwoWriters() throws {
        try writeRoot()
        try admit(sam, label: "Sam")
        try admit(kim, label: "Kim", kind: .phone)
        try event("01", subject: sam.author.fingerprint, role: Permit.reviewerRole)
        try event("01", subject: kim.author.fingerprint, role: Permit.reviewerRole)

        let ops = [creation("01", by: sam.author),
                   withdraw("02", of: "01", by: kim.author)]
        XCTAssertEqual(derived(ops, try amendments()).map(\.id), ["01"])
    }

    /// A book author may edit a reviewer's note: the authority to settle a note
    /// and the authority to amend one are the same, and she has it.
    func test_aBookAuthorEditingAReviewersNoteIsHonoured() throws {
        try writeRoot()
        try admit(sam, label: "Sam")
        try admit(kim, label: "Kim")
        try event("01", subject: kim.author.fingerprint, role: Permit.reviewerRole)

        let ops = [creation("01", by: kim.author, body: "as written"),
                   edit("02", of: "01", by: sam.author, body: "as edited")]
        XCTAssertEqual(derived(ops, try amendments()).first?.body, "as edited")
    }

    /// An author of SOME pieces may amend inside hers and not outside them —
    /// the class the policy was built with is what decides.
    func test_aScopedAuthorAmendsInsideHerPiecesAndNotOutsideThem() throws {
        try writeRoot()
        try admit(sam, label: "Sam")
        try admit(kim, label: "Kim")
        try event(
            "01", subject: sam.author.fingerprint, role: Permit.authorRole,
            scope: Permit.piecesScope, pieces: [docId])
        try event("01", subject: kim.author.fingerprint, role: Permit.reviewerRole)

        let ops = [creation("01", by: kim.author, body: "as written"),
                   edit("02", of: "01", by: sam.author, body: "as edited")]
        let inHers = AnnotationAmendments.judged(
            by: try table(), class: { .piece(self.docId) })
        let elsewhere = AnnotationAmendments.judged(
            by: try table(), class: { .piece("doc-not-hers") })
        XCTAssertEqual(derived(ops, inHers).first?.body, "as edited")
        XCTAssertEqual(derived(ops, elsewhere).first?.body, "as written")
    }

    /// **An assistant-signed amendment of somebody else's note is ignored.**
    /// The assistant is the reviewer row on every device, the root's included,
    /// which is the storage-layer form of *AI is never the author*.
    func test_theAssistantMayNotAmendSomebodyElseSNote() throws {
        try writeRoot()
        try admit(sam, label: "Sam")
        try admit(kim, label: "Kim")

        let ops = [creation("01", by: kim.author),
                   withdraw("02", of: "01", by: sam.assistant)]
        XCTAssertEqual(derived(ops, try amendments()).map(\.id), ["01"])
    }

    /// And the same key amending its OWN person's note is honoured, because
    /// same-person does not depend on a permit at all.
    func test_theAssistantMayAmendItsOwnPersonsNote() throws {
        try writeRoot()
        try admit(sam, label: "Sam")

        let ops = [creation("01", by: sam.author),
                   withdraw("02", of: "01", by: sam.assistant)]
        XCTAssertEqual(derived(ops, try amendments()).count, 0)
    }

    /// **A disputed key's amendment is ignored.** Two verified records claim
    /// one fingerprint, so `Registry.actorKeyOwners` awards it to nobody for
    /// good — and a reader that acted on it would let a dispute be settled by
    /// whoever wrote a record last.
    func test_aDisputedKeysAmendmentIsIgnored() throws {
        try writeRoot()
        try admit(kim, label: "Kim")
        // Sam's record names her own assistant key; Kim's record claims the
        // same key. Neither owns it afterwards.
        try RegistryWriter.write(
            PersonRecord(
                person: sam.author.fingerprint, label: "Sam", ownName: "Sam",
                admittedAt: Date(timeIntervalSince1970: 20), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: sam.author.fingerprint, name: "Sam", kind: .mac,
                actors: [
                    DeviceActor.author.rawValue: sam.author.fingerprint,
                    DeviceActor.assistant.rawValue: sam.assistant.fingerprint,
                ],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: sam.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: kim.author.fingerprint, name: "Kim", kind: .mac,
                actors: [
                    DeviceActor.author.rawValue: kim.author.fingerprint,
                    DeviceActor.assistant.rawValue: sam.assistant.fingerprint,
                ],
                madeAt: Date(timeIntervalSince1970: 6)),
            signedBy: kim.author, in: projectURL)

        let judged = try table()
        XCTAssertTrue(judged.aDeviceRecordNames(sam.assistant.fingerprint),
                      "the register has an opinion about this key")
        let disputed = try XCTUnwrap(
            judged.deviceKey(forDeviceId: sam.assistant.deviceId))
        XCTAssertFalse(disputed.isOwned, "and the opinion is nobody's")

        let ops = [creation("01", by: sam.author),
                   withdraw("02", of: "01", by: sam.assistant)]
        XCTAssertEqual(derived(ops, try amendments()).map(\.id), ["01"])
    }

    /// **A contested key the writer has ADMITTED is still nobody's.**
    ///
    /// This is the one shape in which the SIGNER's `isOwned` guard decides
    /// anything, and it is reachable: a held span is offered to the admission
    /// sheet keyed on the sealing key, so the writer can admit a contested
    /// fingerprint as a person and give it a label. With that label matching
    /// the note's creator, the same-person arm would honour the amendment —
    /// and the whole point of `Registry.actorKeyOwners`' third clause is that
    /// nothing may decide who holds a key two records claim.
    func test_aContestedKeyAdmittedUnderAMatchingLabelIsStillNobody() throws {
        try writeRoot()
        try admit(kim, label: "Kim")
        try admit(sam, label: "Sam")
        // Kim's record claims Sam's assistant key, so it is nobody's.
        try RegistryWriter.write(
            DeviceRecord(
                device: kim.author.fingerprint, name: "Kim", kind: .mac,
                actors: [
                    DeviceActor.author.rawValue: kim.author.fingerprint,
                    DeviceActor.assistant.rawValue: sam.assistant.fingerprint,
                ],
                madeAt: Date(timeIntervalSince1970: 6)),
            signedBy: kim.author, in: projectURL)
        // And the writer has admitted that very key, under Sam's own label.
        try RegistryWriter.write(
            PersonRecord(
                person: sam.assistant.fingerprint, label: "Sam", ownName: "Sam",
                admittedAt: Date(timeIntervalSince1970: 25), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)

        let judged = try table()
        XCTAssertTrue(
            judged.sameWriter(sam.assistant.fingerprint, sam.author.fingerprint),
            "the labels match, so the same-person arm would say yes")
        XCTAssertFalse(
            try XCTUnwrap(judged.deviceKey(forDeviceId: sam.assistant.deviceId))
                .isOwned,
            "but no record owns the key")

        let ops = [creation("01", by: sam.author),
                   withdraw("02", of: "01", by: sam.assistant)]
        XCTAssertEqual(derived(ops, try amendments()).map(\.id), ["01"])
    }

    /// `mayAmend`'s OWN unplaced arm, asked directly — the policy asks the same
    /// question first, so without this the function's own guard is unpinned.
    func test_mayAmendLeavesAnUnplacedSignerExactlyAsP1LeftIt() throws {
        try writeRoot()
        try admit(sam, label: "Sam")
        XCTAssertTrue(AnnotationOwnership.mayAmend(
            signerDevice: "denvers-macbook-pro",
            creatorDevice: sam.author.deviceId,
            signerPermit: .reviewer, signerActor: .author,
            in: .piece(docId), trust: try table()),
            "the register cannot place it, so P1's answer stands")
        XCTAssertFalse(AnnotationOwnership.mayAmend(
            signerDevice: sam.author.deviceId,
            creatorDevice: "denvers-macbook-pro",
            signerPermit: .reviewer, signerActor: .author,
            in: .piece(docId), trust: try table()),
            "but a CREATOR it cannot place fails the same-person half")
    }

    /// **A device this register has never heard of is left alone** (decision
    /// B3). Its lines are unsigned history, which the permit partition does not
    /// judge either — and ignoring them would resurrect every note the writer
    /// deleted before P1, the day the book's first permit event is written.
    func test_aDeviceTheRegisterCannotPlaceIsLeftExactlyAsP1LeftIt() throws {
        try writeRoot()
        try admit(sam, label: "Sam")
        try event("01", subject: sam.author.fingerprint, role: Permit.reviewerRole)

        // A pre-P1 hostname sentinel, the shape every legacy op carries.
        let legacy = Op(
            opId: "02", docId: docId, at: Date(timeIntervalSince1970: 200),
            device: "denvers-macbook-pro", session: "s",
            kind: .annotationWithdraw, changes: [],
            provenance: .init(sourceAnnotationId: "01"))
        let ops = [creation("01", by: sam.author), legacy]
        XCTAssertEqual(derived(ops, try amendments()).count, 0,
                       "a note the writer deleted before P1 stays deleted")
    }

    /// An amendment naming a note this stream does not hold decides nothing —
    /// the note is not in the projection either.
    func test_anAmendmentWithNoCreationOpInTheStreamIsLeftAlone() throws {
        try writeRoot()
        try admit(sam, label: "Sam")
        try event("01", subject: sam.author.fingerprint, role: Permit.reviewerRole)
        let ops = [withdraw("02", of: "missing", by: sam.author)]
        XCTAssertEqual(derived(ops, try amendments()).count, 0)
    }

    /// `isWithdrawn` — the accept guard's question — answers the same rule, so
    /// a surface cannot think a note is gone while the projection shows it.
    func test_theWithdrawnGuardAnswersTheSameRule() throws {
        try writeRoot()
        try admit(sam, label: "Sam")
        try admit(kim, label: "Kim")
        try event("01", subject: sam.author.fingerprint, role: Permit.reviewerRole)
        try event("01", subject: kim.author.fingerprint, role: Permit.reviewerRole)

        let ops = [creation("01", by: kim.author),
                   withdraw("02", of: "01", by: sam.author)]
        XCTAssertFalse(AnnotationDeriver.isWithdrawn(
            annotationId: "01", in: ops, amendments: try amendments()))
        XCTAssertTrue(AnnotationDeriver.isWithdrawn(annotationId: "01", in: ops),
                      "and the neutral default is unchanged")
    }
}
