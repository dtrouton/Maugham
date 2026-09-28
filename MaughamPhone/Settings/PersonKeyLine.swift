import MaughamCore

/// **Settings' device-wide line: whether this phone is recognised by the
/// writer's person key** (your devices are you, plan 2 Task 2).
///
/// One line, after Code, for the whole phone — the person key is the
/// writer's, not a book's. The pure half of the line, so every sentence is
/// pinned without a window (tripwire 33); the view draws `sentence` and
/// nothing else.
///
/// **Every sentence is made TRUE for what the look can know.** The phone only
/// FINDS the key (controller ruling 5 — it never mints and never names), so a
/// phone with no key is not necessarily one whose iCloud Keychain is off: the
/// Mac may not have made the key yet, or it has not synced here. The store
/// tells those apart (`PersonKeyFinding`), and so does this line. Where the
/// phone is not recognised, the line says what happens instead — the Mac's
/// admission sheet asks who this phone is (and remembers the answer,
/// `AdmissionMemory`), which is why the plan's *each book asks once* was not
/// used: it is false on a Mac that has already been told.
enum PersonKeyLine: Equatable, Sendable {
    /// The key is here, under this name — its item's, trimmed.
    case recognised(name: String)
    /// The key is here, and its item carries no name yet.
    case recognisedUnnamed
    /// The store answered and holds no item: no Mac has made the key, or it
    /// has not reached this phone.
    case notYetHere
    /// The store could not answer — iCloud Keychain off or locked, or this
    /// build has no access to it.
    case keychainUnreachable
    /// An item is there, and it is not a key.
    case unreadableKey
    /// This phone cannot sign, so it writes no record and makes no claim.
    case cannotSign

    /// What `PhoneDeviceRecord.findPersonKey(canSign:)` found — nil is the
    /// phone that cannot sign and so never looked.
    static func make(_ finding: PersonKeyFinding?) -> PersonKeyLine {
        guard let finding else { return .cannotSign }
        switch finding {
        case .found(let key):
            let name = key.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? .recognisedUnnamed : .recognised(name: name)
        case .absent: return .notYetHere
        case .unavailable: return .keychainUnreachable
        case .notAKey: return .unreadableKey
        }
    }

    /// The line Settings draws.
    var sentence: String {
        switch self {
        case .recognised(let name):
            return "Recognised as \(name) on your other devices."
        case .recognisedUnnamed:
            return "Recognised on your other devices. Your name shows here "
                 + "once a Mac has named you."
        case .notYetHere:
            return "Not recognised yet. Your Mac makes the key, and this phone "
                 + "picks it up through iCloud Keychain. Until then, your Mac "
                 + "asks who this phone is."
        case .keychainUnreachable:
            return "iCloud Keychain isn\u{2019}t reachable from this phone, so "
                 + "your Mac asks who this phone is instead of recognising it."
        case .unreadableKey:
            return "The key in iCloud Keychain couldn\u{2019}t be read, so your "
                 + "Mac asks who this phone is instead of recognising it."
        case .cannotSign:
            return "This phone has no key of its own to sign with, so your Mac "
                 + "asks who this phone is instead of recognising it."
        }
    }
}
