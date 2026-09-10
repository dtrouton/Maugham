import Foundation
import XCTest
@testable import MaughamCore

/// **One canonicalization, named in one file.**
///
/// The whole of P2's registry rests on the writer and the reader asking the
/// same question of the same bytes. They cannot ask it of the same bytes if
/// either of them spells the question itself: a second `JSONEncoder`, a second
/// `JSONSerialization` call, a second `SHA256` — each is a second opinion about
/// what was signed, and each fails in the direction that costs a device its
/// admission rather than the direction that shouts.
///
/// So `RegistryCanonical` is the one file in the registry that may name any of
/// them, and this is the census that says so. It is a census with a planted
/// offender beside it, because a comment saying the same thing has been merged
/// and lost three times elsewhere in this codebase.
final class RegistryCanonicalCensusTests: XCTestCase {

    /// The registry's sources, minus the one file allowed to canonicalize.
    private static let censusedFiles = [
        "RegistryWriter.swift", "RegistryWriter+Restore.swift",
        "RegistryReader.swift", "RegistryRecord.swift",
    ]

    /// Naming any of these is claiming an opinion about what was signed.
    private static let forbidden = ["JSONEncoder(", "JSONSerialization", "SHA256"]

    private static var sourceDirectory: URL {
        // …/Packages/MaughamCore/Tests/MaughamCoreTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MaughamCore
            .appendingPathComponent("Sources/MaughamCore")
    }

    func test_onlyRegistryCanonicalDecidesWhatWasSigned() throws {
        for name in Self.censusedFiles {
            let url = Self.sourceDirectory.appendingPathComponent(name)
            let source = try String(contentsOf: url, encoding: .utf8)
            for offender in Self.offenders(in: source) {
                XCTFail("""
                    \(name) names “\(offender)”. The bytes a registry record is \
                    signed over are RegistryCanonical's decision and nothing \
                    else's — ask it, don't spell it again.
                    """)
            }
        }
    }

    func test_registryCanonicalIsTheFileThatDoesCanonicalize() throws {
        let source = try String(
            contentsOf: Self.sourceDirectory.appendingPathComponent("RegistryCanonical.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("JSONSerialization"),
                      "the census means nothing if the allowed file stopped doing the work")
        XCTAssertTrue(source.contains("SHA256"))
        XCTAssertTrue(source.contains("withoutEscapingSlashes"),
                      "the pinned escaping choice lives here, once")
    }

    /// The control. A census that cannot fail is a comment.
    func test_theCensusFiresOnAPlantedOffender() {
        let planted = """
            func digest(of record: Record) -> Data {
                Data(SHA256.hash(data: try JSONEncoder().encode(record)))
            }
            """

        XCTAssertEqual(Self.offenders(in: planted).sorted(), ["JSONEncoder(", "SHA256"])
        XCTAssertEqual(Self.offenders(in: "let url = writer.url(for: record)"), [],
                       "and it is quiet about a file that asks RegistryCanonical instead")
    }

    private static func offenders(in source: String) -> [String] {
        forbidden.filter { source.contains($0) }
    }
}
