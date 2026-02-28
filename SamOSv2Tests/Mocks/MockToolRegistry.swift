import Foundation
@testable import SamOSv2

/// A simple test tool that returns a preconfigured result.
struct MockTool: Tool {
    let name: String
    let description: String
    let parameterDescription: String
    var result: ToolResult

    init(name: String, description: String = "Mock tool", result: ToolResult? = nil) {
        self.name = name
        self.description = description
        self.parameterDescription = ""
        self.result = result ?? ToolResult.success(tool: name, spoken: "Mock tool executed")
    }

    func execute(args: [String: String]) async -> ToolResult {
        result
    }
}

/// Mock tool registry for testing.
final class MockToolRegistry: ToolRegistryProtocol, @unchecked Sendable {
    private var tools: [String: any Tool] = [:]

    var allTools: [any Tool] {
        Array(tools.values)
    }

    func get(_ name: String) -> (any Tool)? {
        tools[name]
    }

    func register(_ tool: any Tool) {
        tools[tool.name] = tool
    }

    func normalizeToolName(_ raw: String) -> String? {
        let lower = raw.lowercased()
        if tools[lower] != nil { return lower }
        return nil
    }
}
