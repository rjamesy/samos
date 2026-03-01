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
        log("AlexaHandler initialized")
    }

    // MARK: - Debug Logging

    private func log(_ message: String) {
        let ts = Self.timestamp()
        print("[Alexa \(ts)] \(message)")
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    // MARK: - Main entry point

    func handle(_ alexaRequest: AlexaRequest) async -> AlexaResponse {
        let sessionId = alexaRequest.session.sessionId
        let shortSession = String(sessionId.suffix(12))
        log(">>> REQUEST type=\(alexaRequest.request.type) session=\(shortSession) new=\(alexaRequest.session.new)")
        if let intent = alexaRequest.request.intent {
            log("    intent=\(intent.name) slots=\(intent.slots?.mapValues { $0.value ?? "(nil)" } ?? [:])")
        }

        let response: AlexaResponse

        switch alexaRequest.request.type {
        case "LaunchRequest":
            let greeting = Self.launchGreetings.randomElement() ?? Self.launchGreetings[0]
            let reprompt = Self.reprompts.randomElement() ?? Self.reprompts[0]
            log("    LaunchRequest -> greeting: \(greeting)")
            response = alexaResponse(
                text: greeting,
                shouldEndSession: false,
                sessionId: sessionId,
                reprompt: reprompt
            )

        case "IntentRequest":
            response = await handleIntent(alexaRequest)

        case "SessionEndedRequest":
            let reason = alexaRequest.request.reason ?? "(unknown)"
            log("    SessionEndedRequest reason=\(reason)")
            response = alexaResponse(text: nil, shouldEndSession: true, sessionId: sessionId)

        default:
            log("    Unknown request type: \(alexaRequest.request.type)")
            response = alexaResponse(
                text: "I'm not sure how to help with that. Try asking me something.",
                shouldEndSession: false,
                sessionId: sessionId,
                reprompt: Self.reprompts.randomElement() ?? Self.reprompts[0]
            )
        }

        log("<<< RESPONSE shouldEndSession=\(response.response.shouldEndSession) hasReprompt=\(response.response.reprompt != nil) speech=\(response.response.outputSpeech?.ssml?.prefix(100) ?? response.response.outputSpeech?.text?.prefix(100) ?? "(none)")")
        return response
    }

    // MARK: - Intent handling

    private func handleIntent(_ alexaRequest: AlexaRequest) async -> AlexaResponse {
        let sessionId = alexaRequest.session.sessionId

        guard let intent = alexaRequest.request.intent else {
            log("    No intent object in IntentRequest — reprompting")
            return repromptResponse("I didn't catch that. What would you like to know?", sessionId: sessionId)
        }

        let query = alexaRequest.extractedQuery
        log("    handleIntent: \(intent.name) query=\(query ?? "(none)")")

        switch intent.name {
        case "AMAZON.StopIntent", "AMAZON.CancelIntent":
            let goodbye = Self.goodbyes.randomElement() ?? Self.goodbyes[0]
            log("    Stop/Cancel -> goodbye: \(goodbye)")
            return alexaResponse(text: goodbye, shouldEndSession: true, sessionId: sessionId)

        case "AMAZON.HelpIntent":
            log("    Help intent")
            return alexaResponse(
                text: "Just ask me anything. I can answer questions, have a chat, check the weather, and more. Go on.",
                shouldEndSession: false,
                sessionId: sessionId,
                reprompt: Self.reprompts.randomElement() ?? Self.reprompts[0]
            )

        case "AMAZON.FallbackIntent":
            // FallbackIntent often has no slots — try to forward whatever we have
            if let query {
                log("    FallbackIntent WITH query -> forwarding: \(query)")
                return await forwardToSam(query: query, sessionId: sessionId)
            }
            // No slot data — Alexa couldn't parse anything. Ask user to rephrase but KEEP SESSION OPEN.
            log("    FallbackIntent NO query -> reprompting (session stays open)")
            return repromptResponse("I didn't quite catch that. Try saying it a different way.", sessionId: sessionId)

        case "AskSamIntent":
            guard let query else {
                log("    AskSamIntent but NO query slot -> reprompting")
                return repromptResponse("I didn't catch that. What would you like to know?", sessionId: sessionId)
            }
            log("    AskSamIntent -> forwarding: \(query)")
            return await forwardToSam(query: query, sessionId: sessionId)

        default:
            // Unknown intent — always try to forward to Sam
            if let query {
                log("    Unknown intent \(intent.name) WITH query -> forwarding: \(query)")
                return await forwardToSam(query: query, sessionId: sessionId)
            }
            log("    Unknown intent \(intent.name) NO query -> reprompting")
            return repromptResponse("I didn't understand. Try asking me directly.", sessionId: sessionId)
        }
    }

    private func forwardToSam(query: String, sessionId: String) async -> AlexaResponse {
        let reprompt = Self.reprompts.randomElement() ?? Self.reprompts[0]
        let start = Date()

        do {
            let chatRequest = ChatAPIRequest(text: query, sessionId: sessionId)
            log("    forwardToSam: sending to orchestrator...")

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

            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let truncated = Self.truncateForAlexa(chatResponse.text)
            log("    forwardToSam: got response in \(elapsed)ms (\(chatResponse.text.count) chars -> \(truncated.count) truncated)")
            log("    forwardToSam: text=\"\(truncated.prefix(200))\"")

            return alexaResponse(
                text: truncated,
                shouldEndSession: false,
                sessionId: sessionId,
                reprompt: reprompt
            )
        } catch is AlexaTimeoutError {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            log("    forwardToSam: TIMEOUT after \(elapsed)ms")
            return alexaResponse(
                text: "Hmm, give me a sec on that one. Ask me again?",
                shouldEndSession: false,
                sessionId: sessionId,
                reprompt: reprompt
            )
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            log("    forwardToSam: ERROR after \(elapsed)ms: \(error)")
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
            let ssml = toSSML(text)
            outputSpeech = AlexaOutputSpeech(
                type: "SSML",
                ssml: ssml,
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

        return "<speak><voice name=\"Joanna\">\(escaped)</voice></speak>"
    }
}

private struct AlexaTimeoutError: Error {}
