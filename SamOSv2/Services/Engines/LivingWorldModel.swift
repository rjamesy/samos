import Foundation

/// Maintains an entity/relationship graph from conversation context.
/// Tracks people, places, things, and their relationships.
final class LivingWorldModel: IntelligenceEngine {
    let name = "world_model"
    let settingsKey = "engine_world_model"
    let description = "Entity and relationship graph from conversation"

    private var entities: [String: EntityInfo] = [:]

    func run(context: EngineTurnContext) async throws -> String {
        let input = context.userText
        guard !input.isEmpty else { return "" }

        // Extract entity mentions from recent conversation
        extractEntities(from: input)

        // Build context block with relevant entities
        let relevant = entities.values
            .sorted { $0.lastMentioned > $1.lastMentioned }
            .prefix(5)

        guard !relevant.isEmpty else { return "" }

        var lines = ["[WORLD MODEL]"]
        for entity in relevant {
            var desc = "- \(entity.name) (\(entity.type))"
            if !entity.attributes.isEmpty {
                desc += ": " + entity.attributes.joined(separator: ", ")
            }
            lines.append(desc)
        }
        return lines.joined(separator: "\n")
    }

    private func extractEntities(from text: String) {
        // Simple entity extraction based on patterns
        let words = text.split(separator: " ").map(String.init)

        // Detect capitalized words as potential entity names (simplified)
        for (i, word) in words.enumerated() {
            let clean = word.trimmingCharacters(in: .punctuationCharacters)
            guard clean.first?.isUppercase == true,
                  clean.count > 1,
                  !isCommonWord(clean) else { continue }

            if entities[clean] != nil {
                entities[clean]?.lastMentioned = Date()
                entities[clean]?.mentionCount += 1
            } else {
                let type = guessEntityType(clean, context: words, index: i)
                entities[clean] = EntityInfo(name: clean, type: type, lastMentioned: Date())
            }
        }
    }

    private func guessEntityType(_ name: String, context: [String], index: Int) -> String {
        let prev = index > 0 ? context[index - 1].lowercased() : ""
        if ["mr", "mrs", "ms", "dr", "my"].contains(prev) { return "person" }
        if ["in", "at", "from", "near", "to"].contains(prev) { return "place" }
        return "entity"
    }

    private func isCommonWord(_ word: String) -> Bool {
        let common: Set = ["I", "The", "This", "That", "What", "When", "Where", "Who",
                           "How", "Why", "Can", "Could", "Would", "Should", "Do", "Does",
                           "Is", "Are", "Was", "Were", "Have", "Has", "Will", "Not", "And",
                           "But", "Or", "If", "Then", "So", "My", "Your", "His", "Her"]
        return common.contains(word)
    }
}

private struct EntityInfo {
    let name: String
    let type: String
    var attributes: [String] = []
    var lastMentioned: Date
    var mentionCount: Int = 1
}
