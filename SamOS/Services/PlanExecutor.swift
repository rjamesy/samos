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

    /// Mutating forge tools that require an active learn-confirm/batch-confirm slot.
    /// Read-only tools (forge_queue_status) are NOT blocked.
    static let forgeToolNames: Set<String> = [
        "start_skillforge", "forge_queue_clear"
    ]

    /// PendingSlot names that grant permission to execute forge tools.
    static let learnSlotNames: Set<String> = [
        "learn_confirm", "batch_confirm"
    ]

    private init() {
        self.toolsRuntime = ToolsRuntime.shared
    }

    /// Test-only initialiser: inject a mock ToolsRuntime.
    init(toolsRuntime: ToolsRuntimeProtocol) {
        self.toolsRuntime = toolsRuntime
    }

    func execute(_ plan: Plan, originalInput: String, pendingSlotName: String? = nil) async -> PlanExecutionResult {
        var result = PlanExecutionResult()

        for step in plan.steps {
            switch step {
            case .talk(let say):
                result.chatMessages.append(ChatMessage(role: .assistant, text: say))
                result.spokenLines.append(say)

            case .tool(let name, _, let say):
                // Safety gate: block mutating forge tools unless active learn slot
                if Self.forgeToolNames.contains(name) && !Self.learnSlotNames.contains(pendingSlotName ?? "") {
                    #if DEBUG
                    print("[PlanExecutor] Blocked forge tool \(name) — no learn slot active (slot=\(pendingSlotName ?? "nil"))")
                    #endif
                    let prompt = "I can learn that as a new skill — do you want me to?"
                    result.chatMessages.append(ChatMessage(role: .assistant, text: prompt))
                    result.spokenLines.append(prompt)
                    result.pendingSlotRequest = (slot: "learn_confirm", prompt: prompt)
                    result.triggerFollowUpCapture = true
                    result.stoppedAtAsk = true
                    return result
                }

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
                        let spoken = say ?? structured.spoken
                        result.chatMessages.append(ChatMessage(role: .assistant, text: spoken))
                        result.spokenLines.append(spoken)
                        result.outputItems.append(OutputItem(kind: .markdown, payload: structured.formatted))
                    } else {
                        if let say = say {
                            result.chatMessages.append(ChatMessage(role: .assistant, text: say))
                            result.spokenLines.append(say)
                        }
                        result.outputItems.append(output)
                    }
                } else {
                    if let say = say {
                        result.chatMessages.append(ChatMessage(role: .assistant, text: say))
                        result.spokenLines.append(say)
                    }
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

        let verified = await ImageProber.probe(urls: urls)
        if verified.isEmpty {
            return (
                slot: "image_url",
                spoken: "I couldn't load that image — the URL seems broken.",
                formatted: "All \(urls.count) image URL(s) failed the download probe (non-200 or non-image content-type). Provide different direct image URLs ending in .jpg, .png, .gif, or .webp."
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

}
