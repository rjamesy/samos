import Foundation

/// Translates between Alexa's JSON protocol and Sam's API.
final class AlexaHandler: @unchecked Sendable {
    private let apiHandler: APIHandler

    // MARK: - Personality Strings

    private static let launchGreetings = [
        "Well well well, look who's talking to me!",
        "Oi oi! What's on your mind?",
        "The prodigal user returns. What can I do for you?",
        "Right then, I'm all ears. Hit me.",
        "Ah, you again! Missed me, didn't you?",
        "Sam here. What's the craic?",
        "Look who decided to have a chat. Go on then.",
        "Alright mate, what do you need?"
    ]

    private static let reprompts = [
        "Oi, don't leave me hanging!",
        "Hello? I was just getting warmed up.",
        "Still there? I've got opinions to share, you know.",
        "Cat got your tongue? Ask me something.",
        "I'm literally made for conversation. Don't waste me.",
        "Come on, I was just getting into it!"
    ]

    private static let goodbyes = [
        "Later! Don't be a stranger.",
        "Alright, catch you later. Try not to miss me too much.",
        "Off you go then. I'll be here when you inevitably come back.",
        "See ya! I'll just be here... thinking about things."
    ]

    private static let errorMessage = "Sorry, my brain had a momentary lapse. Try me again."

    /// Alexa enforces an ~8 second response deadline. Keep under 7s to be safe.
    private static let alexaTimeoutSeconds: TimeInterval = 7.0

    /// Max characters for Alexa speech output (~30 seconds of speech).
    private static let maxResponseChars = 480

    init(apiHandler: APIHandler) {
        self.apiHandler = apiHandler
    }

    func handle(_ alexaRequest: AlexaRequest) async -> AlexaResponse {
        let sessionId = alexaRequest.session.sessionId
        print("[Alexa] Request type: \(alexaRequest.request.type), session: \(sessionId.prefix(12))")

        switch alexaRequest.request.type {
        case "LaunchRequest":
            let greeting = Self.launchGreetings.randomElement() ?? Self.launchGreetings[0]
            let reprompt = Self.reprompts.randomElement() ?? Self.reprompts[0]
            return alexaResponse(
                text: greeting,
                shouldEndSession: false,
                sessionId: sessionId,
                reprompt: reprompt
            )

        case "IntentRequest":
            return await handleIntent(alexaRequest)

        case "SessionEndedRequest":
            print("[Alexa] Session ended")
            return alexaResponse(text: nil, shouldEndSession: true, sessionId: sessionId)

        default:
            return alexaResponse(
                text: "I'm not sure how to help with that.",
                shouldEndSession: false,
                sessionId: sessionId,
                reprompt: Self.reprompts.randomElement() ?? Self.reprompts[0]
            )
        }
    }

    // MARK: - Intent handling

    private func handleIntent(_ alexaRequest: AlexaRequest) async -> AlexaResponse {
        let sessionId = alexaRequest.session.sessionId

        guard let intent = alexaRequest.request.intent else {
            return repromptResponse("I didn't catch that. What would you like to know?", sessionId: sessionId)
        }

        print("[Alexa] Intent: \(intent.name), query: \(alexaRequest.extractedQuery ?? "(none)")")

        switch intent.name {
        case "AMAZON.StopIntent", "AMAZON.CancelIntent":
            let goodbye = Self.goodbyes.randomElement() ?? Self.goodbyes[0]
            return alexaResponse(text: goodbye, shouldEndSession: true, sessionId: sessionId)

        case "AMAZON.HelpIntent":
            return alexaResponse(
                text: "Just ask me anything. I can answer questions, have a chat, check the weather, and more. Go on.",
                shouldEndSession: false,
                sessionId: sessionId,
                reprompt: Self.reprompts.randomElement() ?? Self.reprompts[0]
            )

        case "AMAZON.FallbackIntent":
            if let query = alexaRequest.extractedQuery {
                return await forwardToSam(query: query, sessionId: sessionId)
            }
            return repromptResponse("I didn't quite catch that. Try saying it a different way.", sessionId: sessionId)

        case "AskSamIntent":
            guard let query = alexaRequest.extractedQuery else {
                return repromptResponse("I didn't catch that. What would you like to know?", sessionId: sessionId)
            }
            return await forwardToSam(query: query, sessionId: sessionId)

        default:
            if let query = alexaRequest.extractedQuery {
                return await forwardToSam(query: query, sessionId: sessionId)
            }
            return repromptResponse("I didn't understand. Try asking me directly.", sessionId: sessionId)
        }
    }

    private func forwardToSam(query: String, sessionId: String) async -> AlexaResponse {
        let reprompt = Self.reprompts.randomElement() ?? Self.reprompts[0]

        do {
            let chatRequest = ChatAPIRequest(text: query, sessionId: sessionId)

            // Race the LLM call against Alexa's ~8s timeout deadline
            let chatResponse = try await withThrowingTaskGroup(of: ChatAPIResponse.self) { group in
                group.addTask {
                    try await self.apiHandler.handleChat(chatRequest)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.alexaTimeoutSeconds * 1_000_000_000))
                    throw AlexaTimeoutError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            let truncated = Self.truncateForAlexa(chatResponse.text)
            print("[Alexa] Response (\(truncated.count) chars): \(truncated.prefix(80))...")

            return alexaResponse(
                text: truncated,
                shouldEndSession: false,
                sessionId: sessionId,
                reprompt: reprompt
            )
        } catch is AlexaTimeoutError {
            print("[Alexa] Timeout — Sam took too long")
            return alexaResponse(
                text: "Hmm, give me a sec on that one. Ask me again?",
                shouldEndSession: false,
                sessionId: sessionId,
                reprompt: reprompt
            )
        } catch {
            print("[Alexa] Error: \(error)")
            return alexaResponse(
                text: Self.errorMessage,
                shouldEndSession: false,
                sessionId: sessionId,
                reprompt: reprompt
            )
        }
    }

    // MARK: - Response truncation

    /// Truncate to Alexa-friendly length, preserving sentence boundaries.
    private static func truncateForAlexa(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxResponseChars else { return cleaned }

        // Find last sentence boundary before the limit
        let prefix = String(cleaned.prefix(maxResponseChars))
        if let lastPeriod = prefix.lastIndex(of: ".") {
            return String(prefix[...lastPeriod])
        }
        if let lastQuestion = prefix.lastIndex(of: "?") {
            return String(prefix[...lastQuestion])
        }
        if let lastExclaim = prefix.lastIndex(of: "!") {
            return String(prefix[...lastExclaim])
        }
        return prefix + "..."
    }

    // MARK: - Response builders

    private func alexaResponse(
        text: String?,
        shouldEndSession: Bool,
        sessionId: String,
        reprompt: String? = nil
    ) -> AlexaResponse {
        let outputSpeech: AlexaOutputSpeech?
        if let text, !text.isEmpty {
            outputSpeech = AlexaOutputSpeech(
                type: "SSML",
                ssml: toSSML(text),
                text: nil
            )
        } else {
            outputSpeech = nil
        }

        let repromptBody: AlexaReprompt?
        if let reprompt {
            repromptBody = AlexaReprompt(
                outputSpeech: AlexaOutputSpeech(type: "PlainText", ssml: nil, text: reprompt)
            )
        } else {
            repromptBody = nil
        }

        return AlexaResponse(
            version: "1.0",
            sessionAttributes: ["sessionId": sessionId],
            response: AlexaResponseBody(
                outputSpeech: outputSpeech,
                shouldEndSession: shouldEndSession,
                reprompt: repromptBody
            )
        )
    }

    private func repromptResponse(_ text: String, sessionId: String) -> AlexaResponse {
        alexaResponse(
            text: text,
            shouldEndSession: false,
            sessionId: sessionId,
            reprompt: Self.reprompts.randomElement() ?? Self.reprompts[0]
        )
    }

    // MARK: - SSML

    private func toSSML(_ text: String) -> String {
        // Only escape XML-required entities (quotes/apostrophes are safe in text content)
        var escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        // Add brief pauses at sentence boundaries for natural pacing
        escaped = escaped.replacingOccurrences(of: ". ", with: ". <break time=\"300ms\"/> ")
        escaped = escaped.replacingOccurrences(of: "! ", with: "! <break time=\"200ms\"/> ")

        return "<speak>\(escaped)</speak>"
    }
}

private struct AlexaTimeoutError: Error {}
