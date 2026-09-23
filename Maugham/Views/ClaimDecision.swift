// Maugham/Views/ClaimDecision.swift
import Foundation
import MaughamCore

/// **This book is mine** — the claim, as a verb the writer chooses (signed op
/// log P2b Task 8, spec §5; made explicit by Denver's ruling on P3b smoke find
/// F3, 2026-09-23).
///
/// The claim is how a Mac holding a book it has no key in — the writer's
/// restored or new machine, after every device that could have admitted it is
/// gone — takes that book's history as its own. Until F3 it was a QUESTION put
/// to every such Mac at open, and an invited collaborator's Mac is exactly such
/// a Mac: the smoke saw one asked *Is it yours?* about somebody else's book,
/// where *Claim* would have made it a second root. Nothing in the folder tells
/// the restored Mac from the collaborator's (a Mac declares its own device
/// record at open, and a restored Mac holds a NEW key), so no predicate could
/// ask only the right one. **No Mac is asked unprompted.** The claim is a
/// control in People & Devices — *This Book Is Mine…* — pressed by the writer
/// who knows it is theirs, confirmed on `ClaimSheet`, and performed by
/// `DocumentStore.claim(adopting:)`.
///
/// Everything the control and its sheet say is decided here and carried as a
/// value, so *would the verb be offered, and what would it name* is
/// answerable with no window at all.
///
/// **Four conditions, each a refusal in its own right.**
///
/// - This Mac is in **no chain here** (`TrustTable.myRoot == nil`). A Mac
///   already on a chain has nothing to claim: it is in this book. The merge
///   between two live roots is the same primitive reached from a different
///   row — the claimant's *Merge: this is also me* — never this one.
/// - The book **has a root**. A folder with no people in it is not somebody
///   else's book; it is a book with no registry yet, and
///   `RegistryPresence.ensureRootIfEmpty` roots it at the next open.
/// - This Mac **can write the folder**. A book on a read-only volume, or a
///   share mounted for reading, is one where the only thing Claim could do is
///   fail after the writer had already decided.
/// - This Mac **can sign**. A claim is two signed records, and a Mac with no
///   key (a VM, CI's runner) is refused by `RegistryWriter` before anything is
///   written — so the control is not offered at all rather than offered and
///   refused.
struct ClaimOffer: Identifiable, Equatable {
    /// The roots this claim would adopt — every root in the book, because the
    /// question is about the whole book and answering it by halves is not
    /// something the writer was offered.
    let roots: [String]
    /// The devices whose history this Mac is holding, named as they name
    /// themselves — this is how a writer recognises their own book, and it is
    /// the device name rather than the label because the label is a word
    /// somebody else's Mac chose.
    let names: [String]

    /// Keyed on the roots, so a book whose registry gains one while the sheet
    /// is up is a new question rather than the old one wearing a new list.
    var id: String { roots.joined(separator: "+") }

    var question: String { ClaimDecision.question(names: names) }
}

enum ClaimDecision {

    /// **The question, in the writer's words** (spec §5).
    ///
    /// The names are capped, because a book with a dozen devices in it would
    /// otherwise put a paragraph of machine names inside a sentence: the first
    /// few are what a writer recognises, and the rest are counted.
    static let namesShown = 4

    static func question(names: [String]) -> String {
        guard !names.isEmpty else {
            return "This book’s history was written by devices this Mac doesn’t know. "
                + "Is it yours?"
        }
        return "This book’s history was written by devices this Mac doesn’t know "
            + "(\(list(names))). Is it yours?"
    }

    /// **What Claim does**, said before the writer presses it. A claim is two
    /// signed records and no way back through the app, so the sheet says what
    /// it will write rather than only what it will feel like.
    static let claimConsequence =
        "Claiming writes this Mac’s own key into the book and adopts what those "
        + "devices wrote, so their history is applied and attributed. They keep "
        + "their own keys."

    /// And what *Cancel* does, which is nothing: decision B3, the state the
    /// book is already in.
    static let cancelConsequence =
        "Cancel changes nothing: Maugham goes on reading this history as unsigned."

    // `title` lived here and was read by nothing: `ClaimSheet` builds its own
    // headline from the project's name (`ClaimSheet.title(projectTitle:)`), so
    // this was a second, quieter answer to what the sheet is called — the shape
    // a reviewer has to prove dead before touching the file. Deleted with C8.
    static let claimTitle = "Claim"
    static let cancelTitle = "Cancel"

    /// The People & Devices control, and the sentence beside it. The sentence
    /// is who the control is FOR, because a collaborator reading the pane must
    /// be able to tell at a glance that it is not for them.
    static let verbTitle = "This Book Is Mine\u{2026}"
    static let verbSentence =
        "If this is your own book and the Mac that started it is gone, claim it "
        + "here. If somebody invited you, don\u{2019}t — ask them to let this Mac in."

    // MARK: - Whether the verb is offered

    /// The claim People & Devices offers for one project, or nil where any of
    /// the four conditions fails.
    ///
    /// Pure: the registry a reader already verified, the table resolved from
    /// exactly that registry, the answer to *can this Mac write the folder* —
    /// which is I/O and is therefore the caller's to ask
    /// (`canWriteRegistry(in:)` below) — and whether this Mac's author key can
    /// sign.
    static func offer(
        registry: Registry, table: TrustTable, canWriteRegistry: Bool,
        canSign: Bool
    ) -> ClaimOffer? {
        guard table.myRoot == nil, canWriteRegistry, canSign else { return nil }
        let roots = registry.roots.map(\.person).sorted()
        guard !roots.isEmpty else { return nil }

        var names: [String] = []
        for root in roots {
            for member in [root] + registry.chain(underRoot: root)
                .subtracting([root]).sorted() {
                let name = name(of: member, in: registry)
                guard !names.contains(name) else { continue }
                names.append(name)
            }
        }
        return ClaimOffer(roots: roots, names: names)
    }

    /// **Can this Mac write this book's registry at all?**
    ///
    /// An `access` check on the registry's own directory — or, where the folder
    /// is not there (a registry this device holds only in its own memory,
    /// because something deleted the files), on the nearest ancestor that is.
    /// The path is asked of `RegistryWriter`, which is the one place a registry
    /// directory is spelled (tripwire 40).
    ///
    /// **It is a probe, not a promise.** A sandbox, an ACL or a volume
    /// remounting a second later can all refuse a write this answered yes to,
    /// which is why `RegistryAdmission.claim` still throws and the sheet still
    /// carries a refusal. What it buys is not offering a verb this Mac could
    /// not act on.
    static func canWriteRegistry(
        in projectURL: URL, fileManager: FileManager = .default
    ) -> Bool {
        var url = RegistryWriter.directoryURL(.people, in: projectURL)
        while !fileManager.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return false }
            url = parent
        }
        return fileManager.isWritableFile(atPath: url.path)
    }

    // MARK: - Naming

    /// What to call a person on the old chain: the name their DEVICE gives
    /// itself, because that is what the writer recognises and what that machine
    /// shows on its own screen; then the label somebody else's Mac gave them;
    /// then the four-character code, which is the one thing about a device with
    /// no record here that can be compared against anything.
    private static func name(of fingerprint: String, in registry: Registry) -> String {
        let candidates = [
            registry.devices.first { $0.device == fingerprint }?.name,
            registry.person(fingerprint)?.label,
        ]
        for candidate in candidates {
            guard let candidate,
                  !candidate.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            return candidate
        }
        return DeviceCode.short(fingerprint)
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > namesShown else {
            return names.joined(separator: ", ")
        }
        let shown = names.prefix(namesShown).joined(separator: ", ")
        let rest = names.count - namesShown
        return "\(shown), and \(rest) more"
    }
}
