// Maugham/Views/ClaimDecision.swift
import Foundation
import MaughamCore

/// **Is this book yours?** (signed op log P2b Task 8, spec §5, parent §4.7.)
///
/// One question, asked once, of a Mac that is holding a book it has no key in:
/// the writer restored a backup, moved to a new machine, or opened a folder
/// that arrived through a share. Everything the sheet says is decided here and
/// carried as a value, so *would the writer be asked, and what would they be
/// asked about* is answerable with no window at all.
///
/// **Three conditions, each a refusal in its own right.**
///
/// - This Mac is in **no chain here** (`TrustTable.myRoot == nil`). A Mac
///   already on a chain has nothing to claim: it is in this book. The merge
///   between two live roots is the same primitive reached from a different
///   surface — People & Devices' *this is also me* — and never from this sheet.
/// - The book **has a root**. A folder with no people in it is not somebody
///   else's book; it is a book with no registry yet, and
///   `RegistryPresence.ensureRootIfEmpty` roots it at the next open without
///   asking anybody anything. Asking here would put a dialog in front of the
///   ordinary first open of an ordinary new project.
/// - This Mac **can write the folder**. A book on a read-only volume, or a
///   share mounted for reading, is one where the only thing Claim could do is
///   fail after the writer had already answered — which is worse than not
///   asking, because it teaches them the answer does not matter.
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

    /// And what *Not mine* does, which is nothing: decision B3, the state the
    /// book is already in.
    static let notMineConsequence =
        "If it isn’t yours, Maugham goes on reading this history as unsigned and "
        + "changes nothing."

    static let title = "Is this book yours?"
    static let claimTitle = "Claim"
    static let notMineTitle = "Not mine"

    // MARK: - Whether to ask

    /// The offer for one project, or nil where any of the three conditions
    /// fails.
    ///
    /// Pure: the registry a reader already verified, the table resolved from
    /// exactly that registry, and the answer to *can this Mac write the
    /// folder* — which is I/O and is therefore the caller's to ask
    /// (`canWriteRegistry(in:)` below).
    static func offer(
        registry: Registry, table: TrustTable, canWriteRegistry: Bool
    ) -> ClaimOffer? {
        guard table.myRoot == nil, canWriteRegistry else { return nil }
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
    /// carries a refusal. What it buys is not asking a question this Mac could
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

/// **Once per project per launch** (spec §5: *one sheet*).
///
/// The claim is a question about a whole book, and a book that asks it twice in
/// one sitting is a dialog the writer cannot get rid of — so a project that has
/// been asked is remembered for the life of the process, whether the answer was
/// Claim, *Not mine*, or Escape. It is deliberately NOT persisted: the next
/// launch is a new chance to notice, which is what *until the next open* means
/// everywhere else in this milestone.
///
/// A class with a `shared` instance rather than a static set, so a test can
/// have one of its own and the production memory is not something a test can
/// leave marked.
@MainActor
final class ClaimPromptMemory {
    static let shared = ClaimPromptMemory()

    private var asked: Set<String> = []

    /// Answers whether this project should be asked NOW, and remembers that it
    /// was. One call per decision, so a caller cannot ask and forget to record.
    func shouldAsk(about projectURL: URL) -> Bool {
        asked.insert(projectURL.standardizedFileURL.path).inserted
    }
}
