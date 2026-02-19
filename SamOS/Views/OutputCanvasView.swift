import SwiftUI
import AppKit

private enum OutputCanvasAutoScroll {
    /// Returns the first changed/new item id so the canvas can scroll to the start of new content.
    static func targetItemID(old: [OutputItem], new: [OutputItem]) -> UUID? {
        guard !new.isEmpty else { return nil }

        let overlap = min(old.count, new.count)
        if overlap > 0 {
            for idx in 0..<overlap where old[idx] != new[idx] {
                return new[idx].id
            }
        }

        if new.count > old.count {
            return new[overlap].id
        }

        return nil
    }
}

private enum OutputCanvasCopy {
    static func copyAllText(_ items: [OutputItem]) -> Bool {
        let text = combinedText(from: items).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    static func combinedText(from items: [OutputItem]) -> String {
        items.compactMap(itemText).joined(separator: "\n\n")
    }

    private static func itemText(_ item: OutputItem) -> String? {
        switch item.kind {
        case .markdown:
            return OutputCanvasMarkdown.toolDisplayString(item.payload)
        case .card:
            return item.payload
        case .image:
            return imageText(item.payload)
        }
    }

    private static func imageText(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ImagePayload.self, from: data) else {
            return nil
        }

        var lines: [String] = ["[Image]"]
        if let alt = decoded.alt?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
            lines.append("Alt: \(alt)")
        }
        for url in decoded.resolvedUrls {
            lines.append("URL: \(url)")
        }
        return lines.joined(separator: "\n")
    }
}

struct OutputCanvasView: View {
    @EnvironmentObject var appState: AppState
    @State private var didCopyAll = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Output Canvas")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                if !appState.outputItems.isEmpty {
                    Button {
                        if OutputCanvasCopy.copyAllText(appState.outputItems) {
                            didCopyAll = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                didCopyAll = false
                            }
                        }
                    } label: {
                        Image(systemName: didCopyAll ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy all output text")

                    Button("Clear") {
                        appState.clearOutputCanvas()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if appState.outputItems.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Output will appear here")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(appState.outputItems) { item in
                                OutputItemView(item: item)
                                    .id(item.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: appState.outputItems) { oldItems, newItems in
                        guard let targetID = OutputCanvasAutoScroll.targetItemID(old: oldItems, new: newItems) else {
                            return
                        }
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(targetID, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Output Item View

struct OutputItemView: View {
    @EnvironmentObject var appState: AppState
    let item: OutputItem
    private let parsedCardType: String?

    init(item: OutputItem) {
        self.item = item
        if item.kind == .card {
            self.parsedCardType = Self.parseCardType(item.payload)
        } else {
            self.parsedCardType = nil
        }
    }

    var body: some View {
        switch item.kind {
        case .markdown:
            MarkdownTextView(markdown: item.payload)
        case .card:
            if parsedCardType == "alarm" {
                AlarmCardView(payload: item.payload)
                    .environmentObject(appState)
            } else if parsedCardType == "learn_skill_permission_review" {
                LearnSkillPermissionCardView(payload: item.payload)
                    .environmentObject(appState)
            } else {
                MarkdownTextView(markdown: item.payload)
            }
        case .image:
            ImageOutputView(payload: item.payload)
        }
    }

    private static func parseCardType(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict["type"] as? String
    }
}

// MARK: - Alarm Card

struct AlarmCardView: View {
    @EnvironmentObject var appState: AppState
    let payload: String

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "alarm.fill")
                    .font(.title2)
                    .foregroundColor(.orange)
                    .symbolEffect(.pulse, isActive: appState.alarmSession.isRinging)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alarm")
                        .font(.headline)
                    if let label = parseLabel(), !label.isEmpty {
                        Text(label)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    if appState.alarmSession.isRinging {
                        Text("Ringing...")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                if parseCanSnooze() && appState.alarmSession.canSnooze {
                    Button(action: {
                        Task {
                            await appState.alarmSession.handleUserReply("snooze 5 minutes")
                        }
                    }) {
                        Text("Snooze 5m")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }

                Button(action: { appState.dismissAlarm() }) {
                    Text("Dismiss")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    private func parseLabel() -> String? {
        guard let data = payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict["label"] as? String
    }

    private func parseCanSnooze() -> Bool {
        guard let data = payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return dict["can_snooze"] as? Bool ?? false
    }
}

// MARK: - Learn Skill Permission Card

struct LearnSkillPermissionCardView: View {
    @EnvironmentObject var appState: AppState
    let payload: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "sparkles.rectangle.stack")
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skill Permission Review")
                        .font(.headline)
                    Text(parseSkillName() ?? "New Skill")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if let goal = parseGoal(), !goal.isEmpty {
                Text("Goal: \(goal)")
                    .font(.subheadline)
            }

            if !parsePermissions().isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Requested permissions")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    ForEach(parsePermissions(), id: \.self) { permission in
                        Text("• \(permission)")
                            .font(.caption)
                    }
                }
            }

            if !parseTools().isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tools")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    ForEach(parseTools(), id: \.self) { tool in
                        Text("• \(tool)")
                            .font(.caption)
                    }
                }
            }

            if !parseTests().isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Validation tests")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    ForEach(parseTests(), id: \.self) { test in
                        Text("• \(test)")
                            .font(.caption)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Reject") {
                    appState.approveLearnSkillPermissions(false)
                }
                .buttonStyle(.bordered)

                Button("Approve & Install") {
                    appState.approveLearnSkillPermissions(true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(12)
    }

    private func parseObject() -> [String: Any] {
        guard let data = payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private func parseSkillName() -> String? {
        parseObject()["skill_name"] as? String
    }

    private func parseGoal() -> String? {
        parseObject()["goal"] as? String
    }

    private func parsePermissions() -> [String] {
        parseObject()["permissions"] as? [String] ?? []
    }

    private func parseTools() -> [String] {
        parseObject()["tools"] as? [String] ?? []
    }

    private func parseTests() -> [String] {
        parseObject()["tests"] as? [String] ?? []
    }
}

// MARK: - Markdown Rendering

struct MarkdownTextView: View {
    let markdown: String
    private static let defaultVisiblePages: Int = 2
    private static let pageCharacterCount: Int = 6_000

    private struct RenderCache {
        let source: String
        let pages: Int
        let blocks: [OutputCanvasMarkdown.Block]
        let hasMore: Bool
    }

    @State private var visiblePages: Int
    @State private var renderCache: RenderCache

    init(markdown: String) {
        self.markdown = markdown
        let initialPages = Self.defaultVisiblePages
        _visiblePages = State(initialValue: initialPages)
        _renderCache = State(initialValue: Self.buildCache(markdown: markdown, pages: initialPages))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(renderCache.blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }

            if renderCache.hasMore {
                Button("Show More") {
                    visiblePages += 1
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .padding(.top, 4)
            }
        }
        .onChange(of: visiblePages) { _, newPages in
            refreshCache(pages: newPages)
        }
        .onChange(of: markdown) { _, _ in
            visiblePages = Self.defaultVisiblePages
            refreshCache(pages: visiblePages)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }

    private func refreshCache(pages: Int) {
        let normalizedPages = max(1, pages)
        let next = Self.buildCache(markdown: markdown, pages: normalizedPages)
        if next.source != renderCache.source
            || next.pages != renderCache.pages
            || next.blocks != renderCache.blocks
            || next.hasMore != renderCache.hasMore {
            renderCache = next
        }
    }

    private static func buildCache(markdown: String, pages: Int) -> RenderCache {
        let source = OutputCanvasMarkdown.toolDisplayString(markdown)
        let visibleRaw = OutputCanvasMarkdown.visibleSlice(
            from: source,
            pages: pages,
            pageCharacterCount: pageCharacterCount
        )
        let blocks = OutputCanvasMarkdown.blocks(from: visibleRaw)
        return RenderCache(
            source: source,
            pages: pages,
            blocks: blocks,
            hasMore: visibleRaw.count < source.count
        )
    }
}

private struct MarkdownBlockView: View {
    let block: OutputCanvasMarkdown.Block

    var body: some View {
        switch block {
        case .blank:
            Color.clear
                .frame(height: 8)

        case .heading(let level, let text):
            inlineMarkdownText(text)
                .font(headingFont(level: level))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                inlineMarkdownText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                inlineMarkdownText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)

        case .plain(let text):
            inlineMarkdownText(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: 22)
        case 2:
            return .system(size: 19)
        case 3:
            return .system(size: 17)
        default:
            return .system(size: 15)
        }
    }

    @ViewBuilder
    private func inlineMarkdownText(_ value: String) -> some View {
        InlineMarkdownTextView(value: value)
    }
}

enum OutputCanvasMarkdown {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case numbered(number: String, text: String)
        case code(language: String?, text: String)
        case plain(text: String)
        case blank
    }

    /// Tool-window markdown must be rendered exactly as stored.
    static func toolDisplayString(_ markdown: String) -> String {
        markdown
    }

    private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.+)$")
    private static let bulletRegex = try! NSRegularExpression(pattern: "^[-*]\\s+(.+)$")
    private static let numberedRegex = try! NSRegularExpression(pattern: "^(\\d+)[\\.)]\\s+(.+)$")

    static func blocks(from markdown: String) -> [Block] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [Block] = []
        var codeFenceLanguage: String?
        var codeBuffer: [String] = []
        var inCodeFence = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeFence {
                    let text = codeBuffer.joined(separator: "\n")
                    blocks.append(.code(language: codeFenceLanguage, text: text))
                    codeFenceLanguage = nil
                    codeBuffer.removeAll(keepingCapacity: false)
                    inCodeFence = false
                } else {
                    let languageRaw = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeFenceLanguage = languageRaw.isEmpty ? nil : languageRaw
                    inCodeFence = true
                }
                continue
            }

            if inCodeFence {
                codeBuffer.append(line)
                continue
            }

            blocks.append(parseLine(line))
        }

        // Unterminated fence: still render buffered content as code.
        if inCodeFence {
            blocks.append(.code(language: codeFenceLanguage, text: codeBuffer.joined(separator: "\n")))
        }

        return blocks
    }

    static func visibleSlice(from markdown: String, pages: Int, pageCharacterCount: Int) -> String {
        let safePages = max(1, pages)
        let safePageSize = max(1, pageCharacterCount)
        let limit = safePages * safePageSize

        guard markdown.count > limit else { return markdown }
        let sliceEnd = markdown.index(markdown.startIndex, offsetBy: limit)
        let prefix = String(markdown[..<sliceEnd])

        // Cut at a nearby newline so incremental pages avoid splitting list tokens mid-line.
        let minReadableCut = max(0, min(prefix.count, limit - 300))
        let minReadableIndex = prefix.index(prefix.startIndex, offsetBy: minReadableCut)
        if let newline = prefix.lastIndex(of: "\n"), newline > minReadableIndex {
            return String(prefix[...newline])
        }

        return prefix
    }

    private static func parseLine(_ line: String) -> Block {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .blank }

        if let match = match(trimmed, regex: headingRegex),
           match.count > 2 {
            let hashes = match[1]
            let text = match[2]
            return .heading(level: hashes.count, text: text)
        }

        if let match = match(trimmed, regex: bulletRegex),
           match.count > 1 {
            let text = match[1]
            return .bullet(text: text)
        }

        if let match = match(trimmed, regex: numberedRegex),
           match.count > 2 {
            let number = match[1]
            let text = match[2]
            return .numbered(number: number, text: text)
        }

        return .plain(text: trimmed)
    }

    private static func match(_ text: String, regex: NSRegularExpression) -> [String]? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, range: range) else { return nil }
        var captures: [String] = []
        captures.reserveCapacity(result.numberOfRanges)
        for idx in 0..<result.numberOfRanges {
            let nsRange = result.range(at: idx)
            guard let captureRange = Range(nsRange, in: text) else {
                captures.append("")
                continue
            }
            captures.append(String(text[captureRange]))
        }
        return captures
    }
}

private struct InlineMarkdownTextView: View {
    let value: String
    @State private var rendered: AttributedString

    init(value: String) {
        self.value = value
        _rendered = State(initialValue: Self.parse(value))
    }

    var body: some View {
        Text(rendered)
            .onChange(of: value) { _, newValue in
                rendered = Self.parse(newValue)
            }
    }

    private static func parse(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}

// MARK: - Image Payload

/// Structured image data decoded from JSON payload.
/// Supports both single `url` (legacy) and `urls` array (fallback list).
struct ImagePayload: Codable {
    let url: String?
    let urls: [String]?
    let alt: String?

    /// All candidate URLs in priority order.
    var resolvedUrls: [String] {
        if let urls = urls, !urls.isEmpty { return urls }
        if let url = url { return [url] }
        return []
    }
}

// MARK: - Image Loader

/// Loads remote images with a proper User-Agent header.
/// Tries multiple candidate URLs in order, falling back on failure.
/// AsyncImage gets 403'd by sites like Wikimedia that block bare requests.
@MainActor
final class ImageLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var isLoading = false
    @Published var error: String?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "SamOS/1.0 (macOS; image-viewer)"]
        return URLSession(configuration: config)
    }()

    /// Tries each URL in order. Stops at the first successful load.
    func load(from urls: [URL]) {
        guard !isLoading, !urls.isEmpty else { return }
        isLoading = true
        error = nil

        Task {
            await tryUrls(urls, index: 0)
        }
    }

    /// Legacy single-URL convenience.
    func load(from url: URL) {
        load(from: [url])
    }

    private func tryUrls(_ urls: [URL], index: Int) async {
        guard index < urls.count else {
            self.error = "All image URLs failed to load"
            self.isLoading = false
            return
        }

        let url = urls[index]
        #if DEBUG
        print("[ImageLoader] Trying URL \(index + 1)/\(urls.count): \(url.absoluteString.prefix(100))")
        #endif

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, response) = try await Self.session.data(for: request)

            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                #if DEBUG
                print("[ImageLoader] URL \(index + 1) failed: HTTP \(code)")
                #endif
                await tryUrls(urls, index: index + 1)
                return
            }

            guard let nsImage = NSImage(data: data) else {
                #if DEBUG
                print("[ImageLoader] URL \(index + 1) failed: invalid image data")
                #endif
                await tryUrls(urls, index: index + 1)
                return
            }

            self.image = nsImage
            self.isLoading = false
        } catch {
            #if DEBUG
            print("[ImageLoader] URL \(index + 1) failed: \(error.localizedDescription)")
            #endif
            await tryUrls(urls, index: index + 1)
        }
    }
}

// MARK: - Image Rendering

struct ImageOutputView: View {
    let payload: String
    private let decodedPayload: ImagePayload?
    @StateObject private var loader = ImageLoader()
    @State private var didRequestLoad = false

    init(payload: String) {
        self.payload = payload
        self.decodedPayload = Self.decodePayload(from: payload)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let decoded = decodedPayload {
                let candidateUrls = decoded.resolvedUrls.compactMap { URL(string: $0) }
                if !candidateUrls.isEmpty {
                    if let nsImage = loader.image {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .cornerRadius(8)
                    } else if let error = loader.error {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.title)
                            Text("Failed to load image")
                                .font(.caption)
                            Text(error)
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                } else {
                    Text("No valid image URLs")
                        .foregroundColor(.secondary)
                }

                if let alt = decoded.alt, !alt.isEmpty {
                    Text(alt)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Invalid image payload")
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
        .onAppear {
            guard !didRequestLoad,
                  let decoded = decodedPayload else { return }
            let candidateUrls = decoded.resolvedUrls.compactMap { URL(string: $0) }
            guard !candidateUrls.isEmpty else { return }
            didRequestLoad = true
            loader.load(from: candidateUrls)
        }
    }

    func decodePayload() -> ImagePayload? {
        Self.decodePayload(from: payload)
    }

    private static func decodePayload(from payload: String) -> ImagePayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ImagePayload.self, from: data)
    }
}
