import Foundation

protocol ToolRegistryContract {
    var allTools: [Tool] { get }
    func get(_ name: String) -> Tool?
    func register(_ tool: Tool)
    func normalizeToolName(_ raw: String) -> String?
    func isAllowedTool(_ name: String) -> Bool
}

extension ToolRegistry: ToolRegistryContract {}

protocol ToolRegistryContributor {
    func register(into registry: ToolRegistry)
}
