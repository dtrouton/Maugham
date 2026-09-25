import Foundation
import MaughamCore

/// **Who may write in this book, on which devices, and what is waiting**
/// (signed op log P2, spec §6) — as a value.
///
/// The registry is four directories of signed records (P3a added the permit
/// events); the trust table turns
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
    static let mergeHelp = "Take everything that Mac wrote into this book"

    /// The sentence beside Merge, which says the thing a writer would
    /// otherwise assume: adopting is not switching. This device stays on its
    /// own chain and that Mac stays on its.
    static let mergeSentence =
        "This Mac will apply everything that Mac wrote. Each of you keeps the "
        + "book you started; neither becomes a copy of the other."

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
    /// **Where a device is removed, in the words the writer has** (Denver's
    /// wording ruling, 2026-09-18). It is a destination rather than a rule
    /// about signatures: the one fact a writer can hold is that a book is
    /// started on a Mac, and that Mac decides who is in it. The label is the
    /// starting Mac's own (the person record's `label`); with none known the
    /// sentence still says where to go.
    static func revokeNotMine(startedOn label: String?) -> String {
        guard let label else {
            return "Only the Mac this book was started on can remove a device"
        }
        return "Devices are removed on \(label), where this book was started"
    }
    static let revokeARoot = "The Mac a book was started on can’t be removed from it"

    /// What a question the writer has already put off says about itself, in
    /// the one place it is still offered (fix round 1, I3).
    ///
    /// A question they ANSWERED never reaches this row at all (fix round 3,
    /// minor 5) — it is over, and saying they put it off would tell them the
    /// opposite of what they did.
    static let pieceQuestionPutOff =
        "You put this off. It is still waiting — nothing has been written and "
        + "nothing has been set aside."
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
    /// `revokeNotMine`'s twin, and the same destination for the same reason.
    static func renameNotMine(startedOn label: String?) -> String {
        guard let label else {
            return "Names in this book are changed on the Mac it was started on"
        }
        return "Names in this book are changed on \(label), where it was started"
    }

    /// The second rename refusal the whole-branch review earned (M2): this Mac
    /// holds nothing in this book that would make a name it wrote stand. In the
    /// writer's words that is the same destination arrived at from the other
    /// side, and it keeps its own sentence because the reason differs.
    static let renameNotARoot =
        "This book wasn’t started on this Mac, so names here are changed there"

    /// **What Restore says** (P2 smoke find 1). The bytes this device kept when
    /// it last verified that record, put back over the one that will not. It is
    /// a press rather than something `reconcile` does on its own, because
    /// overwriting a signed record on shared storage is a decision, and a
    /// device cannot tell *tampered with* from *damaged in transit*.
    static let restoreHelp = "Put back the last version of this file this Mac could read"

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
        "This book wasn’t started on this Mac, so there is nothing here to merge "
        + "with. Claim the book on this Mac first."

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
        /// **What is waiting, and where** (P3b smoke find F2) — the admission
        /// sheet's own line (`AdmissionWaiting.line`), so this row and the
        /// sheet say one thing about one device. Nil draws the plain count.
        var described: String? = nil

        var id: String { fingerprint }

        var sentence: String {
            if let described { return "\(name) (\(code)) — \(described)" }
            // A device whose record arrived before any of its writing (F10) —
            // the sheet's own sentence, never *0 lines waiting*.
            if heldLines <= 0 { return "\(name) (\(code)) — \(AdmissionRequest.nothingYet)" }
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
        /// The device's own name in brackets, **only where no device row under
        /// this person already shows it** (Denver's re-smoke, 2026-09-19).
        ///
        /// It is here for the writer who called two machines "Denver" and needs
        /// to know which is which before revoking one. Under P2 a person IS one
        /// device, so that machine's row sits directly beneath carrying the same
        /// name — and the row then read *Denver Trouton (Denver's MacBook Air) ·
        /// you* above *Denver's MacBook Air · this Mac*, which is the same words
        /// twice in two lines. Nil where the nested rows say it; kept where they
        /// cannot, which is a person with no device record here at all, and the
        /// shape this milestone leaves room for: a person key with several
        /// machines, where the label alone would not say which one was admitted.
        let ownName: String?
        let role: String
        /// **What this record says they may write** (P3b Task 5, spec §7.2) —
        /// the record's own permit, which is the current-state convenience the
        /// registry keeps beside the history.
        ///
        /// Not the enforcement (tripwire 43): a line is judged by the permit
        /// its signer held when they wrote it, off the timeline. Where the two
        /// disagree the row says so and offers to correct it
        /// (`recordBehindHistory`), which is the one honest thing a surface can
        /// do about spec §3.2's crash window.
        let permit: Permit
        /// The rung the permit control would draw, or nil where no control can
        /// draw it: a role or scope word a later build invented. Nil is why the
        /// change control is refused rather than offering to overwrite a rung
        /// this Mac never showed.
        let rung: Permit.Rung?
        /// The pieces the permit names, as titles, in the binder's own order —
        /// an id no manifest here carries drawn as what it is rather than as a
        /// document id, which is not a thing a writer has ever seen.
        let pieceTitles: [String]
        /// Whether THIS Mac may change what they may write, by
        /// `RegistryAdmission.changePermitOutcome` — the verb's own rule, asked
        /// of the verb (`whyNotRenamable`'s arrangement, for its reason).
        let canChangePermit: Bool
        /// Why not, when not. The control is drawn either way EXCEPT on a root
        /// (`offersPermitChange`), which is the same exception Revoke keeps.
        let whyNotChangeable: String?
        /// **Whether the row draws a change control at all.** A root writes the
        /// whole book unconditionally (spec §2) and a book must not end up with
        /// no author, so the verb could not become live on any folder, on any
        /// day — a disabled button is an offer with a condition on it, and
        /// there is no condition here.
        let offersPermitChange: Bool
        /// **The record is a step behind this book's history**
        /// (`RegistryAdmission.recordBehindEvents`) — spec §3.2's crash window,
        /// which nothing refuses because nothing about what is APPLIED is
        /// wrong. Carries what the history says, so the row can state both.
        let historySays: Permit?
        /// Whether this Mac may write the record again from that history. The
        /// same authority a permit change needs, because re-signing the record
        /// is the second half of one.
        let canResign: Bool
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
        ///
        /// **The permit it would put back may still be one this build cannot
        /// draw** — that refusal is `whyNotReadmittable`'s, and the button is
        /// drawn either way.
        let canReadmit: Bool
        /// Why a Re-admit would be refused: the permit they held when they
        /// were shut out is one no control here can draw.
        ///
        /// **It is computed for every row, not only for the readmittable
        /// ones** (fix round 1, Minor 4), because it is a fact about their
        /// permit rather than about the authority — so a person who is not
        /// revoked at all can carry it. The gate is `canReadmit`: the section
        /// draws the button only there, and disables it on this. A surface
        /// that read this alone would refuse a verb it was never offering.
        let whyNotReadmittable: String?
        /// **The permit a Re-admit should propose** (Task 4's review, the
        /// Critical): the one they held when they were revoked, read off their
        /// `PermitTimeline` — a revocation installs no entry, so `current` is
        /// still the last permit anything installed. A P2-era person with no
        /// events answers author-of-the-whole-book, which is what re-admission
        /// has always meant for them.
        ///
        /// It is here rather than derived at the press because a re-admission
        /// that WIDENS must never happen in silence, and the only way to make
        /// that true is for the value the confirmation proposes to come from
        /// the same read the row was drawn from.
        let permitWhenRevoked: Permit
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

        /// **What they may write, in the writer's own words** — the rung's
        /// title, with the pieces where there are any. Drawn on the row, so the
        /// question the change control answers is visible before it is pressed.
        ///
        /// A rung this build cannot draw says so rather than guessing: the
        /// record carries a word a later Maugham wrote, and naming it *author*
        /// would be this Mac deciding something it does not know.
        ///
        /// The sentence is `PermitWords.sentence`, in Core, so the phone reads
        /// the same words (P3c plan 2, Task 1).
        var permitSentence: String {
            PermitWords.sentence(rung: rung, pieceTitles: pieceTitles)
        }

        /// **The record and the history disagree**, in one sentence naming both
        /// (spec §3.2). Nil when they agree, which is every person in every book
        /// written before P3.
        var behindHistorySentence: String? {
            guard let historySays else { return nil }
            let said = Permit.rung(of: historySays)?.title ?? "something else"
            return "This book\u{2019}s history says \(said.lowercased()), and it "
                + "is the history Maugham goes by. The file describing them is "
                + "a step behind it."
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
        /// **This Mac can write the record again** (audit PR #65's F4; P3b
        /// Task 5). True only where the record is this device's OWN, this Mac
        /// cannot Restore it, and — for a person record — there is no other
        /// verified root in this book whose decision it is.
        ///
        /// It is the last resort and never the first: Restore puts back a file
        /// this Mac read, and this writes a new one, so it is offered only
        /// where the first is impossible. `RegistryPresence.writeOwnRecordAgain`
        /// refuses all three ways itself; this decides what is DRAWN.
        let canWriteAgain: Bool
        /// Where nobody here can repair it, the Mac that can — so the row is
        /// never a dead end. Nil when `canRestore` or `canWriteAgain`.
        let whoRepairsIt: String?

        var fingerprint: String { ref.fingerprint }
        var id: String { "\(ref.directory.rawValue)-\(ref.fingerprint)" }

        var sentence: String {
            "The \(kind) record for \(name) (\(code)) \(reason)."
        }
    }

    /// **A stream in this book that nothing signs** (#8, spec §7.2; P3b Task 5).
    ///
    /// There is no device to admit, because there is no key: whatever wrote
    /// these files put no seal on them that any register can name. It is a row
    /// about a FILE rather than about a person, which is why it names a stream
    /// and never a code.
    ///
    /// **Its sentence is true in both of the two cases it covers**, which is
    /// the wording Task 2's review earned (M2). One is a Mac with no Secure
    /// Enclave — a VM, an old Intel machine — which signs nothing it will ever
    /// write. The other is a Mac that signs perfectly well whose FIRST seal has
    /// not synced into this folder yet, and which will stop being here the
    /// moment it does. This Mac cannot tell them apart and must not claim to:
    /// what it knows is that nothing this book holds says who signs for that
    /// stream, and that is what the row says.
    struct UnsignedStream: Equatable, Identifiable {
        /// The device slug the stream's files carry, or the stream key where
        /// there is no slug at all — `HeldLines.unsignedHolder`'s own choice,
        /// so a rotated segment and the tail it came out of are one row.
        let stream: String

        var id: String { stream }

        /// **What is true now**, in both cases above.
        var sentence: String {
            "Nothing this book holds says who signs for \u{201C}\(stream)\u{201D}."
        }

        /// **What narrowing will do to it, before there is a reviewer** — the
        /// half a writer must read BEFORE they create the first one, because
        /// the day they do is a cliff rather than a slope (the fix wave's
        /// *unsigned Mac's cliff*).
        static let beforeNarrowing =
            "While everyone in this book writes the whole of it, that changes "
            + "nothing: what this stream writes is applied everywhere, as it "
            + "always has been. The first time anyone here is anything less "
            + "than an author of the whole book, what it writes from then on "
            + "waits on the other Macs until it is sent to the Inbox \u{2014} "
            + "and nothing it has already written changes."

        /// And what narrowing HAS done, once it has.
        static let afterNarrowing =
            "Since this book first limited what somebody may write, what this "
            + "stream writes waits on the other Macs until it is sent to the "
            + "Inbox. Nothing it wrote before then changed."
    }

    /// **A held key that is nobody to ask about** (P3b Task 4's two never-offered
    /// classes, given the row Task 5 owes them).
    ///
    /// The admission sheet is silent about both on purpose — a sheet would
    /// offer a control that cannot help — and silence is only honest if
    /// something somewhere says why lines are waiting. That is this row.
    ///
    /// `AdmissionDecision.standing` is the one classification and this reads
    /// it; a reason derived twice is how one surface comes to say *waiting to
    /// be let in* about a holder the other calls contested.
    struct WaitingKey: Equatable, Identifiable {
        let fingerprint: String
        let code: String
        /// What is waiting, so the row is a fact with a size.
        let heldLines: Int
        /// Why it is not a question for the writer.
        let sentence: String

        var id: String { fingerprint }
    }

    /// **A piece somebody started that nobody has claimed** (spec §7.2, P3b
    /// Task 7 fix round 1, I3).
    ///
    /// The question a load puts in a sheet, and the place it waits when the
    /// writer says *Not now* — which is what the sheet's own copy promises,
    /// and until this row existed that promise pointed at nothing.
    ///
    /// It is the very `LoadQuestions.NewPiece` the sheet draws, carried rather
    /// than re-derived: a second derivation is how one surface comes to name a
    /// different count, a different title or a different person than the other
    /// about one question.
    ///
    /// **Questions already DECLINED are listed here too**, and only here: a
    /// decline silences the sheet for good, so a pane that also hid them would
    /// leave the writer no way back to a question they meant to answer later.
    struct PendingPiece: Equatable, Identifiable {
        let question: LoadQuestions.NewPiece
        /// Whether the writer has already put this one off. Drawn as a note,
        /// not as a reason to hide the row.
        let putOff: Bool

        var id: String { question.id }
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
    /// **This book was started on THIS Mac** (Denver's wording ruling,
    /// 2026-09-18). The header says so in `standing`, and the line beneath it
    /// says whose code follows — *Its code is 4FD2* reads right under *This book
    /// was started on this Mac* and wrong under *This book was started on
    /// Denver*, where "it" would be the other Mac.
    let startedOnThisMac: Bool
    let pending: [PendingRequest]
    /// Held keys that are nobody to ask about — a non-author actor key whose
    /// device record has not arrived, and a key two device records claim. They
    /// sit with `pending` because they are the same fact (something is waiting)
    /// with a different answer (nothing to press).
    let waiting: [WaitingKey]
    let people: [Person]
    /// §7.2's pending-piece questions, including the ones already put off.
    let pendingPieces: [PendingPiece]
    /// Streams in this book that answer to no key (#8). Drawn whether or not
    /// the book has been narrowed, with a different sentence for each.
    let unsigned: [UnsignedStream]
    /// Has anybody in this book already been given less than the whole of it?
    /// It decides which of `UnsignedStream`'s two sentences a row carries, and
    /// it is the FOLDER's answer (`TrustTable.hasNarrowingPermits`) rather than
    /// a guess from this Mac's own permit.
    let alreadyNarrowed: Bool
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
    ///   - held: every held-line count this window is holding, as
    ///     `DocumentStore.heldLines` counted them — the SAME map `requests`
    ///     was built from. It is taken as well as the requests because the
    ///     rows Task 5 owes are about the holders `requests` DECLINED, and a
    ///     second walk to find them would be a second opinion about who is
    ///     waiting.
    ///   - heldStreams: the slugs each holder was held under, the union's
    ///     second half. `AdmissionDecision.standing` needs them to tell a
    ///     non-author actor key from a person's.
    ///   - unsignedStreams: streams this book holds that answer to no key, as
    ///     `OpLogStore.unattributablePositions` swept them — a fact about
    ///     FILES, never about this Mac's own enclave, because the Mac that
    ///     signs nothing is usually somebody else's.
    ///   - pieces: the book's manuscript documents, for drawing a permit's
    ///     piece list as titles.
    static func make(
        registry: Registry,
        table: TrustTable,
        remembered: [String: AdmissionMemory.Label],
        requests: [AdmissionRequest],
        claimants: [String],
        restores: [RestoredRecord] = [],
        restorable: Set<RecordRef> = [],
        standing: DeviceStanding,
        me: String,
        held: [String: Int] = [:],
        heldStreams: [String: Set<String>] = [:],
        unsignedStreams: [String] = [],
        pieces: [PermitControl.Piece] = [],
        heldPieceStarts: [String: [String: Int]] = [:],
        heldWaiting: [String: [String: HeldLines.Waiting]] = [:],
        heldCaptures: [String: Int] = [:],
        declinedPieces: Set<OpLogDeviceState.DeclinedPiece> = [],
        settledPieces: Set<OpLogDeviceState.DeclinedPiece> = []
    ) -> PeopleAndDevicesModel {
        if let refusal = standing.refusal {
            return PeopleAndDevicesModel(
                refusal: refusal, standing: standing.sentence, code: standing.code,
                startedOnThisMac: standing.isRoot,
                pending: [], waiting: [], people: [], pendingPieces: [],
                unsigned: [],
                alreadyNarrowed: false,
                merged: [], claimants: [], absent: [],
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
                heldLines: request.waitingCount,
                described: AdmissionWaiting.describe(
                    holder: request.fingerprint, waiting: heldWaiting,
                    captures: heldCaptures,
                    order: pieces.map { (id: $0.id, title: $0.title) })?.line)
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
                   restoredAt: restoredAt, me: me, pieces: pieces)
        }

        // **§7.2's pending-piece questions** (fix round 1, I3) — the very
        // values the sheet draws, from the one model, so the pane cannot name
        // a different count or a different piece than the dialog did. The
        // DECLINED ones are here and nowhere else: a decline silences the
        // sheet for good, and a pane that also hid them would leave the writer
        // with no way back to a question they meant to answer later.
        var pieceTitleById: [String: String] = [:]
        for piece in pieces { pieceTitleById[piece.id] = piece.title }
        // **SETTLED questions are not drawn; DECLINED ones are** (fix round
        // 3, minor 5). The two are different facts and the row says which:
        // a question the writer ANSWERED is over — drawing it under *You put
        // this off* tells them the opposite of what they did — while one they
        // put off is still theirs to come back to, and this is the only
        // surface that offers it.
        let asked = LoadQuestions.newPieces(
            held: HeldLineUnion(
                counts: held, startedAPiece: heldPieceStarts, waiting: heldWaiting),
            registry: registry, titles: pieceTitleById,
            declined: settledPieces, me: me)
        let pendingPieces: [PendingPiece] = asked.map { question in
            PendingPiece(
                question: question,
                putOff: declinedPieces.contains(
                    .init(person: question.person, docId: question.docId)))
        }

        // **The holders `requests` DECLINED** (P3b Task 4's two never-offered
        // classes). The classification is `AdmissionDecision.standing`'s and is
        // asked, never re-derived — a reason worked out twice is how one
        // surface comes to say *waiting to be let in* about a holder the other
        // calls contested. The unsigned and permit-pending arms belong to Task
        // 7's sentences and get no row here.
        let offered = Set(requests.map(\.fingerprint))
        let waiting: [WaitingKey] = held.keys.sorted().compactMap { holder in
            guard let count = held[holder], count > 0,
                  !offered.contains(holder) else { return nil }
            let sentence: String
            switch AdmissionDecision.standing(
                ofHolder: holder, streams: heldStreams[holder] ?? [],
                registry: registry) {
            case .waitingForItsDeviceRecord(let actor):
                sentence = waitingForADeviceRecord(actor: actor)
            case .contested:
                sentence = contestedKey
            case .aStrangerToAskAbout, .notAStranger:
                return nil
            }
            return WaitingKey(
                fingerprint: holder, code: DeviceCode.short(holder),
                heldLines: count, sentence: sentence)
        }

        let unsigned: [UnsignedStream] = unsignedStreams.sorted()
            .map(UnsignedStream.init(stream:))

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
                    canRestore: restorable.contains(ref),
                    // **F4: the last resort, and never the first.** Restore
                    // puts back bytes this Mac read; this writes a new record,
                    // so it is offered only where there are no bytes to put
                    // back and where the record is this device's own. The
                    // person arm is narrower for the reason
                    // `RegistryPresence.writeOwnRecordAgain` refuses on: a
                    // person record written self-signed makes this Mac a root,
                    // and where the book still has a verified root that would
                    // be a second root made out of a damaged file.
                    canWriteAgain: canWriteAgain(
                        ref, registry: registry, me: me,
                        restorable: restorable),
                    whoRepairsIt: restorable.contains(ref)
                        || canWriteAgain(ref, registry: registry, me: me,
                                         restorable: restorable)
                        ? nil
                        : whoRepairsIt(ref, registry: registry, me: me))
            }
            .sorted { $0.id < $1.id }

        return PeopleAndDevicesModel(
            refusal: nil,
            standing: standing.sentence,
            code: standing.code,
            startedOnThisMac: standing.isRoot,
            pending: pendingRows,
            waiting: waiting,
            people: people,
            pendingPieces: pendingPieces,
            unsigned: unsigned,
            alreadyNarrowed: table.hasNarrowingPermits,
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
        restoredAt: [RecordRef: Date], me: String,
        pieces: [PermitControl.Piece]
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
        // **What the RECORD says** (the current-state convenience), and what
        // the HISTORY says (what every reader in this book is actually going
        // by). They agree for everybody in every book written before P3, and
        // where they do not the row says so — spec §3.2's crash window is the
        // one thing a surface can honestly do about a state nothing refuses.
        let permit = Permit.permit(recordedIn: record)
        let timeline = PermitTimeline(about: record.person, in: registry)
        let behind = RegistryAdmission.recordBehindEvents(
            person: record.person, in: registry)
        let changeRefusal = whyNotChangeable(record, in: registry, me: me)
        return Person(
            fingerprint: record.person, label: record.label,
            ownName: bracketedOwnName(of: record, beside: devices),
            role: record.role,
            permit: permit,
            rung: PermitControl.choice(displaying: permit),
            pieceTitles: titles(
                of: PermitControl.pieces(displaying: permit), among: pieces),
            canChangePermit: changeRefusal == nil,
            whyNotChangeable: changeRefusal,
            // A root writes the whole book unconditionally and a book must not
            // end up with no author, so this control could not become live on
            // any folder, on any day — Revoke's own exception, for its reason.
            offersPermitChange: !record.isRoot,
            historySays: behind ? timeline.current : nil,
            canResign: behind && changeRefusal == nil,
            admittedAt: record.admittedAt,
            revokedAt: record.revokedAt,
            canRevoke: revocable(record, in: registry, me: me),
            whyNotRevocable: whyNotRevocable(record, in: registry, me: me),
            canRename: whyNotRenamable(record, in: registry, me: me) == nil,
            whyNotRenamable: whyNotRenamable(record, in: registry, me: me),
            offersRevoke: !record.isRoot,
            // The inverse of a revocation, offered only by the authority that
            // performed it: `RegistryAdmission.admit` refuses anybody else's
            // record, so a button here would be a control that cannot act.
            canReadmit: record.isRevoked && !record.isRoot && record.admittedBy == me,
            // **And why it is refused when it is drawn** (Task 5's ruling,
            // built in Task 6): the authority is this Mac's and the permit is
            // still one this build cannot put back. The button is kept and
            // disabled, in the register Rename and Change use.
            whyNotReadmittable: whyNotReadmittable(timeline.current),
            // **What a Re-admit would put back** (Task 4's review, Critical).
            // The permit she held when she was revoked, which is the
            // timeline's `current` — a revocation installs no entry, so the
            // last thing that did is still the last word. A P2-era person with
            // no events answers author-of-the-whole-book, exactly as before.
            // Re-admitting must never WIDEN in silence, which is what a bare
            // `admit` did: its role/scope/pieces default to the whole book and
            // a revoked record takes them from the caller.
            permitWhenRevoked: timeline.current,
            recordedOwnName: record.ownName,
            mark: mark(for: record, myRoot: myRoot, me: me),
            restoredAt: restoredAt[RecordRef(
                directory: .people, fingerprint: record.person)],
            devices: devices)
    }

    /// **The bracketed name, and when it says anything** (Denver's re-smoke,
    /// 2026-09-19).
    ///
    /// Two ways of saying nothing, and both are dropped. A name equal to the
    /// label reads *Denver (Denver)*; a name a device row directly beneath
    /// already carries reads as the same words twice in two lines, which under
    /// P2 — where a person is exactly one device — is every ordinary row.
    ///
    /// Asked of the DEVICE ROWS this person was built with rather than of the
    /// registry, because the question is about what the writer can see: a
    /// device record that exists but is not drawn here would still leave the
    /// label alone on screen.
    private static func bracketedOwnName(
        of record: PersonRecord, beside devices: [Device]
    ) -> String? {
        guard record.ownName != record.label,
              !devices.contains(where: { $0.name == record.ownName }),
              // **C2: a nameless device never shows its code as its own name**
              // (P3b Task 5, spec §7.2). A device that reached the admission
              // sheet with no record of its own proposes no `ownName`, and the
              // sheet writes the code in its place — so the row read *Denver
              // (4FD2)*, which is the writer's own label next to a checksum
              // presented as the machine's name. The code is already on the
              // row in its own right; a third way of saying it is the code
              // pretending to be something it is not.
              record.ownName != DeviceCode.short(record.person)
        else { return nil }
        return record.ownName
    }

    /// **Only the root that admitted them, and only once** (spec §5). A person
    /// record is signed by the root it names as its admitter, so a Mac that is
    /// not that root would write a file every reader lists as malformed — a
    /// device un-admitted in silence rather than revoked. A root answers to
    /// itself and is claimed over, never revoked. And a second revocation would
    /// move the line the first one drew.
    private static func revocable(
        _ record: PersonRecord, in registry: Registry, me: String
    ) -> Bool {
        whyNotRevocable(record, in: registry, me: me) == nil
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
        case .failure:
            return renameNotMine(startedOn: startingMac(of: record, in: registry, me: me))
        }
    }

    /// **The verb's own rule, asked of the verb** — `whyNotRenamable`'s
    /// arrangement for `changePermit`, because the two refuse for four of the
    /// same reasons and this pane must not spell any of them twice.
    ///
    /// `RegistryAdmission.changePermitOutcome` is the one definition of who may
    /// change whose permit. Only the root arm earns a sentence of its own;
    /// every other refusal amounts to *not this Mac's to change*, which is the
    /// same destination Rename names.
    private static func whyNotChangeable(
        _ record: PersonRecord, in registry: Registry, me: String
    ) -> String? {
        switch RegistryAdmission.changePermitOutcome(
            person: record.person, by: me, in: registry) {
        case .success:
            // A record that DOES read but says something this build cannot
            // draw is a fifth refusal, and it is this surface's own rather
            // than the verb's: the verb would happily overwrite it, and a
            // control offering to replace a rung the writer was never shown is
            // the thing that must not be drawn.
            guard PermitControl.choice(
                displaying: Permit.permit(recordedIn: record)) != nil
            else { return permitThisBuildCannotDraw }
            return nil
        case .failure(.cannotChangeARoot): return changeARoot
        case .failure:
            return changeNotMine(startedOn: startingMac(of: record, in: registry, me: me))
        }
    }

    /// The root's own refusal, in the register the disabled tooltips use.
    static let changeARoot =
        "The Mac a book was started on writes the whole of it"
    /// `revokeNotMine`'s twin, and the same destination for the same reason.
    static func changeNotMine(startedOn label: String?) -> String {
        guard let label else {
            return "What a device may write is changed on the Mac this book was started on"
        }
        return "What a device may write is changed on \(label), where this book was started"
    }
    /// What Change… says when it is offered.
    static let changeHelp = "Change what this device may write in this book"
    /// **Re-admitting a permit no control can draw** (Task 5's ruling, built
    /// in Task 6) — the same stop as Change…, one verb over.
    ///
    /// A re-admission installs a permit: `RegistryAdmission.admit` writes
    /// whatever it is given over a revoked record. So a build that cannot draw
    /// the permit they held when they were shut out cannot offer to put it
    /// back — and it must not fall back to the whole book after a message,
    /// which is a WIDENING chosen by the build that understands least. The
    /// newer Maugham that wrote that rung is where they are let back in.
    private static func whyNotReadmittable(_ permit: Permit) -> String? {
        PermitControl.choice(displaying: permit) == nil
            ? permitThisBuildCannotReinstall : nil
    }

    /// Its sentence — `permitThisBuildCannotDraw`'s twin, in the register of
    /// the verb it refuses.
    static let permitThisBuildCannotReinstall =
        "A newer version of Maugham set what they may write. Let them back in "
        + "there, so this Mac doesn\u{2019}t put back something it can\u{2019}t "
        + "show you."

    /// **A permit no control can draw** — a role or scope word a later Maugham
    /// wrote. The control is refused rather than shown pre-filled with a rung
    /// this Mac invented, because pressing it would overwrite a permit the
    /// writer was never shown (`PermitControl.choice(displaying:)` answering
    /// nil is the one place that is decided).
    static let permitThisBuildCannotDraw =
        "A newer version of Maugham set what they may write. Change it there, "
        + "so this Mac doesn\u{2019}t overwrite something it can\u{2019}t show you."

    /// What Re-sign says, and what it is not: it moves nothing about what is
    /// applied, because the history is what the book has been going by.
    static let resignHelp = "Write the record again so it agrees with this book’s history"

    /// **A held key that is one of a device's other three writers** (P3b Task 4
    /// / Task 5). Silent in the sheet by design; this is the line that says why.
    ///
    /// The actor is named in the app's own vocabulary — *the assistant*, never
    /// a product name — and the sentence says what is waited FOR, because it
    /// resolves itself the moment that device's record syncs in.
    static func waitingForADeviceRecord(actor: DeviceActor) -> String {
        "\(actorWord(actor)) on a Mac this book hasn\u{2019}t been introduced "
        + "to yet. There is no person here to let in \u{2014} the machine\u{2019}s "
        + "own record has to arrive first, and then its writer is asked about."
    }

    /// **Two device records claim one key** (`Registry.isContestedActorKey`).
    /// Nobody's, for good: naming one owner would decide the thing the dispute
    /// rule refuses to decide, and there is no person to admit.
    static let contestedKey =
        "Two devices in this book say this key is theirs, so Maugham can\u{2019}t "
        + "tell whose writing this is. It waits until one of them stops "
        + "claiming it."

    /// The app's word for each writer a device holds. *The assistant*, never a
    /// product name (P3's standing instruction).
    private static func actorWord(_ actor: DeviceActor) -> String {
        switch actor {
        case .author: return "Somebody\u{2019}s own hand"
        case .assistant: return "The assistant"
        case .translator: return "The translation pipeline"
        case .maugham: return "Maugham itself"
        }
    }

    /// **Can this Mac write this record again?** (audit F4.) Three conditions,
    /// and the third is the person arm's alone.
    private static func canWriteAgain(
        _ ref: RecordRef, registry: Registry, me: String,
        restorable: Set<RecordRef>
    ) -> Bool {
        guard ref.fingerprint == me, !restorable.contains(ref) else { return false }
        switch ref.directory {
        case .devices: return true
        case .people: return !registry.roots.contains { $0.person != me }
        case .claims, .events: return false
        }
    }

    /// **Where a record nobody here can repair is repaired** — so the row is
    /// never a dead end. The Mac it is ABOUT for a device record, the Mac that
    /// signed it for a person record.
    private static func whoRepairsIt(
        _ ref: RecordRef, registry: Registry, me: String
    ) -> String? {
        if ref.fingerprint != me {
            return "The Mac this is about is the only one that can write it "
                + "again. Open this book there."
        }
        switch ref.directory {
        case .people:
            guard let root = registry.roots.first(where: { $0.person != me })
            else { return nil }
            return "This book was started on \(root.label), and that Mac decides "
                + "who is in it. Open the book there to put this record back."
        case .devices, .claims, .events:
            return nil
        }
    }

    /// The titles of the pieces a permit names, in the binder's own order, with
    /// an id this manifest does not carry drawn as what it is. The rule is
    /// Core's `PermitWords.pieceTitles`, so the phone's Settings names the same
    /// pieces the same way (P3c plan 2, Task 6; tripwire 19).
    private static func titles(
        of chosen: Set<String>, among pieces: [PermitControl.Piece]
    ) -> [String] {
        PermitWords.pieceTitles(
            of: chosen, among: pieces.map { (id: $0.id, title: $0.title) },
            unknownPiece: unknownPiece)
    }

    /// What a piece id this Mac cannot find is called on a row.
    static let unknownPiece = "a piece this Mac can\u{2019}t find"

    private static func whyNotRevocable(
        _ record: PersonRecord, in registry: Registry, me: String
    ) -> String? {
        if record.isRoot { return revokeARoot }
        if record.isRevoked { return alreadyRevoked }
        if record.admittedBy != me {
            return revokeNotMine(startedOn: startingMac(of: record, in: registry, me: me))
        }
        return nil
    }

    /// **The Mac this row's name and membership are decided on**, as a word the
    /// writer can act on — the label of the person record that admitted them,
    /// which under labels-only IS the Mac the book was started on.
    ///
    /// Nil where naming one would tell the writer nothing: this Mac is the
    /// admitter (so the destination is where they already are, and the refusal
    /// is about something else), or the book holds no record for the admitter
    /// at all. Both fall back to the sentence that names no Mac.
    private static func startingMac(
        of record: PersonRecord, in registry: Registry, me: String
    ) -> String? {
        guard record.admittedBy != me else { return nil }
        return registry.person(record.admittedBy)?.label
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

    /// Which of the registry's kinds of record a row is about, as a word —
    /// count `RegistryDirectory`'s cases, not this comment. The enum rather
    /// than a path, so no surface spells `.maugham/people`
    /// (tripwire 40) and an unfamiliar directory a later build adds still reads
    /// as something.
    private static func word(for directory: RegistryDirectory) -> String {
        switch directory {
        case .people: return "person"
        case .devices: return "device"
        case .claims: return "claim"
        case .events: return "permit event"
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
