import Foundation
import MaughamCore

/// **Who a capture is from** (P2 spec §6's Inbox line).
///
/// A phone's captures arrive in the same pane whether the Mac has admitted it
/// or not, and until it does they are held rather than applied. So a row that
/// says nothing about its source is a row the writer reads as *my note is
/// here* when what is actually true is *your note is waiting for you to admit
/// this phone*. One line per row closes that, and the vocabulary is the
/// admission sheet's, so the two screens describe the same device in the same
/// words.
///
/// **A pure composition over what the store already resolved.** The inbox
/// reads the registry once per refresh for its trust table; the byline is that
/// same registry answering a second question, never a second read.
///
/// **A book with no chain says nothing at all** (B3). Under P1 every remote
/// key is `.noChain` and every capture is applied as unsigned history — which
/// is correct and unchanged — so labelling every row *not yet admitted* there
/// would invent a state the project is not in.
enum InboxByline {

    /// **What to call a device that has written into this book**, admitted or
    /// not: the name its own record gives, and otherwise the four-character
    /// code its Settings screen shows.
    ///
    /// One spelling, because two surfaces ask it of the same device and about
    /// the same decision — the Inbox's pending banner, and People & Devices'
    /// pending row — and a writer comparing *N captures from The old iPhone*
    /// with a row naming that phone something else has no way to tell whether
    /// they are looking at one machine or two.
    ///
    /// Keyed on the DEVICE fingerprint (what a held line carries), never on a
    /// capture's `deviceId`, which is the actor form `text(forDeviceId:…)`
    /// below takes.
    static func name(forDevice fingerprint: String, registry: Registry) -> String {
        registry.devices.first { $0.device == fingerprint }?.name
            ?? DeviceCode.short(fingerprint)
    }

    /// The line for one capture's `deviceId`, or nil when there is nothing
    /// worth saying: this Mac's own capture, and any capture in a book this
    /// device is on no chain of.
    ///
    /// `deviceId` is `<actor>-<first 16 of the fingerprint>` (`DeviceIdentity`),
    /// so the device record naming that actor is what turns a capture into a
    /// person. A device with no record here can still be named by its code —
    /// the same four characters its own Settings screen shows — which is
    /// precisely what the writer needs in order to admit it.
    static func text(
        forDeviceId deviceId: String, registry: Registry, table: TrustTable
    ) -> String? {
        guard table.myRoot != nil else { return nil }
        guard let dash = deviceId.firstIndex(of: "-") else { return nil }
        let actor = String(deviceId[deviceId.startIndex..<dash])
        let prefix = String(deviceId[deviceId.index(after: dash)...])
        guard !actor.isEmpty, !prefix.isEmpty else { return nil }

        guard let record = registry.devices.first(
                where: { $0.actors[actor]?.hasPrefix(prefix) == true }),
              let key = record.actors[actor]
        else {
            // No record at all: the code is everything this book knows about
            // the device, and it is enough to check against the phone's screen.
            return "from \(DeviceCode.short(prefix)) (not yet admitted)"
        }

        func label(_ person: String) -> String {
            registry.person(person)?.label ?? record.name
        }

        switch table.verdict(forSealKey: key) {
        case .mine:
            return nil
        case .admitted(let person):
            return "from \(label(person))"
        case .revoked(let person, _):
            return "from \(label(person)) (revoked)"
        case .retired(let device, _):
            // A retired device's PAST is verified and only what it wrote after
            // it stopped is refused, so the word here is the device's state
            // rather than a verdict on this entry: *retired* says why an old
            // capture reads normally and a new one does not arrive.
            return "from \(label(device)) (retired)"
        case .stranger:
            return "from \(record.name) (not yet admitted)"
        case .otherRoot:
            return "from \(record.name) (another chain)"
        case .noChain:
            return nil
        }
    }
}
