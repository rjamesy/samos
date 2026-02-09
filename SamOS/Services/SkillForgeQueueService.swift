import Foundation
import SQLite3

/// SQLite-backed FIFO queue that processes one SkillForge job at a time.
/// Enqueue via `enqueue(goal:constraints:)`. The service drains automatically,
/// calling `SkillForge.shared.forge(...)` for each job in order.
/// All DB access is serialized via `dbQueue` to prevent multi-threaded sqlite crashes.
final class SkillForgeQueueService {

    static let shared = SkillForgeQueueService()

    // MARK: - State

    /// The currently running job (nil when idle).
    private(set) var currentJob: ForgeQueueJob?

    /// Callback when a job completes successfully. Called on MainActor by drain loop.
    var onJobCompleted: (@MainActor (ForgeQueueJob, SkillSpec) -> Void)?

    /// Callback when a job fails. Called on MainActor by drain loop.
    var onJobFailed: (@MainActor (ForgeQueueJob, String) -> Void)?

    /// Callback for streaming forge progress/log lines. Called on MainActor by drain loop.
    var onJobLog: (@MainActor (ForgeQueueJob, String) -> Void)?

    // MARK: - Private State

    private var db: OpaquePointer?
    private(set) var isAvailable = false
    private var isDraining = false
    private var drainTask: Task<Void, Never>?

    /// Serial queue protecting ALL sqlite3 operations on `db`.
    private let dbQueue = DispatchQueue(label: "com.samos.forgequeue.db")

    // MARK: - Init

    private init() {
        do {
            try openDatabase()
            try createTable()
            isAvailable = true
        } catch {
            print("[ForgeQueue] Failed to initialize: \(error.localizedDescription)")
        }
    }

    /// Test-only initializer with custom DB path.
    init(dbPath: String) {
        do {
            guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
                let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                throw NSError(domain: "ForgeQueue", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            try createTable()
            isAvailable = true
        } catch {
            print("[ForgeQueue] Failed to initialize: \(error.localizedDescription)")
        }
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Database Setup

    private func openDatabase() throws {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let samosDir = appSupport.appendingPathComponent("SamOS")

        if !fileManager.fileExists(atPath: samosDir.path) {
            try fileManager.createDirectory(at: samosDir, withIntermediateDirectories: true)
        }

        let dbPath = samosDir.appendingPathComponent("forge_queue.sqlite3").path

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw NSError(domain: "ForgeQueue", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }

        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
    }

    private func createTable() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS forge_queue (
            id TEXT PRIMARY KEY,
            goal TEXT NOT NULL,
            constraints TEXT,
            status TEXT NOT NULL DEFAULT 'queued',
            created_at REAL NOT NULL,
            started_at REAL,
            completed_at REAL
        )
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw NSError(domain: "ForgeQueue", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    // MARK: - Public API

    /// Enqueues a new forge job. Returns the job. Kicks off drain if idle.
    @discardableResult
    func enqueue(goal: String, constraints: String? = nil) -> ForgeQueueJob? {
        let job = ForgeQueueJob(goal: goal, constraints: constraints)

        let inserted: Bool = dbQueue.sync {
            guard let db = db else { return false }

            let sql = "INSERT INTO forge_queue (id, goal, constraints, status, created_at) VALUES (?, ?, ?, 'queued', ?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }

            let idStr = job.id.uuidString
            sqlite3_bind_text(stmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, goal, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if let c = constraints {
                sqlite3_bind_text(stmt, 3, c, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_double(stmt, 4, job.createdAt.timeIntervalSince1970)

            return sqlite3_step(stmt) == SQLITE_DONE
        }

        guard inserted else { return nil }

        print("[ForgeQueue] Enqueued: \(goal)")
        drainIfIdle()
        return job
    }

    /// Returns count of queued (not yet started) jobs.
    var pendingCount: Int {
        listQueued().count
    }

    /// Returns all jobs (queued + running + completed + failed), ordered by created_at ASC.
    func allJobs() -> [ForgeQueueJob] {
        dbQueue.sync {
            guard let db = db else { return [] }

            let sql = "SELECT id, goal, constraints, status, created_at, started_at, completed_at FROM forge_queue ORDER BY created_at ASC"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var jobs: [ForgeQueueJob] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let job = parseRow(stmt) { jobs.append(job) }
            }
            return jobs
        }
    }

    /// Clears all completed and failed jobs from the queue.
    func clearFinished() {
        dbQueue.sync {
            guard let db = db else { return }
            sqlite3_exec(db, "DELETE FROM forge_queue WHERE status IN ('completed', 'failed')", nil, nil, nil)
        }
    }

    /// Clears the entire queue (including queued/running). Use with caution.
    func clearAll() {
        drainTask?.cancel()
        drainTask = nil
        dbQueue.sync {
            guard let db = db else { return }
            sqlite3_exec(db, "DELETE FROM forge_queue", nil, nil, nil)
        }
        currentJob = nil
        isDraining = false
    }

    /// Stops active/queued forge processing and clears the queue.
    /// In-flight OpenAI calls are cancelled via Task cancellation where possible.
    func stopAll() {
        clearAll()
    }

    // MARK: - Drain Loop

    private func drainIfIdle() {
        guard !isDraining else { return }
        isDraining = true
        drainTask = Task { @MainActor in
            await self.drainLoop()
        }
    }

    @MainActor
    private func drainLoop() async {
        defer { drainTask = nil }
        while let next = dequeueNext() {
            if Task.isCancelled { break }
            var job = next
            job.status = .running
            job.startedAt = Date()
            updateJob(job)
            currentJob = job

            do {
                var emittedLogCount = 0
                let skill = try await SkillForge.shared.forge(
                    goal: job.goal,
                    missing: job.constraints ?? job.goal
                ) { skillJob in
                    guard skillJob.logs.count > emittedLogCount else { return }
                    let newLogs = skillJob.logs[emittedLogCount...]
                    emittedLogCount = skillJob.logs.count
                    let messages = newLogs.map(\.message)
                    Task { @MainActor in
                        for message in messages {
                            self.onJobLog?(job, message)
                        }
                    }
                }
                if Task.isCancelled { break }

                job.status = .completed
                job.completedAt = Date()
                updateJob(job)
                currentJob = nil

                onJobCompleted?(job, skill)
            } catch {
                if Task.isCancelled { break }
                job.status = .failed
                job.completedAt = Date()
                updateJob(job)
                currentJob = nil

                onJobFailed?(job, error.localizedDescription)
            }
        }
        isDraining = false
    }

    // MARK: - Private Helpers

    private func listQueued() -> [ForgeQueueJob] {
        dbQueue.sync {
            guard let db = db else { return [] }

            let sql = "SELECT id, goal, constraints, status, created_at, started_at, completed_at FROM forge_queue WHERE status = 'queued' ORDER BY created_at ASC"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var jobs: [ForgeQueueJob] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let job = parseRow(stmt) { jobs.append(job) }
            }
            return jobs
        }
    }

    private func dequeueNext() -> ForgeQueueJob? {
        dbQueue.sync {
            guard let db = db else { return nil }

            let sql = "SELECT id, goal, constraints, status, created_at, started_at, completed_at FROM forge_queue WHERE status = 'queued' ORDER BY created_at ASC LIMIT 1"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            if sqlite3_step(stmt) == SQLITE_ROW {
                return parseRow(stmt)
            }
            return nil
        }
    }

    private func updateJob(_ job: ForgeQueueJob) {
        dbQueue.sync {
            guard let db = db else { return }

            let sql = "UPDATE forge_queue SET status = ?, started_at = ?, completed_at = ? WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, job.status.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if let s = job.startedAt {
                sqlite3_bind_double(stmt, 2, s.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let c = job.completedAt {
                sqlite3_bind_double(stmt, 3, c.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            let idStr = job.id.uuidString
            sqlite3_bind_text(stmt, 4, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            sqlite3_step(stmt)
        }
    }

    private func parseRow(_ stmt: OpaquePointer?) -> ForgeQueueJob? {
        guard let stmt = stmt,
              let idCStr = sqlite3_column_text(stmt, 0),
              let goalCStr = sqlite3_column_text(stmt, 1),
              let statusCStr = sqlite3_column_text(stmt, 3)
        else { return nil }

        let idString = String(cString: idCStr)
        guard let uuid = UUID(uuidString: idString) else { return nil }

        let goal = String(cString: goalCStr)
        let constraints: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let statusStr = String(cString: statusCStr)
        let status = ForgeQueueJob.Status(rawValue: statusStr) ?? .queued
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))

        let startedAt: Date? = sqlite3_column_type(stmt, 5) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)) : nil
        let completedAt: Date? = sqlite3_column_type(stmt, 6) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)) : nil

        return ForgeQueueJob(
            id: uuid,
            goal: goal,
            constraints: constraints,
            status: status,
            createdAt: createdAt,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}
