import Foundation

/// LLM-related errors.
enum LLMError: Error, LocalizedError {
    case apiKeyMissing
    case networkUnavailable
    case invalidResponse(String)
    case rateLimited
    case timeout
    case modelNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing: return "OpenAI API key is not configured"
        case .networkUnavailable: return "Network is unavailable"
        case .invalidResponse(let detail): return "Invalid LLM response: \(detail)"
        case .rateLimited: return "Rate limited by API provider"
        case .timeout: return "LLM request timed out"
        case .modelNotAvailable(let model): return "Model not available: \(model)"
        }
    }
}

/// Memory system errors.
enum MemoryError: Error, LocalizedError {
    case databaseError(String)
    case duplicateMemory
    case notFound(String)
    case corruptDatabase

    var errorDescription: String? {
        switch self {
        case .databaseError(let detail): return "Database error: \(detail)"
        case .duplicateMemory: return "Duplicate memory entry"
        case .notFound(let id): return "Memory not found: \(id)"
        case .corruptDatabase: return "Database integrity check failed"
        }
    }
}

/// Tool execution errors.
enum ToolError: Error, LocalizedError {
    case toolNotFound(String)
    case invalidArguments(String)
    case executionFailed(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name): return "Tool not found: \(name)"
        case .invalidArguments(let detail): return "Invalid tool arguments: \(detail)"
        case .executionFailed(let detail): return "Tool execution failed: \(detail)"
        case .permissionDenied(let detail): return "Permission denied: \(detail)"
        }
    }
}

/// TTS errors.
enum TTSError: Error, LocalizedError {
    case apiKeyMissing
    case synthesisError(String)
    case playbackError(String)

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing: return "ElevenLabs API key is not configured"
        case .synthesisError(let detail): return "Speech synthesis failed: \(detail)"
        case .playbackError(let detail): return "Audio playback failed: \(detail)"
        }
    }
}

/// Pipeline/routing errors.
enum PipelineError: Error, LocalizedError {
    case noProviderAvailable
    case parseFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noProviderAvailable: return "No LLM provider available"
        case .parseFailed(let detail): return "Response parse failed: \(detail)"
        case .emptyResponse: return "Empty response from LLM"
        }
    }
}

/// Skill system errors.
enum SkillError: Error, LocalizedError {
    case buildFailed(String)
    case validationFailed(String)
    case notApproved
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .buildFailed(let detail): return "Skill build failed: \(detail)"
        case .validationFailed(let detail): return "Skill validation failed: \(detail)"
        case .notApproved: return "Skill not approved"
        case .notFound(let id): return "Skill not found: \(id)"
        }
    }
}
