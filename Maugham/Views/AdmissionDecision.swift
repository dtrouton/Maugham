// Maugham/Views/AdmissionDecision.swift
import Foundation
import MaughamCore

/// One device asking to be let into this book (signed op log P2, spec §4.1).
///
/// Everything the sheet says is decided here and carried as a value, so the
/// question *what would the writer be shown* is answerable with no window at
/// all. The sheet draws it; it never derives it.
struct AdmissionRequest: Identifiable, Equatable {
    /// The device this is about — the fingerprint the held lines are counted
    /// under, which is the device record's own key where a record names it and
    /// the sealing key itself where none does.
    let fingerprint: String
    /// What that device calls itself, from its device record. **Nil is a real
    /// state**: a device that wrote before this milestone, or whose record has
    /// not synced yet, is a stranger with no name, and inventing one for it
    /// would put a word in its mouth on the one screen where the writer is
    /// deciding whether to believe it.
    let ownName: String?
    /// The four characters that device shows for itself in its own Settings
    /// (`DeviceCode`). Shown, never demanded.
    let code: String
    /// How many lines of this device's history are held right now.
    let waitingCount: Int
    /// What the label field starts with — its own name, because the ordinary
    /// answer to *what shall I call this* is *what it calls itself*. Empty when
    /// the device has no record here, which leaves Admit refused until the
    /// writer types something (`outcome` answers `.notNow` for empty).
    ///
    /// **And empty when its own name is a label this book already has** (P3b
    /// smoke find F1). Two Macs sharing a name is the ORDINARY case — the
    /// shipped default, a machine restored from another's backup (tripwire
    /// 35) — and a field pre-filled with a known label is a merge: one press
    /// of Admit made a stranger the root, with the root's permit. A merge is
    /// only ever the writer's deliberate act, through *this is also…* or a
    /// label they typed; never the default. `sharesItsNameWith` says why the
    /// field is empty. This holds for the request as DERIVED; keeping a stale
    /// derivation out of the field is `AdmissionQueue.awaitingSettlement`'s and
    /// `AdmissionSheet.reseeded`'s.
    let proposedLabel: String
    /// Every label this book already knows, so *this is also…* can offer them
    /// rather than making the writer re-spell one. Sorted, and deduplicated
    /// case-insensitively on first spelling.
    let knownLabels: [String]
    /// The label this book already has that the device's OWN name matches,
    /// in that label's spelling — nil when there is none (F1). Set exactly
    /// when the device's name was withheld from `proposedLabel`.
    let sharesItsNameWith: String?
    /// **What is waiting, and where, in the writer's terms** (P3b smoke find
    /// F2) — *1 paragraph in “Chapter 3”* and the first words of it. Filled in
    /// by the window from the loads' own descriptions (`AdmissionWaiting
    /// .describe`); nil where there is nothing to describe, and the sheet then
    /// says the plain count.
    var described: AdmissionWaiting?

    init(
        fingerprint: String, ownName: String?, code: String,
        waitingCount: Int, proposedLabel: String, knownLabels: [String],
        sharesItsNameWith: String? = nil
    ) {
        self.fingerprint = fingerprint
        self.ownName = ownName
        self.code = code
        self.waitingCount = waitingCount
        self.proposedLabel = proposedLabel
        self.knownLabels = knownLabels
        self.sharesItsNameWith = sharesItsNameWith
    }

    var id: String { fingerprint }

    /// The name to say this device by in a sentence. Its own name where it has
    /// one, else the code — which is the one thing the writer can check against
    /// the other screen.
    var displayName: String {
        if let ownName, !ownName.isEmpty { return ownName }
        return "A device with code \(code)"
    }

    /// What `RegistryAdmission.admit` records as this device's own name. The
    /// device's word where the folder has it; the code otherwise, so the record
    /// carries something a human can match against a screen rather than an
    /// empty string.
    var recordedOwnName: String {
        if let ownName, !ownName.isEmpty { return ownName }
        return code
    }

    /// **What a request with nothing held says about what is waiting** (P3b
    /// smoke find F10, in F2's shape): a device whose record has arrived and
    /// none of whose writing has. One sentence, read by the sheet and by People
    /// & Devices' pending row alike, so neither can say *0 notes waiting* —
    /// a count of nothing reads as a count that failed.
    static let nothingYet = "Nothing from it has reached this Mac yet."
}

/// What pressing a button on the sheet means.
///
/// `.admit` and `.mergeUnder` both end in the same write — the difference is
/// whose SPELLING the person record carries — and they are two cases rather
/// than one so the sheet can say which is about to happen, and so a test can
/// pin the merge without reading a string twice.
enum AdmissionOutcome: Equatable {
    /// Let this device in under a label this book has not used before.
    case admit(label: String)
    /// Let it in under a label this book already has, in that label's own
    /// existing spelling. Spec §4.1: *a typed label matching an existing one
    /// merges the device under that label; nobody can be admitted AS a new
    /// "Denver" by asking.*
    case mergeUnder(label: String)
    /// Nothing happens. The lines stay held and History goes on counting them.
    case notNow
}

/// **Who is asking, and what an answer means** (spec §4.1–4.2).
///
/// Pure, and deliberately ignorant of the folder: it is handed the counts a
/// load already produced, the registry a reader already verified, and this
/// device's own label memory. Nothing here reads a file, so the whole of the
/// sheet's content is decidable in a unit test and nothing about admission is
/// only observable by mounting a window.
enum AdmissionDecision {

    /// The strangers waiting, one request each: the ones holding lines first,
    /// then the ones whose device record has arrived with nothing yet, each
    /// group ordered by fingerprint so two runs over the same folder ask in the
    /// same order.
    ///
    /// **Two ways to be somebody to ask about** (P3b smoke find F10, Denver's
    /// ruling 2026-09-24). A holder of held lines, as since P2b — and a
    /// STRANGER'S DEVICE RECORD on its own, with no line of theirs anywhere
    /// this window can see. Without the second a collaborator who wrote only
    /// in chapters this Mac has not opened, or who has not written yet, was
    /// asked about by nothing: the sheet was raised by lines, and lines in a
    /// closed chapter cost a full read of its log to find. The record is
    /// already in the verified registry this reads, so the second way costs
    /// nothing. Such a request carries `waitingCount` 0 and no `described`,
    /// and the sheet says *nothing from it has reached this Mac yet*
    /// (`AdmissionRequest.nothingYet`). A device that is both is ONE request,
    /// with its held count.
    ///
    /// A record-only candidate is a verified `DeviceRecord` that has not
    /// RETIRED (a retired machine is not asking to write anything), that is not
    /// `thisDevice` (a Mac's own record is never a request of its own), and
    /// that `standing(ofHolder:streams:registry:)` offers with no streams to
    /// judge — which is where `Registry.isStrangerDevice` is asked, so a person
    /// record under any root, an unsigned holder and a contested key are all
    /// refused by the same classification a held holder is.
    ///
    /// **Empty unless this Mac is a ROOT here.** Two rules meet in `myRoot`.
    /// Decision B3: a device no record names judges nobody, so nothing of
    /// anybody's is held and there is nothing to admit. And spec P2 §4.1's
    /// *the sheet (root device, Mac only)* (P3c Task 9, Ruling AA): an
    /// ADMITTED Mac has a root to judge by but no root record of its own, and
    /// the only answer it could give is Admit → `.notARoot`. Production
    /// callers pass `askingRoot(in:thisDevice:)` — never `TrustTable.myRoot`,
    /// which is the ADMITTING root on a non-root Mac and would put the sheet
    /// in front of every admitted Mac in the book each time a record arrives.
    ///
    /// **A fingerprint with a person record is not a stranger**, whoever
    /// admitted it: under my own root it is already in, and under another
    /// root's it is a claimant, which is merged by a claim record at a surface
    /// and never by this sheet (`RegistryAdmission.admit` refuses it outright).
    ///
    /// **And three more holders are never offered** (P3b Task 4, spec §7.1) —
    /// see `standing(ofHolder:streams:registry:)`, which is where every one of
    /// those judgements is made. `streams` is `DocumentStore.heldLines`'
    /// second half; passing none is the P2b answer, which offers everything
    /// this book has no record of.
    ///
    /// `thisDevice` is this Mac's author fingerprint — the key its own device
    /// record is filed under. Both production callers pass it; nil excludes
    /// nothing, which is only right for a registry this Mac has no record in.
    static func requests(
        pending: [String: Int],
        streams: [String: Set<String>] = [:],
        registry: Registry,
        memory: [String: AdmissionMemory.Label],
        myRoot: String?,
        thisDevice: String? = nil
    ) -> [AdmissionRequest] {
        guard myRoot != nil else { return [] }
        let labels = knownLabels(registry: registry, memory: memory)
        let holding = pending.keys.sorted().filter { fingerprint in
            guard let waiting = pending[fingerprint], waiting > 0 else { return false }
            return standing(ofHolder: fingerprint,
                            streams: streams[fingerprint] ?? [],
                            registry: registry) == .aStrangerToAskAbout
        }
        let alreadyAsked = Set(holding)
        let arrived = Set(registry.devices.filter { record in
            record.retiredAt == nil
                && record.device != thisDevice
                && !alreadyAsked.contains(record.device)
                // The one classification, as for a holder: it asks
                // `Registry.isStrangerDevice` (a person record anywhere, or an
                // unsigned holder's string, is not a stranger) and refuses a
                // contested key.
                && standing(ofHolder: record.device, streams: [], registry: registry)
                    == .aStrangerToAskAbout
        }.map(\.device)).sorted()
        return (holding + arrived).map { fingerprint -> AdmissionRequest in
            let record = registry.devices.first { $0.device == fingerprint }
            let ownName = record?.name
            let start = Self.proposal(ownName: ownName, knownLabels: labels)
            return AdmissionRequest(
                fingerprint: fingerprint,
                ownName: ownName,
                code: DeviceCode.short(fingerprint),
                waitingCount: pending[fingerprint] ?? 0,
                proposedLabel: start.label,
                knownLabels: labels,
                sharesItsNameWith: start.collidesWith)
        }
    }

    /// **What the label field starts with — never a merge** (P3b smoke F1).
    ///
    /// The device's own name, unless that name is already a label here — in
    /// which case nothing, and the label it collides with, so the sheet can
    /// say why. Matched by `matches`, the same rule `outcome` merges by, so
    /// the field's starting value can never be one `outcome` would read as
    /// `.mergeUnder`: the two cannot disagree about what a collision is.
    static func proposal(
        ownName: String?, knownLabels: [String]
    ) -> (label: String, collidesWith: String?) {
        guard let ownName, !ownName.isEmpty else { return ("", nil) }
        if let existing = knownLabels.first(where: { matches($0, ownName) }) {
            return ("", existing)
        }
        return (ownName, nil)
    }

    // MARK: - What a held holder IS (P3b Task 4, spec §7.1)

    /// **Why a holder is, or is not, somebody to put a sheet in front of.**
    ///
    /// Four answers, and only the first is a question for the writer. The other
    /// three are lines that wait for something *else* to happen — a device
    /// record to arrive, a dispute to be settled, a permit this build cannot
    /// read to be understood by one that can — and a sheet about any of them
    /// would offer a control that cannot help.
    ///
    /// Each carries its own reason rather than collapsing into a Bool, because
    /// People & Devices (Task 5) draws a LINE for each of the three, and a
    /// reason derived twice is how one surface comes to say *waiting to be let
    /// in* about a holder the other calls contested.
    enum HeldKeyStanding: Equatable {
        /// A key this book has no record of, shaped like a person's: the
        /// ordinary case, and the one the admission sheet exists for.
        case aStrangerToAskAbout
        /// A key that is not a person's — one of a device's other three
        /// writers, whose device record has not arrived yet. Admitting it would
        /// let a machine into the book under the name of its assistant.
        case waitingForItsDeviceRecord(actor: DeviceActor)
        /// Two verified device records claim this key, so it is nobody's for
        /// good (`Registry.isContestedActorKey`). There is no one person to
        /// admit and naming one would decide the thing the dispute rule
        /// refuses to decide.
        case contested
        /// Not a stranger at all — already in the book, or not a key.
        case notAStranger(HeldLines.Holder)
    }

    /// **The one classification**, over the holder string and the streams it
    /// was held in.
    ///
    /// Order matters, and it is the order of how much each answer KNOWS:
    ///
    /// 1. `HeldLines.holder` first (P3b Task 2's one classifier, asked and
    ///    never re-spelled) — an unsigned stream is decided by the string
    ///    itself and a permit-pending line by a person record, and neither is a
    ///    stranger.
    /// 2. Then the register's own opinion: a key two device records claim is
    ///    nobody's, and *nobody's* is not *unheard of*.
    /// 3. Then, and only where nothing on disk names the key at all, the FILE:
    ///    a stream slug is `<actor>-<hex of the key>`, so
    ///    `DeviceIdentity.actor(ofDeviceId:signingWith:)` can say which of the
    ///    four writers made it — and it CHECKS the claim against the key rather
    ///    than believing the word, which is what keeps this narrowing honest.
    ///
    /// **Both directions of that third rule**, because it is the one that can
    /// wrongly withhold a sheet. An honest stranger whose held lines happen to
    /// sit in her own ASSISTANT file is held under her DEVICE's fingerprint
    /// (the record names the actor key, so the walk resolves it to the device)
    /// — and that fingerprint is not a prefix-match for the assistant slug, so
    /// the checked parse answers nil and she is offered exactly as before. A
    /// slug that says `assistant` about a key it does not name narrows nothing.
    /// The only holder this withholds is one whose own file says it is not an
    /// author key, which is precisely a key no person is.
    ///
    /// **An AUTHOR slug for this very key outranks every other**, and that is
    /// the third rule's own second direction. A key that has written as an
    /// author IS a person under labels-only, whatever else names it — so a file
    /// planted beside her own tail, calling her key an assistant's, costs her
    /// nothing. Without that precedence a writer with the shared folder could
    /// deny an honest stranger her sheet by writing one filename. In every
    /// honest case the two rules agree: a non-author key never writes an
    /// author-shaped stream, because a slug is derived from the key it belongs
    /// to.
    ///
    /// A holder with no streams (a legacy file, an inbox read before this
    /// milestone, a hand-built map) is offered as P2b offered it.
    static func standing(
        ofHolder fingerprint: String,
        streams: Set<String>,
        registry: Registry
    ) -> HeldKeyStanding {
        let holder = HeldLines.holder(of: fingerprint, registry: registry)
        guard case .stranger = holder else { return .notAStranger(holder) }
        if registry.isContestedActorKey(fingerprint) { return .contested }
        var otherWriter: DeviceActor?
        for slug in streams.sorted() {
            guard let actor = DeviceIdentity.actor(
                ofDeviceId: slug, signingWith: fingerprint) else { continue }
            if actor == .author { return .aStrangerToAskAbout }
            if otherWriter == nil { otherWriter = actor }
        }
        if let otherWriter {
            return .waitingForItsDeviceRecord(actor: otherWriter)
        }
        return .aStrangerToAskAbout
    }

    // MARK: - A refresh, in order (decision B2 mid-session; find 4, 2026-09-17)

    /// **What a refresh does, and the order it does it in.**
    ///
    /// Decision B2 is *once per device*, and until this existed it held only at
    /// a project OPEN: `RegistryPresence.admitRemembered` ran there and nowhere
    /// else, so a device arriving mid-session — a window open for days, a phone
    /// syncing in over lunch — was asked about again, with the memory used only
    /// to pre-fill the label field. Mid-session arrival is the ORDINARY case.
    ///
    /// Two acts, and the order between them is the whole contract: admit
    /// everyone this Mac has already named, THEN read the registry. Read first
    /// and the person record the admission just wrote is invisible to
    /// `requests`, which asks about the device all over again — the defect,
    /// exactly, with an extra write in it.
    ///
    /// Closures rather than a store, for `CompilerOrchestrator`'s reason: the
    /// order is then decidable with no window, no folder and no admission, and
    /// a later reordering of the two lines fails a test instead of shipping.
    ///
    /// **`nil` means leave the queue alone.** A registry that will not read
    /// costs the writer the sheet, never the strangers they are already being
    /// asked about; `[]` is the different, positive answer *nobody is waiting*.
    ///
    /// **The silent admission is attempted only when something remembered is
    /// waiting** (`anyRemembered`). It costs a verified folder read and a
    /// signature check per record, and this runs on every document open that
    /// announces held lines — so a book whose only stranger is a stranger pays
    /// nothing for a memory that has nothing to say about it.
    ///
    /// **`heldStreams` is read at the same moment as the counts** (P3b Task 4)
    /// and defaults to nothing, which is the P2b answer: a holder whose stream
    /// nothing names is offered exactly as it was. It is a second closure
    /// rather than a widened first one so that the order above — admit, then
    /// re-read, then resolve — is still the only thing this function decides.
    ///
    /// **`arrivedDevices` is the F10 pre-check** (Denver's ruling,
    /// 2026-09-24): the fingerprints whose device record is on disk with no
    /// person record beside it — `devicesWithNoPersonRecord(in:excluding:)`, a
    /// listing of two folders, run detached, never a signature check and never
    /// an op log. It is what lets a stranger's RECORD raise the question with
    /// no line of theirs held, and it is also the gate on the verified read:
    /// nothing held and no such file means nobody can be asked about, so a
    /// book of admitted people pays for no resolve on a settle or an open. It
    /// is UNVERIFIED on purpose — it only decides whether to look; `requests`
    /// decides, over the verified registry, who is asked.
    ///
    /// **`recountCaptures` runs when an arrived device has nothing counted**,
    /// before anything else reads the counts. A registry settle refreshes the
    /// inbox on a task nobody awaits (`DocumentStore.invalidateTrust`), so the
    /// capture counts read here can predate captures that synced in beside the
    /// record — and the sheet would say *nothing from it has reached this Mac
    /// yet* over captures that have. Paid only when such a device exists.
    ///
    /// The silent admission is attempted for an arrived device this Mac has
    /// already named as well as for a remembered holder (`anyRemembered`):
    /// `RegistryPresence.admitRemembered` walks the folder's device records and
    /// needs no held line, so a known machine joins on its record's arrival.
    ///
    /// **And only on a SETTLE** (Ruling AB, the review's M1): `cause` says
    /// which event asked, and the recount is paid for `.settle` alone — the
    /// one event whose un-awaited inbox refresh is the race. An open or a
    /// load's announcement has counts already in hand, and a stranger who
    /// waits for days must not cost an inbox read on every chapter opened.
    ///
    /// **`holdsARootRecord` is asked FIRST** (P3c plan 2 Task 8, plan 1's
    /// limit): every production caller passes the cheap filename check
    /// (`mayHoldARootRecord(_:in:)`), and a Mac that holds no root record here
    /// answers `[]` before it counts, recounts, admits or resolves anything —
    /// the question is the root's (Ruling AA), `requests` answers `[]` for any
    /// other Mac, and `RegistryPresence.admitRemembered` refuses one. It used
    /// to pay one verified resolve per settle to learn that. Defaulted to
    /// *look*, the side that errs toward the verified read.
    @MainActor
    static func refreshedRequests(
        cause: RefreshCause = .announcement,
        holdsARootRecord: @MainActor () async -> Bool = { true },
        heldLines: @MainActor () -> [String: Int],
        heldStreams: @MainActor () -> [String: Set<String>] = { [:] },
        arrivedDevices: @MainActor () async -> Set<String> = { [] },
        recountCaptures: @MainActor () async -> Void = {},
        thisDevice: String? = nil,
        memory: [String: AdmissionMemory.Label],
        admitRemembered: @MainActor () async -> Void,
        resolve: @MainActor () async -> (registry: Registry, myRoot: String?)?
    ) async -> [AdmissionRequest]? {
        guard await holdsARootRecord() else { return [] }
        var pending = heldLines()
        var arrived = await arrivedDevices()
        guard !pending.isEmpty || !arrived.isEmpty else { return [] }
        if cause == .settle, arrived.contains(where: { (pending[$0] ?? 0) == 0 }) {
            await recountCaptures()
            pending = heldLines()
        }
        if anyRemembered(pending: pending, arrived: arrived, memory: memory) {
            await admitRemembered()
            // What it let in is applied, so the counts moved underneath us —
            // and the person records it wrote are beside their device records.
            pending = heldLines()
            arrived = await arrivedDevices()
            guard !pending.isEmpty || !arrived.isEmpty else { return [] }
        }
        guard let resolved = await resolve() else { return nil }
        return requests(
            pending: pending, streams: heldStreams(),
            registry: resolved.registry,
            memory: memory, myRoot: resolved.myRoot,
            thisDevice: thisDevice)
    }

    /// **Which event asked for a refresh** — the window's four triggers, named
    /// so a rule that holds for one of them is decided here with no window.
    enum RefreshCause: Equatable {
        /// The window opened on this project (`.task(id:)`).
        case open
        /// A load or a synced op file announced a newcomer's held lines.
        case announcement
        /// A registry change settled: a record arrived, or somebody was let
        /// in. The only cause that recounts captures.
        case settle
        /// The writer pressed an *Admit…* control; the inbox was re-read
        /// before this was asked.
        case writersPress
    }

    /// **The root this Mac may admit as, or nil** (Ruling AA): its OWN root
    /// record, asked of the one test the verbs use
    /// (`Registry.holdsARootRecord`, which `RegistryAdmission.admit` and
    /// `RegistryPresence.admitRemembered` refuse and admit by). What both
    /// production callers hand `requests` as `myRoot`.
    static func askingRoot(in registry: Registry, thisDevice: String) -> String? {
        registry.holdsARootRecord(thisDevice) ? thisDevice : nil
    }

    /// Is any device waiting here one this writer has already named?
    ///
    /// Cheap and folder-free, and keyed the way the held counts are keyed —
    /// `OpLogChain.pendingByDevice` counts under the device record's own
    /// fingerprint, which is the key `AdmissionMemory` uses, so the two spaces
    /// meet wherever a silent admission could act at all. A held count under a
    /// key no device record names cannot be admitted by
    /// `RegistryPresence.admitRemembered` either — it walks the folder's device
    /// records — so answering false about it costs nothing and the sheet still
    /// asks.
    ///
    /// **`arrived` is the second way to be waiting** (F10): a device whose
    /// record is on disk with no person record, and no line held. That is
    /// exactly the set `admitRemembered` walks, so a remembered one of them is
    /// let in on its record's arrival rather than put in front of the writer.
    static func anyRemembered(
        pending: [String: Int], arrived: Set<String> = [],
        memory: [String: AdmissionMemory.Label]
    ) -> Bool {
        pending.contains { fingerprint, waiting in
            waiting > 0 && memory[fingerprint] != nil
        } || arrived.contains { memory[$0] != nil }
    }

    // MARK: - The F10 pre-check: the one thing here that touches a folder

    /// **Which device records have arrived with no person record beside them**
    /// — by FILENAME, from a listing of `.maugham/devices` and
    /// `.maugham/people` and nothing else (P3b smoke find F10).
    ///
    /// Records are filed `<fingerprint>.json` (`RegistryWriter.url`), so a
    /// device file with no person file of the same name is a device the book
    /// has not let in — or one whose admission has not synced yet, which the
    /// verified read then sorts out. No signature check and no op log, because
    /// this runs on every registry settle and every open, and its only job is
    /// to say whether the verified read is worth paying for. A malformed or
    /// forged file answers *look*, and the look is what refuses it.
    ///
    /// **A RETIRED record is not waiting** (Ruling AB, the review's M2). The
    /// one file this opens is a device record ALREADY unmatched by name —
    /// usually none at all — and only to ask whether it carries `retiredAt`.
    /// Otherwise a retired, never-admitted machine would cost a verified read
    /// on every settle for ever, and would reach `anyRemembered`'s record arm
    /// and so the silent admission mid-session. A file that will not read or
    /// parse answers *not retired*, which is *look*.
    ///
    /// `thisDevice` is left out — a Mac waiting to be let into somebody else's
    /// book has exactly this shape for its own record, and it asks nobody about
    /// itself. A folder that will not list is answered as its absence: no
    /// devices listed means nobody to look for; no people listed means every
    /// device is worth a look, which errs toward the verified read deciding.
    ///
    /// Asks `RegistryWriter.directoryURL` for both paths (tripwire 40) and
    /// skips by NAME only (`DotfileScan`), the reader's own rule.
    ///
    /// **A person file that will not read is no person record** (P3c plan 2
    /// Task 8, plan 1's limit). Matching by NAME alone, a corrupt
    /// `people/<fp>.json` hid a record-only stranger from the question: the
    /// name matched, so the device read as already let in, and the verified
    /// read that would have refused the file was never paid for. A matched
    /// person file is now opened and must parse as a JSON object; one that does
    /// not answers *look*. Still UNVERIFIED — only whether to look is decided.
    nonisolated static func devicesWithNoPersonRecord(
        in projectURL: URL, excluding thisDevice: String?
    ) -> Set<String> {
        let devices = recordNames(in: .devices, projectURL: projectURL)
        guard !devices.isEmpty else { return [] }
        let people = recordNames(in: .people, projectURL: projectURL)
            .intersection(devices)
            .filter { readsAsARecord($0, in: .people, projectURL: projectURL) }
        var arrived = devices.subtracting(people)
        if let thisDevice { arrived.remove(thisDevice) }
        return arrived.filter { !saysItRetired($0, projectURL: projectURL) }
    }

    /// **Might this Mac hold its own ROOT record here?** — by filename first
    /// (P3c plan 2 Task 8): a root's record is filed under its own
    /// fingerprint (`RegistryWriter.url`) and names itself as its admitter
    /// (`PersonRecord.isRoot`), so no `people/<thisDevice>.json` at all is a
    /// Mac with no root record, and one that reads and names somebody else
    /// as its admitter is an admitted Mac, not a root. Either answers false
    /// and the admission question is skipped outright. UNVERIFIED like the
    /// listing beside it: a file that will not read or parse answers *look*
    /// (true), and so does a self-admitted one — the verified read
    /// (`askingRoot`, `Registry.holdsARootRecord`) is what decides.
    ///
    /// **A root whose own record was DELETED reads here as a Mac with none**
    /// (whole-branch review, Minor 1). The verified resolve that would put it
    /// back from this Mac's memory (`TrustResolution.resolveVerified` through
    /// `RegistryCache`) is never reached on this path, so that root asks no
    /// admission question until some other resolve restores the record — the
    /// next `Document.load`'s `localWritePermit`, or any posture refresh —
    /// and the question is then put at the next announcement. One
    /// announcement late, and self-healing; nothing is admitted or refused
    /// meanwhile.
    nonisolated static func mayHoldARootRecord(
        _ thisDevice: String, in projectURL: URL
    ) -> Bool {
        let url = recordURL(thisDevice, in: .people, projectURL: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let object = jsonObject(at: url),
              let admittedBy = object["admittedBy"] as? String
        else { return true }
        return admittedBy == thisDevice
    }

    /// Whether a registry file parses as a JSON object at all.
    nonisolated private static func readsAsARecord(
        _ fingerprint: String, in directory: RegistryDirectory, projectURL: URL
    ) -> Bool {
        jsonObject(at: recordURL(fingerprint, in: directory, projectURL: projectURL)) != nil
    }

    /// `<directory>/<fingerprint>.json` — asked of `RegistryWriter.directoryURL`
    /// (a read; tripwire 40), `saysItRetired`'s own spelling.
    nonisolated private static func recordURL(
        _ fingerprint: String, in directory: RegistryDirectory, projectURL: URL
    ) -> URL {
        RegistryWriter.directoryURL(directory, in: projectURL)
            .appendingPathComponent("\(fingerprint).json")
    }

    nonisolated private static func jsonObject(at url: URL) -> [String: Any]? {
        guard let bytes = try? Data(contentsOf: url)  // adr-0018-ok: a registry record's shape, never manuscript text
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    /// Whether an unmatched device file says it retired — a key's presence,
    /// UNVERIFIED on purpose, like the listing it refines: a record whose
    /// signature fails is refused by the verified read whichever way this
    /// answers, so the only thing it decides is whether to look.
    nonisolated private static func saysItRetired(
        _ fingerprint: String, projectURL: URL
    ) -> Bool {
        let url = RegistryWriter.directoryURL(.devices, in: projectURL)
            .appendingPathComponent("\(fingerprint).json")
        guard let bytes = try? Data(contentsOf: url),  // adr-0018-ok: a device record's retirement flag, never manuscript text
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let retired = object["retiredAt"]
        else { return false }
        return !(retired is NSNull)
    }

    /// The fingerprints one registry folder files records under, from their
    /// names alone.
    nonisolated private static func recordNames(
        in directory: RegistryDirectory, projectURL: URL
    ) -> Set<String> {
        let folder = RegistryWriter.directoryURL(directory, in: projectURL)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [])
        else { return [] }
        return Set(entries
            .filter { !DotfileScan.isDotfile($0) && $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent })
    }

    /// What the writer's typed label means for this request.
    ///
    /// Whitespace is trimmed first, because a trailing space is a typo and not
    /// a second person. An empty field is `.notNow` — there is nothing to call
    /// this device, so nothing is written.
    static func outcome(for request: AdmissionRequest, typedLabel: String) -> AdmissionOutcome {
        let typed = typedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return .notNow }
        if let existing = request.knownLabels.first(where: { matches($0, typed) }) {
            return .mergeUnder(label: existing)
        }
        return .admit(label: typed)
    }

    /// Two labels are the same person when they differ only in case or in the
    /// space around them. Deliberately not a fuzzier rule: "Denver" and "denver"
    /// are one writer, "Denver" and "Denvers" are two, and guessing past that
    /// would merge two people's history on a typo.
    static func matches(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines))
            == .orderedSame
    }

    /// Every label this book already knows — the registry's person records
    /// first, then anything this device has said before about a device the
    /// folder has no record of yet.
    static func knownLabels(
        registry: Registry, memory: [String: AdmissionMemory.Label]
    ) -> [String] {
        var seen: [String] = []
        for label in registry.people.map(\.label) + memory.values.map(\.label) {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !seen.contains(where: { matches($0, trimmed) }) else { continue }
            seen.append(trimmed)
        }
        return seen.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - When it refuses

    /// A refusal in the writer's own language, carrying what the error itself
    /// says (RULING-7: a thing that failed is never presented as a thing that
    /// did nothing).
    ///
    /// Anything that is not a `RegistryAdmissionError` — a write that failed, a
    /// folder that would not read — falls back to its own description, because
    /// this function has nothing to add to it. An admission refusal, though,
    /// goes to the exhaustive switch below, so a case added to that enum
    /// **cannot compile** until somebody has written the writer a sentence.
    ///
    /// **The fallback names no verb** (Task 7, 2026-09-11). This became the
    /// shared refusal door for Revoke and Retire as well as Admit, and a
    /// sentence reading *That device couldn't be admitted* over a failed
    /// revocation tells the writer the opposite of what happened — that
    /// somebody was kept out, when the truth is that they were not shut out.
    /// Every arm of the switch below names its own act because each knows it;
    /// this one does not know it, so it says nothing it cannot stand behind.
    static func refusal(_ error: Error) -> String {
        guard let refusal = error as? RegistryAdmissionError else {
            return "That didn’t work: \(error.localizedDescription)"
        }
        return sentence(for: refusal)
    }

    /// Every refusal of AUTHORITY, with the writer's next move in each.
    ///
    /// **Exhaustive on purpose, with no `default`** (the review's Important 1):
    /// a `default` arm here sent the third case to `localizedDescription`, and
    /// `RegistryAdmissionError` has no `LocalizedError` conformance anywhere, so
    /// the writer read *"The operation couldn't be completed.
    /// (MaughamCore.RegistryAdmissionError error 2.)"* about the one refusal of
    /// the three that is ROUTINE. Count the arms, never a number in prose
    /// (`feedback_prose_counts_are_unmaintainable`).
    ///
    /// Each wants a sentence of its own because each wants a different next
    /// move: *this Mac cannot do this at all*; *somebody else already did, and
    /// merging is a different act*; *wait, this will fix itself*; *there is
    /// nobody there*; *a root is claimed over, never revoked*; *only that
    /// machine can say this about itself*.
    ///
    /// The last three are revocation and retirement refusals rather than
    /// admission ones, and the exhaustive switch is how they arrived: they were
    /// added to the enum while this task was in its fix round, and the build
    /// stopped until somebody had written them. That is the guard working, and
    /// it is why there is no `default` here.
    ///
    /// **This is the ONE place a `RegistryAdmissionError` becomes a sentence**
    /// (the team lead's ruling, 2026-09-11). People & Devices' Revoke and
    /// Retire call here rather than spelling their own: two vocabularies for
    /// one enum means the same refusal reads two ways depending on which
    /// surface the writer happened to be standing in, and the arm nobody
    /// remembered to write twice is the one that falls back to an error
    /// domain — which is the defect this function was fixed for.
    static func sentence(for refusal: RegistryAdmissionError) -> String {
        switch refusal {
        case .notARoot:
            // Shared by four verbs since P3a — admit, revoke, rename and
            // changePermit all refuse a Mac that is no root here — so it names
            // the two acts rather than only the first. A sentence reading *it
            // can't let a device in* over a refused role change tells the
            // writer about a door they were not standing at.
            return "This book wasn’t started on this Mac, so it can’t let a device "
                + "in or change what one may write. Do that from the Mac it was "
                + "started on."
        case .alreadyAdmittedElsewhere(let root):
            return "Another Mac (code \(DeviceCode.short(root))) has already let this "
                + "device in. Two Macs that both started this book are brought "
                + "together by claiming it, never by admitting on both."
        case .recordUnreadable(let fingerprint):
            // The routine one, and the only refusal here that resolves ITSELF:
            // another Mac has admitted this device and its own root record has
            // not arrived yet, so everything that record is signed with reads
            // as not-a-root until it does. Writing over it would destroy their
            // admission. So the sentence is a wait, not a fix — and it names
            // the code rather than the file, because a path under
            // `.maugham/people/` may not be spelled outside `RegistryWriter`
            // (tripwire 40) and a code is what the writer can compare anyway.
            return "There’s already something here about this device (code "
                + "\(DeviceCode.short(fingerprint))) that Maugham can’t read yet — "
                + "usually another Mac letting it in, before that Mac has finished "
                + "syncing. Admitting now would overwrite it. Try again in a minute."
        case .notAdmitted(let fingerprint):
            // Four verbs reach this now, and two of them are not withdrawals
            // (fix round 2): a permit change over somebody this book never let
            // in, and one over somebody it has already shut out. Both are the
            // same fact — there is nobody here to act on — and the sentence
            // says it once rather than naming one verb's noun.
            return "This book has no device with code "
                + "\(DeviceCode.short(fingerprint)) it can act on: either it was "
                + "never let in, or it has already been shut out. Re-admit it "
                + "first if you meant to change what it may write."
        case .cannotRevokeARoot(let fingerprint):
            return "The device with code \(DeviceCode.short(fingerprint)) is the Mac "
                + "this book was started on, and that Mac answers to itself. To move "
                + "the book, claim it on the Mac you want to keep."
        case .cannotAdoptItself(let root):
            // Unreachable from either surface as they stand — the claim
            // (People & Devices' *This Book Is Mine…*) adopts the roots this Mac is NOT, and a claimant row is by
            // definition somebody else — so this sentence exists for the day a
            // third caller gets the list wrong, and says what it would mean
            // rather than what went wrong.
            return "This book was already started on this Mac (code "
                + "\(DeviceCode.short(root))), so there is nothing of its own for it "
                + "to take in."
        case .historyUnreadable(let name, let act):
            // The one refusal here that is about a FILE rather than about
            // authority, and the only one that promises nothing happened. It
            // says so first, because a writer who has just pressed a
            // destructive button needs to know the destruction did not occur
            // before they need to know why.
            //
            // **It names the ACT** (fix round 2, minor C). Four verbs compute
            // a mark and all four refuse over a short reading; this said *a
            // revocation* to all of them, so a writer who pressed *make Sam a
            // reviewer* was told a revocation had been refused.
            //
            // **And it says what to DO** (P3b Task 5, closing Task 1's review
            // Minor 4 and Task 2's review I2). A narrowing verb sweeps every
            // op-log file in the project, so it can refuse over a file
            // anywhere in the book — an iCloud placeholder that has not
            // downloaded, or a stream this Mac remembers applying from that is
            // no longer there. *Try again in a moment* is true for the first
            // and false for the second, and on its own it is a dead end for
            // both: the writer is told a filename and left with nothing to do
            // about it. The error cannot tell the two apart, so the sentence
            // names both moves and neither is a guess.
            return "Nothing was changed. Maugham couldn’t read everything this "
                + "device wrote (\(name)), and \(act.phrase) decided on a partial "
                + "reading would set aside more than you asked it to. Try again "
                + "in a moment. If it keeps refusing, open that file so iCloud "
                + "finishes downloading it \u{2014} and History shows what this "
                + "book is missing."
        case .notThatDevice(let device):
            return "Only the device with code \(DeviceCode.short(device)) can retire "
                + "itself — a retirement from anything else is one no other Mac would "
                + "accept. Retire it from that machine."
        case .cannotChangeARoot(let fingerprint):
            // The subject is the Mac this book was started on, and a book must
            // not end up with no author (spec §2). It names the CODE rather
            // than the file, for `recordUnreadable`'s reason: a path under
            // `.maugham/people/` may not be spelled outside `RegistryWriter`,
            // and a code is what the writer can check against a screen.
            return "The device with code \(DeviceCode.short(fingerprint)) is the Mac "
                + "this book was started on, and it writes the whole book — changing "
                + "that would leave the book with no author. To move the book, claim "
                + "it on the Mac you want to keep."
        case .cannotAdoptANonRoot(let fingerprint):
            return "The device with code \(DeviceCode.short(fingerprint)) didn’t start "
                + "a book of its own here, so there is no history of its own to take "
                + "in. If it has written in this book, it was let in by somebody — "
                + "nothing needs merging."
        case .narrowingWithoutASnapshot(let fingerprint):
            // Not reachable from any control this build ships — every store
            // verb that can narrow takes the photograph first — so this is the
            // sentence for the day a fourth caller forgets, and it says what
            // did not happen rather than naming a value it was not given.
            return "Nothing was changed. Before this book can limit what the device "
                + "with code \(DeviceCode.short(fingerprint)) may write, Maugham has "
                + "to note where every unsigned Mac’s writing had got to — otherwise "
                + "the limit would reach back through work already in the book. Try "
                + "again in a moment."
        case .manifestNotGated(let reason, let act):
            // The gate runs BEFORE the event, so nothing was written — and the
            // sentence has to say why the writer should care that a *version
            // number* could not be saved, because on its face that is the
            // dullest failure in the app.
            return "Nothing was changed. Before this book can limit what a device "
                + "may write, it has to be marked as needing this version of "
                + "Maugham — otherwise an older copy would go on applying writing "
                + "this book has set aside. Saving that mark failed, so "
                + "\(act.phrase) did not happen: \(reason)"
        }
    }
}
