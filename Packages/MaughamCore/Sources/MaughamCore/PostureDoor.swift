import Foundation

/// **The one door a surface builds a `Posture` through** — on the Mac and on
/// the phone alike (signed op log P3c plan 2, Task 1; tripwires 19, 46, 51).
///
/// A posture is the permit asked a surface's question, and the permit is
/// `OpLogStore.localWritePermit` (tripwire 46). Before this door each Mac site
/// that needed one — the window's door, the ruling performer's windowless
/// fallback, the translation pipeline — wrapped that builder in a `Posture(`
/// of its own, and the phone would have been a fourth. Now there is ONE place
/// that turns a `LocalWritePermit` into a `Posture`:
/// `posture(permit:yieldingTo:)`, which the three convenience entries —
/// `posture(forDocId:in:as:using:)`, `posture(as:using:documentClass:)` and
/// `postureYieldingToItsStarter(forDocId:in:as:using:)` — funnel through.
///
/// **Which yield is decided where.** The STARTER yield (Ruling U) is decided
/// here, from the permit's own `unsettledStarter` — a fact the one builder
/// already decided, so `postureYieldingToItsStarter` only hands its name to
/// `posture(permit:yieldingTo:)`; on the phone, which has no *Edit Anyway*,
/// that yield is a lock (Ruling W). The root's OWNER yield stays the Mac's
/// (it reads `PieceWriters` and the window's *Edit Anyway* set), and so does
/// the Mac's honouring of *Edit Anyway* over either yield: the Mac decides
/// the name and hands it in, and this door decides nothing about it.
/// Caching is the caller's too: the Mac's door keeps a per-epoch cache and
/// resolves the class and the starter off its live manifest (ruling AD), then
/// hands the permit it cached to `posture(permit:yieldingTo:)`.
///
/// **One manifest read per ask** (P3 plan 3 Task 6): the two entries that
/// start from a project URL hand the builder one `ManifestPlacement`, so a
/// narrowed book decodes its manifest once for both the class and the
/// starter, and a book that needs neither decodes nothing.
public enum PostureDoor {

    /// The posture for `docId`, for `actor`'s key, with the document's class
    /// and its piece's starter read off the manifest on disk, once
    /// (`ManifestPlacement`) — the entry for a caller holding a project URL and
    /// nothing else.
    @MainActor
    public static func posture(
        forDocId docId: String, in projectURL: URL,
        as actor: DeviceActor = .author, using store: OpLogStore
    ) -> Posture {
        posture(permit: store.localWritePermit(
            as: actor, placement: ManifestPlacement(docId: docId, in: projectURL)))
    }

    /// The posture for `actor`'s key in a class the CALLER names — a reader
    /// that constructs its stream's class rather than resolving it (the
    /// translation pipeline judges `.translation(piece:)`, as the partition
    /// does). The closure is asked only where the permit needs it.
    @MainActor
    public static func posture(
        as actor: DeviceActor, using store: OpLogStore,
        documentClass: () -> DocumentClass
    ) -> Posture {
        posture(permit: store.localWritePermit(as: actor, documentClass: documentClass))
    }

    /// **A surface with no *Edit Anyway*** — the phone (P3c plan 2 fix wave,
    /// Ruling W). The posture for `docId` as `posture(forDocId:in:as:using:)`
    /// answers it, except that wherever the permit carries
    /// `unsettledStarter` (somebody else started the piece and nobody has
    /// claimed it) it YIELDS to the starter, and — with no override to lift
    /// it — the yield is a lock: every verb but `annotate` refused until the
    /// piece is settled on a Mac. The fact is the permit's, decided once by
    /// `OpLogStore.localWritePermit`; this entry only hands its name to
    /// `posture(permit:yieldingTo:)`, exactly as the Mac's door does.
    @MainActor
    public static func postureYieldingToItsStarter(
        forDocId docId: String, in projectURL: URL,
        as actor: DeviceActor = .author, using store: OpLogStore
    ) -> Posture {
        let permit = store.localWritePermit(
            as: actor, placement: ManifestPlacement(docId: docId, in: projectURL))
        return posture(permit: permit, yieldingTo: permit.unsettledStarter?.yieldName)
    }

    /// **The one place a `LocalWritePermit` becomes a `Posture`.** `yieldingTo`
    /// is a name the caller has already decided on; nil everywhere but the
    /// Mac's root yielding to a piece's owner, and a book author yielding to
    /// a piece's starter (Ruling U — the fact is the permit's
    /// `unsettledStarter`; on the Mac the yield carries *Edit Anyway*, and on
    /// the phone, which has none, it is a lock — Ruling W).
    public static func posture(
        permit: LocalWritePermit, yieldingTo: String? = nil
    ) -> Posture {
        Posture(permit, yieldingTo: yieldingTo)
    }
}
