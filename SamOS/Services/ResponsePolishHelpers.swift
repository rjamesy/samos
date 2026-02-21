import Foundation

extension TurnOrchestrator: TurnOrchestrating {}

struct TTSPacing {
    let preSpeakDelayMs: Int
    let ttsText: String

    var preSpeakDelayNs: UInt64 {
        UInt64(max(0, preSpeakDelayMs)) * 1_000_000
    }
}

enum ResponsePolish {

    private static let uncertaintyMarkers: [String] = [
        "i think", "maybe", "not sure", "likely", "might", "could be", "approximately",
        "can't confirm", "cannot confirm", "i don't have access", "unknown"
    ]

    private static let strongHedges: [String] = [
        "i'm not 100% sure", "i am not 100% sure", "not sure", "maybe", "i think"
    ]

    private static let memoryAckMarkers: [String] = [
        "i remember you mentioned", "i remember you said", "if i'm remembering right",
        "if i’m remembering right", "i recall you mentioned", "as you mentioned earlier",
        "you mentioned earlier"
    ]

    static func applyConfidenceModulation(to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard isUncertain(trimmed) else { return text }
        guard !isStronglyHedged(trimmed) else { return text }
        guard !trimmed.lowercased().contains("double-check") else { return text }
        return "\(trimmed) (If you want, I can double-check.)"
    }

    static func ttsPacing(for text: String, mode: SpeechMode) -> TTSPacing {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, mode == .answer else {
            return TTSPacing(preSpeakDelayMs: 0, ttsText: trimmed)
        }

        let longResponse = trimmed.count > 120 || sentenceCount(in: trimmed) >= 3
        guard longResponse else {
            return TTSPacing(preSpeakDelayMs: 0, ttsText: trimmed)
        }

        return TTSPacing(preSpeakDelayMs: 250, ttsText: addSentencePauses(to: trimmed))
    }

    static func containsMemoryAcknowledgement(_ text: String) -> Bool {
        let firstSentence = leadingSentence(text).lowercased()
        return memoryAckMarkers.contains { firstSentence.contains($0) }
    }

    static func stripLeadingMemoryAcknowledgement(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard containsMemoryAcknowledgement(trimmed) else { return trimmed }

        if let punctuationRange = trimmed.range(of: #"[.!?]\s+"#, options: .regularExpression) {
            let remainder = String(trimmed[punctuationRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? trimmed : remainder
        }
        return trimmed
    }

    static func stripQuickDetailedPrompt(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let patterns = [
            #"\s*want\s+the\s+quick\s+version\s+or\s+more\s+detail\??\s*$"#,
            #"\s*want\s+me\s+to\s+keep\s+it\s+brief\s+or\s+expand\??\s*$"#,
            #"\s*quick\s+version\s+or\s+detailed?\s+version\??\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            let stripped = regex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped != trimmed {
                return stripped
            }
        }
        return trimmed
    }

    static func stripAutoClosePrompt(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let patterns = [
            #"\s*(anything\s+else\s+i\s+can\s+help\s+with\??)\s*$"#,
            #"\s*(anything\s+else\s+you(?:'d|\s+would)?\s+like\s+to\s+know\??)\s*$"#,
            #"\s*(let\s+me\s+know\s+if\s+you\s+need\s+anything\s+else\.?)\s*$"#,
            #"\s*(let\s+me\s+know\s+if\s+you(?:'d|\s+would)?\s+like\s+to\s+know\s+more\.?)\s*$"#,
            #"\s*(how\s+else\s+can\s+i\s+help\??)\s*$"#,
            #"\s*(need\s+anything\s+else\s+on\s+this\??)\s*$"#,
            #"\s*(want\s+me\s+to\s+continue\s+on\s+this\??)\s*$"#,
            #"\s*(should\s+i\s+add\s+anything\s+else\??)\s*$"#,
            #"\s*(what\s+else\s+can\s+i\s+help\s+with\??)\s*$"#,
            #"\s*((?:want|would\s+you\s+like)\s+to\s+know\s+more\??)\s*$"#
        ]

        var output = trimmed
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if output.isEmpty {
            return "Done."
        }
        return output
    }

    private static func isUncertain(_ text: String) -> Bool {
        let lower = text.lowercased()
        return uncertaintyMarkers.contains { lower.contains($0) }
    }

    private static func isStronglyHedged(_ text: String) -> Bool {
        let lower = text.lowercased()
        return strongHedges.contains { lower.contains($0) }
    }

    private static func leadingSentence(_ text: String) -> String {
        if let punctuationRange = text.range(of: #"[.!?]\s+"#, options: .regularExpression) {
            return String(text[..<punctuationRange.lowerBound])
        }
        return text
    }

    private static func sentenceCount(in text: String) -> Int {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.count
    }

    private static func addSentencePauses(to text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"([.!?])\s+"#, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1\n")
    }
}
