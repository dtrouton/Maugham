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
    public static func writtenOp(_ line: Data) -> Written? {
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
        class documentClass: DocumentClass,
        streamKey: String,
        fileSegmentDigest: String?,
        trust: TrustTable,
        settledByKey: String? = nil,
        decoding: WrittenDecoder = writtenOp,
        unowned: () -> UnownedPiece
    ) -> OpLogChain.Verification {
        guard judgesAnything(trust) else { return verification }
        let lines = verification.lines
        guard !lines.isEmpty else { return verification }
        let keys = attributableKeys(
            of: lines, trust: trust, settledByKey: settledByKey)
        guard !keys.isEmpty else { return verification }
        let governing = governingEntries(
            forKeys: Set(keys.values), lines: lines,
            streamKey: streamKey, fileSegmentDigest: fileSegmentDigest,
            trust: trust)

        var refusing: [Int: OpLogChain.QuarantineCause] = [:]
        var holding: [Int: String] = [:]
        // Asked at most once, and only where §4.5 is actually reached.
        var unownedAnswer: UnownedPiece?

        for (index, line) in lines.enumerated() {
            guard isApplied(line), line.kind == .op,
                  let key = keys[index],
                  let entry = governing[key]?[index],
                  let what = decoding(line.bytes)
            else { continue }
            let actor = trust.actor(forSealKey: key)
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
                  trust.actor(forSealKey: key) == .author,
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
