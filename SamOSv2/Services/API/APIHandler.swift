import Foundation

/// Bridges HTTP API requests into the TurnOrchestrator pipeline.
final class APIHandler: @unchecked Sendable {
    private let orchestrator: TurnOrchestrator
    private let settings: any SettingsStoreProtocol

    // Session history: sessionId → messages, capped per session
    private var sessions: [String: SessionState] = [:]
    private let sessionsLock = NSLock()
    private let maxHistoryPerSession = 50
    private let sessionExpirySeconds: TimeInterval = 4 * 60 * 60 // 4 hours

    private struct SessionState {
        var history: [ChatMessage]
        var lastAccess: Date
    }

    init(orchestrator: TurnOrchestrator, settings: any SettingsStoreProtocol) {
        self.orchestrator = orchestrator
        self.settings = settings
    }

    // MARK: - Route incoming API requests

    func route(_ request: APIRequest) async -> APIResponse {
        // Auth check
        if let token = settings.string(forKey: SettingsKey.apiAuthToken), !token.isEmpty {
            let authHeader = request.headers["authorization"] ?? request.headers["Authorization"] ?? ""
            if authHeader != "Bearer \(token)" {
                log("AUTH FAILED for \(request.method) \(request.path)")
                return .error("Unauthorized", status: 401)
            }
        }

        log(">>> \(request.method) \(request.path) (\(request.body?.count ?? 0) bytes)")

        switch (request.method.uppercased(), request.path) {
        case ("POST", "/api/chat"):
            return await handleChatRequest(request)
        case ("POST", "/alexa"):
            return await handleAlexaRequest(request)
        case ("GET", "/health"):
            let body = try? JSONEncoder().encode(["status": "ok"])
            return .json(body ?? Data())
        default:
            log("404 Not Found: \(request.method) \(request.path)")
            return .error("Not found", status: 404)
        }
    }

    // MARK: - Chat endpoint

    private func handleChatRequest(_ request: APIRequest) async -> APIResponse {
        guard let body = request.body,
              let chatReq = try? JSONDecoder().decode(ChatAPIRequest.self, from: body) else {
            log("Chat: invalid JSON body")
            return .error("Invalid JSON body — expected {\"text\": \"...\", \"sessionId\": \"...\"}")
        }

        do {
            let response = try await handleChat(chatReq)
            let data = try JSONEncoder().encode(response)
            return .json(data)
        } catch {
            log("Chat: turn failed: \(error)")
            return .error("Turn failed: \(error.localizedDescription)", status: 500)
        }
    }

    func handleChat(_ request: ChatAPIRequest) async throws -> ChatAPIResponse {
        let sessionId = request.sessionId ?? UUID().uuidString
        let history = getHistory(for: sessionId)
        log("handleChat: session=\(sessionId.suffix(12)) historyCount=\(history.count) text=\"\(request.text.prefix(80))\"")

        let start = Date()
        let result = try await orchestrator.processTurn(
            text: request.text,
            history: history,
            sessionId: sessionId
        )
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)

        log("handleChat: response in \(elapsed)ms, \(result.sayText.count) chars, tools=\(result.toolCalls), memory=\(result.usedMemory)")

        // Append user + assistant messages to session history
        appendToHistory(sessionId: sessionId, userText: request.text, assistantText: result.sayText)

        return ChatAPIResponse(
            text: result.sayText,
            sessionId: sessionId,
            latencyMs: result.latencyMs,
            toolCalls: result.toolCalls.isEmpty ? nil : result.toolCalls
        )
    }

    // MARK: - Alexa endpoint (delegates to AlexaHandler)

    private var alexaHandler: AlexaHandler?

    func setAlexaHandler(_ handler: AlexaHandler) {
        self.alexaHandler = handler
    }

    private func handleAlexaRequest(_ request: APIRequest) async -> APIResponse {
        guard let handler = alexaHandler else {
            log("Alexa: handler not configured!")
            return .error("Alexa handler not configured", status: 500)
        }
        guard let body = request.body else {
            log("Alexa: no request body")
            return .error("No request body")
        }

        // Log raw body for debugging
        let bodyStr = String(data: body.prefix(1000), encoding: .utf8) ?? "(non-utf8)"
        log("Alexa raw body (\(body.count) bytes): \(bodyStr.prefix(300))")

        let alexaReq: AlexaRequest
        do {
            alexaReq = try JSONDecoder().decode(AlexaRequest.self, from: body)
        } catch {
            log("Alexa DECODE ERROR: \(error)")
            log("Alexa body: \(bodyStr)")
            // Return a valid Alexa response even on decode failure — never crash the session
            let fallback = AlexaResponse(
                version: "1.0",
                sessionAttributes: nil,
                response: AlexaResponseBody(
                    outputSpeech: AlexaOutputSpeech(type: "PlainText", ssml: nil, text: "Sorry, I had trouble understanding that request. Try again."),
                    shouldEndSession: false,
                    reprompt: AlexaReprompt(outputSpeech: AlexaOutputSpeech(type: "PlainText", ssml: nil, text: "I'm still here. What would you like to know?"))
                )
            )
            guard let fallbackData = try? JSONEncoder().encode(fallback) else {
                return .error("Failed to encode fallback response", status: 500)
            }
            return .json(fallbackData)
        }

        let alexaResp = await handler.handle(alexaReq)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        guard let data = try? encoder.encode(alexaResp) else {
            log("Alexa ENCODE ERROR — could not encode response")
            return .error("Failed to encode Alexa response", status: 500)
        }

        log("Alexa response: \(data.count) bytes, shouldEndSession=\(alexaResp.response.shouldEndSession)")
        return .json(data)
    }

    // MARK: - Session management

    private func getHistory(for sessionId: String) -> [ChatMessage] {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        pruneExpiredSessions()
        return sessions[sessionId]?.history ?? []
    }

    func appendToHistory(sessionId: String, userText: String, assistantText: String) {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }

        var state = sessions[sessionId] ?? SessionState(history: [], lastAccess: Date())
        state.history.append(ChatMessage(role: .user, text: userText))
        state.history.append(ChatMessage(role: .assistant, text: assistantText))

        // Cap history
        if state.history.count > maxHistoryPerSession {
            state.history = Array(state.history.suffix(maxHistoryPerSession))
        }
        state.lastAccess = Date()
        sessions[sessionId] = state
    }

    private func pruneExpiredSessions() {
        let now = Date()
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastAccess) < sessionExpirySeconds }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        print("[SamAPI \(f.string(from: Date()))] \(message)")
    }
}
