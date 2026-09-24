import Foundation
import MaughamCore

/// The one place a batch of translated paragraphs is validated, built into
/// `TranslationRecord`s, and persisted.
///
/// Extracted from `WriteTranslationTool.handle` so the MCP tool and the
/// translator-loop ingest path cannot drift. Everything that makes a batch
/// safe lives here and nowhere else: exactly one form per entry, no
/// intra-batch duplicate ids, the unknown-id all-or-nothing rule that `delete`
/// is exempt from, the server-stamped source hash no caller may supply, the
/// advisory warnings, and the single coordinated append that makes "nothing is
/// written" hold for an I/O failure and not only for a validation failure.
/// `TripwireGrepTests.test_theTranslationWritePipelineIsTheOnlyPlaceAWriteBatchIsAppended`
/// is the census.
///
/// It lives beside the tool it was extracted from rather than in
/// `MaughamCore`: it throws `MCPError` and speaks the tool's vocabulary, and
/// its second consumer is app-side too.
@MainActor
public enum TranslationWritePipeline {

    /// One paragraph's instruction, mirroring `WriteTranslationTool.Params.Entry`:
    /// exactly one of `text` (the translated paragraph), `verbatim` (copy the
    /// current source unchanged) or `delete` (tombstone this paragraph's
    /// translation). The three-optionals shape is deliberate — the wire form
    /// can express "none" and "two", and rejecting those is a validation the
    /// pipeline owns rather than a case the type forbids, so a malformed MCP
    /// call gets the same worded error it always got.
    public struct Entry: Equatable {
        public let paragraphId: String
        public let text: String?
        public let verbatim: Bool?
        public let delete: Bool?

        public init(paragraphId: String, text: String? = nil,
                    verbatim: Bool? = nil, delete: Bool? = nil) {
            self.paragraphId = paragraphId
            self.text = text
            self.verbatim = verbatim
            self.delete = delete
        }
    }

    /// The current-paragraph snapshot the batch is validated and hashed
    /// against — what `currentParagraphState` returns (tripwire 20: the live
    /// `Document` for an open doc, the op-log-derived state for a closed one,
    /// never the on-disk `.md`).
    public typealias SourceState = (
        sequence: [String], paragraphs: [String: String], projectURL: URL)

    /// The language-tag gate. Called by the pipeline itself, so no caller can
    /// mint a translation file named after a tag the readers will not parse —
    /// and callable ahead of time by a caller that wants to reject before it
    /// does the more expensive work of resolving a project.
    public static func validate(language: String) throws {
        guard TranslationRecord.isValidLanguageTag(language) else {
            throw MCPError.invalidArgument("invalid language tag: \(language)")
        }
    }

    /// Validate `entries`, build every record, and persist the whole batch in
    /// one append. Returns the advisory warnings — structural drift and
    /// equals-source reminders — which never block the write.
    ///
    /// `actor` is who is writing, and it decides both the file and the key that
    /// signs it: `.translator` for `write_translation` and the pipeline's own
    /// ingest, which is what a translation IS. The signer is taken out of
    /// `identities` rather than passed beside it, so the key a line is signed
    /// with and the keys the file is read back under cannot disagree.
    ///
    /// Throws `MCPError.invalidArgument` and writes nothing if the language
    /// tag is malformed, an entry supplies other than exactly one form, the
    /// batch repeats a paragraph id, or a `text`/`verbatim` entry names an id
    /// outside the current sequence.
    @discardableResult
    public static func perform(
        entries: [Entry],
        language: String,
        documentId: String,
        state: SourceState,
        actor: DeviceActor,
        identities: LocalIdentities = .current,
        deviceState: OpLogDeviceState = .shared
    ) async throws -> [String] {
        // 1. Valid language tag.
        try validate(language: language)

        // 1a. **May this device's `actor` write a translation of this piece at
        // all?** (signed op log P3c Task 8.) Asked before anything is built or
        // appended, so a refusal writes nothing — a line a reader would set
        // aside is never signed in the first place.
        try refuseUnlessTranslatable(
            documentId: documentId, actor: actor, identities: identities,
            deviceState: deviceState, projectURL: state.projectURL)

        // 2. Each entry supplies exactly one of `text` / `verbatim: true` /
        // `delete: true`.
        for e in entries {
            let forms = [e.text != nil, e.verbatim == true, e.delete == true]
            if forms.filter({ $0 }).count != 1 {
                throw MCPError.invalidArgument(
                    "entry for paragraph \(e.paragraphId) must supply exactly one of " +
                    "`text`, `verbatim: true` or `delete: true`")
            }
        }

        // 2a. Reject intra-batch duplicate paragraph ids (a client bug).
        let ids = entries.map(\.paragraphId)
        let duplicates = Array(Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })).sorted()
        if !duplicates.isEmpty {
            throw MCPError.invalidArgument(
                "duplicate paragraph ids in batch: \(duplicates.joined(separator: ", "))")
        }

        // 3. All-or-nothing: every id a `text` or `verbatim` entry names must be
        // in the current sequence. A `delete` entry is exempt — an orphaned
        // translation names a paragraph the document no longer has, which is
        // exactly the one a writer needs to purge, and tombstoning an id that
        // was never translated is an idempotent no-op. The exemption is per
        // entry, not per batch: a text entry's unknown id still rejects the
        // whole call, its delete siblings included.
        let known = Set(state.sequence)
        let unknown = entries
            .filter { $0.delete != true }
            .map(\.paragraphId)
            .filter { !known.contains($0) }
        if !unknown.isEmpty {
            throw MCPError.invalidArgument(
                "unknown paragraph ids: \(unknown.joined(separator: ", "))")
        }

        // 4-6. Build every record first, then persist the whole batch in one
        // write, so "nothing is written" holds for an I/O failure and not only
        // for a validation failure. Every record carries `language` — one call
        // is one language, the invariant the batch append takes the tag as a
        // parameter for and does not re-check per record.
        var warnings: [String] = []
        var records: [TranslationRecord] = []
        for e in entries {
            let source = state.paragraphs[e.paragraphId] ?? ""
            let isVerbatim = e.verbatim == true
            let isDelete = e.delete == true
            // `text == nil` is the tombstone `TranslationStore.latestByParagraph`
            // already honors — the delete form is what finally mints one.
            let text: String? = isDelete ? nil : (isVerbatim ? source : (e.text ?? ""))
            records.append(TranslationRecord(
                paragraphId: e.paragraphId,
                language: language,
                text: text,
                sourceHash: TranslationHash.hash(source),
                verbatim: isVerbatim))
            if !isVerbatim, !isDelete, let translation = text {
                warnings.append(contentsOf: ConstructSkeleton.warnings(
                    source: source, translation: translation, paragraphId: e.paragraphId))
                // Both sides in display form, normalized through the same
                // stripper the freshness hash normalizes with: against the raw
                // source this comparison could never fire on an anchored
                // paragraph — a slugline or a numeral, the very lines the
                // advisory exists for.
                if MarkdownDisplayFilter.stripAnchors(translation)
                    == MarkdownDisplayFilter.stripAnchors(source) {
                    warnings.append(
                        "¶\(e.paragraphId): translated text equals source — mark " +
                        "verbatim: true if deliberate")
                }
            }
        }
        try await TranslationStore.appendBatch(
            records, forDocId: documentId, language: language,
            identity: identities[actor], identities: identities,
            state: deviceState, in: state.projectURL)

        return warnings
    }

    // MARK: - The permit (signed op log P3c Task 8)

    /// **Refuse, before anything is written, a translation this device's
    /// `actor` may not sign.**
    ///
    /// Judged as the ACTOR that signs the lines — `.translator` for
    /// `write_translation` and the pipeline's ingest — never as the writer's
    /// own hand: the actor is what the reader judges (`PermitJudge
    /// .translation`), so a refusal here is exactly a line the next read would
    /// have set aside. And in the class the reader CONSTRUCTS for a
    /// translation stream — `.translation(piece:)`, whose id is the piece's
    /// own — rather than one resolved from the manifest.
    ///
    /// **Built through Core's posture door, over the one builder**
    /// (`PostureDoor`, `OpLogStore.localWritePermit` — tripwire 46; controller
    /// ruling A; P3c plan 2 Task 1): the pipeline is reached from MCP and
    /// from the translator's ingest with a project URL and no window, and its
    /// callers inject the identities and the device memory the lines are
    /// signed with — the permit is asked over the SAME ones, so the key that
    /// would sign and the key that was judged cannot come apart. A book with
    /// no register asks nothing and answers yes.
    static func refuseUnlessTranslatable(
        documentId: String, actor: DeviceActor, identities: LocalIdentities,
        deviceState: OpLogDeviceState, projectURL: URL
    ) throws {
        let store = OpLogStore(
            projectURL: projectURL, presenter: nil, identities: identities,
            state: deviceState, cache: Document.loadRegistryCache)
        let posture = PostureDoor.posture(as: actor, using: store) {
            .translation(piece: documentId)
        }
        guard posture.allows(.translate) else {
            let title = pieceTitle(documentId, in: projectURL)
            throw MCPError.toolError(payload: .init(
                error: "translation_not_permitted",
                message: notPermittedSentence(title: title),
                hint: "This Mac's part in the book does not reach that piece. "
                    + "Nothing was written; the piece's author can translate it.",
                fields: ["document_id": .string(documentId)]))
        }
    }

    /// The sentence a refused translation is told in — the piece by its title
    /// where the manifest names it, else by its id.
    static func notPermittedSentence(title: String) -> String {
        "This Mac may not translate \u{201C}\(title)\u{201D} \u{2014} your part in "
            + "this book doesn\u{2019}t reach that piece, so nothing was written."
    }

    /// The piece's title from the manifest on disk, or its id.
    private static func pieceTitle(_ documentId: String, in projectURL: URL) -> String {
        let url = projectURL.appendingPathComponent(ProjectManifest.fileName)
        guard let data = try? Data(contentsOf: url),  // adr-0018-ok: project manifest JSON read for a title, not manuscript
              let manifest = try? ProjectManifest.makeDecoder().decode(
                ProjectManifest.self, from: data),
              let item = TreeWalk.find(id: documentId, in: manifest.structure)
        else { return documentId }
        return item.title
    }
}
