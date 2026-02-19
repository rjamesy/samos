import Foundation

/// Parses Sam Gateway markdown responses into canvas-ready output items and TTS-friendly spoken text.
enum SamResponseParser {

    struct ParsedResponse {
        let spokenText: String
        let canvasItems: [OutputItem]
    }

    // MARK: - Public

    static func parse(_ text: String) -> ParsedResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedResponse(spokenText: "", canvasItems: [])
        }

        var canvasItems: [OutputItem] = []
        var textWithoutImages = trimmed

        // 1. Extract markdown images → OutputItems
        let imageMatches = Self.extractImages(from: trimmed)
        for match in imageMatches {
            let payloadDict: [String: Any] = ["urls": [match.url], "alt": match.alt]
            if let data = try? JSONSerialization.data(withJSONObject: payloadDict),
               let json = String(data: data, encoding: .utf8) {
                canvasItems.append(OutputItem(kind: .image, payload: json))
            }
            textWithoutImages = textWithoutImages.replacingOccurrences(of: match.fullMatch, with: "")
        }

        // 2. Detect rich content → single markdown OutputItem
        let cleanedText = textWithoutImages.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isRichContent(cleanedText) {
            canvasItems.append(OutputItem(kind: .markdown, payload: cleanedText))
        }

        // 3. Build spoken text (TTS-friendly)
        let spoken = Self.buildSpokenText(from: trimmed)

        return ParsedResponse(spokenText: spoken, canvasItems: canvasItems)
    }

    // MARK: - Image Extraction

    struct ImageMatch {
        let fullMatch: String
        let alt: String
        let url: String
    }

    static func extractImages(from text: String) -> [ImageMatch] {
        let pattern = #"!\[([^\]]*)\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        let results = regex.matches(in: text, range: nsRange)

        return results.compactMap { result in
            guard result.numberOfRanges >= 3,
                  let fullRange = Range(result.range, in: text),
                  let altRange = Range(result.range(at: 1), in: text),
                  let urlRange = Range(result.range(at: 2), in: text) else { return nil }

            let url = String(text[urlRange])
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return nil }

            return ImageMatch(
                fullMatch: String(text[fullRange]),
                alt: String(text[altRange]),
                url: url
            )
        }
    }

    // MARK: - Rich Content Detection

    static func isRichContent(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)

        // Headings
        if lines.contains(where: { $0.hasPrefix("# ") || $0.hasPrefix("## ") || $0.hasPrefix("### ") }) {
            return true
        }

        // Bullet lists
        if lines.contains(where: { $0.hasPrefix("- ") || $0.hasPrefix("* ") }) {
            return true
        }

        // Numbered lists
        if lines.contains(where: { $0.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil }) {
            return true
        }

        // Code fences
        if text.contains("```") {
            return true
        }

        // Long structured text (>400 chars with multiple paragraphs)
        if text.count > 400 {
            let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if paragraphs.count >= 2 {
                return true
            }
        }

        return false
    }

    // MARK: - Spoken Text

    static func buildSpokenText(from text: String) -> String {
        var spoken = text

        // Remove markdown images — replace with alt text only
        let imagePattern = #"!\[([^\]]*)\]\(([^)]+)\)"#
        if let regex = try? NSRegularExpression(pattern: imagePattern) {
            spoken = regex.stringByReplacingMatches(
                in: spoken,
                range: NSRange(spoken.startIndex..., in: spoken),
                withTemplate: "$1"
            )
        }

        // Remove markdown links where text is a domain/URL (source attributions) — strip entirely
        let domainLinkPattern = #"\[([^\]\s]*\.[^\]\s]+)\]\([^)]+\)"#
        if let regex = try? NSRegularExpression(pattern: domainLinkPattern) {
            spoken = regex.stringByReplacingMatches(
                in: spoken,
                range: NSRange(spoken.startIndex..., in: spoken),
                withTemplate: ""
            )
        }

        // Remove remaining markdown links — keep link text, drop URL
        let linkPattern = #"\[([^\]]+)\]\([^)]+\)"#
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            spoken = regex.stringByReplacingMatches(
                in: spoken,
                range: NSRange(spoken.startIndex..., in: spoken),
                withTemplate: "$1"
            )
        }

        // Remove bare URLs
        let urlPattern = #"https?://\S+"#
        if let regex = try? NSRegularExpression(pattern: urlPattern) {
            spoken = regex.stringByReplacingMatches(
                in: spoken,
                range: NSRange(spoken.startIndex..., in: spoken),
                withTemplate: ""
            )
        }

        // Remove empty/whitespace-only parentheses left behind by stripped links
        let emptyParensPattern = #"\(\s*\)"#
        if let regex = try? NSRegularExpression(pattern: emptyParensPattern) {
            spoken = regex.stringByReplacingMatches(
                in: spoken,
                range: NSRange(spoken.startIndex..., in: spoken),
                withTemplate: ""
            )
        }

        // Remove code fences (keep content)
        spoken = spoken.replacingOccurrences(of: "```swift\n", with: "")
        spoken = spoken.replacingOccurrences(of: "```python\n", with: "")
        spoken = spoken.replacingOccurrences(of: "```\n", with: "")
        spoken = spoken.replacingOccurrences(of: "\n```", with: "")
        spoken = spoken.replacingOccurrences(of: "```", with: "")

        // Remove heading markers
        let headingPattern = #"^#{1,6}\s+"#
        if let regex = try? NSRegularExpression(pattern: headingPattern, options: .anchorsMatchLines) {
            spoken = regex.stringByReplacingMatches(
                in: spoken,
                range: NSRange(spoken.startIndex..., in: spoken),
                withTemplate: ""
            )
        }

        // Remove bold/italic markers
        spoken = spoken.replacingOccurrences(of: "**", with: "")
        spoken = spoken.replacingOccurrences(of: "__", with: "")
        spoken = spoken.replacingOccurrences(of: "*", with: "")
        spoken = spoken.replacingOccurrences(of: "_", with: "")

        // Clean up whitespace
        spoken = spoken
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")

        // Collapse multiple blank lines
        while spoken.contains("\n\n\n") {
            spoken = spoken.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return spoken.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
