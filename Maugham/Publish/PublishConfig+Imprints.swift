import Foundation

// MARK: - Imprint resolution (spec §3)

/// Resolution is the ONE place imprint-awareness lives. `resolved(imprint:)`
/// turns `(config, name)` into an ordinary `PublishConfig` — the compilers,
/// the filename builder, the coverage gate and the publication snapshot all
/// read a plain config and never learn that an imprint existed. That is what
/// keeps an imprint from becoming a second code path through publishing.
extension PublishConfig {

    /// A name that no imprint in this project answers to.
    public struct UnknownImprint: LocalizedError, Equatable {
        public let requested: String
        /// Every imprint this project does define, sorted.
        public let known: [String]

        public init(requested: String, known: [String]) {
            self.requested = requested
            self.known = known.sorted()
        }

        public var errorDescription: String? {
            known.isEmpty
                ? "unknown imprint '\(requested)'; this project defines no imprints"
                : "unknown imprint '\(requested)'; known: \(known.joined(separator: ", "))"
        }
    }

    /// A merge-patch fragment that left a block unable to decode — deleting a
    /// required field (`metadata.title`), or giving one the wrong type. The
    /// validator (Task 3) refuses such a fragment at save time; this is the
    /// backstop for one that reached disk another way.
    public struct ImprintResolutionFailure: LocalizedError, Equatable {
        public let imprint: String
        /// `"metadata"`, `"outputs"` or `"cover"`.
        public let block: String
        public let reason: String

        public var errorDescription: String? {
            "imprint '\(imprint)' cannot be resolved: its \(block) \(reason)"
        }
    }

    /// The config this project compiles under when publishing as `imprint`.
    ///
    /// - `nil` → `self`, untouched: the book is not an imprint, and resolving
    ///   to it leaves `imprints` in place.
    /// - `template` replaces when the imprint names one.
    /// - `sections`, when present, is an ALLOWLIST and is *materialized*: every
    ///   id it names keeps its entry with `include` forced `true` (naming a
    ///   piece IS the inclusion), and every id in `pieceIDs` it does not name
    ///   gets `Section(include: false)`. That single move is what makes
    ///   `excludedSectionIDs`, `IncludeFilteredASTSource` and the coverage
    ///   gate's excluded set correct with no change of their own. Absent, the
    ///   book's own map is inherited.
    /// - `metadata`, `outputs`, `cover` are RFC 7396 merge-patch fragments
    ///   applied through `JSONMergePatch` — `null` deletes, everything the
    ///   fragment does not name is inherited.
    /// - `nextVersion` replaces when present: an imprint counts its own
    ///   versions.
    /// - `languageOverrides` are untouched; they apply after, in the
    ///   orchestrator.
    ///
    /// - Throws: `UnknownImprint` for a name this project does not define;
    ///   `ImprintResolutionFailure` for a fragment that leaves a block
    ///   undecodable.
    public func resolved(imprint name: String?, pieceIDs: [String]) throws -> PublishConfig {
        guard let name else { return self }
        guard let layer = imprints[name] else {
            throw UnknownImprint(requested: name, known: Array(imprints.keys))
        }

        var result = self

        if let template = layer.template {
            result.template = template
        }

        if let allowlist = layer.sections {
            var materialized: [String: Section] = [:]
            for (id, section) in allowlist {
                var section = section
                section.include = true
                materialized[id] = section
            }
            for id in pieceIDs where materialized[id] == nil {
                materialized[id] = Section(include: false)
            }
            result.sections = materialized
        }

        result.metadata = try Self.merging(
            metadata, with: layer.metadata, block: "metadata", imprint: name)
        result.outputs = try Self.merging(
            outputs, with: layer.outputs, block: "outputs", imprint: name)
        result.cover = try Self.merging(
            cover, with: layer.cover, block: "cover", imprint: name)

        if let nextVersion = layer.nextVersion {
            result.nextVersion = nextVersion
        }

        result.imprint = name
        return result
    }

    /// Encode the typed block, apply the fragment as an RFC 7396 merge patch,
    /// decode it back. `JSONMergePatch` is the one merger — a second
    /// implementation here would be a second set of null-deletes-a-key rules
    /// to keep in agreement with `set_publish_config`'s.
    private static func merging<Block: Codable>(
        _ block: Block,
        with fragment: [String: JSONValue]?,
        block name: String,
        imprint: String
    ) throws -> Block {
        guard let fragment, !fragment.isEmpty else { return block }
        let merged = try JSONMergePatch.apply(
            patch: try JSONEncoder().encode(fragment),
            to: try JSONEncoder().encode(block))
        do {
            return try JSONDecoder().decode(Block.self, from: merged)
        } catch {
            throw ImprintResolutionFailure(
                imprint: imprint, block: name, reason: describe(error))
        }
    }

    private static func describe(_ error: Swift.Error) -> String {
        guard let error = error as? DecodingError else {
            return "could not be decoded: \(error)"
        }
        switch error {
        case .keyNotFound(let key, _):
            return "no longer carries the required field '\(key.stringValue)'"
        case .valueNotFound(_, let context):
            return "leaves the required field '\(name(of: context))' with no value"
        case .typeMismatch(let type, let context):
            return "gives the field '\(name(of: context))' a value that is not a \(type)"
        case .dataCorrupted(let context):
            return "is not valid: \(context.debugDescription)"
        @unknown default:
            return "could not be decoded: \(error)"
        }
    }

    private static func name(of context: DecodingError.Context) -> String {
        context.codingPath.map(\.stringValue).joined(separator: ".")
    }
}
