import Foundation

/// HTTP client for OpenAI chat completions, used by SkillForge to refine skill specs.
final class OpenAIRefinerClient {

    struct DebugExchange {
        enum Phase {
            case request
            case response
            case error
        }

        let phase: Phase
        let content: String
    }

    enum RefinerError: Error, LocalizedError {
        case notConfigured
        case requestFailed(String)
        case badResponse(Int)
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OpenAI API key not configured"
            case .requestFailed(let msg): return "OpenAI request failed: \(msg)"
            case .badResponse(let code): return "OpenAI returned HTTP \(code)"
            case .parseFailed(let msg): return "Failed to parse skill spec: \(msg)"
            }
        }
    }

    struct ImplementationReview {
        let approved: Bool
        let summary: String
        let implementationSteps: [String]
        let blockers: [String]
    }

    struct CapabilityRequirements {
        let summary: String
        let requirements: [String]
        let acceptanceCriteria: [String]
        let risks: [String]
        let openQuestions: [String]
    }

    /// Asks OpenAI to refine a draft skill spec into valid JSON.
    func refineSkillSpec(goal: String,
                         draft: SkillSpec,
                         requirements: CapabilityRequirements,
                         toolList: [String],
                         onDebugExchange: ((DebugExchange) -> Void)? = nil) async throws -> SkillSpec {
        guard OpenAISettings.isConfigured else {
            OpenAIAPILogStore.shared.logBlockedRequest(
                service: "OpenAIRefinerClient.refineSkillSpec",
                endpoint: "https://api.openai.com/v1/chat/completions",
                method: "POST",
                model: OpenAISettings.model,
                reason: "OpenAI API key not configured",
                payload: ["goal": goal]
            )
            throw RefinerError.notConfigured
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let draftJSON = (try? encoder.encode(draft)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let requirementsJSON = formatRequirementsJSON(requirements)
        let tools = toolList.joined(separator: ", ")

        let systemMessage = """
        You are a skill specification generator for SamOS, a macOS voice assistant.
        Your job is to refine a draft skill spec into a valid, complete SkillSpec JSON.

        Available tools that can be used in steps: \(tools)

        The spec must include: id, name, version, triggerPhrases, slots, steps, and optionally onTrigger.
        Slot types: "date", "string", "number".
        Step actions: tool names (e.g. "schedule_task", "show_text") or "talk".
        Step args support {{slotName}} interpolation.
        IMPORTANT:
        - Use placeholders ONLY for declared slot names.
        - Do NOT invent placeholders from previous tool outputs (e.g. {{fetchedImageUrl}} is invalid).
        - For show_image, valid args are 'url' (single) or 'urls' (pipe-separated).
        - For show_text, use arg 'markdown'.
        - Design capabilities using ONLY the listed tools; do NOT require new external APIs/services.
        - If a goal mentions an unavailable integration, implement the closest feasible behavior with available tools.

        Return ONLY the JSON object. No explanation, no markdown, no code fences.
        """

        let userMessage = """
        Goal: \(goal)

        Specific capability requirements from OpenAI:
        \(requirementsJSON)

        Draft spec:
        \(draftJSON)

        Please refine this into a complete, valid skill spec.
        """

        onDebugExchange?(DebugExchange(
            phase: .request,
            content: """
            SYSTEM:
            \(systemMessage)

            USER:
            \(userMessage)
            """
        ))

        let requestBody: [String: Any] = [
            "model": OpenAISettings.model,
            "messages": [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.3
        ]

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw RefinerError.requestFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let requestID = OpenAIAPILogStore.shared.logHTTPRequest(
            service: "OpenAIRefinerClient.refineSkillSpec",
            endpoint: url.absoluteString,
            method: "POST",
            model: OpenAISettings.model,
            timeoutSeconds: request.timeoutInterval,
            payload: requestBody
        )
        let startedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIRefinerClient.refineSkillSpec",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.model,
                statusCode: nil,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: error.localizedDescription,
                responseData: nil
            )
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            onDebugExchange?(DebugExchange(phase: .error, content: "Invalid response object from OpenAI."))
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIRefinerClient.refineSkillSpec",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.model,
                statusCode: nil,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: "Invalid response object",
                responseData: data
            )
            throw RefinerError.requestFailed("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            onDebugExchange?(DebugExchange(
                phase: .error,
                content: "HTTP \(http.statusCode)\(body.isEmpty ? "" : "\n\(body)")"
            ))
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIRefinerClient.refineSkillSpec",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.model,
                statusCode: http.statusCode,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: "HTTP \(http.statusCode)",
                responseData: data
            )
            throw RefinerError.badResponse(http.statusCode)
        }
        OpenAIAPILogStore.shared.logHTTPResponse(
            requestID: requestID,
            service: "OpenAIRefinerClient.refineSkillSpec",
            endpoint: url.absoluteString,
            method: "POST",
            model: OpenAISettings.model,
            statusCode: http.statusCode,
            latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            responseData: data
        )

        // Parse OpenAI response envelope
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            onDebugExchange?(DebugExchange(
                phase: .error,
                content: "Could not extract message content from OpenAI envelope."
            ))
            throw RefinerError.parseFailed("Could not extract content from OpenAI response")
        }

        onDebugExchange?(DebugExchange(phase: .response, content: content))

        // Extract JSON from content
        let jsonString = extractJSON(from: content)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw RefinerError.parseFailed("Invalid UTF-8 in response")
        }

        do {
            return try JSONDecoder().decode(SkillSpec.self, from: jsonData)
        } catch let error as DecodingError {
            throw RefinerError.parseFailed(describeDecodingError(error))
        } catch {
            throw RefinerError.parseFailed(error.localizedDescription)
        }
    }

    /// Ask OpenAI what the specific requirements are for a requested capability.
    func fetchCapabilityRequirements(goal: String,
                                     missing: String,
                                     toolList: [String],
                                     onDebugExchange: ((DebugExchange) -> Void)? = nil) async throws -> CapabilityRequirements {
        guard OpenAISettings.isConfigured else {
            OpenAIAPILogStore.shared.logBlockedRequest(
                service: "OpenAIRefinerClient.fetchCapabilityRequirements",
                endpoint: "https://api.openai.com/v1/chat/completions",
                method: "POST",
                model: OpenAISettings.model,
                reason: "OpenAI API key not configured",
                payload: ["goal": goal, "missing": missing]
            )
            throw RefinerError.notConfigured
        }

        let tools = toolList.joined(separator: ", ")
        let systemMessage = """
        You are defining implementation requirements for a SamOS capability.
        Available tools: \(tools)

        Return STRICT JSON ONLY:
        {
          "summary": "one short sentence",
          "requirements": ["specific requirement 1", "specific requirement 2"],
          "acceptance_criteria": ["testable outcome 1", "testable outcome 2"],
          "risks": ["risk 1"],
          "open_questions": ["question for user if needed"]
        }

        Rules:
        - Be specific and implementation-oriented.
        - Avoid vague placeholders.
        - requirements must describe what must exist for this capability to work.
        - REQUIREMENTS MUST be implementable using ONLY the listed tools.
        - Do NOT require external APIs/services that are not present as tools.
        - If the user's ideal request exceeds available tools, write feasible requirements for the closest useful capability.
        - No markdown, no prose outside JSON.
        """

        let userMessage = """
        Capability goal: \(goal)
        Missing details currently known: \(missing)
        """

        onDebugExchange?(DebugExchange(
            phase: .request,
            content: """
            [Capability Requirements]
            SYSTEM:
            \(systemMessage)

            USER:
            \(userMessage)
            """
        ))

        let requestBody: [String: Any] = [
            "model": OpenAISettings.model,
            "messages": [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.1
        ]

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw RefinerError.requestFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let requestID = OpenAIAPILogStore.shared.logHTTPRequest(
            service: "OpenAIRefinerClient.fetchCapabilityRequirements",
            endpoint: url.absoluteString,
            method: "POST",
            model: OpenAISettings.model,
            timeoutSeconds: request.timeoutInterval,
            payload: requestBody
        )
        let startedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIRefinerClient.fetchCapabilityRequirements",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.model,
                statusCode: nil,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: error.localizedDescription,
                responseData: nil
            )
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            onDebugExchange?(DebugExchange(phase: .error, content: "[Capability Requirements] Invalid response object from OpenAI."))
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIRefinerClient.fetchCapabilityRequirements",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.model,
                statusCode: nil,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: "Invalid response object",
                responseData: data
            )
            throw RefinerError.requestFailed("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            onDebugExchange?(DebugExchange(
                phase: .error,
                content: "[Capability Requirements] HTTP \(http.statusCode)\(body.isEmpty ? "" : "\n\(body)")"
            ))
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIRefinerClient.fetchCapabilityRequirements",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.model,
                statusCode: http.statusCode,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: "HTTP \(http.statusCode)",
                responseData: data
            )
            throw RefinerError.badResponse(http.statusCode)
        }
        OpenAIAPILogStore.shared.logHTTPResponse(
            requestID: requestID,
            service: "OpenAIRefinerClient.fetchCapabilityRequirements",
            endpoint: url.absoluteString,
            method: "POST",
            model: OpenAISettings.model,
            statusCode: http.statusCode,
            latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            responseData: data
        )

        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            onDebugExchange?(DebugExchange(
                phase: .error,
                content: "[Capability Requirements] Could not extract message content from OpenAI envelope."
            ))
            throw RefinerError.parseFailed("Could not extract content from OpenAI response")
        }

        onDebugExchange?(DebugExchange(phase: .response, content: "[Capability Requirements]\n\(content)"))
        return try parseCapabilityRequirements(from: content)
    }

    /// Asks OpenAI to verify whether a refined spec is truly implementable for the goal,
    /// and to provide explicit implementation steps.
    func reviewSkillSpec(goal: String,
                         missing: String,
                         spec: SkillSpec,
                         requirements: CapabilityRequirements,
                         toolList: [String],
                         onDebugExchange: ((DebugExchange) -> Void)? = nil) async throws -> ImplementationReview {
        guard OpenAISettings.isConfigured else {
            OpenAIAPILogStore.shared.logBlockedRequest(
                service: "OpenAIRefinerClient.reviewSkillSpec",
                endpoint: "https://api.openai.com/v1/chat/completions",
                method: "POST",
                model: OpenAISettings.model,
                reason: "OpenAI API key not configured",
                payload: ["goal": goal, "missing": missing, "spec_id": spec.id]
            )
            throw RefinerError.notConfigured
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let specJSON = (try? encoder.encode(spec)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let requirementsJSON = formatRequirementsJSON(requirements)
        let tools = toolList.joined(separator: ", ")

        let systemMessage = """
        You are auditing a SamOS capability spec before install.
        Decide whether this spec actually implements the requested capability.
        Available tools: \(tools)

        Return STRICT JSON ONLY:
        {
          "approved": true|false,
          "summary": "one short sentence",
          "implementation_steps": ["step 1", "step 2"],
          "blockers": ["blocker 1"]
        }

        Rules:
        - approved=true ONLY if the steps are concrete and executable with the available tools.
        - Reject placeholder-only specs.
        - Reject self-referential learning loops (e.g. start_skillforge as skill behavior).
        - implementation_steps must be actionable and specific.
        - Do NOT require external APIs/services that are not available as tools.
        - Evaluate the best feasible implementation for the goal using available tools.
        - No markdown, no prose outside JSON.
        """

        let userMessage = """
        Goal: \(goal)
        Missing capability details: \(missing)

        Capability requirements:
        \(requirementsJSON)

        Candidate skill spec:
        \(specJSON)
        """

        onDebugExchange?(DebugExchange(
            phase: .request,
            content: """
            [Skill Review]
            SYSTEM:
            \(systemMessage)

            USER:
            \(userMessage)
            """
        ))

        let requestBody: [String: Any] = [
            "model": OpenAISettings.model,
            "messages": [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.1
        ]

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw RefinerError.requestFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let requestID = OpenAIAPILogStore.shared.logHTTPRequest(
            service: "OpenAIRefinerClient.reviewSkillSpec",
            endpoint: url.absoluteString,
            method: "POST",
            model: OpenAISettings.model,
            timeoutSeconds: request.timeoutInterval,
            payload: requestBody
        )
        let startedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIRefinerClient.reviewSkillSpec",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.model,
                statusCode: nil,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: error.localizedDescription,
                responseData: nil
            )
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            onDebugExchange?(DebugExchange(phase: .error, content: "[Skill Review] Invalid response object from OpenAI."))
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIRefinerClient.reviewSkillSpec",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.model,
                statusCode: nil,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: "Invalid response object",
                responseData: data
            )
            throw RefinerError.requestFailed("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            onDebugExchange?(DebugExchange(
                phase: .error,
                content: "[Skill Review] HTTP \(http.statusCode)\(body.isEmpty ? "" : "\n\(body)")"
            ))
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIRefinerClient.reviewSkillSpec",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.model,
                statusCode: http.statusCode,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: "HTTP \(http.statusCode)",
                responseData: data
            )
            throw RefinerError.badResponse(http.statusCode)
        }
        OpenAIAPILogStore.shared.logHTTPResponse(
            requestID: requestID,
            service: "OpenAIRefinerClient.reviewSkillSpec",
            endpoint: url.absoluteString,
            method: "POST",
            model: OpenAISettings.model,
            statusCode: http.statusCode,
            latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            responseData: data
        )

        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            onDebugExchange?(DebugExchange(
                phase: .error,
                content: "[Skill Review] Could not extract message content from OpenAI envelope."
            ))
            throw RefinerError.parseFailed("Could not extract content from OpenAI response")
        }

        onDebugExchange?(DebugExchange(phase: .response, content: "[Skill Review]\n\(content)"))

        let jsonString = extractJSON(from: content)
        guard let jsonData = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            throw RefinerError.parseFailed("Invalid review JSON")
        }

        let approved = dict["approved"] as? Bool ?? false
        let summary = (dict["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let implementationSteps = (dict["implementation_steps"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let blockers = (dict["blockers"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return ImplementationReview(
            approved: approved,
            summary: summary,
            implementationSteps: implementationSteps,
            blockers: blockers
        )
    }

    func parseCapabilityRequirements(from content: String) throws -> CapabilityRequirements {
        let jsonString = extractJSON(from: content)
        guard let jsonData = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            throw RefinerError.parseFailed("Invalid requirements JSON")
        }

        let summary = (dict["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requirements = (dict["requirements"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let acceptanceCriteria = (dict["acceptance_criteria"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let risks = (dict["risks"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let openQuestions = (dict["open_questions"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return CapabilityRequirements(
            summary: summary,
            requirements: requirements,
            acceptanceCriteria: acceptanceCriteria,
            risks: risks,
            openQuestions: openQuestions
        )
    }

    private func formatRequirementsJSON(_ requirements: CapabilityRequirements) -> String {
        let payload: [String: Any] = [
            "summary": requirements.summary,
            "requirements": requirements.requirements,
            "acceptance_criteria": requirements.acceptanceCriteria,
            "risks": requirements.risks,
            "open_questions": requirements.openQuestions
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func extractJSON(from text: String) -> String {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}")
        else { return text }
        return String(text[start...end])
    }

    private func describeDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing key '\(key.stringValue)' at \(codingPathString(context.codingPath))"
        case .valueNotFound(let type, let context):
            return "Missing value for \(type) at \(codingPathString(context.codingPath))"
        case .typeMismatch(let type, let context):
            return "Type mismatch for \(type) at \(codingPathString(context.codingPath)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "Data corrupted at \(codingPathString(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private func codingPathString(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "root" }
        return codingPath.map(\.stringValue).joined(separator: ".")
    }
}
