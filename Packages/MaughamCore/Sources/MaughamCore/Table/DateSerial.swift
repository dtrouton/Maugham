import Foundation

/// Excel's 1900 date system as integer calendar arithmetic: a serial is the count of days
/// since 1899-12-30 in the proleptic Gregorian calendar. No `Calendar`, no time zone.
/// Serials below 1900-03-01 are not supported (Excel's phantom 1900-02-29 never matters).
public enum DateSerial {
    public static let earliest = 61            // 1900-03-01
    public static let latest = 2_958_465       // 9999-12-31

    /// Days from 1970-01-01 to 1899-12-30 (negated): serial = unixDays + 25_569.
    private static let epochOffset = 25_569

    public static func serial(year: Int, month: Int, day: Int) -> Int? {
        guard (1...12).contains(month), day >= 1, day <= daysIn(year: year, month: month) else { return nil }
        let s = daysFromCivil(year, month, day) + epochOffset
        return (earliest...latest).contains(s) ? s : nil
    }

    public static func components(_ serial: Int) -> (year: Int, month: Int, day: Int)? {
        guard (earliest...latest).contains(serial) else { return nil }
        return civilFromDays(serial - epochOffset)
    }

    public static func isoString(_ serial: Int) -> String {
        guard let c = components(serial) else { return "" }
        return pad(c.year, 4) + "-" + pad(c.month, 2) + "-" + pad(c.day, 2)
    }

    public static func serial(iso: String) -> Int? {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        return serial(year: y, month: m, day: d)
    }

    /// EDATE: the same day `months` later, clamped to the end of a shorter month.
    public static func addingMonths(_ months: Int, to serial: Int) -> Int? {
        guard let c = components(serial), abs(months) < 1_000_000 else { return nil }
        let index = c.year * 12 + (c.month - 1) + months
        let year = Int((Double(index) / 12).rounded(.down)), month = index - year * 12 + 1
        return Self.serial(year: year, month: month, day: min(c.day, daysIn(year: year, month: month)))
    }

    // MARK: Calendar arithmetic (Hinnant's civil-days algorithms)

    private static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    private static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}
