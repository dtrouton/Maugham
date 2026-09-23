// Maugham/Views/PeopleAndDevicesConfirmation.swift
import Foundation
import MaughamCore

/// **What the writer is asked before an act there is no way back from**
/// (signed op log P2b Task 7, fix round 1, Important 3a).
///
/// Revoke and Retire are one click and, today, one direction: a revocation can
/// be undone only by the root re-admitting, and a retirement cannot be undone
/// at all. Both sit on a row beside the control the writer presses to rename a
/// device. So each is confirmed first, and the confirmation carries the
/// CONSEQUENCE rather than a restatement of the verb — *are you sure* tells a
/// writer nothing they did not know when they pressed.
///
/// **Merge is the third** (Task 8), for the same reason from the other
/// direction: it is not destructive, it is ADMITTING — a whole chain of
/// somebody's devices begins applying in this book at once — and there is no
/// un-adopt verb anywhere in this milestone.
///
/// **A value, not a sheet.** Everything on the alert is decided here and
/// compared in a test with nothing mounted (tripwire 33: no test presses a
/// mounted control and waits for its effect). The host presents it and calls
/// the verb when the writer confirms; this type never acts.
struct PeopleAndDevicesConfirmation: Identifiable, Equatable {

    /// Which act is being confirmed. The host switches on it to call the verb,
    /// so a further act is a compile error there rather than a silent no-op.
    enum Verb: String, Equatable {
        case revoke
        case retire
        case merge
        case rename
        case restore
        /// **Change what somebody may write** (P3b Task 5, spec §7.2). The one
        /// verb here whose message is a function of two values rather than of
        /// a name: what they hold now, and what they would hold.
        case changePermit
        /// **Bring a record up to the history it is a step behind** (spec
        /// §3.2's crash window). It writes a record and no event, so it moves
        /// nothing about what is applied — it makes the screen say what the
        /// book is already enforcing.
        case resign
        /// **Write this Mac's own record again**, over one the reader refuses
        /// and this device holds no earlier bytes for (audit F4).
        case writeOwnRecord
    }

    /// **The one thing the writer types** (P2 smoke find 3).
    ///
    /// Revoke, Retire and Merge need a yes; a rename needs a word, and the word
    /// is the whole act. It is carried here rather than kept in the host's own
    /// `@State` beside the confirmation, so *what the writer is asked, and what
    /// the field starts with* is part of the value a test compares with nothing
    /// mounted — the same reason everything else on the alert is.
    struct Field: Equatable {
        let prompt: String
        let initialValue: String
    }

    let verb: Verb
    /// The person (Revoke) or the device (Retire) the act is about. Under
    /// labels-only these are the same key and are still not the same argument.
    let fingerprint: String
    /// **Which FILE the act is about**, for the one verb that is about a file
    /// rather than a person (Restore, P2 smoke find 1). A fingerprint is half
    /// of a record — the same key can name a person record and a device record,
    /// and putting back the wrong one is putting back a record nobody asked
    /// for. Nil for every other verb, which are all about a key.
    let record: RecordRef?
    let title: String
    /// The consequence, in the words the surface uses for it afterwards.
    let message: String
    let confirmTitle: String
    /// What the writer types, for the one act that is about a word. Nil for
    /// every verb that only needs a yes.
    let field: Field?
    /// **What this act would install**, for the one verb that installs a permit
    /// (P3b Task 5). Nil for every other, because a yes about a name or a file
    /// is not a permit and a defaulted one would be a rung nobody chose.
    let permit: Permit?
    /// **The second way to perform the same act**, where there are two. Nil for
    /// every verb with one.
    let alternate: Alternate?

    /// A second button on the same alert, for an act the writer has two honest
    /// ways to perform (find 5, ruled 2026-09-18).
    ///
    /// It carries its own sentence because the whole point is that the two
    /// costs are different — offering *Revoke* and *Revoke everything* with one
    /// shared message would be asking the writer to choose between two things
    /// they have been told the same thing about.
    struct Alternate: Equatable {
        let title: String
        /// What THIS choice costs. The default's cost is in `message`.
        let message: String
        /// How much of that device's history the alternate takes back. The
        /// primary button always performs the default, `.whatWasApplied`.
        let scope: RevocationScope
    }

    /// **Everything the alert says, in one string** (find 5).
    ///
    /// An alert carries one message and the writer may be choosing between two
    /// consequences, so the alternate's sentence is appended rather than left
    /// on a button nobody has pressed yet. Here rather than in the host so the
    /// words are comparable with nothing mounted, like the rest of this type.
    static func alertMessage(for confirmation: Self) -> String {
        guard let alternate = confirmation.alternate else { return confirmation.message }
        return confirmation.message + "\n\n" + alternate.message
    }

    /// Keyed on the verb AND the subject, so a writer who dismisses one and
    /// opens another gets a new alert rather than the old one's identity — and
    /// on the DIRECTORY too where there is one, because one fingerprint can
    /// name a record in two of them.
    var id: String {
        guard let record else { return "\(verb.rawValue)-\(fingerprint)" }
        return "\(verb.rawValue)-\(record.directory.rawValue)-\(fingerprint)"
    }

    /// **Revoke**, carrying spec §5's own sentence — the one that says what
    /// Maugham will stop doing and what it cannot do — and the writer's two
    /// ways of doing it (find 5, ruled 2026-09-18).
    ///
    /// **The default leaves the draft as the writer has read it.** Everything
    /// this Mac had already applied from that device stays in the book; only
    /// what arrives afterwards is set aside. That is the ordinary case — a
    /// collaborator who has left, a machine being retired — and taking their
    /// paragraphs back out of chapters the writer has since redrafted would be
    /// a rewrite nobody asked for.
    ///
    /// **The alternate is the whole history**, which is what a revocation did
    /// before the ruling, and it stays available because it is sometimes the
    /// right answer: a machine that was never theirs, or one they no longer
    /// want a word from. It says what it costs in the sentence rather than in
    /// the button, because the button has room for a verb and this needs a
    /// consequence.
    static func revoke(person fingerprint: String, named name: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .revoke,
            fingerprint: fingerprint,
            record: nil,
            title: "Stop applying what \(name) writes?",
            message: PeopleAndDevicesModel.revokeSentence
                + " What they have already written stays in this book. "
                + "You can let them back in from this Mac.",
            confirmTitle: "Revoke",
            field: nil,
            permit: nil,
            alternate: Alternate(
                title: "Revoke and Set Aside Everything",
                message: "Every paragraph and note from \(name) leaves this book "
                    + "until you let them back in. Nothing is deleted \u{2014} it is "
                    + "kept in this project\u{2019}s set-aside records.",
                scope: .nothing))
    }

    /// **Merge**, carrying the consequence in the words the row uses for it
    /// afterwards: what this Mac will start applying, and the thing a writer
    /// might otherwise assume it means — that one of the two roots gives way.
    /// Neither does (B1).
    static func merge(root fingerprint: String, named name: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .merge,
            fingerprint: fingerprint,
            record: nil,
            title: "Is \(name) also you?",
            message: PeopleAndDevicesModel.mergeSentence,
            confirmTitle: "Merge",
            field: nil,
            permit: nil,
            alternate: nil)
    }

    /// **Retire**, carrying `DeviceStanding`'s own consequence — the same
    /// clause the standing notice uses afterwards, in the future tense, plus
    /// the fact that there is no way back.
    static func retire(device fingerprint: String, named name: String,
                       kind: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .retire,
            fingerprint: fingerprint,
            record: nil,
            title: "Retire \(name)?",
            message: DeviceStanding.retirementConsequence(device: kind),
            confirmTitle: "Retire",
            field: nil,
            permit: nil,
            alternate: nil)
    }

    /// **Rename**, the fourth and the only one that asks for a word rather than
    /// a yes (P2 smoke find 3).
    ///
    /// It is confirmed like the other three, for the opposite reason: not
    /// because it cannot be undone — it is the one act here that can, by
    /// renaming again — but because it is the one that needs something typed,
    /// and the message is where a writer learns what a label is and is not
    /// before they change one. A rename admits nobody and shuts nobody out.
    ///
    /// The field starts at the name that stands, so the ordinary edit is a
    /// correction rather than a re-typing, and Cancel and an untouched field
    /// come to the same thing.
    static func rename(person fingerprint: String, named name: String,
                       currently label: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .rename,
            fingerprint: fingerprint,
            record: nil,
            title: "What should this book call \(name)?",
            message: "A name is this book's word for them — every Mac that reads "
                + "this book will see it. Changing it admits nobody and shuts "
                + "nobody out.",
            confirmTitle: "Rename",
            field: Field(prompt: "Name", initialValue: label),
            permit: nil,
            alternate: nil)
    }

    /// **Restore**, the fifth, and the only one that writes over a file
    /// somebody else signed (P2 smoke find 1).
    ///
    /// It is confirmed because that is a decision, and because the writer is
    /// about to replace bytes Maugham has just told them do not verify. The
    /// message says what putting a record back is — the version this device saw
    /// verify, not a version it wrote — and what it is not: it forges nothing
    /// and admits nobody, because the next read checks the signature on it like
    /// any other.
    static func restore(record: RecordRef, named name: String, kind: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .restore,
            fingerprint: record.fingerprint,
            record: record,
            title: "Put back the \(kind) record for \(name)?",
            message: "This writes back the exact version this Mac last read, over "
                + "the one it can\u{2019}t. It adds nothing of this Mac\u{2019}s and "
                + "admits nobody \u{2014} the next read checks it like any other.",
            confirmTitle: "Restore",
            field: nil,
            permit: nil,
            alternate: nil)
    }

    // MARK: - Changing what somebody may write (P3b Task 5, spec §5 and §7.2)

    /// **What a permit change does to one book, in both directions** — the
    /// value the sentence is a pure function of.
    ///
    /// The two directions are spec §5's own two rows, and they are read off the
    /// PERMIT LAYER rather than restated here: for every piece the book has,
    /// `Permit.authors(_:)` is asked of the old permit and of the new one, and
    /// the pieces where the two answers differ are the change. Nothing here
    /// compares a rung (tripwire 47) or names a wire word (tripwire 44); there
    /// is no second permission table, because there is no table — there is one
    /// question asked twice per piece.
    ///
    /// **Every transition decomposes into those two sets, and that is why §5's
    /// two rows cover all of them.** The ladder is ordered — a reviewer may
    /// write nothing in the manuscript, an author of some pieces may write in
    /// hers, an author of the whole book may write anywhere — so a change from
    /// any rung to any other is *these pieces left* and/or *these pieces
    /// joined*, including the one transition the table does not spell out
    /// (one piece list becoming another, where both happen at once). The
    /// sentence states whichever halves are non-empty and never invents a
    /// third.
    ///
    /// The piece list is the manifest's, UNIONED with any id either permit
    /// names, so a scope holding a document this Mac has not synced is still
    /// counted and drawn as what it is.
    struct PermitChange: Equatable {
        /// The book's manuscript documents, in the binder's own order.
        let pieces: [PermitControl.Piece]
        /// What they hold now — the record's permit, which is what the row drew.
        let from: Permit
        /// What the writer has chosen.
        let to: Permit

        init(pieces: [PermitControl.Piece], from: Permit, to: Permit) {
            // A piece named by a permit and not by the manifest is real: a
            // document that has not synced to this Mac, or one that was
            // trashed. It is still a place the change moves, so it is counted
            // — and drawn as the one thing this Mac can honestly say about it.
            let known = Set(pieces.map(\.id))
            let named = Set(from.wirePieces + to.wirePieces).subtracting(known)
            self.pieces = pieces + named.sorted().map {
                PermitControl.Piece(id: $0, title: PermitChange.unknownPieceTitle)
            }
            self.from = from
            self.to = to
        }

        /// What a piece id no manifest here carries is called. Never the raw
        /// id: a document id is not a thing a writer has ever seen.
        static let unknownPieceTitle = "a piece this Mac can\u{2019}t find"

        /// Pieces they could write in and now cannot — §5's demotion row.
        var leaving: [PermitControl.Piece] {
            pieces.filter {
                from.authors(.piece($0.id)) && !to.authors(.piece($0.id))
            }
        }

        /// Pieces they could not write in and now can — §5's promotion row.
        var joining: [PermitControl.Piece] {
            pieces.filter {
                !from.authors(.piece($0.id)) && to.authors(.piece($0.id))
            }
        }

    }

    /// **Change what somebody may write**, with both directions of spec §5 in
    /// the message.
    ///
    /// Two halves, each stated only where it happened:
    ///
    /// - **What leaves.** *What Sam already wrote in "Chapter 4" stays.
    ///   Anything she writes there from now on is set aside.* A demotion does
    ///   not reach back — the mark is what makes that true — and a writer who
    ///   thought it did would be afraid to use the verb at all.
    /// - **What joins.** *…and what was set aside while it wasn't hers stays
    ///   set aside.* A promotion is not a pardon, which is the half nobody
    ///   assumes, and the words that were refused come back only through the
    ///   Inbox door.
    ///
    /// `notice` is `PermitControl.firstNarrowingNotice`'s — the ONE sentence
    /// about what a book's first narrowing costs, shared with the admission
    /// sheet, never written a second time here.
    static func changePermit(
        forPerson fingerprint: String, named name: String,
        change: PermitChange, notice: String? = nil
    ) -> Self {
        var parts: [String] = []
        if let leaving = sentence(
            forLeaving: change.leaving, of: change.pieces, named: name) {
            parts.append(leaving)
        }
        if let joining = sentence(
            forJoining: change.joining, of: change.pieces, named: name) {
            parts.append(joining)
        }
        if parts.isEmpty { parts.append(nothingMoves(named: name)) }
        if change.to.wirePieces.isEmpty, change.to.mayStartAPieceOfTheirOwn {
            parts.append(startsTheirOwn(named: name))
        }
        if let notice { parts.append(notice) }

        return PeopleAndDevicesConfirmation(
            verb: .changePermit,
            fingerprint: fingerprint,
            record: nil,
            title: "Change what \(name) may write?",
            message: parts.joined(separator: " "),
            confirmTitle: "Change",
            field: nil,
            permit: change.to,
            alternate: nil)
    }

    /// The demotion half. Named where a writer could hold the list in their
    /// head, counted where they could not, and *this book* where it is
    /// everything.
    private static func sentence(
        forLeaving leaving: [PermitControl.Piece],
        of all: [PermitControl.Piece], named name: String
    ) -> String? {
        guard !leaving.isEmpty else { return nil }
        if leaving.count == all.count {
            return "What \(name) has already written in this book stays in it. "
                + "Anything they write in the manuscript from now on is set aside."
        }
        return "What \(name) already wrote in \(list(leaving)) stays in this "
            + "book. Anything they write there from now on is set aside."
    }

    /// The promotion half — and the clause nobody assumes, which is that it is
    /// not a pardon.
    private static func sentence(
        forJoining joining: [PermitControl.Piece],
        of all: [PermitControl.Piece], named name: String
    ) -> String? {
        guard !joining.isEmpty else { return nil }
        let where_ = joining.count == all.count
            ? "anywhere in this book" : "in \(list(joining))"
        return "\(name) can write \(where_) from now on, and what was set aside "
            + "while they couldn\u{2019}t stays set aside."
    }

    /// Neither half happened: a change of words with no change of places — a
    /// book with no pieces yet, or a piece list that moved only among documents
    /// this permit already covered.
    private static func nothingMoves(named name: String) -> String {
        "Nothing \(name) has written moves, and there is no piece in this book "
        + "this changes what they may write in."
    }

    /// **The empty piece list is a real state, not an error** (`PermitPicker
    /// .noPiecesChosen`): an author of no pieces yet may still start one, and
    /// this book asks whose it is when they do.
    private static func startsTheirOwn(named name: String) -> String {
        "\(name) can still start a piece of their own; this book will ask you "
        + "whether it\u{2019}s theirs."
    }

    /// *"Chapter 4"*, *"Chapter 4" and "Chapter 9"*, else *6 pieces* — a list a
    /// writer can check against the tree, or a count where naming them would
    /// be a paragraph.
    private static func list(_ pieces: [PermitControl.Piece]) -> String {
        let titles = pieces.map { "\u{201C}\($0.title)\u{201D}" }
        switch titles.count {
        case 1: return titles[0]
        case 2: return "\(titles[0]) and \(titles[1])"
        case 3: return "\(titles[0]), \(titles[1]) and \(titles[2])"
        default: return "\(titles.count) pieces"
        }
    }

    /// **Let somebody back in, saying what they will be able to write** (Task
    /// 4's review, the Critical).
    ///
    /// `RegistryAdmission.admit` over a REVOKED record installs the permit it
    /// is given, and `DocumentStore.admit`'s permit defaults to the whole book
    /// — so before this, Re-admit turned an author of two chapters into an
    /// author of the whole novel with nothing on screen saying so. Widening is
    /// the direction a writer must never be moved in silently, which is why
    /// the message NAMES the permit and the caller's default is the one they
    /// held when they were shut out.
    ///
    /// The set-aside clause is the half nobody assumes and is the same fact
    /// spec §5's promotion row states: letting them back in is not a pardon.
    /// What was refused while they were out comes back only through the Inbox.
    static func readmit(
        person fingerprint: String, named name: String,
        change: PermitChange, notice: String? = nil
    ) -> Self {
        var parts = [
            "\(name) can write in this book again.",
            saying(change.to, among: change.pieces),
            "What was set aside while they were out stays set aside \u{2014} it "
                + "comes back only through the Inbox.",
        ]
        if let notice { parts.append(notice) }
        return PeopleAndDevicesConfirmation(
            verb: .changePermit,
            fingerprint: fingerprint,
            record: nil,
            title: "Let \(name) write in this book again?",
            message: parts.joined(separator: " "),
            confirmTitle: "Re-admit",
            field: nil,
            permit: change.to,
            alternate: nil)
    }

    /// **What a permit says, in the words the control uses for it** — the
    /// rung's own title and explanation, so the sentence a writer reads before
    /// committing is the sentence they read while choosing.
    ///
    /// A permit no control can draw says so: `Permit.rung(of:)` answers nil for
    /// a role or scope word a later Maugham wrote, and naming it anything would
    /// be this Mac deciding what it does not know.
    static func saying(
        _ permit: Permit, among pieces: [PermitControl.Piece]
    ) -> String {
        guard let rung = PermitControl.choice(displaying: permit) else {
            return "What they may write is something this version of Maugham "
                + "doesn\u{2019}t recognise."
        }
        guard rung.picksPieces else {
            return "They will be \(article(rung.title)) \u{2014} "
                + rung.explanation.lowercasedFirst
        }
        let named = pieces.filter { permit.authors(.piece($0.id)) }
        guard !named.isEmpty else {
            return "They will be \(article(rung.title)), with no piece chosen "
                + "yet \u{2014} " + PermitPicker.noPiecesChosen.lowercasedFirst
        }
        return "They will be \(article(rung.title)): \(list(named))."
    }

    /// *an author of some pieces*, *a reviewer* — the rung's title as it reads
    /// mid-sentence.
    private static func article(_ title: String) -> String {
        let lowered = title.lowercasedFirst
        return "aeiou".contains(lowered.first ?? "x") ? "an \(lowered)" : "a \(lowered)"
    }

    // MARK: - The two repairs

    /// **Bring a record up to its history.** It is confirmed because it writes
    /// over a signed file, and the message says the thing a writer would
    /// otherwise assume — that something about what is applied is about to
    /// change. Nothing is: the book has been enforcing the history all along.
    static func resign(person fingerprint: String, named name: String,
                       history: String, record says: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .resign,
            fingerprint: fingerprint,
            record: nil,
            title: "Bring \(name)\u{2019}s record up to this book\u{2019}s history?",
            message: "This book\u{2019}s history says \(history) and the file "
                + "describing \(name) still says \(says). The history is what "
                + "Maugham has been going by, so nothing about what is applied "
                + "changes \u{2014} this writes the file again so it agrees.",
            confirmTitle: "Re-sign",
            field: nil,
            permit: nil,
            alternate: nil)
    }

    /// **Write this Mac's own record again** (audit F4) — the last resort, and
    /// the only repair in this pane that invents bytes rather than putting old
    /// ones back. That distinction is the whole message: Restore replaces a
    /// file with a version this Mac read; this replaces it with a new one, so
    /// anything only the old file knew is gone.
    static func writeOwnRecord(record: RecordRef, kind: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .writeOwnRecord,
            fingerprint: record.fingerprint,
            record: record,
            title: "Write this Mac\u{2019}s \(kind) record again?",
            message: "This Mac signs a new \(kind) record for itself, over the "
                + "one that doesn\u{2019}t check out. It isn\u{2019}t the old "
                + "file put back \u{2014} this Mac doesn\u{2019}t have that "
                + "\u{2014} so anything only the old one said is gone. Nothing "
                + "anyone has written is touched.",
            confirmTitle: "Write It Again",
            field: nil,
            permit: nil,
            alternate: nil)
    }
}

private extension String {
    /// A sentence's own words, lowered at the front so they read mid-sentence.
    /// Only the first character, because *Chapter 4* inside one must not move.
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
