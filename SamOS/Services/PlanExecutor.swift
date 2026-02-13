import Foundation

// MARK: - Plan Execution Result

struct PlanExecutionResult {
    var chatMessages: [ChatMessage] = []
    var spokenLines: [String] = []
    var outputItems: [OutputItem] = []
    var triggerFollowUpCapture: Bool = false
    var pendingSlotRequest: (slot: String, prompt: String)?
    var executedToolSteps: [(name: String, args: [String: String])] = []
    var toolMsTotal: Int = 0
    var stoppedAtAsk: Bool = false
    var executionMs: Int = 0
    var speechSelectionMs: Int = 0
}

// MARK: - Image Prober

/// Validates image URLs by performing lightweight HEAD requests.
enum ImageProber {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "SamOS/1.0 (macOS; image-prober)"]
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

#if DEBUG
    private static var testSession: URLSession?

    static func setSessionForTesting(_ session: URLSession?) {
        testSession = session
    }
#endif

    private static var activeSession: URLSession {
#if DEBUG
        testSession ?? session
#else
        session
#endif
    }

    /// Per-URL probe result with failure reason.
    struct ProbeDetail {
        let url: String
        let passed: Bool
        let reason: String // e.g. "HTTP 404", "text/html", "timeout"
    }

    /// Probes URLs and returns per-URL pass/fail details including HTTP status.
    static func probeDetailed(urls: [String]) async -> [ProbeDetail] {
        var details: [ProbeDetail] = []
        for urlString in urls {
            guard let url = URL(string: urlString) else {
                details.append(ProbeDetail(url: urlString, passed: false, reason: "invalid URL"))
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5

            do {
                let (_, response) = try await activeSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    details.append(ProbeDetail(url: urlString, passed: false, reason: "no HTTP response"))
                    continue
                }
                if !(200...299).contains(http.statusCode) {
                    details.append(ProbeDetail(url: urlString, passed: false, reason: "HTTP \(http.statusCode)"))
                    continue
                }
                let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                if contentType.hasPrefix("text/html") {
                    details.append(ProbeDetail(url: urlString, passed: false, reason: "text/html (web page)"))
                } else {
                    details.append(ProbeDetail(url: urlString, passed: true, reason: "OK"))
                }
            } catch {
                details.append(ProbeDetail(url: urlString, passed: false, reason: "network error"))
            }
        }
        return details
    }

    /// Probes a list of URLs with HEAD requests.
    /// Returns the subset that respond with HTTP 200 and Content-Type starting with "image/".
    static func probe(urls: [String]) async -> [String] {
        var verified: [String] = []
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5

            do {
                let (_, response) = try await activeSession.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    #if DEBUG
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    print("[ImageProber] \(urlString.prefix(80)) → HTTP \(code)")
                    #endif
                    continue
                }
                let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                // Reject only if explicitly text/html (web page).
                // Many CDNs return application/octet-stream or omit content-type for HEAD.
                if contentType.hasPrefix("text/html") {
                    #if DEBUG
                    print("[ImageProber] \(urlString.prefix(80)) → rejected: text/html (web page)")
                    #endif
                } else {
                    verified.append(urlString)
                }
            } catch {
                #if DEBUG
                print("[ImageProber] \(urlString.prefix(80)) → error: \(error.localizedDescription)")
                #endif
            }
        }
        return verified
    }
}

// MARK: - Plan Executor

/// Shared executor for Plan steps. Used by TurnOrchestrator and AlarmSession.
/// Does NOT manage pendingSlot state — returns a pendingSlotRequest for the caller to handle.
@MainActor
final class PlanExecutor {
    static let shared = PlanExecutor()
    private let toolsRuntime: ToolsRuntimeProtocol
    private let speechCoordinator: SpeechLineSelecting

    private init() {
        self.toolsRuntime = ToolsRuntime.shared
        self.speechCoordinator = SpeechCoordinator.shared
    }

    /// Test-only initialiser: inject a mock ToolsRuntime.
    init(toolsRuntime: ToolsRuntimeProtocol,
         speechCoordinator: SpeechLineSelecting? = nil) {
        self.toolsRuntime = toolsRuntime
        self.speechCoordinator = speechCoordinator ?? SpeechCoordinator.shared
    }

    func execute(_ plan: Plan, originalInput: String, pendingSlotName: String? = nil) async -> PlanExecutionResult {
        let executionStartedAt = CFAbsoluteTimeGetCurrent()
        var result = PlanExecutionResult()
        let _ = pendingSlotName // Retained for API compatibility with existing call sites/tests.
        let topLevelToolSay = singleToolPlanSay(in: plan)
        let turnCorrelationID = String(UUID().uuidString.prefix(8))
        var speechEntries: [SpeechLineEntry] = []
        var toolProducedUserFacingOutput = false

        func appendSpeech(_ text: String, source: SpeechLineSource) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            speechEntries.append(SpeechLineEntry(text: trimmed, source: source))
            result.spokenLines.append(trimmed)
        }

        func finalizedResult() -> PlanExecutionResult {
            let speechSelectStartedAt = CFAbsoluteTimeGetCurrent()
            let selectedSpeech = speechCoordinator.selectSpokenLines(
                entries: speechEntries,
                toolProducedUserFacingOutput: toolProducedUserFacingOutput,
                maxSpeakChars: M2Settings.maxSpeakChars
            )
            result.speechSelectionMs = max(0, Int((CFAbsoluteTimeGetCurrent() - speechSelectStartedAt) * 1000))
            #if DEBUG
            print("[SPEECH_POLICY] entries=\(speechEntries.count) tool_user_facing=\(toolProducedUserFacingOutput) selected_count=\(selectedSpeech.count)")
            #endif
            result.spokenLines = selectedSpeech
            result.executionMs = max(0, Int((CFAbsoluteTimeGetCurrent() - executionStartedAt) * 1000))
            return result
        }

        if let topLevelToolSay {
            result.chatMessages.append(ChatMessage(role: .assistant, text: topLevelToolSay))
                appendSpeech(topLevelToolSay, source: .talk)
        }

        for step in plan.steps {
            switch step {
            case .talk(let say):
                result.chatMessages.append(ChatMessage(role: .assistant, text: say))
                appendSpeech(say, source: .talk)

            case .tool(let name, _, let say):
                // Hard gate: unknown tools must never execute
                if !toolsRuntime.toolExists(name) {
                    #if DEBUG
                    print("[PlanExecutor] Unknown tool '\(name)' — routing to capability gap")
                    #endif
                    let gapMessage = "I don't have a \"\(name)\" tool yet. Can you share the source URL or rephrase what you need?"
                    result.chatMessages.append(ChatMessage(role: .assistant, text: gapMessage))
                    appendSpeech(gapMessage, source: .tool)
                    toolProducedUserFacingOutput = true
                    result.executedToolSteps.append((name: "capability_gap", args: ["unknown_tool": name]))
                    return finalizedResult()
                }

                let toolAction = ToolAction(name: name, args: step.toolArgsAsStrings, say: say)
                let toolStartedAt = CFAbsoluteTimeGetCurrent()
                let output = toolsRuntime.execute(toolAction)
                let toolElapsedMs = Int((CFAbsoluteTimeGetCurrent() - toolStartedAt) * 1000)
                result.toolMsTotal += max(0, toolElapsedMs)

                result.executedToolSteps.append((name: name, args: step.toolArgsAsStrings))

                #if DEBUG
                print("[PlanExecutor] Tool \(name) returned: kind=\(output?.kind.rawValue ?? "nil")")
                #endif

                if let output = output {
                    #if DEBUG
                    print("[TOOL_OUTPUT_RAW] turn=\(turnCorrelationID) tool=\(name) kind=\(output.kind.rawValue) payload=\(output.payload)")
                    #endif
                    // Check for structured prompt payload (tool requesting info)
                    if let promptPayload = parsePromptPayload(output.payload) {
                        let promptText = normalizedToolSpeech(promptPayload.spoken, fallback: promptPayload.formatted)
                        result.chatMessages.append(ChatMessage(role: .assistant, text: promptText))
                        appendSpeech(promptText, source: .tool)
                        toolProducedUserFacingOutput = true
                        #if DEBUG
                        print("[TOOL_OUTPUT_TEXT] turn=\(turnCorrelationID) tool=\(name) text=\(promptText)")
                        #endif
                        result.pendingSlotRequest = (slot: promptPayload.slot, prompt: promptPayload.spoken)
                        result.triggerFollowUpCapture = true
                        return finalizedResult() // Stop further steps
                    }

                    // Image probe: verify URLs are live before displaying
                    if name == "show_image" && output.kind == .image {
                        let probeResult = await probeImageOutput(output)
                        if let probeResult = probeResult {
                            // Probe failed — return as prompt payload for auto-repair
                            result.chatMessages.append(ChatMessage(role: .assistant, text: probeResult.spoken))
                            appendSpeech(probeResult.spoken, source: .tool)
                            toolProducedUserFacingOutput = true
                            result.pendingSlotRequest = (slot: probeResult.slot, prompt: probeResult.spoken)
                            result.triggerFollowUpCapture = false // auto-repair, not user
                            return finalizedResult()
                        }
                        // Probe passed — output is good, fall through to normal handling
                    }

                    let isPrompt = output.payload.hasPrefix("I need") || output.payload.hasPrefix("I couldn't")
                    if isPrompt {
                        // Tool is asking for info (legacy string format)
                        let promptText = normalizedToolSpeech(output.payload, fallback: output.payload)
                        result.chatMessages.append(ChatMessage(role: .assistant, text: promptText))
                        appendSpeech(promptText, source: .tool)
                        toolProducedUserFacingOutput = true
                        #if DEBUG
                        print("[TOOL_OUTPUT_TEXT] turn=\(turnCorrelationID) tool=\(name) text=\(promptText)")
                        #endif

                        if output.payload.hasPrefix("I need") {
                            result.pendingSlotRequest = (slot: name, prompt: output.payload)
                            result.triggerFollowUpCapture = true
                        }
                        return finalizedResult() // Stop further steps
                    } else if let structured = parseStructuredPayload(output.payload) {
                        let spoken = normalizedToolSpeech(structured.spoken, fallback: structured.formatted)
                        result.chatMessages.append(ChatMessage(role: .assistant, text: spoken))
                        appendSpeech(spoken, source: .tool)
                        toolProducedUserFacingOutput = true
                        #if DEBUG
                        print("[TOOL_OUTPUT_TEXT] turn=\(turnCorrelationID) tool=\(name) text=\(spoken)")
                        #endif
                        // Tool window must display raw markdown exactly as provided.
                        result.outputItems.append(OutputItem(kind: .markdown, payload: structured.formatted))
                    } else {
                        if let spoken = fallbackSpokenText(for: output) {
                            result.chatMessages.append(ChatMessage(role: .assistant, text: spoken))
                            appendSpeech(spoken, source: .tool)
                            toolProducedUserFacingOutput = true
                            #if DEBUG
                            print("[TOOL_OUTPUT_TEXT] turn=\(turnCorrelationID) tool=\(name) text=\(spoken)")
                            #endif
                        }
                        result.outputItems.append(output)
                    }
                } else {
                    _ = say // tool step say is intentionally silent (debug/log only)
                }

            case .ask(let slot, let prompt):
                result.pendingSlotRequest = (slot: slot, prompt: prompt)
                result.chatMessages.append(ChatMessage(role: .assistant, text: prompt))
                appendSpeech(prompt, source: .prompt)
                result.triggerFollowUpCapture = true
                result.stoppedAtAsk = true
                return finalizedResult() // Stop further steps

            case .delegate(let task, _, let say):
                if let say = say {
                    result.chatMessages.append(ChatMessage(role: .assistant, text: say))
                    appendSpeech(say, source: .talk)
                }
                result.chatMessages.append(ChatMessage(
                    role: .system,
                    text: "Delegating: \(task)"
                ))

                if let goal = capabilityGapGoal(from: task) {
                    var args: [String: String] = ["goal": goal]
                    if let missing = capabilityGapMissing(from: step), !missing.isEmpty {
                        args["constraints"] = missing
                    }

                    let forgeAction = ToolAction(name: "start_skillforge", args: args, say: nil)
                    let toolStartedAt = CFAbsoluteTimeGetCurrent()
                    let forgeOutput = toolsRuntime.execute(forgeAction)
                    let toolElapsedMs = Int((CFAbsoluteTimeGetCurrent() - toolStartedAt) * 1000)
                    result.toolMsTotal += max(0, toolElapsedMs)
                    result.executedToolSteps.append((name: forgeAction.name, args: forgeAction.args))

                    if let forgeOutput {
                        if let structured = parseStructuredPayload(forgeOutput.payload) {
                            result.chatMessages.append(ChatMessage(role: .assistant, text: structured.spoken))
                            appendSpeech(structured.spoken, source: .tool)
                            toolProducedUserFacingOutput = true
                            result.outputItems.append(OutputItem(kind: .markdown, payload: structured.formatted))
                        } else {
                            result.outputItems.append(forgeOutput)
                        }
                    }
                }
            }
        }

        return finalizedResult()
    }

    // MARK: - Image Probe

    /// Probes image URLs from a show_image output. Returns a prompt payload if all URLs fail,
    /// or nil if at least one URL is live.
    private func probeImageOutput(_ output: OutputItem) async -> (slot: String, spoken: String, formatted: String)? {
        guard let data = output.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urls = dict["urls"] as? [String], !urls.isEmpty
        else { return nil }

        let details = await ImageProber.probeDetailed(urls: urls)
        let allFailed = details.allSatisfy { !$0.passed }

        if allFailed {
            // Build per-URL failure reasons for the repair prompt
            let failureLines = details.map { "\($0.url.prefix(80)) → \($0.reason)" }
            let failureSummary = failureLines.joined(separator: "; ")

            return (
                slot: "image_url",
                spoken: "I couldn't load that image — the URL seems broken.",
                formatted: "All \(urls.count) image URL(s) failed probe: \(failureSummary). Return 3 NEW direct image URLs from upload.wikimedia.org (preferred), images.unsplash.com, or images.pexels.com. URLs must end in .jpg, .png, .gif, or .webp."
            )
        }

        return nil // At least one URL is live
    }

    // MARK: - Payload Parsing

    /// Parses a structured JSON tool payload containing spoken + formatted fields.
    /// Skips prompt payloads (handled by parsePromptPayload).
    private func parseStructuredPayload(_ payload: String) -> (spoken: String, formatted: String)? {
        guard let data = payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spoken = dict["spoken"] as? String,
              let formatted = dict["formatted"] as? String
        else { return nil }
        // Skip prompt payloads — those are handled separately
        if (dict["kind"] as? String) == "prompt" { return nil }
        return (spoken, formatted)
    }

    /// Parses a structured prompt payload from a tool requesting info.
    private func parsePromptPayload(_ payload: String) -> (slot: String, spoken: String, formatted: String)? {
        guard let data = payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = dict["kind"] as? String, kind == "prompt",
              let slot = dict["slot"] as? String,
              let spoken = dict["spoken"] as? String,
              let formatted = dict["formatted"] as? String
        else { return nil }
        return (slot, spoken, formatted)
    }

    private func fallbackSpokenText(for output: OutputItem) -> String? {
        if let data = output.payload.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let jsonSpoken = dict["spoken"] as? String
            let jsonFormatted = dict["formatted"] as? String
            if let jsonSpoken, !jsonSpoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalizedToolSpeech(jsonSpoken, fallback: jsonFormatted ?? output.payload)
            }
            if let jsonFormatted, !jsonFormatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalizedToolSpeech(jsonFormatted, fallback: output.payload)
            }
        }

        switch output.kind {
        case .markdown, .card:
            let spoken = normalizedToolSpeech(output.payload, fallback: output.payload)
            return spoken.isEmpty ? nil : spoken
        case .image:
            return "I found image results."
        }
    }

    private func normalizedToolSpeech(_ text: String, fallback: String) -> String {
        let stripped = stripMarkdownForSpeech(text)
        var cleaned = stripPlaceholderTokens(stripped)
        if cleaned.isEmpty {
            cleaned = stripPlaceholderTokens(stripMarkdownForSpeech(fallback))
        }
        if cleaned.count > 320 {
            cleaned = String(cleaned.prefix(320)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private func stripPlaceholderTokens(_ text: String) -> String {
        let removedTokens = text.replacingOccurrences(
            of: #"\{[A-Za-z0-9_]+\}"#,
            with: " ",
            options: .regularExpression
        )
        return removedTokens
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripMarkdownForSpeech(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)^\s*\d+[\.)]\s+"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[*_>#]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns plan-level say when this is a single-tool plan (legacy TOOL action shape).
    private func singleToolPlanSay(in plan: Plan) -> String? {
        guard plan.steps.count == 1 else { return nil }
        guard case .tool = plan.steps[0] else { return nil }
        let trimmed = plan.say?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func capabilityGapGoal(from task: String) -> String? {
        let marker = "capability_gap:"
        guard task.lowercased().hasPrefix(marker) else { return nil }
        let start = task.index(task.startIndex, offsetBy: marker.count)
        let goal = String(task[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? nil : goal
    }

    private func capabilityGapMissing(from step: PlanStep) -> String? {
        guard case .delegate(_, let context, _) = step else { return nil }
        guard var context = context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty else {
            return nil
        }
        let prefix = "missing:"
        if context.lowercased().hasPrefix(prefix) {
            context = String(context.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return context.isEmpty ? nil : context
    }

}
