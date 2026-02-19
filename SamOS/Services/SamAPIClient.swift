import Foundation
import os.log

// MARK: - Reply Model

struct SamReply {
    let sessionId: String
    let replyText: String
    let latencyMs: Int
    let requestId: String
    let responseId: String
    let model: String
    let newSession: Bool
    let usage: [String: Int]
}

// MARK: - Errors

enum SamAPIError: Error, LocalizedError {
    case noGatewayURL
    case invalidURL
    case invalidResponse
    case httpError(status: Int, body: String)
    case invalidJSON
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .noGatewayURL: return "Sam gateway URL not configured"
        case .invalidURL: return "Invalid gateway URL"
        case .invalidResponse: return "Invalid HTTP response"
        case .httpError(let status, let body): return "HTTP \(status): \(body.prefix(200))"
        case .invalidJSON: return "Invalid JSON response"
        case .emptyReply: return "Empty reply from Sam"
        }
    }
}

// MARK: - Client

enum SamAPIClient {

    private static let logger = Logger(subsystem: "com.samos", category: "SamAPIClient")

    /// Send a message to the Sam gateway.
    /// - Parameters:
    ///   - sessionId: Existing session ID, or nil to create a new session.
    ///   - text: User text (typed or STT transcript).
    ///   - source: "typed" or "stt".
    ///   - confidence: STT confidence score if available.
    /// - Returns: SamReply with the assistant response.
    static func sendMessage(
        sessionId: String?,
        text: String,
        source: String = "typed",
        confidence: Double? = nil
    ) async throws -> SamReply {
        let rawURL = M2Settings.samGatewayURL
        guard !rawURL.isEmpty else { throw SamAPIError.noGatewayURL }

        // Force IPv4 to avoid noisy IPv6 connection-refused fallback in URLSession
        let gatewayURL = rawURL.replacingOccurrences(of: "://localhost", with: "://127.0.0.1")

        guard let url = URL(string: "\(gatewayURL)/v1/sam/message") else {
            throw SamAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body: [String: Any] = ["text": text]
        if let sid = sessionId { body["session_id"] = sid }

        var metadata: [String: Any] = [
            "source": source,
            "device": "macOS",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        ]
        if let conf = confidence { metadata["confidence"] = conf }
        body["metadata"] = metadata

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let clientStart = CFAbsoluteTimeGetCurrent()

        let (data, response) = try await URLSession.shared.data(for: request)

        let clientMs = Int((CFAbsoluteTimeGetCurrent() - clientStart) * 1000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SamAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            let bodyPreview = String(errorBody.prefix(200))
            logger.error("sam_api_error | status=\(httpResponse.statusCode, privacy: .public) | body=\(bodyPreview, privacy: .public)")
            throw SamAPIError.httpError(status: httpResponse.statusCode, body: errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SamAPIError.invalidJSON
        }

        let replyText = json["reply_text"] as? String ?? ""
        let serverLatencyMs = json["latency_ms"] as? Int ?? 0
        let trace = json["trace"] as? [String: Any] ?? [:]

        // Parse usage from trace
        var usage: [String: Int] = [:]
        if let usageDict = trace["usage"] as? [String: Any] {
            for (k, v) in usageDict {
                if let intVal = v as? Int { usage[k] = intVal }
            }
        }

        let modelName = json["model"] as? String ?? trace["model"] as? String ?? "unknown"

        let reply = SamReply(
            sessionId: json["session_id"] as? String ?? "",
            replyText: replyText,
            latencyMs: serverLatencyMs,
            requestId: trace["request_id"] as? String ?? "",
            responseId: trace["response_id"] as? String ?? "",
            model: modelName,
            newSession: trace["new_session"] as? Bool ?? false,
            usage: usage
        )

        let totalTokens = usage["total_tokens"] ?? 0
        logger.info(
            "sam_reply | session=\(reply.sessionId, privacy: .public) | model=\(reply.model, privacy: .public) | new=\(reply.newSession, privacy: .public) | server_ms=\(serverLatencyMs, privacy: .public) | client_ms=\(clientMs, privacy: .public) | reply_len=\(replyText.count, privacy: .public) | tokens=\(totalTokens, privacy: .public)"
        )

        return reply
    }
}
