import Foundation

// MARK: - Raw HTTP Request / Response

struct APIRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
}

struct APIResponse: Sendable {
    let statusCode: Int
    let body: Data
    let contentType: String

    static func json(_ data: Data, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, body: data, contentType: "application/json;charset=UTF-8")
    }

    static func error(_ message: String, status: Int = 400) -> APIResponse {
        let body = try? JSONEncoder().encode(["error": message])
        return APIResponse(statusCode: status, body: body ?? Data(), contentType: "application/json;charset=UTF-8")
    }
}

// MARK: - Chat API

struct ChatAPIRequest: Codable, Sendable {
    let text: String
    let sessionId: String?
}

struct ChatAPIResponse: Codable, Sendable {
    let text: String
    let sessionId: String
    let latencyMs: Int?
    let toolCalls: [String]?
}
