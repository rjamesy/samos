import Foundation

/// JSON Schema definition for a tool's parameters.
struct ToolSchema: Sendable {
    let properties: [String: ToolSchemaProperty]
    let required: [String]

    init(properties: [String: ToolSchemaProperty] = [:], required: [String] = []) {
        self.properties = properties
        self.required = required
    }

    /// Convert to JSON-serializable dictionary.
    func toJSON() -> [String: Any] {
        var props: [String: Any] = [:]
        for (key, prop) in properties {
            var p: [String: Any] = ["type": prop.type]
            if let desc = prop.description { p["description"] = desc }
            if let enumVals = prop.enumValues { p["enum"] = enumVals }
            props[key] = p
        }
        return [
            "type": "object",
            "properties": props,
            "required": required
        ]
    }
}

/// A single property in a tool schema.
struct ToolSchemaProperty: Sendable {
    let type: String
    let description: String?
    let enumValues: [String]?

    init(type: String = "string", description: String? = nil, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }
}

/// A single tool that can be executed by the plan executor.
protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameterDescription: String { get }
    var schema: ToolSchema? { get }
    func execute(args: [String: String]) async -> ToolResult
}

extension Tool {
    /// Default: no schema (tool stays in text manifest only).
    var schema: ToolSchema? { nil }
}

/// Registry of all available tools with alias normalization.
protocol ToolRegistryProtocol: Sendable {
    var allTools: [any Tool] { get }
    func get(_ name: String) -> (any Tool)?
    func register(_ tool: any Tool)
    func normalizeToolName(_ raw: String) -> String?
}
