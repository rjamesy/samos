import Foundation

/// Context passed to intelligence engines each turn.
struct EngineTurnContext: Sendable {
    let userText: String
    let assistantText: String
    let turnId: String
    let sessionId: String
    let timestamp: Date

    init(
        userText: String,
        assistantText: String,
        turnId: String = UUID().uuidString,
        sessionId: String = "",
        timestamp: Date = Date()
    ) {
        self.userText = userText
        self.assistantText = assistantText
        self.turnId = turnId
        self.sessionId = sessionId
        self.timestamp = timestamp
    }
}

/// Protocol for intelligence engines that run after each turn.
protocol IntelligenceEngine: Sendable {
    var name: String { get }
    var settingsKey: String { get }
    func run(context: EngineTurnContext) async throws -> String
}
