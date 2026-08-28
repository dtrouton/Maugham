import Foundation
import MaughamCore

/// A `ProjectASTBuilder.Source` that can produce itself bound to another
/// language edition.
///
/// The production conformer is `ProjectStoreASTSource`, whose `language`
/// decides whether `orderedPieces()` substitutes the merged translation
/// sidecar. A multi-body compile needs one source per body, so the plan asks
/// the source it was handed for its own siblings rather than knowing how to
/// build one — which is what keeps `BodyPlan` free of `ProjectStore`, and what
/// lets a test source that knows nothing about languages keep driving a
/// single-body compile.
public protocol LanguageRebindableSource: ProjectASTBuilder.Source {
    func rebound(toLanguage tag: String?) -> ProjectASTBuilder.Source
}

/// One body per rendered language, each already bound to its own AST source
/// and folded to its own effective config.
///
/// This is the value that keeps the word "languages" out of the compilers and
/// the orchestrator: they walk `bodies`, and each `Body` already answers what
/// text to read (`source`) and what config to emit under (`config`). The two
/// language folds a compile used to perform inline — `effectiveMetadata` then
/// `LanguageSuffixedFile.resolvingStyleFiles` — happen here, exactly once per
/// body, so a second body cannot silently inherit the first one's metadata or
/// its per-piece style files.
///
/// **Not `Sendable`, deliberately.** `ProjectASTBuilder.Source` is a
/// non-`Sendable` existential whose production conformer is main-actor
/// isolated; the codebase's own spelling for storing one is
/// `CompileOrchestrator.astSource` — a plain stored property on a struct that
/// makes no `Sendable` claim. `@unchecked Sendable` here would be that claim
/// made falsely, so the plan follows the orchestrator instead.
///
/// **`@MainActor` on `make`, for the same reason.**
/// `ProjectStoreASTSource`'s conformance to `ProjectASTBuilder.Source` is
/// itself `@MainActor` (SE-0470 isolated conformances — see that type's own
/// note), so the `LanguageRebindableSource` conformance refining it is too,
/// and the `as?` that reaches `rebound(toLanguage:)` has to run on the main
/// actor. The orchestrator's existing `astSource as? ProjectStoreASTSource`
/// gate already runs there, so this costs the callers nothing new.
public struct BodyPlan {

    /// A source that cannot answer for more than one language, asked to.
    /// Shaped after `LanguageSet.Invalid`: a `LocalizedError` whose sentence
    /// is the whole report.
    public struct NotRebindable: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public struct Body {
        /// The language this body renders; `nil` is the source body.
        public let tag: String?
        /// `tag ?? sourceTag` — how this body is spelled in a wrapper, a
        /// filename, or an identity. Never empty.
        public let displayTag: String
        /// Already wrapped by the caller's include filter.
        public let source: ProjectASTBuilder.Source
        /// `resolved` with both language folds applied.
        public let config: PublishConfig
    }

    /// Never empty; same order as `LanguageSet.bodies`.
    public let bodies: [Body]

    public var first: Body { bodies[0] }

    /// Builds one body per tag in `set`.
    ///
    /// - Parameters:
    ///   - resolved: the door's already-resolved config (imprint applied,
    ///     `nextVersion` threaded). Never mutated — each body gets its own fold
    ///     of it.
    ///   - source: the live source. Every body is bound to its own language
    ///     when the source can answer for one; a source that cannot is used AS
    ///     GIVEN, which is what keeps every test source that knows nothing
    ///     about languages driving a single-body compile. For two or more
    ///     bodies it MUST be a `LanguageRebindableSource`.
    ///
    ///     A one-body plan rebinds too, deliberately. A caller that already
    ///     bound its source to the language it is compiling gets the same value
    ///     back (`ProjectStoreASTSource(language: "es")` rebound to `"es"`), so
    ///     nothing changes for it — while an UNBOUND source handed
    ///     `languages: ["es"]` used to render the SOURCE text into a file named
    ///     `-es.epub`, recorded as `language: "es"`, with the coverage gate
    ///     green because the gate reads the translation layer rather than the
    ///     emitted book.
    ///   - wrap: how the caller wraps a bound source (the include filter).
    ///     Applied to EVERY body, the single given one included.
    /// - Throws: `NotRebindable` when `set.bodies.count > 1` and `source` is
    ///   not a `LanguageRebindableSource`.
    @MainActor
    public static func make(
        set: LanguageSet,
        resolved: PublishConfig,
        source: ProjectASTBuilder.Source,
        publishDir: URL,
        wrap: (ProjectASTBuilder.Source) -> ProjectASTBuilder.Source
    ) throws -> BodyPlan {

        // Asked of the source itself, never of the body count: a single body
        // needs its own text as much as one of two does.
        let rebindable = source as? any LanguageRebindableSource
        if set.bodies.count > 1, rebindable == nil {
            let list = set.bodies.map { $0 ?? set.sourceTag }.joined(separator: ", ")
            throw NotRebindable(message:
                "this compile renders \(set.bodies.count) languages (\(list)), "
                + "but its manuscript source cannot bind to a language")
        }

        let bodies = set.bodies.map { tag -> Body in
            // Each body asks the source for its own binding; a source that
            // cannot answer is used as given (one body only — the throw above
            // has already refused the rest).
            let bound = rebindable?.rebound(toLanguage: tag) ?? source
            return Body(
                tag: tag,
                displayTag: tag ?? set.sourceTag,
                source: wrap(bound),
                config: fold(resolved, toLanguage: tag, publishDir: publishDir))
        }
        return BodyPlan(bodies: bodies)
    }

    /// The two language folds a compile performs, in the order the orchestrator
    /// performed them inline: metadata first (`dc:language` plus
    /// `language_overrides`), then the per-piece style files, which are resolved
    /// against the filesystem because the emitter has none.
    private static func fold(
        _ config: PublishConfig, toLanguage tag: String?, publishDir: URL
    ) -> PublishConfig {
        var out = config
        out.metadata = config.effectiveMetadata(language: tag)
        return LanguageSuffixedFile.resolvingStyleFiles(
            in: out, language: tag, publishDir: publishDir)
    }

    private init(bodies: [Body]) {
        self.bodies = bodies
    }
}
