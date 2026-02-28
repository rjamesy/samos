import Foundation

/// Learns from a website URL.
struct LearnWebsiteTool: Tool {
    let name = "learn_website"
    let description = "Learn and summarize content from a website URL"
    let parameterDescription = "Args: url (string)"
    let webLearner: WebLearningService

    var schema: ToolSchema? {
        ToolSchema(properties: [
            "url": ToolSchemaProperty(description: "The URL to learn from")
        ], required: ["url"])
    }

    func execute(args: [String: String]) async -> ToolResult {
        let url = args["url"] ?? args["link"] ?? args["website"] ?? ""
        guard !url.isEmpty else {
            return .failure(tool: name, error: "No URL provided")
        }
        guard URL(string: url) != nil else {
            return .failure(tool: name, error: "Invalid URL: \(url)")
        }
        do {
            let website = try await webLearner.learnFromURL(url)
            return .success(tool: name, spoken: "Learned from '\(website.title)'. \(website.summary)")
        } catch {
            return .failure(tool: name, error: "Failed to learn from URL: \(error.localizedDescription)")
        }
    }
}

/// Starts autonomous web research.
struct AutonomousLearnTool: Tool {
    let name = "autonomous_learn"
    let description = "Start autonomous web research on a topic"
    let parameterDescription = "Args: topic|query (string)"
    let research: AutonomousResearchService

    func execute(args: [String: String]) async -> ToolResult {
        let topic = args["topic"] ?? args["query"] ?? args["subject"] ?? ""
        guard !topic.isEmpty else {
            return .failure(tool: name, error: "No topic provided")
        }
        do {
            let findings = try await research.startResearch(topic: topic)
            if findings.isEmpty {
                return .success(tool: name, spoken: "Research on '\(topic)' completed but found no results.")
            }
            let summary = findings.prefix(3).map { $0.content }.joined(separator: " ")
            let truncated = String(summary.prefix(500))
            return .success(tool: name, spoken: "Research on '\(topic)' found \(findings.count) sources. \(truncated)")
        } catch {
            return .failure(tool: name, error: "Research failed: \(error.localizedDescription)")
        }
    }
}

/// Stops autonomous learning.
struct StopAutonomousLearnTool: Tool {
    let name = "stop_autonomous_learn"
    let description = "Stop the current autonomous learning session"
    let parameterDescription = "No args"
    let research: AutonomousResearchService

    func execute(args: [String: String]) async -> ToolResult {
        await research.stopResearch()
        return .success(tool: name, spoken: "Autonomous learning stopped.")
    }
}
