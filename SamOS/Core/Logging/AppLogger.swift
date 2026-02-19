import Foundation

protocol AppLogger {
    func info(_ event: String, metadata: [String: String])
    func error(_ event: String, metadata: [String: String])
}

final class JSONLineLogger: AppLogger {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "SamOS.JSONLineLogger")

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("SamOS/logs", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            self.fileURL = dir.appendingPathComponent("runtime_events.jsonl")
            if !FileManager.default.fileExists(atPath: self.fileURL.path) {
                FileManager.default.createFile(atPath: self.fileURL.path, contents: nil)
            }
        }
    }

    func info(_ event: String, metadata: [String: String] = [:]) {
        write(level: "info", event: event, metadata: metadata)
    }

    func error(_ event: String, metadata: [String: String] = [:]) {
        write(level: "error", event: event, metadata: metadata)
    }

    private func write(level: String, event: String, metadata: [String: String]) {
        let payload: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "level": level,
            "event": event,
            "metadata": metadata
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line += "\n"

        queue.async { [fileURL] in
            guard let handle = try? FileHandle(forWritingTo: fileURL),
                  let bytes = line.data(using: .utf8) else {
                return
            }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: bytes)
            } catch {
                // swallow logger I/O failures to keep app resilient
            }
        }
    }
}
