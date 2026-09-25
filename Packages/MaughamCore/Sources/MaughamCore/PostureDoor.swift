import Foundation

/// **The one door a surface builds a `Posture` through** — on the Mac and on
/// the phone alike (signed op log P3c plan 2, Task 1; tripwires 19, 46, 51).
///
/// A posture is the permit asked a surface's question, and the permit is
/// `OpLogStore.localWritePermit` (tripwire 46). Before this door each Mac site
/// that needed one — the window's door, the ruling performer's windowless
/// fallback, the translation pipeline — wrapped that builder in a `Posture(`
/// of its own, and the phone would have been a fourth. Now there is ONE place
/// that turns a `LocalWritePermit` into a `Posture`: `posture(permit:)`, which
/// the two convenience entries funnel through.
///
/// **What stays out of Core.** Whom the root yields to is the Mac's decision
/// (it reads `PieceWriters` and the window's *Edit Anyway* set), so this door
/// takes the yield as an already-decided name and decides nothing about it.
/// Caching is the caller's too: the Mac's door keeps a per-epoch cache and
/// resolves the class off its live manifest (ruling AD), then hands the
/// permit it cached to `posture(permit:)`.
public enum PostureDoor {

    /// The posture for `docId`, for `actor`'s key, with the document's class
    /// read off the manifest on disk (`OpLogStore.documentClass(forDocId:in:)`)
    /// — the entry for a caller holding a project URL and nothing else.
    @MainActor
    public static func posture(
        forDocId docId: String, in projectURL: URL,
        as actor: DeviceActor = .author, using store: OpLogStore
    ) -> Posture {
        posture(as: actor, using: store) {
            OpLogStore.documentClass(forDocId: docId, in: projectURL)
        }
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

    /// **The one place a `LocalWritePermit` becomes a `Posture`.** `yieldingTo`
    /// is a name the caller has already decided on; nil everywhere but the
    /// Mac's root yielding to a piece's owner, and a book author's Mac
    /// yielding to a piece's starter (Ruling U — the fact is the permit's
    /// `unsettledStarter`; the yield, and its *Edit Anyway*, are the Mac's).
    public static func posture(
        permit: LocalWritePermit, yieldingTo: String? = nil
    ) -> Posture {
        Posture(permit, yieldingTo: yieldingTo)
    }
}
