// Maugham/Stores/DocumentStore+Registry.swift
import Foundation
import MaughamCore
import os

private let registryVerbLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "RegistryVerbs")

/// **Revocation and retirement, as this window performs them** (signed op log
/// P2b, spec §5).
///
/// `admit`'s two peers, in a file of their own and in its shape: write the
/// record off the main actor, then tell every reader in this project to forget
/// the trust table it resolved, then re-read what is open. The order is the
/// contract there and it is the contract here — a revocation that reached the
/// registry and not the readers is a device the writer believes they shut out
/// and whose words keep arriving in the draft in front of them.
///
/// **Nothing here decides who may do what.** `RegistryAdmission` refuses a
/// non-root, a root target and a device retiring somebody else, and the refusal
/// is thrown rather than swallowed (RULING-7). This file computes the one thing
/// the registry cannot know by itself — how far this Mac had got with that
/// device's history — and does the telling afterwards.
extension DocumentStore {

    /// **Revoke a person**, in one of the two ways the writer chose. Answers
    /// the record that now stands for them.
    ///
    /// **The default keeps what this Mac had already applied** (find 5, ruled
    /// 2026-09-18). `highestOpIdApplied` is computed here rather than read off
    /// the folder, because it is a fact about THIS Mac's reading: the highest
    /// opId it had actually applied from that device, anywhere in the project.
    /// Everything at or below it stays in the book — it was there before the
    /// writer revoked anybody — and everything above it is set aside. Nothing
    /// is newly trusted by that; see `RevocationSplit`.
    ///
    /// **`.everything` is the other choice**, and it is the behaviour a
    /// revocation had before the ruling: no mark is recorded, so no line of
    /// theirs was ever *already here* and the whole history leaves the book
    /// until they are re-admitted. It is the writer's to pick, in words that
    /// say what it costs (`PeopleAndDevicesConfirmation`).
    ///
    /// The mark is computed only for the default: asking how far this Mac had
    /// got is a project-wide read, and the total revocation does not turn on
    /// the answer.
    @discardableResult
    public func revoke(
        person fingerprint: String, keeping scope: RevocationScope = .whatWasApplied
    ) async throws -> PersonRecord {
        let projectURL = self.projectURL
        let author = Document.loadIdentities.author
        let cache = Document.loadRegistryCache
        let mark: String?
        switch scope {
        case .whatWasApplied:
            switch await highestOpIdApplied(fromPerson: fingerprint) {
            case .upTo(let opId):
                mark = opId
            case .nothingApplied:
                // A real mark, not nil (find-5 review, the High). Nil is the
                // one spelling of *set aside everything it wrote*, so writing
                // it here would record the harsh choice over the gentle press
                // and History would narrate it as one. The lowest ULID keeps
                // exactly nothing, which is the truth.
                mark = RevocationScope.nothingAppliedMark
            case .unreadable(let name):
                // Refuse rather than record a mark that came back short: short
                // silently widens what the revocation takes back, and shortest
                // of all is indistinguishable from the other button.
                throw RegistryAdmissionError.historyUnreadable(name: name)
            }
        case .nothing:
            mark = nil
        }
        // **The same line in the other format** (P3a Task 7, spec §3.3). The
        // opId stays, for every P2-era reader; the event beside it carries the
        // chain POSITIONS this Mac had APPLIED, which is the one act whose mark
        // means applied rather than seen, and which nothing the revoked device
        // writes afterwards can move. `.nothing` records an empty mark, which
        // judges every line new — `nothingAppliedMark`'s meaning, said in
        // positions.
        let positions: PermitMark
        switch scope {
        case .whatWasApplied:
            switch await permitMark(forPerson: fingerprint, seen: false) {
            case .mark(let found):
                positions = found
            case .unreadable(let name):
                throw RegistryAdmissionError.historyUnreadable(name: name)
            }
        case .nothing:
            positions = .nothingApplied
        }
        let record = try await Task.detached(priority: .userInitiated) {
            try RegistryAdmission.revoke(
                person: fingerprint, in: projectURL, by: author,
                highestOpIdSeen: mark, mark: positions, cache: cache)
        }.value

        await settle(after: "revoking", DeviceCode.short(fingerprint))
        return record
    }

    /// **Change what one person may write** — the root's verb, and P3b's pane's
    /// one door to it (P3 spec §6).
    ///
    /// Three acts in `admit`'s own order: compute the mark, write the event and
    /// then the record off the main actor, and tell every reader in this
    /// project to forget the table it resolved. The third is not optional here
    /// — this verb moves what an open document APPLIES, so a change that
    /// reached the registry and not the readers is a demotion the writer has
    /// made and cannot see.
    ///
    /// **The mark is `seenPositions`, not `appliedPositions`** (spec §3.3, as
    /// corrected). A mark does not bless lines, it selects which permit judges
    /// them — so *the last line applied* would make a promotion pardon the text
    /// sitting refused at the end of what this Mac had read, and would make a
    /// demotion reach back through a segment holding one refused line among a
    /// thousand honest ones. The position is the last line this Mac SAW and
    /// judged, whatever it then did with it.
    ///
    /// **The open documents need no folding in, and that is a fact about the
    /// two marks rather than an omission.** `highestOpIdApplied` folds
    /// `opLogSnapshot` because an opId is a value carried in memory; a position
    /// is the hash of a LINE, and a line exists only once it is in a file.
    /// `Document.appendToMirror` runs after `opStore.append` returns, so every
    /// op in an open document's mirror is already on disk and the sweep below
    /// reads it. What is NOT on disk is the pending keystroke buffer, which has
    /// no line and therefore no hash — and which is not in the op log at all,
    /// so no mark of any shape could name it.
    @discardableResult
    public func changePermit(
        person fingerprint: String, to permit: Permit
    ) async throws -> PersonRecord {
        try await changePermit(person: fingerprint, to: permit, settling: [])
    }

    /// **The same verb, told which pieces this act SETTLES** (fix round 1's
    /// C1, made internal in fix round 3's minor 4).
    ///
    /// `settling` is not a knob: it names the pieces whose §4.5 question this
    /// act is answering, and passing it writes them onto the event as
    /// `settled` — *these pieces were hers all along*, which `PermitTimeline`
    /// reads BY REASON (P3b smoke find F9, Denver's ruling of 2026-09-23). The
    /// mark is the ordinary one. Exactly one caller has an answer to give —
    /// `pieceIsTheirs` — so the parameter is internal and the public verb
    /// above is the signature every other surface has always called.
    func changePermit(
        person fingerprint: String, to permit: Permit,
        settling: Set<String>
    ) async throws -> PersonRecord {
        // Refuse rather than record a mark that came back short, for the
        // revocation's reason: a short mark moves a permission boundary
        // silently, and the direction it moves it in is *more set aside than
        // the writer asked for*.
        let mark = try await sweptPermitMark(forPerson: fingerprint)
        let unsigned = try await sweptUnsignedSnapshot(for: permit)
        // Gate, then event, then record (P3b Task 3).
        try await gateOldBuildsOut(before: permit)
        return try await changePermit(
            person: fingerprint, to: permit, mark: mark, unsigned: unsigned,
            settling: settling)
    }

    /// **Shut older builds out of this book before it is narrowed** (P3b
    /// Task 3's MUST) — and do nothing at all to a book that is not being
    /// narrowed.
    ///
    /// ## Why a version number is load-bearing here
    ///
    /// The moment a person in this book is anything other than an author of the
    /// whole of it, reading the book means judging every line against a permit.
    /// A build without a permit layer — v0.40 and everything before it — cannot
    /// do that. It applies the reviewer's refused text, folds it into the
    /// manuscript, and its own next burst re-asserts those words in ITS file
    /// under ITS book-author key, which every signed Mac then has to accept.
    /// The writer's demotion is undone by the oldest machine in the house, with
    /// nothing anywhere saying it happened. `ProjectManifest
    /// .decodeGuardingSchema` is the only thing that can stop that, and the way
    /// it stops it is by refusing the project.
    ///
    /// ## The order, and why this way round
    ///
    /// Gate → event → record. A crash after the gate and before the event
    /// leaves a **gated, un-narrowed book**: one old build loses one project it
    /// could still open yesterday, which is a nuisance the writer can see and
    /// ask about. The reverse order leaves a **narrowed, ungated book**, which
    /// is the defect above with nothing to say so. If the gate cannot be
    /// written the verb refuses (`RegistryAdmissionError.manifestNotGated`) and
    /// no event exists.
    ///
    /// ## What it touches
    ///
    /// Only the number, and only upwards, and only once: a book already at this
    /// build's schema is left byte-identical, so the SECOND narrowing writes no
    /// manifest at all — and a non-narrowing admission, revocation, retirement
    /// or rename never gets here. The bytes go through `writeManifest`, the
    /// store's own coordinated door, with `ProjectManifest`'s own encoder (never
    /// hand-written JSON — tripwire 14's neighbourhood).
    ///
    /// ## The in-memory copy
    ///
    /// `ProjectStore` holds the manifest and re-encodes ITS copy on every
    /// structural save, and `schemaVersion` is a DECODED field carried through
    /// that round trip rather than re-stamped. So a gate written behind the
    /// live store's back is undone by the writer's next chapter rename. The
    /// open store is told what disk now says — a cache refresh after the one
    /// write, not a second writer — and it is a weak, optional reference for
    /// exactly `ProjectStore.documentStore`'s reason: a headless or transient
    /// store has none, and its gate is on disk where it belongs whether or not
    /// anybody is looking at the project.
    /// Internal rather than private for `sweptUnsignedSnapshot`'s reason: the
    /// admission door lives one file over and is the other narrowing verb.
    func gateOldBuildsOut(
        before permit: Permit, act: RegistryAdmissionError.Act = .permitChange
    ) async throws {
        guard permit.narrows else { return }
        do {
            let manifest = try ProjectManifest.decodeGuardingSchema(
                try await readManifest())
            if manifest.schemaVersion < ProjectManifest.currentSchemaVersion {
                var raised = manifest
                raised.schemaVersion = ProjectManifest.currentSchemaVersion
                try await writeManifest(
                    try ProjectManifest.makeEncoder().encode(raised))
            }
        } catch {
            throw RegistryAdmissionError.manifestNotGated(
                reason: error.localizedDescription, act: act)
        }
        // On BOTH paths, including the one that wrote nothing: a book already
        // gated by another Mac, whose gate synced in after this window opened,
        // leaves the same stale in-memory number behind the same next save.
        // Never downwards — a live store at a HIGHER number than this build
        // writes is a newer build's manifest, and lowering it is the forward-
        // data-loss `decodeGuardingSchema` exists to refuse.
        if let live = projectStore,
           live.manifest.schemaVersion < ProjectManifest.currentSchemaVersion {
            live.manifest.schemaVersion = ProjectManifest.currentSchemaVersion
        }
    }

    /// **The photograph, where this act is the kind that needs one** (P3b
    /// Task 1) — nil for every permit that leaves the person an author of the
    /// whole book.
    ///
    /// The question is asked of the permit layer (`Permit.narrows`) rather
    /// than by comparing a rung here: a store that decided for itself what
    /// narrowing meant would be a second answer to the one thing
    /// `TrustTable.unsignedSnapshot` and `RegistryAdmission`'s door already
    /// agree on (tripwire 47).
    ///
    /// **Taken ONCE per book** (P3c Task 7, Ruling Q): where the book is
    /// already narrowed, the governing snapshot's own mark is returned and
    /// nothing is walked, so every later narrowing event carries the same
    /// photograph and no event's date can move the cliff.
    ///
    /// **And nothing pays for it that does not need it.** The sweep is a walk
    /// of every op-log file, every translation sidecar and every inbox
    /// manifest in the project; an ordinary admission narrows nobody, so it
    /// performs zero extra directory listings and its event's bytes are
    /// unchanged.
    ///
    /// Refuses in `historyUnreadable`'s own words, like every other sweep
    /// here: *a short snapshot is the reach-back this ruling exists to
    /// prevent*, so a folder this Mac could only half read must stop the act
    /// rather than narrow the book over a reading it knows is short.
    /// Internal rather than private, for `seenMarkOrRefuse`'s reason: the
    /// admission door lives one file over and must ask the same question.
    /// Bumped once per sweep actually performed — never where a governing
    /// photograph was carried forward instead (P3c Task 7, Ruling Q). The
    /// counter a test pins *no sweep ran* by.
    ///
    /// **Keyed by the project folder and behind a lock** (P3c plan 2 Task 9).
    /// Task 7's hook was a `nonisolated(unsafe)` closure one test set and
    /// cleared: a second test setting it in the same process — or a sweep
    /// still in flight from an earlier one — would have raced it or counted
    /// into the wrong answer. A test reads the count for its OWN folder, so
    /// nothing is set and nothing needs clearing. It counts in production
    /// too: one locked increment beside a sweep that walks the whole folder.
    static let unsignedSweepsForTesting = UnsignedSweepCounter()

    func sweptUnsignedSnapshot(
        for permit: Permit, act: RegistryAdmissionError.Act = .permitChange
    ) async throws -> PermitMark? {
        guard permit.narrows else { return nil }
        let projectURL = self.projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let state = Document.loadDeviceState
        let swept: Result<PermitMark, Error> = await Task.detached(
            priority: .userInitiated
        ) { () -> Result<PermitMark, Error> in
            do {
                let resolved = try TrustResolution.resolveVerified(
                    projectURL: projectURL, identities: identities, cache: cache)
                // **A book already narrowed carries its governing photograph
                // FORWARD** (P3c Task 7, Ruling Q). The earliest narrowing
                // governs by `(at, event)`, and `at` is the narrowing root's
                // own clock: a later event whose clock reads earlier — two
                // adopted roots a few minutes apart, or a clock that stepped
                // back — governs instead. Were its photograph empty (`{}`), or
                // taken now, the cliff would move; were it empty, every
                // unsigned line ever written, P1-era text included, would be
                // held on every Mac. The same happens with no skew at all on
                // a fresh Mac whose sync delivers the later event first. The
                // governor's own mark written forward makes the photograph
                // identical whichever event governs — and costs no sweep.
                if let governing = resolved.table.unsignedSnapshot {
                    return .success(governing.mark)
                }
                DocumentStore.unsignedSweepsForTesting.bump(projectURL)
                return .success(try OpLogStore.unattributablePositions(
                    in: projectURL, trust: resolved.table,
                    // What this Mac remembers having applied from ANY other
                    // device, so a stream that has gone missing mid-sync
                    // refuses the act rather than silently drawing the line at
                    // the beginning of it (P3b Task 2).
                    expecting: DocumentStore.everyExpectedStream(
                        in: projectURL, state: state)))
            } catch {
                return .failure(error)
            }
        }.value
        switch swept {
        case .success(let mark): return mark
        case .failure(let error):
            throw RegistryAdmissionError.historyUnreadable(
                name: OpLogStore.unreadableName(error), act: act)
        }
    }

    /// **The permit an admission of this fingerprint would INSTALL** — nil
    /// where it would install none (Task 1's review, Minor 7).
    ///
    /// `RegistryAdmission.standingRecord` is the rule and it is Core's; this
    /// only reads the folder to ask it. The answer decides whether the two
    /// prices of writing a narrowing event — the book's photograph and the
    /// schema gate — are owed at all, so it is asked before either is paid.
    ///
    /// A registry that will not read is NOT swallowed: it throws here, and the
    /// admission would have thrown a moment later for the same reason. The one
    /// thing this must not do is answer *nothing is being installed* over a
    /// folder it could not see, which would take the photograph away from an
    /// act that does narrow the book.
    ///
    /// Detached for `TrustResolution`'s own rule: a folder read and a signature
    /// check per record. Internal rather than private for
    /// `sweptUnsignedSnapshot`'s reason: the admission door lives one file
    /// over and is the caller that needs the answer.
    func permitThisAdmissionInstalls(
        asked: Permit, for fingerprint: String
    ) async throws -> Permit? {
        let projectURL = self.projectURL
        let cache = Document.loadRegistryCache
        let standing = try await Task.detached(priority: .userInitiated) {
            () -> Bool in
            let registry = try TrustResolution.verifiedRegistry(
                projectURL: projectURL, presenter: nil, cache: cache)
            return RegistryAdmission
                .standingRecord(registry.person(fingerprint)) != nil
        }.value
        return standing ? nil : asked
    }

    /// `changePermit`'s sweep, alone — so the plural verb below can take every
    /// record's mark BEFORE it writes any of them (fix round 1, minor 2).
    private func sweptPermitMark(
        forPerson fingerprint: String
    ) async throws -> PermitMark {
        switch await permitMark(forPerson: fingerprint, seen: true) {
        case .mark(let found): return found
        case .unreadable(let name):
            throw RegistryAdmissionError.historyUnreadable(
                name: name, act: .permitChange)
        }
    }

    /// `changePermit`'s write, over a mark already swept.
    @discardableResult
    private func changePermit(
        person fingerprint: String, to permit: Permit, mark: PermitMark,
        unsigned: PermitMark?, settling: Set<String> = []
    ) async throws -> PersonRecord {
        let projectURL = self.projectURL
        let author = Document.loadIdentities.author
        let cache = Document.loadRegistryCache
        let record = try await Task.detached(priority: .userInitiated) {
            try RegistryAdmission.changePermit(
                person: fingerprint,
                role: permit.wireRole, scope: permit.wireScope,
                pieces: permit.wirePieces, mark: mark, unsigned: unsigned,
                settling: settling,
                in: projectURL, by: author, cache: cache)
        }.value

        await settle(after: "changing what may be written by",
                     DeviceCode.short(fingerprint))
        return record
    }

    /// **Change what one WRITER may write — every machine of theirs at once**
    /// (fix round 1, I3). **This is the verb P3b's pane calls**, and
    /// `changePermit(person:to:)` is the single-record primitive underneath it.
    ///
    /// A permit lives on a person RECORD and a record is one device. P2b's
    /// admission merges a typed label matching a known one under that label's
    /// own spelling, so a writer whose Mac and phone were both let in is two
    /// records the root has said are one person. Demote the Mac alone and she
    /// goes on writing manuscript text from the phone — applied by every
    /// reader, with nothing anywhere saying why. A pane that offered *make Sam
    /// a reviewer* and did half of it would be worse than one that offered
    /// nothing.
    ///
    /// **It refuses the whole act up front, and *up front* now means the
    /// sweeps as well as the outcomes** (fix round 1, minor 2). Every record is
    /// put to `RegistryAdmission.changePermitOutcome` — so a set containing a
    /// root, or somebody another root admitted, is refused entire — and then
    /// every record's MARK is swept, before a byte is written. A stream that
    /// has gone missing under the third machine is knowable before the first
    /// one moves, and a writer who is going to be refused should be refused
    /// with nothing changed rather than with two of three records re-signed.
    ///
    /// **Each record gets its OWN mark and its own event**, swept for that
    /// machine's own streams: the two devices have read to different places
    /// and a shared mark would draw one of the two lines in the wrong file.
    /// The sweeps stay one per record — this holds their answers, it does not
    /// fold them into one pass.
    ///
    /// **A write that fails midway names what moved**, and that is now all
    /// `PermitChangePartlyApplied` ever means: a genuine failure of the WRITE,
    /// with the readable half of the world already checked. The records are
    /// ordered (the subject first, then by fingerprint), so the error says
    /// exactly which permits changed and which did not, and pressing again
    /// finishes the job — each record's own verb is idempotent in both halves.
    @discardableResult
    public func changePermit(
        everyRecordOf person: String, to permit: Permit
    ) async throws -> [PersonRecord] {
        try await changePermit(everyRecordOf: person, to: permit, settling: [])
    }

    /// The plural verb's own settling form; internal for the singular's
    /// reason (fix round 3, minor 4).
    @discardableResult
    func changePermit(
        everyRecordOf person: String, to permit: Permit,
        settling: Set<String>
    ) async throws -> [PersonRecord] {
        let projectURL = self.projectURL
        let author = Document.loadIdentities.author
        let cache = Document.loadRegistryCache
        let registry = try await Task.detached(priority: .userInitiated) {
            try TrustResolution.verifiedRegistry(
                projectURL: projectURL, presenter: nil, cache: cache)
        }.value

        // **A REVOKED subject is a refusal, not a quiet no-op** (fix round 2,
        // minor A). The loop below would skip her own record as it skips a
        // revoked sibling's, press would do nothing, and the pane would draw
        // the old permit with no sentence saying why. Re-admit her first; the
        // re-admission carries a permit of its own.
        guard let subject = registry.person(person), !subject.isRevoked else {
            throw RegistryAdmissionError.notAdmitted(fingerprint: person)
        }
        // **Revoked siblings are left out; RETIRED ones are not** (fix round
        // 2, minor A). A revoked machine's lines are refused by the VERDICT,
        // which outranks any permit, so writing a `roleChanged` on its record
        // would put *became a reviewer* in History AFTER the revocation — a
        // row about a machine that is already shut out, and a re-signed record
        // nobody asked for. A later re-admission brings its own permit. A
        // RETIRED machine is the opposite case: its pre-retirement lines are
        // still judged by permit, so a demotion must reach it.
        //
        // The label rule itself stays label-only
        // (`RegistryAdmission.records(sharingLabelWith:in:)`): who is the same
        // WRITER is one question, and who this act should touch is another.
        let records = RegistryAdmission
            .records(sharingLabelWith: person, in: registry)
            .filter { !$0.isRevoked }
        guard !records.isEmpty else {
            throw RegistryAdmissionError.notAdmitted(fingerprint: person)
        }
        // Up front, before anything is written: the whole act or none of it.
        // Both halves — who may be changed, and whether this Mac can say where
        // each of their streams stood.
        for record in records {
            _ = try RegistryAdmission.changePermitOutcome(
                person: record.person, by: author.fingerprint, in: registry).get()
        }
        var marks: [String: PermitMark] = [:]
        for record in records {
            marks[record.person] = try await sweptPermitMark(
                forPerson: record.person)
        }
        // **One photograph for the whole act** (P3b Task 1). The snapshot is
        // of the BOOK's unsigned streams, not of this person's, so sweeping it
        // per record would be the same walk three times over — and the three
        // answers would differ by whatever iCloud did in between, leaving one
        // writer's machines carrying three different accounts of when the book
        // was first narrowed. Taken here, with the marks, so an unreadable
        // folder refuses before a byte is written.
        let unsigned = try await sweptUnsignedSnapshot(for: permit)
        // **Gated ONCE, first, for the whole act** (P3b Task 3). The gate is
        // about the BOOK rather than about a record, so the loop below must not
        // reach it: the second record's gate would be a no-op anyway, and a
        // manifest that could not be written must refuse before the first
        // record moves rather than half way through three of them.
        try await gateOldBuildsOut(before: permit)

        var moved: [PersonRecord] = []
        for record in records {
            do {
                moved.append(try await changePermit(
                    person: record.person, to: permit,
                    mark: marks[record.person] ?? .nothingApplied,
                    unsigned: unsigned, settling: settling))
            } catch {
                throw PermitChangePartlyApplied(
                    moved: moved.map(\.person), failed: record.person,
                    underlying: error)
            }
        }
        return moved
    }

    /// **Rename a person.** Answers the record that now carries the new word.
    ///
    /// The one verb here that moves no verdict at all: a label is what this
    /// book calls somebody, and `TrustTable` has never read one. It still goes
    /// through `settle` with the others, because the surfaces that DO read a
    /// label — the Inbox byline, History's rows, this pane — refresh on the
    /// event it posts, and a rename nobody announced would leave the writer
    /// looking at the name they just corrected.
    @discardableResult
    public func rename(person fingerprint: String, to label: String) async throws -> PersonRecord {
        let projectURL = self.projectURL
        let author = Document.loadIdentities.author
        let cache = Document.loadRegistryCache
        let memory = Document.loadAdmissionMemory
        let record = try await Task.detached(priority: .userInitiated) {
            try RegistryAdmission.rename(
                person: fingerprint, to: label, in: projectURL, by: author,
                cache: cache, memory: memory)
        }.value

        await settle(after: "renaming", DeviceCode.short(fingerprint))
        return record
    }

    /// **Put a registry record back** (P2 smoke find 1). Answers the file it
    /// wrote.
    ///
    /// The bytes are this device's own memory of a record it verified, and the
    /// write is `RegistryCache.restore` — the same door `reconcile` uses for a
    /// record that VANISHED, pressed here over one that is present and will not
    /// verify. Nothing is signed: the next read checks the signature on those
    /// bytes like any other record's.
    @discardableResult
    public func restore(record ref: RecordRef) async throws -> URL {
        let projectURL = self.projectURL
        let cache = Document.loadRegistryCache
        let url = try await Task.detached(priority: .userInitiated) {
            try cache.restore(ref, in: projectURL)
        }.value

        await settle(after: "putting back the record for",
                     DeviceCode.short(ref.fingerprint))
        return url
    }

    /// **Retire this device.** A device signs its own retirement, so the only
    /// fingerprint this Mac can pass is its own author key — `RegistryAdmission`
    /// refuses anything else, and People & Devices offers the button on one row
    /// for the same reason.
    @discardableResult
    public func retire(device fingerprint: String) async throws -> DeviceRecord {
        let projectURL = self.projectURL
        let author = Document.loadIdentities.author
        let cache = Document.loadRegistryCache
        // **Its own files, and everything it wrote it both saw and applied**
        // (P3a Task 7, ruling 2C). The mark is what *written while retired* is
        // derived from on every OTHER device: a line of this Mac's after it is
        // one written after this Mac said it had stopped.
        //
        // **And a short reading refuses, exactly as the other three do** (fix
        // round 2). This arm recorded `.nothingApplied` and let the retirement
        // through, which is the I2 defect wearing a different hat: an empty
        // mark calls EVERY paragraph this machine ever wrote *written while
        // retired*, so every other Mac would set aside this machine's whole
        // history under a sentence that is false about nearly all of it.
        // (P3b's *N paragraphs — bring them in?* question, which this comment
        // used to name, was WITHDRAWN on 2026-09-23: a retirement is one-way
        // and what follows it is set aside rather than held, so there is
        // nothing to bring in and the Inbox is the way back. The refusal below
        // matters more for it, not less.) A retirement is not typing —
        // refusing one breaks no
        // constitutional must — and a folder that will not read is a fact the
        // writer can fix, while a mark signed over it is not. The root can
        // still revoke a device whose folder will not open.
        //
        // The `expectedStreams` half stays as Task 9 left it: this verb's
        // subject is its own machine, which names no FOREIGN stream, so the
        // memory answers empty and the refusal here is for a directory that
        // will not list or a file that will not read.
        let positions: PermitMark
        switch await permitMark(forPerson: fingerprint, seen: true) {
        case .mark(let found):
            positions = found
        case .unreadable(let name):
            throw RegistryAdmissionError.historyUnreadable(name: name, act: .retirement)
        }
        let record = try await Task.detached(priority: .userInitiated) {
            try RegistryAdmission.retire(
                device: fingerprint, in: projectURL, by: author,
                mark: positions, cache: cache)
        }.value

        await settle(after: "retiring", DeviceCode.short(fingerprint))
        return record
    }

    /// **Claim this book, and adopt the history it holds** (spec §5, P2b Task
    /// 8). Answers the claim record that now stands for this Mac.
    ///
    /// Two surfaces reach it and they are the same act: the sheet a Mac in no
    /// chain is shown at open, which adopts every root it found, and People &
    /// Devices' *Merge: this is also me*, which adopts one claimant. Adoption
    /// is symmetric — the other Mac makes the same call naming this one — and
    /// neither half moves anybody's root (B1).
    ///
    /// The settle afterwards is what makes it visible: every table in flight
    /// was resolved while this device had no chain at all, so the adopted
    /// history would otherwise go on reading as unsigned until the next open.
    @discardableResult
    public func claim(adopting roots: [String]) async throws -> ClaimRecord {
        let projectURL = self.projectURL
        let author = Document.loadIdentities.author
        let cache = Document.loadRegistryCache
        let record = try await Task.detached(priority: .userInitiated) {
            try RegistryAdmission.claim(
                adopting: roots, in: projectURL, by: author, cache: cache)
        }.value

        await settle(after: "claiming", DeviceCode.short(record.newRoot))
        return record
    }

    /// **Admit, without asking, everyone this writer has already named** —
    /// decision B2 away from the project open (find 4, 2026-09-17). Answers the
    /// records it wrote, empty when it wrote none.
    ///
    /// `DocumentStore.open` makes the same call inline, before the first
    /// `Document.load`, and until this existed that was the ONLY place it was
    /// made: a device whose history arrived mid-session — a window open for
    /// days, a phone syncing in — put the sheet up again over a label this Mac
    /// had already decided. The verb is `RegistryPresence.admitRemembered`
    /// either way, because two paths admitting by two rules is two answers to
    /// *have I met you before*.
    ///
    /// It refuses nothing and throws nothing: `admitRemembered` admits nobody
    /// unless this Mac is a root here, leaves alone every device the folder
    /// already has a person record for, and a registry that will not read is
    /// logged rather than raised — there is no writer waiting on a button, and
    /// the sheet behind this is the recourse if it wrote nothing.
    ///
    /// The settle runs only when something was admitted, so the
    /// `admissionSettled` post cannot drive a window that re-derives its queue
    /// from it back round for a second helping.
    @discardableResult
    public func admitRemembered() async -> [PersonRecord] {
        let projectURL = self.projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let memory = Document.loadAdmissionMemory
        let state = Document.loadDeviceState
        let admitted: [PersonRecord]
        do {
            admitted = try await Task.detached(priority: .userInitiated) {
                try RegistryPresence.admitRemembered(
                    in: projectURL, identities: identities, cache: cache,
                    memory: memory,
                    // Asked per device actually admitted, which on the ordinary
                    // open is nobody at all: the sweep behind it walks every
                    // op-log file in the project, and paying for one at every
                    // open of every book would be paying to admit no one.
                    mark: {
                        try DocumentStore.rememberedAdmissionMark(
                            forPerson: $0, in: projectURL,
                            identities: identities, cache: cache, state: state)
                    })
            }.value
        } catch {
            registryVerbLog.error(
                "remembered admission in \(projectURL.lastPathComponent, privacy: .public) could not read the registry: \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard !admitted.isEmpty else { return [] }
        for record in admitted {
            registryVerbLog.info(
                "admitted \(DeviceCode.short(record.person), privacy: .public) as \(record.label, privacy: .public) in \(projectURL.lastPathComponent, privacy: .public), remembered from an earlier book")
        }
        await settle(after: "admitting", admitted.map { DeviceCode.short($0.person) }
            .joined(separator: ", "))
        return admitted
    }

    /// Forget every resolved table, re-read every open document, and say so —
    /// `admit`'s own third act, shared rather than spelled twice.
    ///
    /// A re-read that throws is logged and never rethrown: the record IS
    /// written, and reporting the whole act as failed would have the writer
    /// press again over a device that is already revoked.
    private func settle(after verb: String, _ subject: String) async {
        invalidateTrust()
        for document in allOpenDocuments() {
            do { try await reReadAfterExternalChange(document) }
            catch {
                registryVerbLog.error(
                    "re-read after \(verb, privacy: .public) \(subject, privacy: .public) failed for \(document.docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        MaughamEvent.postAdmissionSettled(projectURL: projectURL)
    }

    // MARK: - What this Mac had already applied

    /// **How far this Mac had got with one device** — the revocation mark, and
    /// the three things it can honestly be (find-5 review, the High).
    ///
    /// A single optional could not tell *this book applies nothing of theirs*
    /// from *a file would not read*, and both came back nil. Nil is the wire
    /// spelling of *set aside everything it wrote*, so a read hiccup turned the
    /// writer's gentle press into the harsh choice and History narrated it as
    /// one. Three cases, and the caller must answer all three.
    private enum AppliedMark {
        case upTo(String)
        /// This project applies nothing this device wrote. A real state, and
        /// NOT the same as not knowing.
        case nothingApplied
        /// A file or the registry is present and would not read. The revocation
        /// refuses; nothing is written.
        case unreadable(name: String)
    }

    /// The highest opId this Mac APPLIES from `person`, over every op-log file
    /// in the project and every document it has open.
    ///
    /// **Over the whole project, not over what is open** (find 5's ruling).
    /// This number decides what a revocation KEEPS, and computed off the open
    /// documents alone it was nil for a writer who revoked from Project
    /// Settings with no chapter open — which is the ordinary way to reach the
    /// button.
    ///
    /// **Off the main actor, whole** — the listing included
    /// (`OpLogStore.highestAppliedOpId`, `nonisolated`). Measured at ~0.25 s per
    /// 20,000-line file, a book of forty would have frozen the window for about
    /// ten seconds behind the confirmation.
    ///
    /// The open documents are still read, from memory and on the main actor
    /// where they live: an op appended a moment ago may not have reached its
    /// file, and a mark that missed it would take the writer's newest paragraph
    /// out of the draft in front of them. That read is a walk of arrays already
    /// in hand.
    ///
    /// The match is `DeviceIdentity.deviceId(actor:fingerprint:)` over the
    /// device record's own actor keys: an op carries the id its writer wrote
    /// under, and the registry carries the keys, and joining them anywhere but
    /// there would be a second opinion about what a device id is.
    private func highestOpIdApplied(fromPerson person: String) async -> AppliedMark {
        let projectURL = self.projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache

        struct Swept: Sendable {
            let mark: String?
            /// The op-log device ids that person writes under, resolved beside
            /// the sweep so the registry is read once rather than twice.
            let ids: Set<String>
        }
        let swept: Result<Swept, Error> = await Task.detached(
            priority: .userInitiated
        ) { () -> Result<Swept, Error> in
            do {
                let resolved = try TrustResolution.resolveVerified(
                    projectURL: projectURL, identities: identities, cache: cache)
                let ids = DocumentStore.opLogDeviceIds(
                    ofPerson: person, in: resolved.registry)
                return .success(Swept(
                    mark: try OpLogStore.highestAppliedOpId(
                        ofDeviceIds: ids, in: projectURL, trust: resolved.table),
                    ids: ids))
            } catch {
                return .failure(error)
            }
        }.value

        let found: Swept
        switch swept {
        case .failure(let error):
            // A registry that will not read is named the way an unreadable
            // op-log file is, through the one door that knows which it was.
            return .unreadable(name: OpLogStore.unreadableName(error))
        case .success(let value):
            found = value
        }

        // Anything written since those bytes were flushed.
        var highest = found.mark
        for document in allOpenDocuments() {
            for op in document.opLogSnapshot where found.ids.contains(op.device) {
                if highest == nil || op.opId > highest! { highest = op.opId }
            }
        }
        return highest.map(AppliedMark.upTo) ?? .nothingApplied
    }

    /// **The op-log device ids one person writes under** — the join, spelled
    /// once because four verbs need it now (P3a Task 7).
    ///
    /// An op carries the id its writer wrote under and the registry carries the
    /// keys; joining them anywhere but `DeviceIdentity.deviceId(actor:
    /// fingerprint:)` would be a second opinion about what a device id is. With
    /// no device record for them — a real state, because a person record and a
    /// device record are two files that sync separately — a person IS a
    /// device's author key under labels-only, so the one id they can have
    /// written under is that key's own.
    nonisolated static func opLogDeviceIds(
        ofPerson person: String, in registry: Registry
    ) -> Set<String> {
        guard let record = registry.devices.first(where: { $0.device == person })
        else {
            return [DeviceIdentity.deviceId(
                actor: DeviceActor.author.rawValue, fingerprint: person)]
        }
        return Set(record.actors.map { actor, key in
            DeviceIdentity.deviceId(actor: actor, fingerprint: key)
        })
    }

    /// **Where this Mac had got to in one person's streams, as chain
    /// positions** — `highestOpIdApplied`'s P3 sibling (spec §3.3).
    ///
    /// `seen` picks which of the two questions the store answers, and the two
    /// are not interchangeable: a PERMIT event records what this root had read
    /// and judged, so that a promotion pardons nothing and a demotion reaches
    /// back through nothing; a REVOCATION records what it had APPLIED, because
    /// *keep what this Mac already had* is about the draft the writer has been
    /// reading. `OpLogStore` holds both and this chooses.
    ///
    /// Off the main actor whole, the listing included, for its sibling's
    /// reason: it is a walk of every op-log file, every translation sidecar and
    /// every inbox manifest in the project, and a window frozen behind a
    /// confirmation is the thing that measurement bought back.
    ///
    /// Two answers, not three. A sweep either produced a mark or could not read
    /// something — there is no *nothing applied* case to tell apart, because an
    /// empty `PermitMark` is a first-class value meaning exactly that and
    /// judging every line new.
    /// `permitMark(forPerson:seen: true)`, with an unreadable sweep turned into
    /// the refusal three of the four verbs make of it.
    ///
    /// Shared with `DocumentStore.admit`, which lives one file over and cannot
    /// see `SweptPositions` — and which must not swallow the unreadable case,
    /// because an admission of somebody REVOKED is a re-admission whose mark is
    /// where their new permit starts.
    func seenMarkOrRefuse(forPerson person: String) async throws -> PermitMark {
        switch await permitMark(forPerson: person, seen: true) {
        case .mark(let found): return found
        case .unreadable(let name):
            throw RegistryAdmissionError.historyUnreadable(name: name, act: .admission)
        }
    }

    /// The same sweep for the SILENT path, which has no writer to refuse to.
    ///
    /// **It throws, and the open is not blocked** (fix round 1, I2). A sweep
    /// that could not list a folder or could not read a file must not answer
    /// with the positions it happened to find — a stream a mark does not name
    /// is judged wholly NEW — so this propagates, `RegistryPresence
    /// .admitRemembered` stops where it stood, and `DocumentStore
    /// .admitRemembered` logs it and returns. Nothing is half-written: the
    /// devices already admitted have both their files, this one has neither,
    /// and the next project open runs the whole thing again.
    ///
    /// `try?` here is what it must NOT be. That was the shape until this fix,
    /// and it turned a folder this Mac could not read into an empty mark on a
    /// signed event — a permanent, silent, unrecoverable *everything after the
    /// beginning* for that person's whole history.
    nonisolated static func rememberedAdmissionMark(
        forPerson person: String, in projectURL: URL,
        identities: LocalIdentities, cache: RegistryCache,
        state: OpLogDeviceState
    ) throws -> PermitMark {
        let resolved = try TrustResolution.resolveVerified(
            projectURL: projectURL, identities: identities, cache: cache)
        let ids = opLogDeviceIds(ofPerson: person, in: resolved.registry)
        return try OpLogStore.seenPositions(
            ofDeviceIds: ids, in: projectURL, trust: resolved.table,
            expecting: expectedStreams(
                ofDeviceIds: ids, in: projectURL, state: state))
    }

    /// **What this Mac has applied from these devices, per stream** (P3a
    /// Task 9; the memory rather than the names since the final fix wave's W2)
    /// — what a position sweep must not come back short of.
    ///
    /// A mark that does not NAME a stream judges that stream wholly NEW, and a
    /// file that is simply ABSENT at sweep time — evicted by iCloud, halfway
    /// through a sync — is indistinguishable from a stream that never existed.
    /// Nothing inside the sweep can tell them apart; this device's own memory
    /// can, and this is it. A stream it remembers and cannot find refuses the
    /// verb (`ReadError.streamMissingFromSweep`, Task 7's hook) instead of
    /// producing a short mark that would reach back through every line of it.
    ///
    /// **The other direction is the point of the memory being of FOREIGN
    /// streams only.** A stream this Mac has never seen is honest late sync,
    /// is not expected, and judges new exactly as ruling 1 says it should. And
    /// a subject who IS this device — `retire`, the one verb whose subject is
    /// its own machine — names no foreign stream at all, so this answers empty
    /// and that verb's sweep is byte-for-byte what it was.
    ///
    /// **And a loss the writer has been shown is not expected** (P3b Task 6).
    /// `OpLogDeviceState.expectedStreams` is the one place that is decided —
    /// this door and its sibling below are the only two things in production
    /// that build an `expecting:`, and both ask it, so a person's position
    /// sweep and the unsigned snapshot's take the same way out of a stream
    /// that is never coming back.
    nonisolated static func expectedStreams(
        ofDeviceIds ids: Set<String>, in projectURL: URL, state: OpLogDeviceState
    ) -> [String: OpLogDeviceState.ForeignStreamMemory] {
        state.expectedStreams(
            inRoot: projectURL,
            writtenBy: Set(ids.map { DeviceSlug.make(from: $0).raw }))
    }

    /// **Every foreign stream this Mac remembers in this book** — the same
    /// memory, for the sweep that cannot name a person (P3b Task 2).
    ///
    /// The unsigned snapshot's whole subject is streams nobody's record names,
    /// so it has no set of device ids to narrow by and must expect everything
    /// this Mac has ever applied from anybody. Its sibling above and this one
    /// read the same store through the same function, so a stream expected by
    /// one and not the other would have to be a difference in the SLUG filter
    /// and nothing else.
    nonisolated static func everyExpectedStream(
        in projectURL: URL, state: OpLogDeviceState
    ) -> [String: OpLogDeviceState.ForeignStreamMemory] {
        state.expectedStreams(inRoot: projectURL, writtenBy: nil)
    }

    private func permitMark(
        forPerson person: String, seen: Bool
    ) async -> SweptPositions {
        let projectURL = self.projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let state = Document.loadDeviceState
        let swept: Result<PermitMark, Error> = await Task.detached(
            priority: .userInitiated
        ) { () -> Result<PermitMark, Error> in
            do {
                let resolved = try TrustResolution.resolveVerified(
                    projectURL: projectURL, identities: identities, cache: cache)
                let ids = DocumentStore.opLogDeviceIds(
                    ofPerson: person, in: resolved.registry)
                // What this Mac remembers having applied from them, so a stream
                // that has gone missing refuses the verb rather than silently
                // drawing the line at the beginning of it (P3a Task 9).
                let expected = DocumentStore.expectedStreams(
                    ofDeviceIds: ids, in: projectURL, state: state)
                return .success(seen
                    ? try OpLogStore.seenPositions(
                        ofDeviceIds: ids, in: projectURL, trust: resolved.table,
                        expecting: expected)
                    : try OpLogStore.appliedPositions(
                        ofDeviceIds: ids, in: projectURL, trust: resolved.table,
                        expecting: expected))
            } catch {
                return .failure(error)
            }
        }.value
        switch swept {
        case .success(let mark):
            return .mark(mark)
        case .failure(let error):
            return .unreadable(name: OpLogStore.unreadableName(error))
        }
    }

    /// A position sweep's two answers, named for `AppliedMark`'s reason: a
    /// single optional could not tell *this book holds none of their lines*
    /// from *a file would not read*, and the two want opposite acts.
    private enum SweptPositions {
        case mark(PermitMark)
        case unreadable(name: String)
    }

    // MARK: - What a narrowing would cost this book (P3b Tasks 4 and 5)

    /// **What this book's own state says about narrowing it**, and which of its
    /// streams answer to no key.
    ///
    /// Two surfaces need this and must not compute it twice: the admission
    /// sheet, before Admit is pressable over a narrowing rung, and People &
    /// Devices, for its unsigned rows and the same first-narrowing sentence.
    /// Two bodies would let the sheet and the pane say different things about
    /// one folder on one afternoon.
    ///
    /// Both halves come off the FOLDER rather than this Mac's own enclave:
    /// whether anybody here has already been given less than the whole book
    /// (`TrustTable.hasNarrowingPermits`) and which streams no key can name
    /// (`OpLogStore.unattributablePositions`, the same sweep a narrowing act
    /// takes its photograph with). The Mac that signs nothing is usually
    /// somebody else's.
    ///
    /// **It reports a refusal rather than guessing.** A folder this Mac could
    /// not read answers with the read's own sentence and no streams; the act
    /// itself runs the same sweep and refuses in the error's own words, so a
    /// guess here would be a second, quieter account of a failure the writer is
    /// about to be told about properly.
    ///
    /// **No `expecting:`, deliberately.** This is a READ for a sentence, not the
    /// photograph a verb writes: a stream that has gone missing mid-sync must
    /// refuse the ACT (`sweptUnsignedSnapshot` passes `everyExpectedStream`) and
    /// must not cost the writer the sentence explaining what the act would do.
    struct UnsignedReading: Sendable, Equatable {
        /// Has anybody in this book already been given less than the whole of
        /// it? Narrowing is sticky, so this only ever becomes true.
        var alreadyNarrowed: Bool = false
        /// **The day this book was first narrowed** — the governing
        /// `UnsignedSnapshot`'s own `at`, which is what History dates its
        /// unsigned entries with (P3b Task 10). Nil exactly when
        /// `alreadyNarrowed` is false, and nil on a refusal.
        var narrowedAt: Date?
        /// The streams no key names, by device slug (or stream key where a file
        /// carries no slug), sorted.
        var streams: [String] = []
        /// The read's own sentence, where it refused. Everything else is then
        /// its default, deliberately — a guess is worse than nothing here.
        var refusal: String?

        var holdsAnUnsignedStream: Bool { !streams.isEmpty }
    }

    /// The reading, off the main actor. `nil` refusal is a reading that stands.
    ///
    /// `onlyIfNarrowed` is a COST rule and never a correctness one: History
    /// draws an unsigned entry only in a book that has been narrowed, so
    /// walking every op file of one that has not would be paying for an answer
    /// with nowhere to go. The sheet and People & Devices pass nothing,
    /// because their sentence is precisely the one about a book BEFORE its
    /// first narrowing.
    func unsignedReading(onlyIfNarrowed: Bool = false) async -> UnsignedReading {
        let projectURL = self.projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        return await Task.detached(priority: .userInitiated) {
            DocumentStore.readUnsigned(
                in: projectURL, identities: identities, cache: cache,
                onlyIfNarrowed: onlyIfNarrowed)
        }.value
    }

    /// The same read, synchronous and folder-facing, so a caller that is
    /// already detached does not nest a second `Task`.
    nonisolated static func readUnsigned(
        in projectURL: URL, identities: LocalIdentities, cache: RegistryCache,
        onlyIfNarrowed: Bool = false
    ) -> UnsignedReading {
        do {
            let resolved = try TrustResolution.resolveVerified(
                projectURL: projectURL, identities: identities, cache: cache)
            guard !onlyIfNarrowed || resolved.table.hasNarrowingPermits else {
                return UnsignedReading(alreadyNarrowed: false)
            }
            let unsigned = try OpLogStore.unattributablePositions(
                in: projectURL, trust: resolved.table)
            // **Named the way the DOOR names them** — by device slug, falling
            // back to the stream key where a file carries none. One Mac is one
            // row whatever it wrote in, because a stream outlives its
            // filenames and two rows for one machine would ask the writer
            // about it twice. The spelling is `HeldLines`', so an unsigned row
            // here and a held-line holder in History are the same word.
            let named = unsigned.streams.keys.map { key in
                HeldLines.unsignedHolder(
                    forStreamKey: key,
                    deviceSlug: PermitMark.deviceSlug(ofStreamKey: key))
            }
            return UnsignedReading(
                alreadyNarrowed: resolved.table.hasNarrowingPermits,
                narrowedAt: resolved.table.unsignedSnapshot?.at,
                streams: Set(named.compactMap(HeldLines.streamOfUnsignedHolder))
                    .sorted())
        } catch {
            return UnsignedReading(refusal: error.localizedDescription)
        }
    }

    // MARK: - The two repairs (P3b Task 5)

    /// **Bring a person's record up to this book's history** — spec §3.2's
    /// crash window, pressed by the root.
    ///
    /// It writes a record and NO event, so it narrows nothing: no photograph is
    /// owed and no schema gate, and neither is paid. The rule about what the
    /// record should say is `RegistryAdmission.resignFromTimeline`'s, which
    /// reads the timeline the check reads (tripwire 43).
    @discardableResult
    public func resignRecord(person fingerprint: String) async throws -> PersonRecord {
        let projectURL = self.projectURL
        let author = Document.loadIdentities.author
        let cache = Document.loadRegistryCache
        let record = try await Task.detached(priority: .userInitiated) {
            try RegistryAdmission.resignFromTimeline(
                person: fingerprint, in: projectURL, by: author, cache: cache)
        }.value

        await settle(after: "re-signing the record for",
                     DeviceCode.short(fingerprint))
        return record
    }

    /// **Write this Mac's own registry record again** (audit PR #65's F4).
    ///
    /// The last resort, over a record the reader refuses that this device holds
    /// no earlier bytes for — Restore's case with nothing to restore. Every
    /// refusal is `RegistryPresence.writeOwnRecordAgain`'s: it is never another
    /// device's record, never one that verifies, and for a person record never
    /// where some other Mac's root decides who is in this book.
    @discardableResult
    public func writeOwnRecordAgain(_ ref: RecordRef) async throws -> URL {
        let projectURL = self.projectURL
        let identities = Document.loadIdentities
        let name = DocumentStore.thisMacsName
        let writerName = DocumentStore.thisWritersName
        let url = try await Task.detached(priority: .userInitiated) {
            try RegistryPresence.writeOwnRecordAgain(
                ref, in: projectURL, identities: identities,
                name: name, writerName: writerName, kind: .mac)
        }.value

        await settle(after: "writing this Mac\u{2019}s own record again for",
                     DeviceCode.short(ref.fingerprint))
        return url
    }

    // MARK: - History this book is missing (P3b Task 6)

    /// **What this Mac remembers of this book's history and cannot find** —
    /// History's drawer, and the fact behind every `historyUnreadable`
    /// refusal that names a stream.
    ///
    /// Off the main actor: it resolves a table so each row can be named the
    /// way the book names that device, and it lists the two stream
    /// directories. It reads no file of the op log and it verifies nothing.
    ///
    /// A folder this Mac cannot read answers with whatever the memory alone
    /// says — the truncations — rather than refusing: this is a read for a
    /// sentence, and the acts that must not proceed over a short reading
    /// refuse on their own account.
    func lostHistory() async -> [OpLogStore.LostHistory] {
        let projectURL = self.projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let state = Document.loadDeviceState
        return await Task.detached(priority: .userInitiated) {
            // **The ordinary book costs nothing at all.** A project this Mac
            // has never read another device's stream in can have lost none of
            // one, so it answers before resolving a table (a folder read and a
            // signature check per record) or listing a directory. The answer is
            // the same either way — `lostHistory` over an empty memory with no
            // truncations is empty — which is what makes the short circuit a
            // cost decision rather than a second rule.
            guard !state.truncations(inRoot: projectURL).isEmpty
                    || !state.foreignStreams(
                        inRoot: projectURL, writtenBy: nil).isEmpty
            else { return [] }
            let table = try? TrustResolution.resolveVerified(
                projectURL: projectURL, identities: identities, cache: cache).table
            return OpLogStore.lostHistory(
                in: projectURL, state: state, trust: table)
        }.value
    }

    /// **How many acknowledged losses each act would be deciding over** (fix
    /// round 1, Minor 1) — the book's, and one count per person.
    ///
    /// The two are needed because the verbs sweep differently. A revocation
    /// and a permit change that narrows NOBODY sweep one person's streams
    /// (`expectedStreams(ofDeviceIds:)`), so a loss under somebody else's
    /// machine cannot affect them and must not be mentioned: a confirmation
    /// that says *this is decided without history you said was gone* about an
    /// act that reads none of it is an over-statement, and an over-statement
    /// about a destructive act is the kind a writer learns to skip. A permit
    /// change that NARROWS also takes the book's photograph
    /// (`everyExpectedStream`), so its count is the book's.
    ///
    /// Read off the same rows the drawer draws, so the pane's sentence and its
    /// rows cannot disagree about what has been put down.
    struct AcknowledgedLosses: Sendable, Equatable {
        /// Every loss this writer has put down in this book.
        var book: Int = 0
        /// Those under one person's own machines, by person fingerprint.
        var byPerson: [String: Int] = [:]

        func count(ofPerson fingerprint: String) -> Int {
            byPerson[fingerprint] ?? 0
        }
    }

    func acknowledgedLostHistory() async -> AcknowledgedLosses {
        let projectURL = self.projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let state = Document.loadDeviceState
        return await Task.detached(priority: .userInitiated) {
            // The drawer's own short circuit, for its own reason: the ordinary
            // book has put nothing down and pays nothing to say so.
            guard !state.acknowledgedLosses(inRoot: projectURL).isEmpty
            else { return AcknowledgedLosses() }
            guard let resolved = try? TrustResolution.resolveVerified(
                projectURL: projectURL, identities: identities, cache: cache)
            else { return AcknowledgedLosses() }
            let put = OpLogStore.lostHistory(
                in: projectURL, state: state, trust: resolved.table
            ).filter(\.acknowledged)
            guard !put.isEmpty else { return AcknowledgedLosses() }
            var byPerson: [String: Int] = [:]
            for person in resolved.registry.people {
                let slugs = Set(DocumentStore.opLogDeviceIds(
                    ofPerson: person.person, in: resolved.registry
                ).map { DeviceSlug.make(from: $0).raw })
                let mine = put.filter { slugs.contains($0.deviceSlug) }.count
                if mine > 0 { byPerson[person.person] = mine }
            }
            return AcknowledgedLosses(book: put.count, byPerson: byPerson)
        }.value
    }

    /// **The writer has been shown a loss and has put it down.**
    ///
    /// It writes nothing to the book: no event, no record, nothing another
    /// device will ever read — only this Mac's own memory of having been told
    /// (`OpLogDeviceState.acknowledgeLoss`), which is what stops the marking
    /// verbs waiting for a stream that is never coming back. Synchronous
    /// because it is a small local write behind a button, like
    /// `acknowledgeSetAsideRecords`.
    func acknowledgeLostHistory(streamKey: String) {
        Document.loadDeviceState.acknowledgeLoss(
            streamKey, inRoot: projectURL)
    }

    // MARK: - A piece nobody has claimed (P3b Task 7, spec §4.5)

    /// **Yes, that piece is theirs** — the one write behind the load's second
    /// question.
    ///
    /// It adds the piece to their scope and changes nothing else. The permit
    /// it installs is built in the permit layer from the one in force RIGHT
    /// NOW — `PermitTimeline.current`, never `PersonRecord.role` (tripwire 43)
    /// and never a rung compared here (tripwire 47) — so a writer who was
    /// already an author of three pieces becomes an author of four and a
    /// writer whose permit changed under this window since it drew does not
    /// have that change quietly reverted.
    ///
    /// **Every record of theirs, like every other permit change** (fix round
    /// 1's I3): a person is a label and a label is as many machines as they
    /// own. Adding the piece to their Mac alone would leave their phone's
    /// paragraphs of the same chapter held, with the writer told the question
    /// was settled.
    ///
    /// **It refuses rather than promoting.** §4.5 can only hold a line for
    /// somebody who may already write *some* of this book, so the permit in
    /// force is an author-of-some-pieces one; if it is not — a permit changed
    /// under this window, a word this build cannot read — this answers nothing
    /// rather than inventing a rung the writer never chose.
    /// `Permit.mayStartAPieceOfTheirOwn` is that question, asked of the permit
    /// layer.
    @discardableResult
    public func pieceIsTheirs(
        person: String, docId: String
    ) async throws -> [PersonRecord] {
        let projectURL = self.projectURL
        let cache = Document.loadRegistryCache
        let registry = try await Task.detached(priority: .userInitiated) {
            try TrustResolution.verifiedRegistry(
                projectURL: projectURL, presenter: nil, cache: cache)
        }.value
        guard registry.person(person) != nil else {
            throw RegistryAdmissionError.notAdmitted(fingerprint: person)
        }
        let standing = PermitTimeline(about: person, in: registry).current
        guard standing.mayStartAPieceOfTheirOwn else {
            throw PieceIsTheirsRefused(person: person)
        }
        var pieces = PermitControl.pieces(displaying: standing)
        pieces.insert(docId)
        let widened = PermitControl.permit(for: .somePieces, pieces: pieces)
        // **An ASSERTION about the two lines above it, not a reachable
        // refusal** (fix round 3, minor 4). `widened` is `standing`'s piece
        // list plus one id, so it covers `standing` by construction and this
        // can only fire if somebody changes how the permit above is built.
        // It is kept because of what it is guarding: `settling` makes every
        // earlier permit of hers be READ as having held this piece, so her
        // scope-only refusals in it are re-judged — and re-judging is safe in
        // one direction only. The day this verb learns to narrow, that stops
        // being safe, and this line is where that is noticed. `Permit.covers`
        // is the permit layer's own comparison, never a rung tested here
        // (tripwire 47).
        guard widened.covers(standing) else {
            throw PieceIsTheirsRefused(person: person)
        }
        let moved = try await changePermit(
            everyRecordOf: person, to: widened, settling: [docId])
        // **The question is answered, and is never put again** (fix round 1).
        // Device-local beside the declines: what makes it true for the book is
        // the signed event above, and this only stops THIS Mac asking about
        // something it has already written down.
        Document.loadDeviceState.settlePiece(
            person: person, docId: docId, inRoot: projectURL)
        return moved
    }

    /// **Not now.** It writes nothing to the book — see
    /// `OpLogDeviceState.declinePiece`, which is the whole of it — and only
    /// stops THIS Mac asking again at the next load. The question goes on
    /// waiting in People & Devices.
    ///
    /// Synchronous, like `acknowledgeLostHistory` beside it: a small local
    /// write behind a button.
    func notNowAboutPiece(person: String, docId: String) {
        Document.loadDeviceState.declinePiece(
            person: person, docId: docId, inRoot: projectURL)
    }

    /// Every question about a piece this Mac has already closed in this book —
    /// put off OR answered (fix round 1). One reader, because *should this be
    /// ASKED again* is one question and both answers are no.
    func closedPieceQuestions() -> Set<OpLogDeviceState.DeclinedPiece> {
        Document.loadDeviceState.closedPieceQuestions(inRoot: projectURL)
    }

    /// **The ones put OFF, and only those** (fix round 3, minor 5).
    ///
    /// *Should this be asked again* and *what happened to it* are different
    /// questions, and People & Devices needs the second: a question the writer
    /// ANSWERED must not be drawn at all, while one they put off is drawn with
    /// a note saying so. Reading the closed set for both made a settled
    /// question appear under *You put this off*, which is the opposite of what
    /// the writer did.
    func declinedPieceQuestions() -> Set<OpLogDeviceState.DeclinedPiece> {
        Set(Document.loadDeviceState.declinedPieces(inRoot: projectURL).keys)
    }

    /// The ones ANSWERED. The pane filters these out entirely.
    func settledPieceQuestions() -> Set<OpLogDeviceState.DeclinedPiece> {
        Set(Document.loadDeviceState.settledPieces(inRoot: projectURL).keys)
    }

    // MARK: - Who is waiting, across this window

    /// **Held lines by device, over everything this window can see** — the open
    /// documents' own loads, the closed documents' last sweep (carry C4,
    /// `DocumentStore+ClosedHeldLines.swift`) and the project's capture stream.
    ///
    /// One computation, because two surfaces ask it about the same decision:
    /// the admission sheet's queue, and People & Devices' pending rows. A
    /// pane counting only the inbox would tell the writer nobody is waiting
    /// while a chapter holds forty lines, and the Admit… button they press in
    /// the other column would be about a device that pane never listed.
    ///
    /// The counts are already in hand — stamped on each open `Document` by its
    /// load and re-stamped by every external-change merge, swept off the main
    /// actor for every closed one, and counted by the inbox on its own refresh
    /// — so this reads them and touches no disk. **Per docId, the open
    /// document's provenance if it is open, else the closed map's** — never
    /// both, so a document is counted once however it got there. It
    /// asks the inbox for what that refresh last counted and does not refresh
    /// it: a caller that wants the stream re-read says so itself, which is what
    /// Project Settings does before it asks.
    public func heldLinesByDevice() -> [String: Int] { heldLines().counts }

    /// **The same union, carrying the STREAMS each holder was held in** (P3b
    /// Task 4).
    ///
    /// The counts answer *how much is waiting*; the streams answer the question
    /// the admission sheet has to ask before it offers anybody — *is this key a
    /// person's at all*. A non-author actor key whose device record has not
    /// arrived stands for itself in `pendingByDevice`, and the slug of the file
    /// it wrote in is the only thing on disk that names it (`AdmissionDecision
    /// .standing`, which CHECKS that claim against the key rather than
    /// believing a word in a filename).
    ///
    /// One walk for both, so the two halves cannot disagree about who is
    /// waiting — and a holder with no streams is a real, ordinary answer
    /// (a legacy file, a hand-built provenance, an inbox read from before this
    /// milestone), which asks nothing of the holder and leaves it offered
    /// exactly as P2b offered it.
    func heldLines() -> HeldLineUnion {
        var counts: [String: Int] = [:]
        var streams: [String: Set<String>] = [:]
        var startedAPiece: [String: [String: Int]] = [:]
        var waiting: [String: [String: HeldLines.Waiting]] = [:]
        func fold(_ provenance: OpLogProvenance, docId: String) {
            for (device, count) in provenance.pendingByDevice {
                counts[device, default: 0] += count
            }
            for (device, what) in provenance.pendingWaitingByDevice {
                waiting[device, default: [:]][docId] = what
            }
            for (device, slugs) in provenance.pendingStreamsByDevice {
                streams[device, default: []].formUnion(slugs)
            }
        }
        let open = allOpenDocuments()
        let openIds = Set(open.map(\.docId))
        // **The closed half** (carry C4): the last sweep's answer for every
        // document nobody has open. `startedAPiece` stays the open documents'
        // — the walk records it on the load's carrier, which a sweep has not
        // got — so §4.5's question is still put when the piece is opened.
        for (docId, provenance) in closedProvenance where !openIds.contains(docId) {
            fold(provenance, docId: docId)
        }
        for document in open {
            guard let provenance = document.provenance else { continue }
            fold(provenance, docId: document.docId)
            // **Where the docId joins the walk's answer** (P3b Task 7). The
            // partition decided WHO opened a piece nobody has claimed; only
            // this fold knows WHICH piece, because a document knows its own id
            // and a file's provenance does not.
            //
            // **With this document's OWN count** (fix round 1, I4). The
            // question names a piece and promises what pressing it brings in,
            // so the number beside it has to be the number in THAT piece — the
            // holder's total across every open document is a different figure
            // and it is the one the sheet was printing.
            for holder in document.startedAPiece {
                startedAPiece[holder, default: [:]][document.docId] =
                    provenance.pendingByDevice[holder] ?? 0
            }
        }
        for (device, count) in inboxStore.pendingByDevice {
            counts[device, default: 0] += count
        }
        for (device, slugs) in inboxStore.pendingStreamsByDevice {
            streams[device, default: []].formUnion(slugs)
        }
        return HeldLineUnion(
            counts: counts, streams: streams, startedAPiece: startedAPiece,
            waiting: waiting, captures: inboxStore.pendingByDevice)
    }

    // MARK: - The words a held line is waiting with (P3b Task 8, spec §7.4)

    /// **How many paragraphs each unsigned holder is waiting with**, for the
    /// one document the pane is showing.
    ///
    /// A held line writes no `.lines` record — nothing is wrong with it — so
    /// the count cannot be read off the quarantine directory the way the record
    /// door's is. It is the walk's own answer, re-run over that document's
    /// files (`OpLogStore.heldLines`), which is why it is resolved on a reload
    /// and held rather than asked from `body` (tripwire 4).
    ///
    /// **Unsigned holders only, and nothing else is asked.** A stranger's held
    /// lines have an admission, which applies them; a permit-pending line has a
    /// later build or the writer's own answer about a piece. Only a stream
    /// nothing signs has no way in but this one, so only it pays for the walk —
    /// and a book that has narrowed nobody has no unsigned holder at all and
    /// pays nothing.
    ///
    /// A read that throws answers NOTHING for that holder rather than a short
    /// count: no door is better than a door that promises half a span.
    func unsignedHeldWordCounts(
        forDocId docId: String, holders: [String]
    ) async -> SetAsideDoor.HeldWordCounts {
        let unsigned = holders.filter { HeldLines.isUnsignedHolder($0) }
        guard !unsigned.isEmpty else { return .none }
        // **Remembered by the LINES, not by the holder** (P3c Task 7, M2). A
        // signing Mac whose first seal has not synced is held as an unsigned
        // stream today and under its key tomorrow; the paragraphs are the same
        // paragraphs, and a memory keyed by the holder offered them again.
        // **What is left, not what is there** (fix round 2, C1): a held span
        // is live, so the door offers the paragraphs this Mac has not already
        // made a capture of — never all of them again, and never none of them
        // because one press happened once. Both are `SetAsideDoor`'s rule.
        var wordsByHolder: [String: [OpLogQuarantine.SetAsideWords]] = [:]
        for holder in unsigned {
            guard let words = try? await unsignedHeldWords(
                forDocId: docId, heldBy: holder), !words.isEmpty
            else { continue }
            wordsByHolder[holder] = words
        }
        return SetAsideDoor.heldWordCounts(
            docId: docId, wordsByHolder: wordsByHolder,
            sent: uiState.sentRecoveredOpIds)
    }

    /// The words themselves — the walk's held lines for this holder, decoded
    /// by the same `OpLogQuarantine.recoverableWords` the record door uses, so
    /// the two doors cannot disagree about what counts as the writer's prose.
    func unsignedHeldWords(
        forDocId docId: String, heldBy holder: String
    ) async throws -> [OpLogQuarantine.SetAsideWords] {
        // `Document.makeLoadOpStore` is the ONE construction on a load path, so
        // the walk this re-runs is built from the same identities, the same
        // remembered heads and the same registry memory the load was — a store
        // put together by hand here would judge the same bytes differently.
        let store = Document.makeLoadOpStore(
            projectURL: projectURL, presenter: presenter)
        let lines = try await store.heldLines(forDocId: docId, heldBy: holder)
        return OpLogQuarantine.recoverableWords(inLines: lines)
    }

    /// **Send an unsigned holder's held words to the Inbox** (spec §7.4).
    ///
    /// The same act the record door performs, over a different source: nothing
    /// is applied, nothing on disk moves, the lines stay held exactly as they
    /// were, and the words arrive as ordinary captures signed by this Mac's own
    /// author actor. The press is remembered per paragraph, by the lines
    /// themselves (`SetAsideDoor.heldLineId`), so the door never offers the
    /// same paragraph twice — whatever holder it is held under by then.
    ///
    /// Answers how many captures landed. Zero — a re-read that found nothing —
    /// writes no memory either, because there is nothing to have sent and the
    /// door should still be there if the span arrives later.
    @discardableResult
    func sendHeldWordsToInbox(
        forDocId docId: String, heldBy holder: String
    ) async throws -> Int {
        // One memory per DOCUMENT, of the lines themselves (P3c Task 7, M2):
        // `holder` chooses which lines to read, and never how they are
        // remembered — see `SetAsideDoor.heldDoorKey`.
        let key = SetAsideDoor.heldDoorKey(docId: docId)
        let words = try await unsignedHeldWords(forDocId: docId, heldBy: holder)
        let captures = SetAsideDoor.heldCaptures(
            docId: docId, words: words, sent: uiState.sentRecoveredOpIds)
        guard !captures.isEmpty else { return 0 }
        // Recorded as each one LANDS (fix round 2, M2): a manifest that stops
        // being writable halfway leaves a re-press with only the rest to do,
        // rather than with every paragraph the writer already has.
        return try await inboxStore.captureRecoveredWords(captures) { landed in
            recordRecoveredCapturesSent(door: key, ids: [landed.id])
        }
    }
}

/// **What this window can see being held, and where** (P3b Task 4).
///
/// Two maps rather than one keyed value, because they are read by different
/// questions and one of them is P2b's: `counts` is every *N notes waiting*
/// sentence in the app, and `streams` exists so that the one surface which
/// offers to ADMIT a holder can first ask whether that holder is a person's
/// key at all.
struct HeldLineUnion: Equatable {
    /// Held OP lines by holder — a device fingerprint, a seal key that no
    /// record names, or one of `HeldLines`' non-key holders.
    var counts: [String: Int]
    /// The device slugs of the streams each holder was held in. Legitimately
    /// empty for a holder whose files carry no slug.
    var streams: [String: Set<String>]
    /// **The pieces each holder OPENED that nobody has claimed** (P3b Task 7,
    /// spec §4.5) — the walk's own answer (`Document.startedAPiece`) with this
    /// fold's docIds joined to it.
    ///
    /// A third map for `streams`' reason: it is read by a different question.
    /// `counts` is every *N notes waiting* sentence, `streams` is *is this
    /// holder a person's key at all*, and this is *did they start something
    /// that is in nobody's scope* — the one held line the writer can answer
    /// today. Empty for every book that has narrowed nobody.
    /// Holder → the pieces they opened → **how much of theirs is held in that
    /// piece** (fix round 1, I4). Per document, because the question names one.
    var startedAPiece: [String: [String: Int]]
    /// **What each holder's held lines ARE, piece by piece** (P3b smoke find
    /// F2) — holder → docId → paragraphs and notes, the open documents' own
    /// `OpLogProvenance.pendingWaitingByDevice` joined to the docId only this
    /// fold knows. The admission sheet says *1 paragraph in “Chapter 1”* from
    /// it rather than *1 note waiting*.
    var waiting: [String: [String: HeldLines.Waiting]]
    /// Held CAPTURES by holder — the capture stream's share of `counts`, which
    /// holds captures and never paragraphs or notes, so a surface can say so.
    var captures: [String: Int]

    init(
        counts: [String: Int] = [:], streams: [String: Set<String>] = [:],
        startedAPiece: [String: [String: Int]] = [:],
        waiting: [String: [String: HeldLines.Waiting]] = [:],
        captures: [String: Int] = [:]
    ) {
        self.counts = counts
        self.streams = streams
        self.startedAPiece = startedAPiece
        self.waiting = waiting
        self.captures = captures
    }
}



/// **A permit change that moved some of a writer's machines and not the rest**
/// (fix round 1, I3).
///
/// Every refusal `changePermit(everyRecordOf:to:)` can see is raised before it
/// writes anything, so this is the other kind: a write that failed — a folder
/// that stopped being writable, a sweep that came back short — after earlier
/// records had already moved. It names them rather than reporting a plain
/// failure, because *nothing happened* and *half of it happened* want
/// different next moves from the writer, and only one of them is true here.
///
/// `LocalizedError`, so `AdmissionDecision.refusal`'s fallback arm reads as a
/// sentence rather than as a type name.
public struct PermitChangePartlyApplied: Error, LocalizedError {
    /// The people whose permit DID change, in the order they changed.
    public let moved: [String]
    /// The one it stopped at.
    public let failed: String
    public let underlying: Error

    public init(moved: [String], failed: String, underlying: Error) {
        self.moved = moved
        self.failed = failed
        self.underlying = underlying
    }

    public var errorDescription: String? {
        let names = moved.map { DeviceCode.short($0) }.joined(separator: ", ")
        let what = moved.isEmpty
            ? "Nothing was changed."
            : "What \(names) may write HAS changed; "
                + "\(DeviceCode.short(failed)) has not."
        return "\(what) \(underlying.localizedDescription) "
            + "Pressing again finishes the rest and changes nothing twice."
    }
}

/// **A piece question whose subject may not write pieces at all** (P3b Task 7).
///
/// §4.5 holds a line only for somebody who may already write *some* of this
/// book, so the permit in force when the question was raised was an
/// author-of-some-pieces one. It can have moved since: a second window, another
/// Mac, or this writer themselves in People & Devices while the question stood.
///
/// Answering it anyway would install a rung nobody chose — *Theirs* is the
/// writer saying whose a PIECE is, never a promotion — so the act refuses and
/// says which of the two facts moved. `LocalizedError`, so
/// `AdmissionDecision.refusal`'s fallback arm reads as a sentence.
public struct PieceIsTheirsRefused: Error, LocalizedError {
    public let person: String

    public init(person: String) { self.person = person }

    public var errorDescription: String? {
        "Nothing was changed. What the device with code "
            + "\(DeviceCode.short(person)) may write has moved since this "
            + "question was asked, so saying the piece is theirs would give "
            + "them access you haven’t chosen. Set what they may write in "
            + "People & Devices instead."
    }
}

/// **Unsigned-snapshot sweeps performed, per project folder** — see
/// `DocumentStore.unsignedSweepsForTesting`. Sendable by its lock, so the
/// detached sweep and a test on the main actor can both reach it.
final class UnsignedSweepCounter: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: [String: Int]())

    func bump(_ projectURL: URL) {
        let key = Self.key(projectURL)
        counts.withLock { $0[key, default: 0] += 1 }
    }

    func count(in projectURL: URL) -> Int {
        let key = Self.key(projectURL)
        return counts.withLock { $0[key] ?? 0 }
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
