import XCTest
import MaughamCore
@testable import Maugham

/// **A permit-pending line does not speak the admission vocabulary**
/// (signed op log P3a Task 5's D5).
///
/// P2 held a line for exactly one reason — a seal from a key this book's chain
/// says nothing about — so *held* and *waiting for admission* were the same
/// fact, and every surface read `pendingByDevice` raw. P3a holds a line for a
/// second reason: a permit this build cannot judge, written by a device that is
/// **already admitted**. The two share `Line.State.pending(device:)`
/// deliberately (same storage state, same tallies, one walk), so the narrowing
/// happens in the WORDS, through one predicate.
///
/// Offering an Admit… sheet about somebody already in the book is a control
/// that would change nothing. Under P3a such a line is held silently; P3b gives
/// it a surface of its own.
final class PermitAdmissionVocabularyTests: XCTestCase {

    private let stranger = String(repeating: "a", count: 64)
    private let admitted = String(repeating: "b", count: 64)
    private let root = String(repeating: "c", count: 64)

    private func registry() -> Registry {
        Registry(
            devices: [
                DeviceRecord(
                    device: admitted, name: "Sam’s Mac", kind: .mac,
                    actors: [DeviceActor.author.rawValue: admitted],
                    madeAt: Date(timeIntervalSince1970: 5)),
            ],
            people: [
                PersonRecord(
                    person: root, label: "Denver", ownName: "Denver’s MacBook",
                    admittedAt: Date(timeIntervalSince1970: 1), admittedBy: root),
                PersonRecord(
                    person: admitted, label: "Sam", ownName: "Sam’s Mac",
                    admittedAt: Date(timeIntervalSince1970: 2), admittedBy: root),
            ])
    }

    /// One file's account, as a load would stamp it.
    private func provenance(
        held: [String: Int], strangers: Set<String>
    ) -> OpLogProvenance {
        OpLogProvenance(files: [
            FileProvenance(
                name: "doc-x.mac.jsonl",
                pending: held.values.reduce(0, +),
                pendingByDevice: held,
                pendingStrangerDevices: strangers),
        ])
    }

    // MARK: - The predicate

    func test_thePredicateIsAboutHavingAPersonRecord() {
        let registry = registry()
        XCTAssertTrue(registry.isStrangerDevice(stranger))
        XCTAssertFalse(registry.isStrangerDevice(admitted))
        XCTAssertFalse(registry.isStrangerDevice(root))
        XCTAssertEqual(
            registry.strangersAwaitingAdmission(among: [stranger: 3, admitted: 4]),
            [stranger: 3])
    }

    // MARK: - The sheet

    func test_theAdmissionSheetAsksAboutNobodyItHasAlreadyAdmitted() {
        let requests = AdmissionDecision.requests(
            pending: [stranger: 2, admitted: 5],
            registry: registry(), memory: [:], myRoot: root)

        XCTAssertEqual(requests.map(\.fingerprint), [stranger],
                       "an admitted person is not somebody to admit")
        XCTAssertEqual(requests.first?.waitingCount, 2)
    }

    // MARK: - The count and the notice

    func test_aPermitHeldLineIsNotCountedAsWaitingForAdmission() {
        let provenance = provenance(held: [admitted: 4], strangers: [])

        XCTAssertEqual(provenance.pendingOpLines, 4, "it IS held")
        XCTAssertEqual(provenance.pendingStrangerOpLines, 0)
        XCTAssertFalse(provenance.hasPendingAdmission)
        XCTAssertNil(
            HistoryPane.pendingNotice(provenance: provenance, names: [:]),
            "no sentence, because there is nothing for the writer to answer")
    }

    /// The converse, so the narrowing has not made P2's sentence disappear.
    func test_aStrangersHeldLinesStillSayTheyAreWaiting() {
        let provenance = provenance(held: [stranger: 4], strangers: [stranger])

        XCTAssertTrue(provenance.hasPendingAdmission)
        XCTAssertEqual(
            HistoryPane.pendingNotice(
                provenance: provenance, names: [stranger: "Sam’s Mac"]),
            "4 notes from Sam’s Mac are waiting for admission.")
    }

    /// Both at once: the sentence counts the stranger's lines and no others,
    /// and names the stranger rather than saying *2 devices*.
    func test_aMixedFileCountsAndNamesTheStrangerAlone() {
        let provenance = provenance(
            held: [stranger: 1, admitted: 9], strangers: [stranger])

        XCTAssertEqual(provenance.pendingOpLines, 10)
        XCTAssertEqual(provenance.pendingStrangerOpLines, 1)
        XCTAssertEqual(
            HistoryPane.pendingNotice(
                provenance: provenance, names: [stranger: "Sam’s Mac"]),
            "1 note from Sam’s Mac is waiting for admission.")
    }
}
