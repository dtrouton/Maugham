import Foundation

// MARK: - Errors

public enum RepublishError: Error, LocalizedError {
    /// The snapshot's `PublishConfig` failed validation (e.g. traversal in
    /// `outputs.directory` or `filenameTemplate`). Fail loudly rather than
    /// writing output files outside the allowed roots (finding 1.5).
    case invalidSnapshotConfig(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshotConfig(let msg): return msg
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
        var effective = snap.config
        effective.nextVersion = newVersion

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
        // just above, so ask it there. A snapshot without one (nothing
        // production writes) falls back to `snap.config`.
        let stagedConfig = try? await PublishConfigStore(projectURL: stage).load()
        let sourceTag = stagedConfig?.metadata.language
            ?? snap.config.metadata.language
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
                effective: effective, newVersion: newVersion,
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
            // stage extract) still propagate — nothing durable has moved and
            // no job exists yet for the early ones.
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
        effective: PublishConfig,
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
        // builds, from the STAGED snapshot config (`effective`, carrying this
        // republish's minted version) and against the STAGE's publish
        // directory, because that is the tree the compilers below read and
        // therefore the one whose language-suffixed style files count.
        //
        // Re-folding an already-folded snapshot config is deliberate and
        // idempotent: `effectiveMetadata` re-applies the same frozen override
        // to the same tag, and a style file already resolved to `x.sr.tex`
        // finds no `x.sr.sr.tex` and keeps what it has. What the fold is
        // actually FOR here is the second body, whose metadata and style files
        // the snapshot never carried.
        //
        // A source that cannot bind to a language throws; `republish`'s own
        // catch converts it into the terminal `.failed` every republish throw
        // takes, with nothing durable moved. Production's source is
        // `ProjectStoreASTSource`, which always can.
        let plan = try await BodyPlan.make(
            set: set, resolved: effective, source: astSource,
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
