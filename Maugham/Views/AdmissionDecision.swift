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
    let proposedLabel: String
    /// Every label this book already knows, so *this is also…* can offer them
    /// rather than making the writer re-spell one. Sorted, and deduplicated
    /// case-insensitively on first spelling.
    let knownLabels: [String]

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

    /// The strangers waiting, one request each, ordered by fingerprint so two
    /// runs over the same folder ask in the same order.
    ///
    /// **Empty when this device has no root** (decision B3). A device no record
    /// names judges nobody, so nothing of anybody's is held and there is
    /// nothing to admit — and asking anyway would be this Mac inviting a device
    /// into a book it is not itself in. `myRoot` is `TrustTable.myRoot`.
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
    static func requests(
        pending: [String: Int],
        streams: [String: Set<String>] = [:],
        registry: Registry,
        memory: [String: AdmissionMemory.Label],
        myRoot: String?
    ) -> [AdmissionRequest] {
        guard myRoot != nil else { return [] }
        let labels = knownLabels(registry: registry, memory: memory)
        return pending.keys.sorted().compactMap { fingerprint -> AdmissionRequest? in
            guard let waiting = pending[fingerprint], waiting > 0 else { return nil }
            guard standing(ofHolder: fingerprint,
                           streams: streams[fingerprint] ?? [],
                           registry: registry) == .aStrangerToAskAbout
            else { return nil }
            let record = registry.devices.first { $0.device == fingerprint }
            let ownName = record?.name
            return AdmissionRequest(
                fingerprint: fingerprint,
                ownName: ownName,
                code: DeviceCode.short(fingerprint),
                waitingCount: waiting,
                proposedLabel: ownName ?? "",
                knownLabels: labels)
        }
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
    @MainActor
    static func refreshedRequests(
        heldLines: @MainActor () -> [String: Int],
        heldStreams: @MainActor () -> [String: Set<String>] = { [:] },
        memory: [String: AdmissionMemory.Label],
        admitRemembered: @MainActor () async -> Void,
        resolve: @MainActor () async -> (registry: Registry, myRoot: String?)?
    ) async -> [AdmissionRequest]? {
        var pending = heldLines()
        guard !pending.isEmpty else { return [] }
        if anyRemembered(pending: pending, memory: memory) {
            await admitRemembered()
            // What it let in is applied, so the counts moved underneath us.
            pending = heldLines()
            guard !pending.isEmpty else { return [] }
        }
        guard let resolved = await resolve() else { return nil }
        return requests(
            pending: pending, streams: heldStreams(),
            registry: resolved.registry,
            memory: memory, myRoot: resolved.myRoot)
    }

    /// Is any device with lines held here one this writer has already named?
    ///
    /// Cheap and folder-free, and keyed the way the held counts are keyed —
    /// `OpLogChain.pendingByDevice` counts under the device record's own
    /// fingerprint, which is the key `AdmissionMemory` uses, so the two spaces
    /// meet wherever a silent admission could act at all. A held count under a
    /// key no device record names cannot be admitted by
    /// `RegistryPresence.admitRemembered` either — it walks the folder's device
    /// records — so answering false about it costs nothing and the sheet still
    /// asks.
    static func anyRemembered(
        pending: [String: Int], memory: [String: AdmissionMemory.Label]
    ) -> Bool {
        pending.contains { fingerprint, waiting in
            waiting > 0 && memory[fingerprint] != nil
        }
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
            // Unreachable from either surface as they stand — the claim sheet
            // adopts the roots this Mac is NOT, and a claimant row is by
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
            return "Nothing was changed. Maugham couldn’t read everything this "
                + "device wrote (\(name)), and \(act.phrase) decided on a partial "
                + "reading would set aside more than you asked it to. Try again "
                + "in a moment."
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
