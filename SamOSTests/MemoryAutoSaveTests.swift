import XCTest
@testable import SamOS

@MainActor
final class MemoryAutoSaveTests: XCTestCase {

    private final class FakeExtractor: MemoryExtracting {
        var draftsPerCall: [[ExtractedMemoryDraft]]

        init(draftsPerCall: [[ExtractedMemoryDraft]]) {
            self.draftsPerCall = draftsPerCall
        }

        func extractMemories(userMessage: String, assistantMessage: String?) async -> [ExtractedMemoryDraft] {
            guard !draftsPerCall.isEmpty else { return [] }
            return draftsPerCall.removeFirst()
        }
    }

    private final class FakeScheduler: TaskScheduling {
        var scheduled: [ScheduledTask] = []

        @discardableResult
        func schedule(runAt: Date, label: String, skillId: String, payload: [String: String]) -> UUID? {
            let id = UUID()
            scheduled.append(ScheduledTask(id: id, runAt: runAt, label: label, skillId: skillId, payload: payload, status: .pending))
            return id
        }

        func listPending() -> [ScheduledTask] {
            scheduled.filter { $0.status == .pending }
        }

        @discardableResult
        func cancel(id: String) -> Bool {
            guard let idx = scheduled.firstIndex(where: { $0.id.uuidString == id && $0.status == .pending }) else {
                return false
            }
            scheduled[idx].status = .cancelled
            return true
        }
    }

    private func makeStore(file: StaticString = #filePath, line: UInt = #line) throws -> (MemoryStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory
        let dbURL = tempDir.appendingPathComponent("memory-tests-\(UUID().uuidString).sqlite3")
        let store = MemoryStore(dbPath: dbURL.path)
        XCTAssertTrue(store.isAvailable, file: file, line: line)
        return (store, dbURL)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "memory-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testAutoSaveAddsMax2PerTurn() async throws {
        let (store, _) = try makeStore()

        let extractor = FakeExtractor(draftsPerCall: [[
            ExtractedMemoryDraft(type: .fact, content: "User likes espresso.", confidence: .high, ttlDays: 365, tags: ["coffee"]),
            ExtractedMemoryDraft(type: .note, content: "User is building SamOS UX polish.", confidence: .medium, ttlDays: 90, tags: ["project"]),
            ExtractedMemoryDraft(type: .checkin, content: "User feels stressed today.", confidence: .medium, ttlDays: 7, tags: ["wellbeing"])
        ]])
        let scheduler = FakeScheduler()
        let checkins = MemoryCheckInScheduler(scheduler: scheduler, store: store, defaults: makeDefaults())
        let service = MemoryAutoSaveService(extractor: extractor, store: store, checkInScheduler: checkins)

        let report = await service.processTurn(userMessage: "I feel stressed and I love espresso", assistantMessage: "Thanks for sharing")

        XCTAssertEqual(report.saved.count, 2)
        XCTAssertEqual(store.listMemories().count, 2)
    }

    func testDedupeUpdatesInsteadOfAdding() async throws {
        let (store, _) = try makeStore()

        let extractor = FakeExtractor(draftsPerCall: [
            [ExtractedMemoryDraft(type: .fact, content: "User loves Interstellar.", confidence: .high, ttlDays: 365, tags: ["movie"])],
            [ExtractedMemoryDraft(type: .fact, content: "user loves interstellar", confidence: .medium, ttlDays: 365, tags: ["film"])]
        ])
        let checkins = MemoryCheckInScheduler(scheduler: FakeScheduler(), store: store, defaults: makeDefaults())
        let service = MemoryAutoSaveService(extractor: extractor, store: store, checkInScheduler: checkins)

        let first = await service.processTurn(userMessage: "I love Interstellar", assistantMessage: nil)
        let second = await service.processTurn(userMessage: "Still love interstellar", assistantMessage: nil)

        XCTAssertEqual(first.saved.count, 1)
        XCTAssertEqual(second.saved.count, 1)

        let facts = store.listMemories(filterType: .fact)
        XCTAssertEqual(facts.count, 1)
        XCTAssertGreaterThanOrEqual(facts[0].lastSeenAt.timeIntervalSince1970, facts[0].createdAt.timeIntervalSince1970)
    }

    func testRecallInjectsMax3AndMaxChars() throws {
        let (store, _) = try makeStore()

        _ = store.addMemory(type: .fact, content: "Working on SamOS UX and response pacing improvements.")
        _ = store.addMemory(type: .note, content: "Prefers concise summaries before detailed breakdowns.")
        _ = store.addMemory(type: .fact, content: "Likes markdown checklists for implementation tracking.")
        _ = store.addMemory(type: .note, content: "Has been testing memory extraction in this sprint.")
        _ = store.addMemory(type: .fact, content: "Enjoys Interstellar and sci-fi film discussions.")

        let context = store.memoryContext(query: "sprint memory ux", maxItems: 3, maxChars: 300)

        XCTAssertLessThanOrEqual(context.count, 3)
        let charCount = context.reduce(0) { partial, row in
            partial + "- \(row.type.rawValue): \(row.content)".count
        }
        XCTAssertLessThanOrEqual(charCount, 300)
    }

    func testCheckinSchedulesOnce() throws {
        let (store, _) = try makeStore()

        let scheduler = FakeScheduler()
        let checkinScheduler = MemoryCheckInScheduler(scheduler: scheduler, store: store, defaults: makeDefaults())

        guard let row = store.addMemory(type: .checkin, content: "User does not feel well.", ttlDays: 7) else {
            XCTFail("Expected checkin memory")
            return
        }

        let now = Date()
        let first = checkinScheduler.scheduleIfNeeded(for: row, now: now)
        let second = checkinScheduler.scheduleIfNeeded(for: row, now: now.addingTimeInterval(60))

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(scheduler.scheduled.count, 1)
        XCTAssertEqual(scheduler.scheduled.first?.payload["type"], "memory_checkin")
    }

    func testTTLPrunesExpired() throws {
        let (store, _) = try makeStore()

        let now = Date()
        let createdAt = now

        guard let expired = store.addMemory(type: .note,
                                            content: "Short-lived note",
                                            ttlDays: 1,
                                            createdAt: createdAt,
                                            lastSeenAt: createdAt) else {
            XCTFail("Expected expired memory to be inserted")
            return
        }

        _ = store.addMemory(type: .fact,
                            content: "Long-lived fact",
                            ttlDays: 365,
                            createdAt: now,
                            lastSeenAt: now)

        let removed = store.pruneExpiredMemories(referenceDate: now.addingTimeInterval(2 * 86_400))

        XCTAssertEqual(removed, 1)
        XCTAssertNil(store.memory(id: expired.id))
        XCTAssertEqual(store.listMemories().count, 1)
    }
}

final class SelfLearningLoopTests: XCTestCase {

    private func makeStore() -> SelfLearningStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-learning-\(UUID().uuidString).json")
        return SelfLearningStore(fileURL: url)
    }

    func testSelfLearningStoreDedupesSimilarLessons() {
        let store = makeStore()
        store.recordLesson(
            "Keep spoken replies short and move detailed structure to the canvas.",
            category: .brevity,
            confidence: 0.8
        )
        store.recordLesson(
            "keep spoken replies short, and move detailed structure to the canvas",
            category: .brevity,
            confidence: 0.7
        )

        let lessons = store.allLessons()
        XCTAssertEqual(lessons.count, 1, "Similar lessons should dedupe into one record")
        XCTAssertEqual(lessons[0].observedCount, 2, "Duplicate observation should increment observed count")
    }

    func testSelfLearningContextRespectsMaxItemsAndChars() {
        let store = makeStore()
        store.recordLesson("Use one short follow-up question at most.", category: .followup, confidence: 0.8)
        store.recordLesson("When user replies briefly after your question, continue the same context.", category: .continuity, confidence: 0.9)
        store.recordLesson("If uncertain, hedge naturally and offer to double-check.", category: .confidence, confidence: 0.85)
        store.recordLesson("If the user says you missed the point, clarify target before proceeding.", category: .clarity, confidence: 0.82)

        let lines = store.relevantLessonTexts(query: "brief reply context", maxItems: 3, maxChars: 140)
        XCTAssertLessThanOrEqual(lines.count, 3)
        let chars = lines.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(chars, 140)
    }

    @MainActor
    func testLearningServiceAddsContinuityLessonForShortAnswer() {
        let store = makeStore()
        let service = SelfLearningService(store: store)

        service.observeIncomingUserReply(
            userMessage: "Blue",
            previousAssistantMessage: "What's your favorite color?"
        )

        let lines = store.relevantLessonTexts(query: "short answer question", maxItems: 3, maxChars: 220)
        let joined = lines.joined(separator: " ").lowercased()
        XCTAssertTrue(joined.contains("short user reply") || joined.contains("short reply"),
                      "Continuity lesson should be saved for brief answers after assistant questions")
    }

    @MainActor
    func testLearningServiceAddsBrevityLessonForLongSpokenOutputWithoutCanvas() {
        let store = makeStore()
        let service = SelfLearningService(store: store)
        let longAssistant = String(repeating: "a", count: 260)

        service.processTurn(
            userMessage: "explain this",
            assistantMessage: longAssistant,
            hadCanvasOutput: false,
            previousAssistantMessage: nil
        )

        let lines = store.relevantLessonTexts(query: "dense long answer", maxItems: 3, maxChars: 220)
        let joined = lines.joined(separator: " ").lowercased()
        XCTAssertTrue(joined.contains("canvas"),
                      "Brevity lesson should push dense detail to canvas")
    }
}

final class WebsiteLearningStoreTests: XCTestCase {

    private func makeLearningStore() -> WebsiteLearningStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("website-learning-\(UUID().uuidString).json")
        return WebsiteLearningStore(fileURL: url)
    }

    private func makeMemoryStore(file: StaticString = #filePath, line: UInt = #line) -> MemoryStore {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("website-memory-\(UUID().uuidString).sqlite3")
        let store = MemoryStore(dbPath: dbURL.path)
        XCTAssertTrue(store.isAvailable, file: file, line: line)
        return store
    }

    func testWebsiteLearningStoreDedupesCanonicalURL() {
        let store = makeLearningStore()
        _ = store.saveLearnedPage(
            url: "https://example.com/docs/",
            title: "Docs",
            summary: "First summary.",
            highlights: ["Point A"]
        )
        _ = store.saveLearnedPage(
            url: "https://example.com/docs?utm_source=test",
            title: "Docs Updated",
            summary: "Second summary.",
            highlights: ["Point B"]
        )

        let records = store.allRecords()
        XCTAssertEqual(records.count, 1, "Canonical URL dedupe should keep a single record")
        XCTAssertEqual(records[0].summary, "Second summary.")
        XCTAssertEqual(records[0].title, "Docs Updated")
    }

    func testWebsiteLearningContextRespectsMaxItemsAndChars() {
        let store = makeLearningStore()
        _ = store.saveLearnedPage(url: "https://example.com/a", title: "A", summary: "Alpha summary for testing.", highlights: ["A1", "A2"])
        _ = store.saveLearnedPage(url: "https://example.com/b", title: "B", summary: "Beta summary for testing.", highlights: ["B1", "B2"])
        _ = store.saveLearnedPage(url: "https://example.com/c", title: "C", summary: "Gamma summary for testing.", highlights: ["C1", "C2"])

        let lines = store.relevantContext(query: "what did you learn", maxItems: 2, maxChars: 120)

        XCTAssertLessThanOrEqual(lines.count, 2)
        XCTAssertLessThanOrEqual(lines.reduce(0) { $0 + $1.count }, 120)
    }

    func testWebsiteLearningContextReranksBySemanticMatch() {
        let store = makeLearningStore()
        let now = Date()
        _ = store.saveLearnedPage(
            url: "https://example.com/ui",
            title: "SwiftUI Notes",
            summary: "Layout spacing and typography guidance.",
            highlights: ["alignment", "stack spacing"],
            now: now
        )
        _ = store.saveLearnedPage(
            url: "https://example.com/brew",
            title: "Home Brewing",
            summary: "Fermentation temperature control and sanitizing reduce off-flavors.",
            highlights: ["fermentation", "sanitize", "temperature"],
            now: now.addingTimeInterval(-86_400 * 3)
        )

        let lines = store.relevantContext(query: "how do I improve fermentation consistency?", maxItems: 1, maxChars: 180)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("Home Brewing"), "Semantic retrieval should prefer topical match over pure recency")
    }

    func testLearnWebsiteToolStoresAndReturnsStructuredPayload() {
        let learningStore = makeLearningStore()
        let memoryStore = makeMemoryStore()
        let html = """
        <html><head><title>SamOS Docs</title></head>
        <body>
        <h1>SamOS Documentation</h1>
        <p>SamOS supports voice workflows for scheduling, memory, and tool execution.</p>
        <p>The platform keeps responses concise and pushes structured detail to the canvas.</p>
        </body></html>
        """

        let tool = LearnWebsiteTool(
            fetcher: { _ in LearnWebsiteTool.FetchResult(body: html, contentType: "text/html; charset=utf-8") },
            learningStore: learningStore,
            memoryStore: memoryStore
        )
        let output = tool.execute(args: ["url": "https://example.com/docs"])

        XCTAssertEqual(output.kind, .markdown)

        guard let data = output.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("Expected structured JSON payload from learn_website")
        }

        XCTAssertEqual(dict["kind"] as? String, "website_learning")
        XCTAssertTrue((dict["formatted"] as? String)?.contains("# Learned From") == true)
        XCTAssertTrue((dict["formatted"] as? String)?.contains("SamOS") == true)

        let records = learningStore.recentRecords(limit: 5)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].summary.lowercased().contains("samos"))

        let memoryContext = memoryStore.memoryContext(query: "samos docs", maxItems: 3, maxChars: 300)
        XCTAssertFalse(memoryContext.isEmpty, "learn_website should seed note memory for recall")
    }

    func testWebsiteLearningStoreDoesNotPruneAtLegacyCap() {
        let store = makeLearningStore()
        for idx in 0..<170 {
            _ = store.saveLearnedPage(
                url: "https://example.com/page-\(idx)",
                title: "Page \(idx)",
                summary: "Summary \(idx)",
                highlights: ["Point \(idx)"]
            )
        }

        XCTAssertEqual(store.count(), 170, "Store should retain all learned pages without a fixed cap.")
    }

    func testWebsiteLearningStoreRetainsAllHighlights() {
        let store = makeLearningStore()
        let highlights = (0..<14).map { "Highlight \($0) with useful detail." }
        _ = store.saveLearnedPage(
            url: "https://example.com/highlights",
            title: "Highlights",
            summary: "Summary",
            highlights: highlights
        )

        let records = store.allRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].highlights.count, highlights.count, "Learning store should not truncate highlights.")
    }

    func testLearnWebsiteToolDoesNotCapHighlightsAtLegacyLimit() {
        let learningStore = makeLearningStore()
        let memoryStore = makeMemoryStore()
        let bodyLines = (0..<30).map { idx in
            "<p>Key point \(idx): This sentence is long enough to be considered useful learning content for summarization logic.</p>"
        }
        let html = """
        <html><head><title>Deep Content</title></head><body>
        \(bodyLines.joined(separator: "\n"))
        </body></html>
        """

        let tool = LearnWebsiteTool(
            fetcher: { _ in LearnWebsiteTool.FetchResult(body: html, contentType: "text/html; charset=utf-8") },
            learningStore: learningStore,
            memoryStore: memoryStore
        )
        _ = tool.execute(args: ["url": "https://example.com/deep-content"])

        let records = learningStore.recentRecords(limit: 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertGreaterThan(records[0].highlights.count, 16, "Website learning should not be capped at the legacy 16-highlight limit.")
    }
}

final class AutonomousLearningTests: XCTestCase {

    private final class FakeAutonomousController: AutonomousLearningControlling {
        var startResult = AutonomousLearningStartResult(
            started: true,
            sessionID: UUID(),
            expectedFinishAt: Date().addingTimeInterval(300),
            message: "started"
        )
        var stopResult = AutonomousLearningStopResult(
            stopped: true,
            sessionID: UUID(),
            message: "stopped"
        )
        var active: AutonomousLearningService.ActiveSession?
        var reports: [AutonomousLearningReport] = []
        private(set) var startedMinutes: Int?
        private(set) var startedTopic: String?
        private(set) var stopCallCount: Int = 0

        func startSession(minutes: Int, topic: String?) -> AutonomousLearningStartResult {
            startedMinutes = minutes
            startedTopic = topic
            return startResult
        }

        func stopActiveSession() -> AutonomousLearningStopResult {
            stopCallCount += 1
            return stopResult
        }

        func activeSessionSnapshot() -> AutonomousLearningService.ActiveSession? {
            active
        }

        func recentReports(limit: Int) -> [AutonomousLearningReport] {
            Array(reports.prefix(max(0, limit)))
        }
    }

    private func makeReportStore() -> AutonomousLearningReportStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autonomous-reports-\(UUID().uuidString).json")
        return AutonomousLearningReportStore(fileURL: url)
    }

    func testAutonomousLearnToolStartedReturnsStructuredPayload() {
        let fake = FakeAutonomousController()
        fake.startResult = AutonomousLearningStartResult(
            started: true,
            sessionID: UUID(),
            expectedFinishAt: Date().addingTimeInterval(300),
            message: "Starting"
        )
        let tool = AutonomousLearnTool(controller: fake)
        let output = tool.execute(args: ["minutes": "5", "topic": "deep work"])

        XCTAssertEqual(output.kind, .markdown)
        guard let data = output.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("Expected structured payload")
        }
        XCTAssertEqual(dict["kind"] as? String, "autonomous_learn")
        let formatted = dict["formatted"] as? String ?? ""
        XCTAssertTrue(formatted.contains("Autonomous Learning Started"))
        XCTAssertTrue(formatted.contains("Duration: 5"))
    }

    func testAutonomousLearnToolAlreadyRunningPayload() {
        let fake = FakeAutonomousController()
        fake.startResult = AutonomousLearningStartResult(
            started: false,
            sessionID: UUID(),
            expectedFinishAt: Date().addingTimeInterval(180),
            message: "Already running"
        )
        let tool = AutonomousLearnTool(controller: fake)
        let output = tool.execute(args: ["minutes": "5"])

        guard let data = output.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("Expected structured payload")
        }
        let formatted = dict["formatted"] as? String ?? ""
        XCTAssertTrue(formatted.contains("Already Running"))
    }

    func testAutonomousLearningReportStoreKeepsNewestFirst() {
        let store = makeReportStore()
        let older = AutonomousLearningReport(
            id: UUID(),
            topic: "older",
            requestedMinutes: 3,
            startedAt: Date().addingTimeInterval(-120),
            finishedAt: Date().addingTimeInterval(-60),
            sources: ["https://a.com"],
            lessons: ["a"],
            openQuestions: []
        )
        let newer = AutonomousLearningReport(
            id: UUID(),
            topic: "newer",
            requestedMinutes: 4,
            startedAt: Date().addingTimeInterval(-30),
            finishedAt: Date(),
            sources: ["https://b.com"],
            lessons: ["b"],
            openQuestions: []
        )

        store.add(older)
        store.add(newer)
        let reports = store.recent(limit: 5)

        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.first?.topic, "newer")
        XCTAssertEqual(reports.last?.topic, "older")
    }

    func testAutonomousLearnToolPassesLargeMinuteValuesWithoutCap() {
        let fake = FakeAutonomousController()
        let tool = AutonomousLearnTool(controller: fake)
        _ = tool.execute(args: ["minutes": "90", "topic": "systems design"])

        XCTAssertEqual(fake.startedMinutes, 90)
        XCTAssertEqual(fake.startedTopic, "systems design")
    }

    func testAutonomousLearningReportStoreDoesNotPruneAtLegacyCap() {
        let store = makeReportStore()
        let now = Date()

        for idx in 0..<140 {
            let report = AutonomousLearningReport(
                id: UUID(),
                topic: "topic-\(idx)",
                requestedMinutes: 1,
                startedAt: now.addingTimeInterval(TimeInterval(-idx - 1)),
                finishedAt: now.addingTimeInterval(TimeInterval(-idx)),
                sources: ["https://example.com/\(idx)"],
                lessons: ["lesson-\(idx)"],
                openQuestions: []
            )
            store.add(report)
        }

        XCTAssertEqual(store.count(), 140, "Report store should retain all session reports without a fixed cap.")
    }

    func testStopAutonomousLearnToolReturnsStructuredPayloadWhenStopped() {
        let fake = FakeAutonomousController()
        fake.stopResult = AutonomousLearningStopResult(
            stopped: true,
            sessionID: UUID(),
            message: "Stopped autonomous learning session on home brewing."
        )
        let tool = StopAutonomousLearnTool(controller: fake)
        let output = tool.execute(args: [:])

        XCTAssertEqual(fake.stopCallCount, 1)
        XCTAssertEqual(output.kind, .markdown)
        guard let data = output.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("Expected structured payload")
        }
        XCTAssertEqual(dict["kind"] as? String, "autonomous_learn_stop")
        XCTAssertEqual(dict["stopped"] as? Bool, true)
        XCTAssertTrue((dict["formatted"] as? String ?? "").contains("Stopped autonomous learning"))
    }

    func testStopAutonomousLearnToolReturnsIdleMessageWhenNotRunning() {
        let fake = FakeAutonomousController()
        fake.stopResult = AutonomousLearningStopResult(
            stopped: false,
            sessionID: nil,
            message: "No autonomous learning session is currently running."
        )
        let tool = StopAutonomousLearnTool(controller: fake)
        let output = tool.execute(args: [:])

        guard let data = output.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("Expected structured payload")
        }
        XCTAssertEqual(dict["stopped"] as? Bool, false)
        XCTAssertTrue((dict["spoken"] as? String ?? "").contains("isn't an autonomous learning session"))
    }
}
