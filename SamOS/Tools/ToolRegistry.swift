import Foundation

// MARK: - Tool Protocol

protocol Tool {
    var name: String { get }
    var description: String { get }
    func execute(args: [String: String]) -> OutputItem
}

// MARK: - Tool Registry

final class ToolRegistry {
    static let shared = ToolRegistry()

    private var tools: [String: Tool] = [:]

    private init() {
        register(ShowTextTool())
        register(FindRecipeTool())
        register(FindImageTool())
        register(FindVideoTool())
        register(FindFilesTool())
        register(ShowImageTool())
        register(DescribeCameraViewTool())
        register(CameraObjectFinderTool())
        register(CameraFacePresenceTool())
        register(EnrollCameraFaceTool())
        register(RecognizeCameraFacesTool())
        register(CameraVisualQATool())
        register(CameraInventorySnapshotTool())
        register(SaveCameraMemoryNoteTool())
        register(CapabilityGapToClaudePromptTool())
        register(SaveMemoryTool())
        register(ListMemoriesTool())
        register(DeleteMemoryTool())
        register(ClearMemoriesTool())
        register(ScheduleTaskTool())
        register(CancelTaskTool())
        register(ListTasksTool())
        register(LearnWebsiteTool())
        register(AutonomousLearnTool())
        register(StopAutonomousLearnTool())
        register(GetWeatherTool())
        register(GetTimeTool())
        register(StartSkillForgeTool())
        register(ForgeQueueStatusTool())
        register(ForgeQueueClearTool())
    }

    func register(_ tool: Tool) {
        tools[tool.name] = tool
    }

    func get(_ name: String) -> Tool? {
        tools[name]
    }

    var allTools: [Tool] {
        Array(tools.values)
    }
}

// MARK: - Built-in Tools

struct ShowTextTool: Tool {
    let name = "show_text"
    let description = "Renders markdown text on the Output Canvas"

    func execute(args: [String: String]) -> OutputItem {
        // Accept common aliases from model-generated specs.
        let markdown = args["markdown"]
            ?? args["text"]
            ?? args["content"]
            ?? "_No content provided._"
        return OutputItem(kind: .markdown, payload: markdown)
    }
}

struct ShowImageTool: Tool {
    let name = "show_image"
    let description = "Displays a remote image on the Output Canvas. Accepts 'urls' (pipe-separated list) or 'url' (single). Provide multiple URLs for fallback."

    static let validImageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "svg"]

    func execute(args: [String: String]) -> OutputItem {
        let alt = args["alt"] ?? "Image"

        // Collect candidate URLs: prefer list variants, then single-url variants.
        var candidates: [String] = []
        let urlListKeys = ["urls", "imageUrls", "image_urls"]
        for key in urlListKeys {
            guard let urlsList = args[key], !urlsList.isEmpty else { continue }
            let parsed = urlsList
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for url in parsed where !candidates.contains(url) {
                candidates.append(url)
            }
        }

        let singleURLKeys = ["url", "imageUrl", "image_url"]
        for key in singleURLKeys {
            guard let singleUrl = args[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !singleUrl.isEmpty else { continue }
            if !candidates.contains(singleUrl) {
                candidates.insert(singleUrl, at: 0)
            }
        }

        // Filter to valid image URLs
        let validUrls = candidates.filter { validateImageURL($0) == nil }

        if validUrls.isEmpty {
            // Try to give a useful error from the first candidate
            let firstError = candidates.first.flatMap { validateImageURL($0) } ?? "No URL provided."
            return OutputItem(kind: .markdown, payload: "**Image Error:** \(firstError)")
        }

        // Encode payload with all valid URLs for fallback at load time
        let payloadDict: [String: Any] = ["urls": validUrls, "alt": alt]
        if let data = try? JSONSerialization.data(withJSONObject: payloadDict),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .image, payload: json)
        }

        return OutputItem(kind: .markdown, payload: "**Image Error:** Failed to encode image data.")
    }

    func validateImageURL(_ urlString: String) -> String? {
        guard !urlString.isEmpty else {
            return "No URL provided."
        }
        guard let url = URL(string: urlString) else {
            return "Invalid URL: \(urlString.prefix(100))"
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "URL must use http or https."
        }
        // Reject wiki page URLs (contain /wiki/ path)
        if url.path.contains("/wiki/") {
            return "URL is a wiki page, not a direct image. Use a URL ending in .jpg, .png, etc."
        }
        // Check for valid image extension in path
        let pathExtension = url.pathExtension.lowercased()
        if !pathExtension.isEmpty && !ShowImageTool.validImageExtensions.contains(pathExtension) {
            return "URL does not point to an image file (.\(pathExtension)). Expected .jpg, .png, .gif, or .webp."
        }
        return nil
    }
}

struct FindImageTool: Tool {
    let name = "find_image"
    let description = "Find relevant image URLs for a query using Google Images (imghp/search) and display them on the Output Canvas. Use when the user asks to find/show/search for an image. Args: 'query' (preferred); also accepts 'q', 'search', 'search_term', 'term', or 'topic'."

    private static let searchResultPatterns: [NSRegularExpression] = [
        // Common Google image result JSON fields.
        (try? NSRegularExpression(pattern: #""ou":"(https?://[^"]+)""#, options: [.caseInsensitive]))!,
        (try? NSRegularExpression(pattern: #""imgurl":"(https?://[^"]+)""#, options: [.caseInsensitive]))!,
        // Google thumbnail hosts often use query-only URLs without file extensions.
        (try? NSRegularExpression(pattern: #"https://encrypted-tbn0\.gstatic\.com/images\?[^"'\s<]+"#, options: [.caseInsensitive]))!,
        // Direct image links with common file extensions.
        (try? NSRegularExpression(pattern: #"https?://[^"'\s<]+\.(?:jpg|jpeg|png|gif|webp|avif)(?:\?[^"'\s<]*)?"#, options: [.caseInsensitive]))!
    ]

    func execute(args: [String: String]) -> OutputItem {
        let query = resolvedQuery(from: args)
        guard !query.isEmpty else {
            return cameraPromptPayload(
                slot: "query",
                spoken: "What image should I find?",
                formatted: "Provide an image query, for example `frog`, `golden retriever`, or `Sydney Opera House`."
            )
        }

        let tags = tokenizedQuery(query)
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let slug = tags.isEmpty ? "image" : tags.joined(separator: "-")
        var urls = fetchGoogleImageURLs(encodedQuery: encodedQuery)

        // No-key visual fallbacks only when Google extraction fails.
        if urls.isEmpty {
            urls = [
                "https://loremflickr.com/1600/900/\(slug)",
                "https://picsum.photos/seed/\(slug)/1600/900.jpg",
                "https://placehold.co/1600x900.jpg?text=\(encodedQuery)"
            ]
        }

        let payload: [String: Any] = [
            "urls": urls,
            "alt": query
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return OutputItem(kind: .markdown, payload: "**Image Error:** Failed to prepare image URLs.")
        }

        return OutputItem(kind: .image, payload: json)
    }

    private func resolvedQuery(from args: [String: String]) -> String {
        let candidates = [
            args["query"],
            args["q"],
            args["search"],
            args["search_term"],
            args["searchTerm"],
            args["term"],
            args["topic"],
            args["text"],
            args["input"]
        ]

        for value in candidates {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private func tokenizedQuery(_ query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(8)
            .map { String($0) }
    }

    private func fetchGoogleImageURLs(encodedQuery: String, maxCount: Int = 6) -> [String] {
        let searchURLs = [
            "https://images.google.com/search?tbm=isch&hl=en&q=\(encodedQuery)",
            "https://www.google.com/search?tbm=isch&hl=en&q=\(encodedQuery)"
        ]

        for searchURL in searchURLs {
            guard let url = URL(string: searchURL) else { continue }
            guard let html = requestSearchHTML(url: url) else { continue }
            let extracted = Self.extractGoogleImageURLs(fromHTML: html, limit: maxCount)
            if !extracted.isEmpty { return extracted }
        }

        return []
    }

    private func requestSearchHTML(url: URL) -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.google.com/imghp", forHTTPHeaderField: "Referer")

        let semaphore = DispatchSemaphore(value: 0)
        var html: String?

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data = data else { return }
            html = String(data: data, encoding: .utf8)
        }.resume()

        _ = semaphore.wait(timeout: .now() + 10)
        guard let html, !html.isEmpty else { return nil }
        return html
    }

    static func extractGoogleImageURLs(fromHTML html: String, limit: Int = 6) -> [String] {
        let decoded = html
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u0025", with: "%")

        var urls: [String] = []
        let source = decoded as NSString
        let fullRange = NSRange(location: 0, length: source.length)

        for regex in searchResultPatterns {
            let matches = regex.matches(in: decoded, options: [], range: fullRange)
            for match in matches {
                let candidateRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
                guard candidateRange.location != NSNotFound else { continue }
                let rawCandidate = source.substring(with: candidateRange)
                guard let cleaned = cleanedImageURL(rawCandidate) else { continue }
                if !urls.contains(cleaned) {
                    urls.append(cleaned)
                    if urls.count >= max(1, limit) { return urls }
                }
            }
        }

        return urls
    }

    private static func cleanedImageURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        // Skip HTML/search pages; keep direct images and known thumbnail hosts.
        if url.host?.contains("google.com") == true, url.path.contains("/search") {
            return nil
        }
        return trimmed
    }
}

private struct FileSearchMatch {
    let url: URL
    let modifiedAt: Date?
    let size: Int64?

    var ext: String {
        let value = url.pathExtension.lowercased()
        return value.isEmpty ? "unknown" : value
    }
}

struct FindFilesTool: Tool {
    let name = "find_files"
    let description = "Search files in Downloads/Documents with partial-name and document-type filters. Use for: 'find that I downloaded', 'what's in Downloads/Documents', 'find all PDFs', 'find Word document', or 'find document named bestreport'. Args: optional query/name/type/folder/limit."

    private let fileManager: FileManager
    private let directoryProvider: () -> [URL]

    init(
        fileManager: FileManager = .default,
        directoryProvider: @escaping () -> [URL] = FindFilesTool.defaultSearchDirectories
    ) {
        self.fileManager = fileManager
        self.directoryProvider = directoryProvider
    }

    func execute(args: [String: String]) -> OutputItem {
        let request = buildRequest(args: args)
        let roots = resolvedRoots(for: request.scope)

        guard !roots.isEmpty else {
            let formatted = """
            # File Search

            I couldn't locate Downloads/Documents directories for this user.
            """
            return structuredPayload(spoken: "I couldn't access Downloads or Documents.", formatted: formatted)
        }

        let matches = scanFiles(roots: roots, request: request)
        let formatted = buildMarkdown(matches: matches, request: request, roots: roots)
        let spoken = matches.isEmpty
            ? "I couldn't find a matching file in Downloads or Documents."
            : "I found \(matches.count) matching file\(matches.count == 1 ? "" : "s") in Downloads and Documents."
        return structuredPayload(spoken: spoken, formatted: formatted)
    }

    private func buildRequest(args: [String: String]) -> FileSearchRequest {
        let query = firstNonEmpty([
            args["query"], args["name"], args["filename"], args["term"], args["search"],
            args["q"], args["topic"], args["text"], args["input"]
        ])

        let folderHint = firstNonEmpty([args["folder"], args["scope"], args["directory"], args["path"], query])
        let scope = parseScope(from: folderHint)

        var extFilters = extensionsForType(firstNonEmpty([args["type"], args["kind"], args["extension"]]))
        extFilters.formUnion(extensionsFromQuery(query))

        let explicitName = firstNonEmpty([args["name"], args["filename"]])
        let partialName = (explicitName.isEmpty ? partialNameFromQuery(query) : explicitName).lowercased()

        let limitRaw = firstNonEmpty([args["limit"], args["max"], args["max_results"]])
        let limit = max(1, min(Int(limitRaw) ?? 30, 120))

        return FileSearchRequest(
            originalQuery: query,
            partialName: partialName,
            extensions: extFilters,
            scope: scope,
            limit: limit
        )
    }

    private func scanFiles(roots: [URL], request: FileSearchRequest) -> [FileSearchMatch] {
        var results: [FileSearchMatch] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]

        outer: for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else {
                    continue
                }

                if !request.extensions.isEmpty {
                    let ext = fileURL.pathExtension.lowercased()
                    if !request.extensions.contains(ext) { continue }
                }

                if !request.partialName.isEmpty {
                    let filename = fileURL.lastPathComponent.lowercased()
                    if !filename.contains(request.partialName) { continue }
                }

                let size = values.fileSize.map { Int64($0) }
                results.append(FileSearchMatch(url: fileURL, modifiedAt: values.contentModificationDate, size: size))
                if results.count >= request.limit { break outer }
            }
        }

        return results.sorted { lhs, rhs in
            (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
        }
    }

    private func buildMarkdown(matches: [FileSearchMatch], request: FileSearchRequest, roots: [URL]) -> String {
        var lines: [String] = [
            "# File Search",
            "",
            "- Scope: \(scopeLabel(for: request.scope, roots: roots))"
        ]

        if !request.originalQuery.isEmpty {
            lines.append("- Query: \(request.originalQuery)")
        }
        if !request.extensions.isEmpty {
            lines.append("- Type filter: \(request.extensions.sorted().joined(separator: ", "))")
        }
        if !request.partialName.isEmpty {
            lines.append("- Name match: `\(request.partialName)`")
        }

        lines.append("")
        if matches.isEmpty {
            lines.append("No matching files found.")
            lines.append("")
            lines.append("Try examples:")
            lines.append("- `find all pdfs`")
            lines.append("- `find a word document`")
            lines.append("- `find document named bestreport`")
            return lines.joined(separator: "\n")
        }

        lines.append("## Matches")
        for (index, match) in matches.enumerated() {
            let fileURL = match.url.absoluteString
            let path = match.url.path
            lines.append("\(index + 1). [\(match.url.lastPathComponent)](\(fileURL))")
            lines.append("   - Path: `\(path)`")
            var detailParts: [String] = ["Type: `\(match.ext)`"]
            if let size = match.size {
                detailParts.append("Size: \(FindFilesTool.byteCountFormatter.string(fromByteCount: size))")
            }
            if let modified = match.modifiedAt {
                detailParts.append("Modified: \(FindFilesTool.modifiedDateFormatter.string(from: modified))")
            }
            lines.append("   - " + detailParts.joined(separator: " · "))
        }

        return lines.joined(separator: "\n")
    }

    private func resolvedRoots(for scope: FileScope) -> [URL] {
        let base = directoryProvider()
        var downloads: URL?
        var documents: URL?
        for candidate in base {
            let lowerPath = candidate.path.lowercased()
            if lowerPath.hasSuffix("/downloads") {
                downloads = candidate
            } else if lowerPath.hasSuffix("/documents") {
                documents = candidate
            }
        }

        var roots: [URL] = []
        switch scope {
        case .downloads:
            if let downloads { roots.append(downloads) }
        case .documents:
            if let documents { roots.append(documents) }
        case .both:
            if let downloads { roots.append(downloads) }
            if let documents, !roots.contains(documents) { roots.append(documents) }
            if roots.isEmpty {
                roots = base
            }
        }
        return roots
    }

    private func parseScope(from hint: String) -> FileScope {
        let lowered = hint.lowercased()
        let mentionsDownloads = lowered.contains("download")
        let mentionsDocuments = lowered.contains("document")

        if mentionsDownloads && !mentionsDocuments { return .downloads }
        if mentionsDocuments && !mentionsDownloads { return .documents }
        return .both
    }

    private func extensionsForType(_ rawType: String) -> Set<String> {
        guard !rawType.isEmpty else { return [] }
        let lowered = rawType.lowercased()
        if lowered.hasPrefix(".") { return [String(lowered.dropFirst())] }
        if lowered.count <= 5 && !lowered.contains(" ") {
            return [lowered]
        }
        return mappedExtensions(for: lowered)
    }

    private func extensionsFromQuery(_ query: String) -> Set<String> {
        guard !query.isEmpty else { return [] }
        return mappedExtensions(for: query.lowercased())
    }

    private func mappedExtensions(for lowered: String) -> Set<String> {
        let mappings: [(terms: [String], exts: [String])] = [
            (["pdf", "pdfs"], ["pdf"]),
            (["word", "doc", "docx", "word document"], ["doc", "docx"]),
            (["excel", "spreadsheet", "xls", "xlsx"], ["xls", "xlsx", "csv"]),
            (["powerpoint", "ppt", "pptx", "slides"], ["ppt", "pptx"]),
            (["text", "txt", "md", "markdown"], ["txt", "md", "rtf"]),
            (["image", "photo", "picture", "png", "jpg", "jpeg"], ["png", "jpg", "jpeg", "heic", "webp", "gif"]),
            (["video", "movie", "clip"], ["mp4", "mov", "m4v", "mkv", "avi"]),
            (["audio", "music", "sound"], ["mp3", "m4a", "wav", "aac", "flac"]),
            (["zip", "archive", "compressed"], ["zip", "rar", "7z", "tar", "gz"])
        ]

        var result: Set<String> = []
        for mapping in mappings where mapping.terms.contains(where: { lowered.contains($0) }) {
            result.formUnion(mapping.exts)
        }
        return result
    }

    private func partialNameFromQuery(_ query: String) -> String {
        let lowered = query.lowercased()
        let markerPatterns = [
            #"named\s+([a-z0-9._-]+)"#,
            #"called\s+([a-z0-9._-]+)"#,
            #"document\s+([a-z0-9._-]+)"#
        ]
        for pattern in markerPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: lowered) else {
                continue
            }
            let value = String(lowered[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }

        let stopwords: Set<String> = [
            "find", "search", "look", "for", "file", "files", "document", "documents", "folder", "in", "my",
            "downloads", "download", "docs", "all", "a", "an", "the", "named", "called", "show", "me",
            "word", "pdf", "pdfs", "doc", "docx", "text", "type", "of", "and", "from", "with"
        ]

        let tokens = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopwords.contains($0) }

        return tokens.joined(separator: " ")
    }

    private func scopeLabel(for scope: FileScope, roots: [URL]) -> String {
        switch scope {
        case .downloads:
            return roots.first?.path ?? "Downloads"
        case .documents:
            return roots.first?.path ?? "Documents"
        case .both:
            if roots.isEmpty { return "Downloads + Documents" }
            return roots.map(\.path).joined(separator: " | ")
        }
    }

    private func firstNonEmpty(_ values: [String?]) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private func structuredPayload(spoken: String, formatted: String) -> OutputItem {
        let payload: [String: String] = [
            "kind": "file_search",
            "spoken": spoken,
            "formatted": String(formatted.prefix(2_400))
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: formatted)
    }

    static func defaultSearchDirectories() -> [URL] {
        let fileManager = FileManager.default
        let preferredHome = preferredHomeDirectory(for: fileManager.homeDirectoryForCurrentUser)

        var dirs: [URL] = []
        let preferredDownloads = preferredHome.appendingPathComponent("Downloads", isDirectory: true)
        let preferredDocuments = preferredHome.appendingPathComponent("Documents", isDirectory: true)

        if fileManager.fileExists(atPath: preferredDownloads.path) {
            dirs.append(preferredDownloads.standardizedFileURL)
        }
        if fileManager.fileExists(atPath: preferredDocuments.path),
           !dirs.contains(preferredDocuments.standardizedFileURL) {
            dirs.append(preferredDocuments.standardizedFileURL)
        }

        // Fallback for environments where preferred home directories are unavailable.
        if dirs.isEmpty, let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            dirs.append(downloads.standardizedFileURL)
        }
        if dirs.isEmpty, let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
           !dirs.contains(documents.standardizedFileURL) {
            dirs.append(documents.standardizedFileURL)
        }

        return dirs
    }

    static func preferredHomeDirectory(for homeDirectory: URL) -> URL {
        let marker = "/Library/Containers/com.samos.SamOS/Data"
        let path = homeDirectory.path
        guard let range = path.range(of: marker) else {
            return homeDirectory.standardizedFileURL
        }

        let rootPath = String(path[..<range.lowerBound])
        guard !rootPath.isEmpty else {
            return homeDirectory.standardizedFileURL
        }

        return URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let modifiedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct FileSearchRequest {
    let originalQuery: String
    let partialName: String
    let extensions: Set<String>
    let scope: FileScope
    let limit: Int
}

private enum FileScope {
    case downloads
    case documents
    case both
}

private struct VideoSearchResult {
    let videoID: String
    let title: String
    let channel: String
    let publishedAt: String
    let thumbnailURL: String?

    var watchURL: String {
        "https://www.youtube.com/watch?v=\(videoID)"
    }
}

private final class VideoHistoryStore {
    static let shared = VideoHistoryStore()

    private let queue = DispatchQueue(label: "com.samos.video-history")
    private let maxTopics = 200
    private let maxIDsPerTopic = 100
    private var topicToVideoIDs: [String: [String]] = [:]
    private let fileURL: URL?

    private init() {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = appSupport
                .appendingPathComponent("SamOS", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fileURL = dir.appendingPathComponent("video_history.json", isDirectory: false)
            loadFromDisk()
        } catch {
            fileURL = nil
        }
    }

    func seenVideoIDs(for topic: String) -> Set<String> {
        let normalized = normalizeTopic(topic)
        return queue.sync {
            Set(topicToVideoIDs[normalized] ?? [])
        }
    }

    func markSeen(videoID: String, topic: String) {
        guard !videoID.isEmpty else { return }
        let normalized = normalizeTopic(topic)
        queue.sync {
            var ids = topicToVideoIDs[normalized] ?? []
            if !ids.contains(videoID) {
                ids.append(videoID)
            }
            if ids.count > maxIDsPerTopic {
                ids.removeFirst(ids.count - maxIDsPerTopic)
            }
            topicToVideoIDs[normalized] = ids
            pruneTopicsIfNeeded()
            persistToDisk()
        }
    }

    func reset(topic: String) {
        let normalized = normalizeTopic(topic)
        queue.sync {
            topicToVideoIDs.removeValue(forKey: normalized)
            persistToDisk()
        }
    }

    private func normalizeTopic(_ topic: String) -> String {
        topic.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func pruneTopicsIfNeeded() {
        guard topicToVideoIDs.count > maxTopics else { return }
        let overflow = topicToVideoIDs.count - maxTopics
        let keysToDrop = topicToVideoIDs.keys.sorted().prefix(overflow)
        for key in keysToDrop {
            topicToVideoIDs.removeValue(forKey: key)
        }
    }

    private func loadFromDisk() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return
        }
        topicToVideoIDs = decoded
    }

    private func persistToDisk() {
        guard let fileURL,
              let data = try? JSONEncoder().encode(topicToVideoIDs) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct FindVideoTool: Tool {
    let name = "find_video"
    let description = "Find a YouTube video for a topic and show one result in Output Canvas with title/channel/date/videoId/clickable URL. Prevents repeats per topic automatically, so asking for 'another' returns a different video when available. Args: 'query' (required); also accepts 'topic', 'q', 'search'. Optional 'reset'='true' clears shown-video history for that topic."

    private static let videoIDRegex = try! NSRegularExpression(
        pattern: #""videoId":"([A-Za-z0-9_-]{11})""#,
        options: []
    )

    private static let videoRendererRegex = try! NSRegularExpression(
        pattern: #""videoRenderer":\{"videoId":"([A-Za-z0-9_-]{11})".*?"title":\{"runs":\[\{"text":"([^"]+)""#,
        options: [.dotMatchesLineSeparators]
    )

    func execute(args: [String: String]) -> OutputItem {
        let query = resolvedQuery(from: args)
        guard !query.isEmpty else {
            return cameraPromptPayload(
                slot: "query",
                spoken: "What video topic should I search for?",
                formatted: "Provide a video query, for example `race car`, `fishing`, or `home brewing`."
            )
        }

        let topicKey = normalizedTopic(query)
        if isResetRequested(args["reset"]) {
            VideoHistoryStore.shared.reset(topic: topicKey)
        }

        let candidates = searchVideos(query: query, maxCount: 12)
        guard !candidates.isEmpty else {
            let formatted = """
            # Video Search

            I couldn't fetch video results for **\(query)** right now.

            - If you want official YouTube Data API results, set **YouTube Data API Key** in `Settings > AI Learning > OpenAI`.
            - You can also try a slightly different query.
            """
            return structuredPayload(
                spoken: "I couldn't fetch video results right now.",
                formatted: formatted
            )
        }

        let seen = VideoHistoryStore.shared.seenVideoIDs(for: topicKey)
        guard let selected = pickNextVideo(from: candidates, seenIDs: seen) else {
            let formatted = """
            # Video Search

            I already showed the current result set for **\(query)**.

            - Ask for a different topic, or ask me to reset this topic's video history.
            """
            return structuredPayload(
                spoken: "I've already shown the current results for that topic.",
                formatted: formatted
            )
        }

        VideoHistoryStore.shared.markSeen(videoID: selected.videoID, topic: topicKey)

        let markdown = buildVideoMarkdown(query: query, selected: selected)
        return structuredPayload(
            spoken: "I found a video for \(query).",
            formatted: markdown
        )
    }

    private func resolvedQuery(from args: [String: String]) -> String {
        let candidates = [
            args["query"],
            args["topic"],
            args["q"],
            args["search"],
            args["search_term"],
            args["searchTerm"],
            args["text"],
            args["input"]
        ]

        for value in candidates {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private func isResetRequested(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return value == "1" || value == "true" || value == "yes" || value == "reset"
    }

    private func normalizedTopic(_ topic: String) -> String {
        topic.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func searchVideos(query: String, maxCount: Int) -> [VideoSearchResult] {
        let apiKey = OpenAISettings.youtubeAPIKey
        if !apiKey.isEmpty {
            let viaAPI = searchWithYouTubeAPI(query: query, apiKey: apiKey, maxCount: maxCount)
            if !viaAPI.isEmpty { return viaAPI }
        }
        return searchWithYouTubeHTML(query: query, maxCount: maxCount)
    }

    private func searchWithYouTubeAPI(query: String, apiKey: String, maxCount: Int) -> [VideoSearchResult] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let endpoint = "https://www.googleapis.com/youtube/v3/search?part=snippet&type=video&maxResults=\(max(1, min(maxCount, 25)))&q=\(encodedQuery)&key=\(apiKey)"
        guard let url = URL(string: endpoint), let data = fetchData(url: url) else { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            return []
        }

        var results: [VideoSearchResult] = []
        for item in items {
            guard let id = item["id"] as? [String: Any],
                  let videoID = id["videoId"] as? String,
                  !videoID.isEmpty,
                  let snippet = item["snippet"] as? [String: Any] else {
                continue
            }
            let title = cleanText(snippet["title"] as? String) ?? "YouTube video"
            let channel = cleanText(snippet["channelTitle"] as? String) ?? "Unknown channel"
            let publishedAt = cleanText(snippet["publishedAt"] as? String) ?? "Unknown"

            var thumbnailURL: String?
            if let thumbnails = snippet["thumbnails"] as? [String: Any] {
                if let high = thumbnails["high"] as? [String: Any], let url = high["url"] as? String {
                    thumbnailURL = url
                } else if let medium = thumbnails["medium"] as? [String: Any], let url = medium["url"] as? String {
                    thumbnailURL = url
                } else if let `default` = thumbnails["default"] as? [String: Any], let url = `default`["url"] as? String {
                    thumbnailURL = url
                }
            }

            results.append(
                VideoSearchResult(
                    videoID: videoID,
                    title: title,
                    channel: channel,
                    publishedAt: publishedAt,
                    thumbnailURL: thumbnailURL
                )
            )
            if results.count >= maxCount { break }
        }
        return dedup(results)
    }

    private func searchWithYouTubeHTML(query: String, maxCount: Int) -> [VideoSearchResult] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://www.youtube.com/results?search_query=\(encodedQuery)&sp=EgIQAQ%253D%253D"),
              let html = fetchHTML(url: url) else {
            return []
        }

        let decoded = html.replacingOccurrences(of: "\\u0026", with: "&")
        let nsDecoded = decoded as NSString
        let fullRange = NSRange(location: 0, length: nsDecoded.length)
        var results: [VideoSearchResult] = []

        let renderedMatches = Self.videoRendererRegex.matches(in: decoded, options: [], range: fullRange)
        for match in renderedMatches {
            guard match.numberOfRanges > 2,
                  let idRange = Range(match.range(at: 1), in: decoded),
                  let titleRange = Range(match.range(at: 2), in: decoded) else {
                continue
            }
            let videoID = String(decoded[idRange])
            let title = decodeYouTubeText(String(decoded[titleRange])) ?? "YouTube video"
            results.append(
                VideoSearchResult(
                    videoID: videoID,
                    title: title,
                    channel: "YouTube",
                    publishedAt: "Unknown",
                    thumbnailURL: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
                )
            )
            if results.count >= maxCount { break }
        }

        if results.isEmpty {
            let idMatches = Self.videoIDRegex.matches(in: decoded, options: [], range: fullRange)
            for match in idMatches {
                guard match.numberOfRanges > 1,
                      let idRange = Range(match.range(at: 1), in: decoded) else {
                    continue
                }
                let videoID = String(decoded[idRange])
                results.append(
                    VideoSearchResult(
                        videoID: videoID,
                        title: "YouTube result for \(query)",
                        channel: "YouTube",
                        publishedAt: "Unknown",
                        thumbnailURL: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
                    )
                )
                if results.count >= maxCount { break }
            }
        }

        return dedup(results)
    }

    private func pickNextVideo(from candidates: [VideoSearchResult], seenIDs: Set<String>) -> VideoSearchResult? {
        if let unseen = candidates.first(where: { !seenIDs.contains($0.videoID) }) {
            return unseen
        }
        return nil
    }

    private func buildVideoMarkdown(query: String, selected: VideoSearchResult) -> String {
        var lines: [String] = [
            "# Video Result",
            "",
            "- Query: \(escapeMarkdown(query))",
            "- Title: [\(escapeMarkdown(selected.title))](\(selected.watchURL))",
            "- Channel: \(escapeMarkdown(selected.channel))",
            "- Published: \(escapeMarkdown(selected.publishedAt))",
            "- Video ID: `\(selected.videoID)`",
            "- Watch: [\(selected.watchURL)](\(selected.watchURL))"
        ]

        if let thumbnailURL = selected.thumbnailURL, !thumbnailURL.isEmpty {
            lines.append("- Thumbnail: [\(thumbnailURL)](\(thumbnailURL))")
        }
        return lines.joined(separator: "\n")
    }

    private func escapeMarkdown(_ raw: String) -> String {
        raw.replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private func structuredPayload(spoken: String, formatted: String) -> OutputItem {
        let payload: [String: Any] = [
            "kind": "video",
            "spoken": spoken,
            "formatted": String(formatted.prefix(1_180))
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: formatted)
    }

    private func cleanText(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text
    }

    private func decodeYouTubeText(_ text: String) -> String? {
        let decoded = text
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u003c", with: "<")
            .replacingOccurrences(of: "\\u003e", with: ">")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    private func dedup(_ results: [VideoSearchResult]) -> [VideoSearchResult] {
        var seen: Set<String> = []
        var deduped: [VideoSearchResult] = []
        for result in results where seen.insert(result.videoID).inserted {
            deduped.append(result)
        }
        return deduped
    }

    private func fetchHTML(url: URL) -> String? {
        guard let data = fetchData(url: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func fetchData(url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let semaphore = DispatchSemaphore(value: 0)
        var bodyData: Data?

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data = data else {
                return
            }
            bodyData = data
        }.resume()

        _ = semaphore.wait(timeout: .now() + 10)
        return bodyData
    }
}

struct FindRecipeTool: Tool {
    let name = "find_recipe"
    let description = "Find a recipe by dish/topic and return concise ingredients + steps in markdown. Use for recipe/how-to-cook/ingredients requests. Args: 'query' (preferred), also accepts 'dish', 'recipe', 'topic', or 'q'."

    private static let searchURLTemplates: [String] = [
        "https://www.taste.com.au/search-recipes/?q=%@",
        "https://duckduckgo.com/html/?q=%@",
        "https://www.bbcgoodfood.com/search?q=%@",
        "https://www.simplyrecipes.com/search?q=%@",
        "https://www.recipetineats.com/?s=%@"
    ]
    private static let mealDBSearchTemplate = "https://www.themealdb.com/api/json/v1/1/search.php?s=%@"
    private static let allowedRecipeHosts: Set<String> = [
        "taste.com.au",
        "bbcgoodfood.com",
        "simplyrecipes.com",
        "recipetineats.com",
        "allrecipes.com",
        "seriouseats.com",
        "delish.com",
        "epicurious.com",
        "foodnetwork.com",
        "bonappetit.com",
        "cookieandkate.com",
        "sbs.com.au",
        "nytimes.com"
    ]
    private static let recipeHostHints: [String] = [
        "allrecipes.", "foodnetwork.", "bbcgoodfood.", "seriouseats.", "taste.", "delish.",
        "epicurious.", "simplyrecipes.", "recipetineats.", "bonappetit.", "cookieandkate.",
        "sbs.com.au/food", "nytimes.com"
    ]
    private static let shownStoreQueue = DispatchQueue(label: "com.samos.findrecipe.shown")
    private static var shownURLsByQuery: [String: [String]] = [:]
    private static let searchLinkRegex = try! NSRegularExpression(
        pattern: #"href="([^"]+)""#,
        options: [.caseInsensitive]
    )
    private static let titleRegex = try! NSRegularExpression(
        pattern: #"(?is)<title[^>]*>(.*?)</title>"#,
        options: []
    )
    private static let scriptRegex = try! NSRegularExpression(
        pattern: #"(?is)<script[^>]*>.*?</script>"#,
        options: []
    )
    private static let styleRegex = try! NSRegularExpression(
        pattern: #"(?is)<style[^>]*>.*?</style>"#,
        options: []
    )
    private static let noscriptRegex = try! NSRegularExpression(
        pattern: #"(?is)<noscript[^>]*>.*?</noscript>"#,
        options: []
    )
    private static let commentsRegex = try! NSRegularExpression(
        pattern: #"(?is)<!--.*?-->"#,
        options: []
    )
    private static let tagsRegex = try! NSRegularExpression(
        pattern: #"(?is)<[^>]+>"#,
        options: []
    )
    private static let whitespaceRegex = try! NSRegularExpression(
        pattern: #"[ \t]+"#,
        options: []
    )
    private static let multiNewlineRegex = try! NSRegularExpression(
        pattern: #"\n{3,}"#,
        options: []
    )
    private static let ingredientUnitRegex = try! NSRegularExpression(
        pattern: #"\b(cup|cups|tbsp|tablespoon|tablespoons|tsp|teaspoon|teaspoons|g|kg|ml|l|oz|lb|pound|pounds|clove|cloves|pinch)\b"#,
        options: [.caseInsensitive]
    )

    func execute(args: [String: String]) -> OutputItem {
        let rawQuery = resolvedQuery(from: args)
        let intent = parseQueryIntent(from: rawQuery)

        guard !intent.canonicalQuery.isEmpty else {
            return recipePromptPayload(
                slot: "query",
                spoken: "What recipe should I find?",
                formatted: "Provide a recipe query, for example `caramel sauce`, `banana muffins`, or `butter chicken`."
            )
        }

        if intent.resetHistoryRequested {
            clearShownHistory(for: intent.cacheKey)
        }

        let searchQuery = intent.canonicalQuery.lowercased().contains("recipe")
            ? intent.canonicalQuery
            : "\(intent.canonicalQuery) recipe"
        let encodedQuery = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery
        let baseCandidates = searchRecipeURLs(
            encodedQuery: encodedQuery,
            domainAllowlist: Self.allowedRecipeHosts
        )
        var candidates = baseCandidates

        if candidates.count < 3 {
            let suggestion = fetchOpenAIRecipeSearchHints(query: intent.canonicalQuery)
            if let suggestion {
                let allowedSuggestionDomains = sanitizeSuggestedDomains(suggestion.domains)
                let allowedDomainSet = Set(allowedSuggestionDomains)
                let variants = [intent.canonicalQuery] + suggestion.queryVariants
                for variant in variants.prefix(5) {
                    let normalizedVariant = variant.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalizedVariant.isEmpty else { continue }
                    let variantSearch = normalizedVariant.lowercased().contains("recipe")
                        ? normalizedVariant
                        : "\(normalizedVariant) recipe"
                    let variantEncoded = variantSearch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? variantSearch
                    let fromVariant = searchRecipeURLs(
                        encodedQuery: variantEncoded,
                        domainAllowlist: allowedDomainSet.isEmpty ? Self.allowedRecipeHosts : allowedDomainSet
                    )
                    candidates = mergeUniqueURLs(candidates, fromVariant)
                    if candidates.count >= 12 { break }
                }
            }
        }

        let allMatches = recipeMatches(query: intent.canonicalQuery, urls: candidates)

        if let selected = selectRecipeMatch(from: allMatches, intent: intent) {
            markRecipeShown(url: selected.url, cacheKey: intent.cacheKey)
            let alternatives = allMatches
                .filter { $0.url != selected.url }
                .filter { !shownURLs(for: intent.cacheKey).contains($0.url.absoluteString) }
                .prefix(3)
            let formatted = buildRecipeMarkdown(
                query: intent.canonicalQuery,
                sourceTitle: selected.title,
                sourceURL: selected.url,
                ingredients: selected.ingredients,
                steps: selected.steps,
                alternatives: Array(alternatives)
            )
            let spoken = "I found several \(intent.canonicalQuery) recipes and put one up here."
            return structuredMarkdownPayload(kind: "recipe", spoken: spoken, formatted: formatted)
        }

        if intent.requestAnother, !allMatches.isEmpty {
            let shownCount = shownURLs(for: intent.cacheKey).count
            let noMore = """
            # Recipe Search

            I found recipes for **\(intent.canonicalQuery)**, but you've already seen all the options I could fetch right now.

            - Shown so far: \(shownCount)
            - Ask: `reset recipe history for \(intent.canonicalQuery)` to start over.
            """
            return structuredMarkdownPayload(
                kind: "recipe",
                spoken: "I ran out of new recipe options for that one.",
                formatted: noMore
            )
        }

        if let mealDBFallback = fetchMealDBRecipeMatch(query: intent.canonicalQuery) {
            markRecipeShown(url: mealDBFallback.url, cacheKey: intent.cacheKey)
            let formatted = buildRecipeMarkdown(
                query: intent.canonicalQuery,
                sourceTitle: mealDBFallback.title,
                sourceURL: mealDBFallback.url,
                ingredients: mealDBFallback.ingredients,
                steps: mealDBFallback.steps,
                alternatives: []
            )
            return structuredMarkdownPayload(
                kind: "recipe",
                spoken: "I found a \(intent.canonicalQuery) recipe for you.",
                formatted: formatted
            )
        }

        if let generated = fetchOpenAIGeneratedRecipe(query: intent.canonicalQuery) {
            let formatted = buildGeneratedRecipeMarkdown(query: intent.canonicalQuery, generated: generated)
            return structuredMarkdownPayload(
                kind: "recipe",
                spoken: "I put together a practical \(intent.canonicalQuery) recipe for you.",
                formatted: formatted
            )
        }

        let fallback = """
        # Recipe Search

        I couldn't fetch a reliable recipe page for **\(intent.canonicalQuery)** right now.

        Try again with a more specific dish name, provide a direct recipe URL, or ask again in a moment.
        """
        return structuredMarkdownPayload(
            kind: "recipe",
            spoken: "I couldn't fetch a reliable recipe page just now.",
            formatted: fallback
        )
    }

    private func resolvedQuery(from args: [String: String]) -> String {
        let candidates = [
            args["query"], args["dish"], args["recipe"], args["topic"], args["q"], args["text"], args["input"]
        ]
        for value in candidates {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private struct ParsedRecipeIntent {
        let canonicalQuery: String
        let cacheKey: String
        let requestAnother: Bool
        let resetHistoryRequested: Bool
    }

    private struct RecipeMatch {
        let url: URL
        let title: String
        let ingredients: [String]
        let steps: [String]
        let score: Int
    }

    private struct OpenAIRecipeHints {
        let domains: [String]
        let queryVariants: [String]
    }

    struct OpenAIGeneratedRecipe {
        let title: String
        let ingredients: [String]
        let steps: [String]
        let note: String?
    }

    private func parseQueryIntent(from rawQuery: String) -> ParsedRecipeIntent {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let requestAnother = lower.contains("another") || lower.contains("different") || lower.contains("next")
        let resetRequested = lower.contains("reset") && lower.contains("history")

        var canonical = trimmed
        let cleanupPatterns = [
            #"(?i)\b(show|find|get)\s+(me\s+)?(another|next|different)\s+recipe\s+(for\s+)?"#,
            #"(?i)\banother\s+recipe\s+(for\s+)?"#,
            #"(?i)\brecipe\s+for\s+"#,
            #"(?i)\bhow\s+to\s+make\s+"#
        ]
        for pattern in cleanupPatterns {
            canonical = canonical.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        canonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        if canonical.isEmpty {
            canonical = trimmed
        }

        let cacheKey = canonical.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedRecipeIntent(
            canonicalQuery: canonical,
            cacheKey: cacheKey,
            requestAnother: requestAnother,
            resetHistoryRequested: resetRequested
        )
    }

    private func searchRecipeURLs(encodedQuery: String, domainAllowlist: Set<String>, limit: Int = 12) -> [URL] {
        var urls: [URL] = []

        for template in Self.searchURLTemplates {
            guard let searchURL = URL(string: String(format: template, encodedQuery)),
                  let html = fetchHTML(url: searchURL) else { continue }

            let source = html as NSString
            let range = NSRange(location: 0, length: source.length)
            let matches = Self.searchLinkRegex.matches(in: html, options: [], range: range)

            for match in matches {
                guard let hrefRange = Range(match.range(at: 1), in: html) else { continue }
                let href = String(html[hrefRange])
                guard let url = normalizeSearchHref(href, baseURL: searchURL) else { continue }
                let host = url.host?.lowercased() ?? ""

                guard !host.contains("duckduckgo.com"),
                      !host.contains("google."),
                      !host.contains("bing."),
                      !host.contains("yahoo."),
                      !host.contains("pinterest."),
                      !host.contains("facebook."),
                      !host.contains("instagram.") else { continue }

                guard isAllowedRecipeHost(host, allowlist: domainAllowlist) else { continue }
                guard looksRecipeLike(url: url) else { continue }
                if urls.contains(url) { continue }
                urls.append(url)
                if urls.count >= max(1, limit * 2) { break }
            }

            if urls.count >= max(1, limit * 2) { break }
        }

        let preferred = urls.sorted { lhs, rhs in
            let l = preferredHostScore(lhs.host?.lowercased() ?? "")
            let r = preferredHostScore(rhs.host?.lowercased() ?? "")
            if l != r { return l > r }
            return lhs.absoluteString.count < rhs.absoluteString.count
        }
        return Array(preferred.prefix(max(1, limit)))
    }

    private func isAllowedRecipeHost(_ host: String, allowlist: Set<String>) -> Bool {
        allowlist.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    }

    private func mergeUniqueURLs(_ base: [URL], _ extra: [URL]) -> [URL] {
        var merged = base
        for url in extra where !merged.contains(url) {
            merged.append(url)
        }
        return merged
    }

    private func preferredHostScore(_ host: String) -> Int {
        for (idx, hint) in Self.recipeHostHints.enumerated() where host.contains(hint) {
            return (Self.recipeHostHints.count - idx) * 10
        }
        return 0
    }

    func normalizeSearchHref(_ href: String, baseURL: URL? = nil) -> URL? {
        let decoded = href
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lower = decoded.lowercased()
        if decoded.hasPrefix("/l/?")
            || lower.contains("duckduckgo.com/l/?") {
            let redirectURLString: String
            if decoded.hasPrefix("http://") || decoded.hasPrefix("https://") {
                redirectURLString = decoded
            } else if decoded.hasPrefix("//") {
                redirectURLString = "https:\(decoded)"
            } else if decoded.hasPrefix("/") {
                redirectURLString = "https://duckduckgo.com\(decoded)"
            } else {
                redirectURLString = "https://duckduckgo.com/\(decoded)"
            }

            if let comps = URLComponents(string: redirectURLString),
               let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value,
               let resolved = URL(string: uddg) {
                return resolved
            }
        }

        if decoded.hasPrefix("http://") || decoded.hasPrefix("https://") {
            return URL(string: decoded)
        }
        if decoded.hasPrefix("//") {
            return URL(string: "https:\(decoded)")
        }
        if decoded.hasPrefix("/") {
            return URL(string: decoded, relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    private func looksRecipeLike(url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()

        let recipePathTokens = [
            "/recipe", "/recipes", "/how-to", "/food/recipe", "/cooking/recipe",
            "/blog/", "/dish/", "/meal/"
        ]

        if recipePathTokens.contains(where: { path.contains($0) }) {
            return true
        }

        return Self.recipeHostHints.contains(where: { host.contains($0) })
    }

    private func recipeMatches(query: String, urls: [URL], maxMatches: Int = 8) -> [RecipeMatch] {
        var matches: [RecipeMatch] = []
        for url in urls.prefix(12) {
            guard let html = fetchHTML(url: url) else { continue }
            let title = extractTitle(fromHTML: html) ?? (url.host ?? "Recipe")
            let text = extractVisibleText(fromHTML: html)
            let lines = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 && $0.count <= 180 }

            let ingredients = extractIngredients(from: lines)
            let steps = extractSteps(from: lines)
            if !ingredients.isEmpty && !steps.isEmpty {
                let hostScore = preferredHostScore(url.host?.lowercased() ?? "")
                let richness = min(ingredients.count, 12) * 2 + min(steps.count, 10) * 3
                matches.append(RecipeMatch(url: url, title: title, ingredients: ingredients, steps: steps, score: hostScore + richness))
                if matches.count >= maxMatches { break }
            }
        }
        return matches.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.url.absoluteString.count < rhs.url.absoluteString.count
        }
    }

    private func selectRecipeMatch(from matches: [RecipeMatch], intent: ParsedRecipeIntent) -> RecipeMatch? {
        guard !matches.isEmpty else { return nil }
        let shown = Set(shownURLs(for: intent.cacheKey))
        if intent.requestAnother, let nextUnseen = matches.first(where: { !shown.contains($0.url.absoluteString) }) {
            return nextUnseen
        }
        if let unseen = matches.first(where: { !shown.contains($0.url.absoluteString) }) {
            return unseen
        }
        return matches.first
    }

    private func shownURLs(for cacheKey: String) -> [String] {
        Self.shownStoreQueue.sync {
            Self.shownURLsByQuery[cacheKey] ?? []
        }
    }

    private func markRecipeShown(url: URL, cacheKey: String) {
        Self.shownStoreQueue.sync {
            var urls = Self.shownURLsByQuery[cacheKey] ?? []
            let absolute = url.absoluteString
            if !urls.contains(absolute) {
                urls.append(absolute)
            }
            if urls.count > 30 {
                urls = Array(urls.suffix(30))
            }
            Self.shownURLsByQuery[cacheKey] = urls
        }
    }

    private func clearShownHistory(for cacheKey: String) {
        Self.shownStoreQueue.sync {
            Self.shownURLsByQuery[cacheKey] = nil
        }
    }

    private func sanitizeSuggestedDomains(_ rawDomains: [String]) -> [String] {
        var domains: [String] = []
        for domain in rawDomains.prefix(12) {
            let trimmed = domain
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"/.*$"#, with: "", options: .regularExpression)
            guard !trimmed.isEmpty else { continue }
            if isAllowedRecipeHost(trimmed, allowlist: Self.allowedRecipeHosts), !domains.contains(trimmed) {
                domains.append(trimmed)
            }
        }
        return domains
    }

    private func fetchMealDBRecipeMatch(query: String) -> RecipeMatch? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: String(format: Self.mealDBSearchTemplate, encoded)),
              let data = fetchData(url: url, timeout: 8) else {
            return nil
        }

        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = envelope["meals"] as? [[String: Any]],
              !meals.isEmpty else {
            return nil
        }

        let queryTokens = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
        let rankedMeals = meals.sorted { lhs, rhs in
            let lTitle = (lhs["strMeal"] as? String ?? "").lowercased()
            let rTitle = (rhs["strMeal"] as? String ?? "").lowercased()
            let lScore = queryTokens.reduce(0) { partial, token in
                partial + (lTitle.contains(token) ? 1 : 0)
            }
            let rScore = queryTokens.reduce(0) { partial, token in
                partial + (rTitle.contains(token) ? 1 : 0)
            }
            if lScore != rScore { return lScore > rScore }
            return lTitle.count < rTitle.count
        }

        for meal in rankedMeals.prefix(3) {
            if let parsed = mealDBRecipeMatch(from: meal) {
                return parsed
            }
        }
        return nil
    }

    private func mealDBRecipeMatch(from meal: [String: Any]) -> RecipeMatch? {
        guard let parsed = parseMealDBRecipePreview(from: meal) else { return nil }
        return RecipeMatch(
            url: parsed.sourceURL,
            title: parsed.title,
            ingredients: parsed.ingredients,
            steps: parsed.steps,
            score: 180
        )
    }

    func parseMealDBRecipePreview(from meal: [String: Any]) -> (title: String, sourceURL: URL, ingredients: [String], steps: [String])? {
        let title = (meal["strMeal"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        var ingredients: [String] = []
        for index in 1...20 {
            let ingredientKey = "strIngredient\(index)"
            let measureKey = "strMeasure\(index)"
            let ingredient = (meal[ingredientKey] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if ingredient.isEmpty { continue }
            let measure = (meal[measureKey] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let combined = measure.isEmpty ? ingredient : "\(measure) \(ingredient)"
            ingredients.append(combined.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
        }

        let instructions = (meal["strInstructions"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = splitInstructionSteps(instructions)
        guard !ingredients.isEmpty, !steps.isEmpty else { return nil }

        let sourceCandidate = (meal["strSource"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let idMeal = (meal["idMeal"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceURL = URL(string: sourceCandidate).flatMap { url in
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url
            }
            return nil
        } ?? URL(string: "https://www.themealdb.com/meal/\(idMeal)")

        guard let sourceURL else { return nil }
        return (
            title: title,
            sourceURL: sourceURL,
            ingredients: Array(ingredients.prefix(12)),
            steps: Array(steps.prefix(10))
        )
    }

    func splitInstructionSteps(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lineSteps = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 10 }
            .map { normalizeStepLine($0) }
            .filter { !$0.isEmpty }
        if lineSteps.count >= 3 {
            return Array(lineSteps.prefix(10))
        }

        let sentenceSeparated = trimmed
            .replacingOccurrences(of: #"\r\n?"#, with: "\n", options: .regularExpression)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 12 }
            .map { step -> String in
                let punctuated = step.hasSuffix(".") ? step : "\(step)."
                return normalizeStepLine(punctuated)
            }
        return Array(sentenceSeparated.prefix(10))
    }

    private func fetchOpenAIRecipeSearchHints(query: String) -> OpenAIRecipeHints? {
        guard OpenAISettings.isConfigured else { return nil }
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }

        let system = """
        You suggest recipe discovery hints.
        Return strict JSON only:
        {"domains":["example.com"],"query_variants":["variant 1","variant 2"]}
        Rules:
        - Suggest at most 5 domains and 5 query_variants.
        - Domains must be likely recipe websites.
        - No prose, no markdown, only JSON.
        """
        let user = "Dish query: \(query)"
        let requestBody: [String: Any] = [
            "model": OpenAISettings.generalModel,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.1,
            "max_tokens": 220,
            "response_format": ["type": "json_object"]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        let requestID = OpenAIAPILogStore.shared.logHTTPRequest(
            service: "FindRecipeTool.fetchOpenAIRecipeSearchHints",
            endpoint: url.absoluteString,
            method: "POST",
            model: OpenAISettings.generalModel,
            timeoutSeconds: request.timeoutInterval,
            payload: requestBody
        )

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseCode: Int?
        var responseError: String?
        let startedAt = Date()

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            responseData = data
            responseCode = (response as? HTTPURLResponse)?.statusCode
            responseError = error?.localizedDescription
        }.resume()

        _ = semaphore.wait(timeout: .now() + 6)
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard let status = responseCode,
              status >= 200,
              status < 300,
              let responseData else {
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "FindRecipeTool.fetchOpenAIRecipeSearchHints",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.generalModel,
                statusCode: responseCode,
                latencyMs: latencyMs,
                error: responseError ?? "No response",
                responseData: responseData
            )
            return nil
        }

        OpenAIAPILogStore.shared.logHTTPResponse(
            requestID: requestID,
            service: "FindRecipeTool.fetchOpenAIRecipeSearchHints",
            endpoint: url.absoluteString,
            method: "POST",
            model: OpenAISettings.generalModel,
            statusCode: status,
            latencyMs: latencyMs,
            responseData: responseData
        )

        guard let envelope = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            return nil
        }

        let raw = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        let domains = (parsed["domains"] as? [String] ?? []).prefix(5).map { $0 }
        let variants = (parsed["query_variants"] as? [String] ?? []).prefix(5).map { $0 }
        return OpenAIRecipeHints(domains: domains, queryVariants: variants)
    }

    private func fetchOpenAIGeneratedRecipe(query: String) -> OpenAIGeneratedRecipe? {
        guard OpenAISettings.isConfigured else { return nil }
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }

        let system = """
        You generate practical cooking recipes.
        Return strict JSON only:
        {"title":"...","ingredients":["..."],"steps":["..."],"note":"..."}
        Rules:
        - Use 6-14 ingredients and 4-10 steps.
        - Keep steps concise and actionable.
        - Do not include markdown.
        - If unsure, return your best common version of the dish.
        """
        let user = "Dish request: \(query)"
        let requestBody: [String: Any] = [
            "model": OpenAISettings.generalModel,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.2,
            "max_tokens": 520,
            "response_format": ["type": "json_object"]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 7
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        let requestID = OpenAIAPILogStore.shared.logHTTPRequest(
            service: "FindRecipeTool.fetchOpenAIGeneratedRecipe",
            endpoint: url.absoluteString,
            method: "POST",
            model: OpenAISettings.generalModel,
            timeoutSeconds: request.timeoutInterval,
            payload: requestBody
        )

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseCode: Int?
        var responseError: String?
        let startedAt = Date()

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            responseData = data
            responseCode = (response as? HTTPURLResponse)?.statusCode
            responseError = error?.localizedDescription
        }.resume()

        _ = semaphore.wait(timeout: .now() + 8)
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard let status = responseCode,
              status >= 200,
              status < 300,
              let responseData else {
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "FindRecipeTool.fetchOpenAIGeneratedRecipe",
                endpoint: url.absoluteString,
                method: "POST",
                model: OpenAISettings.generalModel,
                statusCode: responseCode,
                latencyMs: latencyMs,
                error: responseError ?? "No response",
                responseData: responseData
            )
            return nil
        }

        OpenAIAPILogStore.shared.logHTTPResponse(
            requestID: requestID,
            service: "FindRecipeTool.fetchOpenAIGeneratedRecipe",
            endpoint: url.absoluteString,
            method: "POST",
            model: OpenAISettings.generalModel,
            statusCode: status,
            latencyMs: latencyMs,
            responseData: responseData
        )

        guard let envelope = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            return nil
        }

        let raw = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseOpenAIGeneratedRecipe(from: payload)
    }

    func parseOpenAIGeneratedRecipe(from payload: [String: Any]) -> OpenAIGeneratedRecipe? {
        let preferredTitle = (payload["title"] as? String ?? payload["name"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = preferredTitle.isEmpty ? "Recipe" : preferredTitle
        let ingredients = normalizeOpenAIIngredientList(payload["ingredients"])
        let steps = normalizeOpenAISteps(payload["steps"] ?? payload["instructions"] ?? payload["method"])
        guard !ingredients.isEmpty, !steps.isEmpty else { return nil }

        let note = (payload["note"] as? String ?? payload["tips"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenAIGeneratedRecipe(
            title: title,
            ingredients: ingredients,
            steps: steps,
            note: note.isEmpty ? nil : note
        )
    }

    private func normalizeOpenAIIngredientList(_ value: Any?) -> [String] {
        var items: [String] = []
        if let list = value as? [String] {
            items = list
        } else if let list = value as? [Any] {
            items = list.compactMap { $0 as? String }
        } else if let single = value as? String {
            items = single
                .components(separatedBy: .newlines)
                .flatMap { line in
                    line.split(separator: ",").map(String.init)
                }
        }

        let normalized = items
            .map { normalizeListLine($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && $0.count <= 120 }
        return Array(normalized.prefix(14))
    }

    private func normalizeOpenAISteps(_ value: Any?) -> [String] {
        if let list = value as? [String] {
            let normalized = list
                .map { normalizeStepLine($0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 8 && $0.count <= 220 }
            if !normalized.isEmpty {
                return Array(normalized.prefix(10))
            }
        } else if let list = value as? [Any] {
            let normalized = list
                .compactMap { $0 as? String }
                .map { normalizeStepLine($0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 8 && $0.count <= 220 }
            if !normalized.isEmpty {
                return Array(normalized.prefix(10))
            }
        } else if let text = value as? String {
            return Array(splitInstructionSteps(text).prefix(10))
        }
        return []
    }

    private func extractIngredients(from lines: [String]) -> [String] {
        if let idx = lines.firstIndex(where: { $0.lowercased().contains("ingredients") }) {
            let section = Array(lines.dropFirst(idx + 1).prefix(30))
            let picked = section
                .filter { isIngredientLine($0) }
                .prefix(12)
                .map { normalizeListLine($0) }
            if !picked.isEmpty { return picked }
        }

        // Fallback: top ingredient-like lines anywhere on the page.
        return lines
            .filter { isIngredientLine($0) }
            .prefix(10)
            .map { normalizeListLine($0) }
    }

    private func extractSteps(from lines: [String]) -> [String] {
        if let idx = lines.firstIndex(where: { line in
            let lower = line.lowercased()
            return lower.contains("instructions") || lower.contains("directions") || lower == "method" || lower.contains("steps")
        }) {
            let section = Array(lines.dropFirst(idx + 1).prefix(40))
            let picked = section
                .filter { isStepLine($0) }
                .prefix(10)
                .map { normalizeStepLine($0) }
            if !picked.isEmpty { return picked }
        }

        // Fallback: numbered/bullet-like procedural lines.
        return lines
            .filter { isStepLine($0) }
            .prefix(8)
            .map { normalizeStepLine($0) }
    }

    private func isIngredientLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("nutrition") || lower.contains("servings") || lower.contains("calories") { return false }
        if lower.count < 3 || lower.count > 120 { return false }
        if lower.hasPrefix("step ") || lower.hasPrefix("directions") { return false }
        let nsRange = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        if Self.ingredientUnitRegex.firstMatch(in: lower, options: [], range: nsRange) != nil { return true }
        return lower.first == "-" || lower.first == "•"
    }

    private func isStepLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.count < 10 || lower.count > 220 { return false }
        if lower.contains("ingredients") || lower.contains("nutrition") { return false }
        if lower.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) != nil { return true }
        if lower.hasPrefix("- ") || lower.hasPrefix("•") { return true }
        let verbs = ["mix", "stir", "cook", "bake", "simmer", "whisk", "heat", "add", "combine", "serve", "pour"]
        return verbs.contains { lower.contains($0) }
    }

    private func normalizeListLine(_ line: String) -> String {
        var output = line.trimmingCharacters(in: .whitespacesAndNewlines)
        output = output.replacingOccurrences(of: #"^[-•\s]+"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"^\d+[\.\)]\s*"#, with: "", options: .regularExpression)
        return output
    }

    private func normalizeStepLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(of: #"^\d+[\.\)]\s*"#, with: "", options: .regularExpression)
    }

    private func buildRecipeMarkdown(query: String,
                                     sourceTitle: String,
                                     sourceURL: URL,
                                     ingredients: [String],
                                     steps: [String],
                                     alternatives: [RecipeMatch]) -> String {
        var lines: [String] = []
        lines.append("# Recipe: \(query)")
        lines.append("")
        lines.append("- Source: [\(sourceTitle)](\(sourceURL.absoluteString))")
        lines.append("")
        lines.append("## Ingredients")
        for ingredient in ingredients.prefix(12) {
            lines.append("- \(ingredient)")
        }
        lines.append("")
        lines.append("## Steps")
        for (index, step) in steps.prefix(10).enumerated() {
            lines.append("\(index + 1). \(step)")
        }
        if !alternatives.isEmpty {
            lines.append("")
            lines.append("## More Recipes Found")
            for alt in alternatives.prefix(3) {
                lines.append("- [\(alt.title)](\(alt.url.absoluteString))")
            }
        }
        lines.append("")
        lines.append("_Want another option? Ask: `show another recipe for \(query)`_")
        lines.append("_To restart options: `reset recipe history for \(query)`_")

        let markdown = lines.joined(separator: "\n")
        // Keep payload comfortably inside router/tool payload guidance.
        return String(markdown.prefix(1_180))
    }

    private func buildGeneratedRecipeMarkdown(query: String, generated: OpenAIGeneratedRecipe) -> String {
        var lines: [String] = []
        lines.append("# Recipe: \(generated.title)")
        lines.append("")
        lines.append("- Source: OpenAI generated fallback (no reliable recipe page was reachable)")
        lines.append("")
        lines.append("## Ingredients")
        for ingredient in generated.ingredients.prefix(14) {
            lines.append("- \(ingredient)")
        }
        lines.append("")
        lines.append("## Steps")
        for (index, step) in generated.steps.prefix(10).enumerated() {
            lines.append("\(index + 1). \(step)")
        }
        if let note = generated.note {
            lines.append("")
            lines.append("## Note")
            lines.append("- \(note)")
        }
        lines.append("")
        lines.append("_Want another option? Ask: `show another recipe for \(query)`_")
        lines.append("_To restart options: `reset recipe history for \(query)`_")
        return String(lines.joined(separator: "\n").prefix(1_180))
    }

    private func extractTitle(fromHTML html: String) -> String? {
        let range = NSRange(html.startIndex..., in: html)
        guard let match = Self.titleRegex.firstMatch(in: html, options: [], range: range),
              let titleRange = Range(match.range(at: 1), in: html) else { return nil }
        let title = decodeHTMLEntities(String(html[titleRange]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return title.isEmpty ? nil : String(title.prefix(120))
    }

    private func extractVisibleText(fromHTML html: String) -> String {
        var text = html
        text = Self.scriptRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        text = Self.styleRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        text = Self.noscriptRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        text = Self.commentsRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</(p|div|section|article|li|h[1-6]|tr)>", with: "\n", options: .regularExpression)
        text = Self.tagsRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        text = decodeHTMLEntities(text)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = Self.whitespaceRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        text = Self.multiNewlineRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    private func fetchHTML(url: URL) -> String? {
        guard let data = fetchData(url: url, timeout: 8) else { return nil }
        let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        guard let body, !body.isEmpty else { return nil }
        return body
    }

    private func fetchData(url: URL, timeout: TimeInterval) -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data = data else { return }
            payload = data
        }.resume()

        _ = semaphore.wait(timeout: .now() + timeout + 2)
        return payload
    }

    private func recipePromptPayload(slot: String, spoken: String, formatted: String) -> OutputItem {
        let payload: [String: Any] = [
            "kind": "prompt",
            "slot": slot,
            "spoken": spoken,
            "formatted": formatted
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: spoken)
    }

    private func structuredMarkdownPayload(kind: String, spoken: String, formatted: String) -> OutputItem {
        let payload: [String: Any] = [
            "kind": kind,
            "spoken": spoken,
            "formatted": formatted
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: formatted)
    }
}

struct DescribeCameraViewTool: Tool {
    let name = "describe_camera_view"
    let description = "Describes what Sam currently sees through the live laptop camera. Use when the user asks what Sam can see or asks for a visual scene description. Camera must be enabled in Audio/Visual settings."

    private let camera: CameraVisionProviding

    init(camera: CameraVisionProviding = CameraVisionService.shared) {
        self.camera = camera
    }

    func execute(args: [String: String]) -> OutputItem {
        _ = args
        guard camera.isRunning else {
            return OutputItem(
                kind: .markdown,
                payload: "Camera is off. Turn on Camera in `Settings > Audio/Visual`, then ask again."
            )
        }

        guard let scene = camera.describeCurrentScene() else {
            return OutputItem(
                kind: .markdown,
                payload: "Camera is on, but I don't have a frame yet. Try again in a second."
            )
        }

        let spoken = "Here's what I can see right now: \(scene.summary)"
        return cameraStructuredPayload(
            kind: "camera_view",
            spoken: spoken,
            formatted: scene.markdown()
        )
    }
}

struct CameraObjectFinderTool: Tool {
    let name = "find_camera_objects"
    let description = "Finds objects in the current live camera frame by keyword. Args: 'query' (required). Example: find_camera_objects(query:\"bottle\")."

    private let camera: CameraVisionProviding

    init(camera: CameraVisionProviding = CameraVisionService.shared) {
        self.camera = camera
    }

    func execute(args: [String: String]) -> OutputItem {
        let query = (args["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return cameraPromptPayload(
                slot: "query",
                spoken: "What object should I look for?",
                formatted: "Provide a query, for example `bottle`, `phone`, or `keys`."
            )
        }

        guard camera.isRunning else {
            return OutputItem(kind: .markdown, payload: "Camera is off. Turn it on first, then ask me to find an object.")
        }
        guard let analysis = camera.currentAnalysis() else {
            return OutputItem(kind: .markdown, payload: "Camera is on, but I don't have a frame yet. Try again in a second.")
        }

        let queryTokens = cameraTokens(from: query)
        let queryTokenSet = Set(queryTokens)
        let queryLower = query.lowercased()

        let labelMatches = analysis.labels.compactMap { label -> (String, Float)? in
            let labelTokens = cameraTokens(from: label.label)
            let overlap = Set(labelTokens).intersection(queryTokenSet).count
            let phraseHit = label.label.contains(queryLower)
            guard overlap > 0 || phraseHit else { return nil }
            let score = label.confidence + Float(overlap) * 0.2 + (phraseHit ? 0.35 : 0)
            return (label.label, score)
        }
        .sorted { $0.1 > $1.1 }

        let textMatches = analysis.recognizedText.filter { line in
            let lower = line.lowercased()
            if lower.contains(queryLower) { return true }
            let lineTokens = Set(cameraTokens(from: lower))
            return !lineTokens.intersection(queryTokenSet).isEmpty
        }

        let spoken: String
        var lines: [String] = [
            "# Object Finder",
            "",
            "- Query: \(query)",
            "- Captured: \(DateFormatter.localizedString(from: analysis.capturedAt, dateStyle: .none, timeStyle: .medium))"
        ]

        if labelMatches.isEmpty && textMatches.isEmpty {
            spoken = "I couldn't confidently find \(query) in the current view."
            lines.append("")
            lines.append("## Result")
            lines.append("No strong match found for `\(query)` in this frame.")
            if !analysis.labels.isEmpty {
                lines.append("")
                lines.append("## Top Visible Objects")
                for label in analysis.labels.prefix(5) {
                    lines.append("- \(label.label) (\(Int((label.confidence * 100).rounded()))%)")
                }
            }
        } else {
            spoken = "I found likely matches for \(query)."
            if !labelMatches.isEmpty {
                lines.append("")
                lines.append("## Object Matches")
                for (label, score) in labelMatches.prefix(5) {
                    lines.append("- \(label) (match score \(String(format: "%.2f", score)))")
                }
            }
            if !textMatches.isEmpty {
                lines.append("")
                lines.append("## Text Matches")
                for match in textMatches.prefix(5) {
                    lines.append("- \(match)")
                }
            }
        }

        return cameraStructuredPayload(
            kind: "camera_object_finder",
            spoken: spoken,
            formatted: lines.joined(separator: "\n")
        )
    }
}

struct CameraFacePresenceTool: Tool {
    let name = "get_camera_face_presence"
    let description = "Detects face presence in the live camera frame. Use for questions like 'do you see a face?' or 'how many faces are there?'."

    private let camera: CameraVisionProviding

    init(camera: CameraVisionProviding = CameraVisionService.shared) {
        self.camera = camera
    }

    func execute(args: [String: String]) -> OutputItem {
        _ = args
        guard camera.isRunning else {
            return OutputItem(kind: .markdown, payload: "Camera is off. Turn it on first, then ask about face presence.")
        }
        guard let analysis = camera.currentAnalysis() else {
            return OutputItem(kind: .markdown, payload: "Camera is on, but I don't have a frame yet. Try again in a second.")
        }

        let count = analysis.faces.count
        let noun = count == 1 ? "face" : "faces"
        let spoken = count == 0
            ? "I do not see a face in the current frame."
            : "I can detect \(count) \(noun) right now."

        var lines: [String] = [
            "# Face Presence",
            "",
            "- Captured: \(DateFormatter.localizedString(from: analysis.capturedAt, dateStyle: .none, timeStyle: .medium))",
            "- Faces detected: \(count)"
        ]

        if !analysis.labels.isEmpty {
            lines.append("")
            lines.append("## Frame Context")
            for label in analysis.labels.prefix(4) {
                lines.append("- \(label.label) (\(Int((label.confidence * 100).rounded()))%)")
            }
        }

        return cameraStructuredPayload(
            kind: "camera_face_presence",
            spoken: spoken,
            formatted: lines.joined(separator: "\n")
        )
    }
}

struct EnrollCameraFaceTool: Tool {
    let name = "enroll_camera_face"
    let description = "Enrolls a person's face in the local camera recognizer. Args: 'name' (required). Example: enroll_camera_face(name:\"Ricky\")."

    private let camera: CameraVisionProviding

    init(camera: CameraVisionProviding = CameraVisionService.shared) {
        self.camera = camera
    }

    func execute(args: [String: String]) -> OutputItem {
        let requestedName = (args["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else {
            return cameraPromptPayload(
                slot: "name",
                spoken: "What name should I use for this face?",
                formatted: "Provide `name`, for example `enroll_camera_face(name:\"Ricky\")`."
            )
        }

        let result = camera.enrollFace(name: requestedName)
        switch result.status {
        case .unsupported:
            return OutputItem(kind: .markdown, payload: "Face enrollment is not available in the current camera provider.")
        case .cameraOff:
            return OutputItem(kind: .markdown, payload: "Camera is off. Turn it on first, then enroll a face.")
        case .noFrame:
            return OutputItem(kind: .markdown, payload: "Camera is on, but I don't have a frame yet. Try again in a second.")
        case .invalidName:
            return cameraPromptPayload(
                slot: "name",
                spoken: "I need a valid name to enroll this face.",
                formatted: "Provide a non-empty `name`."
            )
        case .noFaceDetected:
            let spoken = "I couldn't find a clear face in the current frame."
            let formatted = [
                "# Face Enrollment",
                "",
                "- Name: \(requestedName)",
                "- Result: no face detected",
                "",
                "Make sure one face is clearly visible, then run enrollment again."
            ].joined(separator: "\n")
            return cameraStructuredPayload(kind: "camera_face_enrollment", spoken: spoken, formatted: formatted)
        case .success:
            let enrolledName = result.enrolledName ?? requestedName
            let captured = result.capturedAt.map {
                DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium)
            } ?? "unknown"
            let spoken = "I learned \(enrolledName)'s face."
            let formatted = [
                "# Face Enrollment",
                "",
                "- Name: \(enrolledName)",
                "- Captured: \(captured)",
                "- Samples for this name: \(result.samplesForName)",
                "- Total enrolled identities: \(result.totalKnownNames)",
                "",
                "I can now try to recognize this person in future camera frames."
            ].joined(separator: "\n")
            return cameraStructuredPayload(kind: "camera_face_enrollment", spoken: spoken, formatted: formatted)
        }
    }
}

struct RecognizeCameraFacesTool: Tool {
    let name = "recognize_camera_faces"
    let description = "Recognizes previously enrolled faces from the live camera frame and reports matches with confidence."

    private let camera: CameraVisionProviding

    init(camera: CameraVisionProviding = CameraVisionService.shared) {
        self.camera = camera
    }

    func execute(args: [String: String]) -> OutputItem {
        _ = args
        guard camera.isRunning else {
            return OutputItem(kind: .markdown, payload: "Camera is off. Turn it on first, then ask me to recognize faces.")
        }
        guard let result = camera.recognizeKnownFaces() else {
            return OutputItem(kind: .markdown, payload: "Camera is on, but I don't have a frame yet. Try again in a second.")
        }

        let spoken: String
        if result.enrolledNames.isEmpty {
            spoken = "I don't have any enrolled faces yet."
        } else if result.detectedFaces == 0 {
            spoken = "I don't currently see a face in the frame."
        } else if result.matches.isEmpty {
            spoken = "I can see faces, but none match my enrolled identities yet."
        } else {
            let names = result.matches.map { $0.name }
            let uniqueNames = Array(NSOrderedSet(array: names)) as? [String] ?? names
            spoken = "I recognize \(uniqueNames.joined(separator: ", "))."
        }

        var lines: [String] = [
            "# Face Recognition",
            "",
            "- Captured: \(DateFormatter.localizedString(from: result.capturedAt, dateStyle: .none, timeStyle: .medium))",
            "- Faces detected: \(result.detectedFaces)",
            "- Matches: \(result.matches.count)",
            "- Unknown faces: \(result.unknownFaces)"
        ]

        if !result.matches.isEmpty {
            lines.append("")
            lines.append("## Recognized")
            for match in result.matches {
                let confidence = Int((match.confidence * 100).rounded())
                lines.append("- \(match.name) (\(confidence)% confidence, distance \(String(format: "%.3f", match.distance)))")
            }
        }

        if !result.enrolledNames.isEmpty {
            lines.append("")
            lines.append("## Enrolled Identities")
            for name in result.enrolledNames {
                lines.append("- \(name)")
            }
        } else {
            lines.append("")
            lines.append("No identities enrolled yet. Use `enroll_camera_face(name:\"...\")` first.")
        }

        return cameraStructuredPayload(
            kind: "camera_face_recognition",
            spoken: spoken,
            formatted: lines.joined(separator: "\n")
        )
    }
}

struct CameraVisualQATool: Tool {
    let name = "camera_visual_qa"
    let description = "Answers a question about the current camera frame. Args: 'question' (required). Generic visual Q&A over detected objects, visible text, and face presence."

    private let camera: CameraVisionProviding

    init(camera: CameraVisionProviding = CameraVisionService.shared) {
        self.camera = camera
    }

    func execute(args: [String: String]) -> OutputItem {
        let question = (args["question"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return cameraPromptPayload(
                slot: "question",
                spoken: "What do you want to know about the camera view?",
                formatted: "Ask one question about what is visible right now."
            )
        }

        guard camera.isRunning else {
            return OutputItem(kind: .markdown, payload: "Camera is off. Turn it on first, then ask a visual question.")
        }
        guard let analysis = camera.currentAnalysis() else {
            return OutputItem(kind: .markdown, payload: "Camera is on, but I don't have a frame yet. Try again in a second.")
        }

        let lower = question.lowercased()
        let qTokens = Set(cameraTokens(from: lower))
        let isYesNo = lower.hasPrefix("is ") || lower.hasPrefix("are ") || lower.hasPrefix("do ") || lower.hasPrefix("does ") || lower.hasPrefix("can ")
        let asksFaceCount = lower.contains("how many") && (lower.contains("face") || lower.contains("person") || lower.contains("people"))
        let asksText = lower.contains("text") || lower.contains("read") || lower.contains("word")

        var spoken = ""
        var evidence: [String] = []

        if asksFaceCount {
            spoken = "I can detect \(analysis.faces.count) \(analysis.faces.count == 1 ? "face" : "faces") right now."
            evidence.append("Faces detected: \(analysis.faces.count)")
        } else if asksText {
            if analysis.recognizedText.isEmpty {
                spoken = "I do not see readable text in the current frame."
            } else {
                spoken = "I can read: \(analysis.recognizedText.prefix(2).joined(separator: "; "))."
                evidence.append(contentsOf: analysis.recognizedText.prefix(5).map { "Text: \($0)" })
            }
        } else {
            let labelMatches = analysis.labels.filter { label in
                let labelTokens = Set(cameraTokens(from: label.label))
                return !labelTokens.intersection(qTokens).isEmpty
            }
            let textMatches = analysis.recognizedText.filter { text in
                let textTokens = Set(cameraTokens(from: text))
                return !textTokens.intersection(qTokens).isEmpty
            }

            if isYesNo {
                let matchFound = !labelMatches.isEmpty || !textMatches.isEmpty
                spoken = matchFound ? "Yes, that appears in the current camera view." : "No, I do not see that in the current frame."
            } else if !labelMatches.isEmpty || !textMatches.isEmpty {
                var parts: [String] = []
                if !labelMatches.isEmpty {
                    parts.append("Objects: \(labelMatches.prefix(3).map { $0.label }.joined(separator: ", "))")
                }
                if !textMatches.isEmpty {
                    parts.append("Text: \(textMatches.prefix(2).joined(separator: "; "))")
                }
                spoken = parts.isEmpty ? "I can summarize what is visible right now." : parts.joined(separator: ". ") + "."
            } else if let scene = camera.describeCurrentScene() {
                spoken = scene.summary
            } else {
                spoken = "I can see the frame, but I cannot confidently answer that question yet."
            }

            evidence.append(contentsOf: labelMatches.prefix(5).map {
                "Label: \($0.label) (\(Int(($0.confidence * 100).rounded()))%)"
            })
            evidence.append(contentsOf: textMatches.prefix(5).map { "Text: \($0)" })
        }

        var lines: [String] = [
            "# Visual Q&A",
            "",
            "- Question: \(question)",
            "- Captured: \(DateFormatter.localizedString(from: analysis.capturedAt, dateStyle: .none, timeStyle: .medium))",
            "",
            "## Answer",
            spoken
        ]

        if !evidence.isEmpty {
            lines.append("")
            lines.append("## Evidence")
            for entry in evidence {
                lines.append("- \(entry)")
            }
        }

        return cameraStructuredPayload(
            kind: "camera_visual_qa",
            spoken: spoken,
            formatted: lines.joined(separator: "\n")
        )
    }
}

struct CameraInventorySnapshotTool: Tool {
    let name = "camera_inventory_snapshot"
    let description = "Captures an inventory snapshot from the live camera frame and reports changes since the previous snapshot."

    private struct Snapshot {
        let capturedAt: Date
        let items: [String: Float]
    }

    private static let snapshotQueue = DispatchQueue(label: "com.samos.camera.inventory.snapshot")
    private static var previousSnapshot: Snapshot?

    private let camera: CameraVisionProviding

    init(camera: CameraVisionProviding = CameraVisionService.shared) {
        self.camera = camera
    }

    func execute(args: [String: String]) -> OutputItem {
        _ = args
        guard camera.isRunning else {
            return OutputItem(kind: .markdown, payload: "Camera is off. Turn it on first, then capture an inventory snapshot.")
        }
        guard let analysis = camera.currentAnalysis() else {
            return OutputItem(kind: .markdown, payload: "Camera is on, but I don't have a frame yet. Try again in a second.")
        }

        var items: [String: Float] = [:]
        for prediction in analysis.labels.prefix(12) {
            let current = items[prediction.label] ?? 0
            items[prediction.label] = max(current, prediction.confidence)
        }

        let nowSnapshot = Snapshot(capturedAt: analysis.capturedAt, items: items)
        let previous = Self.snapshotQueue.sync { () -> Snapshot? in
            let old = Self.previousSnapshot
            Self.previousSnapshot = nowSnapshot
            return old
        }

        let currentKeys = Set(items.keys)
        let previousKeys = Set(previous?.items.keys.map { $0 } ?? [])
        let added = currentKeys.subtracting(previousKeys).sorted()
        let removed = previousKeys.subtracting(currentKeys).sorted()
        let unchanged = currentKeys.intersection(previousKeys).sorted()

        let spoken = previous == nil
            ? "Inventory snapshot captured."
            : "Inventory snapshot captured. I found \(added.count) new and \(removed.count) removed item types."

        var lines: [String] = [
            "# Camera Inventory Snapshot",
            "",
            "- Captured: \(DateFormatter.localizedString(from: analysis.capturedAt, dateStyle: .none, timeStyle: .medium))",
            "- Item types: \(items.count)"
        ]

        if !items.isEmpty {
            lines.append("")
            lines.append("## Items")
            for key in items.keys.sorted() {
                let confidence = Int(((items[key] ?? 0) * 100).rounded())
                lines.append("- \(key) (\(confidence)%)")
            }
        }

        if previous != nil {
            lines.append("")
            lines.append("## Changes Since Previous Snapshot")
            lines.append("- Added: \(added.isEmpty ? "none" : added.joined(separator: ", "))")
            lines.append("- Removed: \(removed.isEmpty ? "none" : removed.joined(separator: ", "))")
            lines.append("- Unchanged: \(unchanged.isEmpty ? "none" : unchanged.joined(separator: ", "))")
        }

        return cameraStructuredPayload(
            kind: "camera_inventory_snapshot",
            spoken: spoken,
            formatted: lines.joined(separator: "\n")
        )
    }
}

struct SaveCameraMemoryNoteTool: Tool {
    let name = "save_camera_memory_note"
    let description = "Saves a timestamped memory note from the current camera view into local memory for later recall."

    private let camera: CameraVisionProviding
    private let memoryStore: MemoryStore

    init(camera: CameraVisionProviding = CameraVisionService.shared, memoryStore: MemoryStore = .shared) {
        self.camera = camera
        self.memoryStore = memoryStore
    }

    func execute(args: [String: String]) -> OutputItem {
        _ = args
        guard memoryStore.isAvailable else {
            return OutputItem(kind: .markdown, payload: "**Memory Error:** Memory store is not available.")
        }
        guard camera.isRunning else {
            return OutputItem(kind: .markdown, payload: "Camera is off. Turn it on first, then save a camera memory note.")
        }
        guard let scene = camera.describeCurrentScene(),
              let analysis = camera.currentAnalysis() else {
            return OutputItem(kind: .markdown, payload: "Camera is on, but I don't have a frame yet. Try again in a second.")
        }

        let topLabels = analysis.labels.prefix(3).map { $0.label }
        let labelFragment = topLabels.isEmpty ? "" : " Top objects: \(topLabels.joined(separator: ", "))."
        let textFragment = analysis.recognizedText.isEmpty ? "" : " Visible text: \(analysis.recognizedText.prefix(2).joined(separator: "; "))."
        var content = "Camera observation: \(scene.summary)\(labelFragment)\(textFragment)"
        content = String(content.prefix(360))

        let iso = ISO8601DateFormatter().string(from: analysis.capturedAt)
        let tags = ["camera", "vision"] + topLabels.map { $0.replacingOccurrences(of: " ", with: "_") }
        let result = memoryStore.upsertMemory(
            type: .note,
            content: content,
            confidence: .medium,
            ttlDays: 90,
            source: "camera_vision",
            sourceSnippet: iso,
            tags: tags,
            now: Date()
        )

        let spoken: String
        let statusLine: String
        switch result {
        case .inserted(let row):
            spoken = "Saved that camera note to memory."
            statusLine = "Saved note `\(row.shortID)`."
        case .updated(let row):
            spoken = "Updated an existing camera memory note."
            statusLine = "Updated note `\(row.shortID)`."
        case .skippedDuplicate:
            spoken = "That camera note is already saved."
            statusLine = "Duplicate note detected, nothing new saved."
        case .skippedLimit:
            spoken = "I hit the memory save limit for now."
            statusLine = "Memory limit reached, note was not saved."
        }

        let formatted = [
            "# Camera Memory Note",
            "",
            "- \(statusLine)",
            "- Captured: \(DateFormatter.localizedString(from: analysis.capturedAt, dateStyle: .none, timeStyle: .medium))",
            "",
            "## Note",
            content
        ].joined(separator: "\n")

        return cameraStructuredPayload(
            kind: "camera_memory_note",
            spoken: spoken,
            formatted: formatted
        )
    }
}

private func cameraStructuredPayload(kind: String, spoken: String, formatted: String) -> OutputItem {
    let payload: [String: Any] = [
        "kind": kind,
        "spoken": spoken,
        "formatted": formatted
    ]

    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let json = String(data: data, encoding: .utf8) {
        return OutputItem(kind: .markdown, payload: json)
    }
    return OutputItem(kind: .markdown, payload: formatted)
}

private func cameraPromptPayload(slot: String, spoken: String, formatted: String) -> OutputItem {
    let payload: [String: Any] = [
        "kind": "prompt",
        "slot": slot,
        "spoken": spoken,
        "formatted": formatted
    ]

    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let json = String(data: data, encoding: .utf8) {
        return OutputItem(kind: .markdown, payload: json)
    }
    return OutputItem(kind: .markdown, payload: spoken)
}

private func cameraTokens(from text: String) -> [String] {
    return text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty && $0.count > 1 && !cameraTokenStopwords.contains($0) }
}

private let cameraTokenStopwords: Set<String> = [
    "the", "a", "an", "is", "are", "do", "does", "can", "you", "see", "there", "any",
    "right", "now", "in", "on", "at", "of", "to", "for", "with", "what", "which", "and",
    "through", "camera", "frame", "view"
]

struct CapabilityGapToClaudePromptTool: Tool {
    let name = "capability_gap_to_claude_prompt"
    let description = "Generates a Claude-ready build prompt for a missing capability"

    func execute(args: [String: String]) -> OutputItem {
        let goal = args["goal"] ?? "Unknown goal"
        let missing = args["missing"] ?? "Unknown capability"
        let repoContext = args["repoContext"] ?? "SamOS macOS SwiftUI app"

        let prompt = """
        # Capability Build Request

        ## Goal
        \(goal)

        ## Missing Capability
        \(missing)

        ## Repository Context
        \(repoContext)

        ## Instructions
        Please design and implement a new capability package for the SamOS system that addresses the above gap. \
        The package should:

        1. Conform to the `Tool` protocol (`name`, `description`, `execute(args:) -> OutputItem`)
        2. Register itself in `ToolRegistry`
        3. Include any necessary Services layer code
        4. Follow the existing project conventions (Models/, Services/, Tools/, Views/)
        5. Handle errors gracefully and return user-friendly OutputItems

        Provide the complete Swift source files needed.
        """

        return OutputItem(kind: .markdown, payload: prompt)
    }
}

struct LearnWebsiteTool: Tool {
    let name = "learn_website"
    let description = "Fetch and learn from a website URL for later Q&A. Use ONLY when user provides or asks about a specific webpage URL. Args: 'url' (required), optional 'focus' (what to focus on). Not for capability/skill building."

    struct FetchResult {
        let body: String
        let contentType: String
    }

    typealias Fetcher = (URL) -> FetchResult?

    private let fetcher: Fetcher
    private let learningStore: WebsiteLearningStore
    private let memoryStore: MemoryStore

    init(fetcher: @escaping Fetcher = LearnWebsiteTool.defaultFetch,
         learningStore: WebsiteLearningStore = .shared,
         memoryStore: MemoryStore = .shared) {
        self.fetcher = fetcher
        self.learningStore = learningStore
        self.memoryStore = memoryStore
    }

    func execute(args: [String: String]) -> OutputItem {
        let rawURL = args["url"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawURL.isEmpty else {
            return buildPromptPayload(
                slot: "url",
                spoken: "Which website should I learn from?",
                formatted: "I need a URL like `https://example.com`."
            )
        }

        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return OutputItem(kind: .markdown, payload: "I couldn't use that URL. Please send a full `http://` or `https://` link.")
        }

        guard let fetched = fetcher(url) else {
            return OutputItem(kind: .markdown, payload: "I couldn't load that website right now. Please try again.")
        }

        let focus = args["focus"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxHighlights = parsePositiveInt(args["max_highlights"])
        guard let learned = summarize(url: url, fetched: fetched, focus: focus) else {
            return OutputItem(kind: .markdown, payload: "I loaded the page, but couldn't extract enough readable content to learn from it.")
        }

        let persistedHighlights: [String]
        if let maxHighlights {
            persistedHighlights = Array(learned.highlights.prefix(maxHighlights))
        } else {
            persistedHighlights = learned.highlights
        }

        let record = learningStore.saveLearnedPage(
            url: url.absoluteString,
            title: learned.title,
            summary: learned.summary,
            highlights: persistedHighlights,
            chunks: learned.chunks
        )

        if memoryStore.isAvailable && !isLowValueLearningSummary(record.summary) {
            let note = "From \(record.host): \(record.summary)"
            _ = memoryStore.upsertMemory(
                type: .note,
                content: note,
                confidence: .medium,
                ttlDays: 90,
                source: "website_learning",
                sourceSnippet: record.url,
                tags: ["website", record.host],
                now: Date()
            )
        }

        let spoken = "Done. I learned that page and saved the key points."
        let formatted = buildFormattedLearningReport(record: record)
        let payload: [String: Any] = [
            "kind": "website_learning",
            "spoken": spoken,
            "formatted": formatted
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }

        return OutputItem(kind: .markdown, payload: formatted)
    }

    private func parsePositiveInt(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = Int(value),
              parsed > 0 else { return nil }
        return parsed
    }

    private func summarize(url: URL, fetched: FetchResult, focus: String?) -> (title: String, summary: String, highlights: [String], chunks: [String])? {
        let host = url.host ?? "website"
        let contentType = fetched.contentType.lowercased()
        let rawText: String

        if contentType.contains("html") || contentType.isEmpty {
            rawText = extractVisibleText(fromHTML: fetched.body)
        } else {
            rawText = normalizeText(fetched.body)
        }

        let lines = rawText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 20 }
            .filter { !isBoilerplateLine($0) }

        guard !lines.isEmpty else { return nil }

        let title = extractTitle(fromHTML: fetched.body) ?? host
        let highlights = selectHighlights(from: lines, focus: focus)
        guard !highlights.isEmpty else { return nil }
        let chunks = buildChunks(from: lines, focus: focus)

        var summary = highlights.prefix(2).joined(separator: " ")
        if summary.count > 280 {
            summary = String(summary.prefix(277)) + "..."
        }

        return (title: title, summary: summary, highlights: highlights, chunks: chunks)
    }

    private func buildFormattedLearningReport(record: WebsiteLearningRecord) -> String {
        var lines: [String] = [
            "# Learned From \(record.title)",
            "",
            "- URL: \(record.url)",
            "- Source: \(record.host)",
            "",
            "## Summary",
            record.summary
        ]

        if !record.highlights.isEmpty {
            lines.append("")
            lines.append("## Key Points")
            for point in record.highlights {
                lines.append("- \(point)")
            }
        }

        lines.append("")
        lines.append("_Saved for follow-up questions._")
        return lines.joined(separator: "\n")
    }

    private func selectHighlights(from lines: [String], focus: String?) -> [String] {
        let focusTokens = tokenize(focus ?? "")

        let ranked: [(line: String, score: Int)] = lines.enumerated().map { idx, line in
            var score = max(0, 6 - min(idx, 6)) // Prefer early, content-rich lines.
            if line.count >= 40 { score += 2 }
            if line.count <= 220 { score += 1 }

            if !focusTokens.isEmpty {
                let lineTokens = Set(tokenize(line))
                let overlap = lineTokens.intersection(Set(focusTokens)).count
                score += overlap * 3
            }

            return (line, score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.line.count < rhs.line.count
        }

        var selected: [String] = []
        for candidate in ranked {
            let line = candidate.line
            guard !selected.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) else { continue }
            selected.append(line)
        }
        return selected
    }

    private func buildChunks(from lines: [String], focus: String?) -> [String] {
        guard !lines.isEmpty else { return [] }
        let focusTokens = Set(tokenize(focus ?? ""))
        let maxChunkChars = 680
        let maxChunks = 320
        var chunks: [String] = []
        var current = ""

        func flushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            chunks.append(trimmed)
            current = ""
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if current.isEmpty {
                current = trimmed
                continue
            }
            if current.count + 1 + trimmed.count <= maxChunkChars {
                current += " " + trimmed
            } else {
                flushCurrent()
                current = trimmed
            }
        }
        flushCurrent()

        var deduped: [String] = []
        var seen: Set<String> = []
        for chunk in chunks {
            let key = chunk.lowercased()
            if seen.insert(key).inserted {
                deduped.append(chunk)
            }
        }

        let ranked = deduped.map { chunk -> (String, Int) in
            let tokens = Set(tokenize(chunk))
            let overlap = focusTokens.isEmpty ? 0 : tokens.intersection(focusTokens).count
            let score = overlap * 3 + min(6, chunk.count / 80)
            return (chunk, score)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.count > rhs.0.count
        }

        return ranked.prefix(maxChunks).map(\.0)
    }

    private func isBoilerplateLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let blocked = [
            "cookie", "privacy policy", "terms of service", "all rights reserved",
            "javascript", "sign in", "subscribe", "accept all", "manage preferences",
            "loading your experience", "this won't take long", "we're getting things ready",
            "we are getting things ready", "enable javascript", "please wait", "loading…",
            "loading ..."
        ]
        return blocked.contains { lower.contains($0) }
    }

    private func isLowValueLearningSummary(_ summary: String) -> Bool {
        let lower = summary.lowercased()
        let noiseSignals = [
            "loading your experience", "this won't take long", "we're getting things ready",
            "we are getting things ready", "enable javascript", "please wait", "checking your browser",
            "before you continue", "just a moment", "loading"
        ]
        let hitCount = noiseSignals.reduce(0) { partial, signal in
            partial + (lower.contains(signal) ? 1 : 0)
        }
        return hitCount >= 1
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 1 }
    }

    private func extractTitle(fromHTML html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<title[^>]*>(.*?)</title>") else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let titleRange = Range(match.range(at: 1), in: html) else { return nil }

        let title = decodeHTMLEntities(String(html[titleRange]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return title.isEmpty ? nil : String(title.prefix(120))
    }

    private func extractVisibleText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<noscript[^>]*>.*?</noscript>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<!--.*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</(p|div|section|article|li|h[1-6]|tr)>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
        text = decodeHTMLEntities(text)
        return normalizeText(text)
    }

    private func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    private func buildPromptPayload(slot: String, spoken: String, formatted: String) -> OutputItem {
        let payload: [String: Any] = [
            "kind": "prompt",
            "slot": slot,
            "spoken": spoken,
            "formatted": formatted
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: spoken)
    }

    private static func defaultFetch(url: URL) -> FetchResult? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "GET"
        request.setValue("SamOS/1.0 (website-learning)", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var output: FetchResult?

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data = data else { return }

            let body = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
            guard let body else { return }

            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            output = FetchResult(body: body, contentType: contentType)
        }.resume()

        _ = semaphore.wait(timeout: .now() + 12)
        return output
    }

}

struct AutonomousLearnTool: Tool {
    let name = "autonomous_learn"
    let description = "Start a timed autonomous learning session. Sam researches across the internet, asks OpenAI for what to learn next, saves useful lessons, and reports what was learned when finished. Args: optional 'minutes' (default 5), optional 'topic'."

    private let controller: AutonomousLearningControlling

    init(controller: AutonomousLearningControlling = AutonomousLearningService.shared) {
        self.controller = controller
    }

    func execute(args: [String: String]) -> OutputItem {
        let minutes = max(1, Int(args["minutes"] ?? "5") ?? 5)
        let topic = args["topic"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = controller.startSession(minutes: minutes, topic: topic)

        let spoken: String
        var lines: [String] = []

        if result.started {
            spoken = "Great, I will learn independently and report back when I finish."
            lines.append("# Autonomous Learning Started")
            lines.append("")
            if let topic = topic, !topic.isEmpty {
                lines.append("- Topic: \(topic)")
            } else {
                lines.append("- Topic: General high-value learning")
            }
            lines.append("- Duration: \(minutes) minute\(minutes == 1 ? "" : "s")")
            if let finish = result.expectedFinishAt {
                lines.append("- Expected finish: \(formatDate(finish))")
            }
            lines.append("")
            lines.append("I will post a summary of what I learned as soon as the session completes.")
        } else {
            spoken = "I am already in an active learning session."
            lines.append("# Autonomous Learning Already Running")
            lines.append("")
            lines.append("- Status: Active")
            if let finish = result.expectedFinishAt {
                lines.append("- Expected finish: \(formatDate(finish))")
            }
            lines.append("")
            lines.append(result.message)
        }

        let payload: [String: Any] = [
            "kind": "autonomous_learn",
            "spoken": spoken,
            "formatted": lines.joined(separator: "\n")
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: lines.joined(separator: "\n"))
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct StopAutonomousLearnTool: Tool {
    let name = "stop_autonomous_learn"
    let description = "Stop the currently active autonomous learning session immediately."

    private let controller: AutonomousLearningControlling

    init(controller: AutonomousLearningControlling = AutonomousLearningService.shared) {
        self.controller = controller
    }

    func execute(args: [String: String]) -> OutputItem {
        let result = controller.stopActiveSession()
        let payload: [String: Any] = [
            "kind": "autonomous_learn_stop",
            "spoken": result.stopped
                ? "Okay, I stopped autonomous learning."
                : "There isn't an autonomous learning session running right now.",
            "formatted": result.message,
            "stopped": result.stopped,
            "session_id": result.sessionID?.uuidString as Any
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: result.message)
    }
}

struct GetTimeTool: Tool {
    let name = "get_time"
    let description = "Use ONLY for current time/date/timezone conversions. NOT for weather, forecasts, or rain. Args: 'timezone' (IANA ID, e.g. \"America/Chicago\"), 'place' (city/state, e.g. \"London\"). Example: \"Time in London\" -> get_time(place:\"London\")."

    /// Injectable date provider for testability. Defaults to `Date()`.
    var dateProvider: () -> Date = { Date() }

    /// Regions that span multiple timezones and require clarification.
    static let ambiguousRegions: Set<String> = [
        "america", "usa", "us", "u.s.", "u.s.a.", "united states",
        "united states of america", "the us", "the usa", "the states"
    ]

    func execute(args: [String: String]) -> OutputItem {
        let now = dateProvider()

        // 1. Explicit IANA timezone takes priority
        if let tzId = args["timezone"], let resolved = TimeZone(identifier: tzId) {
            let placeLabel = args["place"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let locationLabel = (placeLabel?.isEmpty == false ? placeLabel : tzId)
            return buildTimePayload(now: now, tz: resolved, locationLabel: locationLabel)
        }

        // 2. Place-based resolution
        if let place = args["place"]?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            let lower = place.lowercased()

            // Check if place is an ambiguous region
            if Self.ambiguousRegions.contains(lower) {
                return buildPromptPayload(
                    slot: "timezone",
                    spoken: "Which state or city in the US?",
                    formatted: "I need a specific state or city (e.g., Alabama, New York, Los Angeles)."
                )
            }

            // Try TimezoneMapping
            if let tzId = TimezoneMapping.lookup(place), let tz = TimeZone(identifier: tzId) {
                return buildTimePayload(now: now, tz: tz, locationLabel: place)
            }

            // Try as direct IANA identifier
            if let tz = TimeZone(identifier: place) {
                return buildTimePayload(now: now, tz: tz, locationLabel: place)
            }

            // Unknown place — prompt for clarification
            return buildPromptPayload(
                slot: "timezone",
                spoken: "I'm not sure which timezone \(place) is in. Could you give me a specific city name?",
                formatted: "Unknown place: \(place). Provide a city name or IANA timezone ID."
            )
        }

        // 3. No timezone or place — use device local timezone
        return buildTimePayload(now: now, tz: .current, locationLabel: nil)
    }

    // MARK: - Payload Builders

    private func buildTimePayload(now: Date, tz: TimeZone, locationLabel: String?) -> OutputItem {
        let spokenFormatter = DateFormatter()
        spokenFormatter.timeZone = tz
        spokenFormatter.dateFormat = "h:mm a"
        let spokenTime = spokenFormatter.string(from: now)
        let cleanedLocation = locationLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let locationSuffix: String
        if let cleanedLocation, !cleanedLocation.isEmpty {
            locationSuffix = " in \(cleanedLocation)"
        } else {
            locationSuffix = ""
        }
        let spoken = "It's \(spokenTime)\(locationSuffix)."

        let fullFormatter = DateFormatter()
        fullFormatter.timeZone = tz
        fullFormatter.dateStyle = .full
        fullFormatter.timeStyle = .short
        let formatted = fullFormatter.string(from: now)

        let timestamp = Int(now.timeIntervalSince1970)

        let payload: [String: Any] = [
            "kind": "time",
            "spoken": spoken,
            "formatted": formatted,
            "timestamp": timestamp,
            "location": cleanedLocation ?? ""
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: formatted)
    }

    private func buildPromptPayload(slot: String, spoken: String, formatted: String) -> OutputItem {
        let payload: [String: Any] = [
            "kind": "prompt",
            "slot": slot,
            "spoken": spoken,
            "formatted": formatted
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: spoken)
    }

    // MARK: - Payload Parsing

    /// Parses a structured get_time payload. Returns (spoken, formatted, timestamp) or nil.
    static func parsePayload(_ payload: String) -> (spoken: String, formatted: String, timestamp: Int)? {
        guard let data = payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spoken = dict["spoken"] as? String,
              let formatted = dict["formatted"] as? String,
              let timestamp = dict["timestamp"] as? Int
        else { return nil }
        return (spoken, formatted, timestamp)
    }

    /// Parses a prompt payload from get_time. Returns (slot, spoken, formatted) or nil.
    static func parsePromptPayload(_ payload: String) -> (slot: String, spoken: String, formatted: String)? {
        guard let data = payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = dict["kind"] as? String, kind == "prompt",
              let slot = dict["slot"] as? String,
              let spoken = dict["spoken"] as? String,
              let formatted = dict["formatted"] as? String
        else { return nil }
        return (slot, spoken, formatted)
    }
}

struct GetWeatherTool: Tool {
    let name = "get_weather"
    let description = "Use for weather and forecast questions: raining?, precipitation chance, temperature, wind, humidity, and warnings. Args: 'place' (required), optional 'days' (1-7), optional 'units' (C/F). Example: \"Is it raining in Melbourne?\" -> get_weather(place:\"Melbourne\"). Example: \"Weather in Greenbank today\" -> get_weather(place:\"Greenbank, QLD\")."

    private enum UnitPreference {
        case celsius
        case fahrenheit

        init(raw: String?) {
            let normalized = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            self = normalized == "F" ? .fahrenheit : .celsius
        }

        var symbol: String {
            switch self {
            case .celsius: return "C"
            case .fahrenheit: return "F"
            }
        }

        var apiTemperatureUnit: String {
            switch self {
            case .celsius: return "celsius"
            case .fahrenheit: return "fahrenheit"
            }
        }

        var apiWindUnit: String {
            switch self {
            case .celsius: return "kmh"
            case .fahrenheit: return "mph"
            }
        }

        var windSuffix: String {
            switch self {
            case .celsius: return "km/h"
            case .fahrenheit: return "mph"
            }
        }
    }

    private struct GeoLocation {
        let name: String
        let admin1: String?
        let country: String?
        let latitude: Double
        let longitude: Double
    }

    private struct WeatherSnapshot {
        let currentTemp: Double
        let currentHumidity: Double
        let currentPrecipitation: Double
        let currentWind: Double
        let currentCode: Int
        let isDay: Bool
        let dailyDates: [String]
        let dailyCode: [Int]
        let dailyTempMax: [Double]
        let dailyTempMin: [Double]
        let dailyRainChance: [Double]
        let dailyWindMax: [Double]
    }

    func execute(args: [String: String]) -> OutputItem {
        let rawPlace = args["place"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawPlace.isEmpty else {
            return buildPromptPayload(
                slot: "place",
                spoken: "Which city should I check the weather for?",
                formatted: "I need a city or town name to check weather."
            )
        }

        let days = max(1, min(7, Int(args["days"] ?? "1") ?? 1))
        let units = UnitPreference(raw: args["units"])

        guard let location = geocode(rawPlace) else {
            return OutputItem(
                kind: .markdown,
                payload: "I couldn't find that place for weather. Try a specific city, like `Melbourne, AU`."
            )
        }

        guard let weather = fetchWeather(for: location, days: days, units: units) else {
            return OutputItem(
                kind: .markdown,
                payload: "I couldn't fetch weather right now. Please try again in a moment."
            )
        }

        let spoken = buildSpokenSummary(location: location, weather: weather)
        let formatted = buildFormattedSummary(location: location, weather: weather, days: days, units: units)
        let payload: [String: Any] = [
            "kind": "weather",
            "spoken": spoken,
            "formatted": formatted,
            "timestamp": Int(Date().timeIntervalSince1970)
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }

        return OutputItem(kind: .markdown, payload: formatted)
    }

    private func geocode(_ place: String) -> GeoLocation? {
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        comps?.queryItems = [
            URLQueryItem(name: "name", value: place),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = comps?.url,
              let json = requestJSON(url: url) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let name = first["name"] as? String,
              let latitude = first["latitude"] as? Double,
              let longitude = first["longitude"] as? Double
        else { return nil }

        return GeoLocation(
            name: name,
            admin1: first["admin1"] as? String,
            country: first["country"] as? String,
            latitude: latitude,
            longitude: longitude
        )
    }

    private func fetchWeather(for location: GeoLocation, days: Int, units: UnitPreference) -> WeatherSnapshot? {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        comps?.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(days)),
            URLQueryItem(name: "temperature_unit", value: units.apiTemperatureUnit),
            URLQueryItem(name: "wind_speed_unit", value: units.apiWindUnit),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,precipitation,wind_speed_10m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max")
        ]
        guard let url = comps?.url,
              let json = requestJSON(url: url) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let daily = json["daily"] as? [String: Any],
              let currentTemp = current["temperature_2m"] as? Double,
              let currentHumidity = current["relative_humidity_2m"] as? Double,
              let currentPrecipitation = current["precipitation"] as? Double,
              let currentWind = current["wind_speed_10m"] as? Double,
              let currentCode = current["weather_code"] as? Int,
              let isDayInt = current["is_day"] as? Int
        else { return nil }

        let dailyDates = daily["time"] as? [String] ?? []
        let dailyCode = daily["weather_code"] as? [Int] ?? []
        let dailyTempMax = daily["temperature_2m_max"] as? [Double] ?? []
        let dailyTempMin = daily["temperature_2m_min"] as? [Double] ?? []
        let dailyRainChance = daily["precipitation_probability_max"] as? [Double] ?? []
        let dailyWindMax = daily["wind_speed_10m_max"] as? [Double] ?? []

        return WeatherSnapshot(
            currentTemp: currentTemp,
            currentHumidity: currentHumidity,
            currentPrecipitation: currentPrecipitation,
            currentWind: currentWind,
            currentCode: currentCode,
            isDay: isDayInt == 1,
            dailyDates: dailyDates,
            dailyCode: dailyCode,
            dailyTempMax: dailyTempMax,
            dailyTempMin: dailyTempMin,
            dailyRainChance: dailyRainChance,
            dailyWindMax: dailyWindMax
        )
    }

    private func buildSpokenSummary(location: GeoLocation, weather: WeatherSnapshot) -> String {
        let locationLabel = shortLocationLabel(location)
        let rainCodes: Set<Int> = [51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99]
        let rainingNow = weather.currentPrecipitation > 0.1 || rainCodes.contains(weather.currentCode)
        let chance = Int(weather.dailyRainChance.first ?? 0)

        if rainingNow {
            return "Yes — it's currently raining in \(locationLabel)."
        }
        if chance >= 50 {
            return "Not right now in \(locationLabel), but rain is likely later today (\(chance)% chance)."
        }
        return "No — it's not raining right now in \(locationLabel)."
    }

    private func buildFormattedSummary(location: GeoLocation, weather: WeatherSnapshot, days: Int, units: UnitPreference) -> String {
        let locationLabel = fullLocationLabel(location)
        let rainNow = weather.currentPrecipitation > 0.1 ? "Yes" : "No"
        let chanceToday = Int(weather.dailyRainChance.first ?? 0)
        let conditionNow = weatherDescription(code: weather.currentCode, isDay: weather.isDay)

        var lines: [String] = [
            "# Weather in \(locationLabel)",
            "",
            "- Condition: \(conditionNow)",
            String(format: "- Temperature: %.1f°%@", weather.currentTemp, units.symbol),
            String(format: "- Humidity: %.0f%%", weather.currentHumidity),
            String(format: "- Wind: %.1f %@", weather.currentWind, units.windSuffix),
            String(format: "- Rain now: %@ (%.1f mm)", rainNow, weather.currentPrecipitation),
            "- Rain chance today: \(chanceToday)%"
        ]

        let dayCount = min(days, weather.dailyDates.count)
        if dayCount > 0 {
            lines.append("")
            lines.append("## Forecast")
            for i in 0..<dayCount {
                let date = weather.dailyDates[safe: i] ?? "Day \(i + 1)"
                let code = weather.dailyCode[safe: i] ?? weather.currentCode
                let minTemp = weather.dailyTempMin[safe: i] ?? weather.currentTemp
                let maxTemp = weather.dailyTempMax[safe: i] ?? weather.currentTemp
                let rain = Int(weather.dailyRainChance[safe: i] ?? 0)
                let wind = weather.dailyWindMax[safe: i] ?? weather.currentWind
                let desc = weatherDescription(code: code, isDay: true)
                lines.append(String(
                    format: "- %@: %@, %.1f°%@ to %.1f°%@, rain %d%%, wind %.1f %@",
                    date, desc, minTemp, units.symbol, maxTemp, units.symbol, rain, wind, units.windSuffix
                ))
            }
        }

        return lines.joined(separator: "\n")
    }

    private func weatherDescription(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "Clear" : "Clear night"
        case 1, 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing rain"
        case 71, 73, 75: return "Snow"
        case 77: return "Snow grains"
        case 80, 81, 82: return "Rain showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Unknown conditions"
        }
    }

    private func shortLocationLabel(_ location: GeoLocation) -> String {
        if let admin = location.admin1, !admin.isEmpty {
            return "\(location.name), \(admin)"
        }
        return location.name
    }

    private func fullLocationLabel(_ location: GeoLocation) -> String {
        var parts = [location.name]
        if let admin = location.admin1, !admin.isEmpty { parts.append(admin) }
        if let country = location.country, !country.isEmpty { parts.append(country) }
        return parts.joined(separator: ", ")
    }

    private func requestJSON(url: URL) -> Any? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("SamOS/1.0 (weather)", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data = data else { return }
            resultData = data
        }.resume()

        _ = semaphore.wait(timeout: .now() + 10)
        guard let data = resultData else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func buildPromptPayload(slot: String, spoken: String, formatted: String) -> OutputItem {
        let payload: [String: Any] = [
            "kind": "prompt",
            "slot": slot,
            "spoken": spoken,
            "formatted": formatted
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: spoken)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
