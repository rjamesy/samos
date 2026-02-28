import Foundation

/// Result of executing a tool, with typed output.
struct ToolResult: Sendable {
    let toolName: String
    let success: Bool
    let output: OutputItem?
    let spokenText: String?
    let error: String?

    init(
        toolName: String,
        success: Bool = true,
        output: OutputItem? = nil,
        spokenText: String? = nil,
        error: String? = nil
    ) {
        self.toolName = toolName
        self.success = success
        self.output = output
        self.spokenText = spokenText
        self.error = error
    }

    static func success(tool: String, output: OutputItem? = nil, spoken: String? = nil) -> ToolResult {
        ToolResult(toolName: tool, success: true, output: output, spokenText: spoken)
    }

    static func failure(tool: String, error: String) -> ToolResult {
        ToolResult(toolName: tool, success: false, error: error)
    }
}
