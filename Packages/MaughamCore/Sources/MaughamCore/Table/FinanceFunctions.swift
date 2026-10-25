import Foundation

/// Excel's finance functions as pure numerics: cash flows (NPV, IRR, MIRR), the annuity
/// family (PV, FV, PMT, NPER, RATE) and CAGR. `atStart` is Excel's `type` 1 (payments at
/// the start of each period). A result that is not finite is `#NUM!`.
///
/// IRR and RATE run Newton's method from `guess` (analytic derivative, at most 100 steps,
/// converged when a step is under 1e-10). Where Newton fails they bracket and bisect on
/// (−0.999999, 10), so where Excel (20 iterations) gives up this may still answer; where
/// Excel converges, it is to the same root.
public enum Finance {
    static let lowestRate = -0.999999
    static let highestRate = 10.0

    // MARK: Cash flows

    /// Σ vᵢ/(1+r)ⁱ for i from 1.
    public static func npv(rate: Double, _ flows: [Double]) -> Result<Double, FormulaError> {
        guard rate != -1 else { return .failure(.divideByZero) }
        return finite(discounted(rate, flows, firstPeriod: 1))
    }

    /// The rate at which the flows' NPV, the first undiscounted, is zero.
    public static func irr(_ flows: [Double], guess: Double = 0.1) -> Result<Double, FormulaError> {
        guard flows.contains(where: { $0 > 0 }), flows.contains(where: { $0 < 0 }) else { return .failure(.num) }
        return solve(guess: guess) { r in
            var f = 0.0, d = 0.0, factor = 1.0      // factor = (1+r)^-i
            for (i, v) in flows.enumerated() {
                f += v * factor
                d -= Double(i) * v * factor / (1 + r)
                factor /= (1 + r)
            }
            return (f, d)
        }
    }

    public static func mirr(_ flows: [Double], financeRate: Double, reinvestRate: Double) -> Result<Double, FormulaError> {
        let n = Double(flows.count)
        let positives = flows.map { max($0, 0) }, negatives = flows.map { min($0, 0) }
        guard flows.count > 1, positives.contains(where: { $0 > 0 }), negatives.contains(where: { $0 < 0 }) else {
            return .failure(.divideByZero)
        }
        guard financeRate != -1, reinvestRate != -1 else { return .failure(.divideByZero) }
        let gains = -discounted(reinvestRate, positives, firstPeriod: 1) * pow(1 + reinvestRate, n)
        let costs = discounted(financeRate, negatives, firstPeriod: 1) * (1 + financeRate)
        guard costs != 0 else { return .failure(.divideByZero) }
        return finite(pow(gains / costs, 1 / (n - 1)) - 1)
    }

    // MARK: Annuities

    public static func pv(rate r: Double, periods n: Double, payment: Double, future: Double = 0, atStart: Bool = false) -> Result<Double, FormulaError> {
        if r == 0 { return finite(-(future + payment * n)) }
        let g = pow(1 + r, n)
        return finite(-(future + payment * (1 + r * t(atStart)) * (g - 1) / r) / g)
    }

    public static func fv(rate r: Double, periods n: Double, payment: Double, present: Double = 0, atStart: Bool = false) -> Result<Double, FormulaError> {
        if r == 0 { return finite(-(present + payment * n)) }
        let g = pow(1 + r, n)
        return finite(-(present * g + payment * (1 + r * t(atStart)) * (g - 1) / r))
    }

    public static func pmt(rate r: Double, periods n: Double, present: Double, future: Double = 0, atStart: Bool = false) -> Result<Double, FormulaError> {
        if r == 0 {
            guard n != 0 else { return .failure(.divideByZero) }
            return finite(-(present + future) / n)
        }
        let g = pow(1 + r, n)
        return finite(-r * (future + present * g) / ((1 + r * t(atStart)) * (g - 1)))
    }

    public static func nper(rate r: Double, payment: Double, present: Double, future: Double = 0, atStart: Bool = false) -> Result<Double, FormulaError> {
        if r == 0 {
            guard payment != 0 else { return .failure(.divideByZero) }
            return finite(-(present + future) / payment)
        }
        guard r > -1 else { return .failure(.num) }
        let p = payment * (1 + r * t(atStart))
        let ratio = (p - future * r) / (p + present * r)
        guard ratio > 0, ratio.isFinite else { return .failure(.num) }
        return finite(log(ratio) / log(1 + r))
    }

    /// The periodic rate at which the annuity balances: pv·(1+r)ⁿ + pmt·(1+r·t)·((1+r)ⁿ−1)/r + fv = 0.
    public static func rate(periods n: Double, payment: Double, present: Double, future: Double = 0, atStart: Bool = false, guess: Double = 0.1) -> Result<Double, FormulaError> {
        let tt = t(atStart)
        return solve(guess: guess) { r in
            if abs(r) < 1e-12 {   // the r → 0 limits of the balance and its derivative
                return (present + payment * n + future,
                        present * n + payment * (n * (n - 1) / 2 + tt * n))
            }
            let g = pow(1 + r, n), gPrime = n * pow(1 + r, n - 1)
            let a = (g - 1) / r, aPrime = (gPrime * r - (g - 1)) / (r * r)
            let f = present * g + payment * (1 + r * tt) * a + future
            let d = present * gPrime + payment * (tt * a + (1 + r * tt) * aPrime)
            return (f, d)
        }
    }

    // MARK: Growth

    /// (end/start)^(1/years) − 1.
    public static func cagr(start: Double, end: Double, years: Double) -> Result<Double, FormulaError> {
        guard start != 0, years != 0 else { return .failure(.divideByZero) }
        return finite(pow(end / start, 1 / years) - 1)   // a negative base with a fractional exponent is NaN → #NUM!
    }

    // MARK: Shared

    private static func t(_ atStart: Bool) -> Double { atStart ? 1 : 0 }

    private static func finite(_ x: Double) -> Result<Double, FormulaError> {
        x.isFinite ? .success(x) : .failure(.num)
    }

    /// Σ vᵢ/(1+r)^(i+firstPeriod), each flow at its own index.
    private static func discounted(_ r: Double, _ flows: [Double], firstPeriod: Int) -> Double {
        var total = 0.0, factor = pow(1 + r, -Double(firstPeriod))
        for v in flows {
            total += v * factor
            factor /= (1 + r)
        }
        return total
    }

    /// A root of `f` on (−1, ∞): Newton from `guess`, else bisection on a bracketing
    /// interval of (lowestRate, highestRate) — the one nearest `guess` when there are several.
    static func solve(guess: Double, _ f: (Double) -> (value: Double, slope: Double)) -> Result<Double, FormulaError> {
        if let root = newton(guess: guess, f) { return .success(root) }
        guard let (lo, hi) = bracket(near: guess, { f($0).value }) else { return .failure(.num) }
        return .success(bisect(lo, hi) { f($0).value })
    }

    private static func newton(guess: Double, _ f: (Double) -> (value: Double, slope: Double)) -> Double? {
        guard guess > -1, guess.isFinite else { return nil }
        var r = guess
        for _ in 0..<100 {
            let (value, slope) = f(r)
            guard value.isFinite, slope.isFinite, slope != 0 else { return nil }
            let step = value / slope
            r -= step
            guard r > -1, r.isFinite else { return nil }
            if abs(step) < 1e-10 { return r }
        }
        return nil
    }

    /// Adjacent sample points of (lowestRate, highestRate) between which `f` changes sign.
    private static func bracket(near guess: Double, _ f: (Double) -> Double) -> (Double, Double)? {
        // Denser near zero, where rates live: a geometric spacing of 1 + r.
        let samples = 2_000
        let logLo = log(1 + lowestRate), logHi = log(1 + highestRate)
        var points: [(r: Double, f: Double)] = []
        for k in 0...samples {
            let r = exp(logLo + (logHi - logLo) * Double(k) / Double(samples)) - 1
            let v = f(r)
            if v.isFinite { points.append((r, v)) }
        }
        var best: (Double, Double)?
        var bestDistance = Double.infinity
        for (a, b) in zip(points, points.dropFirst()) {
            if a.f == 0 { return (a.r, a.r) }
            guard (a.f < 0) != (b.f < 0) else { continue }
            let distance = min(abs(a.r - guess), abs(b.r - guess))
            if distance < bestDistance { (best, bestDistance) = ((a.r, b.r), distance) }
        }
        return best
    }

    private static func bisect(_ lo: Double, _ hi: Double, _ f: (Double) -> Double) -> Double {
        var (lo, hi) = (lo, hi)
        var fLo = f(lo)
        for _ in 0..<200 where hi - lo > 1e-15 {
            let mid = (lo + hi) / 2, fMid = f(mid)
            if fMid == 0 { return mid }
            if (fMid < 0) == (fLo < 0) { (lo, fLo) = (mid, fMid) } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}

/// The finance functions' formula entries: argument reading per Excel, then `Finance`.
extension FormulaFunctions {
    static let finance: [String: FormulaFunction] = [
        "NPV": FormulaFunction(2) { args in
            lift {
                let rate = try number(args[0]).get()
                return try Finance.npv(rate: rate, npvFlows(Array(args.dropFirst())).get()).get()
            }
        },
        "IRR": FormulaFunction(1, 2) { args in
            lift {
                let flows = try rangeFlows(args[0]).get()
                let guess = try optional(args, 1, default: 0.1)
                return try Finance.irr(flows, guess: guess).get()
            }
        },
        "MIRR": FormulaFunction(3, 3) { args in
            lift {
                try Finance.mirr(rangeFlows(args[0]).get(), financeRate: number(args[1]).get(),
                                 reinvestRate: number(args[2]).get()).get()
            }
        },
        "PV": FormulaFunction(3, 5) { args in
            lift {
                try Finance.pv(rate: number(args[0]).get(), periods: number(args[1]).get(), payment: number(args[2]).get(),
                               future: optional(args, 3, default: 0), atStart: flag(args, 4)).get()
            }
        },
        "FV": FormulaFunction(3, 5) { args in
            lift {
                try Finance.fv(rate: number(args[0]).get(), periods: number(args[1]).get(), payment: number(args[2]).get(),
                               present: optional(args, 3, default: 0), atStart: flag(args, 4)).get()
            }
        },
        "PMT": FormulaFunction(3, 5) { args in
            lift {
                try Finance.pmt(rate: number(args[0]).get(), periods: number(args[1]).get(), present: number(args[2]).get(),
                                future: optional(args, 3, default: 0), atStart: flag(args, 4)).get()
            }
        },
        "NPER": FormulaFunction(3, 5) { args in
            lift {
                try Finance.nper(rate: number(args[0]).get(), payment: number(args[1]).get(), present: number(args[2]).get(),
                                 future: optional(args, 3, default: 0), atStart: flag(args, 4)).get()
            }
        },
        "RATE": FormulaFunction(3, 6) { args in
            lift {
                try Finance.rate(periods: number(args[0]).get(), payment: number(args[1]).get(), present: number(args[2]).get(),
                                 future: optional(args, 3, default: 0), atStart: flag(args, 4),
                                 guess: optional(args, 5, default: 0.1)).get()
            }
        },
        "CAGR": FormulaFunction(3, 3) { args in
            lift {
                try Finance.cagr(start: number(args[0]).get(), end: number(args[1]).get(), years: number(args[2]).get()).get()
            }
        },
    ]

    private static func lift(_ body: () throws -> Double) -> CellValue {
        do { return FormulaCoercion.finite(try body()) } catch let err as FormulaError { return .error(err) } catch {
            return .error(.value)
        }
    }

    /// An optional numeric argument: absent or an empty slot takes the default.
    private static func optional(_ args: [FormulaArgument], _ i: Int, default d: Double) throws -> Double {
        guard i < args.count else { return d }
        if case .missing = args[i] { return d }
        return try number(args[i]).get()
    }

    /// Excel's `type`: truthy means payments at the start of each period.
    private static func flag(_ args: [FormulaArgument], _ i: Int) throws -> Bool {
        try optional(args, i, default: 0) != 0
    }

    /// NPV's values: inside a range only numbers count (text, booleans, empties and dates
    /// are ignored); given directly, numbers, dates, booleans and numeric text count, an
    /// empty slot is 0, and other text is `#VALUE!`. Errors propagate either way.
    private static func npvFlows(_ args: [FormulaArgument]) -> Result<[Double], FormulaError> {
        var xs: [Double] = []
        for arg in args {
            switch arg {
            case .missing: xs.append(0)
            case .range(let rows):
                for row in rows {
                    for v in row {
                        switch v {
                        case .number(let x): xs.append(x)
                        case .error(let err): return .failure(err)
                        default: break
                        }
                    }
                }
            case .scalar(let v):
                switch v {
                case .error(let err): return .failure(err)
                case .text(let s):
                    guard let x = FormulaCoercion.plainNumber(s) else { return .failure(.value) }
                    xs.append(x)
                default:
                    if case .success(let x) = FormulaCoercion.number(v) { xs.append(x) }
                }
            }
        }
        return .success(xs)
    }

    /// IRR's and MIRR's one range: only numbers count, errors propagate. A single number
    /// given directly is a one-flow array.
    private static func rangeFlows(_ arg: FormulaArgument) -> Result<[Double], FormulaError> {
        switch arg {
        case .scalar(.number(let x)): return .success([x])
        default: break
        }
        return range(arg).flatMap { rows in
            var xs: [Double] = []
            for row in rows {
                for v in row {
                    switch v {
                    case .number(let x): xs.append(x)
                    case .error(let err): return .failure(err)
                    default: break
                    }
                }
            }
            return .success(xs)
        }
    }
}
