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

    /// **Revoke a person.** Answers the record that now stands for them.
    ///
    /// `highestOpIdSeen` is computed here, from the documents this window has
    /// open, because it is a fact about THIS Mac's reading rather than about
    /// the folder: the highest opId it had actually applied from that device.
    /// A line below that mark arriving later is *may be late sync or may be
    /// backdated*; one above it was written after the door closed. Both are
    /// refused, and the writer is owed which is which.
    @discardableResult
    public func revoke(person fingerprint: String) async throws -> PersonRecord {
        let projectURL = self.projectURL
        let author = Document.loadIdentities.author
        let cache = Document.loadRegistryCache
        let mark = await highestOpIdApplied(fromPerson: fingerprint)
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

    /// The highest opId this window has APPLIED from `person`, over every
    /// document it has open — nil when it has applied none.
    ///
    /// **Open documents only**, for `AdmissionModifier.recompute`'s reason: a
    /// closed document's history would cost a full read of its log per chapter,
    /// at the moment the writer is waiting on a button. The consequence is
    /// stated rather than hidden: the mark is this Mac's honest answer to *how
    /// far had I got*, and a chapter nobody has opened since that device last
    /// wrote in it can put a line above the mark that this Mac had, in some
    /// sense, already seen. It is filed as *after revocation* — the strict side
    /// — which is the side to be wrong on.
    ///
    /// The match is `DeviceIdentity.deviceId(actor:fingerprint:)` over the
    /// device record's own actor keys: an op carries the id its writer wrote
    /// under, and the registry carries the keys, and joining them anywhere but
    /// there would be a second opinion about what a device id is.
    private func highestOpIdApplied(fromPerson person: String) async -> String? {
        let projectURL = self.projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let ids = await Task.detached(priority: .userInitiated) { () -> Set<String> in
            guard let resolved = try? TrustResolution.resolveVerified(
                projectURL: projectURL, identities: identities, cache: cache)
            else { return [] }
            guard let record = resolved.registry.devices.first(
                where: { $0.device == person }) else {
                // No device record for them: under labels-only a person IS a
                // device's author key, so the one id they can have written
                // under is that key's own.
                return [DeviceIdentity.deviceId(
                    actor: DeviceActor.author.rawValue, fingerprint: person)]
            }
            return Set(record.actors.map { actor, key in
                DeviceIdentity.deviceId(actor: actor, fingerprint: key)
            })
        }.value
        guard !ids.isEmpty else { return nil }

        var highest: String?
        for document in allOpenDocuments() {
            for op in document.opLogSnapshot where ids.contains(op.device) {
                if highest == nil || op.opId > highest! { highest = op.opId }
            }
        }
        return highest
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
