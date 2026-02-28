import Foundation

/// Decides what text to speak from a plan execution result.
/// Per ARCHITECTURE.md: talk entries win over tool entries.
struct SpeechCoordinator: Sendable {

    /// Select the best text to speak from a plan execution result.
    func selectSpeech(from result: PlanExecutionResult) -> String? {
        let text = result.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Split long text into TTS-friendly chunks.
    func chunkForTTS(_ text: String, maxChunkLength: Int = 500) -> [String] {
        guard text.count > maxChunkLength else { return [text] }

        var chunks: [String] = []
        var remaining = text

        while !remaining.isEmpty {
            if remaining.count <= maxChunkLength {
                chunks.append(remaining)
                break
            }

            // Find a sentence boundary near the max length
            let searchRange = remaining.prefix(maxChunkLength)
            if let lastPeriod = searchRange.lastIndex(of: ".") {
                let chunk = String(remaining[remaining.startIndex...lastPeriod])
                chunks.append(chunk)
                remaining = String(remaining[remaining.index(after: lastPeriod)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // No period found, split at max
                let chunk = String(remaining.prefix(maxChunkLength))
                chunks.append(chunk)
                remaining = String(remaining.dropFirst(maxChunkLength))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return chunks
    }
}
