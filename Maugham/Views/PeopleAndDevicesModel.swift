import Foundation
import MaughamCore

/// **Who may write in this book, on which devices, and what is waiting**
/// (signed op log P2, spec §6) — as a value.
///
/// The registry is three directories of signed records; the trust table turns
/// them into verdicts; this device's own memory holds the labels it gave and
/// the claimants it has heard. A writer asking *who is in my book* needs all
/// three put together, and the putting-together is the part with the judgment
/// in it: which row is a question and which is a fact, which root is this Mac,
/// which claimant has already been answered. So it is decided here, once, as a
/// pure function, and the section below it draws exactly what it is handed.
///
/// **Nothing here reads a folder, a clock or a shared cache.** Every input is
/// an argument, which is what lets each rule be pinned as a value —
/// `TrustTable`'s own discipline, for its own reason.
///
/// **A refusal is a state of its own** (RULING-54). A registry record present
/// and unreadable answers with the read's own sentence and NO rows: empty rows
/// would tell the writer that nobody may write in this book, which is a trust
/// decision nobody made.
struct PeopleAndDevicesModel: Equatable {

    /// The one sentence that says what this section can and cannot do. Removing
    /// a device here is Maugham's decision about what it applies; it is not a
    /// lock on the folder, and a writer who thought otherwise would leave a
    /// machine they meant to shut out still writing into the share.
    static let shareSentence =
        "Removing a device here stops Maugham applying what it writes. "
        + "To stop it writing at all, remove it from the iCloud share."

    /// **What Merge says, and what it is** (P2b Task 8, spec §5). A claimant
    /// is another root that names this device, and the writer is the only one
    /// who can say whether that root is also them. Pressing it writes a claim
    /// adopting their chain; it moves nobody's root, and the other Mac makes
    /// the same press to see this one's history (plan decision P2).
    static let mergeHelp = "Adopt this root’s history into this book’s chain"

    /// The sentence beside Merge, which says the thing a writer would
    /// otherwise assume: adopting is not switching. This device stays on its
    /// own chain and that Mac stays on its.
    static let mergeSentence =
        "This Mac will apply everything that root’s devices wrote. "
        + "They keep their own root, and this Mac keeps its own."

    /// **The sentence beside Revoke** (spec §5). It says exactly what the verb
    /// is and, more importantly, what it is not: Maugham decides what it
    /// applies, and it does not hold the door of the share. A writer who
    /// thought otherwise would leave a machine they meant to shut out still
    /// writing into the folder every other device reads.
    static let revokeSentence =
        "This stops Maugham applying what this device writes. "
        + "To stop it writing at all, remove it from the iCloud share."

    /// What Revoke says when it is offered, and why it is not.
    static let revokeHelp = "Stop applying what this device writes"
    static let revokeNotMine =
        "Only the Mac that admitted this device can revoke it"
    static let revokeARoot = "A root is claimed over, never revoked"
    static let alreadyRevoked = "Already revoked"

    /// What Re-admit says, and what it is: the same door an admission goes
    /// through, pressed by the root that closed it.
    static let readmitHelp = "Let this device write in this book again"

    /// **What Rename says, and who may** (P2 smoke find 3). A label was chosen
    /// once — at the admission sheet, or by whatever a first root's Mac called
    /// itself — and a writer who mistyped it had no way back. It is the one
    /// verb here that changes no authority at all.
    ///
    /// **Two refusals, because the verb has two guards** (whole-branch review,
    /// Minor 1). The familiar one is the signature rule Revoke keeps: a person
    /// record is signed by the root it names, so only that root may re-sign it.
    /// The other is about this Mac rather than the row — a rename re-signs, and
    /// a Mac that holds no root record of its own here signs nothing any reader
    /// accepts, whoever the row belongs to. This pane asked only the first, so
    /// a Mac whose own root record had been deleted went on offering a live
    /// Rename on every row it had admitted, and the press threw.
    static let renameHelp = "Change the name this book calls them"
    static let renameNotMine =
        "Only the Mac that admitted this device can rename it"
    static let renameNotARoot =
        "This Mac holds no root record in this book, so nothing it signs would stand"

    /// **What Restore says** (P2 smoke find 1). The bytes this device kept when
    /// it last verified that record, put back over the one that will not. It is
    /// a press rather than something `reconcile` does on its own, because
    /// overwriting a signed record on shared storage is a decision, and a
    /// device cannot tell *tampered with* from *damaged in transit*.
    static let restoreHelp = "Put back the version this Mac last saw verify"

    /// And Retire, which is a device’s word about itself.
    static let retireHelp = "Say this Mac has stopped writing in this book"
    static let retireNotThisDevice = "A device retires itself"
    static let alreadyRetired = "Already retired"

    /// **Why Merge is refused** (whole-branch review, I2).
    ///
    /// A claim is signed by the root record making it, so a Mac that JOINED
    /// somebody else's root — arm 3, `ownRootRecord == nil` — has no root of
    /// its own to sign one with, and `RegistryAdmission.claim` refuses it.
    /// Drawn live, that button told the writer to merge by claiming the book
    /// immediately after they pressed the merge button, which reads as the app
    /// arguing with itself. Gated, the sentence is simply never reached from
    /// this surface.
    static let mergeNoRootOfMyOwn =
        "This Mac is on another root’s chain, so it has no root of its own to "
        + "merge with. Claim this book first."

    // MARK: - When a verb refuses

    /// **A refusal is `AdmissionDecision.sentence(for:)`'s** (the team lead's
    /// ruling, 2026-09-11). Revoke and Retire throw the same
    /// `RegistryAdmissionError` admission throws, and one enum with two
    /// vocabularies would have the same refusal read two ways depending on
    /// which surface the writer was standing in — with the arm nobody
    /// remembered to write twice falling back to an error domain. So this
    /// section has no sentences of its own; its host asks there.

    // MARK: - Rows

    /// A device whose writes this book is HOLDING — the only row that asks the
    /// writer for something, which is why they come first.
    struct PendingRequest: Equatable, Identifiable {
        /// The device record's fingerprint, or the seal key itself when no
        /// record on disk names it. It is what an Admit… is about.
        let fingerprint: String
        /// The device's own name, or its code when the book knows no name.
        let name: String
        /// The four characters the device shows on its own Settings screen —
        /// the whole of how an admission is checked.
        let code: String
        let heldLines: Int

        var id: String { fingerprint }

        var sentence: String {
            let held = heldLines == 1 ? "1 line" : "\(heldLines) lines"
            return "\(name) (\(code)) — \(held) waiting"
        }
    }

    /// One machine, as its own record describes it.
    struct Device: Equatable, Identifiable {
        let fingerprint: String
        let name: String
        /// *Mac*, *iPhone*, or whatever an unfamiliar record calls itself.
        let kind: String
        /// The actors this device holds, as words, in the order `DeviceActor`
        /// declares them. A count of keys would say nothing about what the
        /// machine may write.
        let actors: [String]
        let addedAt: Date
        let retiredAt: Date?
        let isThisMac: Bool
        /// **A device signs its own retirement** (spec §5), so this is true on
        /// exactly one row: this Mac's, and only while it has not already said
        /// so.
        let canRetire: Bool
        let whyNotRetirable: String?
        /// **What retirement means, on the machine that did it** (fix round 1,
        /// Important 2). Non-nil on this Mac's own retired row and nowhere
        /// else: a peer's retirement is a fact about a machine the writer is
        /// not sitting at, and *what it writes now stays on this Mac* would be
        /// a lie told about somebody else's desk. `DeviceStanding`'s own
        /// sentence, so History and this row cannot drift (tripwire 19).
        let retirementNotice: String?
        /// **When this Mac last put this record back** (P2b Task 10), from
        /// `RegistryCache.restores`. Non-nil means the folder had lost the
        /// record and this device restored it from its own memory — a fact
        /// nothing in the folder carries afterwards, because the file is back
        /// and looks untouched.
        let restoredAt: Date?

        var id: String { fingerprint }

        var detail: String {
            var parts = [kind]
            if !actors.isEmpty { parts.append(actors.joined(separator: ", ")) }
            parts.append("added \(PeopleAndDevicesModel.day(addedAt))")
            if let retiredAt {
                parts.append("retired \(PeopleAndDevicesModel.day(retiredAt))")
            }
            if let restoredAt {
                parts.append("put back \(PeopleAndDevicesModel.day(restoredAt))")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// One admitted person — under labels-only, one author key with a name the
    /// root gave it.
    struct Person: Equatable, Identifiable {
        let fingerprint: String
        let label: String
        /// The device's own name, when it differs from the label. A writer who
        /// called both machines "Denver" needs to know which is which before
        /// they revoke one.
        let ownName: String?
        let role: String
        let admittedAt: Date
        let revokedAt: Date?
        /// Whether THIS Mac may revoke them — it is the root that admitted
        /// them, they are not a root themselves, and they are not already
        /// revoked. Decided here rather than in the view, so the rule is
        /// assertable with nothing mounted.
        let canRevoke: Bool
        /// Why not, when not. The button is drawn either way (P2a's Admit…
        /// pattern) and says what would make it live.
        let whyNotRevocable: String?
        /// **Whether this Mac may change the word this book calls them** (P2
        /// smoke find 3): it is the root that admitted them — which a ROOT's
        /// own record says of itself, so a root may rename itself and may not
        /// rename another root.
        ///
        /// Unlike `offersRevoke` this keeps its button when it refuses, because
        /// the verb EXISTS for the row and is merely not this Mac's to press:
        /// somebody else's Mac can rename them, and *why can I not rename this*
        /// is a question an absent button answers with silence.
        let canRename: Bool
        /// Why not, when not.
        let whyNotRenamable: String?
        /// **Whether the row draws a Revoke control at all** (P2 smoke find 2).
        ///
        /// A refused verb normally keeps its button, disabled, with the reason
        /// in its tooltip — *why can I not revoke this* is a question an absent
        /// button answers with silence. A ROOT is the one exception, and it is
        /// an exception because the question never arises: a root is claimed
        /// over, never revoked (spec §5), so the control could not become live
        /// on any folder, on any day, for any writer. A disabled button is an
        /// offer with a condition on it; there is no condition here. On the row
        /// that is usually the writer's own Mac it was simply a dead control
        /// beside their own name.
        let offersRevoke: Bool
        /// **Whether this Mac may let them back in** (fix round 1, Important
        /// 3b): they are revoked, and this Mac is the root that revoked them.
        /// The inverse of a revocation is an admission by the same authority,
        /// so the row offers it where the row offered Revoke.
        let canReadmit: Bool
        /// The device's own name as the RECORD holds it — what a re-admission
        /// writes back. `ownName` above is nil when it matches the label, which
        /// is a drawing decision; this is the fact.
        let recordedOwnName: String
        /// *this Mac*, or *<label>'s Mac* for a root somebody else owns. Nil
        /// for everyone who is not the root of this book's chain.
        let mark: String?
        /// **When this Mac last put this record back** (P2b Task 10). See
        /// `Device.restoredAt`: the same fact, one directory over.
        let restoredAt: Date?
        let devices: [Device]

        var id: String { fingerprint }

        var title: String {
            guard let ownName else { return label }
            return "\(label) (\(ownName))"
        }

        var detail: String {
            var parts = [role]
            if let revokedAt {
                parts.append("revoked \(PeopleAndDevicesModel.day(revokedAt))")
            } else {
                parts.append("admitted \(PeopleAndDevicesModel.day(admittedAt))")
            }
            if let restoredAt {
                parts.append("put back \(PeopleAndDevicesModel.day(restoredAt))")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// A root this device has something to say about but nothing to nest under
    /// it: a claimant, an adopted chain, or a device this Mac remembers
    /// labelling whose record is no longer in the folder.
    struct Named: Equatable, Identifiable {
        let fingerprint: String
        let name: String
        let code: String

        var id: String { fingerprint }
    }

    /// **A record on disk this device cannot vouch for** (P2 smoke find 1).
    ///
    /// A malformed record is listed by the reader and contributes nothing to
    /// the registry — which is right, and which until now meant it appeared
    /// nowhere in the app at all. The consequences are loud and the cause was
    /// invisible: this Mac's own tampered root record made it read as *not yet
    /// admitted* on its own book, with nothing on any screen naming the file or
    /// saying what was wrong with it.
    ///
    /// It is named by the FILE, which is the one thing a malformed listing
    /// still says for certain (`MalformedRecord.ref`) — what the bytes CLAIM is
    /// exactly what cannot be trusted here.
    struct Unverifiable: Equatable, Identifiable {
        /// Which FILE this row is about. A `RecordRef` rather than a bare
        /// fingerprint because the same key can name a record in two
        /// directories, and Restore must put back the one the writer is
        /// looking at.
        let ref: RecordRef
        /// *person*, *device*, *claim* — the directory as a word, so the row
        /// says which of the three kinds of record this is without spelling a
        /// path (tripwire 40).
        let kind: String
        /// The best name this book still has for whoever the record is about:
        /// a verified record of theirs elsewhere, this Mac's own memory of a
        /// label, else the code. Never the malformed record's own words.
        let name: String
        let code: String
        /// Why it does not verify, in `MalformedRecord.Reason`'s own sentence —
        /// the reader's vocabulary, not a second one.
        let reason: String
        /// The record names THIS device. The row says so, because the header
        /// above it can only say what this device's standing IS and this is the
        /// reason for it.
        let isMine: Bool
        /// This device still holds the bytes that last verified, so Restore can
        /// put them back. False is a real and ordinary state — a record that
        /// never verified here was never remembered — and the row is listed
        /// either way, because naming the file is the whole point.
        let canRestore: Bool

        var fingerprint: String { ref.fingerprint }
        var id: String { "\(ref.directory.rawValue)-\(ref.fingerprint)" }

        var sentence: String {
            "The \(kind) record for \(name) (\(code)) \(reason)."
        }
    }

    /// A claimant row — a `Named` plus whether this Mac can actually answer it
    /// (whole-branch review, I2).
    ///
    /// Its own type rather than two more fields on `Named`, because merged and
    /// absent rows have no such question and a defaulted flag on a shared row
    /// is a claim about them that nobody made. The shape is `Person.canRevoke`
    /// and `Device.canRetire`'s, for their reason: a refused verb keeps its
    /// button, disabled, with the reason in the tooltip, because *why can I not
    /// merge this* is a question an absent button answers with silence.
    struct Claimant: Equatable, Identifiable {
        let root: Named
        /// Whether pressing Merge could write a claim at all.
        let canMerge: Bool
        /// Why not, when it could not. Nil exactly when `canMerge`.
        let whyNotMergeable: String?

        var id: String { root.fingerprint }
        var fingerprint: String { root.fingerprint }
        var name: String { root.name }
        var code: String { root.code }
    }

    // MARK: - The model

    /// The registry read's own sentence, when it refused. Everything else is
    /// empty in that case, deliberately.
    let refusal: String?
    /// What this device is to this book, in `DeviceStanding`'s one sentence —
    /// the same words the phone's Settings row shows, so the two screens can be
    /// compared (tripwire 19).
    let standing: String
    /// This device's own four-character code.
    let code: String
    let pending: [PendingRequest]
    let people: [Person]
    /// Roots this device's own root has adopted: listed as *merged*, because
    /// the writer has already answered the question a claimant asks.
    let merged: [Named]
    /// Roots that name this device without being the one it is on. Listed,
    /// never merged (B1). Each carries whether this Mac can answer it.
    let claimants: [Claimant]
    /// Devices this Mac remembers labelling whose record is not in the folder —
    /// the only thing left naming them, and **Forget this device** clears it.
    let absent: [Named]
    /// Records the folder holds that this device cannot vouch for (smoke find
    /// 1). Last, because everything above is a fact about who may write and
    /// this is a fact about a file.
    let unverifiable: [Unverifiable]

    // MARK: - Making it

    /// The rows for one project.
    ///
    /// - Parameters:
    ///   - registry: the verified records, as `TrustResolution` resolved them.
    ///   - table: the verdicts resolved from exactly that registry — a second
    ///     read here would let this section describe a device off a folder the
    ///     verdicts were not taken from.
    ///   - remembered: `AdmissionMemory`'s labels, by fingerprint.
    ///   - requests: who is waiting, as `AdmissionDecision.requests` decided —
    ///     the SAME list the admission sheet queues, built from the same held
    ///     counts. Two derivations of *who is a stranger with lines waiting*
    ///     would let this pane list a device the sheet never asks about, or
    ///     offer an Admit… about one it has already let in.
    ///   - claimants: `RegistryCache.claimants(for:)`.
    ///   - restores: `RegistryCache.restores(for:)` — the SAME dated list
    ///     History reads, so a record marked *put back* in a row and an event
    ///     saying so in the timeline are one fact rather than two derivations.
    ///   - restorable: the records whose last verified bytes this device still
    ///     holds (`RegistryCache.rawBytes(of:for:)`), asked of the cache by the
    ///     host and handed in as a value — this type reads no folder and no
    ///     shared memory, which is what lets every rule below be pinned.
    ///   - standing: this device's own sentence, and the carrier of a refusal.
    ///   - me: this device's author fingerprint.
    static func make(
        registry: Registry,
        table: TrustTable,
        remembered: [String: AdmissionMemory.Label],
        requests: [AdmissionRequest],
        claimants: [String],
        restores: [RestoredRecord] = [],
        restorable: Set<RecordRef> = [],
        standing: DeviceStanding,
        me: String
    ) -> PeopleAndDevicesModel {
        if let refusal = standing.refusal {
            return PeopleAndDevicesModel(
                refusal: refusal, standing: standing.sentence, code: standing.code,
                pending: [], people: [], merged: [], claimants: [], absent: [],
                unverifiable: [])
        }

        // The LATEST restoration of each record: a record put back twice is two
        // events in History, which is a timeline, and one mark on a row, which
        // is a state.
        var restoredAt: [RecordRef: Date] = [:]
        for restore in restores {
            if let known = restoredAt[restore.ref], known >= restore.restoredAt { continue }
            restoredAt[restore.ref] = restore.restoredAt
        }

        let deviceByFingerprint = Dictionary(
            registry.devices.map { ($0.device, $0) }, uniquingKeysWith: { first, _ in first })

        /// Whatever this book's VERIFIED records still call a fingerprint, or
        /// nil. Separate from `name` below because the unverifiable rows have a
        /// further fallback of their own (this Mac's memory of a label) before
        /// they give up and show the code.
        func knownName(_ fingerprint: String) -> String? {
            registry.person(fingerprint)?.label
                ?? deviceByFingerprint[fingerprint]?.name
        }

        func name(_ fingerprint: String) -> String {
            knownName(fingerprint) ?? DeviceCode.short(fingerprint)
        }

        func named(_ fingerprint: String) -> Named {
            Named(fingerprint: fingerprint, name: name(fingerprint),
                  code: DeviceCode.short(fingerprint))
        }

        // **Who is waiting is the admission sheet's own answer** (Task 7). The
        // membership rules — a device with no person record, a Mac with a chain
        // to judge by at all — are `AdmissionDecision.requests`'s, so admitting
        // somebody takes their row away here for the same reason it takes the
        // sheet down there, and neither surface can list a device the other
        // does not.
        //
        // The NAME is still this pane's: the inbox banner's rule, asked for
        // rather than repeated, so the two surfaces name one device one way.
        var pendingRows: [PendingRequest] = requests.map { request in
            PendingRequest(
                fingerprint: request.fingerprint,
                name: InboxByline.name(
                    forDevice: request.fingerprint, registry: registry),
                code: request.code,
                heldLines: request.waitingCount)
        }
        pendingRows.sort { left, right in
            left.heldLines == right.heldLines
                ? left.fingerprint < right.fingerprint
                : left.heldLines > right.heldLines
        }

        // Everyone on the chain this device judges by, and nobody else: a
        // person under another root is that root's business, and is listed —
        // if it concerns this device at all — as a claimant below.
        let members: Set<String> = table.myRoot.map { registry.chain(underRoot: $0) } ?? []
        var memberRecords: [PersonRecord] = registry.people.filter {
            members.contains($0.person)
        }
        memberRecords.sort { left, right in
            left.admittedAt == right.admittedAt
                ? left.label < right.label
                : left.admittedAt < right.admittedAt
        }
        let people: [Person] = memberRecords.map { record in
            person(record, in: registry, myRoot: table.myRoot,
                   restoredAt: restoredAt, me: me)
        }

        let adopted = Set(table.adoptedRoots)
        let merged: [Named] = table.adoptedRoots.map(named)
        // A claimant this device has ADOPTED is merged, not claiming: it has
        // been answered, and listing it in both places would ask the writer a
        // question they have already settled (Task 2's carry).
        // **Whether Merge can do anything is this Mac's state, not the row's**
        // (whole-branch review, I2) — but it is carried on the row, because
        // the row is what draws the button and a view deciding for itself
        // would be a second authority on a trust question. A Mac that joined
        // another root has no root record to sign a claim with, so every one
        // of these buttons can only refuse.
        let canMerge = table.ownRootRecord != nil
        let stillClaiming: [Claimant] = claimants
            .filter { !adopted.contains($0) }
            .sorted()
            .map { Claimant(root: named($0), canMerge: canMerge,
                            whyNotMergeable: canMerge ? nil : mergeNoRootOfMyOwn) }
        var absent: [Named] = []
        for fingerprint in remembered.keys.sorted() {
            guard registry.person(fingerprint) == nil,
                  deviceByFingerprint[fingerprint] == nil else { continue }
            absent.append(Named(
                fingerprint: fingerprint,
                name: remembered[fingerprint]?.label ?? DeviceCode.short(fingerprint),
                code: DeviceCode.short(fingerprint)))
        }

        // Named by the FILE. A malformed record contributes nothing, so the
        // name comes from whatever else this book still knows about that
        // fingerprint — a verified record of theirs, this Mac's own memory of a
        // label, else the code. Sorted by the row's own id, so a folder read in
        // another order lists the same way.
        let unverifiable: [Unverifiable] = registry.malformed
            .compactMap { fault -> Unverifiable? in
                guard let ref = fault.ref else { return nil }
                return Unverifiable(
                    ref: ref,
                    kind: word(for: ref.directory),
                    name: knownName(ref.fingerprint)
                        ?? remembered[ref.fingerprint]?.label
                        ?? DeviceCode.short(ref.fingerprint),
                    code: DeviceCode.short(ref.fingerprint),
                    reason: fault.reason.sentence,
                    isMine: ref.fingerprint == me,
                    canRestore: restorable.contains(ref))
            }
            .sorted { $0.id < $1.id }

        return PeopleAndDevicesModel(
            refusal: nil,
            standing: standing.sentence,
            code: standing.code,
            pending: pendingRows,
            people: people,
            merged: merged,
            claimants: stillClaiming,
            absent: absent,
            unverifiable: unverifiable)
    }

    /// One person's row, with the devices whose records name them nested under
    /// it. Under labels-only a person IS a device's author key, so that is at
    /// most one machine today; it is a list because the shape this milestone
    /// leaves room for is a person key with several.
    private static func person(
        _ record: PersonRecord, in registry: Registry, myRoot: String?,
        restoredAt: [RecordRef: Date], me: String
    ) -> Person {
        let devices: [Device] = registry.devices
            .filter { $0.device == record.person }
            .map { device in
                let isThisMac = device.device == me
                return Device(
                    fingerprint: device.device, name: device.name,
                    kind: word(for: device.kind), actors: actorWords(of: device),
                    addedAt: device.madeAt, retiredAt: device.retiredAt,
                    isThisMac: isThisMac,
                    // A device record is signed by the device it describes, so
                    // this is the only row where Retire could write anything a
                    // reader would accept (spec §5).
                    canRetire: isThisMac && device.retiredAt == nil,
                    whyNotRetirable: !isThisMac ? retireNotThisDevice
                        : device.retiredAt != nil ? alreadyRetired : nil,
                    retirementNotice: isThisMac
                        ? device.retiredAt.map {
                            DeviceStanding.retirementNotice(
                                device: word(for: device.kind), retiredAt: $0)
                        }
                        : nil,
                    restoredAt: restoredAt[RecordRef(
                        directory: .devices, fingerprint: device.device)])
            }
        return Person(
            fingerprint: record.person, label: record.label,
            ownName: record.ownName == record.label ? nil : record.ownName,
            role: record.role, admittedAt: record.admittedAt,
            revokedAt: record.revokedAt,
            canRevoke: revocable(record, me: me),
            whyNotRevocable: whyNotRevocable(record, me: me),
            canRename: whyNotRenamable(record, in: registry, me: me) == nil,
            whyNotRenamable: whyNotRenamable(record, in: registry, me: me),
            offersRevoke: !record.isRoot,
            // The inverse of a revocation, offered only by the authority that
            // performed it: `RegistryAdmission.admit` refuses anybody else's
            // record, so a button here would be a control that cannot act.
            canReadmit: record.isRevoked && !record.isRoot && record.admittedBy == me,
            recordedOwnName: record.ownName,
            mark: mark(for: record, myRoot: myRoot, me: me),
            restoredAt: restoredAt[RecordRef(
                directory: .people, fingerprint: record.person)],
            devices: devices)
    }

    /// **Only the root that admitted them, and only once** (spec §5). A person
    /// record is signed by the root it names as its admitter, so a Mac that is
    /// not that root would write a file every reader lists as malformed — a
    /// device un-admitted in silence rather than revoked. A root answers to
    /// itself and is claimed over, never revoked. And a second revocation would
    /// move the line the first one drew.
    private static func revocable(_ record: PersonRecord, me: String) -> Bool {
        whyNotRevocable(record, me: me) == nil
    }

    /// **The verb's own rule, asked of the verb** (whole-branch review, Minor
    /// 1). `RegistryAdmission.renameOutcome` is the one definition of who may
    /// rename whom; this turns its refusal into the register a disabled
    /// control speaks in.
    ///
    /// The rule is shared and only the WORDING is local, which is the same
    /// arrangement Revoke's tooltips keep: a refusal the writer reads after a
    /// press is `AdmissionDecision.sentence`'s, in admission's verbs, and a
    /// tooltip on a control that never fired wants a shorter sentence in the
    /// present tense.
    ///
    /// Only `.notARoot` earns a second sentence. Every other refusal — admitted
    /// by another root, no verified record, a record present and unreadable —
    /// amounts to the same thing from this row's point of view: not this Mac's
    /// to rename.
    private static func whyNotRenamable(
        _ record: PersonRecord, in registry: Registry, me: String
    ) -> String? {
        switch RegistryAdmission.renameOutcome(
            person: record.person, by: me, in: registry) {
        case .success: return nil
        case .failure(.notARoot): return renameNotARoot
        case .failure: return renameNotMine
        }
    }

    private static func whyNotRevocable(_ record: PersonRecord, me: String) -> String? {
        if record.isRoot { return revokeARoot }
        if record.isRevoked { return alreadyRevoked }
        if record.admittedBy != me { return revokeNotMine }
        return nil
    }

    /// *you* for the root that is this device, *<label>'s Mac* for a root
    /// somebody else owns, nothing for anyone who is not the root. Saying "this
    /// Mac" of a foreign root would be a lie about whose machine holds the book.
    ///
    /// **A person is not a machine** (P2 smoke find 2). This row used to be
    /// marked *this Mac*, and the device row nested directly under it carries
    /// that same badge — so one Mac read as two, above a header saying the
    /// machine's name a third time. The badge belongs on the device row, which
    /// is the row that IS a machine; what this row can say that no other row
    /// can is that the person on it is the writer reading it.
    private static func mark(
        for record: PersonRecord, myRoot: String?, me: String
    ) -> String? {
        guard record.person == myRoot else { return nil }
        return record.person == me ? "you" : "\(record.label)\u{2019}s Mac"
    }

    /// Which of the registry's three kinds of record a row is about, as a
    /// word. The enum rather than a path, so no surface spells `.maugham/people`
    /// (tripwire 40) and an unfamiliar directory a later build adds still reads
    /// as something.
    private static func word(for directory: RegistryDirectory) -> String {
        switch directory {
        case .people: return "person"
        case .devices: return "device"
        case .claims: return "claim"
        }
    }

    private static func word(for kind: DeviceKind) -> String {
        switch kind {
        case .mac: return "Mac"
        case .phone: return "iPhone"
        case .unknown(let raw): return raw
        }
    }

    /// The actors a device holds, in the order `DeviceActor` declares them,
    /// with anything an unfamiliar build named appended in its own order — a
    /// record is a wire format and a word this build does not know is still
    /// something the writer is owed.
    private static func actorWords(of device: DeviceRecord) -> [String] {
        let known = DeviceActor.allCases.map(\.rawValue)
        let held = Set(device.actors.keys)
        return known.filter(held.contains)
            + held.subtracting(known).sorted()
    }

    /// *9 Sep* — `DeviceStanding`'s own formatting, for its reason: a date a
    /// writer is reading off a settings row is the day it happened, never a
    /// timestamp.
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter
    }()
}
