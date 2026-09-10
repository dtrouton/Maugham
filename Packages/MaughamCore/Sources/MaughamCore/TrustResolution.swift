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
    /// (`RegistryCache.reconcile`), and only then resolved into verdicts. The
    /// root the table settles on is remembered the FIRST time (`join`, decision
    /// B1): a device never switches roots on its own, so a root once joined
    /// outranks whatever the folder says on a later day.
    ///
    /// **A project with no registry folder at all answers `.noChain` and reads
    /// nothing.** That is decision B3 and it is also every project written
    /// before this milestone, which is why the short-circuit is a `fileExists`
    /// rather than a load: the ordinary case must not cost a registry read, a
    /// cache load or a write, and a project that never joined a chain must not
    /// grow a cache entry for being opened.
    ///
    /// **It throws.** A registry record that is present and cannot be read
    /// refuses the whole resolution (RULING-54), because a device silently
    /// un-admitted by a permissions error is exactly the shape that rule
    /// exists to forbid. A record that is present and says something WRONG is
    /// not this: the reader lists it as malformed and the load goes on.
    nonisolated public static func resolve(
        projectURL: URL,
        identities: LocalIdentities,
        presenter: NSFilePresenter? = nil,
        cache: RegistryCache? = nil
    ) throws -> TrustTable {
        guard hasRegistry(in: projectURL) else { return keyless(mine: identities) }
        let cache = cache ?? .shared

        let folder = try RegistryReader.load(projectURL: projectURL, presenter: presenter)
        let reconciled = try cache.reconcile(
            folder: folder, cached: cache.cached(for: projectURL),
            in: projectURL, presenter: presenter).registry

        let joined = cache.joinedRoot(for: projectURL)
        let table = TrustTable.resolve(
            registry: reconciled, mine: identities, joinedRoot: joined)

        // B1: the first root that names this device is the one it is on.
        // `RegistryCache.join` is what enforces write-once — a later, different
        // root becomes a listed claimant and the join is unchanged — so the
        // guard here buys nothing but the lock and the persist that a resolve
        // with nothing new to say would otherwise cost on every load.
        if joined == nil, let root = table.myRoot {
            cache.join(root: root, for: projectURL)
        }
        return table
    }

    /// The table a reader uses when there is nothing to judge by: this device's
    /// own keys are its own and every other key answers `.noChain`.
    ///
    /// That is P1's behaviour exactly — a seal of ours is `verified`, anybody
    /// else's is `unsignedHistory` and applied — which is why every suite
    /// written before P2a passes unchanged: a project with no `.maugham/people`
    /// resolves to this.
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
}
