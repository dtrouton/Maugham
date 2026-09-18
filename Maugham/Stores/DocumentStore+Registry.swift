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
        let record = try await Task.detached(priority: .userInitiated) {
            try RegistryAdmission.revoke(
                person: fingerprint, in: projectURL, by: author,
                highestOpIdSeen: mark, cache: cache)
        }.value

        await settle(after: "revoking", DeviceCode.short(fingerprint))
        return record
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
        let record = try await Task.detached(priority: .userInitiated) {
            try RegistryAdmission.retire(
                device: fingerprint, in: projectURL, by: author, cache: cache)
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
        let admitted: [PersonRecord]
        do {
            admitted = try await Task.detached(priority: .userInitiated) {
                try RegistryPresence.admitRemembered(
                    in: projectURL, identities: identities, cache: cache, memory: memory)
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
                let ids: Set<String>
                if let record = resolved.registry.devices.first(
                    where: { $0.device == person }) {
                    ids = Set(record.actors.map { actor, key in
                        DeviceIdentity.deviceId(actor: actor, fingerprint: key)
                    })
                } else {
                    // No device record for them: under labels-only a person IS
                    // a device's author key, so the one id they can have
                    // written under is that key's own.
                    ids = [DeviceIdentity.deviceId(
                        actor: DeviceActor.author.rawValue, fingerprint: person)]
                }
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
