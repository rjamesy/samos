import Foundation

/// Emotional affect detected from text.
enum Affect: String, Sendable {
    case neutral
    case happy
    case sad
    case frustrated
    case excited
    case anxious
    case curious
}

/// Detects emotional state from user text for tone adaptation.
struct AffectClassifier: Sendable {

    func classify(_ text: String) -> Affect {
        let lower = text.lowercased()

        // Simple keyword-based classification
        let happyWords = ["happy", "great", "awesome", "love", "excited", "wonderful", "amazing", "yay", "woohoo"]
        let sadWords = ["sad", "depressed", "down", "upset", "crying", "miss", "lonely", "heartbroken"]
        let frustratedWords = ["frustrated", "angry", "annoyed", "ugh", "damn", "stupid", "broken", "hate"]
        let excitedWords = ["omg", "wow", "incredible", "can't believe", "finally", "!!", "!!!"]
        let anxiousWords = ["worried", "nervous", "anxious", "scared", "afraid", "stressed", "overwhelmed"]
        let curiousWords = ["wonder", "curious", "interesting", "tell me", "explain", "how does"]

        if happyWords.contains(where: { lower.contains($0) }) { return .happy }
        if sadWords.contains(where: { lower.contains($0) }) { return .sad }
        if frustratedWords.contains(where: { lower.contains($0) }) { return .frustrated }
        if excitedWords.contains(where: { lower.contains($0) }) { return .excited }
        if anxiousWords.contains(where: { lower.contains($0) }) { return .anxious }
        if curiousWords.contains(where: { lower.contains($0) }) { return .curious }

        return .neutral
    }
}
