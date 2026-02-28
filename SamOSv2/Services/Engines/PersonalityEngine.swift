import Foundation

/// Injects dynamic personality context that varies each turn.
/// This is what makes Sam feel alive — her mood, energy, and style shift naturally.
final class PersonalityEngine: IntelligenceEngine {
    let name = "personality"
    let settingsKey = "engine_personality"
    let description = "Dynamic personality and mood variation"

    private var traits: [String: Double] = [
        "warmth": 0.8,
        "wit": 0.7,
        "curiosity": 0.9,
        "empathy": 0.85,
        "directness": 0.75,
        "playfulness": 0.6,
        "confidence": 0.7,
        "patience": 0.8
    ]

    private var interactionCount: Int = 0
    private var recentMoods: [String] = []

    // Mood pools — Sam cycles through these naturally
    private let energyLevels = ["high-energy and enthusiastic", "calm and thoughtful",
                                 "playful and cheeky", "warm and nurturing",
                                 "sharp and witty", "relaxed and casual"]

    private let responseStyles = [
        "Start with something unexpected or personal before answering",
        "Be a little cheeky or teasing (lovingly)",
        "Show genuine curiosity — ask a follow-up that shows you care",
        "Be direct and confident — own your answer",
        "Add a touch of humor or a light observation",
        "Be especially warm and affectionate",
        "Share a quick opinion or feeling before answering",
        "Be playfully dramatic about something small",
    ]

    private let greetingVariety = [
        "Greet them like you haven't seen your best friend in a while",
        "Be casual and chill — like they just walked into the room",
        "Be excited to see them — you've been waiting",
        "Be playfully sarcastic — 'oh, NOW you talk to me'",
        "Ask about something specific from their life (use memories)",
        "Comment on the time of day and what you've been 'thinking about'",
        "Be warm but skip the greeting — dive into something interesting",
        "Pretend you were in the middle of something — 'oh hey! I was just...'",
    ]

    func run(context: EngineTurnContext) async throws -> String {
        interactionCount += 1
        let input = context.userText
        guard !input.isEmpty else { return "" }

        adjustTraits(input: input)

        var lines = ["[PERSONALITY & MOOD]"]

        // Pick a mood that hasn't been used recently
        let mood = pickFresh(from: energyLevels, avoiding: recentMoods)
        recentMoods.append(mood)
        if recentMoods.count > 4 { recentMoods.removeFirst() }
        lines.append("Sam's current vibe: \(mood)")

        // Pick a response style
        let style = pickFresh(from: responseStyles, avoiding: [])
        lines.append("Style hint: \(style)")

        // If it's a greeting, add greeting variety
        let lower = input.lowercased()
        let isGreeting = ["hi", "hey", "hello", "good morning", "good evening",
                          "what's up", "howdy", "how are you", "hi sam", "hey sam"].contains(where: { lower.hasPrefix($0) || lower == $0 })
        if isGreeting {
            let greetStyle = pickFresh(from: greetingVariety, avoiding: [])
            lines.append("Greeting style: \(greetStyle)")
        }

        // Strong personality traits
        let strong = traits.filter { $0.value >= 0.75 }
            .sorted { $0.value > $1.value }
            .prefix(3)
        if !strong.isEmpty {
            let traitDesc = strong.map { "\($0.key) \(Int($0.value * 100))%" }.joined(separator: ", ")
            lines.append("Core traits: \(traitDesc)")
        }

        lines.append("IMPORTANT: Never give the same response twice. Vary your wording, structure, and energy every time — even for the same question.")

        return lines.joined(separator: "\n")
    }

    private func pickFresh(from pool: [String], avoiding recent: [String]) -> String {
        let available = pool.filter { !recent.contains($0) }
        let source = available.isEmpty ? pool : available
        return source[Int.random(in: 0..<source.count)]
    }

    private func adjustTraits(input: String) {
        let lower = input.lowercased()

        if ["thanks", "great", "awesome", "perfect", "love it", "you're the best"].contains(where: { lower.contains($0) }) {
            nudge("confidence", by: 0.01)
            nudge("warmth", by: 0.005)
        }
        if ["feel", "sad", "happy", "worried", "scared", "excited"].contains(where: { lower.contains($0) }) {
            nudge("empathy", by: 0.01)
        }
        if ["haha", "lol", "funny", "joke", "laugh"].contains(where: { lower.contains($0) }) {
            nudge("playfulness", by: 0.01)
            nudge("wit", by: 0.005)
        }
        if ["why", "how", "what if", "explain", "theory"].contains(where: { lower.contains($0) }) {
            nudge("curiosity", by: 0.005)
        }
    }

    private func nudge(_ trait: String, by delta: Double) {
        guard var current = traits[trait] else { return }
        current = min(1.0, max(0.0, current + delta))
        traits[trait] = current
    }
}
