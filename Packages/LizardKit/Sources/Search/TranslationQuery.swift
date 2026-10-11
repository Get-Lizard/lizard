import Foundation

/// Spots a translation request typed into the launcher: "good morning in spanish",
/// "hello to japanese", "obrigado em inglês", "tr thank you" (to your usual language).
public struct TranslationQuery: Sendable, Equatable {
    public let text: String
    /// BCP-47 language code to translate into; nil means "your usual target".
    public let target: String?

    public static func parse(_ query: String, locale: Locale = .current) -> TranslationQuery? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        for prefix in ["tr ", "translate "] where lower.hasPrefix(prefix) {
            let rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            // "translate hello to french" names the language too.
            return parse(rest, locale: locale).map { $0 } ?? TranslationQuery(text: rest, target: nil)
        }
        // "<text> in|to|into|em|para|en|auf|in <language>": the last connector wins.
        for connector in [" into ", " in ", " to ", " em ", " para ", " en ", " auf "] {
            guard let range = lower.range(of: connector, options: .backwards) else { continue }
            let text = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let name = String(lower[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= 500, let code = languageCode(named: name, locale: locale) else { continue }
            return TranslationQuery(text: text, target: code)
        }
        return nil
    }

    /// "spanish", "español", "espanhol", "Japanese" → "es"/"ja". Two-letter languages only (the
    /// ones Apple Translation and people actually name).
    public static func languageCode(named name: String, locale: Locale = .current) -> String? {
        let wanted = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard wanted.count >= 3 else { return nil }
        if let cached = names[wanted] { return cached }
        let displayLocales = [Locale(identifier: "en"), locale]
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) where code.count == 2 {
            var candidates = displayLocales.compactMap { $0.localizedString(forLanguageCode: code) }
            if let native = Locale(identifier: code).localizedString(forLanguageCode: code) { candidates.append(native) }
            if candidates.contains(where: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == wanted }) {
                return code
            }
        }
        return nil
    }

    /// Common names that don't match a locale display name exactly.
    private static let names: [String: String] = [
        "chinese": "zh", "mandarin": "zh", "brazilian": "pt", "portugues": "pt", "ingles": "en", "espanhol": "es",
        "frances": "fr", "alemao": "de", "italiano": "it", "japones": "ja", "persian": "fa", "farsi": "fa",
    ]
}
