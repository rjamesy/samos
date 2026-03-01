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
                return .error("Unauthorized", status: 401)
            }
        }

        print("[SamAPI] \(request.method) \(request.path) (\(request.body?.count ?? 0) bytes)")

        switch (request.method.uppercased(), request.path) {
        case ("POST", "/api/chat"):
            return await handleChatRequest(request)
        case ("POST", "/alexa"):
            return await handleAlexaRequest(request)
        case ("GET", "/health"):
            let body = try? JSONEncoder().encode(["status": "ok"])
            return .json(body ?? Data())
        default:
            return .error("Not found", status: 404)
        }
    }

    // MARK: - Chat endpoint

    private func handleChatRequest(_ request: APIRequest) async -> APIResponse {
        guard let body = request.body,
              let chatReq = try? JSONDecoder().decode(ChatAPIRequest.self, from: body) else {
            return .error("Invalid JSON body — expected {\"text\": \"...\", \"sessionId\": \"...\"}")
        }

        do {
            let response = try await handleChat(chatReq)
            let data = try JSONEncoder().encode(response)
            return .json(data)
        } catch {
            return .error("Turn failed: \(error.localizedDescription)", status: 500)
        }
    }

    func handleChat(_ request: ChatAPIRequest) async throws -> ChatAPIResponse {
        let sessionId = request.sessionId ?? UUID().uuidString
        let history = getHistory(for: sessionId)

        let result = try await orchestrator.processTurn(
            text: request.text,
            history: history,
            sessionId: sessionId
        )

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
            return .error("Alexa handler not configured", status: 500)
        }
        guard let body = request.body else {
            print("[SamAPI] Alexa: no request body")
            return .error("No request body")
        }
        let alexaReq: AlexaRequest
        do {
            alexaReq = try JSONDecoder().decode(AlexaRequest.self, from: body)
        } catch {
            print("[SamAPI] Alexa decode error: \(error)")
            print("[SamAPI] Alexa body: \(String(data: body.prefix(500), encoding: .utf8) ?? "non-utf8")")
            return .error("Invalid Alexa JSON: \(error.localizedDescription)")
        }

        let alexaResp = await handler.handle(alexaReq)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        guard let data = try? encoder.encode(alexaResp) else {
            return .error("Failed to encode Alexa response", status: 500)
        }
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
}
