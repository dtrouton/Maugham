// Maugham/OpLog/ISO8601Fast.swift
import Foundation

/// A hand parser for the two ISO 8601 shapes Maugham itself writes:
///
///     YYYY-MM-DDTHH:MM:SSZ
///     YYYY-MM-DDTHH:MM:SS.fffZ      (1–9 fraction digits)
///
/// It exists for one reason: a cold open of a 50,000-line op log decodes a date
/// per line, and `ISO8601DateFormatter` costs an allocation and a trip through
/// ICU for each one. This costs neither — fixed positions, days-from-civil
/// arithmetic (Howard Hinnant's algorithm), no `Calendar`, no `DateFormatter`,
/// nothing heap-allocated on the path.
///
/// It is deliberately NARROW. `Z` only, no offsets, no lowercase `z`, no
/// missing `T`, no out-of-range field. Anything it does not recognise it
/// refuses by answering nil, and the caller falls back to the formatter that
/// has always been there — so a shape this parser has never seen decodes
/// exactly as it did before, and being wrong here can only cost speed.
public enum ISO8601Fast {

    /// The parsed instant, or nil if the bytes are not one of the two shapes.
    ///
    /// Generic over the byte collection so a caller can pass `String.utf8`
    /// without materialising anything; within the module the optimiser
    /// specialises it for the one type that is ever passed.
    public static func date<C: Collection>(utf8: C) -> Date? where C.Element == UInt8 {
        var index = utf8.startIndex
        let end = utf8.endIndex

        // A run of exactly `count` ASCII digits, as an Int.
        func digits(_ count: Int) -> Int? {
            var value = 0
            var seen = 0
            while seen < count {
                guard index < end else { return nil }
                let byte = utf8[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
                index = utf8.index(after: index)
                seen += 1
            }
            return value
        }

        func literal(_ byte: UInt8) -> Bool {
            guard index < end, utf8[index] == byte else { return false }
            index = utf8.index(after: index)
            return true
        }

        guard let year = digits(4), literal(UInt8(ascii: "-")),
              let month = digits(2), literal(UInt8(ascii: "-")),
              let day = digits(2), literal(UInt8(ascii: "T")),
              let hour = digits(2), literal(UInt8(ascii: ":")),
              let minute = digits(2), literal(UInt8(ascii: ":")),
              let second = digits(2)
        else { return nil }

        guard month >= 1, month <= 12,
              day >= 1, day <= daysInMonth(year: year, month: month),
              hour <= 23, minute <= 59, second <= 59
        else { return nil }

        var fraction = 0.0
        if index < end, utf8[index] == UInt8(ascii: ".") {
            index = utf8.index(after: index)
            var value = 0
            var seen = 0
            while index < end, seen < 9 {
                let byte = utf8[index]
                guard byte >= 0x30, byte <= 0x39 else { break }
                value = value * 10 + Int(byte - 0x30)
                index = utf8.index(after: index)
                seen += 1
            }
            guard seen >= 1 else { return nil }
            fraction = Double(value) / powerOfTen(seen)
        }

        // `Z`, and then nothing — a tenth fraction digit or a trailing offset
        // lands here and is refused.
        guard literal(UInt8(ascii: "Z")), index == end else { return nil }

        let seconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3_600 + minute * 60 + second
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    // MARK: - Arithmetic

    private static func isLeap(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeap(year) ? 29 : 28
        default: return 0
        }
    }

    /// Days from 1970-01-01 to the given civil date. Howard Hinnant's
    /// `days_from_civil`: shift the year to start in March so the leap day is
    /// last, then count eras of 400 years.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400                                   // [0, 399]
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// A switch rather than a table: nothing to allocate, nothing to bounds-check.
    private static func powerOfTen(_ exponent: Int) -> Double {
        switch exponent {
        case 1: return 10
        case 2: return 100
        case 3: return 1_000
        case 4: return 10_000
        case 5: return 100_000
        case 6: return 1_000_000
        case 7: return 10_000_000
        case 8: return 100_000_000
        default: return 1_000_000_000
        }
    }
}
