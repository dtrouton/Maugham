import XCTest
import MaughamCore
@testable import Maugham

/// **An output format this build doesn't know round-trips as itself**
/// (ADR 0015 §5 amendment). `PublishConfig.Format` used to decode an unknown
/// name to `.pdf`, so a newer build's `"docx"` re-saved as `"pdf"` and compiled
/// a second PDF. It is now `.unknown(raw)`, kept verbatim through `config.json`
/// and the publications catalog, absent from `allCases`, and refused — never
/// compiled — by `PublishFormatRefusal`.
final class PublishFormatToleranceTests: XCTestCase {

    private static let docxOutputsJSON =
        #"{"directory":"Exports","filename_template":"x","sanitize_spaces":false,"formats_enabled":["pdf","docx"]}"#

    // MARK: - Decode / encode

    /// The inverted symptom pin. On the old code this decoded to
    /// `[.pdf, .pdf]` (pinned green there before the rewrite).
    func test_anUnknownFormatDecodesAsItselfNotAsPDF() throws {
        let outputs = try JSONDecoder().decode(
            PublishConfig.Outputs.self, from: Data(Self.docxOutputsJSON.utf8))
        XCTAssertEqual(outputs.formatsEnabled, [.pdf, .unknown("docx")])
    }

    func test_anUnknownFormatReEncodesByteForByte() throws {
        let outputs = try JSONDecoder().decode(
            PublishConfig.Outputs.self, from: Data(Self.docxOutputsJSON.utf8))
        let array = try JSONEncoder().encode(outputs.formatsEnabled)
        XCTAssertEqual(String(decoding: array, as: UTF8.self), #"["pdf","docx"]"#)
    }

    /// Today's encoding of a known-only `Outputs`, captured on the old code:
    /// the rewrite changes nothing for a project that only names pdf/epub.
    func test_knownOnlyEncodingIsUnchanged() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(PublishConfig.Outputs(formatsEnabled: [.pdf, .epub]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
            #"{"directory":"Exports","filename_template":"{title}-v{version}{label_suffix}.{ext}","formats_enabled":["pdf","epub"],"sanitize_spaces":false}"#)
    }

    /// Known names match case-insensitively. `"PDF"` was already `.pdf` (via
    /// the old fallback); `"Epub"` USED to fall back to `.pdf` and is now
    /// `.epub` — a declared behaviour change.
    func test_knownNamesMatchCaseInsensitively() throws {
        XCTAssertEqual(PublishConfig.Format(rawValue: "PDF"), .pdf)
        XCTAssertEqual(PublishConfig.Format(rawValue: "Epub"), .epub)
        XCTAssertEqual(PublishConfig.Format(rawValue: "EPUB"), .epub)
        let decoded = try JSONDecoder().decode(
            [PublishConfig.Format].self, from: Data(#"["PDF","Epub"]"#.utf8))
        XCTAssertEqual(decoded, [.pdf, .epub])
    }

    /// The init never builds `.unknown` around a known name, whatever its case.
    func test_theInitNeverConstructsUnknownForAKnownName() {
        for raw in ["pdf", "PDF", "Pdf", "pDF", "epub", "EPUB", "Epub", "ePuB"] {
            if case .unknown = PublishConfig.Format(rawValue: raw) {
                XCTFail("'\(raw)' built .unknown")
            }
        }
    }

    func test_unknownKeepsItsStringVerbatim() {
        XCTAssertEqual(PublishConfig.Format(rawValue: "DocX"), .unknown("DocX"))
        XCTAssertEqual(PublishConfig.Format.unknown("DocX").rawValue, "DocX")
        XCTAssertEqual(PublishConfig.Format.pdf.rawValue, "pdf")
        XCTAssertEqual(PublishConfig.Format.epub.rawValue, "epub")
    }

    /// Equality and hashing compare CASES, never `rawValue`: a hand-built
    /// `.unknown("pdf")` is not the PDF format.
    func test_anUnknownNeverEqualsAKnownFormat() {
        XCTAssertNotEqual(PublishConfig.Format.unknown("pdf"), .pdf)
        XCTAssertNotEqual(PublishConfig.Format.unknown("epub"), .epub)
        XCTAssertEqual(Set<PublishConfig.Format>([.pdf, .unknown("pdf")]).count, 2)
    }

    func test_allCasesIsWhatThisBuildCanProduce() {
        XCTAssertEqual(PublishConfig.Format.allCases, [.pdf, .epub])
    }

    func test_theRefusalSentence() {
        XCTAssertEqual(
            PublishFormatRefusal(raw: "docx").errorDescription,
            "This Maugham can't produce 'docx' output — it was named by a newer "
                + "version of Maugham. Update Maugham to compile it. Nothing was compiled.")
        XCTAssertEqual(PublishFormatRefusal(raw: "docx").errorDescription,
                       PublishFormatRefusal.message(raw: "docx"))
    }

    // MARK: - config.json through PublishConfigStore

    func test_configJSONRoundTripThroughTheStoreKeepsDocx() async throws {
        let project = try makeProjectDir()
        let url = PublishConfigStore.fileURL(in: project)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.configJSONNamingDocx().write(to: url)

        let store = PublishConfigStore(projectURL: project)
        let maybeLoaded = try await store.load()
        let loaded = try XCTUnwrap(maybeLoaded)
        XCTAssertEqual(loaded.outputs.formatsEnabled, [.pdf, .unknown("docx")])

        try await store.save(loaded)
        let written = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: written) as? [String: Any]
        let outputs = obj?["outputs"] as? [String: Any]
        XCTAssertEqual(outputs?["formats_enabled"] as? [String], ["pdf", "docx"])
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded?.outputs.formatsEnabled, [.pdf, .unknown("docx")])
    }

    // MARK: - The publications catalog

    @MainActor
    func test_catalogRowNamingDocxSurvivesAnAppendAndReload() async throws {
        let project = try makeProjectDir()
        let store = PublicationStore(projectURL: project)
        let file = PublicationStore.fileURL(
            deviceSlug: DeviceIdentity.author.slug, in: project)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written as a newer build would write it: today's encoding of a known
        // row with its format renamed, so the fixture does not lean on the
        // encoder under test.
        let line = try Self.catalogLineNamingDocx()
        try Data((line + "\n").utf8).write(to: file)

        let first = try await store.load()
        XCTAssertEqual(first.map(\.format), [.unknown("docx")])

        try await store.append(Self.publication(id: "pub-new", format: .pdf, minutes: 1))
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.first { $0.publicationID == "pub-docx" }?.format,
                       .unknown("docx"))
        // Guards the APPEND (it must not rewrite earlier lines); the old
        // symptom — the row read as a PDF — is pinned by the load assertions.
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(raw.contains(#""format":"docx""#), raw)
    }

    // MARK: - MCP echoes the raw string

    /// `set_publish_config` on an unrelated key, over a config naming a newer
    /// build's format: not a config error (an older build may edit a newer
    /// build's config), and the response, the file and `get_publish_config`
    /// all still say "docx".
    @MainActor
    func test_setAndGetPublishConfigKeepAndEchoDocx() async throws {
        let root = try makeProjectDir()
        let projectURL = try await ProjectFactory.createNovelProject(named: "T", in: root)
        try Self.configJSONNamingDocx().write(to: PublishConfigStore.fileURL(in: projectURL))
        let store = try await ProjectStore.load(from: projectURL)
        let registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        let projectID = ProjectIdentifier.id(for: projectURL)

        let data = try await SetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID)","patch":{"metadata":{"subtitle":"S"}}}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual((resp?["errors"] as? [Any])?.count, 0, "\(String(describing: resp))")
        let outputs = (resp?["config"] as? [String: Any])?["outputs"] as? [String: Any]
        XCTAssertEqual(outputs?["formats_enabled"] as? [String], ["pdf", "docx"])

        let getData = try await GetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID)"}"#.utf8), registry: registry)
        let got = try JSONSerialization.jsonObject(with: getData) as? [String: Any]
        let gotOutputs = (got?["config"] as? [String: Any])?["outputs"] as? [String: Any]
        XCTAssertEqual(gotOutputs?["formats_enabled"] as? [String], ["pdf", "docx"])
    }

    // MARK: - Fixtures

    private func makeProjectDir() throws -> URL {
        let url = TestTemp.root.appendingPathComponent(
            "PublishFormatTolerance-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A full default `config.json` whose `formats_enabled` names `"docx"`,
    /// built by editing the JSON object rather than through `Format`'s encoder.
    private static func configJSONNamingDocx() throws -> Data {
        let base = try JSONEncoder().encode(PublishConfig())
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: base) as? [String: Any])
        var outputs = try XCTUnwrap(obj["outputs"] as? [String: Any])
        outputs["formats_enabled"] = ["pdf", "docx"]
        obj["outputs"] = outputs
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    private static func catalogLineNamingDocx() throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let known = String(decoding: try enc.encode(
            publication(id: "pub-docx", format: .pdf, minutes: 10)), as: UTF8.self)
        XCTAssertTrue(known.contains(#""format":"pdf""#), known)
        return known.replacingOccurrences(of: #""format":"pdf""#, with: #""format":"docx""#)
    }

    private static func publication(id: String, format: PublishConfig.Format,
                                     minutes: Int) -> Publication {
        Publication(
            publicationID: id, version: "1.0", label: nil, format: format,
            outputPath: "Exports/book.\(format.rawValue)", snapshotID: "snap-\(id)",
            checkpointID: "ckpt-\(id)", republishedFrom: nil,
            compiledAt: Date(timeIntervalSince1970: 1_800_000_000 - Double(minutes) * 60),
            maughamVersion: "test", tectonicVersion: "test")
    }
}
