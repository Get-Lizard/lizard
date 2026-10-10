import CryptoKit
import Foundation

public enum TransformError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// Everyday developer text conversions. Pure functions, so they're trivially testable.
public enum TextTransform: String, CaseIterable, Sendable, Identifiable {
    case jsonPretty, jsonMinify, jsonSortKeys, jwtDecode, base64Encode, base64Decode, urlEncode, urlDecode
    case uuid, timestamp, md5, sha1, sha256, camelCase, snakeCase, kebabCase, titleCase, upperCase, lowerCase
    case count, htmlEncode, htmlDecode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .jsonPretty: "Format JSON"
        case .jsonMinify: "Minify JSON"
        case .jsonSortKeys: "Sort JSON Keys"
        case .jwtDecode: "Decode JWT"
        case .base64Encode: "Base64 Encode"
        case .base64Decode: "Base64 Decode"
        case .urlEncode: "URL Encode"
        case .urlDecode: "URL Decode"
        case .uuid: "Generate UUID"
        case .timestamp: "Convert Timestamp"
        case .md5: "MD5 Hash"
        case .sha1: "SHA-1 Hash"
        case .sha256: "SHA-256 Hash"
        case .camelCase: "camelCase"
        case .snakeCase: "snake_case"
        case .kebabCase: "kebab-case"
        case .titleCase: "Title Case"
        case .upperCase: "UPPERCASE"
        case .lowerCase: "lowercase"
        case .count: "Count Characters & Words"
        case .htmlEncode: "HTML Encode"
        case .htmlDecode: "HTML Decode"
        }
    }

    public var symbol: String {
        switch self {
        case .jsonPretty, .jsonMinify, .jsonSortKeys: "curlybraces"
        case .jwtDecode: "key"
        case .base64Encode, .base64Decode: "64.square"
        case .urlEncode, .urlDecode: "link"
        case .uuid: "number"
        case .timestamp: "clock"
        case .md5, .sha1, .sha256: "number.square"
        case .count: "textformat.123"
        case .htmlEncode, .htmlDecode: "chevron.left.slash.chevron.right"
        default: "textformat"
        }
    }

    public func apply(_ input: String, now: Date = .now) throws -> String {
        switch self {
        case .jsonPretty: return try Self.json(input, options: [.prettyPrinted, .withoutEscapingSlashes])
        case .jsonMinify: return try Self.json(input, options: [.withoutEscapingSlashes])
        case .jsonSortKeys: return try Self.json(input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        case .jwtDecode: return try Self.decodeJWT(input)
        case .base64Encode: return Data(input.utf8).base64EncodedString()
        case .base64Decode:
            guard let data = Self.base64Data(input), let text = String(data: data, encoding: .utf8) else { throw TransformError.invalid("Not valid Base64 text.") }
            return text
        case .urlEncode:
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&+=?#/:")
            return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
        case .urlDecode: return input.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? input
        case .uuid: return UUID().uuidString.lowercased()
        case .timestamp: return try Self.timestamp(input, now: now)
        case .md5: return Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        case .sha1: return Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        case .sha256: return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        case .camelCase:
            let words = Self.words(input)
            return (words.first?.lowercased() ?? "") + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
        case .snakeCase: return Self.words(input).map { $0.lowercased() }.joined(separator: "_")
        case .kebabCase: return Self.words(input).map { $0.lowercased() }.joined(separator: "-")
        case .titleCase: return Self.words(input).map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        case .upperCase: return input.uppercased()
        case .lowerCase: return input.lowercased()
        case .count:
            let words = input.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let lines = input.isEmpty ? 0 : input.split(separator: "\n", omittingEmptySubsequences: false).count
            return "\(input.count) characters · \(words) words · \(lines) lines · \(input.utf8.count) bytes"
        case .htmlEncode:
            return input.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        case .htmlDecode:
            var text = input
            for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
                text = text.replacingOccurrences(of: entity, with: value)
            }
            return text
        }
    }

    /// Whether this transform needs input text.
    public var needsInput: Bool { self != .uuid }

    static func json(_ input: String, options: JSONSerialization.WritingOptions) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed]) else {
            throw TransformError.invalid("Not valid JSON.")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: options.union(.fragmentsAllowed))
        return String(decoding: data, as: UTF8.self)
    }

    static func base64Data(_ input: String) -> Data? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    /// Header and payload as pretty JSON, with exp/iat/nbf as dates. The signature is NOT verified.
    static func decodeJWT(_ input: String) throws -> String {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "Bearer ", with: "").split(separator: ".")
        guard parts.count >= 2, let header = base64Data(String(parts[0])), let payload = base64Data(String(parts[1])) else {
            throw TransformError.invalid("Not a JWT (expected header.payload.signature).")
        }
        func pretty(_ data: Data) throws -> String {
            try json(String(decoding: data, as: UTF8.self), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        var lines = ["Header:", try pretty(header), "", "Payload:", try pretty(payload)]
        if let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            let formatter = ISO8601DateFormatter()
            let dates = ["iat": "Issued", "nbf": "Not before", "exp": "Expires"].compactMap { key, label -> String? in
                guard let value = claims[key] as? Double else { return nil }
                return "\(label): \(formatter.string(from: Date(timeIntervalSince1970: value)))"
            }
            if !dates.isEmpty { lines += [""] + dates.sorted() }
        }
        lines += ["", "Signature not verified."]
        return lines.joined(separator: "\n")
    }

    /// Unix seconds or milliseconds ↔ ISO-8601. Empty input → now.
    static func timestamp(_ input: String, now: Date) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        if text.isEmpty {
            return "\(Int(now.timeIntervalSince1970))\n\(iso.string(from: now))"
        }
        if let number = Double(text) {
            let seconds = number > 100_000_000_000 ? number / 1000 : number
            let date = Date(timeIntervalSince1970: seconds)
            let local = DateFormatter()
            local.dateStyle = .full
            local.timeStyle = .long
            return "\(iso.string(from: date))\n\(local.string(from: date))"
        }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
            return "\(Int(date.timeIntervalSince1970))\n\(Int(date.timeIntervalSince1970 * 1000)) ms"
        }
        throw TransformError.invalid("Enter a Unix timestamp or an ISO-8601 date.")
    }

    /// Splits "someHTTPValue_with-mixed Words" into words.
    static func words(_ input: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(input)
        for (index, character) in characters.enumerated() {
            if !character.isLetter && !character.isNumber {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if character.isUppercase, !current.isEmpty {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && next?.isLowercase == true) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
