import Foundation

/// Normalizes LLM output text for display — unescapes literal \n, \t,
/// and unicode sequences so markdown renders with real line breaks.
/// Does NOT strip valid markdown symbols (#, -, 1., *, etc.).
enum TextUnescaper {
    private static let unicodeEscapeRegex = try! NSRegularExpression(pattern: "\\\\u([0-9a-fA-F]{4})")

    /// Converts single newlines to paragraph breaks so CommonMark renders
    /// each line as a separate block. LLMs use single \n between lines,
    /// which standard markdown collapses to spaces within a paragraph.
    static func ensureParagraphBreaks(_ s: String) -> String {
        s.replacingOccurrences(
            of: "(?<!\n)\n(?!\n)",
            with: "\n\n",
            options: .regularExpression
        )
    }

    static func normalizeLLMText(_ s: String) -> String {
        var text = s

        // Step 1: Replace literal two-char escape sequences
        // (e.g. the LLM printed the characters \ and n, not an actual newline)
        text = text.replacingOccurrences(of: "\\r\\n", with: "\n")
        text = text.replacingOccurrences(of: "\\n", with: "\n")
        text = text.replacingOccurrences(of: "\\t", with: "    ")

        // Step 2: Decode unicode escapes (\u00e9 → é)
        text = decodeUnicodeEscapes(text)

        // Step 3: Normalize CRLF → LF
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        return text
    }

    /// Replaces literal \uXXXX sequences with the corresponding Unicode character.
    private static func decodeUnicodeEscapes(_ s: String) -> String {
        let nsString = s as NSString
        let range = NSRange(location: 0, length: nsString.length)
        var result = s
        // Process matches in reverse order to preserve indices
        let matches = unicodeEscapeRegex.matches(in: s, range: range)
        for match in matches.reversed() {
            let hexRange = match.range(at: 1)
            let hex = nsString.substring(with: hexRange)
            if let codePoint = UInt32(hex, radix: 16),
               let scalar = Unicode.Scalar(codePoint) {
                let char = String(scalar)
                let fullRange = Range(match.range, in: result)!
                result.replaceSubrange(fullRange, with: char)
            }
        }
        return result
    }
}
