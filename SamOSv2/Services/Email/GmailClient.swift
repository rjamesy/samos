import Foundation

/// Gmail API HTTP client for email operations.
final class GmailClient: @unchecked Sendable {
    private let authService: GoogleAuthService
    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"

    init(authService: GoogleAuthService) {
        self.authService = authService
    }

    /// Fetch recent messages from inbox.
    func fetchInbox(maxResults: Int = 10) async throws -> [GmailMessage] {
        let token = try await authService.getAccessToken()
        let url = URL(string: "\(baseURL)/messages?maxResults=\(maxResults)&labelIds=INBOX")!

        var request = URLRequest(url: url)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageList = json["messages"] as? [[String: String]] else {
            return []
        }

        var messages: [GmailMessage] = []
        for item in messageList.prefix(maxResults) {
            if let id = item["id"] {
                if let msg = try await fetchMessage(id: id, token: token) {
                    messages.append(msg)
                }
            }
        }
        return messages
    }

    /// Fetch a single message by ID.
    func fetchMessage(id: String, token: String? = nil) async throws -> GmailMessage? {
        let accessToken: String
        if let token {
            accessToken = token
        } else {
            accessToken = try await authService.getAccessToken()
        }
        let url = URL(string: "\(baseURL)/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date")!

        var request = URLRequest(url: url)
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let headers = (json["payload"] as? [String: Any])?["headers"] as? [[String: String]] ?? []
        let subject = headers.first { $0["name"] == "Subject" }?["value"] ?? "(no subject)"
        let from = headers.first { $0["name"] == "From" }?["value"] ?? "Unknown"
        let snippet = json["snippet"] as? String ?? ""

        return GmailMessage(id: id, from: from, subject: subject, snippet: snippet)
    }

    /// Trash a message.
    func trashMessage(id: String) async throws {
        let token = try await authService.getAccessToken()
        let url = URL(string: "\(baseURL)/messages/\(id)/trash")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)
    }

    /// Mark a message as read.
    func markAsRead(id: String) async throws {
        let token = try await authService.getAccessToken()
        let url = URL(string: "\(baseURL)/messages/\(id)/modify")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["removeLabelIds": ["UNREAD"]])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)
    }

    /// Send a reply to a message.
    func sendReply(to: String, subject: String, body: String, threadId: String? = nil) async throws {
        let token = try await authService.getAccessToken()
        let url = URL(string: "\(baseURL)/messages/send")!

        let raw = "To: \(to)\r\nSubject: \(subject)\r\n\r\n\(body)"
        let encoded = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")

        var messageBody: [String: Any] = ["raw": encoded]
        if let threadId { messageBody["threadId"] = threadId }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: messageBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailError.apiError(msg)
        }
    }
}

struct GmailMessage: Sendable {
    let id: String
    let from: String
    let subject: String
    let snippet: String
}

enum GmailError: Error, LocalizedError {
    case apiError(String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return "Gmail API error: \(msg)"
        case .notAuthenticated: return "Gmail authentication required"
        }
    }
}
