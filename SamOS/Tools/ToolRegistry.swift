import Foundation

// MARK: - Tool Protocol

protocol Tool {
    var name: String { get }
    var description: String { get }
    func execute(args: [String: String]) -> OutputItem
}

// MARK: - Tool Registry

final class ToolRegistry {
    static let shared = ToolRegistry()

    private var tools: [String: Tool] = [:]

    private init() {
        register(ShowTextTool())
        register(ShowImageTool())
        register(CapabilityGapToClaudePromptTool())
        register(SaveMemoryTool())
        register(ListMemoriesTool())
        register(DeleteMemoryTool())
        register(ClearMemoriesTool())
        register(ScheduleTaskTool())
        register(CancelTaskTool())
        register(ListTasksTool())
        register(GetTimeTool())
        register(StartSkillForgeTool())
        register(ForgeQueueStatusTool())
        register(ForgeQueueClearTool())
    }

    func register(_ tool: Tool) {
        tools[tool.name] = tool
    }

    func get(_ name: String) -> Tool? {
        tools[name]
    }

    var allTools: [Tool] {
        Array(tools.values)
    }
}

// MARK: - Built-in Tools

struct ShowTextTool: Tool {
    let name = "show_text"
    let description = "Renders markdown text on the Output Canvas"

    func execute(args: [String: String]) -> OutputItem {
        let markdown = args["markdown"] ?? "_No content provided._"
        return OutputItem(kind: .markdown, payload: markdown)
    }
}

struct ShowImageTool: Tool {
    let name = "show_image"
    let description = "Displays a remote image on the Output Canvas. Accepts 'urls' (pipe-separated list) or 'url' (single). Provide multiple URLs for fallback."

    static let validImageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "svg"]

    func execute(args: [String: String]) -> OutputItem {
        let alt = args["alt"] ?? "Image"

        // Collect candidate URLs: prefer 'urls' (pipe-separated), fall back to 'url'
        var candidates: [String] = []
        if let urlsList = args["urls"], !urlsList.isEmpty {
            candidates = urlsList.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let singleUrl = args["url"], !singleUrl.isEmpty {
            if !candidates.contains(singleUrl) {
                candidates.insert(singleUrl, at: 0)
            }
        }

        // Filter to valid image URLs
        let validUrls = candidates.filter { validateImageURL($0) == nil }

        if validUrls.isEmpty {
            // Try to give a useful error from the first candidate
            let firstError = candidates.first.flatMap { validateImageURL($0) } ?? "No URL provided."
            return OutputItem(kind: .markdown, payload: "**Image Error:** \(firstError)")
        }

        // Encode payload with all valid URLs for fallback at load time
        let payloadDict: [String: Any] = ["urls": validUrls, "alt": alt]
        if let data = try? JSONSerialization.data(withJSONObject: payloadDict),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .image, payload: json)
        }

        return OutputItem(kind: .markdown, payload: "**Image Error:** Failed to encode image data.")
    }

    func validateImageURL(_ urlString: String) -> String? {
        guard !urlString.isEmpty else {
            return "No URL provided."
        }
        guard let url = URL(string: urlString) else {
            return "Invalid URL: \(urlString.prefix(100))"
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "URL must use http or https."
        }
        // Reject wiki page URLs (contain /wiki/ path)
        if url.path.contains("/wiki/") {
            return "URL is a wiki page, not a direct image. Use a URL ending in .jpg, .png, etc."
        }
        // Check for valid image extension in path
        let pathExtension = url.pathExtension.lowercased()
        if !pathExtension.isEmpty && !ShowImageTool.validImageExtensions.contains(pathExtension) {
            return "URL does not point to an image file (.\(pathExtension)). Expected .jpg, .png, .gif, or .webp."
        }
        return nil
    }
}

struct CapabilityGapToClaudePromptTool: Tool {
    let name = "capability_gap_to_claude_prompt"
    let description = "Generates a Claude-ready build prompt for a missing capability"

    func execute(args: [String: String]) -> OutputItem {
        let goal = args["goal"] ?? "Unknown goal"
        let missing = args["missing"] ?? "Unknown capability"
        let repoContext = args["repoContext"] ?? "SamOS macOS SwiftUI app"

        let prompt = """
        # Capability Build Request

        ## Goal
        \(goal)

        ## Missing Capability
        \(missing)

        ## Repository Context
        \(repoContext)

        ## Instructions
        Please design and implement a new capability package for the SamOS system that addresses the above gap. \
        The package should:

        1. Conform to the `Tool` protocol (`name`, `description`, `execute(args:) -> OutputItem`)
        2. Register itself in `ToolRegistry`
        3. Include any necessary Services layer code
        4. Follow the existing project conventions (Models/, Services/, Tools/, Views/)
        5. Handle errors gracefully and return user-friendly OutputItems

        Provide the complete Swift source files needed.
        """

        return OutputItem(kind: .markdown, payload: prompt)
    }
}

struct GetTimeTool: Tool {
    let name = "get_time"
    let description = "Returns the current date and time. Args: 'timezone' (IANA ID e.g. \"America/Chicago\"), 'place' (free text e.g. \"London\", \"Tokyo\", \"New York\"). Resolves international cities to IANA timezone internally. If place is ambiguous (country/region spanning multiple zones), returns a prompt asking to narrow down."

    /// Injectable date provider for testability. Defaults to `Date()`.
    var dateProvider: () -> Date = { Date() }

    /// Regions that span multiple timezones and require clarification.
    static let ambiguousRegions: Set<String> = [
        "america", "usa", "us", "u.s.", "u.s.a.", "united states",
        "united states of america", "the us", "the usa", "the states"
    ]

    func execute(args: [String: String]) -> OutputItem {
        let now = dateProvider()

        // 1. Explicit IANA timezone takes priority
        if let tzId = args["timezone"], let resolved = TimeZone(identifier: tzId) {
            return buildTimePayload(now: now, tz: resolved)
        }

        // 2. Place-based resolution
        if let place = args["place"]?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            let lower = place.lowercased()

            // Check if place is an ambiguous region
            if Self.ambiguousRegions.contains(lower) {
                return buildPromptPayload(
                    slot: "timezone",
                    spoken: "Which state or city in the US?",
                    formatted: "I need a specific state or city (e.g., Alabama, New York, Los Angeles)."
                )
            }

            // Try TimezoneMapping
            if let tzId = TimezoneMapping.lookup(place), let tz = TimeZone(identifier: tzId) {
                return buildTimePayload(now: now, tz: tz)
            }

            // Try as direct IANA identifier
            if let tz = TimeZone(identifier: place) {
                return buildTimePayload(now: now, tz: tz)
            }

            // Unknown place — prompt for clarification
            return buildPromptPayload(
                slot: "timezone",
                spoken: "I'm not sure which timezone \(place) is in. Could you give me a specific city name?",
                formatted: "Unknown place: \(place). Provide a city name or IANA timezone ID."
            )
        }

        // 3. No timezone or place — use device local timezone
        return buildTimePayload(now: now, tz: .current)
    }

    // MARK: - Payload Builders

    private func buildTimePayload(now: Date, tz: TimeZone) -> OutputItem {
        let spokenFormatter = DateFormatter()
        spokenFormatter.timeZone = tz
        spokenFormatter.dateFormat = "h:mm a"
        let spokenTime = spokenFormatter.string(from: now)
        let spoken = "It's \(spokenTime)."

        let fullFormatter = DateFormatter()
        fullFormatter.timeZone = tz
        fullFormatter.dateStyle = .full
        fullFormatter.timeStyle = .short
        let formatted = fullFormatter.string(from: now)

        let timestamp = Int(now.timeIntervalSince1970)

        let payload: [String: Any] = [
            "kind": "time",
            "spoken": spoken,
            "formatted": formatted,
            "timestamp": timestamp
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: formatted)
    }

    private func buildPromptPayload(slot: String, spoken: String, formatted: String) -> OutputItem {
        let payload: [String: Any] = [
            "kind": "prompt",
            "slot": slot,
            "spoken": spoken,
            "formatted": formatted
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: spoken)
    }

    // MARK: - Payload Parsing

    /// Parses a structured get_time payload. Returns (spoken, formatted, timestamp) or nil.
    static func parsePayload(_ payload: String) -> (spoken: String, formatted: String, timestamp: Int)? {
        guard let data = payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spoken = dict["spoken"] as? String,
              let formatted = dict["formatted"] as? String,
              let timestamp = dict["timestamp"] as? Int
        else { return nil }
        return (spoken, formatted, timestamp)
    }

    /// Parses a prompt payload from get_time. Returns (slot, spoken, formatted) or nil.
    static func parsePromptPayload(_ payload: String) -> (slot: String, spoken: String, formatted: String)? {
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
