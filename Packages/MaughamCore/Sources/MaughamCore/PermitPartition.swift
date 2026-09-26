import Foundation

/// **What a permit costs a file, line by line** (P3 spec §4.3).
///
/// `RevocationSplit` is the precedent and the shape: a pure function over a
/// walk's own `Verification`, run where the walk's answer and the registry's
/// answer are both in hand, and **before the parse** — because a line this
/// refuses must never reach the element decoder, and a line it holds must
/// never reach the document.
///
/// Three rules, and each one is a ruling rather than an implementation choice:
///
/// - **Line by line** (spec §1, amending parent §4.9's *quarantined whole*).
///   A refused line takes its neighbours nowhere: a reviewer's notes in the
///   same sealed span as her refused paragraph are applied, because a note is
///   something she may write and a paragraph is not.
/// - **As of the line** (spec §3.4). The permit asked is the one that held
///   when the line was written, which `PermitTimeline` answers off
///   `PermitMark`'s chain positions. A demotion does not reach back and a
///   promotion is not a pardon.
/// - **Unjudgeable is PENDING, never set aside** (spec §3.1, §4.2). A later
///   build's op kind, a role or scope word this one does not know, a key no
///   device record names an actor for: held, not refused. An older Mac must
///   never quarantine what a newer one would apply.
///
/// **Which lines it judges at all.** Only a line whose covering seal is a key
/// this device calls `.mine` or `.admitted`. Everything else is left exactly
/// as the walk found it: unsigned history still applies (decision B3, P1's
/// whole world), a stranger's span is still held, a revoked or retired key's
/// is still refused in its own words, and a file with no seal this device can
/// attribute — a legacy tail, an unsigned device's — is not judged at all.
/// Widening past that would be judging a line by a `device` string its own
/// writer chose, which proves nothing.
public enum PermitPartition {

    // MARK: - What the caller has to work out first

    /// §4.5's document-level fact: **has a book author written this piece's
    /// text?**
    ///
    /// An author of some pieces writing in a piece that is in nobody's scope
    /// is the *she started something new* case, and it is a question rather
    /// than a violation — her lines are held until the root says whose the
    /// piece is. Where a book author HAS written the piece's text, the piece
    /// is theirs and her lines are refused (spec §4.5).
    ///
    /// It is a fact about the DOCUMENT, not about one file, so the caller
    /// computes it after classifying every file of the docId and hands the
    /// answer in. Pending→refused on a later load is harmless (nothing was
    /// applied); refused→pending must never happen, which is why the answer is
    /// *a book author has written it*, a fact that only ever becomes more
    /// true.
    public enum UnownedPiece: Equatable, Hashable, Sendable {
        /// Nobody holding an author-of-the-whole-book permit has applied a
        /// manuscript-text line in this document — an opening (`bootstrap`)
        /// is not one (Option A; see `bookAuthorWroteManuscriptText`).
        case nobodyHasWrittenItsText
        /// Somebody has, so the piece is theirs.
        case aBookAuthorHasWrittenItsText
    }

    /// **What one line was**, or nil where the permit table judges nothing
    /// about it.
    ///
    /// A parameter rather than a hard-coded `Op` decode because the same
    /// partition runs over three streams: the op log, the translation sidecars
    /// and the inbox manifests, whose lines are not `Op`s at all. Nil means
    /// *not something this table has an opinion about* — a seal line, or a
    /// line that does not parse, which is `JSONLAppendStore.parse`'s to report
    /// and never this function's to refuse.
    public typealias WrittenDecoder = (Data) -> Written?

    /// The op log's decoder: the `kind` field and nothing else.
    ///
    /// The read itself is `Op.kind(ofLine:)`'s, which is where a raw op line's
    /// header fields are taken apart. It is not spelled here because `Permit*`
    /// is in the population of the census that keeps one opinion about what a
    /// signature covers, and that census bans the serializer's name in these
    /// files outright (tripwire 42, `RegistryCanonicalCensusTests`).
    ///
    /// An unrecognised kind is `.unknown`, which the table holds PENDING; a
    /// line with no `kind` at all is nobody's to refuse and answers nil.
    @Sendable public static func writtenOp(_ line: Data) -> Written? {
        Op.kind(ofLine: line).map(Written.op)
    }

    // MARK: - The partition

    /// Judge every applied line of one file and answer the walk again, with
    /// the lines this permit refuses **quarantined** and the ones it cannot
    /// judge **pending**.
    ///
    /// - Parameters:
    ///   - verification: the walk, AFTER `RevocationSplit` has had its say.
    ///     The two are run in order and never folded: a revocation is a
    ///     verdict about a whole key, this is a permit about one line.
    ///   - documentClass: what this stream is, resolved once per docId by a
    ///     caller that has the manifest. `classify` works per FILE and has
    ///     none.
    ///   - streamKey: `PermitMark.stream(of:)`'s answer for this file — never
    ///     rebuilt here, because a stream outlives its filenames and one
    ///     spelling is what makes a rotated segment and the tail it came out
    ///     of the same stream.
    ///   - fileSegmentDigest: the digest a `.mzseg` container CARRIES and that
    ///     VERIFIED, nil for a tail and for a container that did not hold
    ///     together. A segment that did not settle whole contributes no digest
    ///     and its lines therefore judge NEW.
    ///   - trust: the one table. The permit, the actor and the person are all
    ///     lookups on it (tripwire 39: no parallel trust table).
    ///   - decoding: see `WrittenDecoder`.
    ///   - unowned: §4.5's document-level fact, **as a closure so it is never
    ///     computed for a book that does not need it**. It is asked at most
    ///     once per file, and only where a scoped author's own hand has
    ///     written manuscript text in a piece outside her scope — which
    ///     requires events in the registry, so no existing book pays for it.
    ///     (`RevocationSplit.partition`'s `highestOpIdSeen` is the same shape
    ///     for the same reason.)
    ///   - startedBy: the piece's recorded starter (`StructureItem.startedBy`),
    ///     for Option A — asked at most once per file, and only where one of
    ///     THIS writer's own lines reached §4.5's hold. Nil (the default, and
    ///     a piece made before this build) is today's rule: held everywhere.
    ///
    /// **Neutral by construction for a book with no events.** Every admitted
    /// person's timeline is then one entry — author of the whole book — and
    /// the only refusals left are the actor rows, which narrow what the
    /// assistant, the translator and the task rebalance may sign whatever the
    /// person's permit says.
    public static func partition(
        of verification: OpLogChain.Verification,
        class documentClass: () -> DocumentClass,
        streamKey: String,
        deviceSlug: String? = nil,
        fileSegmentDigest: String?,
        trust: TrustTable,
        settledByKey: String? = nil,
        decoding: WrittenDecoder = writtenOp,
        recordingAmendmentsInto amendments: AmendmentPermits? = nil,
        unowned: () -> UnownedPiece,
        startedBy: () -> String? = { nil }
    ) -> OpLogChain.Verification {
        guard judgesAnything(trust) else { return verification }
        let lines = verification.lines
        guard !lines.isEmpty else { return verification }
        // Past every early exit: this file's lines are about to be examined.
        walkObserverForTesting?()
        let keys = attributableKeys(
            of: lines, trust: trust, settledByKey: settledByKey,
            namedBy: deviceSlug)
        guard !keys.isEmpty else { return verification }
        let governing = governingEntries(
            forKeys: Set(keys.values), lines: lines,
            streamKey: streamKey, fileSegmentDigest: fileSegmentDigest,
            trust: trust)

        var refusing: [Int: OpLogChain.QuarantineCause] = [:]
        var holding: [Int: String] = [:]
        // Both asked at most once per file, and only where a line's own
        // (permit, actor) pair makes the answer turn on them. Resolving a
        // class reads and decodes a manifest; answering `unowned` classifies
        // the document's other files again. A book whose people are authors of
        // the whole book pays for neither.
        var resolvedClass: DocumentClass?
        var unownedAnswer: UnownedPiece?
        // Option A's starter, read at most once per file and only where one of
        // this writer's own lines reached §4.5.
        var startedByAnswer: String??
        // **Is the governing permit of an amendment line worth writing down?**
        // (fix round 1; narrowed by the final fix wave's W1.) Only where
        // somebody in this book is NARROWED: where every permit is *author of
        // the whole book* — which includes every book whose only events are
        // P3a's own admissions — the answer a deriver would look up is the
        // answer it already gets by asking the table today, and recording it
        // would put a decode on every line of every load for nothing. See
        // `AmendmentPermits` and `TrustTable.hasNarrowingPermits`.
        let recordAmendments = amendments != nil && trust.hasNarrowingPermits

        for (index, line) in lines.enumerated() {
            guard isApplied(line), line.kind == .op,
                  let key = keys[index],
                  let entry = governing[key]?[index]
            else { continue }
            let actor = actor(ofSealKey: key, trust: trust, deviceSlug: deviceSlug)
            // **The skip, before the two expensive questions** (fix round 1,
            // I1 and I3). A permit that can refuse nothing does not need to be
            // told what the line was — a JSON parse of bytes `parse` is about
            // to parse again — nor where the stream sits. `Permit
            // .allowsEverything` is the table's own answer, asked rather than
            // restated; see it for what it does with an unreadable kind.
            //
            // **A book with events pays the decode anyway**, because the line
            // whose permit most needs recording is exactly one this skip would
            // step over: an AUTHOR's edit of somebody else's note is
            // `allowsEverything`, and it is her later demotion that would
            // otherwise reach back and un-do it.
            // **`judging`, never `permit`** (P3b smoke find F9): the entry's
            // permit read as having held any piece a later answer settled.
            let permit = entry.judging
            let skip = permit.allowsEverything(actor: actor)
            if skip, !recordAmendments { continue }
            guard let what = decoding(line.bytes) else { continue }
            if recordAmendments, Permit.group(of: what) == .ownAnnotation,
               let opId = RevocationSplit.opId(ofLine: line.bytes) {
                amendments?.record(opId, permit)
            }
            if skip { continue }
            let documentClass = resolvedClass ?? documentClass()
            resolvedClass = documentClass
            // **The load's own emissions are the author's, whoever an older
            // build had sign them** (final fix wave, W3(a)). Released builds
            // v0.37–v0.40 signed `bootstrap` and the anchor `taskCreate` with
            // whichever actor opened the document, so a book where MCP or the
            // pipeline opened a never-opened piece holds assistant-signed lines
            // the actor rows refuse — and a refused `bootstrap` is a document
            // whose opening op is gone, deriving empty under the first autosave.
            //
            // **Applied HERE and not inside `allows`**, which was tried and is
            // wrong: `allows` is the ladder of spec §2, `PermitTableTests`
            // writes it out cell by cell, and a grandfather folded into it
            // would make eleven of those cells stop meaning what they say. This
            // is a rule about which actor a LINE is judged under — an input to
            // the table, decided by the reader that holds the line. The
            // partition is the only reader that can meet a load emission under
            // a narrowed actor at all: `LocalWritePermit` asks as `.author`,
            // the ownership rule asks about a disposition, and
            // `answersWholeFile` asks about a translation record or an inbox
            // row. See `Permit.actorJudging`, which is also where the
            // `typingBurst` arm is explained and why it is not built.
            let judging = Permit.actorJudging(what, signedBy: actor)
            switch permit.allows(what, in: documentClass, actor: judging) {
            case .yes:
                continue
            case .cannotJudge:
                holding[index] = trust.person(forSealKey: key)
            case let .no(refused):
                if permit.startsAPieceNobodyHasClaimed(
                    what, in: documentClass, actor: judging) {
                    let answer = unownedAnswer ?? unowned()
                    unownedAnswer = answer
                    if answer == .nobodyHasWrittenItsText {
                        // **Her own words, on her own Mac** (P3c plan 2,
                        // Option A, ruling OA-3). A line this writer signed
                        // — on this Mac or on another of hers — in a piece
                        // one of her own devices STARTED is applied here, and
                        // nowhere else: every other Mac holds it and the root
                        // is asked, exactly as below. `trust.isThisWriters`
                        // is asked first because it is a lookup; the starter
                        // is a manifest read and is asked only after it.
                        if appliesOnItsWritersOwnMac(
                            key: key, trust: trust, class: documentClass,
                            startedBy: {
                                if let known = startedByAnswer { return known }
                                let read = startedBy()
                                startedByAnswer = .some(read)
                                return read
                            }) {
                            continue
                        }
                        let holder = trust.person(forSealKey: key)
                        holding[index] = holder
                        // **Which of the two holds this is** (P3b Task 7,
                        // finding B). `.cannotJudge` above holds under the
                        // same string, and the two want opposite sentences.
                        // Recorded rather than re-derived: everything this
                        // arm turned on — the permit, the actor, the class,
                        // the `Written` — is gone by the time a surface asks.
                        // See `AmendmentPermits.recordStartedAPiece`.
                        amendments?.recordStartedAPiece(holder)
                        // **And whether she STARTED it at all** (Q1): the
                        // permit layer's one answer, so the question can be
                        // put truthfully after a deliberate removal.
                        if let piece = documentClass.piece,
                           trust.timeline(forSealKey: key)
                            .wasTakenFromThem(piece: piece) {
                            amendments?.recordKeptWritingInATakenPiece(holder)
                        }
                        continue
                    }
                }
                // **The actor the refusal NAMES is the one that judged it**,
                // not always the one that signed. For every kind but the two
                // load emissions those are the same word. For a load emission
                // they are not, and naming the signer would put a sentence in
                // the writer's `.lines` record that is simply untrue — *written
                // by the assistant, which never changes the manuscript*, about
                // a line the assistant row did not refuse. What refused it is
                // the person's own permit, and that is what it should say.
                refusing[index] = .notPermitted(
                    person: trust.person(forSealKey: key),
                    what: refused,
                    afterMark: changedAnExistingPermit(entry),
                    actor: judging?.rawValue)
            }
        }

        // **A seal travels with the op immediately before it**, exactly as in
        // `RevocationSplit`: a seal carries nothing of its own — no op id, no
        // kind, nothing the table has an opinion about — and the span it
        // closes ends at the line above it. Leaving a signature applied over a
        // line that has just been taken out of the book would file it under a
        // position its own op no longer has.
        for (index, line) in lines.enumerated() where line.kind == .seal {
            guard index > 0, lines[index - 1].kind == .op,
                  let cause = refusing[index - 1] else { continue }
            refusing[index] = cause
        }

        guard !refusing.isEmpty || !holding.isEmpty else { return verification }
        return OpLogChain.repartitioned(
            verification, refusing: refusing, holding: holding)
    }

    /// **The partition, for a reader holding a FILE** — the one door every
    /// stream reaches it by (P3a Task 6).
    ///
    /// `partition` above takes a stream key and a decoder because it is pure;
    /// every real caller has a URL instead, and turning one into the other is
    /// `PermitMark.stream(of:)`'s job and nobody else's. Spelling that hop once
    /// is what keeps the op log's three call sites, the translation sidecars'
    /// and the inbox manifest's from growing five opinions about which stream a
    /// file belongs to — and a mark filed under a name no reader looks up fails
    /// silently, by judging everything new.
    ///
    /// **Nil `judging` is the explicit *do not judge*** — the keyless readers,
    /// which pass no table either.
    public static func partition(
        of verification: OpLogChain.Verification,
        file url: URL,
        judging judge: PermitJudge?,
        fileSegmentDigest: String? = nil,
        settledByKey: String? = nil
    ) -> OpLogChain.Verification {
        guard let judge, let stream = PermitMark.stream(of: url)
        else { return verification }
        // **The unsigned door, before everything below it** (P3b Task 2,
        // Denver's ruling of 2026-09-20). A file this register can name no key
        // for reaches none of the rules that follow — `attributableKeys`
        // answers empty for it by the same two facts `Verification
        // .unattributable` is made of — so this is not a branch taken instead
        // of the partition, it is the only thing there ever was to do with
        // such a file. Spelled at the FILE-level door so every stream reaches
        // it by the same call the permit partition already reaches: the op
        // log's two classify paths, `TranslationStore.loadMerged` and
        // `JSONLAppendStore.loadVerifiedStrict`.
        if verification.unattributable {
            return holdingUnsignedLines(
                of: verification, stream: stream,
                fileSegmentDigest: fileSegmentDigest, judge: judge)
        }
        // **A stream whose every line is ONE thing can be answered whole —
        // when its own writer is one the table allows that thing** (fix round
        // 2's R3, narrowed in fix round 3). See `answersWholeFile`.
        if let what = judge.everyLineIs,
           answersWholeFile(
            verification.lines, is: what, class: judge.context.documentClass,
            trust: judge.trust, deviceSlug: stream.deviceSlug) {
            return verification
        }
        return partition(
            of: verification, class: judge.context.documentClass,
            streamKey: stream.key, deviceSlug: stream.deviceSlug,
            fileSegmentDigest: fileSegmentDigest,
            trust: judge.trust, settledByKey: settledByKey,
            decoding: judge.decoding,
            recordingAmendmentsInto: judge.context.amendments,
            unowned: judge.context.unowned,
            startedBy: judge.context.startedBy)
    }

    // MARK: - The unsigned door (P3b Task 2)

    /// **A file nothing signs, judged against the photograph the book took the
    /// first time anybody was narrowed** — the close of P1's last open door.
    ///
    /// The rule is `UnsignedSnapshot`'s and is not restated here: a line at or
    /// before the snapshot is **exactly what P1 made of it** — applied, and
    /// (`AnnotationOwnership`) its amendments honoured — and a line after it is
    /// **held**. Held and never refused: nothing is wrong with these bytes, no
    /// `.lines` record is written, and there is nothing for the writer to be
    /// told they should have stopped doing. Its one way back in is the Inbox.
    ///
    /// **Three guards, and each is a direction of the ruling.**
    ///
    /// 1. `judgesAnything` — a device on no chain of its own judges nobody, the
    ///    same first question the permit partition asks. Without it a Mac that
    ///    has not joined this book would hold every file whose device has no
    ///    record here, which is most of a book it can see and none of its
    ///    business.
    /// 2. No snapshot ⇒ nothing narrowed this book ⇒ P1, untouched. The table
    ///    answers a snapshot exactly when it answers `hasNarrowingPermits`, so
    ///    there is no state in which one of the two says otherwise.
    /// 3. Only a line the walk APPLIED is moved. A stranger's sealed span is
    ///    already `.pending` and a revoked key's already `.quarantined`; this
    ///    never softens either, and never claims one of them for a holder of
    ///    its own.
    ///
    /// **This device's own file is not reachable from here**, and that is
    /// structural rather than guarded: `TrustTable.resolve` puts every one of
    /// this device's own actor ids into `keyByDeviceId` whatever the registry
    /// says, so `PermitMark.keyNaming` names its own file and `unattributable`
    /// is false for it. An enclave-less Mac therefore applies its own lines on
    /// its own screen — typing never waits on anything — while a signed Mac
    /// reading the same file after the snapshot holds what it wrote.
    ///
    /// **A stranger-sealed file keeps its stranger** (Task 1's review, minor
    /// 1). A file sealed by a key no device record names is `unattributable`
    /// too — `.stranger(device: nil)` is one of the two verdicts that means
    /// *the register has nothing to say about this key* — but it is somebody's
    /// file, and that somebody can be ADMITTED, which applies what they wrote.
    /// So where the walk has already held a line under a device, that device
    /// is the holder for anything else this rule holds in the same file (ADR
    /// 0012: one file, one writer). Calling it unsigned instead would file an
    /// admittable stranger under a holder no admission can pardon.
    private static func holdingUnsignedLines(
        of verification: OpLogChain.Verification,
        stream: PermitMark.Stream,
        fileSegmentDigest: String?,
        judge: PermitJudge
    ) -> OpLogChain.Verification {
        guard judgesAnything(judge.trust),
              let snapshot = judge.trust.unsignedSnapshot
        else { return verification }
        let lines = verification.lines
        guard !lines.isEmpty else { return verification }
        walkObserverForTesting?()
        let sides = snapshot.side(
            streamKey: stream.key, fileIsSegmentWithDigest: fileSegmentDigest,
            lines: lines.map(\.bytes))
        // The walk's own answer for this file, where it has one; otherwise
        // the stream itself, which is what an unsigned Mac is.
        let holder = lines.compactMap(\.state.pendingDevice).first
            ?? HeldLines.unsignedHolder(for: stream)
        let amendments = judge.context.amendments

        var holding: [Int: String] = [:]
        for (index, line) in lines.enumerated() where isApplied(line) {
            guard sides.side(ofLineAt: index) != .new else {
                holding[index] = holder
                continue
            }
            // **Inside the photograph: record it, so the ownership rule can
            // honour it** (ruling 1's other direction). An `annotationEdit` or
            // an `annotationWithdraw` signed by an id this register cannot
            // place is not honoured in a narrowed book — that is P3a's answer
            // and it stays P3a's answer — UNLESS the line is inside the
            // snapshot, where narrowing must not reach back. The side travels
            // by op id through the carrier the governing permit already
            // travels by (`AmendmentPermits`), because a second carrier would
            // be a second opinion about which line was which.
            guard let amendments, line.kind == .op,
                  let what = judge.decoding(line.bytes),
                  Permit.group(of: what) == .ownAnnotation,
                  let opId = RevocationSplit.opId(ofLine: line.bytes)
            else { continue }
            amendments.recordInsideTheUnsignedSnapshot(opId)
        }
        guard !holding.isEmpty else { return verification }
        return OpLogChain.repartitioned(
            verification, refusing: [:], holding: holding)
    }

    /// §4.5's pass 1: **did a book author apply a manuscript-text line here?**
    ///
    /// Run by the caller over every file of one docId, BEFORE the partition,
    /// to answer `UnownedPiece`. It asks the same questions `partition` asks
    /// and shares every one of its rules, so the two cannot disagree about
    /// which lines count.
    ///
    /// **A book author's `bootstrap` counts — unless the piece was started by
    /// somebody else** (P3c plan 2, controller ruling G). A bootstrap carries
    /// the piece's paragraph TEXT: an Add-File import, a seed, a legacy piece
    /// the root opened from its `.md` — each is the root's own writing, and
    /// counts exactly as before. The one bootstrap that does NOT claim a piece
    /// is a book author's opening of a piece whose recorded starter
    /// (`startedBy`) is a DIFFERENT writer — the Option A race, where the root
    /// opened her new piece before its ops synced (OA-2 stops it minting one
    /// now; an older opening stays unclaiming). A starter this register cannot
    /// resolve is somebody else, which is the safe side: her lines are held,
    /// never set aside. It is the one rule this pass keeps that `partition`
    /// has no use for.
    ///
    /// Only a line signed by the person's own **author** key counts. The
    /// assistant's hand is the reviewer row on every device including the
    /// root's, so an assistant-signed manuscript line is refused rather than
    /// applied, and a line that is not applied has claimed nothing.
    public static func bookAuthorWroteManuscriptText(
        in verification: OpLogChain.Verification,
        streamKey: String,
        deviceSlug: String? = nil,
        fileSegmentDigest: String?,
        trust: TrustTable,
        settledByKey: String? = nil,
        decoding: WrittenDecoder = writtenOp,
        startedBy: String? = nil
    ) -> Bool {
        guard judgesAnything(trust) else { return false }
        let lines = verification.lines
        guard !lines.isEmpty else { return false }
        let keys = attributableKeys(
            of: lines, trust: trust, settledByKey: settledByKey,
            namedBy: deviceSlug)
        guard !keys.isEmpty else { return false }
        let governing = governingEntries(
            forKeys: Set(keys.values), lines: lines,
            streamKey: streamKey, fileSegmentDigest: fileSegmentDigest,
            trust: trust)

        for (index, line) in lines.enumerated() {
            guard isApplied(line), line.kind == .op,
                  let key = keys[index],
                  actor(ofSealKey: key, trust: trust, deviceSlug: deviceSlug) == .author,
                  let entry = governing[key]?[index],
                  let what = decoding(line.bytes),
                  Permit.group(of: what) == .manuscriptText
            else { continue }
            if what == .op(.bootstrap), let startedBy,
               !trust.isAStarter(startedBy, ofTheSameWriterAs: key) { continue }
            if entry.judging.claimsAPieceByWritingItsText(actor: .author) { return true }
        }
        return false
    }

    // MARK: - The parts

    /// Test-only counting seam: called once per (file, timeline entry with a
    /// mark) judged — `OpLogChain.verifyObserverForTesting`'s twin.
    ///
    /// It exists to pin the cost claim rather than argue it: **a book with no
    /// permit events hashes nothing**, because every timeline is one entry and
    /// that entry has no mark. A regression that started judging the opening
    /// entry would put a SHA-256 over every line of every file back on every
    /// load and nothing else would go red.
    ///
    /// `nonisolated(unsafe)` because it is a test's own variable, set and
    /// cleared on one thread; production never assigns it.
    nonisolated(unsafe) public static var judgeObserverForTesting: (@Sendable () -> Void)?

    /// Test-only counting seam: called once per FILE whose lines this
    /// partition goes on to examine — `judgeObserverForTesting`'s coarser
    /// sibling, and the one that can see an early exit.
    ///
    /// It pins fix round 2's cost claim rather than arguing it: a registered
    /// book with no permit events walks NO translation sidecar and NO inbox
    /// manifest, however many of the thirty-odd synchronous readers ask for
    /// one. A regression that dropped the one-kind exit would put a
    /// `Seal.parse` per seal line back on every publish compile and every
    /// inbox refresh, and nothing else would go red.
    ///
    /// `nonisolated(unsafe)` because it is a test's own variable, set and
    /// cleared on one thread; production never assigns it.
    nonisolated(unsafe) public static var walkObserverForTesting: (@Sendable () -> Void)?

    /// **A book with no register has no ladder** — decision B3, spec §8's
    /// *a book with no registry has posture author*, and the read-side twin of
    /// `OpLogStore.localWritePermit`'s own first question.
    ///
    /// A permit is a fact the REGISTER states. Where this device is on no
    /// chain, there is nothing to state it: every foreign key already answers
    /// `.noChain` and applies as unsigned history (P1's whole world), so the
    /// only keys a partition could reach are this device's own — and judging
    /// the writer's own hand against a ladder their book does not have would
    /// refuse lines on the strength of nothing.
    ///
    /// **Not `hasEvents`**, which would be a narrower and wrong test: the actor
    /// rows bind in a book with a register and no events at all, which is every
    /// book opened since P2a (`RegistryPresence.ensureRootIfEmpty` writes this
    /// Mac a root at the first open of every project).
    private static func judgesAnything(_ trust: TrustTable) -> Bool {
        trust.myRoot != nil
    }

    /// **Could this partition refuse or hold anything in a file named like
    /// this, without knowing which key sealed it?** (fix round 3, minor 1.)
    ///
    /// The one caller is `classifySegment`, deciding whether a segment whose
    /// signature it cannot read is worth WALKING rather than applying whole.
    /// Walking such a file is what stops a demoted device escaping the permit
    /// by deleting its own `.sig` — but a walk is not free, and it can reach
    /// answers the fast path never would (a break inside the container), so it
    /// must not happen where the partition would refuse nothing anyway.
    ///
    /// Three questions, narrowing: this device must be on a chain at all; a
    /// NARROWED permit anywhere in the book means some key here might be
    /// judged differently; and with every permit at *author of the whole book*
    /// the only thing that can refuse is one of the three narrowed actor rows,
    /// so a file the AUTHOR's own name is on has nothing to judge. The name is
    /// a CLAIM with nothing checking it — which is safe in this direction only,
    /// because a lie about it costs a walk and buys nothing: the walk is the
    /// careful path.
    ///
    /// **Narrowing, not existence** (final fix wave, W1): admitting a phone
    /// writes an event, and under the old test that admission made every
    /// segment in the book worth walking for as long as the book lasted.
    public static func couldJudge(
        aFileNamedBy deviceSlug: String?, trust: TrustTable
    ) -> Bool {
        guard judgesAnything(trust) else { return false }
        if trust.hasNarrowingPermits { return true }
        guard let deviceSlug,
              let claimed = DeviceIdentity.claimedActor(ofDeviceId: deviceSlug)
        else { return true }
        return claimed != .author
    }

    /// **Can this whole file be answered `.yes` without walking it?** (fix
    /// round 2's R3, narrowed by fix round 3.)
    ///
    /// `TranslationStore.loadMerged` is read from around thirty synchronous
    /// call sites — the publish AST, the coverage gate, the editor's translated
    /// surface — and the inbox re-reads on every refresh. Paying
    /// `attributableKeys`, which is a `Seal.parse` per SEAL LINE and an inbox
    /// manifest is half seal lines, on every one of those in a book that can
    /// refuse nothing is what R3 flagged.
    ///
    /// **Three conditions, and the third is fix round 3's.**
    ///
    /// 1. **Nobody in this book is narrowed.** Then every person is an author
    ///    of the whole book for the whole of their history, so there is no *as
    ///    of the line* left to work out. **Narrowing, not events** (final fix
    ///    wave, W1): P3a's own admissions write book-author events, and gating
    ///    on their existence took this exit away from every book the moment its
    ///    writer admitted a second machine — which is the reading the thirty
    ///    synchronous `TranslationStore.loadMerged` sites and every inbox
    ///    refresh pay for.
    /// 2. **The file's own writer can be named.** One key per file is ADR
    ///    0012's premise and the FILENAME encodes it — a translation sidecar is
    ///    `<doc>.<lang>.<slug>` and an inbox manifest `inbox.<slug>`, one
    ///    identity's slug either way — so the first seal this device can
    ///    attribute names the file. Where nothing can be attributed (a legacy
    ///    file, a stranger's, an unsigned device's) this answers false and the
    ///    walk runs, which is what it did before any exit existed.
    /// 3. **The table allows that `Written` to that ACTOR**, asked of
    ///    `Permit.bookAuthor.allows` rather than restated. This is the
    ///    condition round 2 was missing, and it mattered: without it an
    ///    `assistant`-signed translation record was applied in an eventless
    ///    book — which is every book that exists today — and *MCP never mutates
    ///    the manuscript* is a sentence of the constitution rather than a thing
    ///    that waits for a book to have events. No production writer emits one
    ///    (the census is in Task 6's report), but the actor rows should not
    ///    depend on that.
    ///
    /// **It is equivalent to the walk, not weaker than it.** With no events
    /// every line of the file has the same governing permit (the opening
    /// entry), the same class, the same key and therefore the same actor — so
    /// the walk would ask `Permit.allows` the same question of every line and
    /// get this same answer. The actor is resolved through the walk's OWN
    /// function (`actor(ofSealKey:trust:deviceSlug:)`), so the two cannot
    /// disagree about whose hand a file is.
    ///
    /// **What it assumes, stated:** that a file's seals are all one key. The
    /// filename says so and every production writer obeys it; a device that
    /// mixed its own two keys in one file could be applied under the first
    /// one's row — and gains nothing by it, because a device holding two of its
    /// own keys can sign with the wider one instead, which is the same
    /// threat-model argument the slug narrowing rests on (Task 5's I5).
    private static func answersWholeFile(
        _ lines: [OpLogChain.Line], is what: Written,
        class documentClass: () -> DocumentClass,
        trust: TrustTable, deviceSlug: String?
    ) -> Bool {
        guard judgesAnything(trust), !trust.hasNarrowingPermits else { return false }
        guard let key = firstAttributableSealKey(lines, trust: trust),
              let actor = actor(ofSealKey: key, trust: trust, deviceSlug: deviceSlug)
        else { return false }
        return Permit.bookAuthor.allows(
            what, in: documentClass(), actor: actor) == .yes
    }

    /// The key of the first seal this device can attribute — **one parse, not
    /// one per seal line**, which is the whole saving.
    ///
    /// A seal that did not parse, was itself quarantined, or belongs to a key
    /// this device cannot vouch for is skipped: those are the seals
    /// `attributableKeys` ignores too, for the reasons spelled there.
    private static func firstAttributableSealKey(
        _ lines: [OpLogChain.Line], trust: TrustTable
    ) -> String? {
        for line in lines where line.kind == .seal && line.state != .quarantined {
            guard let seal = OpLogChain.Seal.parse(line.bytes) else { continue }
            switch trust.verdict(forSealKey: seal.key) {
            case .mine, .admitted: return seal.key
            case .stranger, .revoked, .retired, .otherRoot, .noChain: continue
            }
        }
        return nil
    }

    /// Applied by the walk: neither held back nor a torn last line.
    private static func isApplied(_ line: OpLogChain.Line) -> Bool {
        !line.state.isHeldBack && line.state != .tornTail
    }

    /// **Whose key each line is**, for the lines this device can attribute.
    ///
    /// A file is one device's writing (ADR 0012), and the seals in it are that
    /// device's key. So a line's key is the key of the seal that COVERS it —
    /// the next seal forward, since a seal closes the span ending at the line
    /// above it — and, for the trailing span that no seal has closed yet, the
    /// key of the last seal before it. A tail whose newest lines are not
    /// sealed is the ordinary shape of a live file, and leaving those lines
    /// unjudged would make *never seal again* a way past the whole check.
    ///
    /// Only a seal that PARSED, was not itself refused, and answers `.mine` or
    /// `.admitted` counts. A `.stranger`'s span is already held, a `.revoked`
    /// or `.otherRoot`'s already refused, a `.noChain`'s is unsigned history
    /// which P1 applies and P3 does not start refusing, and a `.retired`
    /// device's own earlier word is left exactly where P2b put it. Since Task
    /// 11 the first three of those are held or refused by the WALK as well,
    /// whether a seal closed them or not, so this filter and
    /// `TrustVerdict.settlingAnUnsealedSpan` now agree about a span twice over
    /// rather than the partition being the only thing standing between a
    /// stranger's tail and the book.
    ///
    /// - Parameter namedBy: the file's own device slug, which answers the case
    ///   no seal can: **a file that has never been sealed at all.** Its lines
    ///   are applied (an admitted device's unsealed tail is the ordinary shape
    ///   of a live file), and with no seal to attribute them to they used to be
    ///   applied UNJUDGED — so *never seal once* was the bypass this function's
    ///   trailing-span rule exists to close one word along. The slug is matched
    ///   against a signed record through `TrustTable.key(forDeviceSlug:)`, so
    ///   it is a claim checked rather than believed, and it can only ever name
    ///   a key the file's own seals would have named. Nil (a legacy unsuffixed
    ///   file, a pure caller, a device no record here mentions) is unchanged.
    private static func attributableKeys(
        of lines: [OpLogChain.Line], trust: TrustTable, settledByKey: String?,
        namedBy deviceSlug: String? = nil
    ) -> [Int: String] {
        // **A settled segment names its own key.** Its lines were never walked
        // — the container's signature settled the whole file at once — so
        // there are no inner seals to read a verdict off, and the key that
        // settled it is the key every line in it is under. Without this a
        // rotated segment would escape the partition that its live tail cannot,
        // which is P2b Task 10's asymmetry one rule along: demote somebody,
        // let them rotate, and everything applies.
        if let settledByKey {
            switch trust.verdict(forSealKey: settledByKey) {
            case .mine, .admitted:
                return Dictionary(
                    uniqueKeysWithValues: lines.indices.map { ($0, settledByKey) })
            case .stranger, .revoked, .retired, .otherRoot, .noChain:
                return [:]
            }
        }
        var sealKeyAt: [Int: String] = [:]
        for (index, line) in lines.enumerated()
        where line.kind == .seal && line.state != .quarantined {
            guard let seal = OpLogChain.Seal.parse(line.bytes) else { continue }
            switch trust.verdict(forSealKey: seal.key) {
            case .mine, .admitted: sealKeyAt[index] = seal.key
            case .stranger, .revoked, .retired, .otherRoot, .noChain: continue
            }
        }
        guard !sealKeyAt.isEmpty else {
            // No seal here names a key this device can judge by. Where the
            // FILENAME does — and only where the key it names is one whose
            // lines are applied at all — every line is under it.
            guard let deviceSlug, let key = trust.key(forDeviceSlug: deviceSlug)
            else { return [:] }
            switch trust.verdict(forSealKey: key) {
            case .mine, .admitted:
                return Dictionary(
                    uniqueKeysWithValues: lines.indices.map { ($0, key) })
            case .stranger, .revoked, .retired, .otherRoot, .noChain:
                return [:]
            }
        }

        var keys: [Int: String] = [:]
        // Backwards: the nearest seal at or after each line — the one that
        // closes its span.
        var covering: String?
        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            if let key = sealKeyAt[index] { covering = key }
            if let covering { keys[index] = covering }
        }
        // Forwards: whatever is left is the trailing unsealed span, which
        // belongs to the last seal before it.
        var preceding: String?
        for index in 0..<lines.count {
            if keys[index] == nil, let preceding { keys[index] = preceding }
            if let key = sealKeyAt[index] { preceding = key }
        }
        return keys
    }

    /// The governing timeline entry per line, per key — **one judgement per
    /// (file, entry)**, never one per line.
    ///
    /// `PermitMark.judge` hashes every line of the file up to the cut, so
    /// asking it per line would hash a novel's tail once per line of it. A
    /// person with no events has one entry and no mark, so this calls `judge`
    /// zero times for every book on disk today.
    private static func governingEntries(
        forKeys keys: Set<String>, lines: [OpLogChain.Line],
        streamKey: String, fileSegmentDigest: String?, trust: TrustTable
    ) -> [String: [PermitTimeline.Entry]] {
        let bytes = lines.map(\.bytes)
        var out: [String: [PermitTimeline.Entry]] = [:]
        for key in keys {
            out[key] = trust.timeline(forSealKey: key)
                .governingEntries(lineCount: lines.count) { mark in
                    judgeObserverForTesting?()
                    return mark.judge(
                        streamKey: streamKey,
                        fileIsSegmentWithDigest: fileSegmentDigest,
                        lines: bytes)
                }
        }
        return out
    }

    /// **Which of the four writers a key is** — the registry's answer, and
    /// where the registry has none, the op log's own filename (fix round 1,
    /// I5).
    ///
    /// A device record is what says what a key is FOR, and where one exists it
    /// decides (Task 3's rule, unchanged). But a person record and a device
    /// record are two files that sync separately, and a book can hold the
    /// first without the second — `RegistryAdmission.admit` writes a person
    /// record and nothing else. Answering nil there would hold every line that
    /// person ever wrote; answering `.author` there, which is what the first
    /// cut of this did, is worse in the one direction that costs words:
    /// a held span is keyed on `device ?? sealKey`, so before the device
    /// record arrives the writer can be asked about — and admit — somebody's
    /// ASSISTANT fingerprint, and calling that key `.author` would apply
    /// assistant-signed manuscript text into the book.
    ///
    /// So it is read off the id the ops and the filenames are named for:
    /// `DeviceIdentity.deviceId(actor:fingerprint:)` is `<actor>-<16 hex of
    /// the key>`, and the claim is only believed where the hex really is this
    /// sealing key's. **It can only ever NARROW.** An honest assistant's file
    /// is named `assistant-…`, and a client lying about it gains nothing it
    /// could not have by signing with its author key instead — which is
    /// outside this milestone's threat model in the same way.
    ///
    /// Nil — *pending* — in three cases, all of them right: a device record
    /// OWNS the key but calls it an actor word this build cannot read (a later
    /// build's fifth writer, which must not be guessed at); the stream has no
    /// device slug (the legacy unsuffixed file, whose lines are unsigned
    /// history and are not judged anyway); and an id whose fingerprint part is
    /// not this key's, which is a filename that does not describe its own
    /// contents.
    private static func actor(
        ofSealKey key: String, trust: TrustTable, deviceSlug: String?
    ) -> DeviceActor? {
        if let recorded = trust.actor(forSealKey: key) { return recorded }
        guard !trust.aDeviceRecordNames(key), let deviceSlug else { return nil }
        return DeviceIdentity.actor(ofDeviceId: deviceSlug, signingWith: key)
    }

    /// **Option A's read-side half** (P3c plan 2, ruling OA-3): does a line
    /// §4.5 would hold apply HERE, because this Mac is its writer's own and
    /// the piece is one her own devices started?
    ///
    /// Asked only inside §4.5's `.nobodyHasWrittenItsText` arm, so every
    /// other fact that arm turned on — an author of some pieces, her own
    /// hand, manuscript text, a piece outside her scope that no book author
    /// has written a word of — already holds. What this adds:
    ///
    /// 1. **The line is this writer's** (`TrustTable.isThisWriters`): one of
    ///    this device's own keys, or her other Mac's. On the ROOT's Mac it is
    ///    somebody else's line, so this answers false and the line is held and
    ///    the root asked — which is the whole of *never let her lines apply on
    ///    the root's Mac before Theirs*.
    /// 2. **One of her own devices started the piece**
    ///    (`TrustTable.starter(ofPieceStartedBy:)`). A piece with no starter
    ///    recorded (made before this build), or one somebody else started,
    ///    keeps today's rule on her Mac too.
    /// 3. **The piece was not TAKEN from her.** A root that removed a piece
    ///    from her scope has said whose it is not; she keeps writing there
    ///    only as today's rule allows (held, and the root asked). Asked of
    ///    her NAMED pieces (`wasTakenFromThem`), so a writer
    ///    narrowed from the whole book can still start a new piece.
    ///
    /// The write side asks the same three facts through
    /// `OpLogStore.localWritePermit`. Its answer is stamped on the open
    /// `Document`, and the third fact (no book author has written the text)
    /// changes as lines ARRIVE — so the Mac re-stamps such a Document after
    /// every external re-read that APPLIED another hand's change (ruling H;
    /// an echo of her own burst cannot claim the piece), the same re-read at
    /// which this arm stops applying her lines. Between a book author's line landing on disk and
    /// that re-read, what she types is set aside by the re-read; it is kept
    /// in History.
    private static func appliesOnItsWritersOwnMac(
        key: String, trust: TrustTable, class documentClass: DocumentClass,
        startedBy: () -> String?
    ) -> Bool {
        guard trust.isThisWriters(sealKey: key),
              let piece = documentClass.piece,
              !trust.timeline(forSealKey: key).wasTakenFromThem(piece: piece),
              let starter = startedBy()
        else { return false }
        switch trust.starter(ofPieceStartedBy: starter) {
        case .thisDevice, .anotherOfThisWritersDevices: return true
        case .somebodyElse: return false
        }
    }

    /// **Spec §4.4's third sentence** — *…after it stopped being hers.*
    ///
    /// Not *this entry has a mark*: an ADMISSION has a mark too (an empty one,
    /// meaning nothing had been applied), and a line written under the permit
    /// somebody was let in with was not written after anything stopped. The
    /// sentence is about a CHANGE, so the kinds that change an existing permit
    /// are what it asks about. The opening entry, which no event installed,
    /// answers false through the same `nil`.
    private static func changedAnExistingPermit(_ entry: PermitTimeline.Entry) -> Bool {
        switch entry.kind {
        case .roleChanged, .scopeChanged, .readmitted: return true
        case .admitted, .silentlyAdmitted: return false
        // The kinds that install no permit never govern a line, and `nil` is
        // the opening entry. Spelled out rather than defaulted so a ninth kind
        // is a compile error here.
        case .revoked, .revokedEntirely, .retired, .unknown, .none: return false
        }
    }
}
