import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class BibleStoreTests: XCTestCase {
    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BibleStore-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// A fresh store over its own unique project directory. Unlike
    /// `DiagnosticsStore`, `BibleStore.init` reads its sidecar eagerly (see
    /// the type doc), so two stores sharing one fixed path — even a
    /// nonexistent one like `/tmp/unused` — would read back whatever the
    /// previous test's `persist()` left on disk. Every test gets its own
    /// directory for that reason.
    private func makeStore() throws -> BibleStore {
        BibleStore(projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
    }

    /// Whole-second, on `DiagnosticsStoreTests`' precedent: ISO8601
    /// round-tripping through the sidecar truncates fractional seconds, so a
    /// sub-second `Date()` fixture fails equality after a save/load cycle
    /// for a reason that has nothing to do with the store's correctness.
    private func wholeSecondNow() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private func makeFact(
        subject: String = "Kelly", fact: String = "has a scar on her left hand",
        establishedAt: String? = "abcd", excerpt: String? = "She turned her hand over and\u{2026}",
        docId: String = "docA"
    ) -> BibleFact {
        BibleFact(
            id: ULID.generate(), subject: subject, fact: fact,
            establishedAt: establishedAt, excerpt: excerpt, docId: docId,
            recordedAt: wholeSecondNow())
    }

    // MARK: - Sidecar filename

    func test_sidecarFilename_isPerDevice_andTakesDeviceSlug() {
        let project = URL(fileURLWithPath: "/tmp/project")
        let slug = DeviceSlug.make(from: "Denvers-Mac.local")
        let url = BibleStore.sidecarURL(projectRoot: project, device: slug)
        XCTAssertEqual(
            url.path,
            project.appendingPathComponent(".maugham/bible.\(slug.raw).json").path)
    }

    // MARK: - Round-trip / corrupt-empty / version (DiagnosticsStore discipline)

    func test_roundTrip_survivesRelaunchWithoutBeingTold() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")

        let store1 = BibleStore(projectRoot: project, device: device)
        let fact = makeFact()
        store1.record([fact])

        // No explicit `load()` call — `init` alone must serve it.
        let store2 = BibleStore(projectRoot: project, device: device)

        XCTAssertEqual(store2.allFacts(), [fact])
        XCTAssertEqual(store2.allFacts().first?.excerpt, fact.excerpt,
                       "the establishing paragraph's words did not survive the sidecar — "
                       + "the pane's caption is the only thing that reads them, and its "
                       + "fallback is to say less, not to print the id")
    }

    /// **A sidecar written before excerpts existed still loads** — and its rows
    /// come back with a nil excerpt rather than failing to decode and taking
    /// the whole ledger with them.
    ///
    /// The field is additive on derived state, which is why there is no
    /// migration: this test is what says "additive" was true. The raw JSON is
    /// hand-written on purpose — encoding a `BibleFact` with a nil excerpt
    /// would prove only that this build's encoder and decoder agree.
    func test_aSidecarFromBeforeExcerptsExistedStillLoads() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let url = BibleStore.sidecarURL(projectRoot: project, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            [{"id":"f1","subject":"Kelly","fact":"Kelly is a nurse.",\
            "establishedAt":"abcd","docId":"docA","recordedAt":"2026-08-07T09:00:00Z"}]
            """.utf8).write(to: url)

        let store = BibleStore(projectRoot: project, device: device)

        XCTAssertEqual(store.allFacts().count, 1,
                       "an old row failed to decode, so one new field cost the ledger")
        XCTAssertEqual(store.allFacts().first?.establishedAt, "abcd")
        XCTAssertNil(store.allFacts().first?.excerpt)
    }

    func test_corruptSidecar_readsAsEmpty_neverThrows() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let url = BibleStore.sidecarURL(projectRoot: project, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0x00, 0x13, 0x37]).write(to: url)

        let store = BibleStore(projectRoot: project, device: device)

        XCTAssertEqual(store.allFacts(), [])
    }

    /// **A decodable sidecar carrying one id twice must not take the app down**
    /// (whole-branch review, I1).
    ///
    /// `Dictionary(uniqueKeysWithValues:)` traps on a duplicate key, and this
    /// load runs from `init`, which runs from `ProjectWindow.load()` — so a
    /// sidecar that decodes but repeats an id crashed the app **at project
    /// open**, and went on crashing it until somebody found and deleted a
    /// hidden file. Nothing in production writes duplicates (`persist`
    /// serializes a dictionary), which is exactly why this needs a test: the
    /// contract this type states is "a missing or corrupt sidecar reads as
    /// empty rather than throwing", and a decodable-but-corrupt file is the
    /// case that contract exists for.
    ///
    /// The survivor is the newest reading, because that is the one a later run
    /// recorded.
    func test_aSidecarWithDuplicateIdsLoadsWithoutTakingTheAppDown() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let older = BibleFact(
            id: "same-id", subject: "Kelly", fact: "the older reading",
            establishedAt: "abcd", docId: "docA",
            recordedAt: Date(timeIntervalSince1970: 1_786_000_000))
        let newer = BibleFact(
            id: "same-id", subject: "Kelly", fact: "the newer reading",
            establishedAt: "abcd", docId: "docA",
            recordedAt: Date(timeIntervalSince1970: 1_786_060_800))
        try writeSidecar([older, newer], project: project, device: device)

        let store = BibleStore(projectRoot: project, device: device)

        XCTAssertEqual(store.allFacts().count, 1,
                       "one id must yield one fact")
        XCTAssertEqual(store.allFacts().first?.fact, "the newer reading",
                       "the survivor of a duplicate id is the newest reading")

        // Both orders, because a rule that depends on which one the array
        // happened to list first is not a rule.
        try writeSidecar([newer, older], project: project, device: device)
        let reversed = BibleStore(projectRoot: project, device: device)
        XCTAssertEqual(reversed.allFacts().first?.fact, "the newer reading",
                       "the survivor changed with the order the file listed them in")
    }

    /// Two duplicates recorded in the same instant still resolve to one answer,
    /// and to the SAME answer every time — the sidecar is rewritten from a
    /// dictionary, so the order it lists them in is not stable and cannot be
    /// what decides.
    func test_duplicatesRecordedInTheSameInstantResolveDeterministically() throws {
        let instant = Date(timeIntervalSince1970: 1_786_060_800)
        let a = BibleFact(id: "same-id", subject: "Kelly", fact: "aaa",
                          establishedAt: nil, docId: "docA", recordedAt: instant)
        let b = BibleFact(id: "same-id", subject: "Kelly", fact: "bbb",
                          establishedAt: nil, docId: "docA", recordedAt: instant)
        XCTAssertEqual(BibleStore.survivor(a, b), BibleStore.survivor(b, a))
    }

    private func writeSidecar(
        _ facts: [BibleFact], project: URL, device: DeviceSlug
    ) throws {
        let url = BibleStore.sidecarURL(projectRoot: project, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(facts).write(to: url)
    }

    func test_missingSidecar_readsAsEmpty_neverThrows() throws {
        let project = try makeProject()
        let store = BibleStore(projectRoot: project, device: DeviceSlug.make(from: "test-mac"))
        XCTAssertEqual(store.allFacts(), [])
    }

    func test_perDevice_sidecarsDoNotCollide() throws {
        let project = try makeProject()
        let deviceA = DeviceSlug.make(from: "mac-a")
        let deviceB = DeviceSlug.make(from: "mac-b")

        let storeA = BibleStore(projectRoot: project, device: deviceA)
        storeA.record([makeFact(subject: "Kelly", fact: "fact from mac A")])

        let storeB = BibleStore(projectRoot: project, device: deviceB)
        XCTAssertEqual(storeB.allFacts(), [], "a fresh device's sidecar starts empty")

        storeB.record([makeFact(subject: "Denver", fact: "fact from mac B")])

        XCTAssertEqual(storeA.allFacts().count, 1)
        XCTAssertEqual(storeB.allFacts().count, 1)
        XCTAssertNotEqual(storeA.allFacts().first?.subject, storeB.allFacts().first?.subject)
    }

    func test_record_bumpsVersion() throws {
        let store = try makeStore()
        let versionBefore = store.version

        store.record([makeFact()])

        XCTAssertGreaterThan(store.version, versionBefore)
    }

    func test_dismiss_bumpsVersion() throws {
        let store = try makeStore()
        let fact = makeFact()
        store.record([fact])
        let versionBefore = store.version

        store.dismiss(fact.id)

        XCTAssertGreaterThan(store.version, versionBefore)
    }

    func test_dismiss_unknownId_isANoOp_doesNotBumpVersion() throws {
        let store = try makeStore()
        store.record([makeFact()])
        let versionBefore = store.version

        store.dismiss("never-recorded")

        XCTAssertEqual(store.version, versionBefore)
    }

    // MARK: - record dedupes

    /// A compiler run re-executed over the same delta (crash-recovery, a
    /// re-run the writer triggered by hand) must not double the ledger.
    func test_reindexingIsIdempotent() throws {
        let store = try makeStore()
        let fact = makeFact(subject: "Kelly", fact: "has a scar on her left hand")

        store.record([fact])
        // Re-running the same delta mints a fresh id (a fresh run, a fresh
        // ULID) but the same (subject, fact) pair.
        let rerun = makeFact(subject: "Kelly", fact: "has a scar on her left hand")
        store.record([rerun])

        XCTAssertEqual(store.allFacts().count, 1, "re-indexing the same delta must not double the ledger")
        XCTAssertEqual(store.allFacts().first?.id, fact.id, "the first-recorded id wins")
    }

    func test_record_dedupesCaseInsensitively() throws {
        let store = try makeStore()
        store.record([makeFact(subject: "Kelly", fact: "Has A Scar On Her Left Hand")])
        store.record([makeFact(subject: "KELLY", fact: "has a scar on her left hand")])

        XCTAssertEqual(store.allFacts().count, 1)
    }

    func test_record_keepsDistinctFactsForTheSameSubject() throws {
        let store = try makeStore()
        store.record([
            makeFact(subject: "Kelly", fact: "has a scar on her left hand"),
            makeFact(subject: "Kelly", fact: "is left-handed"),
        ])

        XCTAssertEqual(store.allFacts().count, 2)
    }

    func test_record_doesNotConflateSubjectAndFactAcrossTheBoundary() throws {
        // subject: "AB", fact: "C"  vs.  subject: "A", fact: "BC" must not
        // collide under whatever separator the dedupe key uses.
        let store = try makeStore()
        store.record([makeFact(subject: "AB", fact: "C")])
        store.record([makeFact(subject: "A", fact: "BC")])

        XCTAssertEqual(store.allFacts().count, 2)
    }

    // MARK: - dismiss / return (spec §3.3)

    /// Dismiss removes the entry; a later `record` of the identical
    /// `(subject, fact)` pair is NOT blocked as a duplicate — the manuscript
    /// re-establishing a dismissed fact is a reading returning, not a
    /// record surviving (spec §3.3: "may return if the manuscript
    /// re-establishes it"). This is intended behavior, not a dedupe gap.
    func test_dismissedFactCanReturn_thisIsIntended() throws {
        let store = try makeStore()
        let fact = makeFact(subject: "Kelly", fact: "has a scar on her left hand")
        store.record([fact])
        store.dismiss(fact.id)
        XCTAssertEqual(store.allFacts(), [], "the dismissal must have taken")

        let reestablished = makeFact(subject: "Kelly", fact: "has a scar on her left hand")
        store.record([reestablished])

        XCTAssertEqual(
            store.allFacts().map(\.id), [reestablished.id],
            "a re-record of a dismissed fact's (subject, fact) pair is intended to return \u{2014} " +
            "it is a fresh reading, not a record the dismissal is meant to keep blocking")
    }

    func test_dismiss_removesOnlyTheNamedFact() throws {
        let store = try makeStore()
        let keep = makeFact(subject: "Kelly", fact: "has a scar on her left hand")
        let drop = makeFact(subject: "Kelly", fact: "is left-handed")
        store.record([keep, drop])

        store.dismiss(drop.id)

        XCTAssertEqual(store.allFacts().map(\.id), [keep.id])
    }

    // MARK: - project-scoped filters

    /// `facts(subjects:)` is the run's slice: subject match only, regardless
    /// of which document established the fact. Cross-piece aggregation is
    /// out of scope (spec §9) for a PANE listing every piece a character
    /// appears in — it is not a reason to hide a subject's facts from
    /// Stage 2 by document.
    func test_facts_filtersBySubjectOnly_acrossDocuments() throws {
        let store = try makeStore()
        let kellyInDocA = makeFact(subject: "Kelly", fact: "has a scar", docId: "docA")
        let kellyInDocB = makeFact(subject: "Kelly", fact: "hates the sea", docId: "docB")
        let denverInDocA = makeFact(subject: "Denver", fact: "collects maps", docId: "docA")
        store.record([kellyInDocA, kellyInDocB, denverInDocA])

        let sliced = store.facts(subjects: ["Kelly"])

        XCTAssertEqual(Set(sliced.map(\.id)), Set([kellyInDocA.id, kellyInDocB.id]),
                       "subject match spans documents")
        XCTAssertFalse(sliced.contains { $0.id == denverInDocA.id })
    }

    func test_facts_withMultipleSubjects_unionsThem() throws {
        let store = try makeStore()
        let kelly = makeFact(subject: "Kelly", fact: "has a scar")
        let denver = makeFact(subject: "Denver", fact: "collects maps")
        let other = makeFact(subject: "Nobody", fact: "unrelated")
        store.record([kelly, denver, other])

        let sliced = store.facts(subjects: ["Kelly", "Denver"])

        XCTAssertEqual(Set(sliced.map(\.id)), Set([kelly.id, denver.id]))
    }

    /// `allFacts()` is the pane's stratum, unfiltered by document — the
    /// caller (a piece's Bible pane) filters by `docId` itself. Asserted
    /// separately from the subject filter above, per the brief: "assert
    /// both filters."
    func test_allFacts_letsTheCallerFilterByDocId_forThePanesStratum() throws {
        let store = try makeStore()
        let inDocA = makeFact(subject: "Kelly", fact: "has a scar", docId: "docA")
        let inDocB = makeFact(subject: "Kelly", fact: "hates the sea", docId: "docB")
        store.record([inDocA, inDocB])

        let paneForDocA = store.allFacts().filter { $0.docId == "docA" }

        XCTAssertEqual(paneForDocA.map(\.id), [inDocA.id])
        XCTAssertEqual(store.allFacts().count, 2, "allFacts() itself is not scoped to one document")
    }
}
