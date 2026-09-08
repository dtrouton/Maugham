import Foundation

/// This device's four writers in one value.
///
/// A reader of the op log asks one question over and over: *is this device
/// string one of mine?* Before the actors there was one answer to compare
/// against; now there are four, and every place that chains, signs, seals or
/// counts "another device" has to mean all four of them. Holding them in one
/// value is what keeps those places from each keeping their own list — a list
/// that would be missing an actor the day a fifth arrives, and would quietly
/// treat this device's own ops as a stranger's.
///
/// **Lazy, per actor.** `current` reads `DeviceIdentity.identity(for:)` for
/// each actor, and that call mints on first ask. Touching `current` as a whole
/// therefore mints all four — fine on the Mac, which is all four — but the
/// phone is the `author` and nothing else (plan constraint 7) and must reach
/// `DeviceIdentity.author` directly rather than through here.
public struct LocalIdentities: Sendable {
    public let author: DeviceIdentity
    public let assistant: DeviceIdentity
    public let translator: DeviceIdentity
    public let maugham: DeviceIdentity

    public init(
        author: DeviceIdentity,
        assistant: DeviceIdentity,
        translator: DeviceIdentity,
        maugham: DeviceIdentity
    ) {
        self.author = author
        self.assistant = assistant
        self.translator = translator
        self.maugham = maugham
    }

    /// Exhaustive over `DeviceActor` — a fifth case is a compile error here,
    /// which is the point of the enum being closed.
    public subscript(actor: DeviceActor) -> DeviceIdentity {
        switch actor {
        case .author: author
        case .assistant: assistant
        case .translator: translator
        case .maugham: maugham
        }
    }

    /// Every local identity, in `DeviceActor.allCases` order, so a caller
    /// iterating either one sees the same sequence.
    public var all: [DeviceIdentity] { DeviceActor.allCases.map { self[$0] } }

    /// The four key fingerprints. What "trusted" means when a signature is
    /// verified on read: any of this device's own actors.
    public var fingerprints: Set<String> { Set(all.map(\.fingerprint)) }

    /// The local identity an op's `device` string names, or `nil` when the op
    /// came from somewhere else.
    ///
    /// Matched on the whole device id and nothing looser: an id from another
    /// Mac carries the same `author-` prefix, and adopting one would have this
    /// device chain and seal a file it does not own — the collision tripwire 17
    /// is the record of.
    public func identity(forDeviceId deviceId: String) -> DeviceIdentity? {
        all.first { $0.deviceId == deviceId }
    }

    /// This process's four identities. Computed rather than stored, over the
    /// per-actor memoization in `DeviceIdentity.identity(for:)`, so nothing is
    /// minted until it is asked for.
    public static var current: LocalIdentities {
        LocalIdentities(
            author: .identity(for: .author),
            assistant: .identity(for: .assistant),
            translator: .identity(for: .translator),
            maugham: .identity(for: .maugham))
    }
}
