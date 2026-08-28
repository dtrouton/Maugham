import Foundation
import MaughamCore

/// RULING-52's ledger (M7-PB-005/006/007): what a compile or republish has
/// already durably changed, written down AS it lands so a failure after the
/// first mutation can say what it did as well as what failed. Deliberately
/// not tracking `build/` intermediates or the EMISSION.md refresh — both are
/// regenerable app-owned artifacts (M7-PB-004's filing); this ledger carries
/// only what the writer would need to know survived.
final class DurableProgress: @unchecked Sendable {
    private(set) var landed: [String] = []
    func record(_ what: String) { landed.append(what) }

    /// The RULING-52 sentence, as diagnostic context: what landed, and that
    /// everything else did not.
    var reportLines: [String] {
        guard !landed.isEmpty else {
            return ["Nothing durable had been written when this failed — the project is unchanged."]
        }
        return ["This failed partway. What already landed and SURVIVES:"]
            + landed.map { "  • \($0)" }
            + ["Everything not listed did not happen."]
    }
}

public struct CompileOrchestrator {

    public enum Outcome: Sendable {
        case completed(Publication, warnings: [TectonicLogParser.Diagnostic])
        case failed(errors: [TectonicLogParser.Diagnostic], logExcerpt: String)
        /// F2 `dry_run`: the coverage gate (and the version-collision guard)
        /// passed, but nothing was compiled, snapshotted, minted, or version-
        /// bumped. Carries the same gate warnings a real compile would ride out
        /// on its success path.
        case dryRunPassed(warnings: [TectonicLogParser.Diagnostic])
        /// RULING-22 (M7-PB-009): the writer cancelled while the compile was
        /// rendering, and the cancel WON — nothing durable was committed. The
        /// job record stays `.cancelled` (the terminal guard in
        /// `CompileJobManager` keeps a late finish from overwriting it).
        case cancelled
    }

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let configStore: PublishConfigStore
    public let publicationStore: PublicationStore
    public let snapshotStore: PublicationSnapshotStore
    public let jobManager: CompileJobManager
    /// P2 (issue #25): the per-project gate that keeps two same-process
    /// compiles of one (version, language, format) triple from both passing
    /// the catalog guard and both minting. Defaulted so the many test call
    /// sites each get their own isolated gate; production passes
    /// `PublishingStores.mintGate` so every compile of a project contends on
    /// the same one (censused by `PublishMintGateTests`).
    public let mintGate: PublishMintGate
    /// **How a caller's typo is told from a compile that went wrong.**
    ///
    /// An unknown imprint refuses at the door — before a job registers, before
    /// a word of the manuscript is read — and it refuses through the ordinary
    /// `.failed` shape, because that is the shape every caller already reads.
    /// The excerpt is what carries the distinction, and a surface that wants to
    /// draw the two differently (`DepartmentCompileState.settled(after:)` draws
    /// this one as a refusal rather than a failure) reads THIS constant rather
    /// than re-typing the prefix. `CompileToolsTests` pins the wire spelling
    /// `"unknown_imprint: nope"`, so the prefix is part of the tool's contract
    /// and not free to drift.
    public static let unknownImprintLogExcerpt = "unknown_imprint: "

    public let maughamVersion: String
    public let tectonicVersion: String

    public init(
        projectURL: URL,
        astSource: ProjectASTBuilder.Source,
        configStore: PublishConfigStore,
        publicationStore: PublicationStore,
        snapshotStore: PublicationSnapshotStore,
        jobManager: CompileJobManager,
        mintGate: PublishMintGate = PublishMintGate(),
        maughamVersion: String,
        tectonicVersion: String
    ) {
        self.projectURL = projectURL
        self.astSource = astSource
        self.configStore = configStore
        self.publicationStore = publicationStore
        self.snapshotStore = snapshotStore
        self.jobManager = jobManager
        self.mintGate = mintGate
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
    }

    public func compile(
        format: PublishConfig.Format,
        label: String?,
        language: String? = nil,
        languages: [String]? = nil,
        allowStale: Bool = false,
        dryRun: Bool = false,
        version: String? = nil,
        imprint: String? = nil,
        onJobRegistered: @Sendable (String) -> Void = { _ in }
    ) async throws -> Outcome {
        // Imprint resolution runs at the DOOR, and it is the only
        // imprint-awareness in the pipeline: everything below reads an
        // ordinary `PublishConfig` and never learns an imprint existed
        // (spec §3).
        let publishDir = projectURL.appendingPathComponent(
            ".maugham/publish", isDirectory: true)

        guard let loaded = try await configStore.load() else {
            let jobID = await jobManager.register(phase: .renderingBody)
            await jobManager.fail(jobID: jobID, errors: [], logExcerpt: "no config")
            return .failed(errors: [], logExcerpt: "no config")
        }

        // Is this a name this project knows? Asked BEFORE the job is
        // registered and before a word of the manuscript is read, because it
        // needs neither: an unknown name is a caller's typo rather than a
        // compile, nothing started, and `compile_status` must not grow a job
        // for a compile that never began. (Every refusal below this point got
        // as far as reading the project, and each of those registers-then-
        // fails.) It reads the same dictionary `resolved(imprint:pieceIDs:)`
        // reads and raises the same error type, so there is one answer to the
        // question rather than two.
        if let imprint, loaded.imprints[imprint] == nil {
            let error = PublishConfig.UnknownImprint(
                requested: imprint, known: Array(loaded.imprints.keys))
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: error.errorDescription ?? "unknown imprint '\(imprint)'",
                contextLines: [
                    "Nothing was compiled — no export, no snapshot, no version bump."
                ])
            return .failed(errors: [diag],
                           logExcerpt: Self.unknownImprintLogExcerpt + imprint)
        }

        // `loaded` is kept beside `config` on purpose: the RESOLVED config is
        // what this compile renders and mints under, but the version bump at
        // the far end writes the ORIGINAL back — an imprint's counter lives
        // inside its own entry, and saving the resolved config would flatten
        // the imprint's overrides onto the book.
        let config: PublishConfig
        let pieceIDs: [String]
        do {
            // The piece ids an imprint's `sections` allowlist is materialized
            // against (Task 2), and the same list the validator holds that
            // allowlist to. Read only when it can change an answer: with no
            // imprints in the config there is no allowlist to materialize and
            // no allowlist id to check, and reading it anyway would derive
            // every manuscript a second time on every ordinary compile — the
            // emitters below do it once already.
            pieceIDs = loaded.imprints.isEmpty
                ? []
                : try astSource.orderedPieces().map(\.pieceID)
            config = try loaded.resolved(imprint: imprint, pieceIDs: pieceIDs)
        } catch {
            // RULING-54 for the read (an unreadable op log refuses the compile
            // rather than publishing a book missing a chapter), and
            // `ImprintResolutionFailure` for a merge-patch fragment that
            // leaves a block undecodable. Both end the same way the AST
            // build's own throw does — a terminal job and a `.failed`
            // outcome — rather than escaping with the job stranded
            // .inProgress (RULING-52's shape).
            // The SENTENCE, not a struct dump: both errors this can carry are
            // `LocalizedError`s written to be read, and the unreadable-catalog
            // refusal below already reports itself this way. The excerpt keeps
            // the raw value — that half is diagnostic vocabulary, not prose.
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: error.localizedDescription,
                contextLines: [
                    "Nothing was compiled — no export, no snapshot, no version bump."
                ])
            // This one registers a job and fails it, where the language
            // refusal just below returns without one: BOTH shapes are the door's
            // existing rule, not an inconsistency. Getting here means the
            // project was READ — the op log, the manifest, the imprint's
            // merge-patch — so a compile did begin and `compile_status` must be
            // able to say how it ended. The register call moved down to make
            // room for the language check; registering it here keeps this path's
            // behaviour exactly what it was before that move.
            let jobID = await jobManager.register(phase: .renderingBody)
            await jobManager.fail(
                jobID: jobID, errors: [diag],
                logExcerpt: "thrown_before_start: \(error)")
            return .failed(
                errors: [diag], logExcerpt: "thrown_before_start: \(error)")
        }

        // The languages this compile renders, in order — one complete body
        // each, all of them inside ONE publication (P2). `LanguageSet` is the
        // single reconciliation of the legacy `language`, the new `languages`
        // list and the "source" sentinel; the `sourceTag` is the RESOLVED
        // config's, because an imprint may spell the book's own language
        // differently from the book.
        //
        // The two things a set answers are NOT interchangeable, and everything
        // below reads one or the other:
        //   • `set.identity` — "en+sr", nil for a plain source compile — is the
        //     edition's NAME: the collision guard, the mint key, the catalog
        //     row, and the version branches' refusals.
        //   • `set.singleTag` — the sole translated tag, nil the moment there
        //     is more than one body — is what the compilers resolve
        //     `template.<tag>.tex` and `styles.<tag>.css` against. A bilingual
        //     document belongs to no single tongue's template, so it takes the
        //     base ones.
        //
        // A combination that cannot resolve is a caller's typo, refused the way
        // an unknown imprint is: before the job registers, because nothing
        // started and `compile_status` must not grow a job for a compile that
        // never began.
        let set: LanguageSet
        do {
            set = try LanguageSet(language: language, languages: languages,
                                  sourceTag: config.metadata.language)
        } catch {
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: error.localizedDescription,
                contextLines: [
                    "Nothing was compiled — no export, no snapshot, no version bump."
                ])
            return .failed(
                errors: [diag],
                logExcerpt: "invalid_languages: \(error.localizedDescription)")
        }

        let jobID = await jobManager.register(phase: .renderingBody)
        // **Whose compile this is.** One `CompileJobManager` serves the whole
        // project — this orchestrator, `PreviewCompiler`, and the designer's
        // sample compiles all register on it — so "the job in flight" is not a
        // question the manager can answer for any particular caller. A caller
        // that means to cancel its OWN compile has to be told which job that
        // is, and this is the only moment anyone can be told: `compile` does
        // not return until the compile is over. `DeskCompileRunner` is why it
        // exists (its Cancel used to take `allInProgress().last`, which is
        // whichever job registered most recently — Claude's preview, as often
        // as the writer's own book).
        onJobRegistered(jobID)

        // Compile pre-flight validation, on the resolved config. This is the
        // stricter door (`validateForCompile`): a config WRITE deliberately
        // does not check that the default `template.tex` is on disk, because a
        // project whose starter install failed silently must still be able to
        // patch its config — but a compile through a template that isn't there
        // must refuse in Maugham's own words rather than as a tectonic error.
        // `resolvedImprint` is the request's own name, not the config's: the
        // door judges the RESOLVED config, so `config.imprint` is legitimate
        // exactly when it is what resolution just set (I3). A book compile
        // over a hand-edited config claiming an imprint is refused here.
        let configErrors = PublishConfigValidator.validateForCompile(
            config, publishDir: publishDir, pieceIDs: pieceIDs, format: format,
            resolvedImprint: imprint)
        if !configErrors.isEmpty {
            let diags = configErrors.map {
                TectonicLogParser.Diagnostic(
                    level: .error, file: nil, line: nil,
                    message: "\($0.field): \($0.message)",
                    contextLines: [
                        "Nothing was compiled — no export, no snapshot, no version bump."
                    ])
            }
            let excerpt = "invalid_config: "
                + configErrors.map(\.field).joined(separator: ", ")
            await jobManager.fail(jobID: jobID, errors: diags, logExcerpt: excerpt)
            return .failed(errors: diags, logExcerpt: excerpt)
        }

        // F1: the pieces this compile leaves out. Read off the RESOLVED config
        // rather than a language-folded one: the two folds `BodyPlan` performs
        // (`effectiveMetadata`, then `LanguageSuffixedFile.resolvingStyleFiles`)
        // rewrite metadata and per-piece style names and touch `sections` in
        // neither, so every body excludes the same pieces and a language
        // edition still cannot diverge the subset. The same set wraps every
        // body's source below; an empty one is a pass-through.
        let excludedSectionIDs = config.excludedSectionIDs

        // Edition identity (spec 2026-07-23): a Publication is keyed on the
        // triple (version, language, format). Resolve the version THIS compile
        // mints at BEFORE the collision guard runs.
        //   • source (`set.isSourceCompile`): version comes from next_version;
        //     a caller-supplied `version` is meaningless here and refused loudly.
        //   • edition (no source body): an edition is a rendering OF a source
        //     version — it never mints its own. With `version` it pins that
        //     exact source version, which must already have a source
        //     publication. Without `version` it targets the latest source
        //     publication's version (most recent `compiledAt`); when no source
        //     publication exists at all it refuses loudly ("compile the source
        //     edition first").
        let existingPublications: [Publication]
        do { existingPublications = try await publicationStore.load() }
        catch {
            // RULING-54: an unreadable catalog file refuses the compile
            // PRE-FLIGHT — this list is exactly what the occupied-destination
            // refusal and the version mint read, so compiling over a silently
            // shorter catalog could overwrite or collide with an edition the
            // writer already shipped. Same shape as the no-config refusal
            // above: a terminal job and a `.failed` outcome, nothing landed.
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: error.localizedDescription,
                contextLines: ["Nothing was compiled — no export, no snapshot, no version bump."])
            await jobManager.fail(jobID: jobID, errors: [diag],
                                  logExcerpt: "publications catalog unreadable")
            return .failed(errors: [diag], logExcerpt: "publications catalog unreadable")
        }

        // What counts as a SOURCE publication for the branches below is
        // `Publication.isSourceEdition(sourceTag:)`, never `language == nil`: a
        // bilingual compile writes the identity "en+sr", and that document
        // contains the source book as surely as a nil-language record does, so
        // a later edition may pin its version and a version-less edition may
        // resolve to it. Two translations joined ("sr+fr") are not a source
        // edition. The tag asked about is `set.sourceTag` — the resolved
        // config's own `metadata.language`, which is exactly what this compile's
        // `LanguageSet` was built with, so the two cannot disagree.
        //
        // How this edition is NAMED, everywhere below: the joined identity for
        // a multi-body compile, the sole tag for one translated body, nil for
        // the source. `langLabel` is its spelling in a sentence.
        let identity = set.identity
        let langLabel = identity ?? "source"

        let effectiveVersion: String
        if set.isSourceCompile {
            if let version {
                let diag = TectonicLogParser.Diagnostic(
                    level: .error, file: nil, line: nil,
                    message: "version '\(version)' requires a language — source versions come from next_version, not a pinned version.",
                    contextLines: [
                        "Omit `version` to compile the source edition at next_version ('\(config.nextVersion)').",
                        "Or pass `language` to render an edition of an existing source version."
                    ])
                await jobManager.fail(
                    jobID: jobID, errors: [diag],
                    logExcerpt: "version_without_language: \(version)")
                return .failed(
                    errors: [diag],
                    logExcerpt: "version_without_language: \(version)")
            }
            effectiveVersion = config.nextVersion
        } else if let version {
            // Original source records only (`republishedFrom == nil`): a
            // republished source record carries a mangled `-r…` version, and
            // letting a pin validate against one would mint the edition at
            // that mangled version — the same family fragmentation the
            // latest-source branch below guards against (T1 review). Pin the
            // ORIGINAL version; the edition compiles the CURRENT manuscript
            // either way (republish is the snapshot-reproduction path).
            // Scoped by imprint (Task 6): an imprint's publications are its
            // own, so a version the BOOK holds is not an imprint's to render
            // and vice versa. Without this, an imprint edition would pin — and
            // mint at — a version belonging to another edition line entirely.
            guard existingPublications.contains(where: {
                $0.isSourceEdition(sourceTag: set.sourceTag)
                    && $0.republishedFrom == nil
                    && $0.version == version && $0.imprint == imprint
            }) else {
                // T1 re-review: when the pinned version exists ONLY as a
                // republished record, "no publication exists at vX" would be
                // literally false — explain the republish-exclusion and name
                // the original, pinnable version instead.
                let existenceLine: String
                if let repub = existingPublications.first(where: {
                    $0.isSourceEdition(sourceTag: set.sourceTag)
                        && $0.republishedFrom != nil
                        && $0.version == version && $0.imprint == imprint
                }), let original = repub.republishedFrom {
                    existenceLine = "v\(version) is a republished record (republished_from: \(original)) — republished versions aren't pinnable as edition sources; pin the original v\(original), or use republish to reproduce the snapshot."
                } else if let elsewhere = existingPublications.first(where: {
                    $0.isSourceEdition(sourceTag: set.sourceTag)
                        && $0.republishedFrom == nil
                        && $0.version == version && $0.imprint != imprint
                }) {
                    // The version EXISTS — under another edition line. Saying
                    // "no publication exists at v1.0" to a writer looking at
                    // one in list_publications would be literally false, so
                    // name where it actually lives.
                    existenceLine = "version '\(version)' exists \(Self.placeOf(elsewhere.imprint)), not \(Self.notPlaceOf(imprint)) — an edition renders a source version of its own imprint."
                } else {
                    existenceLine = "No source publication — one whose edition includes '\(set.sourceTag)' — exists at v\(version)."
                }
                let diag = TectonicLogParser.Diagnostic(
                    level: .error, file: nil, line: nil,
                    message: "no source v\(version) to render in \(langLabel) — compile the source edition first, then render its edition.",
                    contextLines: [
                        "A language edition pins an EXISTING source publication's version.",
                        existenceLine
                    ])
                await jobManager.fail(
                    jobID: jobID, errors: [diag],
                    logExcerpt: "no_source_version: \(version)/\(langLabel)")
                return .failed(
                    errors: [diag],
                    logExcerpt: "no_source_version: \(version)/\(langLabel)")
            }
            effectiveVersion = version
        } else {
            // Latest ORIGINAL source publication by compiledAt. Republished
            // source records (`republishedFrom != nil`) are excluded: they carry a mangled `-r…` version, and if one were
            // the most recent, resolving to it would mint the edition at that
            // mangled version, fragmenting the (version, language, format)
            // family (T1 review).
            // Scoped by imprint for the same reason the pin above is: the
            // latest source of THIS edition line, never whatever happens to be
            // the newest row in the catalog.
            let sources = existingPublications.filter {
                $0.isSourceEdition(sourceTag: set.sourceTag)
                    && $0.republishedFrom == nil
                    && $0.imprint == imprint
            }
            guard let latest = sources.max(by: { $0.compiledAt < $1.compiledAt }) else {
                let diag = TectonicLogParser.Diagnostic(
                    level: .error, file: nil, line: nil,
                    message: "no source publication exists\(imprint.map { " under imprint '\($0)'" } ?? "") — compile the source edition first (or pass version to pin one) before rendering the \(langLabel) edition.",
                    contextLines: [
                        "An edition is a rendering of a source version; it no longer mints its own.",
                        imprint.map {
                            "Compile without a language under imprint '\($0)' to create its source edition, then retry."
                        } ?? "Compile without a language to create the source edition, then retry."
                    ])
                await jobManager.fail(
                    jobID: jobID, errors: [diag],
                    logExcerpt: "no_source_publication: \(langLabel)")
                return .failed(
                    errors: [diag],
                    logExcerpt: "no_source_publication: \(langLabel)")
            }
            effectiveVersion = latest.version
        }

        // C1: thread the resolved version into the EFFECTIVE config so it
        // reaches the compiled OUTPUT — the filename `{version}` token
        // (OutputFilenameBuilder), the PDF interior `\MaughamVersion`, and the
        // EPUB `<dc:...>`/metadata all render `config.nextVersion`, which for an
        // edition still holds the (possibly-bumped) source next_version, not the
        // version this edition targets. No-op for source compiles (equal by
        // construction: `effectiveVersion == config.nextVersion`). Runs BEFORE
        // snapshot capture so a republished edition reproduces the frozen
        // version — and its filename — exactly.
        var versioned = config
        versioned.nextVersion = effectiveVersion

        // One body per language, each bound to its own text and folded to its
        // own config — the two folds this function used to perform inline now
        // happen once per body, so a second body cannot inherit the first's
        // metadata or its per-piece style files. Built from the VERSION-THREADED
        // config (above) rather than the raw resolved one, because every body's
        // interior renders `nextVersion`: `PDFCompiler` writes
        // `build/metadata.<tag>.tex` — and `build/metadata.tex` itself — from
        // the bodies' own configs.
        //
        // A source that cannot bind to a language is refused HERE and not at
        // the door: `languages: ["en","sr"]` is a well-formed request, and
        // whether this project's manuscript source can answer for two tongues
        // is a property of the project, discovered on the way to compiling it.
        // So it registers-then-fails like every other refusal past the door.
        let plan: BodyPlan
        do {
            plan = try await BodyPlan.make(
                set: set, resolved: versioned, source: astSource,
                publishDir: publishDir,
                wrap: { IncludeFilteredASTSource(
                    base: $0, excludedSectionIDs: excludedSectionIDs) })
        } catch {
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: error.localizedDescription,
                contextLines: [
                    "Nothing was compiled — no export, no snapshot, no version bump."
                ])
            await jobManager.fail(
                jobID: jobID, errors: [diag],
                logExcerpt: "not_rebindable: \(error.localizedDescription)")
            return .failed(
                errors: [diag],
                logExcerpt: "not_rebindable: \(error.localizedDescription)")
        }

        // The edition-effective config: the FIRST body's. Everything that
        // describes the publication as a whole — the snapshot, the compilers'
        // document-level metadata, the filename, the catalog row — reads it, so
        // a bilingual book is titled in its source language and each body
        // retitles only inside its own half. The snapshot freezes it for
        // `Republisher` (which reads snap.config); it does NOT freeze
        // manuscript/translation content — `astSource` still reads the live
        // ProjectStore on republish, so a translated edition is re-gated
        // separately in `Republisher.republish` (Task 9 F1), not here.
        // The post-compile version bump below saves `loaded` — the config as it
        // came off disk — never `effective` and never the imprint-resolved
        // `config`, so neither a translated nor an imprint compile can
        // overwrite the shared config.
        let effective = plan.first.config

        // Pre-compile collision guard: refuse only an exact (version, language,
        // format) match. For source compiles this is strictly weaker than the
        // old version-only guard (format joins the key), permitting a
        // deliberately completed edition family at a manually-set version.
        // Republished records share a version deliberately but always carry a
        // distinct `-r…` version string, so they never match this triple
        // (republish path untouched).
        // Scoped by imprint (Task 6): the book and an imprint may each hold
        // a v0.1 pdf, because those are two different publications.
        if existingPublications.contains(where: {
            $0.version == effectiveVersion
                && $0.language == identity
                && $0.format == format
                && $0.imprint == imprint
        }) {
            let diag = TectonicLogParser.Diagnostic(
                level: .error,
                file: nil, line: nil,
                message: "Publication v\(effectiveVersion) (\(langLabel), \(format.rawValue)) already exists \(Self.placeOf(imprint)); refusing to compile a colliding edition.",
                contextLines: [
                    "The (version, language, format) triple '\(effectiveVersion)/\(langLabel)/\(format.rawValue)' matches an existing Publication \(Self.placeOf(imprint)).",
                    set.isSourceCompile
                        ? "Bump next_version via set_publish_config, or compile a different format/language to complete the family."
                        : "This edition already exists; compile a different format, or a new source version.",
                    "Or use republish if you want a new compile from a prior snapshot."
                ])
            await jobManager.fail(
                jobID: jobID,
                errors: [diag],
                logExcerpt: "version_collision: \(effectiveVersion)/\(langLabel)/\(format.rawValue)")
            return .failed(
                errors: [diag],
                logExcerpt: "version_collision: \(effectiveVersion)/\(langLabel)/\(format.rawValue)")
        }

        // P2 (issue #25): the catalog guard above answers "does this edition
        // already exist"; this one answers "is one already in flight". Two
        // concurrent calls both read a catalog without the other's row, so
        // both pass the guard — the gate is what stops the second from
        // minting a duplicate (and, on the source path, from grabbing the
        // same `next_version`). Reserved AFTER the catalog guard so an
        // already-published edition still gets the "already exists" refusal,
        // which names the actual remedy.
        //
        // A dry run is EXEMPT (M1, whole-branch review): it answers "would this
        // compile?" and returns before the snapshot, the compilers and the
        // catalog append, so it mints nothing a concurrent compile could
        // duplicate. Refusing it — or letting it hold the triple against a real
        // compile — would be the gate charging a mutation's price for a
        // question. The release below is paired to this same condition: a dry
        // run that never reserved must never release, or it would hand back the
        // in-flight compile's reservation.
        let mintKey = PublishMintGate.Key(
            version: effectiveVersion, language: identity, format: format,
            imprint: imprint)
        if !dryRun {
            guard await mintGate.reserve(mintKey) else {
                let diag = TectonicLogParser.Diagnostic(
                    level: .error,
                    file: nil, line: nil,
                    message: "Publication v\(effectiveVersion) (\(langLabel), \(format.rawValue)) \(Self.placeOf(imprint)) is already compiling; wait for it to finish.",
                    contextLines: [
                        "Another compile of the (version, language, format) triple '\(effectiveVersion)/\(langLabel)/\(format.rawValue)' \(Self.placeOf(imprint)) is in flight in this app.",
                        "Poll it with compile_status, or compile a different format/language."
                    ])
                await jobManager.fail(
                    jobID: jobID,
                    errors: [diag],
                    logExcerpt: "mint_in_flight: \(effectiveVersion)/\(langLabel)/\(format.rawValue)")
                return .failed(
                    errors: [diag],
                    logExcerpt: "mint_in_flight: \(effectiveVersion)/\(langLabel)/\(format.rawValue)")
            }
        }

        // Everything past the reservation lives in `compileReserved` so the
        // release has exactly TWO sites — the two below. Inline, the release
        // would have to be repeated before each of the four remaining returns
        // AND could not cover the half-dozen `try` calls that throw straight
        // out of `compile` (snapshot capture/save, the compilers, the catalog
        // append, the config save); a reservation leaked on a thrown error is
        // permanent for the life of the process, which would be a worse
        // failure than the duplicate this gate exists to prevent.
        let progress = DurableProgress()
        do {
            let outcome = try await compileReserved(
                format: format, label: label, set: set, plan: plan,
                allowStale: allowStale, dryRun: dryRun, jobID: jobID,
                config: config, loaded: loaded, imprint: imprint,
                effective: effective,
                effectiveVersion: effectiveVersion,
                excludedSectionIDs: excludedSectionIDs,
                progress: progress)
            if !dryRun { await mintGate.release(mintKey) }
            return outcome
        } catch {
            if !dryRun { await mintGate.release(mintKey) }
            // RULING-52 + RULING-7 (M7-PB-005/006/007): a thrown error used to
            // escape as a raw internal_error with the job stranded
            // .inProgress forever — a dead compile reported as still
            // compiling, and nothing anywhere naming the export and snapshot
            // that had already landed. The failure now says what it did as
            // well as what failed, and the job is terminal.
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

    /// The compiling half of `compile`, run while its (version, language,
    /// format) triple is reserved on the mint gate. Split out for the release
    /// discipline only — see the call site.
    private func compileReserved(
        format: PublishConfig.Format,
        label: String?,
        set: LanguageSet,
        plan: BodyPlan,
        allowStale: Bool,
        dryRun: Bool,
        jobID: String,
        config: PublishConfig,
        loaded: PublishConfig,
        imprint: String?,
        effective: PublishConfig,
        effectiveVersion: String,
        excludedSectionIDs: Set<String>,
        progress: DurableProgress
    ) async throws -> Outcome {
        // F5: EMISSION.md is app-owned and generated — refresh the project's
        // copy on every compile (dry_run included: it still runs the
        // pipeline's front half, and there's no reason to let the doc drift
        // just because nothing got emitted) so it never misinforms an agent
        // reading it as instructed. Unconditional overwrite of that ONE file;
        // every other starter file (template.tex, preamble/partials,
        // config.json, style files) is untouched. Runs BEHIND the mint-gate
        // reservation — a refused compile touches nothing, and its
        // atomic-write temp must not appear beside a winner's snapshot
        // capture (CI run 31584930789 lost a winning compile reading the
        // loser's vanishing `EMISSION.md.sb-*`) — and BEFORE the snapshot
        // capture below, so a real compile's snapshot embeds the
        // freshly-stamped copy.
        try EmissionContract.renderProjectCopy(appVersion: maughamVersion)
            .write(to: projectURL.appendingPathComponent(
                       ".maugham/publish/EMISSION.md"),
                   atomically: true, encoding: .utf8)

        // Task 9: translation coverage gate. A translated edition
        // (`language != nil`) must not ship a book whose translation lags the
        // source. Reuse the astSource's own `ProjectStore` (the same one the
        // substitution path reads) to walk pieces, derive each, and hand the
        // report to `TranslationCoverage.applyGate` — the ONE place either
        // `compile` or `republish` decides block-vs-warn (Task 9 F1 round 5;
        // this used to be reimplemented in `Republisher.republish`, which let
        // the two drift apart).
        //
        // P2: once per TRANSLATED body, through `gateEveryTongue` — the ONE
        // loop this door, `PreviewCompiler` and `Republisher` share (Task 6),
        // for the same reason they already share `applyGate`. What it does
        // with a tag, a block and a passing tongue is documented there.
        //
        // `allow_stale` is the whole compile's, so it applies to EVERY tongue:
        // there is one book, and a writer who accepts source-text fallback for
        // one of its halves has accepted it for the other. A tongue with no
        // translation layer at all still refuses under it (the zero-layer
        // guard), which is why one blocked tongue can sink an allow_stale
        // compile that every other tongue passed.
        var gateWarnings: [TectonicLogParser.Diagnostic] = []
        if let source = astSource as? ProjectStoreASTSource {
            switch try await TranslationCoverage.gateEveryTongue(
                projectStore: source.projectStore, tags: set.translatedTags,
                excludedSectionIDs: excludedSectionIDs, allowStale: allowStale
            ) {
            case .blocked(let errors, let excerpt):
                await jobManager.fail(
                    jobID: jobID, errors: errors, logExcerpt: excerpt)
                return .failed(errors: errors, logExcerpt: excerpt)
            case .passed(let warnings):
                gateWarnings += warnings
            }
        }

        // F2 dry_run: short-circuit AFTER the version-collision guard and the
        // coverage gate (both of which report a would-be failure with the
        // standard `.failed` shape above) but BEFORE any mutation — no snapshot,
        // no compile, no Publication, no event, no version bump, no output file.
        // Returns the gate verdict (any allow_stale/fountain-drift warnings) so
        // the caller can see exactly what a real compile would emit. The job
        // terminates in the distinct `.dryRunPassed` state so a polled
        // `compile_status` (wait_seconds:0 race) reports the dry-run outcome,
        // not a completed job with an empty output path.
        if dryRun {
            await jobManager.completeDryRun(jobID: jobID, warnings: gateWarnings)
            return .dryRunPassed(warnings: gateWarnings)
        }

        // Capture snapshot BEFORE compile so it reflects the source state used.
        // Freeze the edition-effective config (see `effective` above).
        let snap = try snapshotStore.capture(
            config: effective, maughamVersion: maughamVersion,
            tectonicVersion: tectonicVersion,
            languages: set.bodies.map { $0 ?? set.sourceTag })

        let outputPath: String
        let warnings: [TectonicLogParser.Diagnostic]
        let errors: [TectonicLogParser.Diagnostic]
        let logExcerpt: String

        switch format {
        case .pdf:
            let pdf = try PDFCompiler(
                projectURL: projectURL, bodies: plan.bodies,
                config: effective, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID,
                language: set.singleTag,
                identity: set.identity)
            let result = try await pdf.compile(label: label)
            outputPath = result.outputPath
            warnings = result.warnings
            errors = result.errors
            logExcerpt = result.logExcerpt

        case .epub:
            let epub = try EPUBCompiler(
                projectURL: projectURL, bodies: plan.bodies,
                config: effective, jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion, jobID: jobID,
                language: set.singleTag,
                identity: set.identity)
            let result = try await epub.compile(label: label)
            outputPath = result.outputPath
            warnings = result.warnings
            errors = result.errors
            logExcerpt = ""
        }

        if !errors.isEmpty || outputPath.isEmpty {
            await jobManager.fail(jobID: jobID, errors: errors, logExcerpt: logExcerpt)
            return .failed(errors: errors, logExcerpt: logExcerpt)
        }

        // RULING-22 (M7-PB-009): the last exit before anything durable is
        // committed. A cancel that landed during rendering is honoured HERE —
        // no snapshot, no catalog row, no event, no version bump; the output
        // file the compiler already moved is below in `Exports/` only on the
        // PDF/EPUB success path, and stopping before the catalog append is
        // what keeps a cancelled compile from PUBLISHING. `isCancelled` had a
        // zero-caller census before this line — the token existed and nothing
        // polled it, so "cancelled" published anyway.
        if await jobManager.isCancelled(jobID: jobID) {
            try? FileManager.default.removeItem(atPath: outputPath)
            return .cancelled
        }
        progress.record("the compiled output, at \(relativePath(outputPath, from: projectURL))")

        // Persist snapshot.
        try snapshotStore.save(snap)
        progress.record("the publish snapshot \(snap.snapshotID) (under .maugham/publications/)")

        // Build Publication record.
        let pubIDSuffix = String(UUID().uuidString.lowercased().prefix(12))
        let pub = Publication(
            publicationID: "pub-\(pubIDSuffix)",
            version: effectiveVersion,
            label: label,
            format: format,
            outputPath: relativePath(outputPath, from: projectURL),
            snapshotID: snap.snapshotID,
            checkpointID: "",      // CheckpointStore integration is a follow-up
            republishedFrom: nil,
            compiledAt: Date(),
            maughamVersion: maughamVersion,
            tectonicVersion: tectonicVersion,
            language: set.identity,
            allowStale: allowStale,
            imprint: imprint)
        // TODO: transactional commit. If `configStore.save` throws after
        // `publicationStore.append` succeeds, the next compile reuses the same
        // version → two Publications at the same version. Swapping order moves
        // the failure mode to "version burned, no Publication" (visible gap).
        // Both shapes are non-corrupting but confusing; a real fix needs a
        // two-phase commit or a "pending publication" record promoted on
        // success of both writes.
        try await publicationStore.append(pub)
        progress.record("the catalog row: v\(effectiveVersion) \(format.rawValue) "
                        + "(\(pub.publicationID)) — list_publications can see it")

        // Notify in-app surfaces (e.g. ExportsListView) that a new publication
        // landed so they can refresh. Project-scoped at the post (ADR 0021):
        // the helper filters to windows on this project (and drops closed
        // ones); receivers no longer hand-filter.
        MaughamEvent.post(
            .maughamPublicationCompleted,
            to: .project(for: projectURL),
            object: pub.publicationID)

        // Bump version in config — source compiles only. A language edition is
        // a rendering of an existing source version and must never advance the
        // source version counter (spec 2026-07-23). Saving the ORIGINAL
        // `loaded` config (never `effective`, and never the imprint-RESOLVED
        // `config` — which has the imprint's overrides flattened onto the book)
        // keeps a translated or imprint compile from overwriting the shared
        // config.
        //
        // Task 6: an imprint counts its own versions, so the bump lands inside
        // its entry and never at the top level. The value bumped is the
        // RESOLVED counter — the imprint's own when it declares one, the
        // inherited book's when it does not — but where it is WRITTEN is the
        // imprint's entry either way, which is what turns an inherited counter
        // into the imprint's own on its first compile. Optional-chained rather
        // than force-unwrapped: resolution above already proved the entry
        // exists, and a crash would be a poor way to say otherwise.
        if set.isSourceCompile {
            var nextConfig = loaded
            let bumped = PublishConfigValidator.bumpedNextVersion(
                from: config.nextVersion)
            if let imprint {
                nextConfig.imprints[imprint]?.nextVersion = bumped
                try await configStore.save(nextConfig)
                progress.record(
                    "next_version for imprint '\(imprint)' advanced to \(bumped)")
            } else {
                nextConfig.nextVersion = bumped
                try await configStore.save(nextConfig)
                progress.record("next_version advanced to \(bumped)")
            }
        }

        // Gate warnings (allow_stale fallbacks + fountain drift) ride alongside
        // the compiler's own warnings on the success path.
        let allWarnings = gateWarnings + warnings
        await jobManager.complete(
            jobID: jobID, outputPath: outputPath,
            warnings: allWarnings, errors: errors)
        return .completed(pub, warnings: allWarnings)
    }

    /// Where a publication lives, for a refusal that has to name it. Two
    /// spellings because both halves of the sentence need one: "version '1.0'
    /// exists under imprint 'special', not the book".
    ///
    /// I2 (whole-branch review): not private, because `Republisher`'s own
    /// mint-gate refusal is the third sentence that has to say this — with
    /// per-imprint counters the book's v0.1 and an imprint's v0.1 are two
    /// publications, so a refusal naming only the (version, language, format)
    /// triple names neither. One spelling for all three rather than a second
    /// vocabulary for the same fact.
    static func placeOf(_ imprint: String?) -> String {
        imprint.map { "under imprint '\($0)'" } ?? "on the book"
    }

    private static func notPlaceOf(_ imprint: String?) -> String {
        imprint.map { "under imprint '\($0)'" } ?? "the book"
    }

    private func relativePath(_ abs: String, from root: URL) -> String {
        let prefix = root.path + "/"
        if abs.hasPrefix(prefix) { return String(abs.dropFirst(prefix.count)) }
        return abs
    }
}
