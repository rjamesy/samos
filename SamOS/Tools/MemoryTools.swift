import Foundation

// MARK: - Save Memory Tool

struct SaveMemoryTool: Tool {
    let name = "save_memory"
    let description = "Save a persistent memory (fact, preference, or note)"

    func execute(args: [String: String]) -> OutputItem {
        guard let typeStr = args["type"], let type = MemoryType(rawValue: typeStr.lowercased()) else {
            return OutputItem(kind: .markdown, payload: "**Memory Error:** Invalid type. Use `fact`, `preference`, or `note`.")
        }

        let rawContent = (args["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawContent.isEmpty else {
            return OutputItem(kind: .markdown, payload: "I couldn't save that — what would you like me to remember?")
        }

        guard MemoryStore.shared.isAvailable else {
            return OutputItem(kind: .markdown, payload: "**Memory Error:** Memory store is not available.")
        }

        let source = args["source"] ?? "user_explicit"

        // Split compound content into separate facts
        let parts = SaveMemoryTool.splitCompoundContent(rawContent)
        var results: [String] = []

        for part in parts {
            let result = saveSingleMemory(type: type, content: part, source: source)
            results.append(result)
        }

        if results.count == 1 {
            return OutputItem(kind: .markdown, payload: results[0])
        }

        return OutputItem(kind: .markdown, payload: results.joined(separator: "\n"))
    }

    /// Saves a single memory clause with dedup/update logic.
    private func saveSingleMemory(type: MemoryType, content: String, source: String) -> String {
        let store = MemoryStore.shared

        switch store.checkForDuplicate(type: type, content: content) {
        case .duplicate:
            return "I already have that saved."

        case .refinement(let existing):
            if let row = store.replaceMemory(old: existing, newContent: content, source: source) {
                return "Updated **\(type.rawValue)**: \(row.content) `(\(row.shortID))`"
            }
            return "**Memory Error:** Failed to update memory."

        case .highValueReplace(let existing):
            if let row = store.replaceMemory(old: existing, newContent: content, source: source) {
                return "Updated **\(type.rawValue)**: \(row.content) `(\(row.shortID))`"
            }
            return "**Memory Error:** Failed to update memory."

        case .noDuplicate:
            if let row = store.addMemory(type: type, content: content, source: source) {
                return "Saved **\(type.rawValue)**: \(row.content) `(\(row.shortID))`"
            }
            return "**Memory Error:** Failed to save memory."
        }
    }

    // MARK: - Compound Splitting

    /// Splits compound content like "my dog's name is Bailey and he's a golden retriever"
    /// into separate memory sentences. Returns 1-3 parts.
    static func splitCompoundContent(_ content: String) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Split on " and " only if both halves are meaningful (>= 2 words)
        let parts = trimmed.components(separatedBy: " and ")
        guard parts.count >= 2, parts.count <= 4 else {
            return [normalize(trimmed)]
        }

        let meaningful = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.split(separator: " ").count >= 2 }

        guard meaningful.count >= 2 else {
            return [normalize(trimmed)]
        }

        // Extract a name from the first clause for pronoun resolution
        let extractedName = extractName(from: meaningful[0])

        var results: [String] = []
        for (i, part) in meaningful.prefix(3).enumerated() {
            var normalized = part
            if i > 0, let name = extractedName {
                normalized = resolvePronoun(in: normalized, name: name)
            }
            results.append(normalize(normalized))
        }

        return results
    }

    /// Normalizes a memory sentence: "my X" → "Your X", ensures period, capitalizes.
    static func normalize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // "my X" → "Your X"
        if result.lowercased().hasPrefix("my ") {
            result = "Your " + result.dropFirst(3)
        }

        // Ensure ends with period
        if !result.hasSuffix(".") && !result.hasSuffix("!") && !result.hasSuffix("?") {
            result += "."
        }

        // Capitalize first letter
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }

    /// Extracts a proper name from a clause like "my dog's name is Bailey".
    private static func extractName(from clause: String) -> String? {
        let lower = clause.lowercased()

        // "name is X" pattern
        if let range = lower.range(of: "name is ") {
            let afterIs = String(clause[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = afterIs.components(separatedBy: " ").first ?? ""
            if !name.isEmpty { return name.trimmingCharacters(in: .punctuationCharacters) }
        }

        // "called X" pattern
        if let range = lower.range(of: "called ") {
            let afterCalled = String(clause[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = afterCalled.components(separatedBy: " ").first ?? ""
            if !name.isEmpty { return name.trimmingCharacters(in: .punctuationCharacters) }
        }

        return nil
    }

    /// Resolves "he's a X" → "Name is a X" using the extracted name.
    static func resolvePronoun(in text: String, name: String) -> String {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pronounStarts = [
            "he's ", "she's ", "it's ",
            "he is ", "she is ", "it is ",
            "they're ", "they are ",
        ]
        for pattern in pronounStarts {
            if lower.hasPrefix(pattern) {
                let remainder = String(text.dropFirst(pattern.count))
                return "\(name) is \(remainder)"
            }
        }
        return text
    }
}

// MARK: - List Memories Tool

struct ListMemoriesTool: Tool {
    let name = "list_memories"
    let description = "List all saved memories, optionally filtered by type"

    func execute(args: [String: String]) -> OutputItem {
        guard MemoryStore.shared.isAvailable else {
            return OutputItem(kind: .markdown, payload: "**Memory Error:** Memory store is not available.")
        }

        let filterType: MemoryType? = args["type"].flatMap { MemoryType(rawValue: $0.lowercased()) }
        let memories = MemoryStore.shared.listMemories(filterType: filterType)

        if memories.isEmpty {
            let typeLabel = filterType.map { " (\($0.rawValue))" } ?? ""
            return OutputItem(kind: .markdown, payload: "No memories saved yet\(typeLabel).")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        var md = "# Memories\n\n"
        md += "| ID | Type | Content | Date |\n"
        md += "|:---|:-----|:--------|:-----|\n"
        for mem in memories {
            md += "| `\(mem.shortID)` | \(mem.type.rawValue) | \(mem.content) | \(dateFormatter.string(from: mem.createdAt)) |\n"
        }
        md += "\n*\(memories.count) memor\(memories.count == 1 ? "y" : "ies") total.*"

        return OutputItem(kind: .markdown, payload: md)
    }
}

// MARK: - Delete Memory Tool

struct DeleteMemoryTool: Tool {
    let name = "delete_memory"
    let description = "Delete a memory by its ID or short ID"

    func execute(args: [String: String]) -> OutputItem {
        guard let id = args["id"], !id.isEmpty else {
            return OutputItem(kind: .markdown, payload: "**Memory Error:** No ID provided.")
        }

        guard MemoryStore.shared.isAvailable else {
            return OutputItem(kind: .markdown, payload: "**Memory Error:** Memory store is not available.")
        }

        if MemoryStore.shared.deleteMemory(idOrPrefix: id) {
            return OutputItem(kind: .markdown, payload: "Memory `\(id.prefix(8))` deleted.")
        } else {
            return OutputItem(kind: .markdown, payload: "**Memory Error:** No active memory found matching `\(id.prefix(8))`.")
        }
    }
}

// MARK: - Clear Memories Tool

struct ClearMemoriesTool: Tool {
    let name = "clear_memories"
    let description = "Clear all saved memories"

    func execute(args: [String: String]) -> OutputItem {
        guard MemoryStore.shared.isAvailable else {
            return OutputItem(kind: .markdown, payload: "**Memory Error:** Memory store is not available.")
        }

        MemoryStore.shared.clearMemories()
        return OutputItem(kind: .markdown, payload: "All memories cleared.")
    }
}
