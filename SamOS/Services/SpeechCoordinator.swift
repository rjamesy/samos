import Foundation

enum SpeechLineSource {
    case talk
    case tool
    case prompt
}

struct SpeechLineEntry {
    let text: String
    let source: SpeechLineSource
}

struct SpeechDecision: Equatable {
    let spokenLines: [String]
    let wasCondensed: Bool
}

@MainActor
protocol SpeechLineSelecting {
    func selectSpeechDecision(entries: [SpeechLineEntry],
                              toolProducedUserFacingOutput: Bool,
                              maxSpeakChars: Int) -> SpeechDecision
    func selectSpokenLines(entries: [SpeechLineEntry],
                           toolProducedUserFacingOutput: Bool,
                           maxSpeakChars: Int) -> [String]
}

extension SpeechLineSelecting {
    func selectSpokenLines(entries: [SpeechLineEntry],
                           toolProducedUserFacingOutput: Bool,
                           maxSpeakChars: Int) -> [String] {
        selectSpeechDecision(
            entries: entries,
            toolProducedUserFacingOutput: toolProducedUserFacingOutput,
            maxSpeakChars: maxSpeakChars
        ).spokenLines
    }
}

@MainActor
protocol TurnSpeechCoordinating: SpeechLineSelecting {
    func beginTurn()
    func consumeThinkingFillerIfAllowed(isTTSSpeaking: Bool,
                                        isCapturing: Bool,
                                        enforceStrictPhases: Bool,
                                        isRoutingPhase: Bool) -> String?
    func clearSlowStartTracking()
    func recordSlowStart(correlationID: String)
    var lastSlowStartCorrelationID: String? { get }
}

@MainActor
final class SpeechCoordinator: TurnSpeechCoordinating {
    static let shared = SpeechCoordinator()

    private var thinkingFillerSpokenThisTurn = false
    private var thinkingFillerIndex = 0
    private(set) var lastSlowStartCorrelationID: String?

    private let thinkingFillers = [
        "One sec.",
        "Hmm.",
        "Just a moment.",
        "Working on it.",
        "Okay, one sec."
    ]

    func beginTurn() {
        thinkingFillerSpokenThisTurn = false
    }

    func consumeThinkingFillerIfAllowed(isTTSSpeaking: Bool,
                                        isCapturing: Bool,
                                        enforceStrictPhases: Bool,
                                        isRoutingPhase: Bool) -> String? {
        guard !thinkingFillerSpokenThisTurn else { return nil }
        guard !isTTSSpeaking else { return nil }
        guard !isCapturing else { return nil }
        if enforceStrictPhases && isRoutingPhase {
            return nil
        }

        thinkingFillerSpokenThisTurn = true
        guard !thinkingFillers.isEmpty else { return "One sec." }
        let value = thinkingFillers[thinkingFillerIndex % thinkingFillers.count]
        thinkingFillerIndex = (thinkingFillerIndex + 1) % thinkingFillers.count
        return value
    }

    func clearSlowStartTracking() {
        lastSlowStartCorrelationID = nil
    }

    func recordSlowStart(correlationID: String) {
        lastSlowStartCorrelationID = correlationID
    }

    func selectSpokenLines(entries: [SpeechLineEntry],
                           toolProducedUserFacingOutput: Bool,
                           maxSpeakChars: Int) -> [String] {
        selectSpeechDecision(
            entries: entries,
            toolProducedUserFacingOutput: toolProducedUserFacingOutput,
            maxSpeakChars: maxSpeakChars
        ).spokenLines
    }

    func selectSpeechDecision(entries: [SpeechLineEntry],
                              toolProducedUserFacingOutput: Bool,
                              maxSpeakChars: Int) -> SpeechDecision {
        guard !entries.isEmpty else { return SpeechDecision(spokenLines: [], wasCondensed: false) }
        let cappedChars = max(120, min(maxSpeakChars, 200))

        func pickToolEntry() -> String? {
            entries.last(where: { $0.source == .tool || $0.source == .prompt })?.text
        }

        func pickTalkEntry() -> String? {
            entries.last(where: { $0.source == .talk && !containsUnresolvedTemplateToken($0.text) })?.text
        }

        let selected: String
        if toolProducedUserFacingOutput, let toolText = pickToolEntry() {
            selected = toolText
        } else if let talkText = pickTalkEntry() {
            selected = talkText
        } else {
            selected = entries.last?.text ?? ""
        }

        let condensed = condensedSpeechLine(selected, maxChars: cappedChars)
        guard !condensed.text.isEmpty else {
            return SpeechDecision(spokenLines: [], wasCondensed: false)
        }
        return SpeechDecision(spokenLines: [condensed.text], wasCondensed: condensed.wasCondensed)
    }

    private func condensedSpeechLine(_ text: String, maxChars: Int) -> (text: String, wasCondensed: Bool) {
        let cleaned = stripMarkdownForSpeech(stripPlaceholderTokens(text))
        guard !cleaned.isEmpty else { return ("", false) }
        guard cleaned.count > maxChars else { return (cleaned, false) }
        let suffix = " ... I've shown the full details on screen."
        let availableChars = max(0, maxChars - suffix.count)
        guard availableChars >= 24 else { return ("I've shown the full details on screen.", true) }
        let prefix = String(cleaned.prefix(availableChars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return ("I've shown the full details on screen.", true) }
        return ("\(prefix)\(suffix)", true)
    }

    private func stripPlaceholderTokens(_ text: String) -> String {
        let removedTokens = text.replacingOccurrences(
            of: #"\{[A-Za-z0-9_]+\}"#,
            with: " ",
            options: .regularExpression
        )
        return removedTokens
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripMarkdownForSpeech(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)^\s*\d+[\.)]\s+"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[*_>#]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsUnresolvedTemplateToken(_ text: String) -> Bool {
        text.range(of: #"\{[A-Za-z0-9_]+\}"#, options: .regularExpression) != nil
    }
}
