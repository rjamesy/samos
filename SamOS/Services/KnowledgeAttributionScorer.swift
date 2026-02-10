import Foundation
import NaturalLanguage

enum KnowledgeEvidenceKind: String, Equatable, Codable {
    case memory
    case website
    case selfLearning
}

struct KnowledgeSourceSnippet: Equatable {
    let kind: KnowledgeEvidenceKind
    let id: String?
    let label: String
    let text: String
    let url: String?
}

struct KnowledgeEvidence: Equatable {
    let kind: KnowledgeEvidenceKind
    let id: String?
    let label: String
    let excerpt: String
    let url: String?
    let overlapCount: Int
    let score: Double

    func markdownLine() -> String {
        let clipped = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .website:
            if let url, !url.isEmpty {
                return "Website: [\(label)](\(url)) — \(clipped)"
            }
            return "Website: \(label) — \(clipped)"
        case .memory:
            let token = id?.isEmpty == false ? "`\(id!)`" : "`memory`"
            return "Memory \(token): \(clipped)"
        case .selfLearning:
            let token = id?.isEmpty == false ? "`\(id!)`" : "`lesson`"
            return "Self-learning \(token): \(clipped)"
        }
    }
}

struct KnowledgeAttribution: Equatable {
    let localKnowledgePercent: Int
    let openAIFillPercent: Int
    let matchedLocalItems: Int
    let consideredLocalItems: Int
    let provider: LLMProvider
    let aiModelUsed: String?
    let evidence: [KnowledgeEvidence]

    init(localKnowledgePercent: Int,
         openAIFillPercent: Int,
         matchedLocalItems: Int,
         consideredLocalItems: Int,
         provider: LLMProvider,
         aiModelUsed: String? = nil,
         evidence: [KnowledgeEvidence] = []) {
        self.localKnowledgePercent = localKnowledgePercent
        self.openAIFillPercent = openAIFillPercent
        self.matchedLocalItems = matchedLocalItems
        self.consideredLocalItems = consideredLocalItems
        self.provider = provider
        self.aiModelUsed = aiModelUsed
        self.evidence = evidence
    }

    var usedLocalKnowledge: Bool {
        matchedLocalItems > 0 && localKnowledgePercent >= 20
    }
}

struct KnowledgeAttributionCalibrationCase {
    let name: String
    let userInput: String
    let assistantText: String
    let provider: LLMProvider
    let snippets: [KnowledgeSourceSnippet]
    let expectedLocalPercent: Int
    let tolerancePercent: Int
}

struct KnowledgeAttributionCalibrationReport {
    let caseCount: Int
    let meanAbsoluteError: Double
    let withinToleranceRate: Double
}

enum KnowledgeAttributionScorer {
    private static let responseWeight = 0.72
    private static let queryWeight = 0.28
    private static let topScoreMultiplier = 2.05

    static func score(userInput: String,
                      assistantText: String,
                      provider: LLMProvider,
                      aiModelUsed: String? = nil,
                      localSnippets: [KnowledgeSourceSnippet]) -> KnowledgeAttribution {
        let snippets = dedupeSnippets(localSnippets)
        guard !snippets.isEmpty else {
            return KnowledgeAttribution(
                localKnowledgePercent: 0,
                openAIFillPercent: provider == .openai ? 100 : 0,
                matchedLocalItems: 0,
                consideredLocalItems: 0,
                provider: provider,
                aiModelUsed: aiModelUsed
            )
        }

        let assistantTokens = Set(tokens(from: assistantText))
        let queryTokens = Set(tokens(from: userInput))
        var matches: [(snippet: KnowledgeSourceSnippet, score: Double, responseCommon: Int, queryCommon: Int)] = []

        for snippet in snippets {
            let snippetTokens = Set(tokens(from: snippet.text + " " + snippet.label))
            guard !snippetTokens.isEmpty else { continue }

            let responseCommon = assistantTokens.intersection(snippetTokens).count
            let queryCommon = queryTokens.intersection(snippetTokens).count
            let responseCoverage = assistantTokens.isEmpty
                ? 0.0
                : Double(responseCommon) / Double(assistantTokens.count)
            let queryCoverage = queryTokens.isEmpty
                ? 0.0
                : Double(queryCommon) / Double(queryTokens.count)
            let lexicalBoost = min(0.10, Double(responseCommon) * 0.02)
            let score = (responseCoverage * responseWeight) + (queryCoverage * queryWeight) + lexicalBoost

            matches.append((snippet, score, responseCommon, queryCommon))
        }

        guard !matches.isEmpty else {
            return KnowledgeAttribution(
                localKnowledgePercent: 0,
                openAIFillPercent: provider == .openai ? 100 : 0,
                matchedLocalItems: 0,
                consideredLocalItems: snippets.count,
                provider: provider,
                aiModelUsed: aiModelUsed
            )
        }

        let sortedScores = matches.map(\.score).sorted(by: >)
        let topScores = sortedScores.prefix(4)
        var localRatio = min(0.96, topScores.reduce(0.0, +) * topScoreMultiplier)

        let matched = matches.filter { $0.responseCommon >= 2 || $0.queryCommon >= 2 }
        if !matched.isEmpty {
            localRatio = max(localRatio, 0.20)
        }
        if localRatio < 0.05 {
            localRatio = 0.0
        }

        let localPercent = min(100, max(0, Int((localRatio * 100.0).rounded())))
        let openAIPercent = provider == .openai ? max(0, 100 - localPercent) : 0

        let evidence = matched
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let lhsOverlap = lhs.responseCommon + lhs.queryCommon
                let rhsOverlap = rhs.responseCommon + rhs.queryCommon
                return lhsOverlap > rhsOverlap
            }
            .prefix(5)
            .map { match in
                KnowledgeEvidence(
                    kind: match.snippet.kind,
                    id: match.snippet.id,
                    label: match.snippet.label,
                    excerpt: clip(match.snippet.text, max: 140),
                    url: match.snippet.url,
                    overlapCount: match.responseCommon + match.queryCommon,
                    score: match.score
                )
            }

        return KnowledgeAttribution(
            localKnowledgePercent: localPercent,
            openAIFillPercent: openAIPercent,
            matchedLocalItems: matched.count,
            consideredLocalItems: snippets.count,
            provider: provider,
            aiModelUsed: aiModelUsed,
            evidence: evidence
        )
    }

    static func evaluateCalibration(_ cases: [KnowledgeAttributionCalibrationCase]) -> KnowledgeAttributionCalibrationReport {
        guard !cases.isEmpty else {
            return KnowledgeAttributionCalibrationReport(caseCount: 0, meanAbsoluteError: 0, withinToleranceRate: 1.0)
        }

        var totalAbsError = 0.0
        var withinTolerance = 0

        for testCase in cases {
            let score = self.score(
                userInput: testCase.userInput,
                assistantText: testCase.assistantText,
                provider: testCase.provider,
                localSnippets: testCase.snippets
            )
            let absError = abs(score.localKnowledgePercent - testCase.expectedLocalPercent)
            totalAbsError += Double(absError)
            if absError <= testCase.tolerancePercent {
                withinTolerance += 1
            }
        }

        return KnowledgeAttributionCalibrationReport(
            caseCount: cases.count,
            meanAbsoluteError: totalAbsError / Double(cases.count),
            withinToleranceRate: Double(withinTolerance) / Double(cases.count)
        )
    }

    static func defaultCalibrationCases() -> [KnowledgeAttributionCalibrationCase] {
        var cases: [KnowledgeAttributionCalibrationCase] = []
        let topics = [
            "home brewing", "aeropress coffee", "swift concurrency", "strength training",
            "budget planning", "language learning", "gardening", "meal prep", "sleep hygiene", "cycling"
        ]

        for idx in 0..<20 {
            let topic = topics[idx % topics.count]
            cases.append(
                KnowledgeAttributionCalibrationCase(
                    name: "high-\(idx)",
                    userInput: "what did you learn about \(topic)?",
                    assistantText: "From my saved notes on \(topic), the key steps are sanitize equipment, control fermentation, and track temperature carefully.",
                    provider: .openai,
                    snippets: [
                        KnowledgeSourceSnippet(kind: .memory, id: "m\(idx)", label: "Memory", text: "\(topic) requires sanitize equipment and fermentation temperature control.", url: nil),
                        KnowledgeSourceSnippet(kind: .website, id: "w\(idx)", label: "\(topic) guide", text: "Track yeast, gravity, and temperature to avoid off flavors.", url: "https://example.com/\(topic.replacingOccurrences(of: " ", with: "-"))"),
                        KnowledgeSourceSnippet(kind: .selfLearning, id: "s\(idx)", label: "Lesson", text: "Use concise summaries from local notes before adding new content.", url: nil)
                    ],
                    expectedLocalPercent: 82,
                    tolerancePercent: 18
                )
            )
        }

        for idx in 0..<20 {
            let topic = topics[idx % topics.count]
            cases.append(
                KnowledgeAttributionCalibrationCase(
                    name: "medium-\(idx)",
                    userInput: "give me tips on \(topic)",
                    assistantText: "I can share a quick summary: start with fundamentals and adjust based on your setup.",
                    provider: .openai,
                    snippets: [
                        KnowledgeSourceSnippet(kind: .memory, id: "mM\(idx)", label: "Memory", text: "User previously asked about \(topic) starter setup.", url: nil),
                        KnowledgeSourceSnippet(kind: .website, id: "wM\(idx)", label: "\(topic) notes", text: "Begin with clean process and stable schedule.", url: "https://example.com/tips-\(idx)"),
                        KnowledgeSourceSnippet(kind: .selfLearning, id: "sM\(idx)", label: "Lesson", text: "Give short summaries first, then details in canvas.", url: nil)
                    ],
                    expectedLocalPercent: 48,
                    tolerancePercent: 20
                )
            )
        }

        for idx in 0..<20 {
            let topic = topics[idx % topics.count]
            cases.append(
                KnowledgeAttributionCalibrationCase(
                    name: "low-\(idx)",
                    userInput: "what is quantum teleportation for beginners?",
                    assistantText: "Quantum teleportation transfers state information using entanglement and classical communication.",
                    provider: .openai,
                    snippets: [
                        KnowledgeSourceSnippet(kind: .memory, id: "mL\(idx)", label: "Memory", text: "User likes \(topic).", url: nil),
                        KnowledgeSourceSnippet(kind: .website, id: "wL\(idx)", label: "\(topic) notes", text: "How to improve \(topic) routine at home.", url: "https://example.com/local-\(idx)"),
                        KnowledgeSourceSnippet(kind: .selfLearning, id: "sL\(idx)", label: "Lesson", text: "Ask one follow-up question only when useful.", url: nil)
                    ],
                    expectedLocalPercent: 8,
                    tolerancePercent: 12
                )
            )
        }

        return cases
    }

    static func tokens(from text: String) -> [String] {
        LocalKnowledgeRetriever.tokens(from: text)
    }

    private static func dedupeSnippets(_ snippets: [KnowledgeSourceSnippet]) -> [KnowledgeSourceSnippet] {
        var seen: Set<String> = []
        var output: [KnowledgeSourceSnippet] = []
        for snippet in snippets {
            let text = snippet.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let key = "\(snippet.kind.rawValue)|\(snippet.id ?? "")|\(snippet.url ?? "")|\(text.lowercased())"
            if seen.contains(key) { continue }
            seen.insert(key)
            output.append(
                KnowledgeSourceSnippet(
                    kind: snippet.kind,
                    id: snippet.id,
                    label: snippet.label,
                    text: text,
                    url: snippet.url
                )
            )
        }
        return output
    }

    private static func clip(_ value: String, max: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max - 3)) + "..."
    }
}

struct RetrievalRankedItem<T> {
    let item: T
    let finalScore: Double
    let semanticScore: Double
    let lexicalScore: Double
    let coverageScore: Double
    let recencyScore: Double
    let sharedTokenCount: Int
}

enum LocalKnowledgeRetriever {
    private static let defaultHashDimension = 192
    // Prefer real on-device semantic vectors when available, with hashed fallback.
    private static let semanticEmbedding: NLEmbedding? = {
        NLEmbedding.wordEmbedding(for: .english)
    }()
    private static let semanticDimension = semanticEmbedding?.dimension ?? defaultHashDimension
    private static let retrievalQueue = DispatchQueue(label: "LocalKnowledgeRetriever.cache")
    private static var idfCache: [String: [String: Double]] = [:]
    private static var queryExpansionCache: [String: [String]] = [:]
    private static let expansionFallbackMap: [String: [String]] = [
        "dog": ["canine", "puppy", "pet"],
        "cat": ["feline", "kitten", "pet"],
        "coffee": ["espresso", "caffeine", "brew"],
        "beer": ["brewing", "fermentation", "ale"],
        "weather": ["forecast", "temperature", "rain"],
        "recipe": ["ingredients", "cooking", "steps"],
        "camera": ["photo", "image", "visual"]
    ]

    static func tokens(from text: String) -> [String] {
        tokenize(text, includeBigrams: false)
    }

    static func expandedQueryTokens(from query: String) -> [String] {
        let base = tokenize(query, includeBigrams: false)
        let expanded = expandedTokens(from: base)
        return uniqueTokens(base + expanded)
    }

    static func rank<T>(
        query: String,
        items: [T],
        text: (T) -> String,
        recencyDate: ((T) -> Date?)? = nil,
        extraBoost: (T) -> Double = { _ in 0 },
        limit: Int? = nil,
        minScore: Double = 0.12,
        requireTokenOverlap: Bool = false
    ) -> [RetrievalRankedItem<T>] {
        guard !items.isEmpty else { return [] }

        let baseQueryTokens = tokenize(query, includeBigrams: false)
        let expandedQueryTokens = expandedTokens(from: baseQueryTokens)
        let queryTokens = uniqueTokens(baseQueryTokens + expandedQueryTokens)
        let queryBigrams = bigrams(queryTokens)
        let queryVector = embeddingVector(from: queryTokens + queryBigrams)

        if queryTokens.isEmpty && queryBigrams.isEmpty {
            let sorted = items
                .sorted { lhs, rhs in
                    let lhsDate = recencyDate?(lhs) ?? .distantPast
                    let rhsDate = recencyDate?(rhs) ?? .distantPast
                    if lhsDate != rhsDate { return lhsDate > rhsDate }
                    return extraBoost(lhs) > extraBoost(rhs)
                }
            let capped = limit.map { Array(sorted.prefix(max(1, $0))) } ?? sorted
            return capped.map { item in
                RetrievalRankedItem(
                    item: item,
                    finalScore: max(0.0, min(1.0, 0.5 + extraBoost(item))),
                    semanticScore: 0.0,
                    lexicalScore: 0.0,
                    coverageScore: 0.0,
                    recencyScore: recencyDate.map { normalizedRecency($0(item)) } ?? 0.0,
                    sharedTokenCount: 0
                )
            }
        }

        let now = Date()
        let documents = items.map { item -> (item: T, text: String, tokens: [String], set: Set<String>, vector: [Double]) in
            let raw = text(item)
            let docTokens = tokenize(raw, includeBigrams: false)
            let docVector = embeddingVector(from: docTokens + bigrams(docTokens))
            return (item, raw, docTokens, Set(docTokens), docVector)
        }

        let querySet = Set(queryTokens)
        let queryIDF = inverseDocumentFrequency(queryTokens: queryTokens, documents: documents.map(\.set))

        var ranked: [RetrievalRankedItem<T>] = []
        ranked.reserveCapacity(items.count)

        for doc in documents {
            let shared = querySet.intersection(doc.set)
            let sharedCount = shared.count
            let semantic = cosineSimilarity(queryVector, doc.vector)
            let coverage = weightedCoverage(sharedTokens: shared, queryTokens: queryTokens, idf: queryIDF)
            let jaccard = jaccardSimilarity(querySet, doc.set)
            let lexical = min(1.0, (coverage * 0.72) + (jaccard * 0.28))
            let phrase = phraseContainment(queryBigrams: queryBigrams, docTokens: doc.tokens)
            let recency = normalizedRecency(recencyDate?(doc.item), now: now)
            let boost = extraBoost(doc.item)

            var final = (semantic * 0.50) + (lexical * 0.30) + (coverage * 0.10) + (phrase * 0.05) + (recency * 0.05) + boost
            if sharedCount == 0 && semantic < 0.24 {
                final *= 0.25
            }

            guard final >= minScore else { continue }
            if requireTokenOverlap && sharedCount == 0 { continue }
            guard sharedCount > 0 || semantic >= 0.28 else { continue }

            ranked.append(
                RetrievalRankedItem(
                    item: doc.item,
                    finalScore: final,
                    semanticScore: semantic,
                    lexicalScore: lexical,
                    coverageScore: coverage,
                    recencyScore: recency,
                    sharedTokenCount: sharedCount
                )
            )
        }

        ranked.sort { lhs, rhs in
            if lhs.finalScore != rhs.finalScore { return lhs.finalScore > rhs.finalScore }
            if lhs.coverageScore != rhs.coverageScore { return lhs.coverageScore > rhs.coverageScore }
            if lhs.sharedTokenCount != rhs.sharedTokenCount { return lhs.sharedTokenCount > rhs.sharedTokenCount }
            return lhs.semanticScore > rhs.semanticScore
        }

        if let limit {
            return Array(ranked.prefix(max(1, limit)))
        }
        return ranked
    }

    private static func tokenize(_ text: String, includeBigrams: Bool) -> [String] {
        let base = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(normalizeToken)
            .filter { token in
                !token.isEmpty && token.count > 1 && !stopwords.contains(token)
            }

        if !includeBigrams {
            return base
        }
        return base + bigrams(base)
    }

    private static func uniqueTokens(_ tokens: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        output.reserveCapacity(tokens.count)
        for token in tokens where !token.isEmpty {
            if seen.insert(token).inserted {
                output.append(token)
            }
        }
        return output
    }

    private static func expandedTokens(from tokens: [String], maxExtraPerToken: Int = 2) -> [String] {
        guard !tokens.isEmpty else { return [] }

        var expanded: [String] = []
        for token in tokens {
            expanded.append(contentsOf: expansionCandidates(for: token, maxCount: maxExtraPerToken))
        }
        return uniqueTokens(expanded.filter { !stopwords.contains($0) && $0.count > 1 })
    }

    private static func expansionCandidates(for token: String, maxCount: Int) -> [String] {
        let key = token.lowercased()
        let cached: [String]? = retrievalQueue.sync { queryExpansionCache[key] }
        if let cached {
            return Array(cached.prefix(maxCount))
        }

        var expanded = expansionFallbackMap[key] ?? []
        if let embedding = semanticEmbedding {
            let neighbors = embedding.neighbors(for: key, maximumCount: max(1, maxCount + 2))
            for neighbor in neighbors {
                let normalized = normalizeToken(neighbor.0.lowercased())
                guard !normalized.isEmpty, normalized != key else { continue }
                if !expanded.contains(normalized) {
                    expanded.append(normalized)
                }
                if expanded.count >= max(1, maxCount + 2) {
                    break
                }
            }
        }

        let deduped = uniqueTokens(expanded)
        retrievalQueue.sync {
            queryExpansionCache[key] = deduped
            if queryExpansionCache.count > 512 {
                queryExpansionCache.removeAll(keepingCapacity: true)
            }
        }
        return Array(deduped.prefix(maxCount))
    }

    private static func normalizeToken(_ token: String) -> String {
        var value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }

        if value.hasSuffix("ies"), value.count > 4 {
            value = String(value.dropLast(3)) + "y"
        } else if value.hasSuffix("ing"), value.count > 5 {
            value = String(value.dropLast(3))
        } else if value.hasSuffix("ed"), value.count > 4 {
            value = String(value.dropLast(2))
        } else if value.hasSuffix("es"), value.count > 4 {
            value = String(value.dropLast(2))
        } else if value.hasSuffix("s"), value.count > 3 {
            value = String(value.dropLast(1))
        }

        return value
    }

    private static func bigrams(_ tokens: [String]) -> [String] {
        guard tokens.count >= 2 else { return [] }
        var result: [String] = []
        result.reserveCapacity(tokens.count - 1)
        for idx in 0..<(tokens.count - 1) {
            result.append(tokens[idx] + "_" + tokens[idx + 1])
        }
        return result
    }

    private static func embeddingVector(from tokens: [String], dimension: Int? = nil) -> [Double] {
        let vectorDimension = max(1, dimension ?? semanticDimension)
        guard !tokens.isEmpty else { return Array(repeating: 0, count: vectorDimension) }

        var tf: [String: Double] = [:]
        for token in tokens {
            tf[token, default: 0] += 1
        }

        if let embedding = semanticEmbedding {
            var vector = Array(repeating: 0.0, count: embedding.dimension)
            var used = 0
            for (token, count) in tf {
                guard let wordVector = embedding.vector(for: token), wordVector.count == embedding.dimension else {
                    continue
                }
                let weight = 1.0 + log(count)
                for idx in 0..<embedding.dimension {
                    vector[idx] += Double(wordVector[idx]) * weight
                }
                used += 1
            }

            if used > 0 {
                let norm = sqrt(vector.reduce(0.0) { $0 + ($1 * $1) })
                if norm > 0 {
                    return vector.map { $0 / norm }
                }
            }
        }

        return hashedEmbeddingVector(from: tf, dimension: vectorDimension)
    }

    private static func hashedEmbeddingVector(from tf: [String: Double], dimension: Int) -> [Double] {
        var vector = Array(repeating: 0.0, count: dimension)
        for (token, count) in tf {
            let weight = 1.0 + log(count)
            let hash = fnv1a64(token)
            let index = Int(hash % UInt64(dimension))
            let sign = ((hash >> 8) & 1) == 0 ? 1.0 : -1.0
            vector[index] += weight * sign
        }
        let norm = sqrt(vector.reduce(0.0) { $0 + ($1 * $1) })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0.0 }
        var dot = 0.0
        for idx in lhs.indices {
            dot += lhs[idx] * rhs[idx]
        }
        return max(0.0, dot)
    }

    private static func inverseDocumentFrequency(queryTokens: [String], documents: [Set<String>]) -> [String: Double] {
        let uniqueTokens = Set(queryTokens)
        guard !uniqueTokens.isEmpty else { return [:] }

        let cacheKey = idfCacheKey(tokens: uniqueTokens, documents: documents)
        let cached: [String: Double]? = retrievalQueue.sync { idfCache[cacheKey] }
        if let cached {
            return cached
        }

        let docCount = max(1.0, Double(documents.count))
        var documentFrequency: [String: Int] = [:]
        documentFrequency.reserveCapacity(uniqueTokens.count)
        for token in uniqueTokens {
            documentFrequency[token] = 0
        }
        for doc in documents {
            for token in uniqueTokens where doc.contains(token) {
                documentFrequency[token, default: 0] += 1
            }
        }

        var map: [String: Double] = [:]
        map.reserveCapacity(uniqueTokens.count)
        for token in uniqueTokens {
            let df = Double(documentFrequency[token] ?? 0)
            map[token] = log((docCount + 1.0) / (df + 1.0)) + 1.0
        }

        retrievalQueue.sync {
            idfCache[cacheKey] = map
            if idfCache.count > 256 {
                idfCache.removeAll(keepingCapacity: true)
            }
        }
        return map
    }

    private static func idfCacheKey(tokens: Set<String>, documents: [Set<String>]) -> String {
        let tokenPart = tokens.sorted().joined(separator: "|")
        let docHashes = documents.map { doc -> UInt64 in
            let sorted = doc.sorted().joined(separator: "|")
            return fnv1a64(sorted)
        }
        let combined = docHashes.reduce(UInt64(1469598103934665603)) { partial, hash in
            (partial ^ hash) &* 1099511628211
        }
        return "\(tokenPart)#\(combined)"
    }

    private static func weightedCoverage(sharedTokens: Set<String>, queryTokens: [String], idf: [String: Double]) -> Double {
        guard !queryTokens.isEmpty else { return 0.0 }
        let total = queryTokens.reduce(0.0) { partial, token in
            partial + (idf[token] ?? 1.0)
        }
        guard total > 0 else { return 0.0 }
        let matched = sharedTokens.reduce(0.0) { partial, token in
            partial + (idf[token] ?? 1.0)
        }
        return min(1.0, matched / total)
    }

    private static func jaccardSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0.0 }
        let intersection = Double(lhs.intersection(rhs).count)
        let union = Double(lhs.union(rhs).count)
        guard union > 0 else { return 0.0 }
        return intersection / union
    }

    private static func phraseContainment(queryBigrams: [String], docTokens: [String]) -> Double {
        guard !queryBigrams.isEmpty, docTokens.count >= 2 else { return 0.0 }
        let docBigrams = Set(bigrams(docTokens))
        let overlap = Double(queryBigrams.filter { docBigrams.contains($0) }.count)
        return min(1.0, overlap / Double(queryBigrams.count))
    }

    private static func normalizedRecency(_ date: Date?, now: Date = Date()) -> Double {
        guard let date else { return 0.0 }
        let ageDays = max(0.0, now.timeIntervalSince(date) / 86_400.0)
        return max(0.0, 1.0 - min(1.0, ageDays / 21.0))
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        let offset: UInt64 = 1_469_598_103_934_665_603
        let prime: UInt64 = 1_099_511_628_211
        var hash = offset
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "to", "for", "of", "in", "on", "at",
        "and", "or", "it", "this", "that", "be", "with", "as", "by", "i", "you", "we", "they",
        "he", "she", "do", "does", "did", "can", "could", "should", "would", "if", "from",
        "what", "when", "where", "why", "how", "about", "into", "onto", "also", "my", "your"
    ]
}
