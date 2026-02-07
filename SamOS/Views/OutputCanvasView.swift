import SwiftUI
import AppKit

struct OutputCanvasView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Output Canvas")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                if !appState.outputItems.isEmpty {
                    Button("Clear") {
                        appState.outputItems.removeAll()
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(appState.outputItems) { item in
                            OutputItemView(item: item)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

// MARK: - Output Item View

struct OutputItemView: View {
    @EnvironmentObject var appState: AppState
    let item: OutputItem

    var body: some View {
        switch item.kind {
        case .markdown:
            MarkdownTextView(markdown: item.payload)
        case .card:
            if let cardType = parseCardType(item.payload), cardType == "alarm" {
                AlarmCardView(payload: item.payload)
                    .environmentObject(appState)
            } else {
                MarkdownTextView(markdown: item.payload)
            }
        case .image:
            ImageOutputView(payload: item.payload)
        }
    }

    private func parseCardType(_ payload: String) -> String? {
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

// MARK: - Markdown Rendering

struct MarkdownTextView: View {
    let markdown: String

    var body: some View {
        Text(attributedMarkdown)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
    }

    private var attributedMarkdown: AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(
            interpretedSyntax: .full
        ))) ?? AttributedString(markdown)
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
    @StateObject private var loader = ImageLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let decoded = decodePayload() {
                let candidateUrls = decoded.resolvedUrls.compactMap { URL(string: $0) }
                if !candidateUrls.isEmpty {
                    Group {
                        if let nsImage = loader.image {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .cornerRadius(8)
                        } else if loader.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 200)
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
                        }
                    }
                    .onAppear { loader.load(from: candidateUrls) }
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
    }

    func decodePayload() -> ImagePayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ImagePayload.self, from: data)
    }
}
