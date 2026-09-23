import Foundation

/// **What one person may write in this book** (P3 spec §2, §3.1).
///
/// P2 asked one question of a key — *is this somebody this book admits?* — and
/// that was the whole of the register. P3's question is the next one: admitted
/// to write WHAT. Three rungs, and the ladder is the spec's:
///
/// | rung | may sign |
/// |---|---|
/// | **reviewer** | annotations, their own annotations' edits, inbox rows |
/// | **author of some pieces** | everything, inside their pieces; the reviewer row everywhere else |
/// | **author of the whole book** | everything, project statements included |
///
/// **What it is not.** It is not a role NAME and no surface should ask it for
/// one: *reviewer* is a rung here, and the same word is an English noun in a
/// dozen places in this app. It is also not a decision — `Permit.allows` (P3a
/// Task 4) is the one table that turns a permit plus what was written plus the
/// actor key into *yes* / *no* / *cannot judge*.
///
/// **The fourth case is the one that matters most.** A permit is parsed from
/// strings in a signed file, and a build that meets a `role` or a `scope` it
/// does not recognise has met a LATER build's vocabulary. It must not guess,
/// and above all it must not guess *reviewer*: the global rule (spec §3.1,
/// §4.2) is that an unrecognised role, scope or event kind holds that person's
/// lines PENDING and never sets them aside — an older Mac must not quarantine
/// what a newer one would apply. `.unjudgeable` is how that reaches the table.
public enum Permit: Equatable, Hashable, Sendable {

    /// Annotations and inbox rows; never the manuscript.
    case reviewer

    /// Everything, inside `Scope`.
    case author(Scope)

    /// A role or scope string this build does not recognise, carried under its
    /// own name. Lines under it are held pending, never refused.
    case unjudgeable(raw: String)

    /// How much of the book an author's permit covers.
    public enum Scope: Equatable, Hashable, Sendable {
        /// The whole book, project statements included.
        case book
        /// These document ids and no others. **Legitimately empty**: *she may
        /// write what she starts* is a real state, and it is why the wire
        /// format spells `"pieces"` explicitly rather than hanging the
        /// distinction on an absent key.
        case pieces(Set<String>)
    }

    /// What every P2-era admission meant, and what a person with no events in
    /// their history still means (`PermitTimeline.bookAuthor`).
    public static let bookAuthor: Permit = .author(.book)

    // MARK: - The wire vocabulary

    /// The four strings a record or an event may carry, spelled once.
    ///
    /// Here rather than at the writers, because the reader that parses them and
    /// the verb that writes them (`RegistryAdmission.changePermit`, Task 7) must
    /// not be two opinions about how the word *author* is spelled — a mismatch
    /// would not fail, it would read as an unrecognised role and hold somebody's
    /// whole history pending.
    public static let authorRole = "author"
    public static let reviewerRole = "reviewer"
    public static let bookScope = "book"
    public static let piecesScope = "pieces"

    // MARK: - Reading one

    /// **The one parse**, from the three strings a `PersonRecord` or a
    /// `PermitEvent` carries.
    ///
    /// - A **missing scope** is `"book"` — what every P2-era record means, and
    ///   the reason the field is optional rather than defaulted on the record.
    /// - `"pieces"` **with no list** is the empty set, not the whole book.
    /// - **Anything else** — a role this build does not know, a scope this
    ///   build does not know — is `.unjudgeable`, under the raw word that was
    ///   not recognised.
    ///
    /// A `pieces` list under `"book"` is ignored rather than refused: it is
    /// meaningless there by the format's own definition, and a later build that
    /// gives it a meaning will say so with a scope word of its own.
    public static func parse(role: String, scope: String?, pieces: [String]?) -> Permit {
        let scopeWord = scope ?? bookScope
        guard scopeWord == bookScope || scopeWord == piecesScope else {
            return .unjudgeable(raw: scopeWord)
        }
        switch role {
        case Self.reviewerRole:
            return .reviewer
        case Self.authorRole:
            return scopeWord == piecesScope
                ? .author(.pieces(Set(pieces ?? [])))
                : .author(.book)
        default:
            return .unjudgeable(raw: role)
        }
    }

    /// The permit an event INSTALLS.
    ///
    /// The event's `kind` is deliberately not consulted here — whether a kind
    /// installs a permit at all is `PermitTimeline`'s question, and a revocation
    /// carries a role and a scope it does not mean to change.
    public init(event: PermitEvent) {
        self = Permit.parse(role: event.role, scope: event.scope, pieces: event.pieces)
    }

    /// Nothing can be decided from this permit, so lines under it are PENDING.
    public var isUnjudgeable: Bool {
        if case .unjudgeable = self { return true }
        return false
    }

    /// **Is this anything but an author of the whole book?** (P3b Task 1.)
    ///
    /// *Narrowing* is the one question a book's whole posture turns on — it is
    /// what `PermitTimeline.narrows` asks of every entry, what
    /// `TrustTable.hasNarrowingPermits` asks of every person, and what decides
    /// whether a verb about to write an event must carry an
    /// `UnsignedSnapshot`. It lives HERE, on the rung itself, so that a store
    /// or a surface deciding *is this a narrowing act* asks the permit layer
    /// rather than testing a permit against a literal rung (tripwire 47): the
    /// two answers drift the first time a rung is added, and the copy outside
    /// this file is the one that does not compile-error when it does.
    ///
    /// **`.unjudgeable` narrows.** A role word this build does not know is a
    /// permit a later build may have narrowed, and the whole point of that
    /// case is that we do not get to assume — the same reading
    /// `PermitTimeline.narrows` has had since the final fix wave's W1.
    public var narrows: Bool { self != .bookAuthor }

    // MARK: - The rungs a surface may offer (P3b Task 4)

    /// **What a control can ask the writer for**, and the one place a chosen
    /// one becomes a `Permit`.
    ///
    /// A surface must not build a permit out of the wire words itself: the
    /// spellings are this file's (`authorRole`, `piecesScope`), the parse is
    /// this file's, and a view assembling them is a second opinion about what
    /// *reviewer* is made of — which is the same failure tripwire 47 names, one
    /// step earlier. So the choice travels as a rung and comes back as a
    /// permit, and `Maugham/Views/PermitControl.swift` supplies nothing but the
    /// words the writer reads.
    ///
    /// Three cases and not four: `.unjudgeable` is a permit a LATER build
    /// wrote, and there is nothing for a control to offer about it. That is why
    /// `rung(of:)` answers an Optional.
    public enum Rung: String, CaseIterable, Identifiable, Sendable {
        /// Notes and captures; never the manuscript.
        case reviewer
        /// Everything, inside the pieces the writer picks — legitimately none.
        case somePieces
        /// Everything, everywhere: what every admission meant before P3.
        case wholeBook

        /// `Identifiable` here rather than retroactively at the control: a
        /// conformance a view module adds to another module's type is one a
        /// later build of THIS module can collide with.
        public var id: String { rawValue }
    }

    /// The permit a chosen rung installs. `pieces` is carried for every rung
    /// and used by one, so a writer changing their mind and changing it back
    /// does not lose the list on the way past.
    public static func permit(offering rung: Rung, pieces: Set<String> = []) -> Permit {
        switch rung {
        case .reviewer: return .reviewer
        case .somePieces: return .author(.pieces(pieces))
        case .wholeBook: return .author(.book)
        }
    }

    /// **The rung a permit IS**, or nil where no control can draw it — a role
    /// or scope word this build does not recognise. A surface meeting nil says
    /// so; drawing an unknown rung as a known one would offer to overwrite a
    /// permit the writer was never shown.
    public static func rung(of permit: Permit) -> Rung? {
        switch permit {
        case .reviewer: return .reviewer
        case .author(.pieces): return .somePieces
        case .author(.book): return .wholeBook
        case .unjudgeable: return nil
        }
    }

    // MARK: - The root

    /// **A root is an author of the whole book, unconditionally** (spec §2).
    ///
    /// It alone admits, revokes and changes a permit, and a book must not end
    /// up with no author — so an event that would give the root anything else
    /// is not a demotion this app performs, it is a file nobody should have
    /// written. `RegistryReader` asks this and LISTS such an event malformed
    /// (`MalformedRecord.Reason.eventDemotesARoot`); `TrustTable` answers the
    /// root's timeline as the default whatever the folder holds. Two guards for
    /// one rule, deliberately: the reader's is about the FILE — a `Registry`
    /// built any other way, in a test or from a later build's bytes, must not
    /// be able to talk this device out of its own root's authority.
    ///
    /// An unrecognised role reaches this as `.unjudgeable` and is refused with
    /// the rest. Holding the root's own lines pending would be the one case
    /// where *pending, never set aside* costs the writer their own book, and
    /// the root's permit is the maximum permit anyway: there is nothing a later
    /// build could widen it to.
    public static func contradictsARoot(_ event: PermitEvent) -> Bool {
        Permit(event: event) != .author(.book)
    }

    // MARK: - Writing one down

    /// **The three strings this permit is WRITTEN as** — `parse`'s inverse, and
    /// the reason it lives beside it (P3a Task 7).
    ///
    /// `RegistryAdmission.changePermit` takes the words rather than the value,
    /// because what a signed file carries is words; these exist so a SURFACE
    /// holding a `Permit` (P3b's pane, `DocumentStore.changePermit`) does not
    /// have to spell them a second time. `parse(role:scope:pieces:)` of these
    /// three answers `self` again for every case, which is what
    /// `PermitTableTests.test_everyPermitRoundTripsThroughItsOwnWords` pins.
    ///
    /// **`.unjudgeable` round-trips as an unrecognised ROLE**, whichever word
    /// was not recognised. That is lossy in one direction — an unknown *scope*
    /// comes back as an unknown role — and it is deliberate: nothing in this app
    /// constructs an unjudgeable permit to write, the value exists so a READER
    /// can hold a word it does not know, and the round trip that matters is that
    /// it stays unjudgeable rather than becoming a rung.
    public var wireRole: String {
        switch self {
        case .reviewer: return Permit.reviewerRole
        case .author: return Permit.authorRole
        case .unjudgeable(let raw): return raw
        }
    }

    public var wireScope: String {
        switch self {
        case .author(.pieces): return Permit.piecesScope
        case .reviewer, .author(.book), .unjudgeable: return Permit.bookScope
        }
    }

    /// Sorted, because two devices compare a signed record byte for byte and a
    /// `Set`'s iteration order is not a fact about the permit.
    public var wirePieces: [String] {
        if case .author(.pieces(let mine)) = self { return mine.sorted() }
        return []
    }

    /// **May a piece nobody has written in yet become theirs?** (spec §4.5.)
    ///
    /// The rung half of `PermitPartition.startsAPieceNobodyHasClaimed`, which
    /// is the rule that ENFORCES it and which adds the two facts a rung cannot
    /// carry: that the line is manuscript text signed by the person's own hand,
    /// and that nobody else has written the piece's text yet. It is here
    /// because *which rungs can start a piece* is a fact about the ladder, and
    /// the only other way for a surface to ask it is to test a permit against a
    /// literal rung — tripwire 47, one step early.
    ///
    /// A reviewer starts nothing (every manuscript line of theirs is refused
    /// wherever it lands). An author of the whole book has nothing to start —
    /// every piece is already theirs — so this is about the middle rung alone,
    /// which is exactly the rung the piece picker can legitimately be left
    /// empty for. `PermitTableTests` pins that the two agree.
    public var mayStartAPieceOfTheirOwn: Bool {
        if case .author(.pieces) = self { return true }
        return false
    }

    /// **The permit a person RECORD says they hold** — the current-state
    /// convenience, and the one spelling of reading it (P3b Task 5).
    ///
    /// It is here because the words on a record are this file's vocabulary and
    /// `Permit.parse` is this file's function: a surface assembling
    /// `Permit.parse(role: record.role, …)` for itself would be naming the
    /// permission table's own spelling outside the permit layer (tripwire 44),
    /// which is exactly what the admission sheet's first draft did and what the
    /// census refused.
    ///
    /// **It is not the check, and no reader may use it as one** (tripwire 43).
    /// A line is judged by the permit its signer held WHEN THEY WROTE IT, which
    /// is `PermitTimeline`'s answer over the events; this is what the record
    /// currently claims, which is what People & Devices draws on a row and what
    /// `recordBehindEvents` compares against the history. The two disagreeing
    /// is a real, detected state with a surface of its own.
    public static func permit(recordedIn record: PersonRecord) -> Permit {
        parse(role: record.role, scope: record.scope, pieces: record.pieces)
    }

    // MARK: - Comparing two

    /// **Does this permit allow everything `other` allows?**
    ///
    /// Asked by History alone, to say which way a change went: a NARROWING
    /// (*What they wrote before then stays in the book*) and a WIDENING
    /// (*Anything set aside before then stays set aside*) are the two halves of
    /// spec §5 and a surface that stated one of them over both would be telling
    /// the writer the opposite of what happened half the time.
    ///
    /// It is a partial order and says so: `.unjudgeable` covers nothing and is
    /// covered by nothing but itself, and two disjoint piece lists cover each
    /// other in neither direction. A caller that gets `false` both ways has a
    /// change that is neither wider nor narrower, and the honest sentence for
    /// one is the conservative half.
    ///
    /// It is NOT the permission check. `allows` is that, and it asks about one
    /// line in one class; this asks about two permits and nothing else.
    public func covers(_ other: Permit) -> Bool {
        switch (self, other) {
        case (.unjudgeable(let mine), .unjudgeable(let theirs)):
            return mine == theirs
        case (.unjudgeable, _), (_, .unjudgeable):
            return false
        case (.author(.book), _):
            return true
        case (.author(.pieces(let mine)), .author(.pieces(let theirs))):
            return theirs.isSubset(of: mine)
        case (.author(.pieces), .reviewer):
            return true
        case (.author(.pieces), .author(.book)):
            return false
        case (.reviewer, .reviewer):
            return true
        case (.reviewer, .author):
            return false
        }
    }
}

// MARK: - What was written

/// **What a line put in the book** (P3a Task 4).
///
/// Three things, because a book's storage has three kinds of writer-made line
/// and only one of them is an `Op`: the op log, a translation record, an inbox
/// row. They are one type rather than three arguments so that the table below
/// is a table — every question it is ever asked is one value of this.
public enum Written: Equatable, Hashable, Sendable {
    /// A line of a document's op log.
    case op(OpKind)
    /// A `TranslationRecord` in one language's translation stream.
    case translationRecord
    /// A captured row in the inbox.
    case inboxRow
}

/// **What a refusal took away**, in the vocabulary of spec §4.4's phrasebook.
///
/// Coarse on purpose. It is not a diagnosis, it is the noun in a sentence the
/// writer reads — *Sam's Mac wrote 2 changes to the manuscript, which a
/// reviewer can't* — so the arms are the six things §4.4 names, plus a last
/// resort for a combination that never occurs in a book anybody wrote.
public enum RefusedWhat: String, Equatable, Hashable, Sendable, CaseIterable {
    /// Words in a manuscript document.
    case manuscriptText
    /// Settling somebody's note: accept, reject, stet, triage, reopen, archive.
    case disposition
    /// **No `OpKind` produces this today**, and that is a fact about the design
    /// rather than an omission: a pass state lives on `StructureItem.passStates`
    /// in the unsigned manifest, and *roles guard the words, not the binder*
    /// (spec §2). It is here because §4.4's phrasebook names it and because
    /// signed structure is its own roadmap milestone — the day a pass state is
    /// an op, the word for refusing one already exists and means one thing.
    case passState
    /// Words in a statement — intent, visual language, lessons, first reader,
    /// an edition brief. A statement is an ordinary `Document`, so it is the
    /// STREAM and not the op kind that makes these words a statement.
    case statement
    /// A task op.
    case task
    /// A translation record.
    case translation
    /// Anything else — a checkpoint bookmark, or a combination of kind and
    /// stream that no writer's Mac produces.
    case other
}

/// **The answer** — yes, no with what was refused, or *I cannot judge this*.
///
/// The third arm is not a failure and must never be collapsed into either of
/// the others. It is the global rule of this whole milestone (spec §3.1, §4.2):
/// an unrecognised role, an unrecognised scope, an op kind from a later build,
/// a seal key this device cannot name — each holds its lines PENDING. An older
/// Mac must not quarantine what a newer one would apply, and must not apply
/// what it cannot read either.
public enum Allowed: Equatable, Hashable, Sendable {
    case yes
    case no(RefusedWhat)
    case cannotJudge
}

// MARK: - The table

extension Permit {

    /// The kinds, grouped by what they ARE — the left-hand column of spec §2.
    ///
    /// Public because the grouping is the reviewable half of this table: a
    /// reader checking the ladder against the code should be able to ask which
    /// group a kind is in without reading the permission logic around it.
    public enum WrittenGroup: Equatable, Hashable, Sendable, CaseIterable {
        /// Folds into the derived words. Exactly `Deriver.appliesToManuscript`.
        case manuscriptText
        /// Making a comment, a query, a suggestion or a craft note.
        case annotationCreation
        /// Editing or withdrawing an annotation. *Whose* annotation is a
        /// same-person rule and not a per-file one (spec §4.2): the table lets
        /// these through on the reviewer row, and `AnnotationDeriver` is what
        /// honours one only from the person who created the note.
        case ownAnnotation
        /// Settling a note — the writer's act, never a reviewer's.
        case disposition
        /// A ⌘S bookmark's breadcrumb.
        case checkpoint
        /// A task's life.
        case task
        /// A translation record.
        case translationRecord
        /// An inbox capture.
        case inboxRow
        /// A kind from a later build. Nothing may be decided about it.
        case unreadable
    }

    /// What was written, as a group.
    public static func group(of what: Written) -> WrittenGroup {
        switch what {
        case .translationRecord: return .translationRecord
        case .inboxRow: return .inboxRow
        case .op(let kind): return group(of: kind)
        }
    }

    /// **The one exhaustive switch over `OpKind`** (spec §4.2). No `default:`:
    /// a kind added by a later build of this app fails to compile here until
    /// somebody decides who may sign it.
    ///
    /// Manuscript text is **asked of `Deriver.appliesToManuscript`** and not
    /// restated. A second opinion about which ops become words would be free to
    /// drift from the one the deriver actually folds, and the drift would be
    /// silent in the worst direction: a kind that moves the prose but is not in
    /// this copy of the list would be waved through on the reviewer row.
    public static func group(of kind: OpKind) -> WrittenGroup {
        if Deriver.appliesToManuscript(kind) { return .manuscriptText }
        switch kind {
        case .typingBurst, .bootstrap, .externalEdit, .checkpointRestore,
             .claudeAccept, .claudeAcceptRevert, .claudeReject:
            // Unreachable — every one of these is manuscript text above — and
            // listed anyway, for two reasons. It keeps the switch exhaustive
            // without a `default:`, which is the compile-forcing gate. And the
            // last three are ALSO dispositions: accepting, rejecting and
            // un-accepting a suggestion each settle somebody's note *and* move
            // the words. Both readings land in the same place — they are the
            // piece author's to sign, never a reviewer's and never the
            // assistant's — so nothing turns on which one wins, and manuscript
            // text wins because that is the classifier the app already has.
            return .manuscriptText
        case .claudeComment, .claudeQuery, .claudeCraftNote, .claudeSuggestion:
            // The `claude`-prefixed names are legacy: `Document.addAnnotation`
            // mints exactly these four for every annotation anybody makes, from
            // the review toolbar, from MCP and from the phone alike.
            return .annotationCreation
        case .annotationEdit, .annotationWithdraw:
            return .ownAnnotation
        case .claudeArchive, .annotationReopen, .annotationStet, .annotationTriage:
            return .disposition
        case .checkpoint:
            return .checkpoint
        case .taskCreate, .taskStatusChange, .taskPriorityChange,
             .taskParentChange, .taskBodyEdit, .taskArchive:
            return .task
        case .unknown:
            return .unreadable
        }
    }

    /// **May this be written here, by this key?** — the ladder of spec §2, made
    /// a function.
    ///
    /// Three things must be true before there is a question at all, and each of
    /// them answers `.cannotJudge` rather than guessing:
    ///
    /// - **An unjudgeable permit.** A role or scope word this build does not
    ///   know. Holding the lines pending is the whole point of `.unjudgeable`.
    /// - **An unreadable kind.** `OpKind.unknown` under *every* permit, the
    ///   book author's included: an older build must not apply what it cannot
    ///   read, and must not refuse it either.
    /// - **No actor.** `actor` is optional because `TrustTable` genuinely
    ///   cannot always name one — an unrecorded key, a key two people claim, a
    ///   later build's actor word. **Nil must never default to `.author`**:
    ///   that would hand the widest of the four keys to a signature nobody can
    ///   attribute, which is the one mistake that turns this whole table into
    ///   decoration.
    ///
    /// Then the actor narrows *within* the person's permit (spec §2's last
    /// paragraph). The narrowing never widens: `assistant` is the reviewer row
    /// on every device including the root's, because *MCP never mutates
    /// manuscript text* is a sentence of the constitution and not a UI
    /// courtesy.
    public func allows(
        _ what: Written, in documentClass: DocumentClass, actor: DeviceActor?
    ) -> Allowed {
        let group = Permit.group(of: what)

        if isUnjudgeable { return .cannotJudge }
        if group == .unreadable { return .cannotJudge }
        guard let actor else { return .cannotJudge }

        // **The second switch** (spec §4.2) — the four keys, narrowing.
        let person: Permit
        switch actor {
        case .author:
            // The writer's own hand and the automations of it: the person's
            // permit, whatever it is.
            person = self
        case .assistant:
            // Anything through MCP. The reviewer row, always, under every
            // person — the root's key included.
            person = .reviewer
        case .translator:
            // The pipeline and `write_translation`: translation records, and
            // nothing else, anywhere.
            guard group == .translationRecord else {
                return .no(Permit.refused(group, documentClass))
            }
            person = self
        case .maugham:
            // The app on nobody's instruction: the task priority rebalance,
            // and nothing else, anywhere.
            guard what == .op(.taskPriorityChange) else {
                return .no(Permit.refused(group, documentClass))
            }
            person = self
        }

        return person.row(group, documentClass)
    }

    /// One row of the ladder: what this permit may write, in this class.
    private func row(_ group: WrittenGroup, _ documentClass: DocumentClass) -> Allowed {
        if case .unplaceable = documentClass { return unplacedRow(group) }
        switch group {
        case .annotationCreation, .ownAnnotation, .inboxRow:
            // **The reviewer row**, and therefore everybody's: the rungs above
            // contain it. A reviewer may annotate any piece of the book and
            // capture to the inbox; an author may do both as well.
            return .yes
        case .task:
            return maySignTasks(in: documentClass) ? .yes : .no(.task)
        case .manuscriptText, .disposition, .checkpoint, .translationRecord:
            return authors(documentClass) ? .yes : .no(Permit.refused(group, documentClass))
        case .unreadable:
            // Unreachable: `allows` answers `.cannotJudge` before it gets here.
            return .cannotJudge
        }
    }

    /// **The row for a statement this build cannot place** (`DocumentClass.unplaceable`).
    ///
    /// One question decides every cell: *could knowing where this statement sits
    /// change the answer?* Where it could not, the answer stands — holding a
    /// line pending forever, against a question that has no second answer, is
    /// not caution. Where it could, the line is **pending**, because the build
    /// that understands the scope word might place it somewhere this person may
    /// write, and an older Mac must not set aside what a newer one would apply.
    ///
    /// - **A book author** may write every class, so the placement is not a
    ///   question she has: `.yes`, exactly as anywhere else.
    /// - **Annotations and inbox rows** are the reviewer row, which every class
    ///   grants to everybody: `.yes`, for every rung.
    /// - **A reviewer's tasks and translations** are refused in every class
    ///   alike, noun and all, so they are refused here.
    /// - **Everything else** turns on the placement and is held.
    ///
    /// An author of some pieces with an EMPTY list is held a little wider than
    /// she strictly needs to be — she has no piece this could land in, so her
    /// translation cell would be uniform too — and that is deliberate: pending
    /// is always the safe side of this rule, and a degenerate case is not worth
    /// a second arm that could disagree with the first.
    private func unplacedRow(_ group: WrittenGroup) -> Allowed {
        switch self {
        case .unjudgeable:
            // Unreachable: `allows` answers `.cannotJudge` before it gets here.
            return .cannotJudge
        case .author(.book):
            return .yes
        case .reviewer:
            switch group {
            case .annotationCreation, .ownAnnotation, .inboxRow:
                return .yes
            case .task:
                return .no(.task)
            case .translationRecord:
                return .no(.translation)
            case .manuscriptText, .disposition, .checkpoint, .unreadable:
                return .cannotJudge
            }
        case .author(.pieces):
            switch group {
            case .annotationCreation, .ownAnnotation, .inboxRow:
                return .yes
            case .manuscriptText, .disposition, .checkpoint, .task,
                 .translationRecord, .unreadable:
                return .cannotJudge
            }
        }
    }

    /// **Whether this permit authors this class** — the scope test, asked once.
    ///
    /// A book author authors everything. An author of some pieces authors a
    /// piece in her list, that piece's own statement and that piece's
    /// translations — and nothing without a piece behind it, which is what
    /// keeps her off the project's statements. A reviewer authors nothing.
    public func authors(_ documentClass: DocumentClass) -> Bool {
        switch self {
        case .reviewer, .unjudgeable:
            return false
        case .author(.book):
            return true
        case .author(.pieces(let mine)):
            guard let piece = documentClass.piece else { return false }
            return mine.contains(piece)
        }
    }

    /// **Can this permit refuse anything at all, whatever the line says and
    /// wherever the stream sits?** (P3a Task 5's fix round 1, I1 and I3.)
    ///
    /// True for exactly one pair — an author of the whole book, writing with
    /// her own hand — and that is the pair every book on disk today is made of.
    /// A reader that has it can skip the two expensive questions before it
    /// asks them: **what** the line was (a JSON parse of bytes the element
    /// decoder is about to parse again) and **where** the stream sits (a
    /// manifest read and decode). Neither can change the answer, so paying for
    /// them would be paying to be told `.yes`.
    ///
    /// It lives here, beside the table, rather than in the partition: the fact
    /// it states is the table's — *this permit's row is `.yes` in every class
    /// for every group* — and restating it one file over is how a skip and the
    /// table it is skipping come to disagree in silence.
    /// `PermitTableTests` pins it against the grid, cell by cell.
    ///
    /// **The one thing it steps over is `OpKind.unknown`.** `allows` answers
    /// `.cannotJudge` for an unreadable kind under every permit, this one
    /// included, so a book author's own line carrying a kind from a later
    /// build would otherwise be HELD. That is the wrong answer for her: she
    /// may write everything, so there is no narrower build for the hold to be
    /// protecting, and P2 already had an answer for such a line — `OpKind`'s
    /// own `.unknown` decode, which the deriver folds inertly. So the skip
    /// stands and her unknown kind is left to `parse` exactly as before P3
    /// (neutrality). Where a line is being JUDGED at all — a narrowed actor,
    /// or a permit that is not the whole book — `.cannotJudge` applies as
    /// written and the line is held.
    public func allowsEverything(actor: DeviceActor?) -> Bool {
        guard actor == .author else { return false }
        if case .author(.book) = self { return true }
        return false
    }

    // MARK: - What the LOAD wrote, whoever an older build had sign it

    /// **The actor a line is judged under**, which is the actor that signed it
    /// except where the line is one the LOAD PATH emits on its own account
    /// (final fix wave, W3(a); whole-branch review F3).
    ///
    /// **The released-build problem.** P3a Task 8 moved five emissions to this
    /// device's AUTHOR key — `Bootstrap`'s opening op, the two pending-recovery
    /// folds, the task-anchor burst and the `taskCreate` beside it — because
    /// none of them is the act of whoever opened the document; they are the
    /// writer's own words arriving through whichever door happened to be first.
    /// That fixed what this build WRITES. It said nothing about what v0.37
    /// through v0.40 already wrote: on those builds the emission took the
    /// LOADING actor's key, so any book where an MCP tool or the translation
    /// pipeline opened a never-opened document, or opened one after a quit
    /// mid-burst, holds `assistant-…` / `translator-…` files containing these
    /// kinds. They verify (`.mine` or `.admitted`), they are manuscript text or
    /// a task, and the actor rows refuse both to those two keys — so without
    /// this rule the permit partition sets them aside on the first load, in
    /// every rooted book, events or not. A refused `bootstrap` is a document
    /// whose OPENING op is gone: it derives empty, and the first autosave
    /// writes that empty render over the manuscript.
    ///
    /// **So: judged under the person's permit, without the actor narrowing.**
    /// The load's own emissions are the author's, whoever an older build had
    /// sign them. A reviewer's device's assistant-signed bootstrap is still
    /// refused — it is judged under the REVIEWER permit, which is correct, and
    /// is why this widens the ACTOR rather than the permit.
    ///
    /// **It is permanent and it is NOT gated on `hasNarrowingPermits`.** A
    /// time-boxed grandfather would mean the first reviewer P3b creates
    /// un-applies every such bootstrap in the book, which is the same defect
    /// arriving later. The constitution's first must — *the words are safe* —
    /// outranks the purity of the actor row.
    ///
    /// **Two kinds, and the third is a STOP** (reported; see the wave's
    /// report). `.bootstrap` has exactly one emitter in the tree
    /// (`Bootstrap.emitBootstrap`) and `.taskCreate` under a non-author actor
    /// has exactly one (`Document.rebuildTasksCache`'s anchor breadcrumb — the
    /// other two `.taskCreate` emitters are the writer's own pane acts, reached
    /// only from editor surfaces), so both are load emissions by KIND alone.
    /// The pending-recovery folds and the anchor burst are `.typingBurst`, and
    /// the rule is not widened to reach them.
    ///
    /// **Since P3b Task 3 those three DO write a `synthesisSource`**
    /// (`.pendingRecovery`, `.anchorSplice`) — and the rule is still not
    /// widened, which is the point worth stating rather than the change. Two
    /// reasons, either sufficient. It only helps lines written AFTER it ships,
    /// so every v0.37–v0.40 line the census is about is still unlabelled; and a
    /// field the assistant writes is a field the assistant can write, so a rule
    /// keyed on it would make *MCP never mutates manuscript text* rest on the
    /// assistant's own good manners. An assistant-signed ordinary `typingBurst`
    /// therefore stays REFUSED, which is the constitution's sentence about MCP
    /// and the manuscript. The label is provenance — it is what `LoadBurstCensus`
    /// reads and what History can say — and it reaches no table: `PermitPartition
    /// .writtenOp` decodes a KIND and nothing else.
    ///
    /// **Nil stays nil.** A key this register cannot attribute names no actor,
    /// and handing it the widest of the four would be the one mistake that
    /// turns the table into decoration (see `allows`). Widening nobody to the
    /// author is not a grandfather, it is a hole.
    ///
    /// **And the waiver is the two DOORS' actors, not every actor that is not
    /// the author** (P3b Task 3). What this rule is for is a document opened
    /// through a door that is not the writer's editor: MCP, which loads
    /// `.assistant`, and the translation pipeline, which loads `.translator`.
    /// Those are the only two actors a v0.37–v0.40 load could have signed an
    /// emission with, because they are the only two a `Document.load` names.
    /// `.maugham` is not a door — it is the app acting on nobody's instruction,
    /// and the single thing the table lets it sign is the task rebalance's
    /// `taskPriorityChange`. Waiving the actor for a `.maugham`-signed
    /// `taskCreate` would hand the app's own key a row it has never held, on
    /// the strength of a shape nothing has ever written; judged as `.maugham`'s
    /// it is refused, which is the honest answer to a line that should not
    /// exist.
    public static func actorJudging(
        _ what: Written, signedBy actor: DeviceActor?
    ) -> DeviceActor? {
        guard let actor, isADoorTheLoadIsOpenedThrough(actor),
              isALoadEmission(what) else { return actor }
        return .author
    }

    /// The two actors a `Document.load` can name that are not the writer's own
    /// hand — spelled as an exhaustive switch for `isALoadEmission`'s reason: a
    /// fifth actor has to be decided here rather than inherited.
    private static func isADoorTheLoadIsOpenedThrough(_ actor: DeviceActor) -> Bool {
        switch actor {
        case .assistant, .translator: return true
        case .author, .maugham: return false
        }
    }

    /// **Is this a line the load path emits on its own account?** — the two
    /// kinds `actorJudging` re-attributes, spelled once so the rule is
    /// census-visible rather than inlined at the partition.
    ///
    /// Written as an exhaustive switch over `OpKind` rather than a membership
    /// test, so a later kind that the load starts emitting is a compile error
    /// here and has to be decided rather than defaulted.
    public static func isALoadEmission(_ what: Written) -> Bool {
        guard case let .op(kind) = what else { return false }
        switch kind {
        case .bootstrap, .taskCreate:
            return true
        case .typingBurst, .externalEdit, .checkpointRestore, .checkpoint,
             .claudeComment, .claudeQuery, .claudeCraftNote, .claudeSuggestion,
             .claudeAccept, .claudeAcceptRevert, .claudeReject, .claudeArchive,
             .annotationEdit, .annotationWithdraw, .annotationReopen,
             .annotationStet, .annotationTriage, .taskStatusChange,
             .taskPriorityChange, .taskParentChange, .taskBodyEdit,
             .taskArchive, .unknown:
            return false
        }
    }

    /// **Whether this permit may sign a task op here.**
    ///
    /// Tasks are the one thing an author of some pieces may write outside her
    /// pieces: *on the project stream, task ops* (spec §2). Not the reviewer
    /// row — a reviewer signs no task anywhere.
    public func maySignTasks(in documentClass: DocumentClass) -> Bool {
        switch self {
        case .reviewer, .unjudgeable:
            return false
        case .author:
            if case .projectStream = documentClass { return true }
            return authors(documentClass)
        }
    }

    /// The noun for a refusal: what the group was, refined by where it landed.
    ///
    /// The stream makes exactly one difference, and it is the one §4.4's
    /// phrasebook needs: words written into a statement's own op log are a
    /// statement, not a manuscript. A statement is an ordinary `Document` and
    /// its ops are `typingBurst`s like any other, so without this the writer
    /// would be told somebody wrote in their manuscript when what happened was
    /// an edit to the book's intent.
    static func refused(_ group: WrittenGroup, _ documentClass: DocumentClass) -> RefusedWhat {
        let onAStatement: Bool
        switch documentClass {
        case .pieceStatement, .projectStatement, .unplaceable:
            // `.unplaceable` is a statement whose SUBJECT is unreadable, not a
            // stream of unknown kind: if it is refused at all, *a statement* is
            // the true word for what was refused.
            onAStatement = true
        case .piece, .projectStream, .translation, .inbox:
            onAStatement = false
        }
        switch group {
        case .manuscriptText:
            return onAStatement ? .statement : .manuscriptText
        case .disposition:
            return onAStatement ? .statement : .disposition
        case .checkpoint:
            return onAStatement ? .statement : .other
        case .task:
            return .task
        case .translationRecord:
            return .translation
        case .annotationCreation, .ownAnnotation, .inboxRow, .unreadable:
            return .other
        }
    }
}
