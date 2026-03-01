import Foundation

// MARK: - Alexa Request Types

struct AlexaRequest: Codable, Sendable {
    let version: String
    let session: AlexaSession
    let request: AlexaRequestBody
}

struct AlexaSession: Codable, Sendable {
    let sessionId: String
    let new: Bool
    let attributes: [String: String]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case new
        case attributes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        new = try container.decodeIfPresent(Bool.self, forKey: .new) ?? true
        attributes = try container.decodeIfPresent([String: String].self, forKey: .attributes)
    }
}

struct AlexaRequestBody: Codable, Sendable {
    let type: String // "LaunchRequest", "IntentRequest", "SessionEndedRequest"
    let intent: AlexaIntent?
    let locale: String?
    let timestamp: String?
}

extension AlexaRequest {
    /// Try to extract the user's raw query from any available source.
    var extractedQuery: String? {
        // 1. Try the query slot from AskSamIntent
        if let value = request.intent?.slots?["query"]?.value, !value.isEmpty {
            return value
        }
        // 2. Try any slot value from any intent
        if let slots = request.intent?.slots {
            for slot in slots.values {
                if let value = slot.value, !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }
}

struct AlexaIntent: Codable, Sendable {
    let name: String // "AskSamIntent"
    let slots: [String: AlexaSlot]?
}

struct AlexaSlot: Codable, Sendable {
    let name: String
    let value: String?
}

// MARK: - Alexa Response Types

struct AlexaResponse: Codable, Sendable {
    let version: String
    let sessionAttributes: [String: String]?
    let response: AlexaResponseBody
}

struct AlexaResponseBody: Codable, Sendable {
    let outputSpeech: AlexaOutputSpeech?
    let shouldEndSession: Bool
    let reprompt: AlexaReprompt?
}

struct AlexaOutputSpeech: Codable, Sendable {
    let type: String // "SSML" or "PlainText"
    let ssml: String?
    let text: String?
}

struct AlexaReprompt: Codable, Sendable {
    let outputSpeech: AlexaOutputSpeech
}
