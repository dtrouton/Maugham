import Foundation

// MARK: - Errors

public enum RepublishError: Error, LocalizedError {
    /// The snapshot's `PublishConfig` failed validation (e.g. traversal in
    /// `outputs.directory` or `filenameTemplate`). Fail loudly rather than
    /// writing output files outside the allowed roots (finding 1.5).
    case invalidSnapshotConfig(String)
    /// P2 (Task 6): the snapshot's frozen, UNFOLDED `config.json` could not be
    /// read. It is the only thing that says which of the record's language tags
    /// is the book's own — `snap.config` is the first body's language-FOLDED
    /// config and answers that question wrongly for every translated edition —
    /// so a republish without it cannot know what it is reproducing. Refused
    /// rather than guessed: the silent fallback would republish the Spanish
    /// edition as the English book under the Spanish name.
    case unreadableSnapshotConfig(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshotConfig(let msg): return msg
        case .unreadableSnapshotConfig(let msg): return msg
        }
    }
}

public struct Republisher {

    public typealias Outcome = CompileOrchestrator.Outcome

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let publicationStore: PublicationStore
    public let snapshotStore: PublicationSnapshotStore
    public let jobManager: CompileJobManager
    /// P2 (issue #25): the same per-project gate `CompileOrchestrator` uses —
    /// a republish mints a triple too, and two of them (or a republish and a
    /// compile that resolved to the same triple) must not be in flight at
    /// once. Defaulted for the test call sites; production passes
    /// `PublishingStores.mintGate`.
    public let mintGate: PublishMintGate
    public let maughamVersion: String
    public let tectonicVersion: String

    /// The random tail of a republish version (`<prior>-r<suffix>`). A stored
    /// property rather than a literal so a test can make the minted version —
    /// and therefore the output FILENAME — predictable; production never
    /// replaces it. See `uniqueRepublishVersion(base:existing:mintSuffix:)`.
    var mintSuffix: () -> String = Republisher.randomSuffix

    public init(
        projectURL: URL, astSource: ProjectASTBuilder.Source,
        publicationStore: PublicationStore,
        snapshotStore: PublicationSnapshotStore,
        jobManager: CompileJobManager,
        mintGate: PublishMintGate = PublishMintGate(),
        maughamVersion: String, tectonicVersion: String
    ) {
        self.projectURL = projectURL
        self.astSource = astSource
        self.publicationStore = publicationStore
        self.snapshotStore = snapshotStore
        self.jobManager = jobManager
        self.mintGate = mintGate
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
    }

    public func republish(
        snapshotID: String,
        format: PublishConfig.Format,
        label: String?
    ) async throws -> Outcome {
        let snap = try snapshotStore.load(id: snapshotID)

        // Traversal guard (finding 1.5): the snapshot's config is validated
        // here before it reaches PDFCompiler/EPUBCompiler, where
        // `outputs.directory` is appended to `projectURL` to form the output
        // path. A crafted `"../../outside"` would escape the project root.
        // `republish` trusts the snapshot, so we must re-check it rather than
        // relying only on `set_publish_config`'s write-time validation.
        let configErrors = PublishConfigValidator.validate(snap.config)
        if !configErrors.isEmpty {
            throw RepublishError.invalidSnapshotConfig(
                "Snapshot config failed validation: " +
                configErrors.map { "\($0.field): \($0.message)" }.joined(separator: "; "))
        }

        // Stage the snapshot's publish files to a temp project-shaped tree.
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("Republish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try PublicationSnapshotStore.extract(
            snap, into: stage.appendingPathComponent(".maugham/publish",
                                                     isDirectory: true))

        // Find the prior publication so we can fill `republishedFrom` and read
        // this edition's IDENTITY off it — the snapshot's config is already
        // language-effective (Task 7 Rule 1), but the compilers and the new
        // Publication record still need the tags explicitly to language-suffix
        // the filename and tag the catalog entry, and (P2) a snapshot that
        // predates the `languages` key has nothing else left to say what it
        // rendered. Through the store's own accessor, deliberately:
        // `RepublishTool` resolves the prior the same way to drive translation
        // substitution, and the two must not answer "which publication is
        // prior" by different rules.
        let prior = try await publicationStore.publication(forSnapshotID: snapshotID)
        let priorVersion = prior?.version

        // The whole catalog, for the mint below: the version it produces has to
        // be free of every row, not just of the prior one. A second read of the
        // same file, which is nothing beside the compile that follows.
        let existing = try await publicationStore.load()

        // P1 (issue #25): the republish version is minted BEFORE compile and
        // stamped through the config — filename, artifact-internal stamp and
        // catalog row all agree, which is CompileOrchestrator's own stamp=row
        // invariant (its `effective.nextVersion = effectiveVersion`) arriving on
        // this path. Minted here, once: the append below must reuse this value.
        let newVersion = Self.uniqueRepublishVersion(
            base: priorVersion, existing: existing, mintSuffix: mintSuffix)

        // P2 (Task 6): the bodies this republish reproduces, and the identity
        // that names them.
        //
        // WHAT was rendered comes from the snapshot first — `languages`, which
        // every compile has written since P2 — and from the prior catalog row
        // when the snapshot predates that key. That fallback splits a JOINED
        // identity ("en+sr") back into its components itself, because
        // `LanguageSet` refuses a `+` in a tag: the identity names an edition,
        // never a tongue, and handing it over unsplit would refuse the
        // republish of the very document it describes. A row with no language
        // at all is the plain source edition — one body, no list.
        //
        // WHICH of those tags is the SOURCE body (rendered untranslated, never
        // gated, and spelled away in a single-body identity) is a separate
        // question, and `snap.config` cannot answer it: that config is the
        // FIRST BODY's language-FOLDED one, so for a translated edition its
        // `metadata.language` is that edition's own tag — reading it would call
        // the translation the source and republish the Spanish edition as the
        // English book under the Spanish name. The snapshot's own frozen
        // `config.json` is the unfolded article; it was extracted into `stage`
        // just above, so ask it there — and REFUSE when it is not there or will
        // not decode, in the same throwing shape the snapshot load and the
        // config validation above use. There is no honest fallback: guessing
        // with `snap.config` is precisely the wrong answer for every translated
        // edition, and a republish that quietly reproduces the wrong book is
        // worse than one that says it cannot.
        let stagedConfig: PublishConfig
        do {
            guard let loaded = try await PublishConfigStore(projectURL: stage).load()
            else {
                throw RepublishError.unreadableSnapshotConfig(
                    "This snapshot carries no config.json, so there is no record "
                    + "of which language the book itself is written in — and "
                    + "without that a republish cannot tell a translated edition "
                    + "from the source. Republish from a snapshot taken by this "
                    + "version of Maugham, or compile the edition afresh.")
            }
            stagedConfig = loaded
        } catch let error as RepublishError {
            throw error
        } catch {
            throw RepublishError.unreadableSnapshotConfig(
                "This snapshot's config.json could not be read (\(error)), so "
                + "there is no record of which language the book itself is "
                + "written in — and without that a republish cannot tell a "
                + "translated edition from the source.")
        }
        let sourceTag = stagedConfig.metadata.language
        let recordedTags = snap.languages
            ?? prior?.language.map { $0.split(separator: "+").map(String.init) }
        let set = try LanguageSet(
            language: nil, languages: recordedTags, sourceTag: sourceTag)
        // How this edition is NAMED, everywhere below — the mint key, the new
        // catalog row, the output filename — exactly as at the compile door.
        let language = set.identity
        // Task 5: an imprint is part of what a republish reproduces. The
        // snapshot's config already carries `imprint` (and the imprint's own
        // `template`), so the COMPILE needs nothing from here — but the mint
        // key and the new catalog row are identity, and identity is read off
        // the prior publication, exactly as `language` is.
        let imprint = prior?.imprint
        // Round 3: `republish` has no `allow_stale` parameter of its own — it
        // replays whichever gate mode the ORIGINAL compile used. `false` for
        // a strictly-gated edition and for any publication compiled before
        // this field existed (ADR 0015 additive default).
        let allowStale = prior?.allowStale ?? false

        // C1 (whole-branch review): the config every body is FOLDED from.
        //
        // It must be the UNFOLDED one — the compile door folds each body from
        // its resolved-but-unfolded config, and a republish that reproduces
        // the same publication has to fold from the same article. `snap.config`
        // is the FIRST BODY's already-folded config, and folding it again is
        // idempotent only for that body: a `["sr","en"]` record's second body
        // is the source (`tag == nil`), whose fold is a no-op, so it would
        // inherit the first body's Serbian title, `\MaughamLanguage{sr}` and
        // `tribute.sr.tex` — the English half of the book, rendered as Serbian
        // in everything but its words. (Every republish test wrote
        // `["en","sr"]`, where the first body's fold IS the identity, which is
        // why this survived a milestone.)
        //
        // The unfolded article is the staged `config.json` read just above,
        // resolved the way the door resolves it: the snapshot's own imprint
        // (carried on the folded config, which resolution set), the live
        // piece ids (as the door derives them — only an imprint's `sections`
        // ALLOWLIST is materialized against them, so the read is skipped
        // outright when the config defines no imprints), and this republish's
        // minted version threaded through `nextVersion` so every body's
        // `\MaughamVersion` and the filename agree with the catalog row.
        //
        // A staged config that cannot describe this snapshot's imprint falls
        // back to the frozen one for a single-body record — the shape every
        // republish had before this fix, and a correct base for one body —
        // and refuses for a multi-body one, where no correct base exists.
        //
        // NOTE the division of labour with `excludedSectionIDs` below: WHICH
        // pieces render is still decided by the FROZEN `snap.config` (an
        // imprint's frozen allowlist, complemented against the live tree —
        // P1's C1 ruling), while what each body is TITLED and which style
        // files it inputs come from `base`. The two cannot disagree about a
        // piece that actually renders: every rendered piece's `Section` value
        // comes from the same frozen `config.json` either way, and the only
        // entries on which they differ describe pieces this republish does not
        // render at all.
        let base = try Self.foldingBase(
            stagedConfig: stagedConfig, snapshotConfig: snap.config,
            set: set, liveSource: astSource, version: newVersion)

        // F1: reproduce the historical subset. The snapshot's config is already
        // language-effective (Task 7 Rule 1), so its `include` flags are exactly
        // those the original compile used — wrap the live source with the same
        // excluded set. An empty set is a pass-through (pre-F1 snapshots).
        // C1: for an imprint that named an allowlist, "the same excluded set"
        // is not the frozen exclusions — see `excludedSections`.
        //
        // P2: the set is carried rather than a pre-wrapped source, because the
        // wrap now happens once per BODY (inside `BodyPlan`) instead of once
        // per compile.
        let excludedSectionIDs = try Self.excludedSections(
            inSnapshot: snap.config, liveSource: astSource)

        let jobID = await jobManager.register(phase: .renderingBody)

        // P2 (issue #25): reserve the triple this republish mints at. The
        // `-r<suffix>` makes a collision with a SIBLING edition impossible, so
        // what this closes is the same republish arriving twice — a re-sent
        // MCP call, or a republish racing a compile that resolved to the same
        // triple. Reserved after `register` (nothing between it and the mint
        // above mutates anything) so the refusal terminates a job the way
        // every other republish failure does.
        let mintKey = PublishMintGate.Key(
            version: newVersion, language: language, format: format,
            imprint: imprint)
        guard await mintGate.reserve(mintKey) else {
            let langLabel = language ?? "source"
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: "Publication v\(newVersion) (\(langLabel), \(format.rawValue)) \(CompileOrchestrator.placeOf(imprint)) is already compiling; wait for it to finish.",
                contextLines: [
                    "Another compile of the (version, language, format) triple '\(newVersion)/\(langLabel)/\(format.rawValue)' \(CompileOrchestrator.placeOf(imprint)) is in flight in this app.",
                    "Poll it with compile_status, or republish once it finishes."
                ])
            await jobManager.fail(
                jobID: jobID, errors: [diag],
                logExcerpt: "mint_in_flight: \(newVersion)/\(langLabel)/\(format.rawValue)")
            return .failed(
                errors: [diag],
                logExcerpt: "mint_in_flight: \(newVersion)/\(langLabel)/\(format.rawValue)")
        }

        // As in `CompileOrchestrator.compile`: the reserved work lives in its
        // own method so the release has exactly two sites and covers the
        // throwing calls (the compilers, the stage→Exports move, the snapshot
        // re-save, the catalog append) as well as the returns.
        let progress = DurableProgress()
        do {
            let outcome = try await republishReserved(
                snap: snap, format: format, label: label, jobID: jobID,
                base: base, newVersion: newVersion,
                priorVersion: priorVersion, set: set,
                imprint: imprint,
                allowStale: allowStale,
                excludedSectionIDs: excludedSectionIDs, stage: stage,
                progress: progress)
            await mintGate.release(mintKey)
            return outcome
        } catch {
            await mintGate.release(mintKey)
            // RULING-52 + RULING-7 (M7-PB-005/006), the same conversion
            // `CompileOrchestrator.compile` makes: the failure says what it
            // did as well as what failed, and the job is terminal. Throws
            // BEFORE the reservation (snapshot load, config validation, the
            // stage extract, the frozen `config.json` read and the
            // `LanguageSet` it feeds) still propagate — nothing durable has
            // moved and no job exists yet for any of them.
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: String(describing: error),
                contextLines: progress.reportLines)
            await jobManager.fail(
                jobID: jobID, errors: [diag],
                logExcerpt: "thrown_after_start: \(error)")
            return .failed(errors: [diag],
                           logExcerpt: "thrown_after_start: \(error)")
        }
    }

    /// The compiling half of `republish`, run while its minted triple is
    /// reserved on the mint gate. Split out for the release discipline only —
    /// see the call site. `stage` is still owned (and cleaned up) by
    /// `republish`.
    private func republishReserved(
        snap: PublicationSnapshot,
        format: PublishConfig.Format,
        label: String?,
        jobID: String,
        base: PublishConfig,
        newVersion: String,
        priorVersion: String?,
        set: LanguageSet,
        imprint: String?,
        allowStale: Bool,
        excludedSectionIDs: Set<String>,
        stage: URL,
        progress: DurableProgress
    ) async throws -> Outcome {
        // Task 9 F1: the snapshot freezes config/templates only — `astSource`
        // still reads the LIVE ProjectStore for manuscript/translation content
        // (see `pieceRef(for:)` in ProjectStoreASTSource), so a translated
        // edition (`prior.language != nil`) can drift stale between the
        // gated `compile` and a later `republish`. Re-run the same coverage
        // check here and hand the report to `TranslationCoverage.applyGate`
        // in whichever mode `prior.allowStale` pins (round 3) — the SAME
        // helper `CompileOrchestrator.compile` uses (round 5: this used to
        // be reimplemented inline here, and had silently dropped
        // `fountainDriftWarnings` as a result).
        var gateWarnings: [TectonicLogParser.Diagnostic] = []
        if let source = astSource as? ProjectStoreASTSource {
            switch try await TranslationCoverage.gateEveryTongue(
                projectStore: source.projectStore, tags: set.translatedTags,
                excludedSectionIDs: excludedSectionIDs, allowStale: allowStale
            ) {
            case .blocked(let errors, let logExcerpt):
                await jobManager.fail(jobID: jobID, errors: errors, logExcerpt: logExcerpt)
                return .failed(errors: errors, logExcerpt: logExcerpt)
            case .passed(let warnings):
                gateWarnings += warnings
            }
        }

        // P2: one body per language the record named, each bound to its own
        // text and folded to its own config — the same plan the compile door
        // builds, from the same UNFOLDED article (`base`, carrying this
        // republish's minted version — see `foldingBase`) and against the
        // STAGE's publish directory, because that is the tree the compilers
        // below read and therefore the one whose language-suffixed style files
        // count.
        //
        // A source that cannot bind to a language throws; `republish`'s own
        // catch converts it into the terminal `.failed` every republish throw
        // takes, with nothing durable moved. Production's source is
        // `ProjectStoreASTSource`, which always can.
        let plan = try await BodyPlan.make(
            set: set, resolved: base, source: astSource,
            publishDir: stage.appendingPathComponent(
                ".maugham/publish", isDirectory: true),
            wrap: { IncludeFilteredASTSource(
                base: $0, excludedSectionIDs: excludedSectionIDs) })

        let outputPath: String
        let warnings: [TectonicLogParser.Diagnostic]
        let errors: [TectonicLogParser.Diagnostic]
        let logExcerpt: String

        switch format {
        case .pdf:
            let pdf = try PDFCompiler(
                projectURL: stage, bodies: plan.bodies,
                config: plan.first.config, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID,
                language: set.singleTag,
                identity: set.identity)
            let r = try await pdf.compile(label: label)
            outputPath = r.outputPath
            warnings = r.warnings
            errors = r.errors
            logExcerpt = r.logExcerpt
        case .epub:
            let e = try EPUBCompiler(
                projectURL: stage, bodies: plan.bodies,
                config: plan.first.config, jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion, jobID: jobID,
                language: set.singleTag,
                identity: set.identity)
            let r = try await e.compile(label: label)
            outputPath = r.outputPath
            warnings = r.warnings
            errors = r.errors
            logExcerpt = ""
        }

        if !errors.isEmpty || outputPath.isEmpty {
            await jobManager.fail(jobID: jobID, errors: errors, logExcerpt: logExcerpt)
            return .failed(errors: errors, logExcerpt: logExcerpt)
        }

        // RULING-22 (M7-PB-009), the same exit `CompileOrchestrator` takes:
        // the compiled artifact so far exists only in the stage, which the
        // caller's `defer` removes — so honouring the cancel here costs
        // nothing durable and keeps a cancelled republish from publishing.
        if await jobManager.isCancelled(jobID: jobID) {
            return .cancelled
        }

        // Move output from stage to real project's Exports/.
        let stageOutputURL = URL(fileURLWithPath: outputPath)
        let exports = projectURL.appendingPathComponent(
            snap.config.outputs.directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: exports, withIntermediateDirectories: true)
        let dest = exports.appendingPathComponent(stageOutputURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            // The minted version is unique against the catalog, so nothing this
            // republish knows about should be here — which is exactly why the
            // answer is to stop rather than to delete. Whatever those bytes are
            // (an orphan from a crash, a writer's own copy, a file the catalog
            // has lost track of), they are not this job's to destroy: deleting
            // them was the same silent loss the `-r` version exists to prevent,
            // arriving through the one door it does not cover.
            let rel = relativePath(dest.path, from: projectURL)
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: "A file already exists at \(rel); refusing to overwrite it.",
                contextLines: [
                    "The republished edition v\(newVersion) renders to that path, but something is already there and this republish did not put it there.",
                    "Move or delete that file yourself if it is expendable, then republish again."
                ])
            await jobManager.fail(
                jobID: jobID, errors: [diag],
                logExcerpt: "output_path_occupied: \(rel)")
            return .failed(errors: [diag], logExcerpt: "output_path_occupied: \(rel)")
        }
        try FileManager.default.moveItem(at: stageOutputURL, to: dest)
        progress.record("the republished output, at \(relativePath(dest.path, from: projectURL))")

        // Re-persist snapshot (idempotent — the file already exists).
        try snapshotStore.save(snap)

        // Append a Publication referencing the source snapshot.
        let pub = Publication(
            publicationID: "pub-" + String(UUID().uuidString.lowercased().prefix(12)),
            version: newVersion,
            label: label,
            format: format,
            outputPath: relativePath(dest.path, from: projectURL),
            snapshotID: snap.snapshotID,
            checkpointID: "",
            republishedFrom: priorVersion,
            compiledAt: Date(),
            maughamVersion: maughamVersion,
            tectonicVersion: tectonicVersion,
            language: set.identity,
            allowStale: allowStale,
            imprint: imprint)
        try await publicationStore.append(pub)
        progress.record("the catalog row: v\(newVersion) \(format.rawValue) (\(pub.publicationID))")

        // The Exports pane refreshes on this event, and a republish lands a
        // publication the same as a compile does — same post, same scope
        // (RULING-8, M7-PB-011; before this the pane answered "does this
        // edition exist?" differently from the catalog until something else
        // triggered a rescan).
        MaughamEvent.post(
            .maughamPublicationCompleted,
            to: .project(for: projectURL),
            object: pub.publicationID)

        // Gate warnings (allow-stale fallbacks) ride alongside the
        // compiler's own warnings on the success path, matching
        // `CompileOrchestrator.compile`.
        let allWarnings = gateWarnings + warnings
        await jobManager.complete(jobID: jobID, outputPath: dest.path,
                                  warnings: allWarnings, errors: errors)
        return .completed(pub, warnings: allWarnings)
    }

    // MARK: - What every body is folded from

    /// The UNFOLDED config a republish folds each of its bodies from — the
    /// republish-side twin of the compile door's version-threaded `resolved`
    /// config, and the ONE place that value is built.
    ///
    /// C1 (whole-branch review): `snapshotConfig` cannot serve, because it is
    /// the first body's already-FOLDED config. Refolding it is idempotent for
    /// that body alone; every other body inherits its metadata and its
    /// language-suffixed style files, and the source body (`tag == nil`,
    /// whose fold is a no-op) inherits them wholesale. The staged
    /// `config.json` is the unfolded article, and it is already read — and
    /// already refused when missing — for `sourceTag`.
    ///
    /// Resolved exactly as `CompileOrchestrator.compile` resolves it:
    ///   * the imprint is the snapshot's own, read off the folded config
    ///     because resolution is what set it there;
    ///   * `pieceIDs` are the LIVE tree's, and read only when the config
    ///     defines imprints at all — they exist solely to materialize an
    ///     imprint's `sections` allowlist, which is the door's own rule for
    ///     when to pay for the derivation;
    ///   * `nextVersion` is this republish's minted version, so every body's
    ///     `\MaughamVersion` and the output filename agree with the catalog
    ///     row (P1, issue #25).
    ///
    /// **When the staged config cannot describe this snapshot's imprint** —
    /// it names one the frozen `config.json` does not define, or a merge-patch
    /// fragment that no longer decodes — the answer depends on how many bodies
    /// the record has, because that is what decides whether the frozen folded
    /// config is a correct base:
    ///   * ONE body: `snapshotConfig` IS a correct base. Its fold is the
    ///     identity for the source body and idempotent for a single
    ///     translated one (the same override re-applied to the same tag; a
    ///     style file already resolved to `x.sr.tex` finds no `x.sr.sr.tex`).
    ///     Fall back to it, which is exactly what every republish did before
    ///     this fix — a shape that predates the fix keeps working.
    ///   * TWO OR MORE: there is no correct base to fall back TO. `snapshot
    ///     Config` is precisely the wrong answer for every body after the
    ///     first, which is the defect this function exists to close, so refuse
    ///     in the same words an unreadable `config.json` is refused in.
    ///
    /// - Throws: `RepublishError.unreadableSnapshotConfig` for that
    ///   multi-body case.
    static func foldingBase(
        stagedConfig: PublishConfig,
        snapshotConfig: PublishConfig,
        set: LanguageSet,
        liveSource: ProjectASTBuilder.Source,
        version: String
    ) throws -> PublishConfig {
        var base: PublishConfig
        do {
            let pieceIDs = stagedConfig.imprints.isEmpty
                ? []
                : try liveSource.orderedPieces().map(\.pieceID)
            base = try stagedConfig.resolved(
                imprint: snapshotConfig.imprint, pieceIDs: pieceIDs)
        } catch {
            guard set.bodies.count == 1 else {
                throw RepublishError.unreadableSnapshotConfig(
                    "This snapshot's config.json could not be resolved "
                    + "(\(error.localizedDescription)), so there is no record "
                    + "of what each half of this \(set.bodies.count)-language "
                    + "edition was titled or which style files it used. "
                    + "Republish from a snapshot taken by this version of "
                    + "Maugham, or compile the edition afresh.")
            }
            base = snapshotConfig
        }
        base.nextVersion = version
        return base
    }

    // MARK: - What a republish leaves out

    /// The piece ids this republish must not render.
    ///
    /// The book's `sections` map is a DENYLIST — a piece with no entry is
    /// included — so reproducing the frozen `include: false` ids against the
    /// live tree is exactly right for it: a chapter written since the compile
    /// joins a republished book the same way it joins a fresh one.
    ///
    /// C1 (whole-branch review): an imprint that named a `sections` ALLOWLIST
    /// is the opposite, and reproducing its frozen exclusions silently widens
    /// the edition. Resolution MATERIALIZES the allowlist (`PublishConfig
    /// +Imprints.swift`), so the frozen config names only the pieces that
    /// existed when it compiled — a piece added afterwards is in neither the
    /// allowlist nor the materialized `include: false` set, and a denylist
    /// built from the latter lets it through. Complement the frozen allowlist
    /// against the LIVE tree instead: what the imprint renders stays exactly
    /// what it named. (A piece the allowlist named that has since been deleted
    /// simply is not in the live tree, so it renders in neither set — correct:
    /// the piece is gone.)
    ///
    /// An imprint that named no `sections` of its own INHERITS the book's map
    /// and is therefore a denylist too — which is why this asks the frozen
    /// config's own imprint layer (still carried on a resolved config) rather
    /// than merely whether `imprint` is set.
    static func excludedSections(
        inSnapshot config: PublishConfig,
        liveSource: ProjectASTBuilder.Source
    ) throws -> Set<String> {
        guard let name = config.imprint,
              config.imprints[name]?.sections != nil else {
            return config.excludedSectionIDs
        }
        let named = Set(config.sections.filter { $0.value.include }.keys)
        return Set(try liveSource.orderedPieces().map(\.pieceID)).subtracting(named)
    }

    // MARK: - Minting the republish version

    static func randomSuffix() -> String {
        String(UUID().uuidString.prefix(4)).lowercased()
    }

    /// The version a republish of `base` mints, guaranteed absent from
    /// `existing`.
    ///
    /// The suffix is four hex characters, and every republish of one edition
    /// composes off the SAME `base` (the prior row is always the original), so
    /// the draws all come from one 65,536-value pool — at which scale a
    /// collision is luck running out, not an impossibility (tripwire 23's
    /// lesson, one type over: mint unique, never mint random). A collision
    /// would render the identical filename and put two catalog rows on one
    /// file, which is the whole failure this branch exists to close.
    static func uniqueRepublishVersion(
        base: String?,
        existing: [Publication],
        mintSuffix: () -> String = Republisher.randomSuffix
    ) -> String {
        let taken = Set(existing.map(\.version))
        func compose(_ suffix: String) -> String {
            base.map { "\($0)-r\(suffix)" } ?? "republish-\(suffix)"
        }
        var candidate = compose(mintSuffix())
        var redraws = 0
        while taken.contains(candidate) {
            redraws += 1
            // Past a few unlucky draws it is the POOL that is the problem, not
            // the luck: an edition republished thousands of times leaves the
            // 4-char space too dense to draw a free value from reliably. Widen
            // the tail rather than spin against a saturated pool.
            candidate = compose(
                redraws < 8 ? mintSuffix() : mintSuffix() + randomSuffix())
        }
        return candidate
    }

    private func relativePath(_ abs: String, from root: URL) -> String {
        let prefix = root.path + "/"
        if abs.hasPrefix(prefix) { return String(abs.dropFirst(prefix.count)) }
        return abs
    }
}
