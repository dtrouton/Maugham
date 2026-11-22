import SwiftUI
import MaughamCore
import os

private let _castLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "EditionCast")

/// **Who translates, reads and collates an edition, who designs the book,
/// and starting an edition** (shell p4 Task 7) — the verbs the Department
/// desk carried, in one home, reached from the Editions header's `+`, the
/// Source row's menu and an edition's Brief.
///
/// **One sheet** (`EditionCastSheet`) names everybody, and every naming is
/// `translatorRole(for:)` (or its reader/collator siblings) + `renameProductionRole`
/// — never a nameless role left standing.
///
/// **Asked of the statement the cast belongs to** (tripwires 47, 51): the
/// cast is a fact of the edition's brief, so a verb is offered where this
/// Mac may write that brief (`StatementSurfaceVerbs`), the designer where it
/// may write the visual language, and Add Language where it may write the
/// book's own statements. Drawn from `posture(forDocId:)`; an act asks the
/// SETTLED posture again before it writes.
@MainActor
enum EditionCastVerbs {

    // MARK: - Words

    /// The ellipsis promises a sheet: the language and its translator are
    /// still to be named.
    static let addLanguageTitle = "Add Language\u{2026}"
    static let addLanguageHelp =
        "Start an edition in another language and say who translates it"
    /// A Brief's door to the cast sheet.
    static let changeCastTitle = "Change\u{2026}"
    static let nameCastTitle = "Name the Translator\u{2026}"
    static func castDoorTitle(hasCast: Bool) -> String { hasCast ? changeCastTitle : nameCastTitle }
    static func castDoorLabel(language: String) -> String {
        "Change who is cast for the "
            + TreeEditionRows.title(forLanguage: language) + " edition"
    }

    /// A proposed brief for a language with no edition yet, on the Source
    /// edition's Brief.
    static func proposedWithoutAnEditionLine(language: String) -> String {
        "Claude proposed a brief for an edition in "
            + TranslationPipeline.Environment.languageName(tag: language) + "."
    }
    static func addProposedTitle(language: String) -> String {
        "Add " + TranslationPipeline.Environment.languageName(tag: language) + "\u{2026}"
    }
    static let discardProposalTitle = "Discard"
    static func discardProposalLabel(language: String) -> String {
        "Discard the proposed "
            + TranslationPipeline.Environment.languageName(tag: language) + " brief"
    }

    // MARK: - May this Mac cast? (drawing door)

    /// The edition brief's own posture id — the statement the cast is about.
    static func briefPostureDocId(language: String, in manifest: ProjectManifest) -> String {
        StatementEditorHost.postureDocId(kind: .editionBrief(language), scope: .project,
                                         statements: manifest.statements)
    }

    static func designerPostureDocId(in manifest: ProjectManifest) -> String {
        StatementEditorHost.postureDocId(kind: .visualLanguage, scope: .project,
                                         statements: manifest.statements)
    }

    /// Whether an edition's cast is offered for change. Hidden, never disabled.
    static func mayCast(language: String, store: ProjectStore, documentStore: DocumentStore) -> Bool {
        StatementSurfaceVerbs.offered(under: documentStore.posture(
            forDocId: briefPostureDocId(language: language, in: store.manifest)))
    }

    static func mayNameTheDesigner(store: ProjectStore, documentStore: DocumentStore) -> Bool {
        StatementSurfaceVerbs.offered(under: documentStore.posture(
            forDocId: designerPostureDocId(in: store.manifest)))
    }

    /// Add Language: the book's own statements' posture — a new edition's
    /// brief would be a new project statement.
    static func mayAddLanguage(documentStore: DocumentStore) -> Bool {
        StatementSurfaceVerbs.offered(under: documentStore.posture(
            forDocId: DocumentClass.projectStreamDocId))
    }

    // MARK: - The asks

    static func addPrompt(proposing tag: String? = nil, manifest: ProjectManifest) -> EditionCastPrompt {
        var prompt = EditionCastPrompt(ask: .addLanguage)
        prompt.proposedTag = tag ?? ""
        for language in manifest.removedEditions ?? [] {
            guard let name = EditionStatus.translatorName(for: language, in: manifest) else { continue }
            prompt.removedCasts[language.lowercased()] = .init(
                name: name, reader: EditionStatus.readerName(for: language, in: manifest),
                collator: EditionStatus.collatorName(for: language, in: manifest))
        }
        return prompt
    }

    /// The edition's whole cast, as it reads now — a pure read, so opening
    /// the sheet mints nothing. Nobody named travels as "", a naming.
    static func renamePrompt(language: String, in manifest: ProjectManifest) -> EditionCastPrompt {
        EditionCastPrompt(
            ask: .rename(subject: .edition(language: language),
                         currentName: EditionStatus.translatorName(for: language, in: manifest) ?? ""),
            currentReader: EditionStatus.readerName(for: language, in: manifest),
            currentCollator: EditionStatus.collatorName(for: language, in: manifest))
    }

    /// `designerRole()` answers the preset when nothing is stored, so the
    /// field starts with Tschichold on a project that never customized him.
    static func designerPrompt(store: ProjectStore) -> EditionCastPrompt {
        EditionCastPrompt(ask: .rename(subject: .designer,
                                       currentName: store.designerRole().effectiveName))
    }

    /// What the one notice line says when the writer backs out.
    static func cancelledLine(_ prompt: EditionCastPrompt) -> String {
        switch prompt.ask {
        case .nameForRun(let language, _), .nameForBookRun(let language, _):
            return EditionCastCopy.cancelledLine(language: language)
        case .addLanguage:
            return EditionCastCopy.addCancelledLine
        case .rename(_, let currentName):
            return EditionCastCopy.renameCancelledLine(currentName: currentName)
        }
    }

    // MARK: - The acts

    /// What Add Language did.
    enum Added: Equatable {
        /// The edition exists now, its translator named. `warning` says what
        /// of the rest of its cast could not be named (review M1), else nil.
        case added(language: String, warning: String?)
        /// The book already has this edition: nothing is written, and the
        /// window goes to that edition's Brief, where its cast is changed.
        case existing(language: String)
        /// A REMOVED edition came back as it was — its translations and its
        /// stored cast, nobody renamed (closing review IM1).
        case restored(language: String)
        /// Nothing was added; the sentence says why.
        case refused(String)
    }

    /// **Where Add Language lands** (fix round): a new edition selected, on
    /// its Brief when a proposed brief brought the writer here (it waits
    /// there) else on To resolve (Run Whole Book is the next step); an
    /// edition the book has, selected on its Brief; a refusal said. Pure.
    struct Landing: Equatable {
        var select: BinderSubject?
        var position: RightColumnPosition?
        var alert: String?
    }

    nonisolated static func landing(_ added: Added, proposed: Bool) -> Landing {
        switch added {
        case .added(let language, let warning):
            return Landing(select: .edition(language: language),
                           position: proposed ? .brief : .resolve, alert: warning)
        case .existing(let language):
            return Landing(select: .edition(language: language), position: .brief, alert: nil)
        case .restored(let language):
            return Landing(select: .edition(language: language), position: .brief,
                           alert: EditionCastCopy.restoredLine(language: language))
        case .refused(let sentence):
            return Landing(select: nil, position: nil, alert: sentence)
        }
    }

    /// Whether `tag` already has an edition: a language the tree lists, or a
    /// translator the manifest stores. Both, because a miss is not a
    /// duplicate row, it is a rename the writer did not mean (issue #43, F-G).
    ///
    /// A REMOVED edition is neither (shell p4 closing round): its stored
    /// translator stays, and adding the language again brings it back.
    /// **Whether Add brings a removed edition back as it was**: the tag is
    /// removed and its translator is stored. Pure.
    nonisolated static func restores(_ tag: String, manifest: ProjectManifest) -> Bool {
        !BookEditions.lists(tag, removed: manifest.removedEditions) && manifest.storedTranslator(for: tag) != nil
    }

    static func alreadyAnEdition(_ tag: String, editions: [String], manifest: ProjectManifest) -> Bool {
        editions.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            || (manifest.storedTranslator(for: tag) != nil && BookEditions.lists(tag, removed: manifest.removedEditions))
    }

    /// **Start an edition**: mint its translator, named. Decided over the
    /// store's CURRENT editions (read at the act, never a held list) and the
    /// SETTLED posture. An edition the book already has is a sentence, never
    /// a silent rename.
    static func addLanguage(answer: EditionCastAnswer, store: ProjectStore,
                            documentStore: DocumentStore) async -> Added {
        let language = (answer.language ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard TranslationRecord.isValidLanguageTag(language) else {
            return .refused(EditionCastCopy.unusableTag(language))
        }
        let posture = await documentStore.settledPosture(forDocId: DocumentClass.projectStreamDocId)
        guard StatementSurfaceVerbs.offered(under: posture) else {
            return .refused(EditionCastCopy.mayNotCast)
        }
        // **A removed edition is restored, not re-cast** (closing review IM1):
        // its stored translator stands, so the sheet's names are not asked
        // of it — the edition simply shows again, as it was.
        if restores(language, manifest: store.manifest) {
            do {
                try await store.setEdition(language, removed: false)
            } catch {
                _castLog.error("could not bring back the \(language, privacy: .public) edition: \(error, privacy: .public)")
                return .refused(EditionCastCopy.restoreFailed(language: language))
            }
            return .restored(language: language)
        }
        let editions = TreeEditionRows.languages(store: store)
        if alreadyAnEdition(language, editions: editions, manifest: store.manifest) {
            return .existing(language: editions.first {
                $0.caseInsensitiveCompare(language) == .orderedSame } ?? language)
        }
        let named = await nameCast(language: language, answer: answer, store: store)
        guard named.translatorNamed else {
            return .refused(named.failure ?? EditionCastCopy.mintFailed(language: language))
        }
        // A removed edition with no stored translator (never cast) comes back
        // through the ordinary mint above; its tag is cleared here.
        do {
            try await store.setEdition(language, removed: false)
        } catch {
            _castLog.error("could not bring back the \(language, privacy: .public) edition: \(error, privacy: .public)")
            return .refused(EditionCastCopy.restoreFailed(language: language))
        }
        return .added(language: language, warning: named.missing.isEmpty ? nil
            : EditionCastCopy.partlyNamed(language: language, missing: named.missing))
    }

    // MARK: - Removing an edition (shell p4 closing round)

    static let removeEditionTitle = "Remove Edition\u{2026}"
    static let removeEditionHelp =
        "Hide this edition. Its translations stay in the project and come back if you add the language again."

    /// What Remove Edition did.
    enum Removed: Equatable {
        case removed(language: String)
        /// Nothing was hidden; the sentence says why.
        case refused(String)
    }

    /// **Which edition the act is about, if it may be removed at all**: a
    /// translated edition the book lists now — never the Source. Pure, over
    /// the store's CURRENT editions (`TreeEditionRows.languages`, Source
    /// first).
    nonisolated static func removable(_ language: String, editions: [String]) -> String? {
        guard let match = editions.dropFirst().first(where: {
            $0.caseInsensitiveCompare(language) == .orderedSame }) else { return nil }
        return match
    }

    /// **What stops a removal now**: a round translating into the language
    /// (or a round whose language is not yet known), or a compile rendering
    /// it, in this window's runner. Nil when nothing does. Pure.
    nonisolated static func removalBusy(language: String, session: TranslationRunSession,
                                        compile: CompileRunState.Phase) -> String? {
        if case .busy(let running) = session,
           running.map({ $0.caseInsensitiveCompare(language) == .orderedSame }) ?? true {
            return EditionCastCopy.removeWhileTranslating(language: language)
        }
        if case .running(_, let languages, _) = compile,
           languages.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
            return EditionCastCopy.removeWhileCompiling(language: language)
        }
        return nil
    }

    /// **Hide an edition** (owner's answer 1, 2026-11-22): the exact inverse
    /// of Add Language for the edition's EXISTENCE — the edition leaves the
    /// tree, the switch, the marks and the compile list — and nothing else
    /// moves: translation text, round ledgers, the edition's brief and cast,
    /// compiled books all stay, and adding the language again brings them
    /// back. Decided over the store's current editions and the SETTLED
    /// posture (Add Language's door), refused while `busy` says so.
    static func removeEdition(language: String, store: ProjectStore, documentStore: DocumentStore,
                              busy: (String) -> String?) async -> Removed {
        let posture = await documentStore.settledPosture(forDocId: DocumentClass.projectStreamDocId)
        guard StatementSurfaceVerbs.offered(under: posture) else {
            return .refused(EditionCastCopy.mayNotRemove)
        }
        let editions = TreeEditionRows.languages(store: store)
        guard let tag = removable(language, editions: editions) else {
            return .refused(editions.first.map {
                $0.caseInsensitiveCompare(language) == .orderedSame } == true
                ? EditionCastCopy.sourceIsNotRemovable : EditionCastCopy.noSuchEdition(language: language))
        }
        if let reason = busy(tag) { return .refused(reason) }
        do {
            try await store.setEdition(tag, removed: true)
        } catch {
            _castLog.error("could not remove the \(tag, privacy: .public) edition: \(error, privacy: .public)")
            return .refused(EditionCastCopy.removeFailed(language: tag))
        }
        return .removed(language: tag)
    }

    /// **A rename's Confirm** — an edition's cast or the designer. Asks the
    /// settled posture of the statement it is about; nil when it landed, else
    /// the sentence.
    static func confirmRename(_ answer: EditionCastAnswer, prompt: EditionCastPrompt,
                              store: ProjectStore, documentStore: DocumentStore) async -> String? {
        switch prompt.ask {
        case .rename(.edition(let language), _):
            let posture = await documentStore.settledPosture(
                forDocId: briefPostureDocId(language: language, in: store.manifest))
            guard StatementSurfaceVerbs.offered(under: posture) else { return EditionCastCopy.mayNotCast }
            return await nameCast(language: language, answer: answer, store: store).failure
        case .rename(.designer, _):
            let posture = await documentStore.settledPosture(
                forDocId: designerPostureDocId(in: store.manifest))
            guard StatementSurfaceVerbs.offered(under: posture) else { return EditionCastCopy.mayNotCast }
            return await renameTheDesigner(to: answer.name, store: store)
        case .nameForRun, .nameForBookRun, .addLanguage:
            return nil
        }
    }

    /// **Mint-then-rename, the one visible act, for the whole cast.**
    /// `translatorRole(for:)` finds or mints; the very next line names them.
    /// The reader and the collator follow, each only when the sheet sent a
    /// name (blank is "change nothing"). Answers whether the TRANSLATOR
    /// landed — a run the sheet stands in front of needs them — and the
    /// sentence for any part that did not.
    static func nameCast(language: String, answer: EditionCastAnswer, store: ProjectStore) async
        -> (translatorNamed: Bool, failure: String?, missing: [String]) {
        do {
            let translator = try await store.translatorRole(for: language)
            try await store.renameProductionRole(id: translator.id, to: answer.name)
        } catch {
            _castLog.error(
                "could not name the \(language, privacy: .public) translator: \(error, privacy: .public)")
            return (false, EditionCastCopy.mintFailed(language: language), [])
        }
        var failure: String?
        var missing: [String] = []
        for (name, mint, what) in [(answer.reader, store.readerRole(for:), "reader"),
                                   (answer.collator, store.collatorRole(for:), "collator")] {
            guard let name else { continue }
            do {
                let role = try await mint(language)
                try await store.renameProductionRole(id: role.id, to: name)
            } catch {
                _castLog.error(
                    "could not name the \(language, privacy: .public) \(what, privacy: .public): \(error, privacy: .public)")
                failure = EditionCastCopy.mintFailed(language: language)
                missing.append(what)
            }
        }
        return (true, failure, missing)
    }

    /// **Say who designs this book.** The id is `designerRole()`'s, the
    /// preset's when nothing is stored — `renameProductionRole` materializes
    /// it — so a project that already stored a designer renames that one.
    static func renameTheDesigner(to name: String, store: ProjectStore) async -> String? {
        do {
            try await store.renameProductionRole(id: store.designerRole().id, to: name)
            return nil
        } catch {
            _castLog.error("could not rename the designer: \(error, privacy: .public)")
            return EditionCastCopy.designerRenameFailed
        }
    }

    // MARK: - Proposed briefs with no edition

    /// **Proposed edition briefs for languages the book has no edition of** —
    /// sorted, for the Source edition's Brief. (A proposal for an edition the
    /// book has shows on that edition's own Brief, `StatementPane`'s gate.)
    nonisolated static func proposalsWithoutAnEdition(
        _ proposals: [StatementProposalStore.Proposal], editions: [String]
    ) -> [String] {
        let present = Set(editions.map { $0.lowercased() })
        return Set(proposals.compactMap { proposal -> String? in
            if case .editionBrief(let language) = proposal.kind { return language.lowercased() }
            return nil
        }).filter { !present.contains($0) }.sorted()
    }

    /// **Discard the proposal the writer was shown** (review M2), asked of
    /// that brief's settled posture and decided over the STORE: a proposal
    /// Claude re-staged since the line was drawn is not the one confirmed,
    /// so it is refused rather than deleted unseen. nil when it went, else
    /// the sentence.
    static func discardProposal(_ shown: StatementProposalStore.Proposal, store: ProjectStore,
                                documentStore: DocumentStore) async -> String? {
        guard case .editionBrief(let language) = shown.kind else { return nil }
        let posture = await documentStore.settledPosture(
            forDocId: briefPostureDocId(language: language, in: store.manifest))
        guard StatementSurfaceVerbs.offered(under: posture) else { return EditionCastCopy.mayNotCast }
        guard StatementProposalStore(projectURL: store.url).pending(for: shown.kind) == shown else {
            return EditionCastCopy.proposalChanged(language: language)
        }
        do {
            try StatementProposalGate.discard(shown.kind, store: store)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The question Discard asks first, naming the edition.
    static func discardQuestion(language: String) -> String {
        "Discard Claude\u{2019}s proposed brief for "
            + TranslationPipeline.Environment.languageName(tag: language) + "?"
    }
    static let discardConfirmTitle = "Discard Proposal"
}
