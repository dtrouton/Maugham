import XCTest
@testable import MaughamCore

final class DateSerialTests: XCTestCase {
    func test_knownSerials() {
        XCTAssertEqual(DateSerial.serial(year: 2008, month: 1, day: 1), 39448)
        XCTAssertEqual(DateSerial.serial(year: 2026, month: 10, day: 24), 46319)
        XCTAssertEqual(DateSerial.serial(year: 1900, month: 3, day: 1), 61)
        XCTAssertEqual(DateSerial.serial(year: 9999, month: 12, day: 31), DateSerial.latest)
        XCTAssertEqual(DateSerial.earliest, 61)
        XCTAssertEqual(DateSerial.latest, 2_958_465)
    }

    func test_invalidDatesAreNil() {
        XCTAssertNil(DateSerial.serial(year: 1900, month: 2, day: 28))
        XCTAssertNil(DateSerial.serial(year: 2026, month: 2, day: 29))
        XCTAssertNil(DateSerial.serial(year: 2026, month: 13, day: 1))
        XCTAssertNil(DateSerial.serial(year: 10000, month: 1, day: 1))
        XCTAssertNotNil(DateSerial.serial(year: 2024, month: 2, day: 29))
        XCTAssertNil(DateSerial.serial(year: 1900, month: 2, day: 29))
    }

    func test_components() {
        let c = DateSerial.components(46319)
        XCTAssertEqual(c?.year, 2026); XCTAssertEqual(c?.month, 10); XCTAssertEqual(c?.day, 24)
        XCTAssertNil(DateSerial.components(60))
    }

    func test_roundTripAcrossTheSupportedYears() {
        let end = DateSerial.serial(year: 2100, month: 12, day: 31)!
        var s = DateSerial.earliest
        while s <= end {
            let c = DateSerial.components(s)!
            XCTAssertEqual(DateSerial.serial(year: c.year, month: c.month, day: c.day), s)
            s += 37
        }
    }

    func test_isoRoundTrip() {
        XCTAssertEqual(DateSerial.isoString(46319), "2026-10-24")
        XCTAssertEqual(DateSerial.serial(iso: "2026-10-24"), 46319)
        XCTAssertNil(DateSerial.serial(iso: "2026-2-4"))
        XCTAssertNil(DateSerial.serial(iso: "2026-02-30"))
    }

    func test_addingMonthsClampsToTheMonthEnd() {
        func add(_ m: Int, _ y: Int, _ mo: Int, _ d: Int) -> String? {
            DateSerial.addingMonths(m, to: DateSerial.serial(year: y, month: mo, day: d)!).map(DateSerial.isoString)
        }
        XCTAssertEqual(add(1, 2026, 1, 31), "2026-02-28")
        XCTAssertEqual(add(1, 2024, 1, 31), "2024-02-29")
        XCTAssertEqual(add(-1, 2026, 3, 31), "2026-02-28")
        XCTAssertEqual(add(12, 2025, 2, 28), "2026-02-28")
        XCTAssertEqual(add(-3, 2026, 1, 15), "2025-10-15")
        XCTAssertNil(add(-1600, 2026, 1, 1))
    }

    func test_centuryAndLeapBoundaries() {
        XCTAssertEqual(DateSerial.serial(year: 2000, month: 2, day: 29), 36585)
        XCTAssertNil(DateSerial.serial(year: 2100, month: 2, day: 29))
        XCTAssertEqual(DateSerial.serial(year: 2100, month: 2, day: 28), 73109)
        XCTAssertEqual(DateSerial.serial(year: 2100, month: 3, day: 1), 73110)
        XCTAssertEqual(DateSerial.serial(year: 9999, month: 12, day: 31), 2958465)
        for (serial, y, m, d) in [(36585, 2000, 2, 29), (73109, 2100, 2, 28), (73110, 2100, 3, 1), (2958465, 9999, 12, 31)] {
            let c = DateSerial.components(serial)
            XCTAssertEqual(c?.year, y); XCTAssertEqual(c?.month, m); XCTAssertEqual(c?.day, d)
        }
        XCTAssertNil(DateSerial.components(2958466))
    }
}
