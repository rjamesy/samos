#if DEBUG
import Foundation
import SwiftUI

// MARK: - Debug Entry Category

enum DebugEntryCategory: String, CaseIterable, Identifiable {
    case routing
    case latency
    case affect
    case tone
    case llmRequest
    case llmResponse
    case tool
    case tts
    case stt
    case error
    case system

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .routing:     return "arrow.triangle.branch"
        case .latency:     return "clock"
        case .affect:      return "heart.text.square"
        case .tone:        return "slider.horizontal.3"
        case .llmRequest:  return "arrow.up.circle"
        case .llmResponse: return "arrow.down.circle"
        case .tool:        return "wrench"
        case .tts:         return "speaker.wave.2"
        case .stt:         return "waveform"
        case .error:       return "exclamationmark.triangle"
        case .system:      return "gearshape"
        }
    }

    var tintColor: Color {
        switch self {
        case .routing:     return .blue
        case .latency:     return .purple
        case .affect:      return .pink
        case .tone:        return .orange
        case .llmRequest:  return .cyan
        case .llmResponse: return .teal
        case .tool:        return .indigo
        case .tts:         return .green
        case .stt:         return .mint
        case .error:       return .red
        case .system:      return .gray
        }
    }

    var shortLabel: String {
        switch self {
        case .routing:     return "Route"
        case .latency:     return "Latency"
        case .affect:      return "Affect"
        case .tone:        return "Tone"
        case .llmRequest:  return "LLM Req"
        case .llmResponse: return "LLM Res"
        case .tool:        return "Tool"
        case .tts:         return "TTS"
        case .stt:         return "STT"
        case .error:       return "Error"
        case .system:      return "System"
        }
    }
}

// MARK: - Debug Entry

struct DebugEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let category: DebugEntryCategory
    let title: String
    let summary: String
    let detail: String?
    let turnID: String?
    let provider: String?
    let durationMs: Int?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DebugEntryCategory,
        title: String,
        summary: String,
        detail: String? = nil,
        turnID: String? = nil,
        provider: String? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.title = title
        self.summary = summary
        self.detail = detail
        self.turnID = turnID
        self.provider = provider
        self.durationMs = durationMs
    }
}

// MARK: - Debug Log Store

@MainActor
final class DebugLogStore: ObservableObject {
    static let shared = DebugLogStore()
    private static let maxEntries = 500

    @Published var entries: [DebugEntry] = []
    @Published var isPaused: Bool = false
    @Published var filterCategory: DebugEntryCategory? = nil
    @Published var latestAffect: String = "neutral:0"
    @Published var latestToneProfile: String = ""

    var filteredEntries: [DebugEntry] {
        guard let filter = filterCategory else { return entries }
        return entries.filter { $0.category == filter }
    }

    private init() {}

    // MARK: - Core

    func append(_ entry: DebugEntry) {
        guard !isPaused else { return }
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func togglePause() {
        isPaused.toggle()
    }

    // MARK: - Convenience Loggers

    func logRouting(turnID: String?, provider: String, reason: String,
                    localOutcome: String? = nil, durationMs: Int? = nil) {
        let outcome = localOutcome.map { " outcome=\($0)" } ?? ""
        append(DebugEntry(
            category: .routing,
            title: "Route \(provider)",
            summary: "\(reason)\(outcome)",
            detail: "provider=\(provider) reason=\(reason)\(outcome)",
            turnID: turnID,
            provider: provider,
            durationMs: durationMs
        ))
    }

    func logAffect(turnID: String?, raw: String, effective: String,
                   intensity: Int, featureEnabled: Bool, userToneEnabled: Bool) {
        latestAffect = "\(effective):\(intensity)"
        append(DebugEntry(
            category: .affect,
            title: "Affect",
            summary: "\(effective):\(intensity) (raw: \(raw))",
            detail: "raw=\(raw) effective=\(effective) intensity=\(intensity) feature=\(featureEnabled) user_tone=\(userToneEnabled)",
            turnID: turnID
        ))
    }

    func logToneProfile(turnID: String?, reason: String, delta: String,
                        directness: Double, warmth: Double, humor: Double,
                        curiosity: Double, reassurance: Double,
                        formality: Double, hedging: Double) {
        let fmt = { (v: Double) -> String in String(format: "%.2f", v) }
        let profile = "d=\(fmt(directness)) w=\(fmt(warmth)) h=\(fmt(humor)) c=\(fmt(curiosity)) r=\(fmt(reassurance)) f=\(fmt(formality)) hd=\(fmt(hedging))"
        latestToneProfile = profile
        append(DebugEntry(
            category: .tone,
            title: "Tone Update",
            summary: "\(reason): \(delta)",
            detail: "reason=\(reason) delta=\(delta)\n\(profile)",
            turnID: turnID
        ))
    }

    func logLLMRequest(turnID: String?, provider: String, model: String? = nil,
                       textPreview: String) {
        let preview = String(textPreview.prefix(100))
        append(DebugEntry(
            category: .llmRequest,
            title: "\(provider) Request",
            summary: preview,
            detail: "provider=\(provider) model=\(model ?? "n/a")\ntext: \(textPreview)",
            turnID: turnID,
            provider: provider
        ))
    }

    func logLLMResponse(turnID: String?, provider: String, model: String? = nil,
                        durationMs: Int? = nil, responseBody: String) {
        let preview = String(responseBody.prefix(120))
        append(DebugEntry(
            category: .llmResponse,
            title: "\(provider) Response",
            summary: preview,
            detail: "provider=\(provider) model=\(model ?? "n/a")\n\(responseBody)",
            turnID: turnID,
            provider: provider,
            durationMs: durationMs
        ))
    }

    func logLatency(turnID: String?, totalMs: Int, breakdown: String) {
        append(DebugEntry(
            category: .latency,
            title: "Latency",
            summary: "\(totalMs)ms total",
            detail: breakdown,
            turnID: turnID,
            durationMs: totalMs
        ))
    }

    func logTool(turnID: String?, name: String, args: String? = nil) {
        append(DebugEntry(
            category: .tool,
            title: "Tool: \(name)",
            summary: args ?? "(no args)",
            detail: "tool=\(name)\(args.map { " args=\($0)" } ?? "")",
            turnID: turnID
        ))
    }

    func logTTS(turnID: String?, event: String, durationMs: Int? = nil,
                correlationID: String? = nil) {
        append(DebugEntry(
            category: .tts,
            title: "TTS \(event)",
            summary: correlationID ?? "",
            detail: "event=\(event)\(correlationID.map { " correlation_id=\($0)" } ?? "")",
            turnID: turnID,
            durationMs: durationMs
        ))
    }

    func logSTT(turnID: String?, event: String, durationMs: Int? = nil) {
        append(DebugEntry(
            category: .stt,
            title: "STT \(event)",
            summary: durationMs.map { "\($0)ms" } ?? "",
            turnID: turnID,
            durationMs: durationMs
        ))
    }

    func logError(turnID: String?, message: String, detail: String? = nil) {
        append(DebugEntry(
            category: .error,
            title: "Error",
            summary: String(message.prefix(120)),
            detail: detail ?? message,
            turnID: turnID
        ))
    }

    func logSystem(title: String, summary: String, detail: String? = nil) {
        append(DebugEntry(
            category: .system,
            title: title,
            summary: summary,
            detail: detail
        ))
    }

    // MARK: - Export

    func exportText() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        return entries.map { entry in
            let ts = dateFormatter.string(from: entry.timestamp)
            let ms = entry.durationMs.map { " (\($0)ms)" } ?? ""
            var line = "[\(ts)] [\(entry.category.rawValue)] \(entry.title)\(ms) — \(entry.summary)"
            if let detail = entry.detail {
                line += "\n  \(detail.replacingOccurrences(of: "\n", with: "\n  "))"
            }
            return line
        }.joined(separator: "\n")
    }

    func exportJSON() -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let items: [[String: Any]] = entries.map { entry in
            var dict: [String: Any] = [
                "timestamp": dateFormatter.string(from: entry.timestamp),
                "category": entry.category.rawValue,
                "title": entry.title,
                "summary": entry.summary
            ]
            if let detail = entry.detail { dict["detail"] = detail }
            if let turnID = entry.turnID { dict["turnID"] = turnID }
            if let provider = entry.provider { dict["provider"] = provider }
            if let ms = entry.durationMs { dict["durationMs"] = ms }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }
}
#endif
