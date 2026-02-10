import Foundation
import SQLite3

// MARK: - Scheduled Task

struct ScheduledTask: Identifiable {
    let id: UUID
    let runAt: Date
    let label: String
    let skillId: String
    let payload: [String: String]
    var status: TaskStatus

    enum TaskStatus: String {
        case pending
        case fired
        case cancelled
        case dismissed
    }
}

// MARK: - Task Scheduler

/// SQLite-backed scheduler that fires callbacks when tasks come due.
/// Polls every second for pending tasks past their run_at time.
/// All DB access is serialized via `dbQueue` to prevent multi-threaded sqlite crashes.
final class TaskScheduler {

    static let shared = TaskScheduler()

    /// Called on the main thread when a task fires.
    var onTaskFired: ((ScheduledTask) -> Void)?

    private var db: OpaquePointer?
    private var pollTimer: Timer?
    private(set) var isAvailable = false
    private static let pollIntervalSeconds: TimeInterval = 1.0

    /// Serial queue protecting ALL sqlite3 operations on `db`.
    private let dbQueue = DispatchQueue(label: "com.samos.taskscheduler.db")

    // MARK: - Init

    private init() {
        do {
            try openDatabase()
            try createTable()
            isAvailable = true
        } catch {
            print("[TaskScheduler] Failed to initialize: \(error.localizedDescription)")
        }
    }

    /// Creates a TaskScheduler with a custom DB path (for tests).
    init(dbPath: String) {
        do {
            guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
                let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                throw NSError(domain: "TaskScheduler", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            try createTable()
            isAvailable = true
        } catch {
            print("[TaskScheduler] Failed to initialize: \(error.localizedDescription)")
        }
    }

    deinit {
        stopPolling()
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

        let dbPath = samosDir.appendingPathComponent("scheduler.sqlite3").path

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw NSError(domain: "TaskScheduler", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }

        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
    }

    private func createTable() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            run_at REAL NOT NULL,
            label TEXT NOT NULL DEFAULT '',
            skill_id TEXT NOT NULL DEFAULT '',
            payload_json TEXT NOT NULL DEFAULT '{}',
            status TEXT NOT NULL DEFAULT 'pending'
        )
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw NSError(domain: "TaskScheduler", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    // MARK: - Launch-time Cleanup

    /// Expires any pending tasks whose run_at is in the past.
    /// Call on launch BEFORE startPolling() to prevent ghost alarms.
    func expireStaleTasks() {
        let changed: Int32 = dbQueue.sync {
            guard let db = db else { return 0 }
            let now = Date().timeIntervalSince1970
            let sql = "UPDATE tasks SET status = 'fired' WHERE status = 'pending' AND run_at <= ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, now)
            sqlite3_step(stmt)
            return sqlite3_changes(db)
        }
        if changed > 0 {
            print("[TaskScheduler] Expired \(changed) stale task(s) on launch")
        }
    }

    /// Expires ALL pending tasks regardless of run_at.
    /// Used on DEBUG launch to guarantee a clean slate.
    func expireAllPending() {
        let changed: Int32 = dbQueue.sync {
            guard let db = db else { return 0 }
            let sql = "UPDATE tasks SET status = 'fired' WHERE status = 'pending'"
            sqlite3_exec(db, sql, nil, nil, nil)
            return sqlite3_changes(db)
        }
        if changed > 0 {
            print("[TaskScheduler] DEBUG: Expired ALL \(changed) pending task(s) on launch")
        }
    }

    // MARK: - Polling

    func startPolling() {
        guard pollTimer == nil else { return }
        checkForDueTasks()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            self?.checkForDueTasks()
        }
        pollTimer?.tolerance = 0.1
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func checkForDueTasks() {
        // Query + mark fired inside one sync block; callbacks outside.
        let dueTasks: [ScheduledTask] = dbQueue.sync {
            guard let db = db else { return [] }

            let now = Date().timeIntervalSince1970
            let sql = "SELECT id, run_at, label, skill_id, payload_json, status FROM tasks WHERE status = 'pending' AND run_at <= ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, now)

            var tasks: [ScheduledTask] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let task = parseRow(stmt) {
                    tasks.append(task)
                }
            }

            // Mark each as fired while still holding the queue
            for task in tasks {
                _updateStatus(id: task.id.uuidString, status: .fired)
            }

            return tasks
        }

        for task in dueTasks {
            onTaskFired?(task)
        }
    }

    // MARK: - Public API

    /// Schedules a new task. Returns the task ID.
    @discardableResult
    func schedule(runAt: Date, label: String = "", skillId: String = "", payload: [String: String] = [:]) -> UUID? {
        return dbQueue.sync {
            guard let db = db else { return nil }

            let id = UUID()
            let payloadJSON: String
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let str = String(data: data, encoding: .utf8) {
                payloadJSON = str
            } else {
                payloadJSON = "{}"
            }

            let sql = "INSERT INTO tasks (id, run_at, label, skill_id, payload_json, status) VALUES (?, ?, ?, ?, ?, 'pending')"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            let idStr = id.uuidString
            sqlite3_bind_text(stmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 2, runAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, label, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 4, skillId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 5, payloadJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }

            print("[TaskScheduler] Scheduled task \(idStr.prefix(8)) for \(runAt)")
            return id
        }
    }

    /// Cancels a pending task by ID string.
    @discardableResult
    func cancel(id: String) -> Bool {
        dbQueue.sync { _updateStatus(id: id, status: .cancelled) }
    }

    /// Dismisses a fired task (e.g. alarm acknowledged).
    @discardableResult
    func dismiss(id: String) -> Bool {
        dbQueue.sync { _updateStatus(id: id, status: .dismissed) }
    }

    /// Returns all pending tasks, ordered by run_at.
    func listPending() -> [ScheduledTask] {
        dbQueue.sync {
            guard let db = db else { return [] }

            let sql = "SELECT id, run_at, label, skill_id, payload_json, status FROM tasks WHERE status = 'pending' ORDER BY run_at ASC"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var tasks: [ScheduledTask] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let task = parseRow(stmt) {
                    tasks.append(task)
                }
            }
            return tasks
        }
    }

    // MARK: - Private

    /// Updates a task's status. Caller MUST be on `dbQueue`.
    @discardableResult
    private func _updateStatus(id: String, status: ScheduledTask.TaskStatus) -> Bool {
        guard let db = db else { return false }

        let sql = "UPDATE tasks SET status = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, status.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
    }

    private func parseRow(_ stmt: OpaquePointer?) -> ScheduledTask? {
        guard let stmt = stmt,
              let idCStr = sqlite3_column_text(stmt, 0),
              let labelCStr = sqlite3_column_text(stmt, 2),
              let skillIdCStr = sqlite3_column_text(stmt, 3),
              let payloadCStr = sqlite3_column_text(stmt, 4),
              let statusCStr = sqlite3_column_text(stmt, 5)
        else { return nil }

        let idString = String(cString: idCStr)
        guard let uuid = UUID(uuidString: idString) else { return nil }

        let runAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let label = String(cString: labelCStr)
        let skillId = String(cString: skillIdCStr)
        let payloadStr = String(cString: payloadCStr)
        let statusStr = String(cString: statusCStr)
        let status = ScheduledTask.TaskStatus(rawValue: statusStr) ?? .pending

        var payload: [String: String] = [:]
        if let data = payloadStr.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            payload = dict
        }

        return ScheduledTask(id: uuid, runAt: runAt, label: label, skillId: skillId, payload: payload, status: status)
    }
}
