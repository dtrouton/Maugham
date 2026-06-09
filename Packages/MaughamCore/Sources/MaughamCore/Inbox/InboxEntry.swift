import Foundation

/// One capture in a project's inbox (`.maugham/inbox/`). The manifest is an
/// append-only JSONL stream, **partitioned per device** like the op log
/// (`inbox.<deviceSlug>.jsonl`, ADR 0012): each status transition appends a new
/// row with the same `id` and updated fields, and `InboxStore` collapses them
/// with a cross-file last-wins merge (newest `createdAt` per `id`).
///
/// Asset bytes live beside the manifest in kind-scoped subdirs
/// (`text/` is inline-only so has no asset; `images/<id>.<ext>`,
/// `audio/<id>.m4a`); `sourceFilename` carries the exact filename so the Mac
/// can locate the asset deterministically. snake_case JSON keys match the op
/// log's on-disk convention.
public struct InboxEntry: Codable, Equatable, Sendable, Identifiable {
    /// What was captured. (`manifest` is intentionally absent — an entry is
    /// never the manifest file itself; that distinction is `InboxFileKind`.)
    public enum Kind: String, Codable, Equatable, Sendable {
        case text, image, audio

        /// Cross-version forward-tolerance (ADR 0015): an unknown `kind` from a
        /// newer build decodes to `.text` rather than throwing (which would
        /// quarantine the whole inbox row). `.text` is the benign default —
        /// inline-only, no asset lookup. The schemaVersion guard doesn't cover
        /// the inbox (it's an append-only per-device JSONL, not the manifest),
        /// so the safe default is the only line of defence here.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .text
        }
    }

    /// Lifecycle of an audio entry's transcript. Non-audio entries are `.none`.
    public enum TranscriptionState: String, Codable, Equatable, Sendable {
        case none
        case onDeviceDraft = "on_device_draft"
        case whisperFinal = "whisper_final"
        case userEdited = "user_edited"   // the writer owns this transcript; the worker leaves it alone
        case failed

        /// Cross-version forward-tolerance (ADR 0015): an unknown state decodes
        /// to `.failed`, which is NOT worker-eligible (only `.none`/
        /// `.onDeviceDraft` are). Defaulting to `.none` would risk a
        /// cross-version re-transcription loop against a state a newer build
        /// owns; `.failed` is the inert, safe choice.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = TranscriptionState(rawValue: raw) ?? .failed
        }
    }

    /// Triage status. Only `.new` entries surface in the inbox pane; promoted /
    /// trashed are terminal and filtered out on load.
    public enum Status: String, Codable, Equatable, Sendable {
        case new
        case promoted
        case trashed

        /// Cross-version forward-tolerance (ADR 0015): an unknown status decodes
        /// to `.new` so the entry stays visible and triageable rather than being
        /// silently hidden (the failure mode if we defaulted to a terminal
        /// state). Non-destructive: the writer can still act on it.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .new
        }
    }

    public var id: String                       // ULID
    public var createdAt: Date                  // entry birth — immutable across transition rows
    /// When *this row* was written. Distinct from `createdAt`, which is the
    /// entry's birth and is copied unchanged onto every transition row. The
    /// last-wins merge orders by `writtenAt` so a later transition (e.g. the
    /// Mac's Whisper transcript) wins over the original create even though both
    /// share `createdAt`. Optional for decode robustness; merge falls back to
    /// `createdAt` when absent.
    public var writtenAt: Date?
    public var deviceId: String                 // per-install identifier of the capturer
    public var kind: Kind
    public var sourceFilename: String?          // nil for inline text
    public var inlineText: String?              // nil unless kind == .text
    public var transcript: String?              // nil until transcription advances
    public var transcriptionState: TranscriptionState
    public var title: String?                   // optional user-set label
    public var status: Status
    public var resolvedAt: Date?                // set when status leaves .new
    /// Human-readable reason the last transcription attempt failed (Whisper
    /// threw, or produced no text). nil unless `transcriptionState == .failed`.
    /// Optional so older readers and the phone (which never writes it) decode
    /// it as nil — tripwire 19.
    public var transcriptionError: String?

    public init(
        id: String,
        createdAt: Date,
        writtenAt: Date? = nil,
        deviceId: String,
        kind: Kind,
        sourceFilename: String? = nil,
        inlineText: String? = nil,
        transcript: String? = nil,
        transcriptionState: TranscriptionState = .none,
        title: String? = nil,
        status: Status = .new,
        resolvedAt: Date? = nil,
        transcriptionError: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.writtenAt = writtenAt
        self.deviceId = deviceId
        self.kind = kind
        self.sourceFilename = sourceFilename
        self.inlineText = inlineText
        self.transcript = transcript
        self.transcriptionState = transcriptionState
        self.title = title
        self.status = status
        self.resolvedAt = resolvedAt
        self.transcriptionError = transcriptionError
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case writtenAt = "written_at"
        case deviceId = "device_id"
        case kind
        case sourceFilename = "source_filename"
        case inlineText = "inline_text"
        case transcript
        case transcriptionState = "transcription_state"
        case title
        case status
        case resolvedAt = "resolved_at"
        case transcriptionError = "transcription_error"
    }
}
