import Foundation
import XCTest
@testable import MaughamCore

/// **One canonicalization, and two callers of it.**
///
/// The whole of P2's registry rests on the writer and the reader asking the
/// same question of the same bytes. They cannot ask it of the same bytes if
/// either of them spells the question itself: a second `JSONEncoder`, a second
/// `JSONSerialization` call, a second `SHA256` — each is a second opinion about
/// what was signed, and each fails in the direction that costs a device its
/// admission rather than the direction that shouts.
///
/// **Membership is derived, not typed** (fix round 1, I2). The first cut of this
/// census listed four file names, which protects the files that existed the day
/// it was written and nothing after — `RegistryPresence.swift` was already
/// outside it, and Task 3's `RegistryAdmission.swift` would have been too. The
/// population is now *every registry and trust source file there is*, found by
/// walking the production trees, so a file added tomorrow is censused the moment
/// it lands.
final class RegistryCanonicalCensusTests: XCTestCase {

    // MARK: - The population

    /// The production trees. Tests live elsewhere and are not censused: a test
    /// canonicalizing by hand is the point (`addFieldAndResign` states the
    /// format rather than restating the code under test).
    private static var productionRoots: [URL] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MaughamCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // <repo>
        return [
            repo.appendingPathComponent("Packages/MaughamCore/Sources"),
            repo.appendingPathComponent("Maugham"),
            repo.appendingPathComponent("MaughamPhone"),
        ]
    }

    /// A registry or trust source file, by name. The registry's own files are
    /// `Registry*`, the trust layer's are `Trust*`, and both are places somebody
    /// would plausibly reach for a hash.
    ///
    /// **`AdmissionMemory.swift` is in the population by name** (P2b Task 10,
    /// from Task 3's carry). It matches neither prefix and is the one other
    /// device-local memory in this layer: it persists the writer's decision
    /// about who a device is, which is what `RegistryPresence.admitRemembered`
    /// writes a signed person record FROM. A hash rolled there would be an
    /// opinion about a record's identity formed one step before the record, in
    /// the file the census was not looking at.
    private static func isRegistryOrTrustSource(_ url: URL) -> Bool {
        guard url.pathExtension == "swift" else { return false }
        let name = url.lastPathComponent
        return name.hasPrefix("Registry") || name.hasPrefix("Trust")
            || name == "AdmissionMemory.swift"
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    // MARK: - Nobody else decides what was signed

    /// Naming any of these is claiming an opinion about what was signed.
    private static let forbidden = ["JSONEncoder(", "JSONSerialization", "SHA256"]

    /// File PLUS spelling, never a bare file. `RegistryCanonical.swift` is the
    /// one place that canonicalizes and hashes. `RegistryCache.swift` encodes
    /// and decodes its OWN persisted memory — a `Stored` blob of remembered
    /// bytes, not a record — so it is let past `JSONEncoder(`/`JSONDecoder(`
    /// alone, and would still be caught reaching for `SHA256` or hand-rolling a
    /// canonical form.
    ///
    /// `AdmissionMemory.swift` is let past the same one spelling for the same
    /// reason: its `Stored` blob is a memory of the writer's decisions, not a
    /// record, and it would still be caught reaching for `SHA256`.
    private static let allowedSpellings: [String: Set<String>] = [
        "RegistryCanonical.swift": ["JSONEncoder(", "JSONSerialization", "SHA256"],
        "RegistryCache.swift": ["JSONEncoder("],
        "AdmissionMemory.swift": ["JSONEncoder("],
    ]

    func test_onlyRegistryCanonicalDecidesWhatWasSigned() throws {
        var censused: [String] = []
        var offenders: [String] = []
        for root in Self.productionRoots {
            for url in Self.swiftFiles(under: root)
            where Self.isRegistryOrTrustSource(url) {
                censused.append(url.lastPathComponent)
                let source = try String(contentsOf: url, encoding: .utf8)
                offenders += Self.offenders(
                    in: source, named: url.lastPathComponent)
            }
        }

        XCTAssertTrue(
            censused.contains("RegistryPresence.swift"),
            """
            The census found \(censused.count) registry/trust sources and \
            RegistryPresence.swift was not among them, so the walk is not \
            reaching the tree it thinks it is. Found: \
            \(censused.sorted().joined(separator: ", "))
            """)
        XCTAssertTrue(offenders.isEmpty, """
            A registry or trust source decides for itself what a record's \
            signature covers. The bytes are RegistryCanonical's decision and \
            nothing else's — ask `canonicalBytes(ofJSON:)`, don't spell it \
            again. Offenders:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: - Two callers, and only two

    /// The digest itself has exactly two production users: the writer makes a
    /// signature over it, the reader checks one against it. A third caller is
    /// somebody deciding for themselves when a record counts as verified.
    private static let digestCallers: Set<String> = [
        "RegistryWriter.swift", "RegistryReader.swift", "RegistryCanonical.swift",
    ]

    func test_theDigestHasTwoCallersAndTheOneThatDefinesIt() throws {
        var callers: Set<String> = []
        for root in Self.productionRoots {
            for url in Self.swiftFiles(under: root) {
                let source = try String(contentsOf: url, encoding: .utf8)
                if source.contains("digestHex(") { callers.insert(url.lastPathComponent) }
            }
        }

        XCTAssertEqual(
            callers, Self.digestCallers,
            """
            The registry digest is made in one place and checked in one place. \
            Anything else asking for it is a third opinion about when a record \
            is verified.
            """)
    }

    // MARK: - The allowed file still does the work

    func test_registryCanonicalIsTheFileThatDoesCanonicalize() throws {
        let url = try XCTUnwrap(
            Self.productionRoots.lazy
                .flatMap(Self.swiftFiles(under:))
                .first { $0.lastPathComponent == "RegistryCanonical.swift" })
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains("JSONSerialization"),
                      "the census means nothing if the allowed file stopped doing the work")
        XCTAssertTrue(source.contains("SHA256"))
        XCTAssertTrue(source.contains("withoutEscapingSlashes"),
                      "the pinned escaping choice lives here, once")
    }

    // MARK: - The control

    /// A census that cannot fail is a comment. This plants the offender in a
    /// file name the derived walk would pick up, in the allow-listed file under
    /// a spelling it is NOT allowed, and in a file that asks properly.
    func test_theCensusFiresOnAPlantedOffender() {
        let planted = """
            func digest(of record: DeviceRecord) throws -> Data {
                Data(SHA256.hash(data: try JSONEncoder().encode(record)))
            }
            """

        XCTAssertEqual(
            Self.offenders(in: planted, named: "RegistryAdmission.swift").count, 2,
            "a new registry file gets no grace period")
        XCTAssertEqual(
            Self.offenders(in: planted, named: "TrustPresence.swift").count, 2,
            "and neither does a new trust file")

        // The allow-list is a file PLUS a spelling: the memory's own encoder
        // passes under its own name, a hash in the same file does not.
        XCTAssertEqual(
            Self.offenders(in: "try JSONEncoder().encode(stored)",
                           named: "RegistryCache.swift"),
            [])
        XCTAssertEqual(
            Self.offenders(in: "let d = SHA256.hash(data: bytes)",
                           named: "RegistryCache.swift").count, 1,
            "the memory may encode itself; it may not decide what was signed")

        XCTAssertEqual(
            Self.offenders(in: planted, named: "RegistryCanonical.swift"), [],
            "and the one file that does the work is not its own offender")
        XCTAssertEqual(
            Self.offenders(in: "let digest = try RegistryCanonical.digestHex(ofRecord: r)",
                           named: "RegistryWriter.swift"),
            [],
            "asking is not spelling")

        // Every tree the census claims to walk must actually yield files.
        // Without this, a mistyped root would make three of the four tests
        // above pass by looking at nothing.
        for root in Self.productionRoots {
            XCTAssertFalse(
                Self.swiftFiles(under: root).isEmpty,
                """
                \(root.path) yielded no Swift files — the census is walking a \
                tree that is not there, and every censused population above is \
                smaller than it looks.
                """)
        }

        // The population predicate itself, since everything rests on it.
        XCTAssertTrue(Self.isRegistryOrTrustSource(URL(fileURLWithPath: "/x/RegistryAdmission.swift")))
        XCTAssertTrue(Self.isRegistryOrTrustSource(URL(fileURLWithPath: "/x/TrustTable.swift")))
        XCTAssertFalse(Self.isRegistryOrTrustSource(URL(fileURLWithPath: "/x/OpLogChain.swift")))
        XCTAssertFalse(Self.isRegistryOrTrustSource(URL(fileURLWithPath: "/x/RegistryNotes.md")))
    }

    private static func offenders(in source: String, named name: String) -> [String] {
        let allowed = allowedSpellings[name] ?? []
        return forbidden
            .filter { !allowed.contains($0) && source.contains($0) }
            .map { "\(name) names “\($0)”" }
    }
}
