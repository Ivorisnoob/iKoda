import Foundation
import NaturalLanguage

/// How lyrics in another script are said, in Latin letters, as Music's Pronunciation shows
/// them under each line. All on the device, with Apple's own transliteration.
public enum LyricsRomanizer {
    /// The lyrics' main language ("ja", "ko", "hi"…), told from all their lines at once:
    /// one line of kanji alone can't say whether it is Japanese or Chinese, the song can.
    public static func language(of lines: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.joined(separator: "\n"))
        return recognizer.dominantLanguage?.rawValue
    }

    /// Whether any line is written in something other than Latin letters.
    public static func needsRomanization(_ lines: [String]) -> Bool {
        lines.contains(where: hasNonLatinLetters)
    }

    /// The line in Latin letters, or nil when it already is.
    public static func romanize(_ text: String, language: String?) -> String? {
        guard hasNonLatinLetters(text) else { return nil }
        let latin: String?
        if language == "ja" || text.unicodeScalars.contains(where: isKana) {
            latin = japanese(text)
        } else if language?.hasPrefix("zh") == true {
            // Pinyin keeps its tone marks, which are how it's said.
            latin = text.applyingTransform(.mandarinToLatin, reverse: false)
        } else {
            latin = text.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false)
        }
        guard let latin else { return nil }
        let tidy = latin.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return tidy.isEmpty || tidy == text ? nil : tidy
    }

    /// Japanese read word by word, so kanji are given their Japanese readings, not Chinese ones.
    private static func japanese(_ text: String) -> String? {
        let string = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(string))
        let tokenizer = CFStringTokenizerCreate(nil, string, range, kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        var words: [String] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if let reading = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                words.append(reading)
            } else if let original = CFStringCreateWithSubstring(nil, string, token) as String? {
                words.append(original.applyingTransform(.toLatin, reverse: false) ?? original)
            }
        }
        let joined = words.joined(separator: " ")
        return joined.applyingTransform(.stripDiacritics, reverse: false) ?? joined
    }

    private static func hasNonLatinLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic && !isLatin($0) }
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: true
        default: false
        }
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value)
    }
}
