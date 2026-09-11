import XCTest
@testable import MaughamCore
@testable import Maugham

/// Static-copy pins for the signed op log's two writer-facing sentences in
/// `HistoryPane` — what part of this document's history is UNSIGNED, and what
/// was SET ASIDE because something that is not Maugham wrote it.
///
/// Pinned without mounting, the `unreadableCheckpointNotice` /
/// `quarantineNotice` pattern: the copy is a pure static over counts, so its
/// grammar and its nil case are assertable with no window and no disk. The one
/// static that must read disk (`setAsideLinesByReason`, ruling 2's "N is the
/// number of LINES, not records") is pinned against a real temp project, and
/// is deliberately not the notice itself — a notice that read files would do
/// file I/O on every `body` evaluation.
///
/// The vocabulary rule these enforce: `unsealed` lines are the ordinary state
/// between seals and are NEVER mentioned; a legacy segment's lines are legacy,
/// never foreign; the internal words ("quarantine", "provenance", "chain")
/// never reach the writer.
@MainActor
final class HistoryPaneProvenanceNoticeTests: XCTestCase {

    // MARK: - unsignedHistoryNotice

    func test_unsignedHistoryNotice_nilForNoProvenance() {
        XCTAssertNil(HistoryPane.unsignedHistoryNotice(provenance: nil))
    }

    func test_unsignedHistoryNotice_nilWhenEverythingIsThisDevicesOwn() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.mac.jsonl", verified: 12, unsealed: 3)
        ])
        XCTAssertNil(
            HistoryPane.unsignedHistoryNotice(provenance: provenance),
            "unsealed lines are the ordinary state between seals — never a notice")
    }

    func test_unsignedHistoryNotice_legacyOnly_saysWrittenBeforeTheBookWasSigned() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.mac.jsonl", legacy: 40, unsealed: 2)
        ])
        XCTAssertEqual(
            HistoryPane.unsignedHistoryNotice(provenance: provenance),
            "Part of this document’s history was written before this book was signed.")
    }

    func test_unsignedHistoryNotice_foreignOnly_countsTheChanges() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", unsignedHistory: 7)
        ])
        XCTAssertEqual(
            HistoryPane.unsignedHistoryNotice(provenance: provenance),
            "7 changes from another device are applied as unsigned history.")
    }

    func test_unsignedHistoryNotice_oneForeignChange_usesSingularGrammar() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", unsignedHistory: 1)
        ])
        XCTAssertEqual(
            HistoryPane.unsignedHistoryNotice(provenance: provenance),
            "1 change from another device is applied as unsigned history.")
    }

    /// The coalescing rule (`Maugham/OpLog/AREA.md`, "The Document's one
    /// writer-facing channel"): the slot holds ONE sentence, so both facts
    /// arrive as one.
    func test_unsignedHistoryNotice_bothCausesCoalesceIntoOneSentence() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.mac.jsonl", legacy: 9),
            FileProvenance(name: "doc-a.phone.jsonl", unsignedHistory: 4),
        ])
        let notice = HistoryPane.unsignedHistoryNotice(provenance: provenance)
        XCTAssertEqual(
            notice,
            "Part of this document’s history was written before this book was signed, "
            + "and 4 changes from another device are applied as unsigned history.")
        XCTAssertEqual(
            notice?.filter { $0 == "." }.count, 1,
            "one sentence, not two — the toast/notice slot holds one")
    }

    func test_unsignedHistoryNotice_bothCauses_singularForeignGrammar() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.mac.jsonl", legacy: 9),
            FileProvenance(name: "doc-a.phone.jsonl", unsignedHistory: 1),
        ])
        XCTAssertEqual(
            HistoryPane.unsignedHistoryNotice(provenance: provenance),
            "Part of this document’s history was written before this book was signed, "
            + "and 1 change from another device is applied as unsigned history.")
    }

    func test_unsignedHistoryNotice_neverUsesInternalVocabulary() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.mac.jsonl", legacy: 3, unsignedHistory: 2)
        ])
        let notice = try! XCTUnwrap(
            HistoryPane.unsignedHistoryNotice(provenance: provenance))
        for word in ["quarantine", "provenance", "chain", "seal", "hash"] {
            XCTAssertFalse(
                notice.localizedCaseInsensitiveContains(word),
                "internal term ‘\(word)’ must never reach the writer — \(notice)")
        }
    }

    // MARK: - setAsideLinesNotice

    func test_setAsideLinesNotice_nilWhenNothingWasSetAside() {
        XCTAssertNil(HistoryPane.setAsideLinesNotice(byReason: [:]))
        XCTAssertNil(
            HistoryPane.setAsideLinesNotice(
                byReason: ["written by something that is not Maugham": 0]),
            "a reason with nothing under it is not a finding")
    }

    func test_setAsideLinesNotice_countsTheChanges() {
        XCTAssertEqual(
            HistoryPane.setAsideLinesNotice(
                byReason: ["written by something that is not Maugham": 3]),
            "3 changes to this document were set aside (written by something "
            + "that is not Maugham); kept in backup, not applied.")
    }

    func test_setAsideLinesNotice_singularGrammar() {
        XCTAssertEqual(
            HistoryPane.setAsideLinesNotice(
                byReason: ["written by something that is not Maugham": 1]),
            "1 change to this document was set aside (written by something "
            + "that is not Maugham); kept in backup, not applied.")
    }

    // MARK: - Each reason says itself (whole-branch review, I3)

    /// **Revoked is not *not Maugham***. Before this, every `.lines` record got
    /// the one sentence P1 wrote for the only reason P1 had. The writer revokes
    /// their old Mac and History told them something that is not Maugham wrote
    /// those changes — a misattribution of the writer's own work, on the one
    /// screen that exists to tell them the truth about their book.
    func test_setAsideLinesNotice_saysRevocationRatherThanNotMaugham() {
        let notice = try! XCTUnwrap(HistoryPane.setAsideLinesNotice(
            byReason: ["written after this device's access was withdrawn": 4]))

        XCTAssertEqual(
            notice,
            "4 changes to this document were set aside (written after this "
            + "device's access was withdrawn); kept in backup, not applied.")
        XCTAssertFalse(notice.contains("not Maugham"),
                       "Maugham wrote them, on the writer's other machine")
    }

    /// The four P2b reasons are four different things to have happened, and a
    /// writer cannot act on any of them while they are all called one thing.
    func test_setAsideLinesNotice_carriesEachOfTheReasonsItIsGiven() {
        for reason in ["written after this device was retired",
                       "may be late sync, or may be backdated",
                       "written under another claimant's copy of this book",
                       "the history's chain is broken"] {
            let notice = try! XCTUnwrap(
                HistoryPane.setAsideLinesNotice(byReason: [reason: 2]))
            XCTAssertTrue(notice.contains(reason), notice)
            XCTAssertFalse(notice.contains("not Maugham"), notice)
        }
    }

    /// **Two causes at once is two clauses.** A revoked device's span splits
    /// into the half above the mark and the half the root had already applied,
    /// which is two records with two sentences and one refusal — so the total
    /// leads and each cause says itself. Ordered by count, then alphabetically,
    /// so one folder answers one way however its sidecars were enumerated.
    func test_setAsideLinesNotice_givesEachCauseItsOwnClause() {
        XCTAssertEqual(
            HistoryPane.setAsideLinesNotice(byReason: [
                "written after this device's access was withdrawn": 2,
                "may be late sync, or may be backdated": 5,
            ]),
            "7 changes to this document were set aside: 5 changes may be late "
            + "sync, or may be backdated; 2 changes written after this "
            + "device's access was withdrawn. Kept in backup, not applied.")
    }

    /// A tie is broken by the reason itself, so the sentence is stable.
    func test_setAsideLinesNotice_ordersEqualCountsByReason() {
        let notice = try! XCTUnwrap(HistoryPane.setAsideLinesNotice(byReason: [
            "written by something that is not Maugham": 1,
            "may be late sync, or may be backdated": 1,
        ]))
        XCTAssertEqual(
            notice,
            "2 changes to this document were set aside: 1 change may be late "
            + "sync, or may be backdated; 1 change written by something that "
            + "is not Maugham. Kept in backup, not applied.")
    }

    // MARK: - setAsideLinesByReason (ruling 2: LINES, not records)

    func test_setAsideLinesByReason_emptyWhenNoRecords() {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        XCTAssertEqual(
            HistoryPane.setAsideLinesByReason(records: [], in: project), [:])
    }

    func test_setAsideLinesByReason_countsLinesAcrossRecords_notRecords() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let opsURL = project.appendingPathComponent(".maugham/ops/doc-abcd.phone.jsonl")

        let first = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [Data("{\"a\":1}".utf8), Data("{\"a\":2}".utf8), Data("{\"a\":3}".utf8)],
            from: opsURL, docId: "doc-abcd",
            reason: "written by something that is not Maugham", in: project))
        let second = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [Data("{\"b\":1}".utf8), Data("{\"b\":2}".utf8)],
            from: opsURL, docId: "doc-abcd",
            reason: "written by something that is not Maugham", in: project))

        XCTAssertEqual(
            HistoryPane.setAsideLinesByReason(records: [first, second], in: project),
            ["written by something that is not Maugham": 5],
            "N is the number of set-aside CHANGES — five lines across two records")
    }

    /// Two records filed under two causes are counted apart, which is what
    /// lets the sentence say each of them (whole-branch review, I3).
    func test_setAsideLinesByReason_countsEachCauseSeparately() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let opsURL = project.appendingPathComponent(".maugham/ops/doc-abcd.phone.jsonl")

        let foreign = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [Data("{\"a\":1}".utf8), Data("{\"a\":2}".utf8)],
            from: opsURL, docId: "doc-abcd",
            reason: "written by something that is not Maugham", in: project))
        let revoked = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [Data("{\"b\":1}".utf8)],
            from: opsURL, docId: "doc-abcd",
            reason: "written after this device's access was withdrawn", in: project))

        XCTAssertEqual(
            HistoryPane.setAsideLinesByReason(
                records: [foreign, revoked], in: project),
            ["written by something that is not Maugham": 2,
             "written after this device's access was withdrawn": 1])
    }

    /// A `.file` record's data file is a whole op log; its line count is not
    /// what this sentence counts, so the counter reads `.lines` records only.
    func test_setAsideLinesByReason_ignoresFileRecords() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let opsURL = project.appendingPathComponent(".maugham/ops/doc-abcd.phone.jsonl")
        try Data("{\"a\":1}\n{\"a\":2}\n".utf8).write(to: opsURL)

        let fileRecord = try OpLogQuarantine.quarantine(
            fileURL: opsURL, docId: "doc-abcd", reason: "unreadable", in: project)
        XCTAssertEqual(
            HistoryPane.setAsideLinesByReason(records: [fileRecord], in: project), [:],
            "a whole set-aside FILE is the Retry notice's subject, not this one's")
    }

    private func makeProject() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("histprov-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        return url
    }
}

/// Static-copy pins for the signed op log's two CHAIN sentences in
/// `HistoryPane` (P2a, spec §6) — what is HELD until the writer admits the
/// device that wrote it, and whose chain this Mac is on.
///
/// Same pattern as the two sentences above: pure statics over values, so the
/// grammar, the naming rule and the nil cases are assertable with no window.
/// The Admit… control is pinned the same way — the decision (drawn, disabled,
/// and what it says instead) is three constants `body` reads, never a press in
/// a mounted window (tripwire 33).
@MainActor
final class HistoryPaneChainNoticeTests: XCTestCase {

    // A device fingerprint is SHA-256 hex; four characters is the "code" a
    // surface shows when no record gives the device a name.
    private let phone = "4f2ka1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e"
    private let mac = "9c8b7a6f5e4d3c2b1a0918273645ffee0011223344556677889900aabbccddee"

    // MARK: - pendingNotice

    func test_pendingNotice_nilForNoProvenance() {
        XCTAssertNil(HistoryPane.pendingNotice(provenance: nil, names: [:]))
    }

    /// Decision B3: a device no root names has no chain to judge by, so every
    /// foreign key answers `.noChain` and its lines are APPLIED as unsigned
    /// history. Nothing is ever pending there, which reaches this function as a
    /// zero count. (The loader half is pinned by `PendingLoadTests`'
    /// no-registry case.)
    func test_pendingNotice_nilWhenNothingIsWaiting() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.mac.jsonl", verified: 20, unsignedHistory: 6)
        ])
        XCTAssertNil(
            HistoryPane.pendingNotice(provenance: provenance, names: [:]),
            "with no chain nothing is held — unsigned history is applied, and says so above")
    }

    func test_pendingNotice_oneDevice_namesItFromItsRecord() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", pending: 14,
                           pendingByDevice: [phone: 14])
        ])
        XCTAssertEqual(
            HistoryPane.pendingNotice(provenance: provenance, names: [phone: "iPhone"]),
            "14 notes from iPhone are waiting for admission.")
    }

    /// No device record names the key, so the writer gets the code they can
    /// compare against the other device's own screen.
    func test_pendingNotice_oneDevice_withNoRecordShowsItsCode() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", pending: 3,
                           pendingByDevice: [phone: 3])
        ])
        XCTAssertEqual(
            HistoryPane.pendingNotice(provenance: provenance, names: [:]),
            "3 notes from 4F2K are waiting for admission.")
    }

    func test_pendingNotice_oneNote_usesSingularGrammar() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", pending: 1,
                           pendingByDevice: [phone: 1])
        ])
        XCTAssertEqual(
            HistoryPane.pendingNotice(provenance: provenance, names: [phone: "iPhone"]),
            "1 note from iPhone is waiting for admission.")
    }

    /// Naming several devices would be a list inside a caption, so the sentence
    /// counts them and People & Devices holds the roll.
    func test_pendingNotice_severalDevices_countsThemRatherThanNamingThem() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", pending: 14,
                           pendingByDevice: [phone: 14]),
            FileProvenance(name: "doc-a.mac.jsonl", pending: 2,
                           pendingByDevice: [mac: 2]),
        ])
        XCTAssertEqual(
            HistoryPane.pendingNotice(
                provenance: provenance, names: [phone: "iPhone", mac: "Studio"]),
            "16 notes from 2 devices are waiting for admission.")
    }

    /// One device writes as several actors, so its history is spread over one
    /// file per actor. `pendingByDevice` is keyed on the DEVICE, so this is one
    /// device waiting, not two (Task 7's fix round).
    func test_pendingNotice_oneDeviceSpreadOverItsActorsFilesIsStillOneDevice() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone-author.jsonl", pending: 5,
                           pendingByDevice: [phone: 5]),
            FileProvenance(name: "doc-a.phone-assistant.jsonl", pending: 4,
                           pendingByDevice: [phone: 4]),
        ])
        XCTAssertEqual(
            HistoryPane.pendingNotice(provenance: provenance, names: [phone: "iPhone"]),
            "9 notes from iPhone are waiting for admission.")
    }

    // MARK: - The seal is held with the span and counted in no sentence (I1)

    /// **The number is OP lines, and a seal is not a note** (whole-branch
    /// review, I1; ADR 0032 §6).
    ///
    /// A held span of two ops is THREE held lines — the ops and the seal that
    /// closes them — and `pendingLines` says three, correctly, because that is
    /// how much of the file was not applied. This sentence puts the word
    /// "notes" after its number, so it says two.
    func test_pendingNotice_countsOpLinesAndNotTheSealThatHoldsThem() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", pending: 3,
                           pendingByDevice: [phone: 2])
        ])
        XCTAssertEqual(provenance.pendingLines, 3, "three lines were not applied")
        XCTAssertEqual(
            HistoryPane.pendingNotice(provenance: provenance, names: [phone: "iPhone"]),
            "2 notes from iPhone are waiting for admission.",
            "and two of them are notes")
    }

    /// **The two surfaces agree by construction**, over one fixture: History's
    /// banner and the admission sheet's request are built from the same map, so
    /// they cannot come to two numbers about one device. Before I1 the banner
    /// said *4 notes* about a device the sheet described as holding 3.
    func test_pendingNotice_andTheAdmissionSheetSayTheSameNumber() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", pending: 4,
                           pendingByDevice: [phone: 3])
        ])
        let requests = AdmissionDecision.requests(
            pending: provenance.pendingByDevice, registry: Registry(),
            memory: [:], myRoot: mac)
        let waiting = try! XCTUnwrap(requests.first).waitingCount
        XCTAssertEqual(waiting, 3)
        XCTAssertEqual(
            HistoryPane.pendingNotice(provenance: provenance, names: [phone: "iPhone"]),
            "\(waiting) notes from iPhone are waiting for admission.")
    }

    /// Held lines that are ALL seal — two adjacent seals, structurally
    /// unlikely — are history with no note in it. There is no number to say,
    /// nobody to name and nothing for Admit… to find, so the sentence is
    /// absent rather than reporting *1 note from another device*.
    func test_pendingNotice_isSilentWhenEveryHeldLineIsASeal() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", pending: 3, pendingByDevice: [:])
        ])
        XCTAssertNil(HistoryPane.pendingNotice(provenance: provenance, names: [:]))
    }

    func test_pendingNotice_neverUsesInternalVocabulary() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", pending: 4,
                           pendingByDevice: [phone: 4])
        ])
        let notice = try! XCTUnwrap(
            HistoryPane.pendingNotice(provenance: provenance, names: [phone: "iPhone"]))
        for word in ["quarantine", "provenance", "chain", "seal", "hash", "pending", "trust"] {
            XCTAssertFalse(
                notice.localizedCaseInsensitiveContains(word),
                "internal term ‘\(word)’ must never reach the writer — \(notice)")
        }
    }

    // MARK: - The one History line that carries a control

    /// Drawn and now LIVE, still never pressed (tripwire 33). The row is drawn
    /// exactly when the sentence exists; P2a said when the button would work
    /// and P2b is that, so this test moved with the constant.
    func test_theAdmitControlIsDrawnAndLiveOnceAdmissionExists() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", pending: 14,
                           pendingByDevice: [phone: 14])
        ])
        XCTAssertNotNil(
            HistoryPane.pendingNotice(provenance: provenance, names: [phone: "iPhone"]),
            "the sentence is what draws the row the control sits in")
        XCTAssertEqual(HistoryPane.admitTitle, "Admit…")
        XCTAssertFalse(
            HistoryPane.admitHelp.isEmpty,
            "and it says what admitting will do, for the hover and for VoiceOver")
    }

    // MARK: - The retirement banner (fix round 1, Important 2)

    /// **The one machine that can see both halves of the divergence is told
    /// about it.** A retired Mac goes on writing and goes on applying its own
    /// lines (`.mine` outranks `.retired`), while every peer sets them aside;
    /// the row in Settings reads "retired 11 Sep", which is a fact and not a
    /// warning, and History is where a standing fact belongs.
    func test_aretiredMacIsToldWhatItsRetirementMeans() throws {
        let standing = DeviceStanding(
            code: "AB12", label: "Denver", rootLabel: "Denver",
            admitted: true, isRoot: true,
            retiredAt: Date(timeIntervalSince1970: 1_757_000_000))

        let notice = try XCTUnwrap(HistoryPane.retirementNotice(standing: standing))

        XCTAssertTrue(notice.hasPrefix("This Mac retired on "), notice)
        XCTAssertTrue(
            notice.contains(
                "what it writes now stays on this Mac and is set aside everywhere else"),
            notice)
    }

    /// Nil while this Mac is still at work — the ordinary case, and the banner
    /// is absent rather than empty.
    func test_amacStillAtWorkDrawsNoRetirementBanner() {
        let standing = DeviceStanding(
            code: "AB12", label: "Denver", rootLabel: "Denver",
            admitted: true, isRoot: true)

        XCTAssertNil(HistoryPane.retirementNotice(standing: standing))
    }

    /// The sentence is `DeviceStanding`'s, not this pane's: the phone draws the
    /// same fact from the same value, and a second spelling here would be the
    /// two screens disagreeing about what happened (tripwire 19).
    func test_thebannerSaysExactlyWhatTheSharedValueSays() {
        let retiredAt = Date(timeIntervalSince1970: 1_757_000_000)
        let standing = DeviceStanding(code: "AB12", retiredAt: retiredAt)

        XCTAssertEqual(
            HistoryPane.retirementNotice(standing: standing),
            DeviceStanding.retirementNotice(device: "Mac", retiredAt: retiredAt))
    }

    // MARK: - joinedChainNotice

    func test_joinedChainNotice_nilWhenThisDeviceJoinedNothing() {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        XCTAssertNil(
            HistoryPane.joinedChainNotice(
                cache: makeCache(), projectURL: project, labels: [:]),
            "a Mac that is its own root joined nobody's chain (B1, arm 2)")
    }

    func test_joinedChainNotice_namesTheRootsLabel() {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let cache = makeCache()
        cache.join(root: mac, for: project)
        XCTAssertEqual(
            HistoryPane.joinedChainNotice(
                cache: cache, projectURL: project, labels: [mac: "Denver’s MacBook"]),
            "This Mac is on Denver’s MacBook’s chain.")
    }

    func test_joinedChainNotice_withNoPersonRecordFallsBackToTheRootsCode() {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let cache = makeCache()
        cache.join(root: mac, for: project)
        XCTAssertEqual(
            HistoryPane.joinedChainNotice(cache: cache, projectURL: project, labels: [:]),
            "This Mac is on 9C8B’s chain.")
    }

    /// B1's write-once rule reaches the sentence: a second root that names this
    /// device is a CLAIMANT, and the line goes on naming the chain this Mac is
    /// actually on.
    func test_joinedChainNotice_namesTheJoinedRootAndNotAClaimant() {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let cache = makeCache()
        cache.join(root: mac, for: project)
        cache.join(root: phone, for: project)
        XCTAssertEqual(
            HistoryPane.joinedChainNotice(
                cache: cache, projectURL: project,
                labels: [mac: "Denver’s MacBook", phone: "Somebody Else"]),
            "This Mac is on Denver’s MacBook’s chain.")
        XCTAssertEqual(cache.claimants(for: project), [phone])
    }

    func test_joinedChainNotice_isPerProject() {
        let project = makeProject()
        let other = makeProject()
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: other)
        }
        let cache = makeCache()
        cache.join(root: mac, for: project)
        XCTAssertNil(
            HistoryPane.joinedChainNotice(
                cache: cache, projectURL: other, labels: [mac: "Denver’s MacBook"]))
    }

    /// Ruling C's re-homing, stated as a test rather than left to the copy: the
    /// banner is a FACT that holds now, so it never carries a past tense or a
    /// date. The joining is a dated entry in the section below.
    func test_theJoinedBannerStatesAStandingFactAndNotAnEvent() {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let cache = makeCache()
        cache.join(root: mac, for: project)
        let banner = try! XCTUnwrap(HistoryPane.joinedChainNotice(
            cache: cache, projectURL: project, labels: [mac: "Denver’s MacBook"]))

        XCTAssertFalse(
            banner.localizedCaseInsensitiveContains("joined"),
            "the event moved to the project section — the banner says what holds")
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: TrustEvent(date: nil, kind: .joined, subject: mac,
                                label: "Denver’s MacBook"),
                labels: [:]),
            "This Mac joined Denver’s MacBook’s chain.",
            "and the event keeps the past tense the banner gave up")
    }

    // MARK: - The project section (ruling C's second shape)

    func test_theProjectSectionIsHeadedByTheBooksOwnWord() {
        XCTAssertEqual(HistoryPane.projectSectionTitle, "Project")
    }

    /// The section is DRAWN from these rows and nothing else, so pinning the
    /// rows pins the section — no window, no press, no wait (tripwire 33).
    func test_everyEventBecomesOneDatedRow() {
        let events = [
            TrustEvent(date: Date(timeIntervalSince1970: 90), kind: .revoked,
                       subject: phone, label: "Sam", by: mac),
            TrustEvent(date: Date(timeIntervalSince1970: 20), kind: .admitted,
                       subject: phone, label: "Sam", by: mac),
        ]
        let lines = HistoryPane.trustEventLines(events, labels: [mac: "Denver"])

        XCTAssertEqual(lines.map(\.sentence),
                       ["Sam revoked by Denver.", "Sam admitted by Denver."])
        XCTAssertEqual(lines.map(\.date), events.map(\.date))
        XCTAssertEqual(Set(lines.map(\.id)).count, 2, "a ForEach needs two identities")
    }

    /// An undated event still draws — the row simply has no date in it. This is
    /// Task 2's carry (a join from before the stamp existed) and B1's claimant,
    /// both of which must appear rather than being dropped for want of a day.
    func test_anUndatedEventStillDrawsItsRow() {
        let lines = HistoryPane.trustEventLines(
            [TrustEvent(date: nil, kind: .anotherClaimant, subject: mac)], labels: [:])

        XCTAssertEqual(lines.count, 1)
        XCTAssertNil(lines[0].date)
        XCTAssertEqual(lines[0].sentence,
                       "Another Mac (9C8B) also claims this book.")
    }

    func test_nothingHappenedMeansNoSection() {
        XCTAssertTrue(HistoryPane.trustEventLines([], labels: [:]).isEmpty)
    }

    /// Every kind gets a face of its own to the extent the vocabulary allows —
    /// what this pins is that none is left without one, and that being let in
    /// and being shown out never look the same.
    func test_everyKindOfEventHasAnIconAndTheTwoOppositesDiffer() {
        for kind in TrustEvent.Kind.allCases {
            XCTAssertFalse(HistoryPane.symbol(for: kind).isEmpty, "\(kind)")
        }
        XCTAssertNotEqual(HistoryPane.symbol(for: .admitted),
                          HistoryPane.symbol(for: .revoked))
    }

    // MARK: - Fixtures

    /// A cache under a test identity, so nothing here reaches this machine's
    /// own key material or the process-wide memory.
    private func makeCache() -> RegistryCache {
        RegistryCache(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("histchain-cache-\(UUID().uuidString).json"),
            identity: "test-identity-fingerprint")
    }

    private func makeProject() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("histchain-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        return url
    }
}
