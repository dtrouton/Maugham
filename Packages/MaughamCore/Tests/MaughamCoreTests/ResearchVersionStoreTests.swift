import XCTest
@testable import MaughamCore

/// Report plan 9d Task 1: every save of a Research table keeps the previous
/// version — write-once per-device files under `.maugham/research-versions/`.
final class ResearchVersionStoreTests: XCTestCase {

    private let item = "res-1a2b3c4d"
    private let mac = DeviceSlug.unsafeForTesting("mac-a")
    private let other = DeviceSlug.unsafeForTesting("mac-b")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder(_ root: URL, _ itemId: String? = nil) -> URL {
        root.appendingPathComponent(".maugham/research-versions/\(itemId ?? item)")
    }

    private func names(_ root: URL, _ itemId: String? = nil) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder(root, itemId).path).sorted()
    }

    func test_keepThenRead_roundTripsTheBytesExactlyAndTheSidecar() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("a,b\r\n1,=A2*2\r\n".utf8)
        let sidecar = ResearchTableSidecar(contentHash: ContentHash.of(bytes), headerRows: 1, totalRow: true,
                                           columnWidths: [80, nil], writtenBy: .assistant)

        let kept = try store.keep(priorBytes: bytes, priorSidecar: sidecar, writtenBy: .assistant,
                                  itemId: item, device: mac, at: t0)

        XCTAssertEqual(kept.name, "20270115-080000-mac-a")
        XCTAssertEqual(try names(root), ["20270115-080000-mac-a.csv", "20270115-080000-mac-a.json"],
                       "a .csv and a .json, no staging left behind")
        XCTAssertEqual(store.versions(itemId: item), [kept])
        XCTAssertEqual(kept.writtenBy, .assistant)
        XCTAssertEqual(kept.savedAt, t0)
        XCTAssertTrue(kept.isKept(by: mac))
        XCTAssertFalse(kept.isKept(by: other))
        let (readBytes, readSidecar) = try store.read(kept)
        XCTAssertEqual(readBytes, bytes, "BOM and line endings kept")
        XCTAssertEqual(readSidecar, sidecar)
    }

    func test_aVersionWithNoSidecarOrWriterReadsBackWithNone() throws {
        let store = ResearchVersionStore(projectURL: TestTemp.root)
        let kept = try store.keep(priorBytes: Data("x\n".utf8), priorSidecar: nil, writtenBy: nil,
                                  itemId: item, device: mac, at: t0)
        XCTAssertNil(store.versions(itemId: item).first?.writtenBy)
        XCTAssertNil(try store.read(kept).1)
    }

    func test_aSecondKeepInTheSameSecond_takesTheNextSuffix_andNothingIsOverwritten() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let first = try store.keep(priorBytes: Data("one".utf8), priorSidecar: nil, writtenBy: .writer,
                                   itemId: item, device: mac, at: t0)
        let second = try store.keep(priorBytes: Data("two".utf8), priorSidecar: nil, writtenBy: .writer,
                                    itemId: item, device: mac, at: t0.addingTimeInterval(0.25))
        let third = try store.keep(priorBytes: Data("three".utf8), priorSidecar: nil, writtenBy: .writer,
                                   itemId: item, device: mac, at: t0.addingTimeInterval(0.5))

        XCTAssertEqual([first.name, second.name, third.name],
                       ["20270115-080000-mac-a", "20270115-080000-mac-a-2", "20270115-080000-mac-a-3"])
        XCTAssertEqual(try store.read(first).0, Data("one".utf8))
        XCTAssertEqual(try store.read(second).0, Data("two".utf8))
        XCTAssertTrue(second.isKept(by: mac))
        XCTAssertEqual(store.versions(itemId: item).map(\.name), [third.name, second.name, first.name],
                       "newest first")
    }

    func test_twoDevicesFilesCoexist_andPruneTouchesOnlyItsOwn() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        for i in 0..<5 {
            try store.keep(priorBytes: Data("m\(i)".utf8), priorSidecar: nil, writtenBy: .writer,
                           itemId: item, device: mac, at: t0.addingTimeInterval(Double(i) * 60))
            try store.keep(priorBytes: Data("o\(i)".utf8), priorSidecar: nil, writtenBy: .writer,
                           itemId: item, device: other, at: t0.addingTimeInterval(Double(i) * 60 + 30))
        }
        XCTAssertEqual(store.versions(itemId: item).count, 10)

        store.prune(itemId: item, device: mac, keep: 2)

        let left = store.versions(itemId: item)
        XCTAssertEqual(left.filter { $0.isKept(by: other) }.count, 5, "the other device's files untouched")
        let mine = left.filter { $0.isKept(by: mac) }
        XCTAssertEqual(try mine.map { try store.read($0).0 }, [Data("m4".utf8), Data("m3".utf8)],
                       "the newest two of mine kept")
        XCTAssertEqual(try names(root).count, 14, "each pruned version's .csv and .json went")
        XCTAssertEqual(ResearchVersionStore.retention, 50)
    }

    func test_pruneOrdersTheSuffixesNumerically() throws {
        let store = ResearchVersionStore(projectURL: TestTemp.root)
        var kept: [ResearchVersion] = []
        for i in 0..<11 {
            kept.append(try store.keep(priorBytes: Data("\(i)".utf8), priorSidecar: nil, writtenBy: nil,
                                       itemId: item, device: mac, at: t0.addingTimeInterval(Double(i) / 100)))
        }
        XCTAssertEqual(kept.last?.name, "20270115-080000-mac-a-11")
        store.prune(itemId: item, device: mac, keep: 2)
        XCTAssertEqual(Set(store.versions(itemId: item).map(\.name)),
                       ["20270115-080000-mac-a-10", "20270115-080000-mac-a-11"])
    }

    func test_aHostileItemIdIsRefused_andNothingIsWritten() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        for hostile in ["../escape", "res.x", ".hidden", "a/b", ""] {
            XCTAssertThrowsError(try store.keep(priorBytes: Data("x".utf8), priorSidecar: nil, writtenBy: nil,
                                                itemId: hostile, device: mac, at: t0), hostile) { error in
                XCTAssertEqual(error as? SafeRelativePath.PathError, .notADocId(hostile))
            }
            XCTAssertEqual(store.versions(itemId: hostile), [])
            store.prune(itemId: hostile, device: mac, keep: 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".maugham").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    /// A file some daemon flagged hidden still lists (`DotfileScan`); a
    /// dot-named staging file never does.
    func test_aHiddenFlaggedVersionIsListed_andADotNamedFileIsNot() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let kept = try store.keep(priorBytes: Data("x".utf8), priorSidecar: nil, writtenBy: .writer,
                                  itemId: item, device: mac, at: t0)
        var csv = folder(root).appendingPathComponent(kept.name + ".csv")
        var values = URLResourceValues()
        values.isHidden = true
        try csv.setResourceValues(values)
        XCTAssertEqual(try csv.resourceValues(forKeys: [.isHiddenKey]).isHidden, true, "premise: flagged hidden")
        try Data("y".utf8).write(to: folder(root).appendingPathComponent(".staging-abc.csv"))

        XCTAssertEqual(store.versions(itemId: item).map(\.name), [kept.name])
    }

    func test_sweepOrphans_removesOnlyThisDevicesFilesOfItemsNoLongerLive() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let live = "res-live0000", gone = "res-gone0000", goneShared = "res-shar0000"
        for id in [live, gone, goneShared] {
            try store.keep(priorBytes: Data(id.utf8), priorSidecar: nil, writtenBy: nil,
                           itemId: id, device: mac, at: t0)
        }
        try store.keep(priorBytes: Data("o".utf8), priorSidecar: nil, writtenBy: nil,
                       itemId: goneShared, device: other, at: t0)

        store.sweepOrphans(liveItemIds: [live], device: mac)

        XCTAssertEqual(store.versions(itemId: live).count, 1, "a live item (or one in the Trash) keeps its versions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder(root, gone).path),
                       "a deleted item's folder goes once empty")
        XCTAssertEqual(store.versions(itemId: goneShared).map { $0.isKept(by: other) }, [true],
                       "another device's versions are its to sweep")
    }

    /// The meta is tolerant: a later build's keys, or a field of the wrong
    /// type, never hide the version.
    func test_aDamagedMetaStillListsTheVersionByItsStamp() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let kept = try store.keep(priorBytes: Data("x".utf8), priorSidecar: nil, writtenBy: .assistant,
                                  itemId: item, device: mac, at: t0.addingTimeInterval(0.5))
        try Data(#"{"written_by":"martian","saved_at":7,"later":{}}"#.utf8)
            .write(to: folder(root).appendingPathComponent(kept.name + ".json"))
        let listed = try XCTUnwrap(store.versions(itemId: item).first)
        XCTAssertEqual(listed.savedAt, t0, "dated by the stamp, to the second")
        XCTAssertNil(listed.writtenBy)
        XCTAssertEqual(try store.read(listed).0, Data("x".utf8))
    }
}
