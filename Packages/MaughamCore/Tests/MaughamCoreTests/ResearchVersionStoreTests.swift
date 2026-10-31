import XCTest
@testable import MaughamCore

/// Report plan 9d Task 1: every save of a Research table keeps the previous
/// version — write-once per-device files under `.maugham/research-versions/`.
final class ResearchVersionStoreTests: XCTestCase {

    private let item = "res-1a2b3c4d"
    private let mac = DeviceSlug.unsafeForTesting("mac-a")
    private let other = DeviceSlug.unsafeForTesting("mac-b")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let trashExpiry: TimeInterval = 30 * 86_400
    /// Long past any file these tests write (their files are dated now).
    private let monthsLater = Date().addingTimeInterval(90 * 86_400)

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

    /// With one `savedAt` for all (the same instant), the `-n` orders as a
    /// number in the listing and in the prune: `-10` is newer than `-2`.
    func test_theSuffixesOrderNumerically() throws {
        let store = ResearchVersionStore(projectURL: TestTemp.root)
        var kept: [ResearchVersion] = []
        for i in 0..<11 {
            kept.append(try store.keep(priorBytes: Data("\(i)".utf8), priorSidecar: nil, writtenBy: nil,
                                       itemId: item, device: mac, at: t0))
        }
        XCTAssertEqual(kept.last?.name, "20270115-080000-mac-a-11")
        XCTAssertEqual(store.versions(itemId: item).map(\.name), kept.reversed().map(\.name))
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

        store.sweepOrphans(liveItemIds: [live], device: mac, minimumAge: trashExpiry, now: monthsLater)

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
    private func age(_ url: URL, by seconds: TimeInterval = 3_600) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    /// Another device's pair arrives one file at a time: a `.csv` alone, or
    /// a `.json` alone, is not a version yet; nor is a `.json` that isn't JSON.
    func test_aVersionListsOnlyOnceBothFilesAreHereAndTheMetaReads() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let kept = try store.keep(priorBytes: Data("x".utf8), priorSidecar: nil, writtenBy: .writer,
                                  itemId: item, device: mac, at: t0)
        try Data("y".utf8).write(to: folder(root).appendingPathComponent("20270115-090000-mac-b.csv"))
        try Data("{}".utf8).write(to: folder(root).appendingPathComponent("20270115-100000-mac-b.json"))
        try Data("z".utf8).write(to: folder(root).appendingPathComponent("20270115-110000-mac-b.csv"))
        try Data("not json".utf8).write(to: folder(root).appendingPathComponent("20270115-110000-mac-b.json"))
        try Data("w".utf8).write(to: folder(root).appendingPathComponent(".20270115-120000-mac-b.csv.icloud"))

        XCTAssertEqual(store.versions(itemId: item).map(\.name), [kept.name])
    }

    /// A restore never silently drops the formats: no meta, no read.
    func test_readThrowsWhenTheMetaIsGone() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let kept = try store.keep(priorBytes: Data("x".utf8), priorSidecar: ResearchTableSidecar(headerRows: 1),
                                  writtenBy: .writer, itemId: item, device: mac, at: t0)
        try FileManager.default.removeItem(at: folder(root).appendingPathComponent(kept.name + ".json"))
        XCTAssertThrowsError(try store.read(kept)) { error in
            XCTAssertEqual(error as? ResearchVersionStore.ReadError, .metaUnreadable(kept.name))
        }
    }

    /// A crash mid-keep leaves a staged file, or this device's `.json` whose
    /// `.csv` never landed: neither lists, and both are swept once stale; a
    /// fresh one (a save in progress) and another device's lone `.json`
    /// (its pair still arriving) stay.
    func test_aCrashMidKeepLeavesNothingListed_andItsLeftoversAreSwept() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let dir = folder(root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent(".staging-crash.csv")
        let lone = dir.appendingPathComponent("20270115-080000-mac-a.json")
        let fresh = dir.appendingPathComponent("20270115-090000-mac-a.json")
        let theirs = dir.appendingPathComponent("20270115-080000-mac-b.json")
        for url in [staged, lone, fresh, theirs] { try Data("{}".utf8).write(to: url) }
        for url in [staged, lone, theirs] { try age(url) }

        XCTAssertEqual(store.versions(itemId: item), [])
        store.prune(itemId: item, device: mac)

        XCTAssertEqual(try names(root), [theirs.lastPathComponent, fresh.lastPathComponent])

        let next = try store.keep(priorBytes: Data("x".utf8), priorSidecar: nil, writtenBy: nil,
                                  itemId: item, device: mac, at: t0)
        XCTAssertEqual(next.name, "20270115-080000-mac-a", "the swept name is free again")
    }

    /// An item deleted for good: this device's lone `.json` goes with its
    /// versions, and the emptied folder goes too.
    func test_sweepOrphans_takesALoneMetaAndTheEmptiedFolder() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let gone = "res-gone0000"
        try store.keep(priorBytes: Data("x".utf8), priorSidecar: nil, writtenBy: nil,
                       itemId: gone, device: mac, at: t0)
        try Data("{}".utf8).write(to: folder(root, gone).appendingPathComponent("20270115-090000-mac-a.json"))

        store.sweepOrphans(liveItemIds: [], device: mac, minimumAge: trashExpiry, now: monthsLater)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder(root, gone).path))
    }

    // MARK: - Final fix wave (I1, I2)

    /// **Whose save replaced the bytes** rides in the meta: an assistant's
    /// write keeps the state before it marked so, and the listing says it.
    func test_replacedByRoundTrips_andAMetaWithoutItReadsNil() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let kept = try store.keep(priorBytes: Data("a\n".utf8), priorSidecar: nil, writtenBy: .writer,
                                  replacedBy: .assistant, itemId: item, device: mac, at: t0)
        XCTAssertEqual(kept.replacedBy, .assistant)
        XCTAssertEqual(store.versions(itemId: item).map(\.replacedBy), [.assistant])
        let meta = try String(contentsOf: folder(root).appendingPathComponent(kept.name + ".json"), encoding: .utf8)
        XCTAssertTrue(meta.contains("\"replaced_by\" : \"assistant\""), meta)

        // A meta from before the field (or a value this build doesn't know) reads nil.
        try Data(#"{"saved_at":"2027-01-15T09:00:00.000Z","written_by":"writer","replaced_by":"robot"}"#.utf8)
            .write(to: folder(root).appendingPathComponent("20270115-090000-mac-a.json"))
        try Data("b\n".utf8).write(to: folder(root).appendingPathComponent("20270115-090000-mac-a.csv"))
        let listed = store.versions(itemId: item)
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed.first { $0.name == "20270115-090000-mac-a" }?.replacedBy, nil)
        XCTAssertEqual(listed.first { $0.name == "20270115-090000-mac-a" }?.writtenBy, .writer,
                       "an unknown replaced_by hides nothing else")
    }

    /// **A young orphan stays; an old one goes**: an item missing from the
    /// manifest whose newest file of this device's is younger than the
    /// Trash's expiry may have a trash entry on its way from another Mac.
    /// Disable experiment: drop the age guard in `sweepOrphans` and the young
    /// folder is swept.
    func test_sweepOrphans_keepsAFolderWhoseNewestOwnFileIsYoungerThanTheExpiry() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let young = "res-youn0000", old = "res-old00000"
        for id in [young, old] {
            try store.keep(priorBytes: Data(id.utf8), priorSidecar: nil, writtenBy: nil,
                           itemId: id, device: mac, at: t0)
        }
        // The old folder's files were last touched 31 days ago; the young one's just now.
        let longAgo = Date().addingTimeInterval(-31 * 86_400)
        for name in try names(root, old) {
            try FileManager.default.setAttributes([.modificationDate: longAgo],
                                                  ofItemAtPath: folder(root, old).appendingPathComponent(name).path)
        }

        store.sweepOrphans(liveItemIds: [], device: mac, minimumAge: trashExpiry)

        XCTAssertEqual(store.versions(itemId: young).count, 1, "a young orphan is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder(root, old).path),
                       "an orphan older than the expiry is swept, its folder with it")
    }

    /// One fresh file of this device's keeps the whole folder: the newest decides.
    func test_sweepOrphans_theNewestOwnFileDecides() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let id = "res-mixd0000"
        let first = try store.keep(priorBytes: Data("1".utf8), priorSidecar: nil, writtenBy: nil,
                                   itemId: id, device: mac, at: t0)
        try store.keep(priorBytes: Data("2".utf8), priorSidecar: nil, writtenBy: nil,
                       itemId: id, device: mac, at: t0.addingTimeInterval(60))
        let longAgo = Date().addingTimeInterval(-31 * 86_400)
        for ext in ["csv", "json"] {
            try FileManager.default.setAttributes(
                [.modificationDate: longAgo],
                ofItemAtPath: folder(root, id).appendingPathComponent("\(first.name).\(ext)").path)
        }
        store.sweepOrphans(liveItemIds: [], device: mac, minimumAge: trashExpiry)
        XCTAssertEqual(store.versions(itemId: id).count, 2, "a fresh file keeps every version of the item")
    }

    /// **The destroyed ids, and only those**: Permanently Delete's sweep
    /// takes this device's versions of the items it destroyed, never another
    /// item's, never another device's.
    func test_removeVersions_takesOnlyTheNamedItemsAndOnlyThisDevicesFiles() throws {
        let root = TestTemp.root
        let store = ResearchVersionStore(projectURL: root)
        let destroyed = "res-dest0000", untouched = "res-untc0000"
        for id in [destroyed, untouched] {
            try store.keep(priorBytes: Data(id.utf8), priorSidecar: nil, writtenBy: nil,
                           itemId: id, device: mac, at: t0)
        }
        try store.keep(priorBytes: Data("o".utf8), priorSidecar: nil, writtenBy: nil,
                       itemId: destroyed, device: other, at: t0)

        store.removeVersions(ofItems: [destroyed], device: mac)

        XCTAssertEqual(store.versions(itemId: destroyed).map { $0.isKept(by: other) }, [true],
                       "another device's versions are its own to remove")
        XCTAssertEqual(store.versions(itemId: untouched).count, 1, "an item not destroyed keeps its versions")
    }
}
