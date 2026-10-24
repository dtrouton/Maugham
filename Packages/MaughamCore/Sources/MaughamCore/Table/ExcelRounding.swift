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
        guard var magnitude = Decimal(string: String(format: "%.15g", abs(x))), !magnitude.isNaN
        else { return x }                                // beyond Decimal's range: nothing to round
        var out = Decimal()
        NSDecimalRound(&out, &magnitude, max(-128, min(128, digits)), mode)
        guard !out.isNaN else { return x }
        guard out != 0 else { return 0 }
        guard let m = Double(NSDecimalNumber(decimal: out).stringValue) else { return x }
        return negative ? -m : m
    }
}
