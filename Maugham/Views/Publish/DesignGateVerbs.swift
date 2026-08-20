import Foundation

/// **What the writer can DO at the gate, and what happens when they can't**
/// (publish-department P4 Task 6, spec §5's verdict).
///
/// `DesignGate`'s other half, written to the same rule: the view below draws,
/// and everything it could get wrong is a pure function here. Task 5 shipped the
/// gate as a thing to READ; this is the thing to ANSWER, and the answer moves the
/// writer's shipping templates — so every part of it that can refuse says its own
/// sentence rather than leaving a button that does nothing (Global Constraint
/// 2/4).
///
/// **Nothing here registers with `NSUndoManager`, at any depth.**
/// `ProposalPromotion`'s type doc settles it and this file is the surface that
/// could most easily forget: *undoable* here is `revert` — a stored reversal the
/// writer asks for by name — and a ⌘Z in a text pane must never, through an undo
/// stack it happens to share, un-ship a book's templates.
/// `DesignGateTests.test_nothingAboutTheGatesVerbsReachesTheUndoManager` is the
/// census.
extension DesignGate {

    /// **The four verbs**, and every string each one wears.
    ///
    /// A closed enum rather than four booleans on a struct because which of them
    /// a proposal offers is one question with one answer per status
    /// (`verbs(status:hasOpenProposalRound:)`), and a surface reading four
    /// independent flags is a surface that can draw Approve beside Revert.
    enum Verb: String, Equatable, Hashable, CaseIterable {
        /// Put this round's staged files onto the live publish tree.
        case approve
        /// Send the writer's words back into the session that made this
        /// proposal — the desk's own verb, reached from the surface where the
        /// writer actually formed the opinion.
        case requestChanges
        /// Take a standing promotion back, restoring the displaced templates.
        case revert
        /// Keep a standing promotion for good, and let the displaced templates
        /// go — deliberately, by name.
        case finalize

        var title: String {
            switch self {
            case .approve: return "Approve"
            case .requestChanges: return DepartmentDesignRow.requestChangesTitle
            case .revert: return "Revert"
            case .finalize: return "Finalize"
            }
        }

        /// Distinct in the accessibility tree for the reason every control in
        /// this department carries one: the visible words are told apart by the
        /// surface they sit on, which a linear tree does not carry — and
        /// "Revert" in particular is a word this app uses elsewhere.
        var accessibilityLabel: String {
            switch self {
            case .approve: return "Approve this design"
            case .requestChanges: return "Request changes to this design"
            case .revert: return "Revert this design"
            case .finalize: return "Finalize this design"
            }
        }

        /// What the verb promises, in the writer's terms — and for the two
        /// destructive ones, what it costs.
        var help: String {
            switch self {
            case .approve:
                return "Put these templates onto the live publish tree. Your "
                    + "current templates are backed up first, and Revert puts "
                    + "them back."
            case .requestChanges:
                return DepartmentDesignRow.requestChangesHelp
            case .revert:
                return "Take this promotion back. Your original templates are "
                    + "restored from the backup, and this round is marked "
                    + "turned down."
            case .finalize:
                return "Keep this design for good. " + DesignGate.finalizeCost
            }
        }
    }

    /// **What finalizing costs, in ONE spelling** — the second sentence of
    /// `Verb.finalize.help` and the whole message of its confirmation.
    ///
    /// One constant rather than two hand-written sentences because the tooltip
    /// and the dialog are the same promise made twice, and a writer who read the
    /// hover and then met a different sentence in the dialog would have to work
    /// out whether the two describe the same act.
    static let finalizeCost =
        "The templates it replaced are discarded \u{2014} after this there is "
        + "nothing to revert to."

    /// **Which verbs a proposal offers**, from its own status and the window's
    /// designer session.
    ///
    /// A pure function of two facts, so the whole truth table is assertable with
    /// nothing mounted — and so a status that arrived a moment ago (the value
    /// the verb itself handed back) reconfigures the footer on the next body
    /// pass, which is the whole of "transitions reflect immediately".
    ///
    /// **Approve is not offered over an approved proposal**, and neither is
    /// Request Changes: a design the writer has already put live is not one they
    /// are still iterating on. `.rejected`, `.superseded` and a status from a
    /// newer build offer nothing at all — see `settledNote`.
    static func verbs(status: DesignProposalStore.Status,
                      hasOpenProposalRound: Bool) -> [Verb] {
        switch status {
        case .pending:
            return hasOpenProposalRound ? [.approve, .requestChanges] : [.approve]
        case .approved:
            return [.revert, .finalize]
        case .rejected, .superseded, .unknown:
            return []
        }
    }

    /// **What a proposal past deciding says instead of a verb.**
    ///
    /// `nil` exactly when `verbs` is non-empty. A footer that drew neither would
    /// be the blank RULING-7's shape forbids: a writer who opened a superseded
    /// round would find no controls and no reason, which reads as a surface that
    /// failed to load rather than as a decision already made.
    static func settledNote(_ proposal: DesignProposalStore.Proposal) -> String? {
        switch proposal.status {
        case .pending, .approved:
            return nil
        case .rejected:
            // The revert's own note when there is one — it is the account of
            // what happened to these templates, written where the cause was
            // known (`ProposalPromotion.defaultRevertNote`, or the writer's own
            // words). A standing sentence only for a proposal turned down some
            // other way, which nothing ships today.
            return proposal.revertNote?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilWhenEmpty ?? turnedDownNote
        case .superseded:
            return supersededNote
        case .unknown(let raw):
            return futureStatusNote(raw)
        }
    }

    static let turnedDownNote =
        "You turned this round down. Nothing it proposed reached the live "
        + "templates."

    static let supersededNote =
        "A later round replaced this proposal, so there is nothing here to "
        + "decide. The newest round is the one on the department desk."

    /// A status this build cannot represent — `DesignProposalStore.Status
    /// .unknown`'s own discipline carried onto the surface. Naming the raw word
    /// rather than printing "unknown" tells the writer their proposal is from a
    /// newer Maugham rather than broken.
    static func futureStatusNote(_ raw: String) -> String {
        "This round is \u{201c}\(raw)\u{201d} \u{2014} a status a newer version "
            + "of Maugham wrote. There is nothing here to decide from this "
            + "version."
    }

    // MARK: - Asking first

    /// **The confirmation a verb owes the writer before it runs**, or `nil` for
    /// one that may act on the press.
    ///
    /// **Finalize is the only one, and it is the only one that needs to be.**
    /// Approve is reversible by name (Revert, offered on the very next frame),
    /// Request Changes writes nothing to the publish tree, and Revert IS the
    /// reversal. Finalize is the single act on this surface with no way back —
    /// it discards the writer's own displaced templates — and it is also the one
    /// verb whose success changes nothing visible about the proposal, so a
    /// mis-click would be an irreversible loss that looked like a no-op.
    ///
    /// A value with its two ways out rather than a boolean, `ReviewBoardChip
    /// Verbs`' shape: what the dialog says and what each of its buttons does are
    /// then one thing a test can hold, and a surface cannot draw a confirmation
    /// whose Finalize button does something else.
    static func confirmation(for verb: Verb,
                             perform: @escaping () -> Void,
                             cancel: @escaping () -> Void) -> DesignGateConfirmation? {
        switch verb {
        case .approve, .requestChanges, .revert:
            return nil
        case .finalize:
            return DesignGateConfirmation(
                verb: verb, title: finalizeConfirmTitle, message: finalizeCost,
                confirmTitle: verb.title, cancelTitle: cancelTitle,
                perform: perform, cancel: cancel)
        }
    }

    /// Names the act and asks, rather than "Are you sure?" — a title that could
    /// stand over any dialog in the app tells a writer who reached it by
    /// mis-click nothing about what they are about to lose.
    static let finalizeConfirmTitle = "Finalize this design?"

    static let cancelTitle = "Cancel"

    // MARK: - Refusals

    /// **Every refusal's own sentence** (Global Constraint 2/4), resolved once
    /// and never restated.
    ///
    /// `ProposalPromotion.Error` already writes them — the busy compile names
    /// the job, the backup slot names the proposal holding it and both ways out,
    /// the double-approve names the standing backup, the finalize-without-backup
    /// names what is not there — so this reads them rather than composing a
    /// second set that could disagree with the ones the MCP surface would show.
    ///
    /// **Total, on purpose.** A promotion is file I/O against the writer's own
    /// folder, and a permissions error or a vanished project must not be the one
    /// press that produces silence.
    static func refusalSentence(_ error: Error) -> String {
        if let promotion = error as? ProposalPromotion.Error {
            return promotion.description
        }
        if let store = error as? DesignProposalStore.StoreError {
            return store.description
        }
        let localized = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localized.isEmpty else { return unexplainedRefusal }
        return "That couldn\u{2019}t be done: \(localized)"
    }

    /// The standing sentence for a failure that arrived with nothing to say —
    /// `noCauseGiven`'s sibling, and here for the same reason: this is the one
    /// place a writer would otherwise be shown an empty box where a reason goes.
    static let unexplainedRefusal =
        "That couldn\u{2019}t be done, and the reason was not recorded. Check "
        + "that the project folder is still where it was, then try again."

    /// A gate mounted with no window behind it — the probe mounts, and a window
    /// whose stores never finished loading. Saying so beats a button that
    /// silently does nothing, which is the whole of Constraint 2.
    static let notWired =
        "This window isn\u{2019}t ready to act on a design proposal yet. Try "
        + "again in a moment, or reopen the project."

    // MARK: - Confirmations

    /// **What each verb says when it worked.**
    ///
    /// Approve and Revert also move the proposal's status, which the header's
    /// own line re-reads — but `finalize` deliberately changes nothing visible
    /// about the proposal (it stays `approved`; what it changes is what can be
    /// undone), so without a sentence the most destructive verb on this surface
    /// would be the only one that looked like nothing happened.
    static let approvedConfirmation =
        "Approved \u{2014} these templates are live. Your previous ones are "
        + "backed up, and Revert puts them back."

    static let revertedConfirmation =
        "Reverted \u{2014} your original templates are back on the live publish "
        + "tree, and this round is marked turned down."

    static let finalizedConfirmation =
        "Finalized \u{2014} this design is permanent. The templates it replaced "
        + "have been discarded, and the next round can be approved."

    static let changesSentConfirmation =
        "Sent \u{2014} the designer is taking another round of this proposal. "
        + "The department desk shows it running."

    /// The gate's own words-for-the-designer field. Distinct from the desk's
    /// `directionPrompt`, which is optional because a bare Run is briefed on the
    /// visual language statement alone: a change request with no words is not a
    /// round at all, and `changesRefusal` says so.
    static let changeRequestPrompt =
        "What to change about this design"
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

/// **What a gate verb did**, in the writer's terms.
///
/// `.done` carries the RE-READ proposal rather than the one the verb was handed,
/// and that is the whole point of this type (Task 5's concern 1, ledgered): the
/// gate holds its proposal as a VALUE, `approve` marks it approved as its last
/// step on disk, and a gate that went on drawing the value it started with would
/// offer Approve over a proposal it had just approved.
enum DesignGateOutcome: Equatable {
    /// The verb ran. The proposal is what the store holds now, and `sentence` is
    /// what the writer is told.
    case done(DesignProposalStore.Proposal, sentence: String)
    /// The verb refused, with its own sentence.
    case refused(String)
}

/// **A verb waiting on the writer's yes** — what the dialog says, and what each
/// of its two buttons does.
///
/// `ReviewBoardChipVerbs.ChipVerb`'s shape and for its reason: a menu item, or
/// here a dialog, is a set of words with an action behind each of them, and
/// holding the pair as one value is what makes it possible to assert that the
/// button labelled Finalize is the one that finalizes. It also makes the
/// pending confirmation *reachable*: a `.confirmationDialog` is drawn by the
/// window server and a headless mount cannot press its buttons, so a surface
/// that kept this only as private view state would put its most destructive
/// verb out of reach of every test in the suite.
///
/// The closures are the view's own — `perform` runs the verb it was holding,
/// `cancel` drops it — so nothing here decides what a verb does.
struct DesignGateConfirmation: Identifiable {
    let verb: DesignGate.Verb
    let title: String
    /// What it costs, said before the writer says yes.
    let message: String
    let confirmTitle: String
    let cancelTitle: String
    let perform: () -> Void
    let cancel: () -> Void

    var id: String { verb.rawValue }
}

/// **The gate's actions seam** (P4 Task 6).
///
/// Closures rather than stores, `DepartmentPane`'s rule for `DepartmentPane`'s
/// reason: the gate takes a value and reads no disk on a body path (tripwire 4),
/// and every one of these verbs reaches something that belongs to the window —
/// the project's `CompileJobManager`, the warm designer session. Defaults that
/// REFUSE with a sentence rather than no-op, so a probe mount or a window whose
/// stores never loaded still tells the writer something.
struct DesignGateActions {
    var approve: (DesignProposalStore.Proposal) async -> DesignGateOutcome
        = { _ in .refused(DesignGate.notWired) }
    var revert: (DesignProposalStore.Proposal) async -> DesignGateOutcome
        = { _ in .refused(DesignGate.notWired) }
    var finalize: (DesignProposalStore.Proposal) async -> DesignGateOutcome
        = { _ in .refused(DesignGate.notWired) }
    /// **The desk's own verb, called and not restated** — the refusal sentence,
    /// or `nil` when the words went. `DepartmentDesignRow.sendChanges` is the one
    /// spelling both surfaces reach.
    var requestChanges: (String) -> String? = { _ in DesignGate.notWired }
}

/// **The three promotions, performed** — the one place the gate's verbs reach
/// `ProposalPromotion`, re-read what they changed, and tell the rest of the
/// window.
///
/// Three things happen here that must happen together, which is why it is one
/// type rather than three closures at the wiring site:
///
/// 1. The promotion runs, and a throw becomes the sentence it threw
///    (`DesignGate.refusalSentence`) rather than a log line.
/// 2. **The proposal is re-read.** `approve` marks it `approved` as its last
///    step and `revert` marks it `rejected` with a note; the caller's copy knows
///    neither, and handing that copy back would leave the gate offering Approve
///    over a proposal it had just approved (Task 5's concern 1).
/// 3. **The project is told** — `.maughamDesignProposalsChanged`, project-scoped
///    (ADR 0021). The department desk in the other column derives its Design row
///    from `.maugham/design/proposals/` and its `ReloadKey` watches the
///    designer's RUN state; a promotion is not a run, so without this the desk
///    would go on describing a proposal by a status it no longer has.
@MainActor
enum DesignGatePromotion {

    static func approve(_ proposal: DesignProposalStore.Proposal,
                        projectURL: URL,
                        jobManager: CompileJobManager) async -> DesignGateOutcome {
        do {
            try await ProposalPromotion.approve(
                proposal: proposal, projectURL: projectURL, jobManager: jobManager)
        } catch {
            return .refused(DesignGate.refusalSentence(error))
        }
        return settled(proposal, projectURL: projectURL, status: .approved,
                       sentence: DesignGate.approvedConfirmation)
    }

    static func revert(_ proposal: DesignProposalStore.Proposal,
                       projectURL: URL,
                       jobManager: CompileJobManager) async -> DesignGateOutcome {
        do {
            try await ProposalPromotion.revert(
                proposal: proposal, projectURL: projectURL, jobManager: jobManager)
        } catch {
            return .refused(DesignGate.refusalSentence(error))
        }
        return settled(proposal, projectURL: projectURL, status: .rejected,
                       sentence: DesignGate.revertedConfirmation)
    }

    /// Not `async`, because `ProposalPromotion.finalize` is not: it removes a
    /// directory under `.maugham/design/` and moves no live byte, so it is the
    /// one verb here that is deliberately NOT gated on a running compile.
    static func finalize(_ proposal: DesignProposalStore.Proposal,
                         projectURL: URL) -> DesignGateOutcome {
        do {
            try ProposalPromotion.finalize(proposal: proposal, projectURL: projectURL)
        } catch {
            return .refused(DesignGate.refusalSentence(error))
        }
        // The status does not move — finalizing changes what can be undone, not
        // what shipped — so the re-read is about the rest of the record.
        return settled(proposal, projectURL: projectURL, status: .approved,
                       sentence: DesignGate.finalizedConfirmation)
    }

    /// The proposal as the store now holds it, and the announcement.
    ///
    /// `status` is the fallback's, for the one case the re-read can fail: the
    /// write landed and the file has since become unreadable. Handing back the
    /// caller's untouched copy there would be the stale-snapshot defect arriving
    /// through the error path, so the status this verb is known to have produced
    /// is patched in rather than left as it was.
    private static func settled(_ proposal: DesignProposalStore.Proposal,
                                projectURL: URL,
                                status: DesignProposalStore.Status,
                                sentence: String) -> DesignGateOutcome {
        MaughamEvent.postDesignProposalsChanged(projectURL: projectURL)
        if let reread = try? DesignProposalStore(projectURL: projectURL)
            .load(id: proposal.id) {
            return .done(reread, sentence: sentence)
        }
        var patched = proposal
        patched.status = status
        return .done(patched, sentence: sentence)
    }
}
