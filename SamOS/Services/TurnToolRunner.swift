import Foundation

@MainActor
final class TurnToolRunner: TurnToolRunning {
    private let planExecutor: PlanExecutor
    private let toolsRuntime: ToolsRuntimeProtocol
    private let toolNameNormalizer: ToolNameNormalizing

    private static let unknownToolPrompt =
        "I couldn't run that request because the requested tool isn't available locally. Please rephrase your request."

    init(planExecutor: PlanExecutor,
         toolsRuntime: ToolsRuntimeProtocol,
         toolNameNormalizer: ToolNameNormalizing = ToolRegistry.shared) {
        self.planExecutor = planExecutor
        self.toolsRuntime = toolsRuntime
        self.toolNameNormalizer = toolNameNormalizer
    }

    func executePlan(_ plan: Plan,
                     originalInput: String,
                     pendingSlotName: String?) async -> ToolRunResult {
        switch normalizePlan(plan, originalInput: originalInput) {
        case .rejected(let raw):
            logToolReject(raw: raw, normalized: nil, reason: "unknown_tool")
            return rejectedToolResult(rawToolName: raw)
        case .normalized(let normalizedPlan):
            var result = await planExecutor.execute(
                normalizedPlan,
                originalInput: originalInput,
                pendingSlotName: pendingSlotName
            )
            result = await maybeRetryWeatherPrompt(
                originalResult: result,
                originalInput: originalInput
            )
            result.outputItems = result.outputItems.compactMap { normalizeToolOutput($0) }
            return result
        }
    }

    func executeTool(_ action: ToolAction) -> OutputItem? {
        guard let normalized = normalizedToolName(for: action.name) else {
            logToolReject(raw: action.name, normalized: nil, reason: "unknown_tool")
            return OutputItem(kind: .markdown, payload: Self.unknownToolPrompt)
        }
        let canonicalAction = ToolAction(
            name: normalized,
            args: canonicalizedToolArgs(name: normalized, args: action.args),
            say: action.say
        )
        return normalizeToolOutput(toolsRuntime.execute(canonicalAction))
    }

    private enum PlanNormalizationResult {
        case normalized(Plan)
        case rejected(rawToolName: String)
    }

    private func normalizePlan(_ plan: Plan, originalInput: String) -> PlanNormalizationResult {
        var normalizedSteps: [PlanStep] = []
        normalizedSteps.reserveCapacity(plan.steps.count)

        for step in plan.steps {
            switch step {
            case .tool(let rawName, let args, let say):
                guard let normalized = normalizedToolName(for: rawName) else {
                    return .rejected(rawToolName: rawName)
                }
                var finalArgs = canonicalizedStepArgs(name: normalized, args: args)
                finalArgs = maybeInjectWeatherPlace(name: normalized, args: finalArgs, originalInput: originalInput)
                normalizedSteps.append(
                    .tool(
                        name: normalized,
                        args: finalArgs,
                        say: say
                    )
                )
            default:
                normalizedSteps.append(step)
            }
        }

        return .normalized(Plan(steps: normalizedSteps, say: plan.say))
    }

    /// Pre-execution: if get_weather has no place arg, try deterministic extraction from user text.
    private func maybeInjectWeatherPlace(name: String, args: [String: CodableValue], originalInput: String) -> [String: CodableValue] {
        guard name == "get_weather" else { return args }
        let existingPlace: String
        if case .string(let p) = args["place"] {
            existingPlace = p.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            existingPlace = ""
        }
        guard existingPlace.isEmpty else { return args }
        guard let extracted = extractWeatherPlace(from: originalInput) else { return args }
        #if DEBUG
        print("[WEATHER_INJECT] place=\(extracted) from=\"\(originalInput)\"")
        #endif
        var patched = args
        patched["place"] = .string(extracted)
        return patched
    }

    private func normalizedToolName(for rawName: String) -> String? {
        guard let normalized = toolNameNormalizer.normalizeToolName(rawName) else { return nil }
        guard toolNameNormalizer.isAllowedTool(normalized) else { return nil }
        guard toolsRuntime.toolExists(normalized) else { return nil }
        return normalized
    }

    private func rejectedToolResult(rawToolName: String) -> ToolRunResult {
        var result = ToolRunResult()
        let message = Self.unknownToolPrompt
        result.chatMessages = [ChatMessage(role: .assistant, text: message)]
        result.spokenLines = [message]
        result.executedToolSteps = [(name: "tool_reject", args: ["unknown_tool": rawToolName])]
        return result
    }

    private func logToolReject(raw: String, normalized: String?, reason: String) {
        #if DEBUG
        print("[TOOL_REJECT] raw=\(raw) normalized=\(normalized ?? "nil") reason=\(reason)")
        #endif
    }

    private func canonicalizedStepArgs(name: String, args: [String: CodableValue]) -> [String: CodableValue] {
        guard name == "get_weather" else { return args }
        var normalized = args
        if normalized["place"] == nil,
           let location = normalized["location"] {
            normalized["place"] = location
        }
        return normalized
    }

    private func canonicalizedToolArgs(name: String, args: [String: String]) -> [String: String] {
        guard name == "get_weather" else { return args }
        var normalized = args
        let place = normalized["place"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if place.isEmpty {
            let location = normalized["location"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !location.isEmpty {
                normalized["place"] = location
            }
        }
        return normalized
    }

    private func maybeRetryWeatherPrompt(originalResult: ToolRunResult,
                                         originalInput: String) async -> ToolRunResult {
        guard let pending = originalResult.pendingSlotRequest,
              pending.slot.caseInsensitiveCompare("place") == .orderedSame else {
            return originalResult
        }
        guard originalResult.executedToolSteps.contains(where: { $0.name == "get_weather" }) else {
            return originalResult
        }
        guard let place = extractWeatherPlace(from: originalInput) else {
            return originalResult
        }

        let retryPlan = Plan(steps: [
            .tool(name: "get_weather", args: ["place": .string(place)], say: nil)
        ])
        var retryResult = await planExecutor.execute(
            retryPlan,
            originalInput: originalInput,
            pendingSlotName: nil
        )
        if let retryPending = retryResult.pendingSlotRequest,
           retryPending.slot.caseInsensitiveCompare("place") == .orderedSame {
            return originalResult
        }

        retryResult.toolMsTotal += originalResult.toolMsTotal
        retryResult.executedToolSteps = originalResult.executedToolSteps + retryResult.executedToolSteps
        return retryResult
    }

    private func extractWeatherPlace(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let blockers = ["what's the weather", "what is the weather", "weather today", "weather now"]
        if blockers.contains(where: { lower == $0 }) { return nil }

        let patterns = [
            #"(?i)\b(?:weather|forecast|temperature|rain|raining)\s+(?:in\s+)?([A-Za-z][A-Za-z\s'\-]{1,40})"#,
            #"(?i)\bin\s+([A-Za-z][A-Za-z\s'\-]{1,40})\s+(?:today|now|right now)\b"#,
            #"(?i)\b([A-Za-z][A-Za-z\s'\-]{1,40})\s+weather\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: trimmed) else { continue }
            var candidate = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            candidate = candidate.replacingOccurrences(of: #"\b(?:today|tomorrow|now|right now|please)\b"#,
                                                       with: "",
                                                       options: .regularExpression)
            candidate = candidate.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { continue }
            let lowerCandidate = candidate.lowercased()
            let disallowed = ["the", "it", "this", "that", "weather", "forecast"]
            if disallowed.contains(lowerCandidate) { continue }
            return candidate
        }

        let tokens = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,!?")) }
        if tokens.count == 2,
           ["weather", "forecast", "rain", "raining"].contains(tokens[0].lowercased()) {
            let city = tokens[1]
            if city.range(of: #"^[A-Za-z][A-Za-z'\-]{1,31}$"#, options: .regularExpression) != nil {
                return city
            }
        }
        return nil
    }

    private func normalizeToolOutput(_ output: OutputItem?) -> OutputItem? {
        guard let output else { return nil }
        let trimmed = output.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == output.payload { return output }
        return OutputItem(id: output.id, ts: output.ts, kind: output.kind, payload: trimmed)
    }
}
