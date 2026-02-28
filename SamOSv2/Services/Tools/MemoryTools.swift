import Foundation

/// Saves a memory entry.
struct SaveMemoryTool: Tool {
    let name = "save_memory"
    let description = "Save a memory (fact, preference, note, or check-in)"
    let parameterDescription = "Args: type (fact/preference/note/checkin), content (string)"
    let memoryStore: any MemoryStoreProtocol

    var schema: ToolSchema? {
        ToolSchema(properties: [
            "type": ToolSchemaProperty(description: "Memory type", enumValues: ["fact", "preference", "note", "checkin"]),
            "content": ToolSchemaProperty(description: "The content to remember")
        ], required: ["content"])
    }

    func execute(args: [String: String]) async -> ToolResult {
        let typeStr = args["type"] ?? "fact"
        let content = args["content"] ?? args["text"] ?? args["memory"] ?? ""
        guard !content.isEmpty else {
            return .failure(tool: name, error: "No content provided")
        }
        let type = MemoryType(rawValue: typeStr) ?? .fact
        do {
            let row = try await memoryStore.addMemory(type: type, content: content, source: "user_explicit")
            return .success(tool: name, spoken: "Saved \(type.rawValue): \(content) (\(row.shortID))")
        } catch {
            return .failure(tool: name, error: error.localizedDescription)
        }
    }
}

/// Lists stored memories.
struct ListMemoriesTool: Tool {
    let name = "list_memories"
    let description = "List stored memories, optionally filtered by type"
    let parameterDescription = "Args: type (optional: fact/preference/note/checkin)"
    let memoryStore: any MemoryStoreProtocol

    func execute(args: [String: String]) async -> ToolResult {
        let filterType = args["type"].flatMap { MemoryType(rawValue: $0) }
        let memories = await memoryStore.listMemories(filterType: filterType)
        if memories.isEmpty {
            return .success(tool: name, spoken: "No memories found.")
        }
        let list = memories.prefix(20).map { "[\($0.type.rawValue)] \($0.content)" }.joined(separator: "; ")
        return .success(tool: name, spoken: "I have \(memories.count) memories: \(list)")
    }
}

/// Deletes a specific memory by ID.
struct DeleteMemoryTool: Tool {
    let name = "delete_memory"
    let description = "Delete a specific memory by its ID"
    let parameterDescription = "Args: id (memory ID or short ID)"
    let memoryStore: any MemoryStoreProtocol

    func execute(args: [String: String]) async -> ToolResult {
        let id = args["id"] ?? args["memory_id"] ?? ""
        guard !id.isEmpty else {
            return .failure(tool: name, error: "No memory ID provided")
        }
        do {
            try await memoryStore.deleteMemory(id: id)
            return .success(tool: name, spoken: "Memory deleted.")
        } catch {
            return .failure(tool: name, error: error.localizedDescription)
        }
    }
}

/// Clears all memories.
struct ClearMemoriesTool: Tool {
    let name = "clear_memories"
    let description = "Clear all stored memories"
    let parameterDescription = "No args"
    let memoryStore: any MemoryStoreProtocol

    func execute(args: [String: String]) async -> ToolResult {
        do {
            try await memoryStore.clearMemories()
            return .success(tool: name, spoken: "All memories have been cleared.")
        } catch {
            return .failure(tool: name, error: error.localizedDescription)
        }
    }
}

/// Recalls ambient listening observations.
struct RecallAmbientTool: Tool {
    let name = "recall_ambient"
    let description = "Recall recent ambient listening observations"
    let parameterDescription = "No args"

    func execute(args: [String: String]) async -> ToolResult {
        .success(tool: name, spoken: "Ambient listening recall is not yet available.")
    }
}
