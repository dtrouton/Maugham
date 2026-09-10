import Foundation

/// Where a reader gets its `TrustTable` from — the one place the folder, this
/// device's memory of it and this device's keys are put together.
///
/// `TrustTable.resolve` is pure and takes every input as an argument, which is
/// what makes each of its arms pinnable as a value. This is the impure half:
/// it reads the registry folder, reconciles it against what this device last
/// verified, and records the root it joined. Every store that needs a verdict
/// comes through here, so no two of them can build a different table over the
/// same project.
public enum TrustResolution {

    /// This device's trust in one project, off disk.
    ///
    /// **Three steps, and the order matters.** The folder is read and verified
    /// (`RegistryReader`), reconciled against this device's memory so a record
    /// somebody deleted is restored rather than silently un-admitting a device
    /// (`RegistryCache.reconcile`), and only then resolved into verdicts.
    ///
    /// **A registry that has VANISHED is restored, not believed.** The
    /// short-circuit below asks whether the folder is there, but an absent
    /// folder is two different events: a project that never joined a chain —
    /// the ordinary case, and the one that must cost nothing — and a registry
    /// something deleted, which is the cheapest possible attack on a chain and
    /// must not read as *no chain here*. This device's memory is what tells
    /// them apart, so `.noChain` is answered only when the folder and the
    /// memory are BOTH empty; otherwise every remembered record is put back and
    /// the resolution proceeds from what was restored.
    ///
    /// **A device never switches roots on its own** (B1), which decides the
    /// whole of the join. A device holding its own self-signed root record is
    /// already on a root — its own — so it JOINS nobody, and every other root
    /// that names it is recorded as a *claimant*: somebody claiming a book this
    /// device already has a chain of its own for. Only a device with no root
    /// record of its own and no join yet takes one, and only the first; the
    /// rest are claimants there too.
    ///
    /// The trap this shape exists to close is not malicious. Two Macs both open
    /// an empty book before sync converges, each writes itself a root, then one
    /// admits the other. Joining on *a root names me* would make the second
    /// Mac's own root lose to the first on the next resolve — arm 1 outranks
    /// arm 2 — and every peer it had admitted under its own root would turn
    /// `.otherRoot`, quarantined, with a `.lines` record apiece.
    ///
    /// **It throws.** A registry record that is present and cannot be read
    /// refuses the whole resolution (RULING-54), because a device silently
    /// un-admitted by a permissions error is exactly the shape that rule
    /// exists to forbid. A record that is present and says something WRONG is
    /// not this: the reader lists it as malformed and the load goes on.
    ///
    /// **Run it off the main actor.** It is a directory read plus a P256
    /// verification per record, and every `@MainActor` caller here reaches it
    /// through a detached task for that reason.
    nonisolated public static func resolve(
        projectURL: URL,
        identities: LocalIdentities,
        presenter: NSFilePresenter? = nil,
        cache: RegistryCache? = nil
    ) throws -> TrustTable {
        // The cheap answer first, because it is the ordinary one: no registry
        // directory at all. Three `fileExists` decide it, and only then is a
        // cache consulted — and only to tell a project that never joined a
        // chain apart from one whose registry something DELETED.
        let folderPresent = hasRegistry(in: projectURL)
        let cache = cache ?? .shared
        let remembered = cache.cached(for: projectURL)
        guard folderPresent || remembered != nil else { return keyless(mine: identities) }

        let folder = folderPresent
            ? try RegistryReader.load(projectURL: projectURL, presenter: presenter)
            : Registry()
        // With no folder this restores every remembered record and reports it,
        // which is the vanished-registry case above; with a folder it is the
        // ordinary per-record restore.
        let reconciled = try cache.reconcile(
            folder: folder, cached: remembered,
            in: projectURL, presenter: presenter).registry

        let table = TrustTable.resolve(
            registry: reconciled, mine: identities,
            joinedRoot: cache.joinedRoot(for: projectURL))

        // A device on a root of its own joins nothing, ever. Otherwise the
        // first root that names it becomes the join and the rest are claimants.
        // `joined` is carried through the loop rather than re-read because the
        // first iteration is what the later ones are measured against.
        let onItsOwnRoot = table.ownRootRecord != nil
        var joined = cache.joinedRoot(for: projectURL)
        for admitting in table.admittingRoots {
            if !onItsOwnRoot, joined == nil {
                joined = cache.join(root: admitting, for: projectURL)
                continue
            }
            guard admitting != joined else { continue }
            cache.recordClaimant(root: admitting, for: projectURL)
        }
        return table
    }

    /// The table a reader uses when there is nothing to judge by: this device's
    /// own keys are its own and every other key answers `.noChain`.
    ///
    /// That is P1's behaviour exactly — a seal of ours is `verified`, anybody
    /// else's is `unsignedHistory` and applied — which is why every suite
    /// written before P2a passes unchanged: a project with no `.maugham/people`
    /// and nothing remembered resolves to this.
    nonisolated public static func keyless(mine: LocalIdentities) -> TrustTable {
        TrustTable.resolve(registry: Registry(), mine: mine, joinedRoot: nil)
    }

    /// Does this project have a registry at all? Any of the three directories
    /// being present is enough — a folder holding only devices, or only a
    /// claim, is still a folder this device must read before it judges anyone.
    nonisolated public static func hasRegistry(in projectURL: URL) -> Bool {
        RegistryDirectory.allCases.contains {
            FileManager.default.fileExists(
                atPath: RegistryWriter.directoryURL($0, in: projectURL).path)
        }
    }

    // MARK: - Knowing when to resolve again

    /// A cheap description of the registry folder as it stands right now —
    /// every record's name and modification time, in one string.
    ///
    /// A caller that keeps a resolved table compares this before reusing it,
    /// which is what makes **admitting a device apply its held ops on the next
    /// read of the same store** (spec §4.1) rather than on the next store. It
    /// is three directory listings and a stat apiece: nothing is opened, no
    /// signature is checked, and an absent registry answers the empty string
    /// without touching the disk beyond the listing itself.
    ///
    /// It is a change DETECTOR, not a digest — two different folders could in
    /// principle agree, which would leave a stale table until the next
    /// difference. That is why `invalidate` exists beside it: a caller that
    /// KNOWS it changed the registry says so rather than hoping a timestamp
    /// moved.
    nonisolated public static func signature(of projectURL: URL) -> String {
        var parts: [String] = []
        for directory in RegistryDirectory.allCases {
            let url = RegistryWriter.directoryURL(directory, in: projectURL)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [])
            else { continue }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let modified = (try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate)
                parts.append("\(directory.rawValue)/\(entry.lastPathComponent)@"
                             + "\(modified?.timeIntervalSince1970 ?? 0)")
            }
        }
        return parts.joined(separator: ";")
    }
}
