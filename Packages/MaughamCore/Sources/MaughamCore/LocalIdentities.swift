import Foundation

/// This device's writers, as the op log will name them.
///
/// A reader of the op log asks one question over and over: *is this device
/// string one of mine?* Before the actors there was one answer to compare
/// against; now there are up to four, and every place that chains, signs,
/// seals or counts "another device" has to mean all of them. Holding them in
/// one value is what keeps those places from each keeping their own list — a
/// list that would be missing an actor the day a fifth arrives, and would
/// quietly treat this device's own ops as a stranger's.
///
/// **Lazy, and a key exists only once a WRITER has named its actor.** This is
/// the rule the whole-branch review's C1 bought, and it splits cleanly in two:
///
/// - `subscript(actor:)` and the four named properties MINT on demand. Naming
///   an actor is the writer's act — `Document.load(actor:)`, the translation
///   writers, `TaskDeriver`'s Maugham id — and a key that is about to sign
///   something is a key worth minting.
/// - `all`, `fingerprints` and `identity(forDeviceId:)` ENUMERATE, and
///   enumeration never mints: they answer over exactly the actors whose key
///   already exists on this device. A read path therefore trusts the keys this
///   device has ever written with, and nothing else.
///
/// So `LocalIdentities.current` costs nothing at all until something asks it a
/// question, and constructing it — which every `OpLogStore` does by default —
/// mints no key. That is what lets the phone hold one blob: it is the `author`
/// and nothing else (plan constraint 7), its writers name `.author`, and the
/// three actors it never names are never minted, whatever it constructs.
///
/// A value built from four given identities (`init`, and the testing helpers)
/// is FIXED: it enumerates all four, because a caller who handed them over has
/// already decided who this device is.
public struct LocalIdentities: Sendable {
    /// Where the identities come from — four given ones, or this device's own
    /// `device/` folder, resolved lazily.
    private enum Source: Sendable {
        /// Four identities a caller handed over. Enumerates all four.
        case fixed(
            author: DeviceIdentity, assistant: DeviceIdentity,
            translator: DeviceIdentity, maugham: DeviceIdentity)
        /// This device's key folder. `nil` is the process's own
        /// (`DeviceState.directory`, memoized per actor); a URL is the
        /// test-only variant over a directory of the caller's choosing.
        case device(directory: URL?)
    }

    private let source: Source

    public init(
        author: DeviceIdentity,
        assistant: DeviceIdentity,
        translator: DeviceIdentity,
        maugham: DeviceIdentity
    ) {
        source = .fixed(
            author: author, assistant: assistant,
            translator: translator, maugham: maugham)
    }

    private init(source: Source) { self.source = source }

    /// This process's identities, resolved lazily. Constructing this value
    /// reads nothing and mints nothing.
    public static var current: LocalIdentities {
        LocalIdentities(source: .device(directory: nil))
    }

    /// `current`'s shape over a directory of the caller's choosing, so the
    /// lazy rule can be pinned without touching the machine's own keys.
    /// Unmemoized on purpose — the process cache is keyed by actor alone.
    static func device(in directory: URL) -> LocalIdentities {
        LocalIdentities(source: .device(directory: directory))
    }

    // MARK: - Naming an actor (mints)

    /// The identity for one actor, MINTING it if this device has never used
    /// it. Exhaustive over `DeviceActor` — a fifth case is a compile error
    /// here, which is the point of the enum being closed.
    ///
    /// This is the writer's door. A caller reaches it because it is about to
    /// sign something as that actor; the read paths use `all` /
    /// `identity(forDeviceId:)` instead and mint nothing.
    public subscript(actor: DeviceActor) -> DeviceIdentity {
        switch source {
        case let .fixed(author, assistant, translator, maugham):
            switch actor {
            case .author: author
            case .assistant: assistant
            case .translator: translator
            case .maugham: maugham
            }
        case let .device(directory):
            if let directory {
                DeviceIdentity.identity(for: actor, in: directory)
            } else {
                DeviceIdentity.identity(for: actor)
            }
        }
    }

    public var author: DeviceIdentity { self[.author] }
    public var assistant: DeviceIdentity { self[.assistant] }
    public var translator: DeviceIdentity { self[.translator] }
    public var maugham: DeviceIdentity { self[.maugham] }

    // MARK: - Enumerating what exists (never mints)

    /// The actors this device has a key for, in `DeviceActor.allCases` order.
    /// A fixed value is all four; a lazy one is exactly what is on disk.
    public var existingActors: [DeviceActor] {
        switch source {
        case .fixed: DeviceActor.allCases
        case let .device(directory):
            DeviceActor.allCases.filter {
                if let directory {
                    DeviceIdentity.hasPersistedIdentity(for: $0, in: directory)
                } else {
                    DeviceIdentity.hasPersistedIdentity(for: $0)
                }
            }
        }
    }

    /// Every local identity this device actually holds, in `DeviceActor
    /// .allCases` order, so a caller iterating either one sees the same
    /// sequence. Never mints: an actor with no key is not here.
    public var all: [DeviceIdentity] { existingActors.map { self[$0] } }

    /// The key fingerprints this device has. What "trusted" means when a
    /// signature is verified on read: any actor this device has ever written
    /// as. An actor it has never named is not trusted, because there is
    /// nothing of its to trust.
    public var fingerprints: Set<String> { Set(all.map(\.fingerprint)) }

    /// The local identity an op's `device` string names, or `nil` when the op
    /// came from somewhere else — or from an actor this device has never used.
    ///
    /// Matched on the whole device id and nothing looser: an id from another
    /// Mac carries the same `author-` prefix, and adopting one would have this
    /// device chain and seal a file it does not own — the collision tripwire 17
    /// is the record of.
    public func identity(forDeviceId deviceId: String) -> DeviceIdentity? {
        all.first { $0.deviceId == deviceId }
    }

    // MARK: - Why a WRITER never finds its actor missing

    /// A note about the case this type deliberately does not have a method for.
    ///
    /// `identity(forDeviceId:)` enumerates, so it can only answer for an actor
    /// whose key exists — which reads like a gap on the write path: what signs
    /// an op naming an actor this device has never used, the Maugham rebalance
    /// on a machine that has never rebalanced before?
    ///
    /// Nothing has to: a device id is DERIVED from its key
    /// (`<actor>-<fingerprint prefix>`), so a writer can only obtain one by
    /// naming the actor, and naming it is what mints it. By the time an op
    /// carries `maugham-…`, the Maugham key exists. `Document+Tasks` is the
    /// case in full — it reads `opStore.identities.maugham.deviceId` (the mint)
    /// and hands the ops to `OpLogStore.append` (the lookup).
    ///
    /// A "mint from the id's prefix" lookup would close nothing and open
    /// something: another Mac's `author-…` op has this device's own prefix, so
    /// such a lookup would mint this device's key just to discover the ids
    /// disagree — minting on a path that is not writing as that actor at all.
    /// The one state that reaches `nil` here is genuinely another device's op,
    /// which is exactly what the plain unchained append is for.
}
