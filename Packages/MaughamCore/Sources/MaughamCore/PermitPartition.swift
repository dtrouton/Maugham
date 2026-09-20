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
        /// manuscript-text line in this document.
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
        unowned: () -> UnownedPiece
    ) -> OpLogChain.Verification {
        guard judgesAnything(trust) else { return verification }
        let lines = verification.lines
        guard !lines.isEmpty else { return verification }
        // Past every early exit: this file's lines are about to be examined.
        walkObserverForTesting?()
        let keys = attributableKeys(
            of: lines, trust: trust, settledByKey: settledByKey)
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
        // **Is the governing permit of an amendment line worth writing down?**
        // (fix round 1.) Only where the book HAS permit events: with none,
        // every timeline is one entry — author of the whole book — so the
        // answer a deriver would look up is the answer it already gets by
        // asking the table today, and recording it would put a decode on every
        // line of every load for nothing. See `AmendmentPermits`.
        let recordAmendments = amendments != nil && trust.hasPermitEvents

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
            let skip = entry.permit.allowsEverything(actor: actor)
            if skip, !recordAmendments { continue }
            guard let what = decoding(line.bytes) else { continue }
            if recordAmendments, Permit.group(of: what) == .ownAnnotation,
               let opId = RevocationSplit.opId(ofLine: line.bytes) {
                amendments?.record(opId, entry.permit)
            }
            if skip { continue }
            let documentClass = resolvedClass ?? documentClass()
            resolvedClass = documentClass
            switch entry.permit.allows(what, in: documentClass, actor: actor) {
            case .yes:
                continue
            case .cannotJudge:
                holding[index] = trust.person(forSealKey: key)
            case let .no(refused):
                if startsAPieceNobodyHasClaimed(
                    permit: entry.permit, actor: actor,
                    class: documentClass, what: what) {
                    let answer = unownedAnswer ?? unowned()
                    unownedAnswer = answer
                    if answer == .nobodyHasWrittenItsText {
                        holding[index] = trust.person(forSealKey: key)
                        continue
                    }
                }
                refusing[index] = .notPermitted(
                    person: trust.person(forSealKey: key),
                    what: refused,
                    afterMark: changedAnExistingPermit(entry),
                    actor: actor?.rawValue)
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
            unowned: judge.context.unowned)
    }

    /// §4.5's pass 1: **did a book author apply a manuscript-text line here?**
    ///
    /// Run by the caller over every file of one docId, BEFORE the partition,
    /// to answer `UnownedPiece`. It asks the same questions `partition` asks
    /// and shares every one of its rules, so the two cannot disagree about
    /// which lines count.
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
        decoding: WrittenDecoder = writtenOp
    ) -> Bool {
        guard judgesAnything(trust) else { return false }
        let lines = verification.lines
        guard !lines.isEmpty else { return false }
        let keys = attributableKeys(
            of: lines, trust: trust, settledByKey: settledByKey)
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
            if case .author(.book) = entry.permit { return true }
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
    /// Three questions, narrowing: this device must be on a chain at all; any
    /// permit history in the book means some key here might be narrowed; and
    /// with NO history the only thing that can refuse is one of the three
    /// narrowed actor rows, so a file the AUTHOR's own name is on has nothing
    /// to judge. The name is a CLAIM with nothing checking it — which is safe
    /// in this direction only, because a lie about it costs a walk and buys
    /// nothing: the walk is the careful path.
    public static func couldJudge(
        aFileNamedBy deviceSlug: String?, trust: TrustTable
    ) -> Bool {
        guard judgesAnything(trust) else { return false }
        if trust.hasPermitEvents { return true }
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
    /// 1. **No permit events.** Then every timeline is one entry and every
    ///    person is an author of the whole book, so there is no *as of the
    ///    line* left to work out.
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
        guard judgesAnything(trust), !trust.hasPermitEvents else { return false }
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
    /// device's own earlier word is left exactly where P2b put it.
    private static func attributableKeys(
        of lines: [OpLogChain.Line], trust: TrustTable, settledByKey: String?
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
        guard !sealKeyAt.isEmpty else { return [:] }

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

    /// **Spec §4.5's shape**: an author of some pieces, writing with her own
    /// hand, putting manuscript text into a piece that is not in her scope.
    ///
    /// The actor must be `.author`: an assistant-signed manuscript line is
    /// refused because the assistant never changes the manuscript on any
    /// device, and that refusal has nothing to do with whose piece it is.
    private static func startsAPieceNobodyHasClaimed(
        permit: Permit, actor: DeviceActor?,
        class documentClass: DocumentClass, what: Written
    ) -> Bool {
        guard actor == .author,
              case let .author(scope) = permit,
              case let .pieces(mine) = scope,
              case let .piece(id) = documentClass, !mine.contains(id),
              Permit.group(of: what) == .manuscriptText
        else { return false }
        return true
    }
}
