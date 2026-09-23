import SwiftUI
import MaughamCore

/// **Project Settings → People & Devices** (signed op log P2, spec §6).
///
/// A thin drawing of `PeopleAndDevicesModel`: every decision about what belongs
/// on screen — which row is a question, which root is this Mac, which claimant
/// has been answered — is made in that value and asserted with nothing mounted.
/// What is left here is layout and four verbs.
///
/// **Every verb here is live**: Revoke and Retire as of P2b Task 7, Merge as of
/// Task 8. A live verb that this Mac may not perform on a given row is disabled
/// with the reason in its tooltip — never hidden, because *why can I not revoke
/// this* is a question an absent button answers with silence.
///
/// **Forget this device** is live and touches no registry record — it clears
/// this Mac's own memory of a label.
///
/// **The share sentence is said once, in the footer** (Denver's re-smoke,
/// 2026-09-19). It used to be drawn a second time under every revocable
/// person's row, in `revokeSentence`'s near-identical spelling, so a pane with
/// two people said *to stop it writing at all, remove it from the iCloud share*
/// three times on one screen. The footer is the right home: it is a fact about
/// what this whole section can and cannot do, not about one row. The sentence
/// still meets the writer at the moment it matters most — inside the Revoke
/// confirmation, which is the last thing they read before pressing
/// (`PeopleAndDevicesConfirmation.revoke`), and that is why `revokeSentence`
/// stays.
///
/// A verb that REFUSES says so in `notice`, drawn under the header: the writer
/// pressed something and it did not happen, and a control that looks dead is
/// worse than a refusal (RULING-7).
struct PeopleAndDevicesSection: View {

    let model: PeopleAndDevicesModel
    /// The writer is asking to admit a device. The sheet belongs to the window,
    /// so this posts and the window asks.
    var admit: () -> Void = {}
    /// Clear this Mac's memory of a label for a device the folder no longer
    /// describes.
    var forget: (String) -> Void = { _ in }
    /// Stop applying what a device writes. The argument is the PERSON's
    /// fingerprint — under labels-only that is the device's author key, and it
    /// is the record the root re-signs.
    var revoke: (String) -> Void = { _ in }
    /// Say this Mac has stopped writing in this book. Offered on this Mac's own
    /// row alone: a device signs its own retirement.
    var retire: (String) -> Void = { _ in }
    /// Let a device this Mac revoked write again — the revocation's inverse,
    /// through the admission door (fix round 1, Important 3b).
    var readmit: (PeopleAndDevicesModel.Person) -> Void = { _ in }
    /// Change the word this book calls somebody (P2 smoke find 3). The whole
    /// row, because the alert starts its field at the name that stands.
    var rename: (PeopleAndDevicesModel.Person) -> Void = { _ in }
    /// Put back the last version of a record this device saw verify (P2 smoke
    /// find 1). The whole row, because a record is a directory AND a
    /// fingerprint and a bare string would be half of one.
    var restore: (PeopleAndDevicesModel.Unverifiable) -> Void = { _ in }
    /// Take another root's chain in: *this is also me* (Task 8). The argument
    /// is the claimant ROOT's fingerprint, and the act is a claim record
    /// adopting it — never a change to which root this device is on (B1).
    var merge: (String) -> Void = { _ in }
    /// **Change what somebody may write** (P3b Task 5, spec §7.2). The whole
    /// row, because the control it opens starts at the permit they hold and
    /// the message states both directions from it.
    var changePermit: (PeopleAndDevicesModel.Person) -> Void = { _ in }
    /// Write a person's record again from this book's history (spec §3.2's
    /// crash window). The whole row, for the sentence naming both.
    var resign: (PeopleAndDevicesModel.Person) -> Void = { _ in }
    /// **Yes, that piece is theirs** (spec §7.2, fix round 1's I3). The whole
    /// question, because the act needs the person AND the piece and either
    /// alone is half of one.
    var onPieceIsTheirs: (LoadQuestions.NewPiece) -> Void = { _ in }
    /// **Not now**, from the pane. It writes nothing to the book — the same
    /// device-local memory the sheet's own *Not now* writes.
    var onPieceNotNow: (LoadQuestions.NewPiece) -> Void = { _ in }
    /// Write this Mac's own registry record again, over one that will not
    /// verify and that this device holds no earlier bytes for (audit F4).
    var writeAgain: (PeopleAndDevicesModel.Unverifiable) -> Void = { _ in }
    /// What the last verb said when it refused, or nil.
    var notice: String?

    /// What Write It Again says, and what it is not — Restore puts a file
    /// back; this makes a new one.
    static let writeAgainHelp = "Sign a new record for this Mac, over the one that doesn’t check out"

    var body: some View {
        Section {
            if let refusal = model.refusal {
                // RULING-54: a registry present and unreadable says so in the
                // read's own words. Empty rows here would tell the writer that
                // nobody may write in this book — a trust decision nobody made.
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                thisMac
                if let notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(model.pending) { request in
                    pendingRow(request)
                }
                // **Held keys that are nobody to ask about** (P3b Task 5). The
                // admission sheet is silent about them by design — a sheet
                // would offer a control that cannot help — and silence is only
                // honest if something somewhere says why lines are waiting.
                ForEach(model.waiting) { key in
                    waitingRow(key)
                }
                ForEach(model.people) { person in
                    personRow(person)
                }
                // **§7.2: pieces somebody started that nobody has claimed**
                // (fix round 1, I3). This is where the sheet's *Not now* says
                // the question waits, so it has to be here — and the ones
                // already put off are listed with the rest, because a decline
                // that hid the question here would leave the writer no way
                // back to it.
                ForEach(model.pendingPieces) { piece in
                    pendingPieceRow(piece)
                }
                // **Streams nothing signs** (#8, spec §7.2). Below the people,
                // because each is a fact about files rather than about anybody
                // who can be let in or shut out.
                ForEach(model.unsigned) { stream in
                    unsignedRow(stream)
                }
                ForEach(model.merged) { root in
                    plainRow(root, note: "merged",
                             caption: "Everything that Mac wrote is in this book.")
                }
                ForEach(model.claimants) { root in
                    claimantRow(root)
                }
                ForEach(model.absent) { device in
                    absentRow(device)
                }
                if !model.unverifiable.isEmpty {
                    // **Last, and headed**, because everything above is a fact
                    // about who may write and this is a fact about a file
                    // (smoke find 1). Until this existed a record the reader
                    // refused appeared nowhere in the app at all, while its
                    // consequences — a Mac reading as *not yet admitted* on its
                    // own book — were on the row above.
                    Text("Records that don\u{2019}t verify")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(model.unverifiable) { record in
                        unverifiableRow(record)
                    }
                }
            }
        } header: {
            Text("People & Devices")
        } footer: {
            Text(PeopleAndDevicesModel.shareSentence)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - This Mac

    private var thisMac: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.standing)
            // *Its* code, under *this book was started on this Mac*; *this
            // Mac's* code under a sentence naming somebody else's, where "it"
            // would be that other Mac (Denver's wording ruling, 2026-09-18).
            Text(model.startedOnThisMac
                 ? "Its code is \(model.code)."
                 : "This Mac\u{2019}s code is \(model.code).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rows

    private func pendingRow(_ request: PeopleAndDevicesModel.PendingRequest) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.name)
                Text(request.sentence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Admit\u{2026}", action: admit)
                .controlSize(.small)
                .help("Give this device a name and let its writing in")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A held key with no question in it: one of a device's other three
    /// writers, or a key two device records claim. Named by its code, because
    /// there is nothing else here to call it.
    private func waitingRow(_ key: PeopleAndDevicesModel.WaitingKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.heldLines == 1
                 ? "1 line waiting (\(key.code))"
                 : "\(key.heldLines) lines waiting (\(key.code))")
            Text(key.sentence)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One §7.2 question: whose a piece is, with the same two answers the
    /// sheet offers and no third (fix round 1, I3).
    ///
    /// It draws `LoadQuestions.NewPiece` and derives nothing — the question,
    /// what each answer costs, and the count are all the model's, so this row
    /// and the dialog cannot say different things about one piece.
    private func pendingPieceRow(
        _ piece: PeopleAndDevicesModel.PendingPiece
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(piece.question.question)
                .accessibilityIdentifier("pending-piece-question")
            Text(piece.question.consequence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if piece.putOff {
                Text(PeopleAndDevicesModel.pieceQuestionPutOff)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(piece.question.theirsTitle) {
                    onPieceIsTheirs(piece.question)
                }
                .accessibilityIdentifier("pending-piece-theirs")
                Button(piece.question.notNowTitle) {
                    onPieceNotNow(piece.question)
                }
                .accessibilityIdentifier("pending-piece-not-now")
                .disabled(piece.putOff)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A stream in this book that answers to no key (#8). Two sentences: what
    /// is true now, and what narrowing does — in the tense the book is in.
    private func unsignedRow(_ stream: PeopleAndDevicesModel.UnsignedStream) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stream.sentence)
            Text(model.alreadyNarrowed
                 ? PeopleAndDevicesModel.UnsignedStream.afterNarrowing
                 : PeopleAndDevicesModel.UnsignedStream.beforeNarrowing)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func personRow(_ person: PeopleAndDevicesModel.Person) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(person.title)
                        if let mark = person.mark {
                            Text(mark)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(person.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // **What they may write** (spec §7.2), on the row rather
                    // than behind the control, so the question the control
                    // answers is visible before it is pressed.
                    Text(person.permitSentence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let behind = person.behindHistorySentence {
                        // Spec §3.2's crash window. Orange because the screen
                        // and the enforcement disagree and only this row can
                        // say so — nothing refuses, and no load blocks.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(behind)
                                .font(.caption)
                                .foregroundStyle(.orange)
                            if person.canResign {
                                Button("Re-sign") { resign(person) }
                                    .controlSize(.small)
                                    .help(PeopleAndDevicesModel.resignHelp)
                                    .accessibilityHint(
                                        Text(PeopleAndDevicesModel.resignHelp))
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                if person.offersPermitChange {
                    // **A root draws no change control at all**, Revoke's own
                    // exception for its reason: a root writes the whole book
                    // unconditionally and a book must not end up with no
                    // author, so this could not become live on any folder, on
                    // any day. Everyone else keeps the button, disabled, with
                    // the reason in the tooltip.
                    Button("Change\u{2026}") { changePermit(person) }
                        .controlSize(.small)
                        .disabled(!person.canChangePermit)
                        .help(person.whyNotChangeable
                              ?? PeopleAndDevicesModel.changeHelp)
                        .accessibilityHint(Text(
                            person.whyNotChangeable
                            ?? PeopleAndDevicesModel.changeHelp))
                }
                // A label was chosen once and could never be corrected (smoke
                // find 3). Drawn on every person row, live where this Mac is
                // the root that admitted them — including its own, which is the
                // row the smoke was actually about.
                Button("Rename\u{2026}") { rename(person) }
                    .controlSize(.small)
                    .disabled(!person.canRename)
                    .help(person.whyNotRenamable ?? PeopleAndDevicesModel.renameHelp)
                    .accessibilityHint(Text(
                        person.whyNotRenamable ?? PeopleAndDevicesModel.renameHelp))
                if person.canReadmit {
                    // **The inverse, where the act was** (fix round 1,
                    // Important 3b): a revoked row used to carry a dead Revoke
                    // saying "Already revoked", which is a fact the row above
                    // already states and a control that could never act. The
                    // way back belongs in that space.
                    // Disabled, with the reason, where the permit it would
                    // put back is one this build cannot draw (P3b Task 6): an
                    // older Maugham must not re-install a rung it was never
                    // shown, and the whole-book fallback it used instead was a
                    // widening chosen by the build that understands least.
                    Button("Re-admit") { readmit(person) }
                        .controlSize(.small)
                        .disabled(person.whyNotReadmittable != nil)
                        .help(person.whyNotReadmittable
                              ?? PeopleAndDevicesModel.readmitHelp)
                        .accessibilityHint(Text(
                            person.whyNotReadmittable
                            ?? PeopleAndDevicesModel.readmitHelp))
                } else if person.offersRevoke {
                    // A root draws no Revoke at all (smoke find 2). Every other
                    // refused verb here keeps its button, disabled, with the
                    // reason in the tooltip — but a disabled control is an offer
                    // with a condition on it, and a root is claimed over rather
                    // than revoked on every folder, on every day. The decision
                    // is the model's; this only draws it.
                    Button("Revoke") { revoke(person.fingerprint) }
                        .controlSize(.small)
                        .disabled(!person.canRevoke)
                        .help(person.whyNotRevocable ?? PeopleAndDevicesModel.revokeHelp)
                        // .help is hover-only; the WHY must reach VoiceOver too.
                        .accessibilityHint(Text(
                            person.whyNotRevocable ?? PeopleAndDevicesModel.revokeHelp))
                }
            }
            ForEach(person.devices) { device in
                deviceRow(device)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deviceRow(_ device: PeopleAndDevicesModel.Device) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.callout)
                    if device.isThisMac {
                        Text("this Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(device.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notice = device.retirementNotice {
                    // A standing FACT, orange because it is a divergence the
                    // writer cannot see from anywhere else: this Mac goes on
                    // applying what it writes and nobody else does (fix round
                    // 1, Important 2).
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Button("Retire") { retire(device.fingerprint) }
                .controlSize(.small)
                .disabled(!device.canRetire)
                .help(device.whyNotRetirable ?? PeopleAndDevicesModel.retireHelp)
                .accessibilityHint(Text(
                    device.whyNotRetirable ?? PeopleAndDevicesModel.retireHelp))
        }
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func claimantRow(_ root: PeopleAndDevicesModel.Claimant) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(root.name) (\(root.code))")
                    Text("This book was also started on that Mac. "
                         + "Nothing it writes is applied here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                // Disabled with the reason beside it, never absent — Revoke's
                // and Retire's own shape (whole-branch review, I2). A Mac on
                // another root's chain can only be refused here, and being
                // refused in words that say *merge by claiming the book* is
                // the app arguing with the button the writer just pressed.
                Button("Merge: this is also me") { merge(root.fingerprint) }
                    .controlSize(.small)
                    .disabled(!root.canMerge)
                    .help(root.whyNotMergeable ?? PeopleAndDevicesModel.mergeHelp)
                    .accessibilityHint(Text(
                        root.whyNotMergeable ?? PeopleAndDevicesModel.mergeHelp))
            }
            // What a merge is and is not, beside the button rather than in the
            // footer: a writer who read it as *switch this book to that Mac*
            // would be answering a different question. Where the verb is
            // refused, the refusal takes that place instead — describing what
            // a merge would do beside a button that cannot do it is the same
            // fault one line up.
            Text(root.whyNotMergeable ?? PeopleAndDevicesModel.mergeSentence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func plainRow(
        _ root: PeopleAndDevicesModel.Named, note: String, caption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(root.name) (\(root.code))")
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One record the reader refused: whose it is, what is wrong with it in the
    /// reader's own words, and — where this Mac still holds the bytes that last
    /// verified — the one press that puts them back.
    private func unverifiableRow(
        _ record: PeopleAndDevicesModel.Unverifiable
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(record.name) (\(record.code))")
                    if record.isMine {
                        // The header above says what this device's standing IS;
                        // this row is the reason for it, and the two are only
                        // one story if the row says whose record it is.
                        Text("this Mac\u{2019}s own record")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(record.sentence)
                    .font(.caption)
                    .foregroundStyle(.orange)
                if !record.canRestore {
                    Text("This Mac doesn\u{2019}t remember an earlier version of it, "
                         + "so it can\u{2019}t put one back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // **Never a dead end** (Task 1's review, Minor 4's shape).
                // Where neither press is offered, the row says which Mac can
                // repair it rather than describing a problem with no next move.
                if let who = record.whoRepairsIt {
                    Text(who)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if record.canRestore {
                Button("Restore") { restore(record) }
                    .controlSize(.small)
                    .help(PeopleAndDevicesModel.restoreHelp)
                    .accessibilityHint(Text(PeopleAndDevicesModel.restoreHelp))
            } else if record.canWriteAgain {
                // **F4: the last resort, and only where Restore is
                // impossible.** Restore puts back a file this Mac read; this
                // signs a new one, so anything only the old file knew is gone
                // — which is why the two are never offered together.
                Button("Write It Again") { writeAgain(record) }
                    .controlSize(.small)
                    .help(PeopleAndDevicesSection.writeAgainHelp)
                    .accessibilityHint(Text(PeopleAndDevicesSection.writeAgainHelp))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func absentRow(_ device: PeopleAndDevicesModel.Named) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(device.name) (\(device.code))")
                Text("This Mac remembers naming it, but nothing in this book describes it now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Forget this device") { forget(device.fingerprint) }
                .controlSize(.small)
                .help("Clear this Mac\u{2019}s memory of the name it gave")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// **The one control that changes what somebody may write** (P3b Task 5, spec
/// §7.2), and the one that says what re-admitting them installs (Task 4's
/// review, the Critical).
///
/// A sheet rather than an alert, because the question needs a picker and a list
/// of pieces and an `Alert` takes buttons and a text field. Everything it
/// DECIDES is still a value: the sentence it draws is
/// `PeopleAndDevicesConfirmation`'s, built from the same pure factory a test
/// compares with nothing mounted, and this view holds the writer's two choices
/// and nothing else (tripwire 33 — the suite asserts the control is drawn, and
/// never presses it and waits).
///
/// **It starts where the writer already is.** A permit change starts at the
/// permit they hold; a re-admission starts at the permit they held when they
/// were shut out. Neither ever starts wider than that, which is the whole of
/// what Task 4's review found: a bare Re-admit installed the caller's default,
/// and the caller's default was the whole book.
struct PermitChangeSheet: View {
    let person: PeopleAndDevicesModel.Person
    let pieces: [PermitControl.Piece]
    /// What a narrowing would cost this book, or nil while the read has not
    /// landed (or refused). Nil says nothing rather than guessing — the act
    /// runs the same sweep and refuses in the error's own words.
    let book: PermitControl.BookNarrowing?
    /// **How many pieces of this book's history the writer has put down** (P3b
    /// Task 6). Zero in every book that has lost nothing, which is nearly all
    /// of them; above zero the confirmation says what deciding without that
    /// history costs.
    ///
    /// **Two counts, because the act sweeps two ways** (fix round 1, Minor 1):
    /// a change that narrows takes the book's photograph as well as this
    /// person's mark, one that narrows nobody reads this person's streams
    /// alone — and the control moves between the two as the writer chooses, so
    /// the sentence is rebuilt with the choice like everything else here.
    /// `PermitControl.lostHistory` is the one place that is decided.
    let lostHistory: Int
    /// The book's, for the narrowing case.
    let lostHistoryInTheBook: Int
    /// Is this letting somebody back in, or moving somebody who is already in?
    let isReadmission: Bool
    let commit: (Permit) -> Void
    let cancel: () -> Void

    @State private var choice: PermitControl.Choice
    @State private var chosenPieces: Set<String>

    init(
        person: PeopleAndDevicesModel.Person,
        pieces: [PermitControl.Piece],
        book: PermitControl.BookNarrowing?,
        lostHistory: Int = 0,
        lostHistoryInTheBook: Int = 0,
        isReadmission: Bool,
        commit: @escaping (Permit) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.person = person
        self.pieces = pieces
        self.book = book
        self.lostHistory = lostHistory
        self.lostHistoryInTheBook = lostHistoryInTheBook
        self.isReadmission = isReadmission
        self.commit = commit
        self.cancel = cancel
        let starting = isReadmission ? person.permitWhenRevoked : person.permit
        // A permit no control can draw never reaches here — the row's Change…
        // is refused for one (`whyNotChangeable`) — so the fallback is the one
        // a re-admission of a P2-era person needs and nothing else.
        _choice = State(initialValue:
            PermitControl.choice(displaying: starting) ?? .wholeBook)
        _chosenPieces = State(initialValue: PermitControl.pieces(displaying: starting))
    }

    /// The whole question, as a value: what it is called, what it costs, and
    /// what it would install. Rebuilt as the writer moves the control, which is
    /// why the sentence under it is always about the choice on screen.
    var confirmation: PeopleAndDevicesConfirmation {
        let change = PeopleAndDevicesConfirmation.PermitChange(
            pieces: pieces,
            from: isReadmission ? person.permitWhenRevoked : person.permit,
            to: PermitControl.permit(for: choice, pieces: chosenPieces))
        let notice = book.flatMap {
            PermitControl.notice(forGranting: change.to, in: $0)
        }
        let put = PermitControl.lostHistory(
            forGranting: change.to, subject: lostHistory,
            book: lostHistoryInTheBook)
        return isReadmission
            ? .readmit(person: person.fingerprint, named: person.title,
                       change: change, notice: notice, lostHistory: put)
            : .changePermit(forPerson: person.fingerprint, named: person.title,
                            change: change, notice: notice, lostHistory: put)
    }

    var body: some View {
        let confirmation = self.confirmation
        return VStack(alignment: .leading, spacing: 16) {
            Text(confirmation.title)
                .font(.headline)
            PermitPicker(
                pieces: pieces, choice: $choice, chosenPieces: $chosenPieces)
            Text(confirmation.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmation.confirmTitle) {
                    commit(confirmation.permit ?? person.permit)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, maxWidth: 480)
    }
}
