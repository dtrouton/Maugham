import Foundation

/// **The kept release census** (signed op log P3b Task 3; handoff ruling 3,
/// *A + 3b*).
///
/// ## What it is looking for
///
/// Released builds v0.37–v0.40 signed the load path's own emissions with
/// whichever actor opened the document. Five kinds are involved; two of them —
/// `bootstrap` and `taskCreate` — are recognisable by KIND alone and are
/// grandfathered by `Permit.isALoadEmission`, so they apply. The other three
/// are `typingBurst`s (both pending-recovery folds and the task-anchor splice)
/// and until this task they carried no `synthesisSource`, which makes them
/// indistinguishable on disk from a person typing.
///
/// A `typingBurst` signed by the assistant's or the translator's key is REFUSED
/// by the permit partition in any rooted book. That is the right answer for a
/// line MCP actually wrote and the wrong one for a line the LOAD wrote through
/// MCP's door — and the words are not lost either way (they are set aside and
/// recoverable), but somebody has to know they are there.
///
/// This is how they are found: run it on every Mac that has opened a book
/// before the P3 release. A hit is a per-line manual recovery, never a rule
/// change.
///
/// ## What it is not
///
/// It **decides nothing** and it **writes nothing** — no file is created,
/// moved, modified or deleted, and `LoadBurstCensusTests.test_itWritesNothing`
/// asserts that byte for byte rather than promising it. It reads METADATA only:
/// the stream's own filename, each line's `kind`, `op_id`, `doc_id` and
/// `provenance.synthesis_source`. It never looks at `changes`, so it never
/// reads a word of anybody's manuscript.
///
/// ## What it asks rather than re-deciding
///
/// - Which stream a file is, and whose slug it carries: `PermitMark.stream(of:)`
///   (tripwire 24 — a slug is read from a name, never built).
/// - Which actor a slug claims: `DeviceIdentity.claimedActor(ofDeviceId:)`
///   (tripwire 35).
/// - Whether a line is a seal: `OpLogChain.isSealLine` (tripwire 37 — there is
///   exactly one recogniser of a seal in this codebase and a census is not
///   allowed a second opinion).
///
/// The legacy unsuffixed `<docId>.jsonl` carries no slug and names no actor: it
/// is pre-signing history, applied under decision B3, and is read past rather
/// than reported.
public enum LoadBurstCensus {

    /// One `typingBurst` found in a stream whose slug names an actor that is
    /// not the author.
    public struct Hit: Equatable, Sendable {
        /// The project folder's path, as given.
        public let project: String
        /// The stream file's own name inside `.maugham/ops`.
        public let file: String
        /// The actor word the stream's slug claims — `assistant`, `translator`
        /// or `maugham`.
        public let actor: String
        public let opId: String
        public let docId: String
        /// `nil` is the shape the ruling is about: a burst with nothing on it
        /// to say the load wrote it. A non-nil value means a build carrying
        /// this task wrote it and it is already distinguishable.
        public let synthesisSource: String?

        public init(
            project: String, file: String, actor: String,
            opId: String, docId: String, synthesisSource: String?
        ) {
            self.project = project
            self.file = file
            self.actor = actor
            self.opId = opId
            self.docId = docId
            self.synthesisSource = synthesisSource
        }
    }

    /// One project's answer.
    ///
    /// It carries what was READ as well as what was found, deliberately: a
    /// census that reports *none* over a folder it could not open is a false
    /// all-clear, and *none* has to be distinguishable from *nothing was looked
    /// at*.
    public struct Report: Equatable, Sendable {
        public let project: String
        /// Live `.jsonl` tails read (including the legacy unsuffixed file).
        public let filesRead: Int
        /// Sealed `.mzseg` segments decoded.
        public let segmentsRead: Int
        /// The names of files that would not open or would not decode.
        public let unreadable: [String]
        public let hits: [Hit]

        public init(
            project: String, filesRead: Int, segmentsRead: Int,
            unreadable: [String], hits: [Hit]
        ) {
            self.project = project
            self.filesRead = filesRead
            self.segmentsRead = segmentsRead
            self.unreadable = unreadable
            self.hits = hits
        }
    }

    // MARK: - Scanning

    /// Every project folder under `root` — a directory holding a
    /// `.maugham/ops`. Read-only; a folder that will not list is skipped.
    public static func projects(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true else { continue }
            var isDir: ObjCBool = false
            let ops = url.appendingPathComponent(".maugham/ops")
            if fm.fileExists(atPath: ops.path, isDirectory: &isDir), isDir.boolValue {
                found.append(url)
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Read one project's op-log folder. Never throws: a census that stops at
    /// the first unreadable file tells you less than one that names it and
    /// carries on.
    public static func scan(projectURL: URL) -> Report {
        let ops = projectURL.appendingPathComponent(".maugham/ops")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: ops.path))
            ?? []).sorted()
        var filesRead = 0
        var segmentsRead = 0
        var unreadable: [String] = []
        var hits: [Hit] = []

        for name in names {
            let isSegment = name.hasSuffix(".\(OpLogSegment.fileExtension)")
            guard name.hasSuffix(".jsonl") || isSegment else { continue }
            let url = ops.appendingPathComponent(name)
            guard let raw = try? Data(contentsOf: url) else {  // adr-0018-ok: op-log tail or sealed segment, never a manuscript file
                unreadable.append(name)
                continue
            }
            let jsonl: Data
            if isSegment {
                let decoded = OpLogSegment.decodeVerifying(raw)
                guard let bytes = decoded.jsonl else {
                    unreadable.append(name)
                    continue
                }
                if !decoded.isVerified { unreadable.append(name) }
                jsonl = bytes
                segmentsRead += 1
            } else {
                jsonl = raw
                filesRead += 1
            }
            // The slug decides whose stream this is. No slug (the legacy
            // unsuffixed file) means no actor, which is not what this looks for.
            guard let slug = PermitMark.stream(of: url)?.deviceSlug,
                  let actor = DeviceIdentity.claimedActor(ofDeviceId: slug),
                  actor != .author else { continue }
            hits.append(contentsOf: bursts(
                inJSONL: jsonl, project: projectURL.path, file: name,
                actor: actor.rawValue))
        }

        return Report(
            project: projectURL.path, filesRead: filesRead,
            segmentsRead: segmentsRead, unreadable: unreadable.sorted(),
            hits: hits)
    }

    /// The metadata of every `typingBurst` in one stream's bytes.
    ///
    /// A private shape carrying the four fields this census reports and nothing
    /// else, so the decode itself cannot reach `changes`.
    private struct Metadata: Decodable {
        struct Provenance: Decodable {
            let synthesisSource: String?
            enum CodingKeys: String, CodingKey {
                case synthesisSource = "synthesis_source"
            }
        }
        let opId: String
        let docId: String
        let kind: String
        let provenance: Provenance?
        enum CodingKeys: String, CodingKey {
            case opId = "op_id"
            case docId = "doc_id"
            case kind, provenance
        }
    }

    private static func bursts(
        inJSONL jsonl: Data, project: String, file: String, actor: String
    ) -> [Hit] {
        let decoder = JSONDecoder()
        var hits: [Hit] = []
        for lineBytes in jsonl.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(lineBytes)
            // A seal is the chain's business and `OpLogChain` is the one thing
            // that recognises one (tripwire 37).
            if OpLogChain.isSealLine(line) { continue }
            guard let meta = try? decoder.decode(Metadata.self, from: line),
                  meta.kind == OpKind.typingBurst.rawValue else { continue }
            hits.append(Hit(
                project: project, file: file, actor: actor,
                opId: meta.opId, docId: meta.docId,
                synthesisSource: meta.provenance?.synthesisSource))
        }
        return hits
    }

    // MARK: - Saying what was found

    /// The sentence the script prints. Plain text, no colour, no escapes — it
    /// is pasted into a report.
    public static func describe(_ reports: [Report]) -> String {
        let hits = reports.flatMap(\.hits)
        let files = reports.reduce(0) { $0 + $1.filesRead }
        let segments = reports.reduce(0) { $0 + $1.segmentsRead }
        let unreadable = reports.flatMap { report in
            report.unreadable.map { "\(report.project): \($0)" }
        }
        var lines: [String] = []
        lines.append(
            "\(plural(reports.count, "project")), "
            + "\(plural(files, "file")), "
            + "\(plural(segments, "segment")) read.")
        if unreadable.isEmpty {
            lines.append("Unreadable: none.")
        } else {
            lines.append("Unreadable (\(unreadable.count)):")
            lines.append(contentsOf: unreadable.map { "  " + $0 })
        }
        if hits.isEmpty {
            lines.append("Load bursts under a non-author actor: none.")
        } else {
            lines.append("Load bursts under a non-author actor: \(hits.count).")
            for hit in hits {
                let label = hit.synthesisSource ?? "<unlabelled>"
                lines.append(
                    "  \(hit.project)  \(hit.file)  \(hit.actor)  "
                    + "op \(hit.opId)  doc \(hit.docId)  \(label)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func plural(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
