// MaughamTests/AdmissionDecisionTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **What the admission sheet would say, decided with no window at all**
/// (signed op log P2b, spec §4.1–4.2).
///
/// Every sentence and every button's meaning is a value here, so the suite that
/// mounts the sheet only has to prove it DRAWS them — no test presses a control
/// and waits to find out what admission means (tripwire 33).
final class AdmissionDecisionTests: XCTestCase {

    private let root = "aaaa1111"
    private let phone = "ffff2222"
    private let other = "bbbb3333"

    // MARK: - Fixtures

    private func person(
        _ fingerprint: String, label: String, ownName: String = "A device",
        admittedBy: String
    ) -> PersonRecord {
        PersonRecord(
            person: fingerprint, label: label, ownName: ownName,
            admittedAt: Date(timeIntervalSince1970: 10), admittedBy: admittedBy)
    }

    private func device(_ fingerprint: String, name: String, kind: DeviceKind = .phone)
        -> DeviceRecord
    {
        DeviceRecord(
            device: fingerprint, name: name, kind: kind,
            actors: [DeviceActor.author.rawValue: fingerprint],
            madeAt: Date(timeIntervalSince1970: 5))
    }

    private func rootedRegistry(
        devices: [DeviceRecord] = [], people: [PersonRecord] = []
    ) -> Registry {
        Registry(
            devices: devices,
            people: [person(root, label: "Denver", ownName: "Denver’s MacBook",
                            admittedBy: root)] + people)
    }

    // MARK: - One request per stranger

    func test_theRequestProposesTheDevicesOwnNameAndCarriesItsCode() {
        let registry = rootedRegistry(devices: [device(phone, name: "Denver’s iPhone")])

        let requests = AdmissionDecision.requests(
            pending: [phone: 14], registry: registry, memory: [:], myRoot: root)

        XCTAssertEqual(requests.count, 1)
        let request = requests.first
        XCTAssertEqual(request?.fingerprint, phone)
        XCTAssertEqual(request?.ownName, "Denver’s iPhone")
        XCTAssertEqual(request?.proposedLabel, "Denver’s iPhone",
                       "the ordinary answer to what shall I call this is what it calls itself")
        XCTAssertEqual(request?.waitingCount, 14)
        XCTAssertEqual(request?.code, DeviceCode.short(phone))
        XCTAssertEqual(request?.displayName, "Denver’s iPhone")
    }

    func test_aStrangerWithNoRecordIsStillAskedAboutButProposesNoLabel() {
        let requests = AdmissionDecision.requests(
            pending: [phone: 3], registry: rootedRegistry(), memory: [:], myRoot: root)

        let request = requests.first
        XCTAssertEqual(request?.fingerprint, phone,
                       "a device with no record of its own is exactly the case the sheet is for")
        XCTAssertNil(request?.ownName, "and Maugham does not invent a name for it")
        XCTAssertEqual(request?.proposedLabel, "")
        XCTAssertEqual(request?.displayName, "A device with code \(DeviceCode.short(phone))")
        XCTAssertEqual(request?.recordedOwnName, DeviceCode.short(phone),
                       "the record carries something a human can match against a screen")
    }

    func test_aDeviceAlreadyAdmittedIsNotAStranger() {
        let registry = rootedRegistry(
            devices: [device(phone, name: "Denver’s iPhone")],
            people: [person(phone, label: "Denver", admittedBy: root)])

        XCTAssertTrue(AdmissionDecision.requests(
            pending: [phone: 9], registry: registry, memory: [:], myRoot: root).isEmpty)
    }

    func test_aDeviceAdmittedUnderAnotherRootIsAClaimantAndNotASheet() {
        let registry = rootedRegistry(
            devices: [device(phone, name: "Denver’s iPhone")],
            people: [person(other, label: "Someone", admittedBy: other),
                     person(phone, label: "Theirs", admittedBy: other)])

        XCTAssertTrue(
            AdmissionDecision.requests(
                pending: [phone: 4], registry: registry, memory: [:], myRoot: root).isEmpty,
            "merging two chains is a claim, and RegistryAdmission.admit would refuse this")
    }

    func test_aDeviceIsAskedAboutOncePerStrangerAndInFingerprintOrder() {
        let requests = AdmissionDecision.requests(
            pending: [phone: 1, other: 2], registry: rootedRegistry(),
            memory: [:], myRoot: root)

        XCTAssertEqual(requests.map(\.fingerprint), [other, phone].sorted(),
                       "two runs over one folder ask in the same order")
    }

    func test_aFingerprintWithNothingWaitingIsNobodyToAskAbout() {
        XCTAssertTrue(AdmissionDecision.requests(
            pending: [phone: 0], registry: rootedRegistry(), memory: [:], myRoot: root).isEmpty)
    }

    // MARK: - Decision B3: no chain, nothing to admit

    func test_withNoRootOfItsOwnThisMacAsksNobody() {
        XCTAssertTrue(
            AdmissionDecision.requests(
                pending: [phone: 14], registry: Registry(), memory: [:], myRoot: nil).isEmpty,
            "a device no record names judges nobody, so nothing is held (B3)")
    }

    // MARK: - Known labels

    func test_knownLabelsComeFromTheRegistryAndFromWhatThisMacRemembers() {
        let registry = rootedRegistry(
            devices: [device(phone, name: "Denver’s iPhone")],
            people: [person(other, label: "Amelia", admittedBy: root)])
        let memory = [
            "cccc4444": AdmissionMemory.Label(
                label: "Rosa", ownName: "Rosa’s iPad",
                labelledAt: Date(timeIntervalSince1970: 1)),
        ]

        let labels = AdmissionDecision.requests(
            pending: [phone: 1], registry: registry, memory: memory, myRoot: root
        ).first?.knownLabels

        XCTAssertEqual(labels, ["Amelia", "Denver", "Rosa"],
                       "sorted, so 'this is also…' reads the same twice")
    }

    func test_oneLabelSpelledTwoWaysIsOneLabel() {
        let registry = rootedRegistry(
            people: [person(other, label: "denver ", admittedBy: root)])

        XCTAssertEqual(
            AdmissionDecision.knownLabels(registry: registry, memory: [:]), ["Denver"],
            "the first spelling stands; a case difference is not a second person")
    }

    // MARK: - What an answer means

    func test_aTypedLabelNobodyUsesAdmitsUnderIt() {
        let request = AdmissionDecision.requests(
            pending: [phone: 1], registry: rootedRegistry(), memory: [:], myRoot: root).first!

        XCTAssertEqual(AdmissionDecision.outcome(for: request, typedLabel: "Amelia"),
                       .admit(label: "Amelia"))
    }

    func test_aTypedLabelThatMatchesAnExistingOneMergesUnderItsOwnSpelling() {
        let request = AdmissionDecision.requests(
            pending: [phone: 1], registry: rootedRegistry(), memory: [:], myRoot: root).first!

        XCTAssertEqual(AdmissionDecision.outcome(for: request, typedLabel: "  denver "),
                       .mergeUnder(label: "Denver"),
                       "nobody is admitted AS a new Denver by asking (spec §4.1)")
    }

    func test_anEmptyLabelIsNotNow() {
        let request = AdmissionDecision.requests(
            pending: [phone: 1], registry: rootedRegistry(), memory: [:], myRoot: root).first!

        XCTAssertEqual(AdmissionDecision.outcome(for: request, typedLabel: "   "), .notNow,
                       "there is nothing to call this device, so nothing is written")
        XCTAssertEqual(request.waitingCount, 1,
                       "and the lines stay held — Not now changes no count")
    }

    func test_theProposedLabelOfADeviceWithNoRecordIsItselfNotNow() {
        let request = AdmissionDecision.requests(
            pending: [phone: 1], registry: rootedRegistry(), memory: [:], myRoot: root).first!

        XCTAssertEqual(
            AdmissionDecision.outcome(for: request, typedLabel: request.proposedLabel), .notNow,
            "Admit is refused until the writer says what to call it")
    }

    // MARK: - Refusals speak (RULING-7)

    func test_eachRefusalCarriesItsOwnSentence() {
        let notARoot = AdmissionDecision.refusal(RegistryAdmissionError.notARoot)
        XCTAssertTrue(notARoot.contains("root"), notARoot)

        let elsewhere = AdmissionDecision.refusal(
            RegistryAdmissionError.alreadyAdmittedElsewhere(root: root))
        XCTAssertTrue(elsewhere.contains(DeviceCode.short(root)),
                      "it names the Mac that already admitted it: \(elsewhere)")
        XCTAssertNotEqual(notARoot, elsewhere,
                          "two refusals with two different next moves")
    }

    /// **The refusal that promises nothing happened** (find-5 review, the
    /// High), and the only one here about a FILE rather than about authority.
    ///
    /// A writer who has just pressed a destructive button needs to know the
    /// destruction did not occur before they need to know why, so the sentence
    /// leads with it — and it names the file, because *try again* is only
    /// actionable if they can tell whether the same thing is still wrong.
    func test_theUnreadableHistoryRefusalLeadsWithNothingHavingHappened() {
        let sentence = AdmissionDecision.refusal(
            RegistryAdmissionError.historyUnreadable(name: "doc-3.maca.jsonl"))

        XCTAssertTrue(sentence.hasPrefix("Nothing was changed."), sentence)
        XCTAssertTrue(sentence.contains("doc-3.maca.jsonl"),
                      "it names what would not read: \(sentence)")
        XCTAssertTrue(sentence.localizedCaseInsensitiveContains("try again"), sentence)
    }

    /// The routine refusal, and the one that used to reach the writer as
    /// *"(MaughamCore.RegistryAdmissionError error 2.)"* — a `default` arm sent
    /// it to `localizedDescription` and the enum conforms to `LocalizedError`
    /// nowhere.
    func test_theRefusalThatResolvesItselfSaysSoAndNamesTheDevice() {
        let unreadable = AdmissionDecision.refusal(
            RegistryAdmissionError.recordUnreadable(fingerprint: phone))

        XCTAssertTrue(unreadable.contains(DeviceCode.short(phone)),
                      "it names the device by the code the writer can compare: \(unreadable)")
        XCTAssertTrue(unreadable.localizedCaseInsensitiveContains("try again"),
                      "and says the true next move, which is to wait: \(unreadable)")
        XCTAssertFalse(unreadable.contains("RegistryAdmissionError"),
                       "never an error domain: \(unreadable)")
        XCTAssertFalse(unreadable.contains("maugham/people"),
                       "and never a registry path (tripwire 40): \(unreadable)")
    }

    /// Every case of the enum, told apart. The switch behind these is
    /// exhaustive with no `default`, so a case added later cannot compile until
    /// somebody writes the writer a sentence — this asserts the sentences are
    /// actually DIFFERENT, which is the half a compiler cannot check.
    func test_noTwoRefusalsShareASentence() {
        let sentences = [
            RegistryAdmissionError.notARoot,
            .alreadyAdmittedElsewhere(root: root),
            .recordUnreadable(fingerprint: phone),
            .notAdmitted(fingerprint: phone),
            .cannotRevokeARoot(fingerprint: root),
            .notThatDevice(device: other),
        ].map(AdmissionDecision.sentence(for:))

        XCTAssertEqual(Set(sentences).count, sentences.count,
                       "each refusal has a next move of its own: \(sentences)")
        for sentence in sentences {
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertFalse(sentence.contains("couldn’t be completed"),
                           "no Foundation boilerplate: \(sentence)")
        }
    }

    // MARK: - Decision B2 mid-session: the refresh admits before it asks

    /// A recording of what a refresh did, in the order it did it — which is the
    /// whole of find 4: today's refresh reads the memory for a LABEL and asks
    /// anyway, so the pin has to be about the order of two acts and not about
    /// either one alone.
    @MainActor
    private final class RefreshLog {
        var acts: [String] = []
        var registry: Registry
        var held: [String: Int]

        init(registry: Registry, held: [String: Int]) {
            self.registry = registry
            self.held = held
        }
    }

    /// The refresh, driven with no window and no folder: the closures are what
    /// `AdmissionModifier` hands it, and `admitRemembered` here does what
    /// `RegistryPresence.admitRemembered` does on disk — writes the person
    /// record and lets the held span in.
    @MainActor
    private func refresh(
        _ log: RefreshLog,
        admits: PersonRecord? = nil,
        memory: [String: AdmissionMemory.Label] = [:],
        resolves: Bool = true
    ) async -> [AdmissionRequest]? {
        await AdmissionDecision.refreshedRequests(
            heldLines: { log.held },
            memory: memory,
            admitRemembered: {
                log.acts.append("admit")
                guard let admits else { return }
                log.registry = Registry(
                    devices: log.registry.devices, people: log.registry.people + [admits])
                log.held.removeValue(forKey: admits.person)
            },
            resolve: {
                log.acts.append("resolve")
                return resolves ? (registry: log.registry, myRoot: self.root) : nil
            })
    }

    /// Two devices arrive mid-session: one this Mac named in an earlier book,
    /// one it has never seen. The remembered one is let in without a word and
    /// its span applies; the stranger is still asked about, exactly once.
    ///
    /// **This is also the order pin.** `resolve` answers the registry as it
    /// stands WHEN IT IS CALLED, so a refresh that read the folder before
    /// admitting would hand `requests` a registry with no person record for the
    /// phone and put its sheet up — which is find 4 itself, now with a wasted
    /// write in front of it.
    @MainActor
    func test_aRememberedDeviceArrivingMidSessionIsAdmittedAndTheStrangerIsNot() async {
        let log = RefreshLog(
            registry: rootedRegistry(devices: [device(phone, name: "Denver’s iPhone")]),
            held: [phone: 4, other: 2])
        let memory = [phone: AdmissionMemory.Label(
            label: "Denver", ownName: "Denver’s iPhone",
            labelledAt: Date(timeIntervalSince1970: 1))]

        let requests = await refresh(
            log, admits: person(phone, label: "Denver", admittedBy: root), memory: memory)

        XCTAssertEqual(requests?.map(\.fingerprint), [other],
                       "decision B2 is once per device, and this Mac has already named "
                           + "the phone — the stranger is a different question")
        XCTAssertEqual(log.acts, ["admit", "resolve"],
                       "the registry is read AFTER the silent admission, or the person "
                           + "record it just wrote is invisible to the queue")
        XCTAssertEqual(log.held, [other: 2], "and the span it was holding is applied")
    }

    /// The same, with nobody else waiting: there is nothing left held, so there
    /// is nothing to ask about and no folder is read to find that out.
    @MainActor
    func test_aRememberedDeviceIsTheWholeQueueAndTheQueueEmpties() async {
        let log = RefreshLog(
            registry: rootedRegistry(devices: [device(phone, name: "Denver’s iPhone")]),
            held: [phone: 4])
        let memory = [phone: AdmissionMemory.Label(
            label: "Denver", ownName: "Denver’s iPhone",
            labelledAt: Date(timeIntervalSince1970: 1))]

        let requests = await refresh(
            log, admits: person(phone, label: "Denver", admittedBy: root), memory: memory)

        XCTAssertEqual(requests, [])
        XCTAssertEqual(log.acts, ["admit"])
    }

    @MainActor
    func test_aDeviceThisMacHasNeverNamedStillRaisesExactlyOneRequest() async {
        let log = RefreshLog(
            registry: rootedRegistry(devices: [device(phone, name: "Denver’s iPhone")]),
            held: [phone: 4])

        let requests = await refresh(log)

        XCTAssertEqual(requests?.map(\.fingerprint), [phone])
        XCTAssertEqual(requests?.first?.waitingCount, 4)
    }

    /// The silent admission costs a verified folder read, and the refresh runs
    /// on every document open that announces held lines. Nothing this Mac has
    /// named is waiting, so there is nothing for it to do and it is not asked.
    @MainActor
    func test_nothingRememberedIsWaitingSoNoSilentAdmissionIsAttempted() async {
        let log = RefreshLog(
            registry: rootedRegistry(devices: [device(phone, name: "Denver’s iPhone")]),
            held: [phone: 4])
        let memory = ["cccc4444": AdmissionMemory.Label(
            label: "Rosa", ownName: "Rosa’s iPad",
            labelledAt: Date(timeIntervalSince1970: 1))]

        _ = await refresh(log, memory: memory)

        let acts = log.acts
        XCTAssertEqual(acts, ["resolve"])
    }

    @MainActor
    func test_nothingHeldAnywhereAsksNobodyAndAdmitsNobody() async {
        let log = RefreshLog(registry: rootedRegistry(), held: [:])

        let requests = await refresh(log)

        XCTAssertEqual(requests, [], "an empty queue, not a queue left standing")
        let acts = log.acts
        XCTAssertEqual(acts, [], "and no folder is read to find that out")
    }

    /// A registry that will not read costs the writer the sheet, never the
    /// queue they already have — `nil` is *leave it alone*, which `[]` is not.
    @MainActor
    func test_aRegistryThatWillNotReadLeavesTheQueueAlone() async {
        let log = RefreshLog(registry: rootedRegistry(), held: [phone: 2])

        let requests = await refresh(log, resolves: false)

        XCTAssertNil(requests)
    }

    /// Anything that is NOT an admission refusal still says what it was. The
    /// fallback is on the outer function, not a `default` inside the switch,
    /// which is what keeps the enum's own arms compiler-checked.
    ///
    /// **And it names no verb.** This function is the shared refusal door for
    /// Revoke and Retire as well as Admit, so a fallback saying *couldn't be
    /// admitted* would tell a writer whose revocation failed the opposite of
    /// what happened.
    func test_anErrorThatIsNotAnAdmissionRefusalStillSpeaksAndNamesNoVerb() {
        struct Disk: LocalizedError {
            var errorDescription: String? { "The folder is read-only." }
        }

        let sentence = AdmissionDecision.refusal(Disk())

        XCTAssertTrue(sentence.contains("The folder is read-only."), sentence)
        for verb in ["admitted", "revoked", "retired"] {
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains(verb),
                           "the fallback does not know which act failed: \(sentence)")
        }
    }
}
