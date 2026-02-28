import Foundation

/// Adaptive communication style based on user interaction patterns.
struct TonePreference: Sendable {
    var formality: Double = 0.3  // 0 = casual, 1 = formal
    var verbosity: Double = 0.3  // 0 = terse, 1 = verbose
    var humor: Double = 0.5      // 0 = serious, 1 = humorous
    var empathy: Double = 0.7    // 0 = detached, 1 = empathetic

    /// Generate tone instructions for the system prompt.
    func toneInstructions() -> String {
        var instructions: [String] = []

        if formality < 0.3 {
            instructions.append("Be casual and relaxed in tone.")
        } else if formality > 0.7 {
            instructions.append("Maintain a professional, measured tone.")
        }

        if verbosity < 0.3 {
            instructions.append("Keep responses very brief — a few words or one sentence when possible.")
        } else if verbosity > 0.7 {
            instructions.append("Feel free to elaborate and provide context.")
        }

        if humor > 0.6 {
            instructions.append("Light humor is welcome when appropriate.")
        }

        if empathy > 0.6 {
            instructions.append("Show emotional awareness and warmth.")
        }

        return instructions.isEmpty ? "" : instructions.joined(separator: " ")
    }
}
