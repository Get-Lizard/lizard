import Foundation

/// Inline calculator for the launcher: arithmetic with precedence and parentheses, powers,
/// percentages ("15% of 80", "200 + 10%"), functions (sqrt, sin, cos, tan, log, ln, abs, round,
/// floor, ceil), constants (pi, e) and unit conversions ("5 km in mi", "100 f to c", "2 GB in MB").
/// A hand-written parser — never `NSExpression`, which raises on malformed input.
public enum Calculator {
    public struct Result: Sendable, Equatable {
        public let value: Double
        /// Formatted for display ("1,234.5", "3.11 mi").
        public let display: String
        /// Plain value for copying ("1234.5").
        public let copyText: String
    }

    public static func evaluate(_ input: String) -> Result? {
        let text = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty, text.count < 200 else { return nil }
        if let converted = convertUnits(text) { return converted }
        // Needs at least one operator or function, so a plain number or word isn't "calculated".
        let hasOperator = text.contains { "+-*/^%×÷()".contains($0) } || functions.keys.contains { text.contains($0 + "(") } || text.contains(" of ")
        guard hasOperator, text.contains(where: \.isNumber) || text.contains("pi") else { return nil }
        var parser = Parser(text: text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: ",", with: ""))
        guard let value = parser.parse(), value.isFinite else { return nil }
        return Result(value: value, display: format(value), copyText: plain(value))
    }

    /// What kind of calculation `input` is, for the result card ("Sum", "Conversion"…).
    public static func kind(of input: String) -> String {
        let text = input.lowercased()
        if convertUnits(text.trimmingCharacters(in: .whitespaces)) != nil { return "Conversion" }
        if text.contains("%") || text.contains(" of ") { return "Percentage" }
        if functions.keys.contains(where: { text.contains($0 + "(") }) { return "Function" }
        // Operators, ignoring a leading minus sign on a number.
        let body = text.drop { $0 == " " || $0 == "-" }
        let operators = Set(body.filter { "+-*/^×÷".contains($0) }.map { $0 == "×" ? "*" : $0 == "÷" ? "/" : $0 })
        switch operators {
        case ["+"]: return "Sum"
        case ["-"]: return "Difference"
        case ["*"]: return "Product"
        case ["/"]: return "Quotient"
        case ["^"]: return "Power"
        default: return "Expression"
        }
    }

    /// The result spelled out ("Two", "Forty-two point five"), for numbers people say aloud.
    public static func words(_ value: Double, locale: Locale = .current) -> String? {
        guard value.isFinite, abs(value) < 1e12 else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = locale
        formatter.maximumFractionDigits = 3
        guard let text = formatter.string(from: NSNumber(value: value)), text.count <= 60 else { return nil }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = abs(value) < 1 ? 10 : 6
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func plain(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 10
        formatter.minimumIntegerDigits = 1
        formatter.decimalSeparator = "."
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static let functions: [String: @Sendable (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "sin": sin, "cos": cos, "tan": tan, "log": log10, "ln": log,
        "abs": abs, "round": { $0.rounded() }, "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
    ]

    /// Recursive-descent parser: expr → term (('+'|'-') term)*, with percentages handled like a calculator.
    struct Parser {
        let chars: [Character]
        var index = 0

        init(text: String) {
            chars = Array(text.filter { !$0.isWhitespace })
        }

        mutating func parse() -> Double? {
            guard let value = expression(), index == chars.count else { return nil }
            return value
        }

        var peek: Character? { index < chars.count ? chars[index] : nil }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = peek, op == "+" || op == "-" {
                index += 1
                // "200 + 10%" adds ten percent of 200.
                let start = index
                guard let rhs = term() else { return nil }
                let isPercent = index > start && chars[index - 1] == "%" && !(index < chars.count && chars[index] == "o")
                let amount = isPercent ? value * rhs : rhs
                value = op == "+" ? value + amount : value - amount
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while true {
                if peek == "*" || peek == "/" {
                    let op = chars[index]
                    index += 1
                    guard let rhs = power() else { return nil }
                    value = op == "*" ? value * rhs : value / rhs
                } else if matches("of") {
                    // "15% of 80"
                    guard let rhs = power() else { return nil }
                    value *= rhs
                } else if peek == "(" || (peek.map { $0.isLetter } ?? false) {
                    // Implicit multiplication: 2pi, 3(4+1)
                    guard let rhs = power() else { return nil }
                    value *= rhs
                } else {
                    return value
                }
            }
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek == "^" {
                index += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        mutating func unary() -> Double? {
            if peek == "-" {
                index += 1
                return unary().map { -$0 }
            }
            if peek == "+" {
                index += 1
                return unary()
            }
            return postfix()
        }

        mutating func postfix() -> Double? {
            guard var value = primary() else { return nil }
            if peek == "%" {
                index += 1
                value /= 100
            }
            return value
        }

        mutating func primary() -> Double? {
            guard let char = peek else { return nil }
            if char == "(" {
                index += 1
                guard let value = expression(), peek == ")" else { return nil }
                index += 1
                return value
            }
            if char.isNumber || char == "." {
                let start = index
                while let next = peek, next.isNumber || next == "." { index += 1 }
                return Double(String(chars[start..<index]))
            }
            if char.isLetter {
                let start = index
                while let next = peek, next.isLetter { index += 1 }
                let word = String(chars[start..<index])
                if word == "pi" { return .pi }
                if word == "e" { return M_E }
                if let function = functions[word], peek == "(" {
                    index += 1
                    guard let argument = expression(), peek == ")" else { return nil }
                    index += 1
                    return function(argument)
                }
                index = start
                return nil
            }
            return nil
        }

        mutating func matches(_ word: String) -> Bool {
            let letters = Array(word)
            guard index + letters.count <= chars.count, Array(chars[index..<index + letters.count]) == letters else { return false }
            index += letters.count
            return true
        }
    }

    // MARK: Units

    struct Unit {
        let names: [String]
        let dimension: String
        /// Factor to the dimension's base unit (temperatures use `toBase`/`fromBase`).
        let factor: Double
        var toBase: ((Double) -> Double)?
        var fromBase: ((Double) -> Double)?
    }

    nonisolated(unsafe) static let units: [Unit] = [
        Unit(names: ["mm"], dimension: "length", factor: 0.001), Unit(names: ["cm"], dimension: "length", factor: 0.01),
        Unit(names: ["m", "meter", "meters"], dimension: "length", factor: 1), Unit(names: ["km"], dimension: "length", factor: 1000),
        Unit(names: ["in", "inch", "inches"], dimension: "length", factor: 0.0254), Unit(names: ["ft", "foot", "feet"], dimension: "length", factor: 0.3048),
        Unit(names: ["yd", "yard", "yards"], dimension: "length", factor: 0.9144), Unit(names: ["mi", "mile", "miles"], dimension: "length", factor: 1609.344),
        Unit(names: ["g", "gram", "grams"], dimension: "mass", factor: 1), Unit(names: ["kg"], dimension: "mass", factor: 1000),
        Unit(names: ["lb", "lbs", "pound", "pounds"], dimension: "mass", factor: 453.59237), Unit(names: ["oz", "ounce", "ounces"], dimension: "mass", factor: 28.349523125),
        Unit(names: ["ml"], dimension: "volume", factor: 0.001), Unit(names: ["l", "liter", "liters"], dimension: "volume", factor: 1),
        Unit(names: ["gal", "gallon", "gallons"], dimension: "volume", factor: 3.785411784),
        Unit(names: ["b", "byte", "bytes"], dimension: "data", factor: 1), Unit(names: ["kb"], dimension: "data", factor: 1_000),
        Unit(names: ["mb"], dimension: "data", factor: 1_000_000), Unit(names: ["gb"], dimension: "data", factor: 1_000_000_000),
        Unit(names: ["tb"], dimension: "data", factor: 1_000_000_000_000), Unit(names: ["kib"], dimension: "data", factor: 1_024),
        Unit(names: ["mib"], dimension: "data", factor: 1_048_576), Unit(names: ["gib"], dimension: "data", factor: 1_073_741_824),
        Unit(names: ["ms"], dimension: "time", factor: 0.001), Unit(names: ["s", "sec", "seconds"], dimension: "time", factor: 1),
        Unit(names: ["min", "minutes"], dimension: "time", factor: 60), Unit(names: ["h", "hr", "hours"], dimension: "time", factor: 3600),
        Unit(names: ["d", "day", "days"], dimension: "time", factor: 86_400), Unit(names: ["week", "weeks"], dimension: "time", factor: 604_800),
        Unit(names: ["c", "celsius"], dimension: "temperature", factor: 1, toBase: { $0 }, fromBase: { $0 }),
        Unit(names: ["f", "fahrenheit"], dimension: "temperature", factor: 1, toBase: { ($0 - 32) * 5 / 9 }, fromBase: { $0 * 9 / 5 + 32 }),
        Unit(names: ["k", "kelvin"], dimension: "temperature", factor: 1, toBase: { $0 - 273.15 }, fromBase: { $0 + 273.15 }),
    ]

    static func unit(_ name: String) -> Unit? { units.first { $0.names.contains(name) } }

    /// "5 km in mi", "100f to c", "2.5 gb as mb".
    static func convertUnits(_ text: String) -> Result? {
        let pattern = #"^(-?[\d.]+)\s*([a-z]+)\s+(?:in|to|as)\s+([a-z]+)$"#
        guard let match = text.firstMatch(of: try! Regex(pattern)), match.count == 4,
            let amount = Double(String(match[1].substring ?? "")),
            let from = unit(String(match[2].substring ?? "")), let to = unit(String(match[3].substring ?? "")),
            from.dimension == to.dimension
        else { return nil }
        let base = from.toBase?(amount) ?? amount * from.factor
        let value = to.fromBase?(base) ?? base / to.factor
        let label = to.names.first ?? ""
        return Result(value: value, display: "\(format(value)) \(label)", copyText: plain(value))
    }
}
