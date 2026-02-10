import Foundation

// MARK: - Extracted Memory Model

struct ExtractedMemoryDraft: Equatable {
    let type: MemoryType
    let content: String
    let confidence: MemoryConfidence
    let ttlDays: Int
    let tags: [String]
}

protocol MemoryExtracting {
    func extractMemories(userMessage: String, assistantMessage: String?) async -> [ExtractedMemoryDraft]
}

final class OpenAIMemoryExtractor: MemoryExtracting {

    private enum Constants {
        static let model = "gpt-4o-mini"
        static let timeout: TimeInterval = 1.5
    }

    private struct OpenAIEnvelope: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct ExtractionJSON: Decodable {
        struct MemoryItem: Decodable {
            let type: String
            let content: String
            let confidence: String?
            let ttlDays: Int?
            let tags: [String]?
        }
        let memories: [MemoryItem]
    }

    func extractMemories(userMessage: String, assistantMessage: String?) async -> [ExtractedMemoryDraft] {
        guard OpenAISettings.isConfigured else { return [] }

        let userText = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { return [] }

        do {
            let content = try await withTimeout(seconds: Constants.timeout) {
                try await self.callExtractor(userMessage: userText, assistantMessage: assistantMessage)
            }
            return parseDrafts(from: content)
        } catch {
            return []
        }
    }

    private func callExtractor(userMessage: String, assistantMessage: String?) async throws -> String {
        let systemPrompt = """
        You are extracting personal memories for a single-user assistant.
        Return STRICT JSON: {"memories":[{"type","content","confidence","ttlDays","tags"}]}
        Max 2 memories. Only include if truly useful later.

        Rules:
        - Do NOT save raw transcripts.
        - Content must be a single sentence.
        - Valid types: fact, note, checkin.
        - confidence must be one of: low, med, high.
        - ttlDays should generally be: fact=365, note=90, checkin=7.
        - If nothing useful, return {"memories":[]}.
        """

        var prompt = "User message: \(userMessage)"
        if let assistantMessage = assistantMessage,
           !assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\nAssistant response: \(assistantMessage)"
        }

        let body: [String: Any] = [
            "model": Constants.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.0,
            "max_tokens": 220
        ]

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw NSError(domain: "MemoryExtractor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Constants.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let requestID = OpenAIAPILogStore.shared.logHTTPRequest(
            service: "OpenAIMemoryExtractor.callExtractor",
            endpoint: url.absoluteString,
            method: "POST",
            model: Constants.model,
            timeoutSeconds: request.timeoutInterval,
            payload: body
        )
        let startedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIMemoryExtractor.callExtractor",
                endpoint: url.absoluteString,
                method: "POST",
                model: Constants.model,
                statusCode: nil,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: error.localizedDescription,
                responseData: nil
            )
            throw error
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIMemoryExtractor.callExtractor",
                endpoint: url.absoluteString,
                method: "POST",
                model: Constants.model,
                statusCode: status,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: "Bad HTTP response",
                responseData: data
            )
            throw NSError(domain: "MemoryExtractor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad HTTP response"])
        }
        OpenAIAPILogStore.shared.logHTTPResponse(
            requestID: requestID,
            service: "OpenAIMemoryExtractor.callExtractor",
            endpoint: url.absoluteString,
            method: "POST",
            model: Constants.model,
            statusCode: http.statusCode,
            latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            responseData: data
        )

        let envelope = try JSONDecoder().decode(OpenAIEnvelope.self, from: data)
        return envelope.choices.first?.message.content ?? ""
    }

    private func parseDrafts(from raw: String) -> [ExtractedMemoryDraft] {
        let jsonText = extractJSONObject(from: raw)
        guard let data = jsonText.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ExtractionJSON.self, from: data)
        else { return [] }

        var drafts: [ExtractedMemoryDraft] = []
        for item in decoded.memories.prefix(2) {
            guard let type = MemoryType(rawValue: item.type.lowercased()) else { continue }
            guard type == .fact || type == .note || type == .checkin else { continue }

            let sentence = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { continue }

            let confidence = MemoryConfidence(rawValue: (item.confidence ?? "med").lowercased()) ?? .medium
            let ttlDefault: Int
            switch type {
            case .fact, .preference:
                ttlDefault = 365
            case .note:
                ttlDefault = 90
            case .checkin:
                ttlDefault = 7
            }
            let ttlDays = max(1, item.ttlDays ?? ttlDefault)

            let tags = (item.tags ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }

            drafts.append(ExtractedMemoryDraft(type: type, content: sentence, confidence: confidence, ttlDays: ttlDays, tags: Array(Set(tags)).sorted()))
        }

        return drafts
    }

    private func extractJSONObject(from text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return text
        }
        return String(text[start...end])
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "MemoryExtractor", code: 3, userInfo: [NSLocalizedDescriptionKey: "timeout"])
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Check-in Scheduling

protocol TaskScheduling {
    @discardableResult
    func schedule(runAt: Date, label: String, skillId: String, payload: [String: String]) -> UUID?
    func listPending() -> [ScheduledTask]
    @discardableResult
    func cancel(id: String) -> Bool
}

extension TaskScheduler: TaskScheduling {}

final class MemoryCheckInScheduler {
    static let shared = MemoryCheckInScheduler()

    private let scheduler: TaskScheduling
    private let store: MemoryStore
    private let defaults: UserDefaults

    private let scheduleKey = "memory_checkin_last_schedule_day"

    init(scheduler: TaskScheduling = TaskScheduler.shared,
         store: MemoryStore = .shared,
         defaults: UserDefaults = .standard) {
        self.scheduler = scheduler
        self.store = store
        self.defaults = defaults
    }

    @discardableResult
    func scheduleIfNeeded(for memory: MemoryRow, now: Date = Date()) -> Bool {
        guard memory.type == .checkin, !memory.isResolved else { return false }
        guard !store.isExpired(memory, relativeTo: now) else { return false }

        let day = dayStamp(now)
        if defaults.string(forKey: scheduleKey) == day {
            return false
        }

        if hasPendingCheckIn(for: memory.id) {
            return false
        }

        let runAt = nextCheckInDate(from: now)
        let payload = [
            "type": "memory_checkin",
            "memory_id": memory.id.uuidString,
            "message": "Hey — feeling any better today?"
        ]

        guard scheduler.schedule(runAt: runAt, label: "memory_checkin", skillId: "", payload: payload) != nil else {
            return false
        }

        defaults.set(day, forKey: scheduleKey)
        return true
    }

    @discardableResult
    func scheduleFollowUpIfNeeded(for memoryID: UUID, now: Date = Date()) -> Bool {
        guard let memory = store.memory(id: memoryID) else { return false }
        return scheduleIfNeeded(for: memory, now: now)
    }

    func cancelPendingCheckins(for memoryIDs: [UUID]) {
        guard !memoryIDs.isEmpty else { return }
        let target = Set(memoryIDs.map(\.uuidString))
        let pending = scheduler.listPending().filter {
            $0.payload["type"] == "memory_checkin" && target.contains($0.payload["memory_id"] ?? "")
        }
        for task in pending {
            _ = scheduler.cancel(id: task.id.uuidString)
        }
    }

    private func hasPendingCheckIn(for memoryID: UUID) -> Bool {
        scheduler.listPending().contains {
            $0.payload["type"] == "memory_checkin" && $0.payload["memory_id"] == memoryID.uuidString
        }
    }

    private func dayStamp(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? 0
        let month = comps.month ?? 0
        let day = comps.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func nextCheckInDate(from now: Date) -> Date {
        let plus18Hours = now.addingTimeInterval(18 * 3600)
        let calendar = Calendar.current
        let nextMorning = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 9, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? plus18Hours
        return min(plus18Hours, nextMorning)
    }
}

// MARK: - Auto Save Service

struct MemoryAutoSaveReport {
    let saved: [MemoryRow]
    let resolvedCheckinIDs: [UUID]
}

@MainActor
final class MemoryAutoSaveService {
    static let shared = MemoryAutoSaveService()

    private let extractor: MemoryExtracting
    private let store: MemoryStore
    private let checkInScheduler: MemoryCheckInScheduler

    init(extractor: MemoryExtracting = OpenAIMemoryExtractor(),
         store: MemoryStore = .shared,
         checkInScheduler: MemoryCheckInScheduler = .shared) {
        self.extractor = extractor
        self.store = store
        self.checkInScheduler = checkInScheduler
    }

    func processTurn(userMessage: String, assistantMessage: String?) async -> MemoryAutoSaveReport {
        guard store.isAvailable else {
            return MemoryAutoSaveReport(saved: [], resolvedCheckinIDs: [])
        }

        let resolved = store.resolveCheckinsIfUserImproved(userMessage)
        if !resolved.isEmpty {
            checkInScheduler.cancelPendingCheckins(for: resolved)
        }

        let drafts = await extractor.extractMemories(userMessage: userMessage, assistantMessage: assistantMessage)
        guard !drafts.isEmpty else {
            return MemoryAutoSaveReport(saved: [], resolvedCheckinIDs: resolved)
        }

        var saved: [MemoryRow] = []

        for draft in drafts.prefix(2) {
            let result = store.upsertMemory(
                type: draft.type,
                content: draft.content,
                confidence: draft.confidence,
                ttlDays: draft.ttlDays,
                source: "auto_extract",
                sourceSnippet: userMessage,
                tags: draft.tags,
                isResolved: false,
                now: Date()
            )

            switch result {
            case .inserted(let row), .updated(let row):
                saved.append(row)
                if row.type == .checkin && !row.isResolved {
                    _ = checkInScheduler.scheduleIfNeeded(for: row)
                }
            case .skippedLimit, .skippedDuplicate:
                continue
            }
        }

        return MemoryAutoSaveReport(saved: saved, resolvedCheckinIDs: resolved)
    }
}

// MARK: - Self Learning Loop

enum SelfLearningCategory: String, Codable, CaseIterable {
    case continuity
    case brevity
    case clarity
    case confidence
    case followup
}

struct SelfLearningLesson: Identifiable, Codable, Equatable {
    let id: UUID
    let category: SelfLearningCategory
    let text: String
    let normalizedText: String
    let createdAt: Date
    var lastUpdatedAt: Date
    var lastAppliedAt: Date?
    var confidence: Double
    var observedCount: Int
    var appliedCount: Int
}

/// Persistent store of compact self-improvement lessons.
final class SelfLearningStore {
    static let shared = SelfLearningStore()

    private let queue = DispatchQueue(label: "SelfLearningStore.queue")
    private var lessons: [SelfLearningLesson] = []
    private let fileURL: URL

    private let maxLessons = 120
    private let duplicateSimilarity = 0.88

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let samosDir = appSupport.appendingPathComponent("SamOS", isDirectory: true)
            if !FileManager.default.fileExists(atPath: samosDir.path) {
                try? FileManager.default.createDirectory(at: samosDir, withIntermediateDirectories: true)
            }
            self.fileURL = samosDir.appendingPathComponent("self_learning.json", isDirectory: false)
        }
        self.lessons = loadLessons()
    }

    func recordLesson(_ text: String,
                      category: SelfLearningCategory,
                      confidence: Double = 0.7,
                      now: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        queue.sync {
            let normalized = canonicalize(trimmed)
            guard !normalized.isEmpty else { return }

            if let idx = existingLessonIndex(for: normalized, category: category) {
                var lesson = lessons[idx]
                let safeConfidence = min(0.99, max(0.1, confidence))
                let weighted = (lesson.confidence * Double(lesson.observedCount)) + safeConfidence
                lesson.observedCount += 1
                lesson.confidence = min(0.99, weighted / Double(lesson.observedCount))
                lesson.lastUpdatedAt = now
                lessons[idx] = lesson
            } else {
                let lesson = SelfLearningLesson(
                    id: UUID(),
                    category: category,
                    text: trimmed,
                    normalizedText: normalized,
                    createdAt: now,
                    lastUpdatedAt: now,
                    lastAppliedAt: nil,
                    confidence: min(0.99, max(0.1, confidence)),
                    observedCount: 1,
                    appliedCount: 0
                )
                lessons.append(lesson)
            }

            pruneIfNeeded(now: now)
            saveLessons(lessons)
        }
    }

    /// Top-k lesson lines for prompt injection.
    func relevantLessonTexts(query: String, maxItems: Int = 3, maxChars: Int = 260) -> [String] {
        queue.sync {
            guard !lessons.isEmpty else { return [] }
            let now = Date()

            let ranked = LocalKnowledgeRetriever.rank(
                query: query,
                items: lessons,
                text: { "[\($0.category.rawValue)] \($0.text)" },
                recencyDate: { $0.lastUpdatedAt },
                extraBoost: { lesson in
                    let confidenceBoost = lesson.confidence * 0.22
                    let observedBoost = min(0.16, log2(Double(max(1, lesson.observedCount)) + 1.0) * 0.06)
                    let appliedBoost = min(0.10, log2(Double(max(1, lesson.appliedCount)) + 1.0) * 0.04)
                    return confidenceBoost + observedBoost + appliedBoost
                },
                limit: max(1, maxItems * 3),
                minScore: 0.08
            )

            var selected: [SelfLearningLesson] = []
            var totalChars = 0

            for entry in ranked {
                let lesson = entry.item
                guard selected.count < max(1, maxItems) else { break }
                let line = "[\(lesson.category.rawValue)] \(lesson.text)"
                if selected.isEmpty {
                    guard line.count <= maxChars else { continue }
                } else if totalChars + line.count > maxChars {
                    break
                }
                selected.append(lesson)
                totalChars += line.count
            }

            guard !selected.isEmpty else { return [] }
            markApplied(ids: selected.map(\.id), now: now)
            return selected.map { "[\($0.category.rawValue)] \($0.text)" }
        }
    }

    func allLessons() -> [SelfLearningLesson] {
        queue.sync { lessons }
    }

    private func markApplied(ids: [UUID], now: Date) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        var changed = false
        for idx in lessons.indices {
            if idSet.contains(lessons[idx].id) {
                lessons[idx].appliedCount += 1
                lessons[idx].lastAppliedAt = now
                changed = true
            }
        }
        if changed {
            saveLessons(lessons)
        }
    }

    private func existingLessonIndex(for normalized: String, category: SelfLearningCategory) -> Int? {
        for idx in lessons.indices where lessons[idx].category == category {
            if lessons[idx].normalizedText == normalized { return idx }
            let similarity = normalizedSimilarity(normalized, lessons[idx].normalizedText)
            if similarity >= duplicateSimilarity { return idx }
        }
        return nil
    }

    private func pruneIfNeeded(now: Date) {
        guard lessons.count > maxLessons else { return }

        lessons.sort { lhs, rhs in
            let lhsScore = utility(lhs, now: now)
            let rhsScore = utility(rhs, now: now)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.lastUpdatedAt > rhs.lastUpdatedAt
        }
        lessons = Array(lessons.prefix(maxLessons))
    }

    private func utility(_ lesson: SelfLearningLesson, now: Date) -> Double {
        let recencyDays = max(0.0, now.timeIntervalSince(lesson.lastUpdatedAt) / 86_400.0)
        let recencyBoost = max(0.0, 1.0 - min(1.0, recencyDays / 30.0))
        let observed = min(3.0, log2(Double(max(1, lesson.observedCount)) + 1.0))
        let applied = min(2.0, log2(Double(max(1, lesson.appliedCount)) + 1.0))
        return (lesson.confidence * 3.0) + recencyBoost + observed + applied
    }

    private func tokenize(_ text: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "and", "or", "to", "for",
            "of", "in", "on", "at", "it", "this", "that", "as", "be", "by", "with",
            "you", "your", "i", "we", "they", "he", "she", "do", "does", "did"
        ]
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 1 && !stopwords.contains($0) }
    }

    private func canonicalize(_ text: String) -> String {
        tokenize(text).joined(separator: " ")
    }

    private func normalizedSimilarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let aSet = Set(a.split(separator: " ").map(String.init))
        let bSet = Set(b.split(separator: " ").map(String.init))
        guard !aSet.isEmpty, !bSet.isEmpty else { return 0 }
        let intersection = Double(aSet.intersection(bSet).count)
        let union = Double(aSet.union(bSet).count)
        if union == 0 { return 0 }
        return intersection / union
    }

    private func loadLessons() -> [SelfLearningLesson] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let decoded = try? JSONDecoder().decode([SelfLearningLesson].self, from: data) else { return [] }
        return decoded
    }

    private func saveLessons(_ lessons: [SelfLearningLesson]) {
        guard let data = try? JSONEncoder().encode(lessons) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

/// Lightweight reflection loop for learning better response behavior.
@MainActor
final class SelfLearningService {
    static let shared = SelfLearningService()

    private let store: SelfLearningStore
    private struct TurnPatternObservation {
        let userShort: Bool
        let userCorrection: Bool
        let userAskedQuestion: Bool
        let assistantAskedQuestion: Bool
        let assistantLongWithoutCanvas: Bool
    }
    private var recentTurnWindow: [TurnPatternObservation] = []
    private let maxTurnWindow = 12

    init(store: SelfLearningStore = .shared) {
        self.store = store
    }

    func observeIncomingUserReply(userMessage: String, previousAssistantMessage: String?) {
        let user = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { return }

        if isShortReply(user), isSingleQuestion(previousAssistantMessage) {
            store.recordLesson(
                "When a short user reply follows your question, treat it as an answer to that question and continue with context.",
                category: .continuity,
                confidence: 0.92
            )
        }

        if isCorrectionSignal(user) {
            store.recordLesson(
                "When the user says the response missed the point, apologize briefly and clarify the exact target before continuing.",
                category: .clarity,
                confidence: 0.84
            )
        }
    }

    func processTurn(userMessage: String,
                     assistantMessage: String?,
                     hadCanvasOutput: Bool,
                     previousAssistantMessage: String?) {
        let user = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = assistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !user.isEmpty else { return }

        if assistant.isEmpty {
            store.recordLesson(
                "Always provide a direct user-visible answer; avoid silent completion without a concise response.",
                category: .clarity,
                confidence: 0.75
            )
            return
        }

        if assistant.count > 220 && !hadCanvasOutput {
            store.recordLesson(
                "For dense answers, keep speech short and put detailed structure in the canvas.",
                category: .brevity,
                confidence: 0.90
            )
        }

        if questionMarkCount(in: assistant) > 1 {
            store.recordLesson(
                "Ask at most one follow-up question per turn to keep the interaction focused.",
                category: .followup,
                confidence: 0.82
            )
        }

        if containsStrongUncertainty(assistant), !assistant.lowercased().contains("double-check") {
            store.recordLesson(
                "When uncertain, hedge naturally and offer to double-check instead of sounding absolute.",
                category: .confidence,
                confidence: 0.78
            )
        }

        if isSingleQuestion(previousAssistantMessage), isShortReply(user) {
            store.recordLesson(
                "Short replies after your question usually continue the same thread; prioritize contextual continuation over topic reset.",
                category: .continuity,
                confidence: 0.88
            )
        }

        recordTurnPattern(
            userMessage: user,
            assistantMessage: assistant,
            hadCanvasOutput: hadCanvasOutput,
            previousAssistantMessage: previousAssistantMessage
        )
        detectMultiTurnPatterns()
    }

    private func isShortReply(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count <= 5
    }

    private func isSingleQuestion(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("?") else { return false }
        return questionMarkCount(in: trimmed) == 1
    }

    private func questionMarkCount(in text: String) -> Int {
        text.filter { $0 == "?" }.count
    }

    private func containsStrongUncertainty(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "i think", "maybe", "not sure", "likely", "might",
            "could be", "approximately", "can't confirm", "cannot confirm", "unknown"
        ]
        return markers.contains { lower.contains($0) }
    }

    private func recordTurnPattern(userMessage: String,
                                   assistantMessage: String,
                                   hadCanvasOutput: Bool,
                                   previousAssistantMessage: String?) {
        let observation = TurnPatternObservation(
            userShort: isShortReply(userMessage),
            userCorrection: isCorrectionSignal(userMessage),
            userAskedQuestion: questionMarkCount(in: userMessage) > 0,
            assistantAskedQuestion: isSingleQuestion(assistantMessage),
            assistantLongWithoutCanvas: assistantMessage.count > 220 && !hadCanvasOutput
        )
        recentTurnWindow.append(observation)
        if recentTurnWindow.count > maxTurnWindow {
            recentTurnWindow.removeFirst(recentTurnWindow.count - maxTurnWindow)
        }

        if isSingleQuestion(previousAssistantMessage), isShortReply(userMessage) {
            store.recordLesson(
                "Brief user replies right after your question usually answer that question; continue the same context unless explicitly redirected.",
                category: .continuity,
                confidence: 0.90
            )
        }
    }

    private func detectMultiTurnPatterns() {
        let recent = Array(recentTurnWindow.suffix(6))
        guard !recent.isEmpty else { return }

        let correctionCount = recent.filter(\.userCorrection).count
        if correctionCount >= 2 {
            store.recordLesson(
                "If corrections repeat across nearby turns, switch to explicit clarification mode before continuing.",
                category: .clarity,
                confidence: 0.88
            )
        }

        let continuitySignals = recent.filter { $0.assistantAskedQuestion && $0.userShort }.count
        if continuitySignals >= 2 {
            store.recordLesson(
                "Across multi-turn exchanges, short replies after your question usually continue the active context.",
                category: .continuity,
                confidence: 0.92
            )
        }

        let longDumpCount = recent.filter(\.assistantLongWithoutCanvas).count
        if longDumpCount >= 2 {
            store.recordLesson(
                "When long responses repeat in nearby turns, keep spoken replies brief and move detail into canvas output.",
                category: .brevity,
                confidence: 0.91
            )
        }

        let followupNeedCount = recent.filter { !$0.assistantAskedQuestion && $0.userAskedQuestion }.count
        if followupNeedCount >= 3 {
            store.recordLesson(
                "When users repeatedly ask follow-up questions after answers, include one concise optional follow-up question.",
                category: .followup,
                confidence: 0.82
            )
        }
    }

    private func isCorrectionSignal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "that's not what i asked",
            "not what i asked",
            "that's wrong",
            "you got that wrong",
            "no, i meant",
            "no i meant",
            "try again",
            "you misunderstood"
        ]
        return markers.contains { lower.contains($0) }
    }
}

// MARK: - Website Learning

struct WebsiteLearningRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let canonicalURL: String
    let url: String
    let host: String
    var title: String
    var summary: String
    var highlights: [String]
    var chunks: [String]
    let createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case canonicalURL
        case url
        case host
        case title
        case summary
        case highlights
        case chunks
        case createdAt
        case updatedAt
    }

    init(id: UUID,
         canonicalURL: String,
         url: String,
         host: String,
         title: String,
         summary: String,
         highlights: [String],
         chunks: [String],
         createdAt: Date,
         updatedAt: Date) {
        self.id = id
        self.canonicalURL = canonicalURL
        self.url = url
        self.host = host
        self.title = title
        self.summary = summary
        self.highlights = highlights
        self.chunks = chunks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        canonicalURL = try container.decode(String.self, forKey: .canonicalURL)
        url = try container.decode(String.self, forKey: .url)
        host = try container.decode(String.self, forKey: .host)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        highlights = try container.decodeIfPresent([String].self, forKey: .highlights) ?? []
        chunks = try container.decodeIfPresent([String].self, forKey: .chunks) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(canonicalURL, forKey: .canonicalURL)
        try container.encode(url, forKey: .url)
        try container.encode(host, forKey: .host)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(chunks, forKey: .chunks)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Persistent store for website-learning summaries that can be reused in future turns.
final class WebsiteLearningStore {
    static let shared = WebsiteLearningStore()

    private let queue = DispatchQueue(label: "WebsiteLearningStore.queue")
    private var records: [WebsiteLearningRecord] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let samosDir = appSupport.appendingPathComponent("SamOS", isDirectory: true)
            if !FileManager.default.fileExists(atPath: samosDir.path) {
                try? FileManager.default.createDirectory(at: samosDir, withIntermediateDirectories: true)
            }
            self.fileURL = samosDir.appendingPathComponent("website_learning.json", isDirectory: false)
        }
        self.records = loadRecords()
        sortRecordsNewestFirst()
    }

    @discardableResult
    func saveLearnedPage(url: String,
                         title: String,
                         summary: String,
                         highlights: [String],
                         chunks: [String],
                         now: Date = Date()) -> WebsiteLearningRecord {
        let cleanedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = canonicalizeURL(cleanedURL) ?? cleanedURL
        let host = URL(string: canonical)?.host?.lowercased() ?? URL(string: cleanedURL)?.host?.lowercased() ?? "website"
        let safeTitle = sanitizeSingleLine(title, fallback: host)
        let safeSummary = sanitizeSingleLine(summary, fallback: "Learned content from \(host).")
        let safeHighlights = highlights
            .map { sanitizeSingleLine($0, fallback: "") }
            .filter { !$0.isEmpty }
        let safeChunks = chunks
            .map { sanitizeChunk($0) }
            .filter { !$0.isEmpty }

        return queue.sync {
            if let idx = records.firstIndex(where: { $0.canonicalURL == canonical }) {
                var updated = records[idx]
                updated.title = safeTitle
                updated.summary = safeSummary
                updated.highlights = safeHighlights
                updated.chunks = safeChunks
                updated.updatedAt = now
                records[idx] = updated
                sortRecordsNewestFirst()
                saveRecords(records)
                return updated
            }

            let record = WebsiteLearningRecord(
                id: UUID(),
                canonicalURL: canonical,
                url: cleanedURL,
                host: host,
                title: safeTitle,
                summary: safeSummary,
                highlights: safeHighlights,
                chunks: safeChunks,
                createdAt: now,
                updatedAt: now
            )
            records.append(record)
            sortRecordsNewestFirst()
            saveRecords(records)
            return record
        }
    }

    @discardableResult
    func saveLearnedPage(url: String,
                         title: String,
                         summary: String,
                         highlights: [String],
                         now: Date = Date()) -> WebsiteLearningRecord {
        saveLearnedPage(
            url: url,
            title: title,
            summary: summary,
            highlights: highlights,
            chunks: [],
            now: now
        )
    }

    func recentRecords(limit: Int = 10) -> [WebsiteLearningRecord] {
        queue.sync {
            Array(records.prefix(max(0, limit)))
        }
    }

    func allRecords() -> [WebsiteLearningRecord] {
        queue.sync { records }
    }

    func count() -> Int {
        queue.sync { records.count }
    }

    func storageBytes() -> Int {
        queue.sync {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let value = attrs[.size] as? NSNumber else {
                return 0
            }
            return value.intValue
        }
    }

    func record(forURL url: String) -> WebsiteLearningRecord? {
        let canonical = canonicalizeURL(url.trimmingCharacters(in: .whitespacesAndNewlines)) ?? url
        return queue.sync {
            records.first { $0.canonicalURL == canonical }
        }
    }

    /// Chunk-first RAG lines for prompt injection with size limits.
    func relevantContext(query: String, maxItems: Int = 3, maxChars: Int = 320) -> [String] {
        queue.sync {
            guard !records.isEmpty else { return [] }

            struct WebsiteContextItem {
                let text: String
                let updatedAt: Date
                let isSummary: Bool
            }

            var candidates: [WebsiteContextItem] = []
            candidates.reserveCapacity(records.count * 16)
            for record in records {
                let summaryLine = "[web \(record.host)] \(record.title): \(record.summary)"
                if !isLowValueWebsiteText(summaryLine) {
                    candidates.append(
                        WebsiteContextItem(
                            text: summaryLine,
                            updatedAt: record.updatedAt,
                            isSummary: true
                        )
                    )
                }
                for chunk in record.chunks {
                    let chunkLine = "[web \(record.host)] \(record.title): \(chunk)"
                    if isLowValueWebsiteText(chunkLine) { continue }
                    candidates.append(
                        WebsiteContextItem(
                            text: chunkLine,
                            updatedAt: record.updatedAt,
                            isSummary: false
                        )
                    )
                }
            }

            let ranked = LocalKnowledgeRetriever.rank(
                query: query,
                items: candidates,
                text: { item in
                    item.text
                },
                recencyDate: { $0.updatedAt },
                extraBoost: { item in
                    let lengthBoost = min(0.08, Double(item.text.count) / 1000.0)
                    let summaryBoost = item.isSummary ? 0.05 : 0.0
                    return lengthBoost + summaryBoost
                },
                limit: max(8, maxItems * 10),
                minScore: 0.05
            )

            var selected: [String] = []
            var usedChars = 0
            let cappedItems = max(1, maxItems)
            var seen: Set<String> = []

            for entry in ranked {
                let item = entry.item
                guard selected.count < cappedItems else { break }
                let rawLine = item.text
                let line = rawLine.count > 420 ? String(rawLine.prefix(417)) + "..." : rawLine
                let key = line.lowercased()
                if !seen.insert(key).inserted { continue }
                if selected.isEmpty {
                    guard line.count <= maxChars else { continue }
                } else if usedChars + line.count > maxChars {
                    break
                }
                selected.append(line)
                usedChars += line.count
            }

            if selected.isEmpty {
                for record in records.prefix(cappedItems) {
                    let fallback = "[web \(record.host)] \(record.title): \(record.summary)"
                    if selected.isEmpty {
                        guard fallback.count <= maxChars else { continue }
                    } else if usedChars + fallback.count > maxChars {
                        break
                    }
                    selected.append(fallback)
                    usedChars += fallback.count
                }
            }

            return selected
        }
    }

    private func isLowValueWebsiteText(_ text: String) -> Bool {
        let lower = text.lowercased()
        let signals = [
            "loading your experience", "this won't take long", "we're getting things ready",
            "we are getting things ready", "checking your browser", "enable javascript",
            "please wait", "just a moment"
        ]
        return signals.contains { lower.contains($0) }
    }

    private func sortRecordsNewestFirst() {
        records.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func sanitizeSingleLine(_ text: String, fallback: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.isEmpty { return fallback }
        return String(compact.prefix(260))
    }

    private func sanitizeChunk(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "" }
        return String(compact.prefix(420))
    }

    private func canonicalizeURL(_ raw: String) -> String? {
        guard var comps = URLComponents(string: raw), let scheme = comps.scheme?.lowercased(), !scheme.isEmpty else {
            return nil
        }
        comps.scheme = scheme
        comps.host = comps.host?.lowercased()
        comps.fragment = nil
        comps.query = nil
        var path = comps.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        comps.path = path
        return comps.url?.absoluteString
    }

    private func tokenize(_ text: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "and", "or", "to", "for",
            "of", "in", "on", "at", "it", "this", "that", "as", "be", "by", "with",
            "you", "your", "i", "we", "they", "he", "she", "do", "does", "did"
        ]
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 1 && !stopwords.contains($0) }
    }

    private func loadRecords() -> [WebsiteLearningRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let decoded = try? JSONDecoder().decode([WebsiteLearningRecord].self, from: data) else { return [] }
        return decoded
    }

    private func saveRecords(_ records: [WebsiteLearningRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

// MARK: - Autonomous Learning

struct AutonomousLearningReport: Identifiable, Codable, Equatable {
    let id: UUID
    let topic: String
    let requestedMinutes: Int
    let startedAt: Date
    let finishedAt: Date
    let sources: [String]
    let lessons: [String]
    let openQuestions: [String]
    let completionReason: String?

    init(id: UUID,
         topic: String,
         requestedMinutes: Int,
         startedAt: Date,
         finishedAt: Date,
         sources: [String],
         lessons: [String],
         openQuestions: [String],
         completionReason: String? = nil) {
        self.id = id
        self.topic = topic
        self.requestedMinutes = requestedMinutes
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.sources = sources
        self.lessons = lessons
        self.openQuestions = openQuestions
        self.completionReason = completionReason
    }
}

final class AutonomousLearningReportStore {
    static let shared = AutonomousLearningReportStore()

    private let queue = DispatchQueue(label: "AutonomousLearningReportStore.queue")
    private var reports: [AutonomousLearningReport] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let samosDir = appSupport.appendingPathComponent("SamOS", isDirectory: true)
            if !FileManager.default.fileExists(atPath: samosDir.path) {
                try? FileManager.default.createDirectory(at: samosDir, withIntermediateDirectories: true)
            }
            self.fileURL = samosDir.appendingPathComponent("autonomous_learning_reports.json", isDirectory: false)
        }
        self.reports = loadReports()
        sortNewestFirst()
    }

    func add(_ report: AutonomousLearningReport) {
        queue.sync {
            reports.removeAll { $0.id == report.id }
            reports.append(report)
            sortNewestFirst()
            saveReports(reports)
        }
    }

    func recent(limit: Int = 20) -> [AutonomousLearningReport] {
        queue.sync {
            Array(reports.prefix(max(0, limit)))
        }
    }

    func count() -> Int {
        queue.sync { reports.count }
    }

    private func sortNewestFirst() {
        reports.sort { lhs, rhs in
            if lhs.finishedAt != rhs.finishedAt { return lhs.finishedAt > rhs.finishedAt }
            return lhs.startedAt > rhs.startedAt
        }
    }

    private func loadReports() -> [AutonomousLearningReport] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let decoded = try? JSONDecoder().decode([AutonomousLearningReport].self, from: data) else { return [] }
        return decoded
    }

    private func saveReports(_ reports: [AutonomousLearningReport]) {
        guard let data = try? JSONEncoder().encode(reports) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

struct AutonomousLearningStartResult {
    let started: Bool
    let sessionID: UUID?
    let expectedFinishAt: Date?
    let message: String
}

struct AutonomousLearningStopResult {
    let stopped: Bool
    let sessionID: UUID?
    let message: String
}

protocol AutonomousLearningControlling {
    func startSession(minutes: Int, topic: String?) -> AutonomousLearningStartResult
    func stopActiveSession() -> AutonomousLearningStopResult
    func activeSessionSnapshot() -> AutonomousLearningService.ActiveSession?
    func recentReports(limit: Int) -> [AutonomousLearningReport]
}

/// Runs timed autonomous internet-learning sessions and reports outcomes on completion.
final class AutonomousLearningService: AutonomousLearningControlling {
    static let shared = AutonomousLearningService()

    private struct LearningBudget {
        let maxSourcesPerSession: Int
        let maxLessonsPerSession: Int
        let maxStorageGrowthBytes: Int
        let maxHighlightsPerSource: Int
    }

    private struct EarlyExitPolicy {
        let minimumElapsedFraction: Double
        let minimumSources: Int
        let minimumLessons: Int
        let stagnantRoundsThreshold: Int
    }

    struct ActiveSession: Equatable {
        let id: UUID
        let topic: String
        let requestedMinutes: Int
        let startedAt: Date
        let expectedFinishAt: Date
    }

    var onSessionCompleted: ((AutonomousLearningReport) -> Void)?

    private let stateQueue = DispatchQueue(label: "AutonomousLearningService.state")
    private var activeSession: ActiveSession?
    private var activeSessionTask: Task<Void, Never>?
    private var activeSessionTaskID: UUID?

    private let reportStore: AutonomousLearningReportStore
    private let websiteStore: WebsiteLearningStore
    private let memoryStore: MemoryStore
    private let learningBudget = LearningBudget(
        maxSourcesPerSession: 120,
        maxLessonsPerSession: 900,
        maxStorageGrowthBytes: 4_000_000,
        maxHighlightsPerSource: 12
    )
    private let earlyExitPolicy = EarlyExitPolicy(
        minimumElapsedFraction: 0.35,
        minimumSources: 10,
        minimumLessons: 36,
        stagnantRoundsThreshold: 4
    )

    init(reportStore: AutonomousLearningReportStore = .shared,
         websiteStore: WebsiteLearningStore = .shared,
         memoryStore: MemoryStore = .shared) {
        self.reportStore = reportStore
        self.websiteStore = websiteStore
        self.memoryStore = memoryStore
    }

    func startSession(minutes: Int, topic: String?) -> AutonomousLearningStartResult {
        let safeMinutes = max(1, minutes)
        let requestedTopic = sanitizeTopic(topic) ?? defaultTopic()
        let now = Date()
        let expectedFinish = now.addingTimeInterval(TimeInterval(safeMinutes * 60))
        let sessionID = UUID()
        let newSession = ActiveSession(
            id: sessionID,
            topic: requestedTopic,
            requestedMinutes: safeMinutes,
            startedAt: now,
            expectedFinishAt: expectedFinish
        )

        let canStart: Bool = stateQueue.sync {
            guard activeSession == nil, activeSessionTask == nil else { return false }
            activeSession = newSession
            return true
        }

        guard canStart else {
            let current = activeSessionSnapshot()
            let msg: String
            let taskStillRunning = stateQueue.sync { activeSessionTask != nil }
            if current != nil {
                msg = "I am already learning right now and will finish soon."
            } else if taskStillRunning {
                msg = "I am stopping the previous learning session. Try again in a few seconds."
            } else {
                msg = "I am already running a learning session."
            }
            return AutonomousLearningStartResult(
                started: false,
                sessionID: current?.id,
                expectedFinishAt: current?.expectedFinishAt,
                message: msg
            )
        }

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let report = await self.runSession(session: newSession)
            self.reportStore.add(report)

            self.stateQueue.sync {
                if self.activeSessionTaskID == sessionID {
                    self.activeSessionTask = nil
                    self.activeSessionTaskID = nil
                }
                if self.activeSession?.id == sessionID {
                    self.activeSession = nil
                }
            }

            await MainActor.run {
                self.onSessionCompleted?(report)
            }
        }
        stateQueue.sync {
            activeSessionTask = task
            activeSessionTaskID = sessionID
        }

        return AutonomousLearningStartResult(
            started: true,
            sessionID: sessionID,
            expectedFinishAt: expectedFinish,
            message: "Starting a \(safeMinutes)-minute autonomous learning session on \(requestedTopic)."
        )
    }

    func activeSessionSnapshot() -> ActiveSession? {
        stateQueue.sync { activeSession }
    }

    func stopActiveSession() -> AutonomousLearningStopResult {
        var session: ActiveSession?
        var taskToCancel: Task<Void, Never>?

        stateQueue.sync {
            session = activeSession
            if let id = activeSession?.id, activeSessionTaskID == id {
                taskToCancel = activeSessionTask
            }
            activeSession = nil
        }

        guard let session else {
            return AutonomousLearningStopResult(
                stopped: false,
                sessionID: nil,
                message: "No autonomous learning session is currently running."
            )
        }

        taskToCancel?.cancel()
        return AutonomousLearningStopResult(
            stopped: true,
            sessionID: session.id,
            message: "Stopped autonomous learning session on \(session.topic)."
        )
    }

    func recentReports(limit: Int = 20) -> [AutonomousLearningReport] {
        reportStore.recent(limit: limit)
    }

    private func runSession(session: ActiveSession) async -> AutonomousLearningReport {
        let learner = LearnWebsiteTool(learningStore: websiteStore, memoryStore: memoryStore)
        let deadline = session.expectedFinishAt
        let topic = session.topic
        var visited: Set<String> = []
        var sources: [String] = []
        var lessons: [String] = []
        var lessonSet: Set<String> = []
        var completionReason = "time_elapsed"
        let sessionStartStorageBytes = websiteStore.storageBytes()
        var stagnantRounds = 0
        var queryPlan = await suggestedQueriesFromOpenAI(topic: topic, lessons: [])
        if queryPlan.isEmpty {
            queryPlan = [topic]
        }
        var round = 0

        while Date() < deadline {
            if Task.isCancelled {
                completionReason = "user_stopped"
                break
            }
            round += 1
            let lessonCountBeforeRound = lessonSet.count
            let fallbackQuery = nextQuery(topic: topic, round: round)
            let query: String
            if queryPlan.isEmpty {
                query = fallbackQuery
            } else {
                query = queryPlan[(round - 1) % queryPlan.count]
            }
            let candidates = candidateURLs(for: query)
            let fallbackCandidates = (query == fallbackQuery) ? [] : candidateURLs(for: fallbackQuery)
            let mergedCandidates = dedupeURLs(candidates + fallbackCandidates)

            var consumedThisRound = 0
            for candidate in mergedCandidates {
                if Task.isCancelled {
                    completionReason = "user_stopped"
                    break
                }
                if Date() >= deadline { break }
                if sources.count >= learningBudget.maxSourcesPerSession {
                    completionReason = "source_budget_reached"
                    break
                }
                if lessonSet.count >= learningBudget.maxLessonsPerSession {
                    completionReason = "lesson_budget_reached"
                    break
                }
                let storageGrowth = max(0, websiteStore.storageBytes() - sessionStartStorageBytes)
                if storageGrowth >= learningBudget.maxStorageGrowthBytes {
                    completionReason = "storage_budget_reached"
                    break
                }
                let raw = candidate.absoluteString
                guard !visited.contains(raw) else { continue }
                visited.insert(raw)

                _ = learner.execute(args: [
                    "url": raw,
                    "focus": topic,
                    "max_highlights": String(learningBudget.maxHighlightsPerSource)
                ])
                guard let record = websiteStore.record(forURL: raw) else { continue }

                consumedThisRound += 1
                sources.append(record.url)

                let summary = cleanLine(record.summary)
                if !summary.isEmpty, !lessonSet.contains(summary.lowercased()) {
                    lessonSet.insert(summary.lowercased())
                    lessons.append(summary)
                }

                for point in record.highlights {
                    let clean = cleanLine(point)
                    if clean.isEmpty { continue }
                    let key = clean.lowercased()
                    if lessonSet.contains(key) { continue }
                    lessonSet.insert(key)
                    lessons.append(clean)
                }
            }

            if completionReason != "time_elapsed" {
                break
            }

            let newLessonsThisRound = lessonSet.count - lessonCountBeforeRound
            if newLessonsThisRound <= 0 {
                stagnantRounds += 1
            } else {
                stagnantRounds = 0
            }

            let elapsedFraction = progressFraction(now: Date(), from: session.startedAt, to: deadline)
            if shouldEndSessionEarly(
                elapsedFraction: elapsedFraction,
                stagnantRounds: stagnantRounds,
                sourceCount: sources.count,
                lessonCount: lessonSet.count
            ) {
                completionReason = "learned_enough"
                break
            }

            if round % 4 == 0 {
                let lessonWindow = Array(lessons.suffix(12))
                let suggested = await suggestedQueriesFromOpenAI(topic: topic, lessons: lessonWindow)
                if !suggested.isEmpty {
                    queryPlan = dedupeQueries(queryPlan + suggested)
                }
            }

            let pauseNs: UInt64 = consumedThisRound > 0 ? 250_000_000 : 900_000_000
            try? await Task.sleep(nanoseconds: pauseNs)
        }

        if lessons.isEmpty {
            lessons.append("I need clearer source material to extract strong lessons.")
        }

        let openQuestions = generateOpenQuestions(topic: topic, lessons: lessons, completionReason: completionReason)
        let finished = Date()
        let uniqueSources = dedupeStrings(sources)
        let uniqueLessons = dedupeStrings(lessons)

        return AutonomousLearningReport(
            id: session.id,
            topic: topic,
            requestedMinutes: session.requestedMinutes,
            startedAt: session.startedAt,
            finishedAt: finished,
            sources: uniqueSources,
            lessons: uniqueLessons,
            openQuestions: openQuestions,
            completionReason: completionReason
        )
    }

    private func sanitizeTopic(_ topic: String?) -> String? {
        guard let topic else { return nil }
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }

    private func defaultTopic() -> String {
        let topics = [
            "productivity and focus habits",
            "clear communication techniques",
            "practical software engineering practices",
            "health and wellbeing routines",
            "critical thinking and decision making"
        ]
        let index = Int(Date().timeIntervalSince1970) % topics.count
        return topics[index]
    }

    private func nextQuery(topic: String, round: Int) -> String {
        let suffixes = [
            "best practices",
            "guide",
            "research summary",
            "examples",
            "common mistakes"
        ]
        let suffix = suffixes[(round - 1) % suffixes.count]
        return "\(topic) \(suffix)"
    }

    private func candidateURLs(for query: String) -> [URL] {
        var urls: [URL] = []
        urls.append(contentsOf: duckDuckGoInstantURLs(query: query))
        urls.append(contentsOf: wikipediaSearchURLs(query: query))
        urls.append(contentsOf: hackerNewsStoryURLs(query: query))
        return dedupeURLs(urls)
    }

    private func dedupeURLs(_ urls: [URL]) -> [URL] {
        var deduped: [URL] = []
        var seen: Set<String> = []
        for url in urls {
            let raw = url.absoluteString
            if seen.contains(raw) { continue }
            seen.insert(raw)
            deduped.append(url)
        }
        return deduped
    }

    private func duckDuckGoInstantURLs(query: String) -> [URL] {
        guard var comps = URLComponents(string: "https://api.duckduckgo.com/") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]
        guard let url = comps.url,
              let json = requestJSON(url: url) as? [String: Any] else { return [] }

        var urls: [URL] = []
        if let abstractURL = json["AbstractURL"] as? String,
           let parsed = URL(string: abstractURL),
           isValidHTTPURL(parsed) {
            urls.append(parsed)
        }

        if let related = json["RelatedTopics"] as? [Any] {
            urls.append(contentsOf: extractDuckDuckGoRelatedURLs(related))
        }

        return urls
    }

    private func extractDuckDuckGoRelatedURLs(_ list: [Any]) -> [URL] {
        var urls: [URL] = []
        for item in list {
            guard let dict = item as? [String: Any] else { continue }
            if let firstURL = dict["FirstURL"] as? String,
               let parsed = URL(string: firstURL),
               isValidHTTPURL(parsed) {
                urls.append(parsed)
            }
            if let nested = dict["Topics"] as? [Any] {
                urls.append(contentsOf: extractDuckDuckGoRelatedURLs(nested))
            }
        }
        return urls
    }

    private func wikipediaSearchURLs(query: String) -> [URL] {
        guard var comps = URLComponents(string: "https://en.wikipedia.org/w/api.php") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "utf8", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "srlimit", value: "6")
        ]
        guard let url = comps.url,
              let json = requestJSON(url: url) as? [String: Any],
              let queryObj = json["query"] as? [String: Any],
              let results = queryObj["search"] as? [[String: Any]] else { return [] }

        return results.compactMap { result in
            guard let title = result["title"] as? String else { return nil }
            let normalized = title.replacingOccurrences(of: " ", with: "_")
            return URL(string: "https://en.wikipedia.org/wiki/\(normalized)")
        }
    }

    private func hackerNewsStoryURLs(query: String) -> [URL] {
        guard var comps = URLComponents(string: "https://hn.algolia.com/api/v1/search") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "tags", value: "story"),
            URLQueryItem(name: "hitsPerPage", value: "8")
        ]
        guard let url = comps.url,
              let json = requestJSON(url: url) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]] else { return [] }

        return hits.compactMap { hit in
            guard let rawURL = hit["url"] as? String,
                  let parsed = URL(string: rawURL),
                  isValidHTTPURL(parsed) else { return nil }
            return parsed
        }
    }

    private func requestJSON(url: URL) -> Any? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("SamOS/1.0 (autonomous-learning)", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data = data else { return }
            result = data
        }.resume()

        _ = semaphore.wait(timeout: .now() + 10)
        guard let data = result else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func isValidHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return false }
        let lower = url.absoluteString.lowercased()
        if lower.contains("duckduckgo.com/y.js") || lower.contains("duckduckgo.com/l/?kh=") {
            return false
        }
        return true
    }

    private func cleanLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generateOpenQuestions(topic: String, lessons: [String], completionReason: String) -> [String] {
        var questions: [String] = []
        if completionReason == "user_stopped" {
            questions.append("I stopped as requested. Want me to resume this later?")
        }
        if completionReason == "learned_enough" {
            questions.append("I reached a good coverage point. Do you want deeper technical detail next?")
        }
        if completionReason == "storage_budget_reached" {
            questions.append("I hit this session's storage budget. Want me to continue with a tighter summary mode?")
        }
        if lessons.count < 4 {
            questions.append("What should I focus on next so I can learn this better?")
        }
        questions.append("Do you want me to keep learning about \(topic), or switch to another topic?")
        return Array(questions.prefix(2))
    }

    private func progressFraction(now: Date, from start: Date, to end: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1.0 }
        let elapsed = now.timeIntervalSince(start)
        return min(1.0, max(0.0, elapsed / total))
    }

    private func shouldEndSessionEarly(elapsedFraction: Double,
                                       stagnantRounds: Int,
                                       sourceCount: Int,
                                       lessonCount: Int) -> Bool {
        guard elapsedFraction >= earlyExitPolicy.minimumElapsedFraction else { return false }
        guard sourceCount >= earlyExitPolicy.minimumSources else { return false }
        guard lessonCount >= earlyExitPolicy.minimumLessons else { return false }
        return stagnantRounds >= earlyExitPolicy.stagnantRoundsThreshold
    }

    private func dedupeQueries(_ queries: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for query in queries {
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            output.append(query.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private func dedupeStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for value in values {
            let clean = cleanLine(value)
            guard !clean.isEmpty else { continue }
            let key = clean.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            output.append(clean)
        }
        return output
    }

    private func suggestedQueriesFromOpenAI(topic: String, lessons: [String]) async -> [String] {
        guard OpenAISettings.isConfigured else { return [] }
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return [] }

        let lessonContext = lessons.prefix(8).joined(separator: " | ")
        let system = """
        You generate internet research search queries for an autonomous assistant.
        Return STRICT JSON only: {"queries":["..."]}.
        Rules:
        - 8 to 16 concise search queries.
        - Keep each query under 90 characters.
        - Queries should broaden and deepen coverage.
        """
        let user = """
        Topic: \(topic)
        Current lessons: \(lessonContext.isEmpty ? "none yet" : lessonContext)
        Return diverse next search queries.
        """
        let requestBody: [String: Any] = [
            "model": OpenAISettings.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.4,
            "max_tokens": 320
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)
        let requestID = OpenAIAPILogStore.shared.logHTTPRequest(
            service: "AutonomousLearningService.suggestedQueriesFromOpenAI",
            endpoint: url.absoluteString,
            method: "POST",
            model: OpenAISettings.model,
            timeoutSeconds: request.timeoutInterval,
            payload: requestBody
        )
        let startedAt = Date()

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                OpenAIAPILogStore.shared.logHTTPError(
                    requestID: requestID,
                    service: "AutonomousLearningService.suggestedQueriesFromOpenAI",
                    endpoint: url.absoluteString,
                    method: "POST",
                    model: OpenAISettings.model,
                    statusCode: (response as? HTTPURLResponse)?.statusCode,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                    error: "Bad HTTP response",
                    responseData: data
                )
                return []
            }
            OpenAIAPILogStore.shared.logHTTPResponse(
                requestID: requestID,
                service: "AutonomousLearningService.suggestedQueriesFromOpenAI",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.model,
                statusCode: http.statusCode,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                responseData: data
            )
            guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = envelope["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else { return [] }

            return parseQueryList(content: content)
        } catch {
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "AutonomousLearningService.suggestedQueriesFromOpenAI",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.model,
                statusCode: nil,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: error.localizedDescription,
                responseData: nil
            )
            return []
        }
    }

    private func parseQueryList(content: String) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let data = trimmed.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let queries = dict["queries"] as? [String] {
            return dedupeQueries(queries.map { String($0.prefix(90)) })
        }

        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"^\s*[-*\d\.\)]\s*"#, with: "", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(90)) }
        return dedupeQueries(lines)
    }
}
