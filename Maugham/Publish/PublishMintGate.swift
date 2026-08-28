import Foundation

/// Serialises compiles of one edition — the (version, language, format)
/// triple — **within this process, for one project**.
///
/// `CompileOrchestrator.compile` loads the catalog, checks the triple against
/// it, compiles, and only then appends the new `Publication`. Two calls
/// arriving inside that window both read a catalog without the other's row,
/// both pass the guard, and both mint: two `Publication`s at one triple, and
/// on the source path two grabs of the same `next_version`. The catalog guard
/// cannot close it — it answers "does this edition already exist", and during
/// the window the honest answer is no. This gate answers the other question,
/// "is one already in flight", and it is the whole remaining fix: since the
/// publication stream was partitioned per device (merge 5aa873af,
/// `publications.<slug>.jsonl`) there is no cross-device contention left to
/// serialise, so an in-memory, per-process gate covers the real race.
///
/// One instance per project, held by `PublishingStores` — every compile of a
/// project must reserve on the SAME gate, which is why both production call
/// sites pass `stores.mintGate` rather than letting the default fire.
public actor PublishMintGate {

    /// The edition identity a compile mints at (spec 2026-07-23). `language`
    /// is `nil` for the source edition.
    public struct Key: Hashable, Sendable {
        public let version: String
        public let language: String?
        public let format: PublishConfig.Format
        /// The imprint this compile resolved, when any (`nil` for a book-level
        /// compile). A fourth identity component: an imprint's compile of an
        /// edition must not contend with the book's own compile of the same
        /// (version, language, format).
        public let imprint: String?

        public init(
            version: String, language: String?, format: PublishConfig.Format,
            imprint: String? = nil
        ) {
            self.version = version
            self.language = language
            self.format = format
            self.imprint = imprint
        }
    }

    private var inFlight: Set<Key> = []

    public init() {}

    /// True = reserved; false = a compile of this triple is already in flight.
    /// The caller that gets `true` owns the reservation and must `release` it
    /// on every exit, thrown errors included.
    public func reserve(_ key: Key) -> Bool {
        inFlight.insert(key).inserted
    }

    /// Hands the triple back. Releasing one nobody holds is a no-op.
    public func release(_ key: Key) {
        inFlight.remove(key)
    }

    /// Test-only: the triples currently held. A leaked reservation is
    /// otherwise invisible on the republish path, whose version carries a
    /// random `-r<suffix>` a test cannot predict and so cannot probe for.
    var _inFlightForTesting: Set<Key> { inFlight }
}
