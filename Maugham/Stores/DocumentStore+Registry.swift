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
        // Refuse rather than record a mark that came back short, for the
        // revocation's reason: a short mark moves a permission boundary
        // silently, and the direction it moves it in is *more set aside than
        // the writer asked for*.
        let mark = try await sweptPermitMark(forPerson: fingerprint)
        return try await changePermit(person: fingerprint, to: permit, mark: mark)
    }

    /// `changePermit`'s sweep, alone — so the plural verb below can take every
    /// record's mark BEFORE it writes any of them (fix round 1, minor 2).
    private func sweptPermitMark(forPerson fingerprint: String) async throws -> PermitMark {
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
        person fingerprint: String, to permit: Permit, mark: PermitMark
    ) async throws -> PersonRecord {
        let projectURL = self.projectURL
        let author = Document.loadIdentities.author
        let cache = Document.loadRegistryCache
        let record = try await Task.detached(priority: .userInitiated) {
            try RegistryAdmission.changePermit(
                person: fingerprint,
                role: permit.wireRole, scope: permit.wireScope,
                pieces: permit.wirePieces, mark: mark,
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
            marks[record.person] = try await sweptPermitMark(forPerson: record.person)
        }

        var moved: [PersonRecord] = []
        for record in records {
            do {
                moved.append(try await changePermit(
                    person: record.person, to: permit,
                    mark: marks[record.person] ?? .nothingApplied))
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
        // retired*, so P3b's *N paragraphs were written on it while retired*
        // would offer the writer their whole history as something to bring
        // back in. A retirement is not typing — refusing one breaks no
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
            do { try await document.handleExternalLogChange() }
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
            expectedStreams: expectedStreams(
                ofDeviceIds: ids, in: projectURL, state: state))
    }

    /// **The streams this Mac has applied from these devices, by name** (P3a
    /// Task 9) — what a position sweep must not come back without.
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
    nonisolated static func expectedStreams(
        ofDeviceIds ids: Set<String>, in projectURL: URL, state: OpLogDeviceState
    ) -> Set<String> {
        state.foreignStreamKeys(
            inRoot: projectURL,
            writtenBy: Set(ids.map { DeviceSlug.make(from: $0).raw }))
    }

    private func permitMark(forPerson person: String, seen: Bool) async -> SweptPositions {
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
                        expectedStreams: expected)
                    : try OpLogStore.appliedPositions(
                        ofDeviceIds: ids, in: projectURL, trust: resolved.table,
                        expectedStreams: expected))
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

    // MARK: - Who is waiting, across this window

    /// **Held lines by device, over everything this window can see** — the open
    /// documents' own loads and the project's capture stream.
    ///
    /// One computation, because two surfaces ask it about the same decision:
    /// the admission sheet's queue, and People & Devices' pending rows. A
    /// pane counting only the inbox would tell the writer nobody is waiting
    /// while a chapter holds forty lines, and the Admit… button they press in
    /// the other column would be about a device that pane never listed.
    ///
    /// The counts are already in hand — stamped on each open `Document` by its
    /// load and re-stamped by every external-change merge, and counted by the
    /// inbox on its own refresh — so this reads them and touches no disk. It
    /// asks the inbox for what that refresh last counted and does not refresh
    /// it: a caller that wants the stream re-read says so itself, which is what
    /// Project Settings does before it asks.
    public func heldLinesByDevice() -> [String: Int] {
        var held: [String: Int] = [:]
        for document in allOpenDocuments() {
            guard let provenance = document.provenance else { continue }
            for (device, count) in provenance.pendingByDevice {
                held[device, default: 0] += count
            }
        }
        for (device, count) in inboxStore.pendingByDevice {
            held[device, default: 0] += count
        }
        return held
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
