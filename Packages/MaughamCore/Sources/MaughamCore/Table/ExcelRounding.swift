import Foundation

/// Excel's rounding: it rounds the value's 15-significant-digit decimal form, not its
/// binary one, so `ROUND(2.675, 2)` is 2.68 where binary arithmetic gives 2.67.
public enum ExcelRounding {
    /// Excel ROUND: half away from zero on the value's 15-significant-digit decimal form.
    public static func round(_ x: Double, digits: Int) -> Double { rounded(x, digits, .plain) }
    /// Excel ROUNDUP: away from zero.
    public static func roundUp(_ x: Double, digits: Int) -> Double { rounded(x, digits, .up) }
    /// Excel ROUNDDOWN: toward zero.
    public static func roundDown(_ x: Double, digits: Int) -> Double { rounded(x, digits, .down) }

    private static func rounded(_ x: Double, _ digits: Int, _ mode: NSDecimalNumber.RoundingMode) -> Double {
        guard x.isFinite, x != 0 else { return x }
        let negative = x < 0
        // The magnitude's decimal form: `.plain`, `.up` and `.down` on it are half-away,
        // away and toward zero.
        let places = max(-128, min(128, digits))
        guard var magnitude = Decimal(string: String(format: "%.15g", abs(x))), !magnitude.isNaN
        else { return abs(x) < 1 ? underflow(x, places, mode) : x }   // too large: nothing to round
        var out = Decimal()
        NSDecimalRound(&out, &magnitude, places, mode)
        guard !out.isNaN else { return x }
        guard out != 0 else { return 0 }
        guard let m = Double(NSDecimalNumber(decimal: out).stringValue) else { return x }
        return negative ? -m : m
    }

    /// A magnitude below Decimal's range (≈1e-128) is under one unit of every place it can
    /// round to: toward zero and half away give 0 (half away gives the unit when |x| is at least
    /// half of it); away from zero gives ±1 unit, as Excel's ROUNDUP does.
    private static func underflow(_ x: Double, _ places: Int, _ mode: NSDecimalNumber.RoundingMode) -> Double {
        let unit = pow(10, Double(-places))
        let away: Bool
        switch mode {
        case .up: away = true
        case .plain: away = abs(x) >= unit / 2
        default: away = false
        }
        return away ? (x < 0 ? -unit : unit) : 0
    }
}
