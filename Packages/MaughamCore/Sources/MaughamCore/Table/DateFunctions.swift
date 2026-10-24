import Foundation

/// The date functions' formula entries. Dates are serials (`DateSerial`); a serial outside
/// 1900-03-01…9999-12-31 is `#NUM!`.
extension FormulaFunctions {
    static let dates: [String: FormulaFunction] = [
        "YEAR": FormulaFunction(1, 1) { args in
            datePart(args[0]) { Double($0.year) }
        },
        "MONTH": FormulaFunction(1, 1) { args in
            datePart(args[0]) { Double($0.month) }
        },
        "EDATE": FormulaFunction(2, 2) { args in
            switch (integerSerial(args[0]), integer(args[1])) {
            case (.failure(let e), _), (_, .failure(let e)): return .error(e)
            case (.success(let s), .success(let m)):
                guard let r = DateSerial.addingMonths(m, to: s) else { return .error(.num) }
                return .date(r)
            }
        },
        "XNPV": FormulaFunction(3, 3) { args in
            switch number(args[0]) {
            case .failure(let e): return .error(e)
            case .success(let rate):
                guard rate > -1 else { return .error(.num) }
                switch datedFlows(args[1], args[2]) {
                case .failure(let e): return .error(e)
                case .success(let (values, times)):
                    var total = 0.0
                    for (v, t) in zip(values, times) { total += v / pow(1 + rate, t) }
                    return FormulaCoercion.finite(total)
                }
            }
        },
        "XIRR": FormulaFunction(2, 3) { args in
            var guess = 0.1
            if args.count > 2 {
                if case .missing = args[2] {} else {
                    switch number(args[2]) {
                    case .failure(let e): return .error(e)
                    case .success(let g): guess = g
                    }
                }
            }
            switch datedFlows(args[0], args[1]) {
            case .failure(let e): return .error(e)
            case .success(let (values, times)):
                guard values.contains(where: { $0 > 0 }), values.contains(where: { $0 < 0 }) else { return .error(.num) }
                let result = Finance.solve(guess: guess) { r in
                    var f = 0.0, d = 0.0
                    for (v, t) in zip(values, times) {
                        let factor = pow(1 + r, -t)
                        f += v * factor
                        d -= t * v * factor / (1 + r)
                    }
                    return (f, d)
                }
                switch result {
                case .failure(let e): return .error(e)
                case .success(let r): return FormulaCoercion.finite(r)
                }
            }
        },
    ]

    /// A date argument as a whole serial: a date, or a number truncated toward zero.
    private static func integerSerial(_ arg: FormulaArgument) -> Result<Int, FormulaError> {
        number(arg).flatMap { x in
            guard x.isFinite, abs(x) < 1e9 else { return .failure(.num) }
            return .success(Int(x.rounded(.towardZero)))
        }
    }

    private static func datePart(_ arg: FormulaArgument, _ pick: ((year: Int, month: Int, day: Int)) -> Double) -> CellValue {
        switch integerSerial(arg) {
        case .failure(let e): return .error(e)
        case .success(let s):
            guard let c = DateSerial.components(s) else { return .error(.num) }
            return .number(pick(c))
        }
    }

    /// XNPV's and XIRR's pairs, aligned by position: the values and, for each, years (days ÷ 365)
    /// since the first date. Counts must match (else `#NUM!`); a blank or non-number at any
    /// position of either list is `#VALUE!`, an error cell propagates; no date may precede the
    /// first or lie outside the supported serials, else `#NUM!`.
    private static func datedFlows(_ valuesArg: FormulaArgument, _ datesArg: FormulaArgument) -> Result<([Double], [Double]), FormulaError> {
        guard let valueCells = cells(valuesArg), let dateCells = cells(datesArg), valueCells.count == dateCells.count,
              !valueCells.isEmpty else { return .failure(.num) }
        var values: [Double] = [], dates: [Double] = []
        for (v, d) in zip(valueCells, dateCells) {
            switch (numberOrDate(v), numberOrDate(d)) {
            case (.failure(let e), _), (_, .failure(let e)): return .failure(e)
            case (.success(let x), .success(let y)): values.append(x); dates.append(y)
            }
        }
        let low = Double(DateSerial.earliest), high = Double(DateSerial.latest)
        let d0 = dates[0].rounded(.towardZero)
        guard d0 >= low, d0 <= high else { return .failure(.num) }
        var times: [Double] = []
        for d in dates {
            let day = d.rounded(.towardZero)
            guard day.isFinite, day >= d0, day <= high else { return .failure(.num) }
            times.append((day - d0) / 365)
        }
        return .success((values, times))
    }

    private static func cells(_ arg: FormulaArgument) -> [CellValue]? {
        switch arg {
        case .missing: return nil
        case .scalar(let v): return [v]
        case .range(let rows): return rows.flatMap { $0 }
        }
    }

    private static func numberOrDate(_ v: CellValue) -> Result<Double, FormulaError> {
        switch v {
        case .number(let x): return .success(x)
        case .date(let d): return .success(Double(d))
        case .error(let e): return .failure(e)
        default: return .failure(.value)
        }
    }
}
