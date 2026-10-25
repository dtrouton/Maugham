// Packages/MaughamCore/Sources/MaughamCore/StreamPositions.swift
import Foundation

/// Marks and positions: where a reader had got to in each stream — the
/// revocation mark, the permit's applied and seen positions, and the unsigned
/// door's photograph — plus the placeholder refusal and the per-file walk the
/// sweeps share. Split out of `OpLogStore` (foundations plan 6); `OpLogStore`
/// keeps forwarders so callers are unchanged.
public enum StreamPositions {
    /// **The highest opId this project APPLIES from one device, anywhere in
    /// it** — the revocation mark, computed with no main-actor hop (find-5
    /// review, the two Mediums).
    ///
    /// Nil when this project applies nothing of theirs; it THROWS when a file
    /// is present and will not read, because a mark that silently came back
    /// short would quietly widen what a revocation takes back. The caller turns
    /// that into a refusal rather than into a number
    /// (`OpLogStore.unreadableName` names the file).
    ///
    /// **Applied, not merely present.** Each file is classified with the same
    /// trust table a load would use, so a line the reader refuses or holds is
    /// not counted as something this device had got to.
    ///
    /// **Read-only in fact, not merely in intent.** `state: nil` and
    /// `identities: nil` are both passed, which is what stops the walk writing
    /// forensic records, adopting heads or remembering segment digests over
    /// forty chapters nobody has opened as a side effect of asking a question
    /// about one device. The remembered head is not lost by it: this device
    /// keeps one only for files it has WRITTEN, and the files that matter here
    /// are the revoked device's.
    ///
    /// `nonisolated` and taking no presenter, so the whole sweep — the listing
    /// included — runs off the main actor. It only reads, so there is no write
    /// of this process's own for a presenter to keep from bouncing back.
    nonisolated public static func highestAppliedOpId(
        ofDeviceIds ids: Set<String>, in projectURL: URL, trust: TrustTable?
    ) throws -> String? {
        guard !ids.isEmpty else { return nil }
        let opsDir = projectURL.appendingPathComponent(".maugham/ops")
        let filenames = (try? FileManager.default
            .contentsOfDirectory(atPath: opsDir.path)) ?? []
        var docIds = OpLogStore.docIds(inOpsDirectoryFilenames: filenames)
        // Named, because the manuscript reader excludes it by contract — the
        // same reason the project-open sweep names it when it rotates tails.
        docIds.insert("__project__")

        // **The permit partition runs here too** (P3a Task 5): a refused line
        // is not *applied*, and a mark that counted one would record a
        // position this Mac never reached. Resolved once for the whole sweep.
        let facts = OpLogStore.manifestFacts(in: projectURL)
        var highest: String?
        for docId in docIds.sorted() {
            let permit = OpLogStore.permitContext(
                forDocId: docId, in: projectURL, trust: trust,
                facts: facts)
            for url in OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL) {
                guard let bytes = try OpLogStore.readCoordinated(url: url, presenter: nil)
                else { continue }
                let classified = OpLogClassifier.classify(
                    url: url, bytes: bytes, state: nil, trust: trust,
                    permit: permit)
                for op in classified.ops where ids.contains(op.device) {
                    if highest == nil || op.opId > highest! { highest = op.opId }
                }
            }
        }
        return highest
    }

    /// **Where in each of this device's streams the reader had got to** — the
    /// P3 mark, and `highestAppliedOpId`'s sibling in every respect but what it
    /// answers (spec §3.3).
    ///
    /// Same listing, same `classify` with `state: nil` and `identities`
    /// unreachable, so it is read-only in fact and not merely in intent: it
    /// writes no forensic record, adopts no head, and remembers no segment
    /// digest over forty chapters nobody has opened. It THROWS for the same
    /// reason its sibling does — a mark that silently came back short would
    /// quietly move a permission boundary — and the caller turns that into a
    /// refusal rather than into a position.
    ///
    /// **What it records, per stream** (`PermitMark.stream(of:)` names them):
    ///
    /// - the digest of every SEGMENT the reader took in whole;
    /// - the `OpLogChain.lineHash` of the last APPLIED line of the live
    ///   `.jsonl` tail — never a held-back line, never a quarantined one,
    ///   never a torn one.
    ///
    /// **`applied` here is the word it says**, and that is what makes this the
    /// REVOCATION's question and not the permit's: *Revoke, keeping what this
    /// Mac already had* means the lines that are in the draft the writer has
    /// been reading. `seenPositions` is the other question — see it for why
    /// one answer cannot serve both acts.
    ///
    /// **The last line is taken from the TAIL and no other file, which is what
    /// keeps this free of any ordering.** A stream is a run of sealed segments
    /// plus one tail, and only the tail is still being appended to; the
    /// segments are whole and are named by digest. So nothing here has to
    /// decide which file came after which — and nothing may, because a segment
    /// index is part of a filename and a filename is the writer's to choose.
    ///
    /// **The known gap, stated rather than hidden:** a segment that neither
    /// settled nor could be walked through to its last line contributes no
    /// digest, so lines inside it judge as *new* later. That is the strict
    /// side of the format the spec fixes — a mark can say *this whole segment*
    /// or *up to this line*, and such a segment is neither.
    ///
    /// `nonisolated` and presenter-free, so the whole sweep runs off the main
    /// actor; it only reads, so there is no write of this process's own for a
    /// presenter to keep from bouncing back.
    nonisolated public static func appliedPositions(
        ofDeviceIds ids: Set<String>, in projectURL: URL, trust: TrustTable?,
        expecting: [String: OpLogDeviceState.ForeignStreamMemory] = [:]
    ) throws -> PermitMark {
        try positions(
            ofDeviceIds: ids, in: projectURL, trust: trust,
            expecting: expecting
        ) { line in
            !line.state.isHeldBack && line.state != .tornTail
        }
    }

    /// **Where in each of this device's streams the reader had READ TO** — the
    /// position a PERMIT event records (spec §3.3, corrected in P3a Task 5's
    /// fix round 2).
    ///
    /// **A mark does not bless lines; it selects which PERMIT judges them.**
    /// At or before the position the OLD permit decides, after it the NEW one.
    /// Once that is the rule, *the last line the root APPLIED* is the wrong
    /// position, and it is wrong in both directions whenever refused or held
    /// lines sit at the END of what the root had read:
    ///
    /// - **A promotion becomes a pardon.** Sam is a reviewer and the tail of
    ///   her file ends in manuscript text this Mac refused. The root promotes
    ///   her. The last APPLIED line is before that text, so the text judges
    ///   NEW — under her new author permit — and is applied. Spec §5 forbids
    ///   exactly that.
    /// - **A demotion reaches back.** A segment holding a thousand honestly
    ///   applied lines and one refused line is not *wholly applied*, so it
    ///   would go unlisted, so all thousand judge NEW — under the demoted
    ///   permit — and are refused retroactively.
    ///
    /// So the position is the last line the root **saw and judged**: the last
    /// line the chain verified, whatever the partition then did with it —
    /// applied, refused by the permit, or held. Lines the root refused under
    /// the old permit stay under the old permit and stay refused; lines it
    /// applied stay applied. Nothing is blessed either way, because the
    /// refusal is re-derived from the permit rather than read off the mark.
    ///
    /// **Two things are not *seen*.** A torn tail line is a write that stopped
    /// mid-line — bytes nobody finished, let alone judged. And everything a
    /// broken chain quarantined: the root never trusted those bytes, so it
    /// never formed an opinion about what they said.
    ///
    /// A SEGMENT the reader took in whole is listed by digest **whether or not
    /// any of its lines were refused**, for the same reason: the digest says
    /// *the root read this whole file*, not *the root applied all of it*.
    nonisolated public static func seenPositions(
        ofDeviceIds ids: Set<String>, in projectURL: URL, trust: TrustTable?,
        expecting: [String: OpLogDeviceState.ForeignStreamMemory] = [:]
    ) throws -> PermitMark {
        try positions(
            ofDeviceIds: ids, in: projectURL, trust: trust,
            expecting: expecting, lastLine: wasSeen)
    }

    /// Did the reader see and JUDGE this line? — `seenPositions`' predicate,
    /// and the one place the two exclusions are spelled.
    nonisolated static func wasSeen(_ line: OpLogChain.Line) -> Bool {
        if line.state == .tornTail { return false }
        if case .chainBroke = line.refusal { return false }
        return true
    }

    /// **The walk both position sweeps share.** They differ in one thing and
    /// it is the `lastLine` predicate: what counts as the last line of a tail.
    /// Everything else — the listing, the classification, the segment rule,
    /// the read-only guarantee, the throw — is one implementation, because two
    /// copies of it would be two answers to *which files are this device's*.
    ///
    /// **Three families of stream, not one** (P3a Task 6). A mark names a
    /// person's `<docId>.<slug>` op streams, their `translation:…` sidecars and
    /// their `inbox:<slug>` manifests, because those last two answer to the
    /// same permit and `PermitMark.judge` asks the mark by stream key: a stream
    /// the mark does not name is judged wholly NEW, so leaving the translation
    /// and inbox families out would make every demotion reach back through
    /// every translation and every capture the subject had ever written. The
    /// families share the predicate and the read-only guarantee; they differ in
    /// how a file is walked, which is what `verificationForPositions` holds.
    ///
    /// **A short answer is a refusal, never a shorter mark** (fix round 1, I2).
    /// A stream the mark does not name is judged wholly NEW, so every way of
    /// failing to SEE a stream is a way of drawing the line at the beginning
    /// of it — which for a revocation sets aside words this Mac had applied
    /// and for a demotion reaches back through the whole file. So: a directory
    /// that exists and will not list throws (`listing(of:naming:)` tells that
    /// from a directory that is simply not there), a file that is present and
    /// will not read throws (`readCoordinated`, RULING-54), and every verb
    /// that marks turns either into its own *nothing was changed* refusal.
    ///
    /// **`expecting` is the third way, and it is a caller's to supply.**
    /// A file that is simply ABSENT — evicted by iCloud, halfway through a
    /// sync — looks exactly like a stream that never existed, and nothing in
    /// this function can tell them apart. A caller that REMEMBERS what it has
    /// applied from each stream says so here and gets
    /// `ReadError.streamMissingFromSweep` naming the first one short.
    ///
    /// **It is the MEMORY and not a set of names** (final fix wave, W2).
    /// Checking that the name came back caught a stream that had vanished and
    /// nothing else, which left the case the shipped UI can walk into: Sam's
    /// Mac rotates, and the tail DELETION reaches the root's disk before the
    /// new segment does. The key is there, the mark names the stream, nothing
    /// refuses — and the mark's position is short. The root presses Revoke
    /// (*keep what was applied*); the late segment arrives; every line in it is
    /// unlisted and unmarked, so every line judges NEW, so the revocation sets
    /// aside words this Mac had already applied. The mark is a signed shared
    /// event, so every device inherits the cut.
    ///
    /// So the guard asks `ForeignStreamWatch.loss` — the load's own predicate,
    /// rotation tolerance and all, called rather than restated — of what this
    /// sweep actually read. A stream that legitimately GREW (a new segment and
    /// a new tail) is not refused; a stream this device never remembered is not
    /// expected at all.
    private nonisolated static func positions(
        ofDeviceIds ids: Set<String>, in projectURL: URL, trust: TrustTable?,
        expecting: [String: OpLogDeviceState.ForeignStreamMemory] = [:],
        lastLine: (OpLogChain.Line) -> Bool
    ) throws -> PermitMark {
        guard !ids.isEmpty else { return .nothingApplied }
        // A device's files are named for its SLUG, and `DeviceSlug.make` is
        // deterministic, so which files are the subject's is decided here
        // rather than by reading ops out of them — a file whose every line is
        // held back still has a position, and a legacy shared file has none.
        let slugs = Set(ids.map { DeviceSlug.make(from: $0).raw })
        let opsDir = projectURL.appendingPathComponent(".maugham/ops")
        // **Listed ONCE** (fix round 2, minor D). This used to call
        // `verifyOpsDirectoryListable` and then list the folder again for the
        // names, which is two directory reads per sweep for one question — and
        // the sentence that came with the first is about a LOAD starting a
        // second parallel history, which is not what a mark sweep is doing.
        // `listing` answers both halves: empty where the folder is not there,
        // a throw where it is there and will not read.
        let filenames = try OpLogStore.listing(of: opsDir, naming: ".maugham/ops")
        try refuseAnyPlaceholder(
            among: filenames, in: opsDir, forSlugs: slugs, kind: .history)
        var docIds = OpLogStore.docIds(inOpsDirectoryFilenames: filenames)
        // Named, because the manuscript reader excludes it by contract — the
        // same reason the project-open sweep names it when it rotates tails.
        docIds.insert("__project__")

        let facts = OpLogStore.manifestFacts(in: projectURL)
        var segments: [String: Set<String>] = [:]
        var lastKnownLine: [String: String] = [:]
        // What this sweep FOUND, per stream, in the shape the load's own
        // predicate takes (final fix wave, W2). Gathered only for the streams
        // a caller remembers, because that is the only question it answers.
        var found: [String: ForeignStreamWatch.Found] = [:]
        func note(
            _ key: String, _ change: (inout ForeignStreamWatch.Found) -> Void
        ) {
            guard expecting[key] != nil else { return }
            var entry = found[key] ?? .init()
            change(&entry)
            found[key] = entry
        }
        for docId in docIds.sorted() {
            let permit = OpLogStore.permitContext(
                forDocId: docId, in: projectURL, trust: trust,
                facts: facts)
            for url in OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL) {
                guard let stream = PermitMark.stream(of: url),
                      let slug = stream.deviceSlug, slugs.contains(slug)
                else { continue }
                guard let bytes = try OpLogStore.readCoordinated(url: url, presenter: nil)
                else { continue }
                let classified = OpLogClassifier.classify(
                    url: url, bytes: bytes, state: nil, trust: trust,
                    permit: permit)
                if url.pathExtension == OpLogSegment.fileExtension {
                    // **The one answer to *did this reader take the segment in
                    // whole*** (Task 9's fix round 1). It used to be computed
                    // here, by a SECOND decode of a container `classify` had
                    // already decoded; it is now the classification's own
                    // `wholeSegmentDigest`, which is also what the foreign
                    // stream memory records — and two spellings of it would be
                    // a stream that memory expects and this mark can never
                    // name, which is a root's verb refusing for ever.
                    if let digest = classified.wholeSegmentDigest {
                        segments[stream.key, default: []].insert(digest)
                        note(stream.key) {
                            $0.digests.insert(digest)
                            $0.answered = true
                        }
                    } else {
                        note(stream.key) { $0.sawUnsettledSegment = true }
                    }
                    continue
                }
                guard let verification = classified.verification else { continue }
                note(stream.key) { entry in
                    if verification.head != nil { entry.answered = true }
                    if let head = expecting[stream.key]?.head,
                       ForeignStreamWatch.holds(head, verification) {
                        entry.holdsRemembered = true
                    }
                }
                guard let last = verification.lines.last(where: lastLine)
                else { continue }
                lastKnownLine[stream.key] = OpLogChain.lineHash(last.bytes)
            }
        }

        // The other two families. Neither rotates — `sealTailIfNeeded` is the
        // op log's alone — so there is no segment rule here and no digest to
        // record, only the last line the reader got to in each file.
        for url in try otherStreamFileURLs(in: projectURL, forSlugs: slugs) {
            guard let stream = PermitMark.stream(of: url),
                  let slug = stream.deviceSlug, slugs.contains(slug),
                  let bytes = try OpLogStore.readCoordinated(url: url, presenter: nil)
            else { continue }
            let verification = verificationForPositions(
                at: url, bytes: bytes, stream: stream, trust: trust)
            note(stream.key) { entry in
                if verification.head != nil { entry.answered = true }
                if let head = expecting[stream.key]?.head,
                   ForeignStreamWatch.holds(head, verification) {
                    entry.holdsRemembered = true
                }
            }
            guard let last = verification.lines.last(where: lastLine) else { continue }
            lastKnownLine[stream.key] = OpLogChain.lineHash(last.bytes)
        }

        var marks: [String: PermitMark.StreamMark] = [:]
        for key in Set(segments.keys).union(lastKnownLine.keys) {
            // Sorted, because `opLogFileURLs` is UNSORTED and a mark two
            // devices compare byte for byte must not depend on what
            // `contentsOfDirectory` felt like saying.
            marks[key] = .init(
                segments: segments[key].map { $0.sorted() } ?? [],
                line: lastKnownLine[key])
        }
        // Sorted, so a sweep short of two streams refuses over the same one
        // twice running and the writer is not chasing a different name each
        // time they press.
        //
        // A stream whose NAME never came back answers `Found()` — nothing
        // found, nothing answered — which `loss` reads as the remembered head
        // being gone, so the two conditions the ruling names are one call.
        for key in expecting.keys.sorted() {
            let seen = found[key] ?? .init()
            guard seen.answered,
                  ForeignStreamWatch.loss(
                    remembered: expecting[key], found: seen) == nil
            else { throw OpLogStore.ReadError.streamMissingFromSweep(streamKey: key) }
        }
        return PermitMark(marks)
    }

    // MARK: - The unsigned door's photograph (P3b Task 1)

    /// **Where every UNATTRIBUTABLE stream in this book stands right now** —
    /// the mark the first narrowing event carries (`UnsignedSnapshot`).
    ///
    /// `seenPositions`' sibling, and deliberately its sibling rather than a
    /// parameter of it: the two ask opposite questions of the listing. A
    /// position sweep starts from a PERSON and knows which files are theirs
    /// before it opens one (`DeviceSlug.make` is deterministic); this one
    /// cannot know whose a file is until it has read it, because the whole
    /// subject is files nobody's record names. So it walks every op stream,
    /// every translation sidecar and every inbox manifest in the project, and
    /// asks each one whether this register can name a key for it
    /// (`OpLogChain.Verification.unattributable` — one spelling, shared with
    /// the reader that later decides which side of the photograph a line falls
    /// on).
    ///
    /// **The legacy unsuffixed `<docId>.jsonl` is in it**, under its own P3a
    /// stream key (a bare docId): it belongs to no device in particular and is
    /// exactly the file no slug can name.
    ///
    /// **It refuses exactly as the other sweeps do**, and the verb that asked
    /// then writes nothing: a directory that exists and will not list, a file
    /// that is present and will not read, an iCloud placeholder standing in
    /// for one, and — since P3b Task 2 — a stream this device REMEMBERS having
    /// applied from and cannot find now (`expecting:`, `ForeignStreamWatch
    /// .loss`, the same memory and the same predicate `seenPositions` uses).
    /// *A short snapshot is the reach-back this ruling exists to prevent* — a
    /// stream this sweep failed to see is a stream the snapshot does not name,
    /// which judges wholly NEW, which holds the whole of an unsigned Mac's
    /// history the moment anybody is narrowed.
    ///
    /// **What `expecting:` cannot cover, stated.** The memory is of FOREIGN
    /// streams, keyed by stream and recorded with a device SLUG, so the legacy
    /// unsuffixed `<docId>.jsonl` — which has no slug, belongs to no device in
    /// particular, and is exactly the file no key can name — is outside it. A
    /// legacy file that is missing at sweep time is not noticed here, and the
    /// snapshot will not name it; nothing writes to one any more
    /// (`opLogFileURL` always carries a slug), so the lines at risk are lines
    /// that were already there when the file went missing, and they come back
    /// applied the moment it does.
    ///
    /// **`state: nil` throughout, exactly as `seenPositions` is** (ledger
    /// L176): a mark must be computable from the shared bytes alone, or a
    /// fresh Mac and the root cut the same file in two places. It follows that
    /// nothing here remembers anything or writes anything.
    ///
    /// **And `permit: nil`.** The position a file is at does not depend on
    /// what the permit partition would do with its lines: `wasSeen` excludes a
    /// torn tail and what a BROKEN CHAIN quarantined, and neither is something
    /// a partition can produce. Passing no context also keeps the sweep off
    /// the manifest and out of `unownedPiece`'s second pass, which is the
    /// cheaper and the more obviously terminating arrangement.
    ///
    /// `nonisolated` and presenter-free, so the whole sweep runs off the main
    /// actor.
    nonisolated public static func unattributablePositions(
        in projectURL: URL, trust: TrustTable,
        expecting: [String: OpLogDeviceState.ForeignStreamMemory] = [:]
    ) throws -> PermitMark {
        // **Only the streams this photograph is ABOUT** (P3b Task 6, out of
        // Task 2's review I2, ruled).
        //
        // The caller hands over every foreign stream this Mac remembers,
        // because the photograph's subject cannot be narrowed by person. The
        // EXPECTATION can be, and must: a stream whose slug this register can
        // name a key for is judged by that key's permit and named in that
        // person's own position sweep — it is never in this mark, present or
        // absent. Expecting it meant one iCloud-evicted chapter of an
        // ordinary, admitted, signing device refused every attempt to make
        // anybody a reviewer until the file came back.
        //
        // The other direction is untouched: a remembered stream nothing here
        // names a key for is exactly what this mark is made of, so its absence
        // still refuses (`ForeignStreamWatch.loss`, below).
        //
        // *Cost if the naming is wrong*: a stream whose device record has not
        // synced yet is unattributable today, so it is still expected — the
        // conservative direction, and a refusal that resolves itself.
        let expecting = expecting.filter {
            trust.key(forDeviceSlug: $0.value.deviceSlug) == nil
        }
        let opsDir = projectURL.appendingPathComponent(".maugham/ops")
        let filenames = try OpLogStore.listing(of: opsDir, naming: ".maugham/ops")
        try refuseAnyPlaceholder(
            among: filenames, in: opsDir, forSlugs: nil, kind: .history)
        var docIds = OpLogStore.docIds(inOpsDirectoryFilenames: filenames)
        // Named, because the manuscript reader excludes it by contract — the
        // project's own task stream is as unattributable as any other.
        docIds.insert("__project__")

        var segments: [String: Set<String>] = [:]
        var lastKnownLine: [String: String] = [:]
        // **What this sweep FOUND, per stream this device REMEMBERS** — the
        // third way a snapshot comes back short, and the only one nothing
        // inside this function can see (P3b Task 2, out of Task 1's review).
        //
        // A stream that is simply ABSENT — evicted by iCloud, halfway through
        // a sync — is indistinguishable from a stream that never existed, and
        // a stream the snapshot does not NAME judges wholly new, which holds
        // the whole applied history of the very Mac this photograph exists to
        // leave alone. The memory tells the two apart, and it is `positions`'
        // own memory asked through `positions`' own predicate — never a second
        // spelling of *what did this stream lose*.
        //
        // **It decides REFUSE-or-proceed and never the mark's contents.** The
        // positions below come from the shared bytes exactly as they did, so a
        // fresh Mac with no memory at all computes the same photograph the
        // root does; what it cannot do is notice that a stream went missing
        // while it read.
        var found: [String: ForeignStreamWatch.Found] = [:]
        func note(
            _ key: String, _ change: (inout ForeignStreamWatch.Found) -> Void
        ) {
            guard expecting[key] != nil else { return }
            var entry = found[key] ?? .init()
            change(&entry)
            found[key] = entry
        }
        /// **What a SEGMENT tells the loss check**, whichever branch read it
        /// (fix round 3, minor 3).
        ///
        /// The two questions a segment answers are different and only one of
        /// them is about the mark: `found` is *is this stream still whole* and
        /// `segments` is *is this file old*. A settling branch lists no digest
        /// in the second and must still answer the first — including the arm
        /// the ordinary path has always had, where a container that did not
        /// verify says so (`sawUnsettledSegment`) rather than saying nothing.
        /// Without it a settling sweep over a broken container would refuse
        /// where the ordinary sweep does not, which is a marking verb refusing
        /// for a reason that has nothing to do with the piece being settled.
        func noteSegment(_ digest: String?, _ key: String) {
            guard let digest else {
                note(key) { $0.sawUnsettledSegment = true }
                return
            }
            note(key) {
                $0.digests.insert(digest)
                $0.answered = true
            }
        }

        for docId in docIds.sorted() {
            for url in OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL) {
                guard let stream = PermitMark.stream(of: url),
                      let bytes = try OpLogStore.readCoordinated(url: url, presenter: nil)
                else { continue }
                let classified = OpLogClassifier.classify(
                    url: url, bytes: bytes, state: nil, trust: trust, permit: nil)
                if url.pathExtension == OpLogSegment.fileExtension {
                    // **Noted before the attributability guard, on purpose.**
                    // The memory is of a STREAM's bytes, not of whose it is: a
                    // stream that became attributable since this device last
                    // read it — its device record arrived — has lost nothing,
                    // and refusing over it would stop the verb for a stream
                    // the photograph does not need to name anyway.
                    if let digest = classified.wholeSegmentDigest {
                        note(stream.key) {
                            $0.digests.insert(digest)
                            $0.answered = true
                        }
                    } else {
                        note(stream.key) { $0.sawUnsettledSegment = true }
                    }
                    // A settled segment answers no verification at all, and it
                    // needs none: settling requires a signature whose key this
                    // device stands behind (`TrustVerdict.isOurWord`), which is
                    // the definition of attributable. So a segment reaches the
                    // snapshot only by the fallback WALK saying so — and only
                    // where that walk reached the end of it, which is
                    // `wholeSegmentDigest`'s own rule and the same strictness
                    // `seenPositions` has.
                    guard classified.verification?.unattributable == true,
                          let digest = classified.wholeSegmentDigest
                    else { continue }
                    segments[stream.key, default: []].insert(digest)
                    continue
                }
                guard let verification = classified.verification else { continue }
                note(stream.key) { entry in
                    if verification.head != nil { entry.answered = true }
                    if let head = expecting[stream.key]?.head,
                       ForeignStreamWatch.holds(head, verification) {
                        entry.holdsRemembered = true
                    }
                }
                guard verification.unattributable,
                      let last = verification.lines.last(where: wasSeen)
                else { continue }
                lastKnownLine[stream.key] = OpLogChain.lineHash(last.bytes)
            }
        }

        // The other two families. Neither rotates, so there is no segment rule
        // here and no digest to record — only the last line the reader got to.
        for url in try otherStreamFileURLs(in: projectURL, forSlugs: nil) {
            guard let stream = PermitMark.stream(of: url),
                  let bytes = try OpLogStore.readCoordinated(url: url, presenter: nil)
            else { continue }
            let verification = verificationForPositions(
                at: url, bytes: bytes, stream: stream, trust: trust)
            note(stream.key) { entry in
                if verification.head != nil { entry.answered = true }
                if let head = expecting[stream.key]?.head,
                   ForeignStreamWatch.holds(head, verification) {
                    entry.holdsRemembered = true
                }
            }
            guard verification.unattributable,
                  let last = verification.lines.last(where: wasSeen)
            else { continue }
            lastKnownLine[stream.key] = OpLogChain.lineHash(last.bytes)
        }

        // Sorted, so a sweep short of two streams refuses over the same one
        // twice running — `positions`' rule, asked of `positions`' predicate.
        for key in expecting.keys.sorted() {
            let seen = found[key] ?? .init()
            guard seen.answered,
                  ForeignStreamWatch.loss(
                    remembered: expecting[key], found: seen) == nil
            else { throw OpLogStore.ReadError.streamMissingFromSweep(streamKey: key) }
        }

        var marks: [String: PermitMark.StreamMark] = [:]
        for key in Set(segments.keys).union(lastKnownLine.keys) {
            // Sorted, because `opLogFileURLs` is UNSORTED and a snapshot two
            // devices read from the same bytes must not depend on what
            // `contentsOfDirectory` felt like saying.
            marks[key] = .init(
                segments: segments[key].map { $0.sorted() } ?? [],
                line: lastKnownLine[key])
        }
        return PermitMark(marks)
    }

    /// Every translation sidecar and inbox manifest in this project, in a
    /// stable order (P3a Task 6). Whose they are is decided by the caller off
    /// `PermitMark.stream(of:)`'s slug, exactly as it is for the op streams.
    ///
    /// A directory that is NOT THERE answers empty — a book with no
    /// translations has no such folder and there is nothing to mark. A
    /// directory that exists and **will not list** throws (fix round 1, I2):
    /// the two used to be one `try?`, and the second of them produced a mark
    /// that silently omitted every stream in the folder, which is a mark that
    /// judges every line of them NEW.
    ///
    /// **`slugs` nil is *every stream in the folder***, which is what the
    /// unattributable sweep needs: it does not know whose a file is until it
    /// has read it, and the placeholder refusal below must therefore fire for
    /// any op-log-shaped name rather than for a named few.
    nonisolated static func otherStreamFileURLs(
        in projectURL: URL, forSlugs slugs: Set<String>?
    ) throws -> [URL] {
        var out: [URL] = []
        for (directory, name, kind) in [
            (TranslationStore.directoryURL(in: projectURL),
             ".maugham/translations", OpLogStore.ReadError.FileKind.translation),
            (projectURL.appendingPathComponent(".maugham/inbox"),
             ".maugham/inbox", OpLogStore.ReadError.FileKind.history),
        ] {
            let names = try OpLogStore.listing(of: directory, naming: name)
            try refuseAnyPlaceholder(
                among: names, in: directory, forSlugs: slugs, kind: kind)
            out.append(contentsOf: names.sorted()
                .filter { $0.hasSuffix(".jsonl") }
                .map { directory.appendingPathComponent($0) })
        }
        return out
    }

    /// **The real name an old-style iCloud placeholder stands in for**, or nil
    /// where the name is not one (P3a Task 7, fix round 2, minor B).
    ///
    /// macOS evicts a file's contents and leaves `.<name>.icloud` beside it —
    /// dot-prefixed, `.icloud`-suffixed, and named for nothing this app's own
    /// filename rules recognise. The sweep's suffix filters
    /// (`hasSuffix(".jsonl")`, `docIds(inOpsDirectoryFilenames:)`) therefore
    /// drop it, and a dropped stream is an ABSENT stream, which a mark does
    /// not name, which judges every line of it NEW. It is I2's hole with no
    /// unreadable folder needed — an evicted chapter is enough.
    ///
    /// A dataless file under its REAL name is already caught, by
    /// `readCoordinated` throwing when the bytes will not come; this is the
    /// shape that has no real name to throw over.
    nonisolated static func nameBehindICloudPlaceholder(_ filename: String) -> String? {
        let placeholder = ".icloud"
        guard filename.hasPrefix("."), filename.hasSuffix(placeholder) else { return nil }
        let real = filename.dropFirst().dropLast(placeholder.count)
        return real.isEmpty ? nil : String(real)
    }

    /// **A placeholder standing in for one of these devices' streams is
    /// present-but-unreadable**, and refuses the sweep by the real file's name.
    ///
    /// It is the same ruling as an unreadable file and the same refusal
    /// (RULING-54: present and unreadable is never silently skipped). The
    /// writer's next move is the same too — wait for iCloud, or open the
    /// document to pull it down.
    ///
    /// **This is the SWEEP's rule and nothing else's.** What a LOAD does with
    /// a placeholder is `RecoveryCause`'s and is untouched: a load can offer to
    /// wait and download, where a sweep has only the choice between refusing
    /// and signing a boundary over a reading it knows is short.
    ///
    /// Sorted, so a folder holding two refuses over the same name twice
    /// running and the writer is not chasing a different file each press.
    private nonisolated static func refuseAnyPlaceholder(
        among names: [String], in directory: URL,
        forSlugs slugs: Set<String>?, kind: OpLogStore.ReadError.FileKind
    ) throws {
        for name in names.sorted() {
            guard let real = nameBehindICloudPlaceholder(name),
                  let stream = PermitMark.stream(of: directory.appendingPathComponent(real))
            else { continue }
            // Nil slugs is *any stream of this project's*, legacy included.
            if let slugs {
                guard let slug = stream.deviceSlug, slugs.contains(slug) else { continue }
            }
            throw OpLogStore.ReadError.unreadableFile(
                name: real,
                underlying: "it hasn’t been downloaded from iCloud yet",
                kind: kind)
        }
    }

    /// One translation sidecar or inbox manifest, walked exactly as its own
    /// READER walks it — verify, resolve the absent head, then the permit.
    ///
    /// The same three steps `TranslationStore.loadMerged` and
    /// `JSONLAppendStore.loadVerifiedStrict` take, with ONE difference and it
    /// is deliberate: the remembered head is not consulted (`rememberedHead:
    /// nil`). A mark has to be computable from the shared bytes alone — that is
    /// the whole of spec §3.3, and the reason a mark is not an opId — so a
    /// position that moved with what THIS device happened to remember would
    /// make two Macs cut the same file in two places. `state: nil` throughout
    /// for the same reason and one more: this remembers nothing and writes
    /// nothing.
    private nonisolated static func verificationForPositions(
        at url: URL, bytes: Data, stream: PermitMark.Stream, trust: TrustTable?
    ) -> OpLogChain.Verification {
        // The load's own `OpLogClassifier.walk`, with no remembered head.
        // Arm 2 here too, so both sweeps judge a file the way the LOAD
        // judges it. **It moves `appliedPositions` and not
        // `seenPositions`**: a held or verdict-refused line was seen
        // and judged — `wasSeen` excludes only a torn tail and what a
        // broken chain quarantined — so a mark recording where the
        // root had READ TO is unchanged, while one recording what it
        // APPLIED correctly stops counting a span this device holds.
        // The lookup is over the shared REGISTER, so it moves with the
        // bytes and not with what this Mac happens to remember, which
        // is the whole of spec §3.3 and the reason the remembered head
        // is skipped just above.
        let walked = OpLogClassifier.walk(bytes: bytes, trust: trust,
                                          rememberedHead: nil, url: url)
        let (resolved, _) = OpLogChain.resolveAbsentHead(
            walked, rememberedHead: nil, previousHead: nil)
        guard let trust else { return resolved }
        let judge: PermitJudge
        switch stream.kind {
        case .translation: judge = .translation(ofPiece: stream.docId, trust: trust)
        case .inbox: judge = .inbox(trust: trust)
        case .ops: return resolved
        }
        return PermitPartition.partition(of: resolved, file: url, judging: judge)
    }
}
