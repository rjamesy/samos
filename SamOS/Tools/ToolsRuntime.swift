import Foundation

// MARK: - Tools Runtime Protocol

/// Abstraction over tool execution so tests can inject a mock.
protocol ToolsRuntimeProtocol {
    func execute(_ toolAction: ToolAction) -> OutputItem?
}

// MARK: - Tools Runtime

/// Executes tool actions by dispatching to the ToolRegistry.
final class ToolsRuntime: ToolsRuntimeProtocol {
    static let shared = ToolsRuntime()

    private let registry = ToolRegistry.shared

    private init() {}

    /// Execute a ToolAction and return the resulting OutputItem.
    /// Returns nil if the tool is not found.
    func execute(_ toolAction: ToolAction) -> OutputItem? {
        guard let tool = registry.get(toolAction.name) else {
            return OutputItem(
                kind: .markdown,
                payload: "**Error:** Unknown tool `\(toolAction.name)`."
            )
        }
        return tool.execute(args: toolAction.args)
    }
}
