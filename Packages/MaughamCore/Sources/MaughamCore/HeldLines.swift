import Foundation

/// **Whose a held line is, and what to say about it** (P3b Task 2).
///
/// A held line is one the reader neither applied nor refused —
/// `OpLogChain.Line.State.pending(device:)`. P2 had exactly one reason to hold
/// one, a stranger's seal, so *held* and *waiting for admission* were the same
/// fact and every surface could read `pendingByDevice` raw. There are now
/// three, they share one storage state on purpose (same walk, same tallies,
/// one `applied` filter), and they are told apart HERE — once, by the string
/// the walk held them under:
///
/// - **a stranger** — a key this book has no person record for. The writer can
///   be asked to admit it, and admitting applies what it wrote.
/// - **permit-pending** — an ADMITTED person whose line this build cannot
///   judge (`Permit.Allowed.cannotJudge`: a later build's op kind, a role or
///   scope word this one does not know). She is already in the book; offering
///   an admission sheet about her would offer a control that changes nothing.
/// - **unsigned** — a line written after the first narrowing by a file this
///   register can name no key for (`UnsignedSnapshot`). There is no device to
///   admit, because there is no key: nothing on that Mac signs what it writes.
///   Its one way back in is the Inbox.
///
/// **The unsigned holder is a string no fingerprint can be**, and that is what
/// makes the classification total rather than a guess. A seal key is 64 hex
/// characters and a device id is `<actor>-<hex…>`; `DeviceSlug.make` maps
/// everything outside `[a-z0-9]` to `-`. A colon appears in none of them, so
/// `unsigned:<stream>` cannot collide with a key, cannot be parsed as a device
/// id (`DeviceIdentity.looksLikeADeviceId` answers false), and cannot be
/// mistaken for a person.
///
/// **One predicate, extended rather than copied.** `Registry.isStrangerDevice`
/// and its twin on `TrustTable` ask this type whether a holder is unsigned, so
/// every admission-worded count in the app narrows in the same place —
/// `strangersAwaitingAdmission`, `OpLogProvenance.pendingStrangersByDevice`,
/// the inbox's own map, `announcePendingHistory`. A filter per surface is how
/// one of them comes to offer an Admit… sheet about a Mac that has no key.
public enum HeldLines {

    // MARK: - The unsigned holder

    /// The one spelling of *this line was held because nothing signs it*.
    ///
    /// Private to this type: a second literal somewhere else is a holder one
    /// surface recognises and another calls a stranger.
    private static let unsignedPrefix = "unsigned:"

    /// **What the unsigned door holds a line under** — the STREAM it was in,
    /// named by the device slug its files carry, or by the stream key where
    /// there is no slug at all (the legacy unsuffixed `<docId>.jsonl`, which
    /// belongs to no device in particular and is exactly the file no key can
    /// name).
    ///
    /// The slug rather than the file, because a stream outlives its filenames:
    /// a rotated `.mzseg` and the tail it came out of are one writer, and two
    /// holder strings for them would ask the writer about one Mac twice.
    public static func unsignedHolder(
        forStreamKey key: String, deviceSlug: String?
    ) -> String {
        "\(unsignedPrefix)\(deviceSlug ?? key)"
    }

    /// `PermitMark.Stream`'s own answer, so no caller picks between the two
    /// halves above by hand.
    public static func unsignedHolder(for stream: PermitMark.Stream) -> String {
        unsignedHolder(forStreamKey: stream.key, deviceSlug: stream.deviceSlug)
    }

    /// Is this held-line holder an unsigned stream rather than a key?
    public static func isUnsignedHolder(_ device: String) -> Bool {
        device.hasPrefix(unsignedPrefix)
    }

    /// The stream (or slug) an unsigned holder names, for a surface that wants
    /// to say WHICH one; nil for anything that is not one.
    public static func streamOfUnsignedHolder(_ device: String) -> String? {
        guard isUnsignedHolder(device) else { return nil }
        let named = device.dropFirst(unsignedPrefix.count)
        return named.isEmpty ? nil : String(named)
    }

    // MARK: - Whose it is

    /// The three reasons a line is held, and nothing else is one.
    public enum Holder: Equatable, Hashable, Sendable {
        /// A key this book has no person record for. Admittable.
        case stranger(fingerprint: String)
        /// A person already in the book, whose line this build cannot judge.
        case permitPending(person: String)
        /// A stream nothing signs, after the first narrowing. The payload is
        /// `unsignedHolder`'s own — a device slug, or a stream key.
        case unsigned(stream: String)
    }

    /// **The one classifier.** Unsigned first, because that answer is decided
    /// by the string itself and no registry can contradict it; then the
    /// registry's own stranger predicate, which this function is the reason
    /// for.
    public static func holder(
        of pendingDevice: String, registry: Registry
    ) -> Holder {
        if let stream = streamOfUnsignedHolder(pendingDevice) {
            return .unsigned(stream: stream)
        }
        return registry.isStrangerDevice(pendingDevice)
            ? .stranger(fingerprint: pendingDevice)
            : .permitPending(person: pendingDevice)
    }

    // MARK: - What to say

    /// **One sentence per holder, and none of them is the others'.**
    ///
    /// `name` is the writer's word for whoever is waiting — the label the root
    /// gave them, else their four-character code — and is nil where there is
    /// nobody to name, which is every unsigned stream: a Mac with no key has
    /// no record, so the book has never been told what to call it.
    ///
    /// `notes` is the count of held OP lines, never the line tally: a held
    /// span's own seal line is one of those lines, and two held ops under one
    /// signature would read as three notes (`OpLogProvenance.pendingOpLines`
    /// is the sum that already makes that distinction).
    ///
    /// Nil for a count of nothing, so a surface drawing this never has to
    /// decide whether zero is worth a sentence.
    public static func sentence(
        _ holder: Holder, notes count: Int, named name: String? = nil
    ) -> String? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? "note" : "notes"
        let verb = count == 1 ? "is" : "are"
        switch holder {
        case .stranger:
            let who = name ?? "another device"
            return "\(count) \(noun) from \(who) \(verb) waiting for admission."
        case .permitPending:
            let who = name ?? "a device in this book"
            return "\(count) \(noun) from \(who) \(verb) waiting. This version "
                + "of Maugham can’t tell what they are allowed to write here; "
                + "a newer one will."
        case .unsigned:
            return "\(count) \(noun) \(verb) waiting from a Mac that signs "
                + "nothing it writes. There is no device to admit — what it "
                + "wrote can be brought back through the Inbox."
        }
    }
}
