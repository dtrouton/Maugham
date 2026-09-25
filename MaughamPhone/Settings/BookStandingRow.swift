import SwiftUI
import MaughamCore

/// **One Settings row: what this phone is in one book, and what it may write
/// there** (signed op log P2 §4.11; P3c plan 2, Task 6).
///
/// The pure half of Settings' *This Device* section — every sentence the row
/// draws, and when the section re-reads — so the view is build-verified and
/// the decisions are pinned without a window (tripwire 33).
///
/// **Every word is somebody else's.** The standing sentence and the
/// retirement notice are `DeviceStanding`'s; the role line is `PermitWords`',
/// through `DeviceStanding.permitSentence` — the same words the Mac's People &
/// Devices draws for a person (tripwire 19). No rung is named here (tripwire
/// 47): the permit is read through `Permit.rung(of:)` in Core.
struct BookStandingRow: Equatable {
    /// The book's title.
    let title: String
    /// `DeviceStanding.sentence` — on whose Mac the book was started, under
    /// what name this phone is in it.
    let sentence: String
    /// What this phone may write here, or nil where there is no admission to
    /// speak of — a book with no register draws no role line and reads exactly
    /// as it did before P3.
    let permitLine: String?
    /// What retirement means, on the machine that retired.
    let retirementNotice: String?

    /// What a piece id this phone cannot find is called — `PermitWords`'
    /// `unknownPiece`, with this machine's own noun.
    static let unknownPiece = "a piece this iPhone can\u{2019}t find"

    static func make(
        title: String, structure: [StructureItem], standing: DeviceStanding
    ) -> BookStandingRow {
        BookStandingRow(
            title: title,
            sentence: standing.sentence,
            permitLine: standing.permitSentence(
                in: structure, unknownPiece: unknownPiece),
            retirementNotice: standing.retirementNotice(device: "iPhone"))
    }

    // MARK: - Resolving

    /// **This phone's standing in one book, off the reconciled register.**
    ///
    /// Resolved through `TrustResolution.resolveVerified` — the folder
    /// reconciled against this device's memory, the same resolution every
    /// phone op-log read already makes — rather than a raw `RegistryReader
    /// .load`, which would describe this phone off a registry the op log is
    /// not judged against (a deleted record read as never-was). The
    /// reconciliation may put back a record something deleted: already-signed
    /// bytes, signing nothing, exactly as the Annotations tab's read does. The
    /// phone signs no record here.
    ///
    /// A registry that will not READ answers the read's own sentence, never
    /// *not yet admitted* (RULING-54). Run it off the main actor: a directory
    /// walk plus a signature check per record.
    nonisolated static func standing(
        in projectURL: URL, mine: LocalIdentities, cache: RegistryCache
    ) -> DeviceStanding {
        do {
            let resolved = try TrustResolution.resolveVerified(
                projectURL: projectURL, identities: mine, cache: cache)
            return DeviceStanding.resolve(
                registry: resolved.registry, cache: cache, mine: mine, for: projectURL)
        } catch {
            return DeviceStanding.refused(mine: mine, error: error)
        }
    }

    // MARK: - When to read again (C5)

    /// **Settings re-reads when the app comes back to the front.** The
    /// standing changes on the MAC — the writer admits or promotes this phone
    /// there and comes back to check — and the phone has no file presenter
    /// (iOS tripwire 5), so returning to the app and pulling to refresh are
    /// the two moments it looks again.
    static func rereads(on phase: ScenePhase) -> Bool {
        phase == .active
    }
}
