import Foundation
import MaughamCore

/// What `adoptExternalManifest` did with a manifest that arrived from
/// elsewhere, and so which copy is the loser `DocumentStore` archives.
enum ManifestAdoption: Equatable {
    /// The incoming manifest is now this window's. `replaced` is the copy it
    /// displaced — the loser — or nil when the two said the same thing and
    /// nothing was lost.
    case adopted(replaced: ProjectManifest?)
    /// This window holds a structural change of its own that has not reached
    /// disk, so its save is about to land after the incoming one: the incoming
    /// manifest is the loser and nothing here moved.
    case keptUnsavedChange
}

extension ProjectStore {

    /// **Take on a manifest another device wrote** (F7, 2026-09-23).
    ///
    /// The manifest is one object rewritten whole, so without this a window
    /// kept the copy it read at open for its whole life: a chapter another Mac
    /// added never appeared, and this Mac's next structural save wrote the
    /// stale copy over it. The master spec's rule is last-writer-wins with the
    /// loser kept in `.maugham/conflicts/`; this is the half that makes the
    /// incoming manifest the winner when it IS the later writer.
    ///
    /// **It refuses exactly one case**: `manifest` differing from
    /// `settledManifest`. Every structural verb mutates the manifest and then
    /// awaits its save, and some move files in between, so adopting in that
    /// window would drop a change whose file surgery has already happened —
    /// manifest and disk disagreeing about where a chapter is. This window's
    /// save is about to land, which makes it the later writer and the incoming
    /// manifest the loser. Merging the two is not attempted; which structure
    /// wins a genuine concurrent edit is last-writer-wins, as it always was.
    ///
    /// `schemaVersion` takes no part in either comparison and never falls:
    /// the number only rises within a session (`writeManifest`'s raise-only
    /// door, the narrowing gate), neither of which is a writer's structural
    /// change, and an incoming lower number is the heal's to answer.
    ///
    /// Its one caller, `DocumentStore.handleManifestChanged`, has already
    /// refused a manifest from a later build (`decodeGuardingSchema`); a new
    /// caller must do the same, because nothing here checks the number.
    func adoptExternalManifest(_ incoming: ProjectManifest) -> ManifestAdoption {
        guard Self.sameIgnoringSchema(manifest, settledManifest) else {
            return .keptUnsavedChange
        }
        var adopted = incoming
        adopted.schemaVersion = max(incoming.schemaVersion, manifest.schemaVersion)
        let replaced = manifest
        manifest = adopted
        settledManifest = adopted
        return .adopted(
            replaced: Self.sameIgnoringSchema(replaced, adopted) ? nil : replaced)
    }

    private static func sameIgnoringSchema(
        _ a: ProjectManifest, _ b: ProjectManifest
    ) -> Bool {
        var a = a
        a.schemaVersion = b.schemaVersion
        return a == b
    }
}
