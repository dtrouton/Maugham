// Packages/MaughamCore/Sources/MaughamCore/OpLogClassifier.swift
import Foundation

/// Load and classify: what one op-log file is made of, and the one verify
/// walk every reader of a per-device stream takes (`walk`). Pure over the
/// bytes plus the reads the doc comments name; the instance loads that need
/// the store's trust cache stay on `OpLogStore` and call in here with the
/// table they resolve. Split out of `OpLogStore` (foundations plan 6);
/// `OpLogStore` keeps one-line forwarders for its public and Mac-facing entry
/// points.
///
/// **`@MainActor` at type level** (tripwire 56): a member that is not
/// `nonisolated` runs where `OpLogStore` ran, so an async function moved in
/// here keeps its isolation without having to say so.
@MainActor
public enum OpLogClassifier {
    // MARK: - Classification (the one rule both readers obey)

    /// What one file turned out to be, and what the reader that can write is
    /// asked to do about it. Pure over the bytes plus two READS (this device's
    /// remembered head and verified-segment memory, and the signature sidecar
    /// beside a segment) — so the coordinated reader and the synchronous one
    /// can call the same function and cannot disagree about which ops a
    /// document is made of. Only the coordinated one performs the side effects.
    /// A file's ops: deduplicated and sorted by id, as every reader takes
    /// them, with the order the file held them in (`appendOrder`).
    nonisolated static func parseOps(_ bytes: Data) -> (elements: [Op], diagnostics: ParseDiagnostics, order: [String]) {
        let parsed = JSONLAppendStore<Op>.parse(bytes: bytes, dedupKey: { $0.opId })
        return (parsed.elements.sorted { $0.opId < $1.opId }, parsed.diagnostics, parsed.elements.map(\.opId))
    }

    struct FileClassification {
        let ops: [Op]
        let diagnostics: ParseDiagnostics
        let provenance: FileProvenance
        /// The walk this classification came out of, when there was one —
        /// what it kept, what it held back, and why. Nil only where a segment
        /// failed before any line could be walked. The reader that can WRITE
        /// hands it to `JSONLAppendStore.setAside`, which owns both the record
        /// and the words for it.
        let verification: OpLogChain.Verification?
        /// Non-nil when this device may now adopt the file's head as its own
        /// (the crash window: a remembered head no line in the file hashes to,
        /// in a file that holds together and whose every seal is ours).
        let adoptedHead: String?
        /// Non-nil when a segment's signature settled it for the first time and
        /// the digest is worth remembering.
        let verifiedSegmentDigest: String?
        /// **The digest of a segment this reader took in WHOLE** — P3a Task
        /// 9's fix round 1, and the ONE answer to that question.
        ///
        /// Whole means every line of it reached a verdict, not that every line
        /// was applied: a mark's `segments` list says *the root read this whole
        /// file*, and a later reader uses it to decide which PERMIT judges the
        /// lines inside, never to decide that they were allowed.
        ///
        /// Two ways in. A container that SETTLED was taken in whole by
        /// definition — that is the claim a segment signature makes, and it is
        /// the same claim this device's memory of the digest makes one load
        /// later. One that did not settle is walked instead, and counts only
        /// if the walk reached the END of it: a chain that broke inside means
        /// the reader never trusted the bytes after the break, so it did not
        /// read the file whole and must not say it did. A container that did
        /// not verify is nil, because the digest a file CARRIES is the digest
        /// a tamperer leaves alone.
        ///
        /// It lives here rather than beside each caller because there are two
        /// of them — the mark sweep and the foreign-stream memory — and a
        /// disagreement between them is a stream the memory expects and the
        /// mark can never name, which is a root's verb refusing for ever.
        let wholeSegmentDigest: String?
        /// **The applied ops' ids in the order the file holds them** — its
        /// append order, where `ops` is sorted by id (report plan 6b Task 8:
        /// what a reader had read of a stream is a prefix of this).
        var appendOrder: [String] = []

        func ordered(_ order: [String]) -> FileClassification {
            var copy = self
            copy.appendOrder = order
            return copy
        }
    }

    /// `permit` is the P3a partition's two document-level answers (spec §4.1,
    /// §4.5). **Nil is the explicit *do not judge*** — the keyless readers,
    /// which pass no table either, and `unownedPiece`'s own second pass, which
    /// is what stops it recursing.
    nonisolated static func classify(
        url: URL, bytes: Data,
        state: OpLogDeviceState?, trust: TrustTable? = nil,
        permit: PermitContext? = nil
    ) -> FileClassification {
        url.pathExtension == OpLogSegment.fileExtension
            ? classifySegment(
                url: url, container: bytes, state: state,
                trust: trust, permit: permit)
            : classifyTail(
                url: url, bytes: bytes, state: state,
                trust: trust, permit: permit)
    }

    /// **The permit partition, in the one place both classify paths reach it**
    /// (P3a Task 5, spec §4.3) — `readmittingWhatWasAlreadyApplied`'s sibling,
    /// and run immediately after it.
    ///
    /// The order is verify → revocation split → permit partition → parse, and
    /// every step of it has to be before the parse: a line this refuses must
    /// never reach the element decoder, and a line it holds must never reach
    /// the document.
    ///
    /// The two are never folded. A revocation is a verdict about a whole KEY,
    /// cut on a mark the root recorded; a permit is about one LINE, judged
    /// against the history its signer had when the line was written. Running
    /// this second means it judges what the revocation left applied, which is
    /// the only order in which both answers survive.
    ///
    /// With no table or no context there is nothing to ask, so a keyless
    /// reader is unchanged — P1's behaviour exactly.
    private nonisolated static func partitioningByPermit(
        _ verification: OpLogChain.Verification,
        url: URL, trust: TrustTable?, permit: PermitContext?,
        fileSegmentDigest: String? = nil, settledByKey: String? = nil
    ) -> OpLogChain.Verification {
        guard let trust, let permit else { return verification }
        // **The class travels as the CLOSURE it is** (fix round 1, I1), inside
        // the `PermitJudge`. Calling it here would make it an argument,
        // evaluated before the partition's own first guard — a manifest read
        // and decode for every op-log file of every book, including a
        // registerless one that then judges nothing.
        return PermitPartition.partition(
            of: verification, file: url,
            judging: PermitJudge(trust: trust, context: permit),
            fileSegmentDigest: fileSegmentDigest, settledByKey: settledByKey)
    }

    /// **The one verify walk** over a per-device stream's bytes (foundations
    /// plan 6, Task 4) — the live tail, an unsettled segment's fallback, and
    /// the mark sweep's walk of a translation sidecar or inbox manifest all
    /// take it, so the three cannot drift apart.
    ///
    /// With a table, every seal is judged by `table.verdict(forSealKey:)`.
    /// **Arm 2 of *the file's key*** (Task 11). A file with no usable seal
    /// still has a name, and the name's slug is the one thing about it this
    /// device can match against a signed record. Lazy: `verify` asks only when
    /// something is unsealed and no seal in the file named it first.
    ///
    /// With no table there is no key to judge by: the KEYLESS walk, which
    /// judges nobody (the closure that trusts no key — tripwire 39's one keyless
    /// spelling in this type) — P1's behaviour exactly (ADR 0032 §6).
    ///
    /// `rememberedHead` is the caller's: the tail passes this device's
    /// remembered head, a segment and the mark sweep pass nil.
    ///
    /// **Every caller is a keyless decision wherever it can pass a nil
    /// table**, so the callers are counted (`TripwireGrepTests.walkCallSites`,
    /// beside tripwire 39). Spell a call `walk(bytes:` on one line — the
    /// census counts that spelling, and the declaration below breaks it
    /// across lines on purpose so it is not counted.
    nonisolated static func walk(
        bytes: Data, trust: TrustTable?, rememberedHead: String?, url: URL
    ) -> OpLogChain.Verification {
        trust.map { table in
            OpLogChain.verify(
                bytes: bytes,
                trust: { table.verdict(forSealKey: $0) },
                rememberedHead: rememberedHead,
                keyOfAnUnsealedFile: { PermitMark.keyNaming(url, in: table) },
                file: url)
        } ?? OpLogChain.verify(
            bytes: bytes,
            trusted: { _ in false },
            rememberedHead: rememberedHead,
            file: url)
    }

    /// A live `.jsonl` tail: verified against this device's remembered head,
    /// with everything the walk quarantined held back.
    ///
    /// It takes no `identities`, for the same reason `classifySegment` does not:
    /// the only question it ever asked of them — is this key ours — is the
    /// table's. A parameter still here would let a future caller pass keys and
    /// no table and silently judge nobody where P1 judged its own.
    private nonisolated static func classifyTail(
        url: URL, bytes: Data,
        state: OpLogDeviceState?, trust: TrustTable?,
        permit: PermitContext? = nil
    ) -> FileClassification {
        let fileKey = OpLogDeviceState.fileKey(url)
        // The table answers `.mine` for EVERY actor on this device — the
        // assistant's seal over the assistant's own file is this device's word,
        // and a trust set of one fingerprint would file the writer's own MCP
        // history under "another device's unsigned history" in the History
        // pane — and, since P2a, `.admitted` for the devices this device's root
        // took in, `.stranger` for a key it can say nothing about (held), and
        // `.revoked`/`.otherRoot` for a key it refuses.
        //
        // With no identities there is no table to build: that reader holds no
        // key, judges nobody, and every seal it meets is unsigned history.
        // Arm 2 of *the file's key* included; see `walk`.
        let walked = walk(bytes: bytes, trust: trust,
                          rememberedHead: state?.head(for: fileKey), url: url)

        // The adopt rule (spec §4.2's crash window) and its converse, both in
        // `OpLogChain.resolveAbsentHead` — the one place that decides what a
        // missing remembered head means, shared with the chained WRITE so a
        // load cannot hold back lines the next append would chain onto.
        let (verification, adopted) = OpLogChain.resolveAbsentHead(
            walked,
            rememberedHead: state?.head(for: fileKey),
            previousHead: state?.previousHead(for: fileKey))

        // **The revocation cut, BEFORE the parse** (find 5, ruled 2026-09-18).
        // The walk refuses a revoked key's span whole and says why; which of
        // those lines this Mac had already applied is told by opId, a number
        // the ROOT recorded when it revoked somebody and which the walk — seals
        // and chains, never ops — is deliberately ignorant of. Here is where
        // both are in hand, and it has to happen before `applied` builds the
        // bytes the parser sees, or a line the revocation keeps never reaches
        // the document.
        let readmitted = readmittingWhatWasAlreadyApplied(
            verification, url: url, trust: trust)
        // **Then the permit, line by line** (P3a Task 5). It judges what the
        // revocation left applied; see `partitioningByPermit`.
        let settled = partitioningByPermit(
            readmitted, url: url, trust: trust, permit: permit)

        let parsed = parseOps(JSONLAppendStore<Op>.applied(settled, whole: bytes))

        return FileClassification(
            ops: parsed.elements,
            diagnostics: parsed.diagnostics,
            provenance: provenance(
                url: url, lines: settled.lines,
                isSealedSegment: false, segmentVerified: nil, trust: trust),
            verification: settled,
            adoptedHead: adopted,
            verifiedSegmentDigest: nil,
            // A live tail is not a segment and carries no digest at all.
            wholeSegmentDigest: nil).ordered(parsed.order)
    }

    /// **What a revocation keeps** — `RevocationSplit`'s answer applied to a
    /// walk, and the one place the two classify paths ask it (find 5).
    ///
    /// A live tail and a rotated segment must agree about what a revocation
    /// costs. Before this, only the tail was split at all, so the same
    /// device's history read one way in `.jsonl` and another in `.mzseg` —
    /// the live-tail-versus-segment asymmetry P2b Task 10 closed for the
    /// keyless walk, re-opened one rule along.
    ///
    /// With no table there is no mark and nothing to ask, so a keyless reader
    /// is unchanged: it holds no key, judges nobody, and never meets
    /// `.afterRevocation` at all.
    ///
    /// **Two forms of the same line** (P3a Task 7). Where the register holds a
    /// revocation EVENT for that person, the cut is by chain POSITION —
    /// tamper-proof, because an opId carries a timestamp its own writer chose
    /// and a device shut out could stamp new text with an old one. Where it
    /// does not — every revocation on disk before P3 — the opId path is
    /// untouched, which is what keeps the P2 suite passing without an edit.
    ///
    /// The judgement is computed **once per person** and only for a person
    /// whose revocation carries a map, so a book with no events hashes nothing
    /// here and a book with one hashes a file's lines once, not once per line.
    private nonisolated static func readmittingWhatWasAlreadyApplied(
        _ verification: OpLogChain.Verification,
        url: URL, trust: TrustTable?, fileSegmentDigest: String? = nil
    ) -> OpLogChain.Verification {
        // **The quarantine short-circuit, restated here as a COST guard** (fix
        // round 1, minor 4). `RevocationSplit.partition` makes the same check
        // first, but it makes it after this function has already parsed the
        // file's name into a stream key — on every file of every load, for a
        // question that only arises where something was refused.
        guard let trust, !verification.quarantined.isEmpty else { return verification }
        let streamKey = PermitMark.stream(of: url)?.key
        var judged: [String: PermitMark.Judgement] = [:]
        let split = RevocationSplit.partition(of: verification) { person in
            if let streamKey, let mark = trust.revocationMark(forPerson: person) {
                if let already = judged[person] { return .byPosition(already) }
                let judgement = mark.judge(
                    streamKey: streamKey,
                    fileIsSegmentWithDigest: fileSegmentDigest,
                    lines: verification.lines.map(\.bytes))
                judged[person] = judgement
                return .byPosition(judgement)
            }
            return trust.highestOpIdSeen(forPerson: person).map(RevocationSplit.Cut.byOpId)
        }
        guard let split else { return verification }
        return OpLogChain.readmitting(verification, lines: split.readmitted)
    }

    /// A sealed `.mzseg` segment. Immutable bytes with a digest already inside
    /// them, so the question is asked once and then remembered: does a
    /// signature this device trusts name this digest? If so the segment's lines
    /// are settled WHOLE and never walked again. If not — a foreign signature,
    /// no signature at all, a segment minted before this milestone — the lines
    /// are walked keylessly, which still catches a break.
    ///
    /// It takes no `identities`: the two questions it once asked of them — is
    /// this signature ours, and is this key trusted — are both the table's now.
    private nonisolated static func classifySegment(
        url: URL, container: Data,
        state: OpLogDeviceState?, trust: TrustTable?,
        permit: PermitContext? = nil
    ) -> FileClassification {
        let decoded = OpLogSegment.decodeVerifying(container)
        var skipped: [ParseDiagnostics.SkippedLine] = []
        if let failure = decoded.failure {
            skipped.append(.init(
                byteOffset: 0,
                raw: "<segment \(url.lastPathComponent): \(failure)>"))
        }
        guard let jsonl = decoded.jsonl else {
            return FileClassification(
                ops: [], diagnostics: ParseDiagnostics(skipped: skipped),
                provenance: FileProvenance(
                    name: url.lastPathComponent,
                    isSealedSegment: true, segmentVerified: false),
                verification: nil,
                adoptedHead: nil, verifiedSegmentDigest: nil,
                // The container did not decode, so there is no digest to
                // believe and nothing to say this file was read whole.
                wholeSegmentDigest: nil)
        }

        // Only a container that verified may be keyed on: the digest a file
        // CARRIES is the digest a tamperer would leave alone.
        let digest = decoded.isVerified ? decoded.digest : nil
        var settled = false
        var toRemember: String?
        if let digest {
            if state?.isVerified(segmentDigest: digest) == true {
                settled = true
            } else if let trust,
                      let signature = SegmentSignature.read(
                          at: OpLogStore.segmentSignatureURL(for: url)),
                      signature.digest == digest,
                      // A segment is settled WHOLE, so the only verdicts that
                      // can settle one are the two that are a word this device
                      // stands behind. A stranger's segment falls through to
                      // the keyless walk below rather than being held: holding
                      // is a per-SPAN decision the walk makes, and a segment
                      // that never settled is walked line by line anyway.
                      trust.verdict(forSealKey: signature.key)
                          .isOurWord(sealedAt: signature.at),
                      signature.verifies() {
                settled = true
                toRemember = digest
            }
        }

        // **What the partition would judge this settled segment by** — built
        // once, and only where a partition is actually due (fix round 1, I4).
        // A container whose signature settled it is never walked, so the lines
        // have to be constructed and the signing key read back off the `.sig`
        // beside it; `settledSegmentVerification` does both or answers nil.
        // **And only where the partition could refuse something in a file
        // named like this one** (fix round 3, minor 1). The gate used to be
        // *a permit context exists*, which is every load: a no-events book's
        // author segment whose `.sig` had gone missing was walked for nothing,
        // and a walk can reach answers the fast path never would.
        let mayJudge = permit != nil && trust.map {
            PermitPartition.couldJudge(
                aFileNamedBy: PermitMark.stream(of: url)?.deviceSlug, trust: $0)
        } ?? false
        let attributable = (settled && mayJudge)
            ? OpLogStore.settledSegmentVerification(at: url, bytes: container) : nil
        // **A digest this device remembers, with the `.sig` beside it since
        // DELETED, does not get the fast path.** It used to fall through and
        // apply the whole segment unjudged: demote Sam with a mark inside her
        // rotated segment, let this Mac load once so the digest is remembered,
        // then delete her `.mzseg.sig` in the shared folder, and her post-mark
        // manuscript text comes back. Walking instead costs a walk — for a
        // file whose signature has gone missing — and the walk's own inner
        // seals attribute every span correctly, which is the answer that needs
        // no memory at all.
        if settled, mayJudge, attributable == nil { settled = false }

        let parsedAll = parseOps(jsonl)
        if settled {
            // Per-line skips inside a segment only matter when the container
            // itself verified (otherwise the container record covers it) — and
            // a settled segment always verified.
            skipped.append(contentsOf: parsedAll.diagnostics.skipped)
            // **A settled segment is partitioned too** (P3a Task 5). The
            // container's signature settles the whole file at once, so there
            // are no inner seals to read a verdict off and the key that signed
            // it is the key every line is under. Skipping this would let a
            // demoted device escape the partition by ROTATING — maintenance a
            // device performs on itself, silently pardoning it, which is P2b
            // Task 10's asymmetry one rule along.
            //
            // The lines are built (and the bytes split) only where a permit
            // context was supplied; the neutral fast path is untouched, and
            // `AREA.md`'s performance note 2 still holds for it.
            //
            // The signing key comes from `settledSegmentVerification`'s own
            // read of the sidecar rather than from the branch above, because
            // this file may have settled from MEMORY
            // (`isVerified(segmentDigest:)`) on a second load, and a remembered
            // digest carries no key.
            //
            // Where that read cannot be made, `settled` was cleared above and
            // this branch is not reached at all (fix round 1, I4).
            if let trust, permit != nil, let digest, let built = attributable {
                let partitioned = partitioningByPermit(
                    built.verification, url: url, trust: trust, permit: permit,
                    fileSegmentDigest: digest, settledByKey: built.key)
                if partitioned != built.verification {
                    let read = parseOps(JSONLAppendStore<Op>.applied(partitioned, whole: jsonl))
                    return FileClassification(
                        ops: read.elements,
                        diagnostics: ParseDiagnostics(skipped: skipped),
                        provenance: provenance(
                            url: url, lines: partitioned.lines,
                            isSealedSegment: true, segmentVerified: true,
                            trust: trust),
                        verification: partitioned,
                        adoptedHead: nil, verifiedSegmentDigest: toRemember,
                        wholeSegmentDigest: digest).ordered(read.order)
                }
            }
            let lines = nonEmptyLineCount(jsonl)
            return FileClassification(
                ops: parsedAll.elements,
                diagnostics: ParseDiagnostics(skipped: skipped),
                provenance: FileProvenance(
                    name: url.lastPathComponent, verified: lines,
                    isSealedSegment: true, segmentVerified: true),
                verification: nil,
                adoptedHead: nil, verifiedSegmentDigest: toRemember,
                // A segment that settled was taken in whole by definition —
                // whether by its own signature or by this device's memory of
                // its digest, which is the SAME claim one load later. Under
                // the mark sweep, which passes no state, the two coincide.
                wholeSegmentDigest: digest).ordered(parsedAll.order)
        }

        // **The fallback walk judges by the TABLE too** (P2b Task 10).
        //
        // A segment that did not settle whole is walked line by line, and until
        // now that walk was keyless — every seal inside it answered `.noChain`
        // and its span was applied as unsigned history. That made a device's
        // ROTATED history a different thing from its live tail: a stranger's
        // `.jsonl` is held and the same stranger's `.mzseg`, once its container
        // signature failed to settle, was applied unread. Rotation is not an
        // admission, so the two must agree — and this device's own inner seals,
        // which the keyless walk could not recognise either, settle `verified`
        // rather than being filed under somebody else's unsigned history.
        //
        // With no table there is still nothing to ask, and the keyless walk is
        // P1's behaviour exactly (ADR 0032 §6).
        // Walked, then cut, then parsed — the tail's own order, spelled out
        // here rather than delegated to `verifiedParse`, because a revocation
        // must cost a rotated segment exactly what it costs a live tail
        // (find 5's fourth carry). A keyless walk meets no `.afterRevocation`
        // and is returned untouched.
        // A segment that did not settle is walked exactly as a tail is,
        // arm 2 included: rotation is maintenance a device performs on
        // itself and must pardon nothing (P2b Task 10's rule, one rule
        // along). Same `walk`, no remembered head.
        let walked = walk(bytes: jsonl, trust: trust, rememberedHead: nil, url: url)
        let readmitted = readmittingWhatWasAlreadyApplied(
            walked, url: url, trust: trust, fileSegmentDigest: digest)
        let verification = partitioningByPermit(
            readmitted, url: url, trust: trust, permit: permit,
            fileSegmentDigest: digest)
        let read = parseOps(JSONLAppendStore<Op>.applied(verification, whole: jsonl))
        if decoded.isVerified {
            skipped.append(contentsOf: read.diagnostics.skipped)
        }
        return FileClassification(
            ops: read.elements,
            diagnostics: ParseDiagnostics(skipped: skipped),
            provenance: provenance(
                url: url, lines: verification.lines,
                isSealedSegment: true, segmentVerified: false, trust: trust),
            verification: verification,
            adoptedHead: nil, verifiedSegmentDigest: nil,
            // Walked rather than settled, so it counts only where the walk
            // reached the END: a chain that broke inside means this reader
            // never trusted the bytes after the break.
            wholeSegmentDigest: digest.flatMap {
                !verification.lines.isEmpty && verification.lines.allSatisfy(StreamPositions.wasSeen)
                    ? $0 : nil
            }).ordered(read.order)
    }

    /// How many non-blank lines these bytes hold — counted, never SPLIT.
    ///
    /// The settled-segment branch needs this number and nothing else from the
    /// bytes, and `split(separator:)` over a five-megabyte segment allocates one
    /// `Data` slice per line to answer it. On the 50,000-line fixture that was
    /// the single largest cost the chain added to a load, for a count.
    private nonisolated static func nonEmptyLineCount(_ bytes: Data) -> Int {
        bytes.withUnsafeBytes { raw -> Int in
            var count = 0
            var inLine = false
            for byte in raw {
                if byte == 0x0A {
                    if inLine { count += 1; inLine = false }
                } else {
                    inLine = true
                }
            }
            return inLine ? count + 1 : count
        }
    }

    /// The counts, taken off the LINES themselves rather than off the walk's
    /// own tallies — one place decides what each class means, and a new state
    /// on `OpLogChain.Line` is a compile error here rather than a silent zero.
    ///
    /// **It takes the URL rather than the name** (P3b Task 4): the file's own
    /// stream slug is recorded beside its counts, and `PermitMark.stream(of:)`
    /// — the one filename parse — needs the directory as well as the name. A
    /// second parse of a name here would be a second opinion about which
    /// stream a file belongs to.
    private nonisolated static func provenance(
        url: URL, lines: [OpLogChain.Line],
        isSealedSegment: Bool, segmentVerified: Bool?,
        trust: TrustTable? = nil
    ) -> FileProvenance {
        let name = url.lastPathComponent
        var legacy = 0, verified = 0, unsealed = 0, unsignedHistory = 0, quarantined = 0
        var pending = 0
        // The split by device is `OpLogChain`'s own derivation, asked for here
        // rather than repeated: the inbox's pending banner asks the same
        // question of a different stream, and two spellings of one count is how
        // two surfaces come to disagree about who is waiting.
        let pendingByDevice = OpLogChain.pendingByDevice(of: lines)
        for line in lines {
            switch line.state {
            case .legacy: legacy += 1
            case .verified: verified += 1
            case .unsealed: unsealed += 1
            case .unsignedHistory: unsignedHistory += 1
            case .pending:
                pending += 1
            // A torn last line is in no provenance class: it was never
            // applied as history and it was never held back either. The
            // element decoder reports it in `diagnostics.skipped`, which is
            // the channel a torn line has always used.
            case .tornTail: break
            case .quarantined: quarantined += 1
            }
        }
        return FileProvenance(
            name: name, legacy: legacy, verified: verified, unsealed: unsealed,
            unsignedHistory: unsignedHistory, quarantined: quarantined,
            pending: pending, pendingByDevice: pendingByDevice,
            // What they ARE (P3b smoke find F2), counted from the same lines.
            pendingWaitingByDevice: pendingByDevice.isEmpty
                ? [:] : HeldLines.Waiting.byDevice(of: lines),
            // **Which of them the writer can be asked to ADMIT** (Task 5's D5).
            // The permit partition holds a line it cannot judge under the same
            // `.pending` state a stranger's seal does, and only the table can
            // tell the two apart. With no table nothing is pending at all, so
            // the `?? []` arm is unreachable rather than lenient.
            pendingStrangerDevices: trust.map { table in
                Set(pendingByDevice.keys.filter(table.isStrangerDevice))
            },
            // **Which stream these lines were held in** (P3b Task 4). Nil for a
            // legacy unsuffixed file and for anything this build does not
            // recognise as a stream, which is the answer that asks nothing of
            // the holder.
            deviceSlug: PermitMark.stream(of: url)?.deviceSlug,
            isSealedSegment: isSealedSegment, segmentVerified: segmentVerified)
    }

    /// Load + parse ONE op-log file — plain `.jsonl` tail or sealed `.mzseg`
    /// segment — into ops + diagnostics. The single per-file read shared by
    /// `OpLogStore.loadDiagnosed(docId:)` and `ProjectIntegrity.check`, so
    /// opIds inside segments stay visible to the dangling-pointer check
    /// exactly as tail opIds are (growth spec §5.4).
    ///
    /// **`@MainActor`, as it was on `OpLogStore`.** It must stay atomic with
    /// the store's appends and seals, which run on the main actor (see the
    /// NOTE on `SegmentSealer.sealTail`): nonisolated, every per-file call
    /// would hop off main and let a seal delete a tail, or an append move the
    /// remembered head, between two reads of one load. Pinned by
    /// `OpLogClassifierIsolationTests`.
    ///
    /// Segment verification failure (bad magic / decompress / checksum) is a
    /// data condition, not an error: surfaced as a `ParseDiagnostics.skipped`
    /// entry (so `ProjectIntegrity.check` marks the doc unhealthy and the
    /// load path quarantines it) while any salvageable decompressed lines
    /// still parse — best-effort, never silent (spec §5.3).
    ///
    /// `trust` is who this device judges the file's seals by. Nil is the
    /// KEYLESS reader — `ProjectIntegrity.check`, and anything else that
    /// inspects a project without opening it — which holds no key and judges
    /// nobody, so every seal it meets is somebody's unsigned history.
    ///
    /// `foreign` is P3a Task 9's memory of where OTHER devices' streams stood,
    /// and it is the LOAD path's alone for `state`'s own reason: a check that
    /// classifies keylessly forms a weaker picture than a load, and a memory
    /// taken from it would be a memory of a reading nobody acted on. It is
    /// carried as a collector rather than returned, because the decision is
    /// about a STREAM and this function sees one FILE of one — the caller
    /// settles it once every file of the document has been observed.
    @MainActor
    public static func loadFileDiagnosed(
        url: URL, presenter: NSFilePresenter?,
        identities: LocalIdentities? = nil, state: OpLogDeviceState? = nil,
        trust: TrustTable? = nil, permit: PermitContext? = nil,
        foreign: ForeignStreamWatch? = nil
    ) async throws -> (ops: [Op], diagnostics: ParseDiagnostics, provenance: FileProvenance, appendOrder: [String]) {
        loadFileObserverForTesting?()
        guard let bytes = try OpLogStore.readCoordinated(url: url, presenter: presenter) else {
            return ([], ParseDiagnostics(),
                    FileProvenance(name: url.lastPathComponent,
                                   isSealedSegment: url.pathExtension == OpLogSegment.fileExtension), [])
        }
        let classified = classify(
            url: url, bytes: bytes, state: state, trust: trust, permit: permit)

        // **Where another device's stream stood** (P3a Task 9). An observation
        // and not a write: the watch settles the whole document's worth at
        // once, so a chapter spread over four foreign files costs one rewrite
        // of the state file rather than four.
        foreign?.observe(
            url: url, verification: classified.verification,
            segmentDigest: classified.wholeSegmentDigest)

        // The three writes a load is allowed to make, all of them derived
        // bookkeeping and every one best-effort: nothing here may cost the
        // writer the load of their own manuscript.
        if let digest = classified.verifiedSegmentDigest {
            state?.markVerified(segmentDigest: digest)
        }
        if let head = classified.adoptedHead {
            // The root is the one `fileKey` scoped this file to, not a
            // handle of this static function's own: it has a URL and no
            // project. Recording the same directory the hash was taken over is
            // what lets the entry be pruned when that project is gone.
            state?.remember(head: head, for: OpLogDeviceState.fileKey(url),
                            root: OpLogDeviceState.projectRoot(of: url))
        }
        // A forensic record is the LOAD path's to write, and only its. A caller
        // taking the nil defaults — `ProjectIntegrity.check`, and anything else
        // that inspects a project without opening it — classifies with no key
        // and no remembered head, so its picture is strictly WEAKER than the
        // load's: it cannot see an `afterRememberedHead` break at all, and what
        // it does see it would file under the load's name. A check reports; the
        // load records.
        let recordsWhatItSetsAside = identities != nil && state != nil
        if recordsWhatItSetsAside, let verification = classified.verification,
           let docId = OpLogStore.docId(fromOpLogFilename: url.lastPathComponent) {
            do {
                try JSONLAppendStore<Op>.setAside(
                    verification,
                    from: url, docId: docId,
                    in: projectRoot(of: url))
            } catch {
                // Mirrors `Document+Load.swift`'s stance on a forensic write
                // that fails: the record is how the writer LEARNS, never how
                // the load proceeds.
                opLogLoadLog.error("""
                    Could not record set-aside lines from \
                    \(url.lastPathComponent, privacy: .public): \
                    \(String(describing: error), privacy: .public).
                    """)
            }
        }
        return (classified.ops, classified.diagnostics, classified.provenance, classified.appendOrder)
    }

    /// The project root a `.maugham/ops/<file>` URL sits under.
    private nonisolated static func projectRoot(of url: URL) -> URL {
        url.deletingLastPathComponent()      // .maugham/ops
            .deletingLastPathComponent()     // .maugham
            .deletingLastPathComponent()     // the project
    }

    /// **What a load of this document WOULD say it is made of, without loading
    /// it** (signed op log P3 plan 3, carry C4).
    ///
    /// The admission sheet counts held lines across the book, and until this
    /// it could count only what an OPEN document's load had stamped — so a
    /// stranger who had written only in chapters nobody had opened was asked
    /// about when one of them was opened, and not before. The Mac's closed-
    /// document sweep asks this, one document at a time, off the main actor.
    ///
    /// **One classifier, and this is not a second one.** The files are
    /// `opLogFileURLs`' listing, the permit context is built exactly as
    /// `loadDiagnosed` builds it (no statements handed over, no amendment
    /// carrier — neither moves a count), every file goes through the same
    /// `classify`, and a file that reads as nothing contributes the same empty
    /// `FileProvenance` `loadFileDiagnosed` returns for one. So the `files` of
    /// the answer are the load's, file by file; `ClosedProvenanceTests` pins
    /// that over a stranger's span, a §4.5 hold and an unsigned tail.
    ///
    /// **The one field it does not carry is `ownStreams`** — which streams are
    /// this device's own is the load's to say from identities this function
    /// is not given, and no held-line reader asks it.
    ///
    /// **It reads and never writes**: `state` is asked what it remembers (a
    /// weaker picture without it could count a line the load sets aside), and
    /// none of the load's three writes — the adopted head, the verified
    /// segment digest, the forensic record — is made here. No presenter: it
    /// only reads, so there is no write of this process's own to keep from
    /// bouncing back.
    ///
    /// **It throws rather than coming back short** — a file present and
    /// unreadable is `readCoordinated`'s to raise (RULING-54).
    ///
    /// `trust` is not optional: the caller resolves one table for a whole
    /// sweep, off the main actor, as `ProjectStore.recountFromOpLogs` does.
    public nonisolated static func provenance(
        forDocId docId: String, in projectURL: URL,
        trust: TrustTable, state: OpLogDeviceState?
    ) throws -> OpLogProvenance {
        let urls = OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL)
        guard !urls.isEmpty else { return OpLogProvenance() }
        let permit = OpLogStore.permitContext(forDocId: docId, in: projectURL, trust: trust)
        var files: [FileProvenance] = []
        for url in urls {
            guard let bytes = try OpLogStore.readCoordinated(url: url, presenter: nil) else {
                files.append(FileProvenance(
                    name: url.lastPathComponent,
                    isSealedSegment: url.pathExtension == OpLogSegment.fileExtension))
                continue
            }
            files.append(classify(
                url: url, bytes: bytes, state: state, trust: trust,
                permit: permit).provenance)
        }
        return OpLogProvenance(files: files)
    }

    /// **Where the held-line walk actually ran** — a test's own variable, so
    /// `OpLogStore.heldLines`' off-actor claim is a measurement rather than a
    /// paragraph (fix round 2, I3). `PermitPartition.walkObserverForTesting`'s
    /// shape and its reason: `nonisolated(unsafe)` because a test sets and
    /// clears it on one thread, and production never assigns it.
    nonisolated(unsafe) public static var heldLinesWalkObserverForTesting:
        (@Sendable () -> Void)?

    /// **Where the per-file load actually ran** — the mirror of
    /// `heldLinesWalkObserverForTesting`, pinning the opposite claim:
    /// `loadFileDiagnosed` runs on the main actor
    /// (`OpLogClassifierIsolationTests`). Same shape, same reason.
    nonisolated(unsafe) public static var loadFileObserverForTesting:
        (@Sendable () -> Void)?

    /// The walk half of `OpLogStore.heldLines`, `nonisolated` so the store can
    /// run it off the main actor.
    ///
    /// **One classifier, and this is not a second one.** `classify` is the
    /// same function both `classifyTail` and `classifySegment` are reached
    /// through. Nothing here re-derives which span is inside the unsigned
    /// photograph, whether a segment verified, or which lines a permit
    /// refused: those are the walk's, and a copy of any of them would answer
    /// differently the first time either changed.
    ///
    /// **It reads and never writes.** `classify` only asks the device state
    /// what it remembers; the three writes a LOAD makes — the adopted head,
    /// the verified segment digest and the forensic record — are
    /// `loadFileDiagnosed`'s and are not made here. The remembered head IS
    /// passed, because leaving it out would give a weaker picture than the
    /// load's and could offer a line the load had set aside.
    ///
    /// **It throws rather than coming back short.** A file present and
    /// unreadable is `readCoordinated`'s to raise (RULING-54): a silent short
    /// answer here would offer the writer some of a held span and tell them it
    /// was all of it.
    ///
    /// Answers the raw LINE BYTES, in file order, per file in listing order —
    /// what they MEAN is the caller's (`OpLogQuarantine.recoverableWords`),
    /// which is the same decode the record door uses.
    nonisolated static func heldLines(
        in urls: [URL], heldBy holder: String, presenter: NSFilePresenter?,
        state: OpLogDeviceState?, trust: TrustTable?, permit: PermitContext?
    ) throws -> [Data] {
        heldLinesWalkObserverForTesting?()
        var held: [Data] = []
        for url in urls {
            guard let bytes = try OpLogStore.readCoordinated(url: url, presenter: presenter)
            else { continue }
            let classified = classify(
                url: url, bytes: bytes, state: state, trust: trust, permit: permit)
            guard let verification = classified.verification else { continue }
            for line in verification.lines
            where line.state.pendingDevice == holder {
                held.append(line.bytes)
            }
        }
        return held
    }

    /// Synchronous globbed read+merge, bypassing `NSFileCoordinator`. For the
    /// local-only / heuristic readers that deliberately avoid async
    /// coordination; the async `OpLogStore.load(docId:)` is the coordinated path and is
    /// preferred where the call site can await. Same opId dedupe + sort.
    /// The synchronous reader classifies exactly as the coordinated one does —
    /// same `classify`, same applied set — and writes NOTHING: no quarantine
    /// record, no remembered head, no verified digest. It is a reader with no
    /// presenter and no writer's authority, so it simply omits what it will not
    /// apply. That the two agree is not a matter of care; it is the same
    /// function called twice, and `OpLogVerifiedLoadTests` pins it anyway,
    /// because this is the reader MCP's `read_document` and the Practice walk
    /// see a closed manuscript through.
    /// `facts` is the manifest's, for a caller LOOPING over a book: the
    /// permit partition resolves a `DocumentClass` per document, and a caller
    /// that already holds a manifest must not make this decode one per chapter
    /// (P3a Task 5). Nil reads it off disk, lazily, and only where some line's
    /// permit makes the answer turn on it.
    public nonisolated static func loadSyncMerged(
        forDocId docId: String, in projectURL: URL,
        identities: LocalIdentities? = .current,
        state: OpLogDeviceState? = .shared,
        trust: TrustTable? = nil,
        facts: DocumentClass.Facts? = nil,
        amendmentPermits: AmendmentPermits? = nil
    ) throws -> [Op] {
        // Resolved here when the caller did not hand one over, so this reader
        // and the coordinated one hold a document to be made of the same ops.
        // A caller in a loop over a book's chapters should resolve ONCE and
        // pass it: the resolution is a verified read of the registry folder.
        let table = try trust ?? identities.map {
            try TrustResolution.resolve(projectURL: projectURL, identities: $0)
        }
        // **The permit partition, in the second read path** (P3a Task 5). One
        // context for the document, so its class is resolved at most once
        // however many files its history is spread over.
        let permit = OpLogStore.permitContext(
            forDocId: docId, in: projectURL, trust: table, facts: facts,
            amendments: amendmentPermits)
        var ops: [Op] = []
        for url in OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL) {
            let data: Data
            do { data = try Data(contentsOf: url) }  // adr-0018-ok: op-log file bytes — the op log IS the source of truth (ADR 0018)
            catch {
                // RULING-54: an unreadable-yet-present file throws — a closed
                // document must not derive SHORTER because one device's file
                // could not be read (the reader here includes MCP
                // read_document, which would otherwise hand Claude a shorter
                // manuscript as the truth).
                throw OpLogStore.ReadError.unreadableFile(
                    name: url.lastPathComponent,
                    underlying: error.localizedDescription)
            }
            ops.append(contentsOf: classify(
                url: url, bytes: data, state: state, trust: table,
                permit: permit).ops)
        }
        return mergeSortedDedup(ops)
    }

    /// Collapse a union of op arrays into the canonical merged log: opId-sorted,
    /// **content-deterministic, load-order-independent** dedupe. Each source file
    /// is already internally deduped+sorted; this collapses any cross-file opId
    /// overlap (e.g. an op in both legacy and a per-device file).
    ///
    /// The survivor of a same-opId collision must be the SAME regardless of the
    /// order the inputs arrive in — production feeds this from
    /// `contentsOfDirectory` enumeration, whose order is NOT guaranteed, so two
    /// devices with identical logs must still derive identical text. A plain
    /// `.sorted { $0.opId < $1.opId }` is not a stable sort, so a same-opId pair
    /// with DIFFERENT content could survive non-deterministically (the loser
    /// depended on file-enumeration order). We fix that by sorting on a TOTAL
    /// order `(opId, canonicalEncoding)`: two ops with the same opId but different
    /// content always order the same way (by their canonical `.sortedKeys` JSON),
    /// so first-wins-by-opId after the sort yields a deterministic survivor.
    ///
    /// NOTE: a same-opId collision whose payloads DIVERGE is a corruption signal
    /// (ULIDs don't collide; a divergent collision means a replay / hand-recovery
    /// / duplicated op). Picking a deterministic survivor here keeps merge correct;
    /// SURFACING the collision (e.g. via `IntegrityQuarantine`) is worth doing
    /// later but needs the `projectURL`/stamp this pure fn deliberately lacks —
    /// don't entangle it here. See `OpLog/AREA.md` for the resolution contract.
    nonisolated static func mergeSortedDedup(_ ops: [Op]) -> [Op] {
        // Canonical, content-deterministic encoding of an op — the same
        // `.sortedKeys` + ISO8601-fractional date coding the store writes to
        // disk, so the tiebreaker is a stable function of content alone (no
        // ordering/clock/enumeration dependence).
        func canonical(_ op: Op) -> String {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
            enc.outputFormatting = [.sortedKeys]
            return (try? enc.encode(op)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        var seen = Set<String>()
        return ops
            .sorted { a, b in
                if a.opId != b.opId { return a.opId < b.opId }
                return canonical(a) < canonical(b)
            }
            .filter { seen.insert($0.opId).inserted }
    }
}
