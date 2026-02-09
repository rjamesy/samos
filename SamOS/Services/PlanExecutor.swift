import Foundation

// MARK: - Plan Execution Result

struct PlanExecutionResult {
    var chatMessages: [ChatMessage] = []
    var spokenLines: [String] = []
    var outputItems: [OutputItem] = []
    var triggerFollowUpCapture: Bool = false
    var pendingSlotRequest: (slot: String, prompt: String)?
    var executedToolSteps: [(name: String, args: [String: String])] = []
    var stoppedAtAsk: Bool = false
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
                let (_, response) = try await session.data(for: request)
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
                let (_, response) = try await session.data(for: request)
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

    private init() {
        self.toolsRuntime = ToolsRuntime.shared
    }

    /// Test-only initialiser: inject a mock ToolsRuntime.
    init(toolsRuntime: ToolsRuntimeProtocol) {
        self.toolsRuntime = toolsRuntime
    }

    func execute(_ plan: Plan, originalInput: String, pendingSlotName: String? = nil) async -> PlanExecutionResult {
        var result = PlanExecutionResult()
        let _ = pendingSlotName // Retained for API compatibility with existing call sites/tests.
        let topLevelToolSay = singleToolPlanSay(in: plan)

        if let topLevelToolSay {
            result.chatMessages.append(ChatMessage(role: .assistant, text: topLevelToolSay))
            result.spokenLines.append(topLevelToolSay)
        }

        for step in plan.steps {
            switch step {
            case .talk(let say):
                result.chatMessages.append(ChatMessage(role: .assistant, text: say))
                result.spokenLines.append(say)

            case .tool(let name, _, let say):
                let toolAction = ToolAction(name: name, args: step.toolArgsAsStrings, say: say)
                let output = toolsRuntime.execute(toolAction)

                result.executedToolSteps.append((name: name, args: step.toolArgsAsStrings))

                #if DEBUG
                print("[PlanExecutor] Tool \(name) returned: kind=\(output?.kind.rawValue ?? "nil")")
                #endif

                if let output = output {
                    // Check for structured prompt payload (tool requesting info)
                    if let promptPayload = parsePromptPayload(output.payload) {
                        result.chatMessages.append(ChatMessage(role: .assistant, text: promptPayload.spoken))
                        result.spokenLines.append(promptPayload.spoken)
                        result.pendingSlotRequest = (slot: promptPayload.slot, prompt: promptPayload.spoken)
                        result.triggerFollowUpCapture = true
                        return result // Stop further steps
                    }

                    // Image probe: verify URLs are live before displaying
                    if name == "show_image" && output.kind == .image {
                        let probeResult = await probeImageOutput(output)
                        if let probeResult = probeResult {
                            // Probe failed — return as prompt payload for auto-repair
                            result.chatMessages.append(ChatMessage(role: .assistant, text: probeResult.spoken))
                            result.spokenLines.append(probeResult.spoken)
                            result.pendingSlotRequest = (slot: probeResult.slot, prompt: probeResult.spoken)
                            result.triggerFollowUpCapture = false // auto-repair, not user
                            return result
                        }
                        // Probe passed — output is good, fall through to normal handling
                    }

                    let isPrompt = output.payload.hasPrefix("I need") || output.payload.hasPrefix("I couldn't")
                    if isPrompt {
                        // Tool is asking for info (legacy string format)
                        result.chatMessages.append(ChatMessage(role: .assistant, text: output.payload))
                        result.spokenLines.append(output.payload)

                        if output.payload.hasPrefix("I need") {
                            result.pendingSlotRequest = (slot: name, prompt: output.payload)
                            result.triggerFollowUpCapture = true
                        }
                        return result // Stop further steps
                    } else if let structured = parseStructuredPayload(output.payload) {
                        // For top-level TOOL actions with say, speak the provided say only once.
                        if topLevelToolSay == nil {
                            result.chatMessages.append(ChatMessage(role: .assistant, text: structured.spoken))
                            result.spokenLines.append(structured.spoken)
                        }
                        // Tool window must display raw markdown exactly as provided.
                        result.outputItems.append(OutputItem(kind: .markdown, payload: structured.formatted))
                    } else {
                        result.outputItems.append(output)
                    }
                } else {
                    _ = say // tool step say is intentionally silent (debug/log only)
                }

            case .ask(let slot, let prompt):
                result.pendingSlotRequest = (slot: slot, prompt: prompt)
                result.chatMessages.append(ChatMessage(role: .assistant, text: prompt))
                result.spokenLines.append(prompt)
                result.triggerFollowUpCapture = true
                result.stoppedAtAsk = true
                return result // Stop further steps

            case .delegate(let task, _, let say):
                if let say = say {
                    result.chatMessages.append(ChatMessage(role: .assistant, text: say))
                    result.spokenLines.append(say)
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
                    let forgeOutput = toolsRuntime.execute(forgeAction)
                    result.executedToolSteps.append((name: forgeAction.name, args: forgeAction.args))

                    if let forgeOutput {
                        if let structured = parseStructuredPayload(forgeOutput.payload) {
                            result.chatMessages.append(ChatMessage(role: .assistant, text: structured.spoken))
                            result.spokenLines.append(structured.spoken)
                            result.outputItems.append(OutputItem(kind: .markdown, payload: structured.formatted))
                        } else {
                            result.outputItems.append(forgeOutput)
                        }
                    }
                }
            }
        }

        return result
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
