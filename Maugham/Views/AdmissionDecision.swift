// Maugham/Views/AdmissionDecision.swift
import Foundation
import MaughamCore

/// One device asking to be let into this book (signed op log P2, spec §4.1).
///
/// Everything the sheet says is decided here and carried as a value, so the
/// question *what would the writer be shown* is answerable with no window at
/// all. The sheet draws it; it never derives it.
struct AdmissionRequest: Identifiable, Equatable {
    /// The device this is about — the fingerprint the held lines are counted
    /// under, which is the device record's own key where a record names it and
    /// the sealing key itself where none does.
    let fingerprint: String
    /// What that device calls itself, from its device record. **Nil is a real
    /// state**: a device that wrote before this milestone, or whose record has
    /// not synced yet, is a stranger with no name, and inventing one for it
    /// would put a word in its mouth on the one screen where the writer is
    /// deciding whether to believe it.
    let ownName: String?
    /// The four characters that device shows for itself in its own Settings
    /// (`DeviceCode`). Shown, never demanded.
    let code: String
    /// How many lines of this device's history are held right now.
    let waitingCount: Int
    /// What the label field starts with — its own name, because the ordinary
    /// answer to *what shall I call this* is *what it calls itself*. Empty when
    /// the device has no record here, which leaves Admit refused until the
    /// writer types something (`outcome` answers `.notNow` for empty).
    let proposedLabel: String
    /// Every label this book already knows, so *this is also…* can offer them
    /// rather than making the writer re-spell one. Sorted, and deduplicated
    /// case-insensitively on first spelling.
    let knownLabels: [String]

    var id: String { fingerprint }

    /// The name to say this device by in a sentence. Its own name where it has
    /// one, else the code — which is the one thing the writer can check against
    /// the other screen.
    var displayName: String {
        if let ownName, !ownName.isEmpty { return ownName }
        return "A device with code \(code)"
    }

    /// What `RegistryAdmission.admit` records as this device's own name. The
    /// device's word where the folder has it; the code otherwise, so the record
    /// carries something a human can match against a screen rather than an
    /// empty string.
    var recordedOwnName: String {
        if let ownName, !ownName.isEmpty { return ownName }
        return code
    }
}

/// What pressing a button on the sheet means.
///
/// `.admit` and `.mergeUnder` both end in the same write — the difference is
/// whose SPELLING the person record carries — and they are two cases rather
/// than one so the sheet can say which is about to happen, and so a test can
/// pin the merge without reading a string twice.
enum AdmissionOutcome: Equatable {
    /// Let this device in under a label this book has not used before.
    case admit(label: String)
    /// Let it in under a label this book already has, in that label's own
    /// existing spelling. Spec §4.1: *a typed label matching an existing one
    /// merges the device under that label; nobody can be admitted AS a new
    /// "Denver" by asking.*
    case mergeUnder(label: String)
    /// Nothing happens. The lines stay held and History goes on counting them.
    case notNow
}

/// **Who is asking, and what an answer means** (spec §4.1–4.2).
///
/// Pure, and deliberately ignorant of the folder: it is handed the counts a
/// load already produced, the registry a reader already verified, and this
/// device's own label memory. Nothing here reads a file, so the whole of the
/// sheet's content is decidable in a unit test and nothing about admission is
/// only observable by mounting a window.
enum AdmissionDecision {

    /// The strangers waiting, one request each, ordered by fingerprint so two
    /// runs over the same folder ask in the same order.
    ///
    /// **Empty when this device has no root** (decision B3). A device no record
    /// names judges nobody, so nothing of anybody's is held and there is
    /// nothing to admit — and asking anyway would be this Mac inviting a device
    /// into a book it is not itself in. `myRoot` is `TrustTable.myRoot`.
    ///
    /// **A fingerprint with a person record is not a stranger**, whoever
    /// admitted it: under my own root it is already in, and under another
    /// root's it is a claimant, which is merged by a claim record at a surface
    /// and never by this sheet (`RegistryAdmission.admit` refuses it outright).
    static func requests(
        pending: [String: Int],
        registry: Registry,
        memory: [String: AdmissionMemory.Label],
        myRoot: String?
    ) -> [AdmissionRequest] {
        guard myRoot != nil else { return [] }
        let labels = knownLabels(registry: registry, memory: memory)
        return pending.keys.sorted().compactMap { fingerprint -> AdmissionRequest? in
            guard let waiting = pending[fingerprint], waiting > 0 else { return nil }
            guard registry.person(fingerprint) == nil else { return nil }
            let record = registry.devices.first { $0.device == fingerprint }
            let ownName = record?.name
            return AdmissionRequest(
                fingerprint: fingerprint,
                ownName: ownName,
                code: DeviceCode.short(fingerprint),
                waitingCount: waiting,
                proposedLabel: ownName ?? "",
                knownLabels: labels)
        }
    }

    /// What the writer's typed label means for this request.
    ///
    /// Whitespace is trimmed first, because a trailing space is a typo and not
    /// a second person. An empty field is `.notNow` — there is nothing to call
    /// this device, so nothing is written.
    static func outcome(for request: AdmissionRequest, typedLabel: String) -> AdmissionOutcome {
        let typed = typedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return .notNow }
        if let existing = request.knownLabels.first(where: { matches($0, typed) }) {
            return .mergeUnder(label: existing)
        }
        return .admit(label: typed)
    }

    /// Two labels are the same person when they differ only in case or in the
    /// space around them. Deliberately not a fuzzier rule: "Denver" and "denver"
    /// are one writer, "Denver" and "Denvers" are two, and guessing past that
    /// would merge two people's history on a typo.
    static func matches(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines))
            == .orderedSame
    }

    /// Every label this book already knows — the registry's person records
    /// first, then anything this device has said before about a device the
    /// folder has no record of yet.
    static func knownLabels(
        registry: Registry, memory: [String: AdmissionMemory.Label]
    ) -> [String] {
        var seen: [String] = []
        for label in registry.people.map(\.label) + memory.values.map(\.label) {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !seen.contains(where: { matches($0, trimmed) }) else { continue }
            seen.append(trimmed)
        }
        return seen.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - When it refuses

    /// A refusal in the writer's own language, carrying what the error itself
    /// says (RULING-7: a thing that failed is never presented as a thing that
    /// did nothing).
    ///
    /// Both `RegistryAdmissionError` cases are refusals of AUTHORITY, and they
    /// want different sentences because they want different next moves: one is
    /// *this Mac cannot do this at all*, the other is *somebody else already
    /// did, and merging is a different act*.
    static func refusal(_ error: Error) -> String {
        switch error {
        case RegistryAdmissionError.notARoot:
            return "This Mac isn’t this book’s root, so nothing it signs would let a "
                + "device in. Admit from the Mac that started the book."
        case RegistryAdmissionError.alreadyAdmittedElsewhere(let root):
            return "Another Mac (code \(DeviceCode.short(root))) already admitted this "
                + "device. Two chains are merged by claiming the book, never by "
                + "admitting into both."
        default:
            return "That device couldn’t be admitted: \(error.localizedDescription)"
        }
    }
}
