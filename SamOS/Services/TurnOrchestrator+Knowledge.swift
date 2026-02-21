import Foundation

// MARK: - Knowledge Sources & Memory

extension TurnOrchestrator {

    func buildLocalKnowledgeContext(for input: String) -> LocalKnowledgeContext {
        let semanticInjection = SemanticMemoryPipeline.shared.injectionContext(for: input)
        let memoryRows = fastMemoryHints(for: input, maxItems: 8, maxChars: 1200)
        let legacyMemoryItems = memoryRows.map { row in
            KnowledgeSourceSnippet(
                kind: .memory,
                id: row.shortID,
                label: "Memory (\(row.type.rawValue))",
                text: row.content,
                url: nil
            )
        }
        let mergedItems = semanticInjection.snippets + legacyMemoryItems
        return LocalKnowledgeContext(
            items: dedupeKnowledgeSnippets(mergedItems),
            memoryPromptBlock: semanticInjection.block,
            memoryShouldClarify: semanticInjection.shouldClarify,
            memoryClarificationPrompt: semanticInjection.clarificationPrompt
        )
    }

    func fastMemoryHints(for query: String, maxItems: Int, maxChars: Int) -> [MemoryRow] {
        // Use temporal-aware memory retrieval so "what did I say yesterday?" etc. works
        MemoryStore.shared.temporalMemoryContext(
            query: query,
            maxItems: max(1, maxItems),
            maxChars: max(120, maxChars)
        )
    }

    func relevantWebsiteKnowledgeSnippets(query: String, maxItems: Int) -> [KnowledgeSourceSnippet] {
        let records = WebsiteLearningStore.shared.allRecords()
        guard !records.isEmpty else { return [] }
        let ranked = LocalKnowledgeRetriever.rank(
            query: query,
            items: records,
            text: { record in
                "\(record.title) \(record.summary) \(record.highlights.joined(separator: " ")) \(record.host)"
            },
            recencyDate: { $0.updatedAt },
            extraBoost: { record in
                min(0.08, Double(record.highlights.count) * 0.02)
            },
            limit: max(1, maxItems * 4),
            minScore: 0.08
        )

        var selected: [KnowledgeSourceSnippet] = []
        for entry in ranked {
            let record = entry.item
            guard selected.count < max(1, maxItems) else { break }
            selected.append(
                KnowledgeSourceSnippet(
                    kind: .website,
                    id: String(record.id.uuidString.prefix(8)).lowercased(),
                    label: record.title,
                    text: record.summary,
                    url: record.url
                )
            )
        }

        return selected
    }

    func relevantSelfLearningSnippets(query: String, maxItems: Int, maxChars: Int) -> [KnowledgeSourceSnippet] {
        let lessons = SelfLearningStore.shared.allLessons()
        guard !lessons.isEmpty else { return [] }
        let ranked = LocalKnowledgeRetriever.rank(
            query: query,
            items: lessons,
            text: { "[\($0.category.rawValue)] \($0.text)" },
            recencyDate: { $0.lastUpdatedAt },
            extraBoost: { lesson in
                let confidence = lesson.confidence * 0.20
                let observedBoost = min(0.14, log2(Double(max(1, lesson.observedCount)) + 1.0) * 0.05)
                let appliedBoost = min(0.10, log2(Double(max(1, lesson.appliedCount)) + 1.0) * 0.04)
                return confidence + observedBoost + appliedBoost
            },
            limit: max(1, maxItems * 4),
            minScore: 0.08
        )

        var items: [KnowledgeSourceSnippet] = []
        var usedChars = 0
        let cappedItems = max(1, maxItems)

        for entry in ranked {
            let lesson = entry.item
            guard items.count < cappedItems else { break }
            let line = String(lesson.text.prefix(220)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let nextChars = usedChars + line.count
            if !items.isEmpty && nextChars > maxChars { break }
            if items.isEmpty && line.count > maxChars { continue }
            items.append(
                KnowledgeSourceSnippet(
                    kind: .selfLearning,
                    id: String(lesson.id.uuidString.prefix(8)).lowercased(),
                    label: "Lesson (\(lesson.category.rawValue))",
                    text: line,
                    url: nil
                )
            )
            usedChars = nextChars
        }

        return items
    }

    func dedupeKnowledgeSnippets(_ snippets: [KnowledgeSourceSnippet]) -> [KnowledgeSourceSnippet] {
        var seen: Set<String> = []
        var output: [KnowledgeSourceSnippet] = []
        for snippet in snippets {
            let trimmed = snippet.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = "\(snippet.kind.rawValue)|\(snippet.id ?? "")|\(snippet.url ?? "")|\(trimmed.lowercased())"
            if seen.contains(key) { continue }
            seen.insert(key)
            output.append(
                KnowledgeSourceSnippet(
                    kind: snippet.kind,
                    id: snippet.id,
                    label: snippet.label,
                    text: trimmed,
                    url: snippet.url
                )
            )
        }
        return output
    }

}
