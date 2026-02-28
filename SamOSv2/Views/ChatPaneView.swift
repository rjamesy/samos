import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ChatPaneView: View {
    @Environment(AppState.self) private var appState
    @State private var inputText = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var composerNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.chatMessages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if appState.isThinkingIndicatorVisible {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Thinking...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding()
                }
                .onChange(of: appState.chatMessages.count) { _, _ in
                    if let last = appState.chatMessages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Composer
            VStack(alignment: .leading, spacing: 8) {
                // Attachment strip
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                AttachmentChip(attachment: attachment) {
                                    removeAttachment(id: attachment.id)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }

                HStack(spacing: 8) {
                    // + menu
                    Menu {
                        Button("Upload File\u{2026}") {
                            pickFiles()
                        }
                        Button("Upload Photo\u{2026}") {
                            pickFiles(allowedTypes: [.image])
                        }
                        Button("Paste From Clipboard") {
                            attachFromClipboard()
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .help("Add files or photos")

                    TextField("Message Sam...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .onSubmit {
                            sendMessage()
                        }

                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                    handleDrop(providers)
                }

                if let composerNotice {
                    Text(composerNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Send

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let capped = String(text.prefix(AppConfig.maxChatMessageLength))
        let chatAttachments = buildChatAttachments()
        inputText = ""
        attachments.removeAll()
        composerNotice = nil
        let sendText = capped.isEmpty ? "Describe these attachments" : capped
        appState.send(sendText, attachments: chatAttachments)
    }

    private func buildChatAttachments() -> [ChatAttachment] {
        attachments.prefix(5).compactMap { pending in
            guard let data = try? Data(contentsOf: pending.url) else { return nil }
            let mime = Self.mimeType(for: pending.url)
            return ChatAttachment(filename: pending.displayName, mimeType: mime, data: data)
        }
    }

    // MARK: - File Picker

    private func pickFiles(allowedTypes: [UTType]? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let allowedTypes, !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes
        }
        if panel.runModal() == .OK {
            addAttachments(panel.urls)
        }
    }

    // MARK: - Clipboard

    private func attachFromClipboard() {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            addAttachments(urls)
            return
        }

        if let tiffData = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiffData),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("samos_clipboard_\(UUID().uuidString).png")
            do {
                try png.write(to: fileURL)
                addAttachments([fileURL])
            } catch {
                setComposerNotice("Couldn't attach clipboard image.")
            }
            return
        }

        setComposerNotice("Nothing attachable found in clipboard.")
    }

    // MARK: - Drag & Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        self.addAttachments([url])
                    }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    var imageData: Data?
                    if let data = item as? Data {
                        imageData = data
                    } else if let url = item as? URL {
                        imageData = try? Data(contentsOf: url)
                    }
                    guard let raw = imageData,
                          let image = NSImage(data: raw),
                          let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let png = bitmap.representation(using: .png, properties: [:]) else { return }
                    let fileURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("samos_drop_\(UUID().uuidString).png")
                    do {
                        try png.write(to: fileURL)
                        DispatchQueue.main.async {
                            self.addAttachments([fileURL])
                        }
                    } catch {}
                }
                handled = true
            }
        }
        return handled
    }

    // MARK: - Attachment Management

    private func addAttachments(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let existing = Set(attachments.map(\.normalizedPath))
        var added = 0
        for url in urls {
            let normalized = url.standardizedFileURL.path
            guard !existing.contains(normalized),
                  !attachments.contains(where: { $0.normalizedPath == normalized }) else {
                continue
            }
            guard attachments.count < 5 else {
                setComposerNotice("Max 5 attachments.")
                break
            }
            attachments.append(PendingAttachment(url: url))
            added += 1
        }
        if added > 0 {
            setComposerNotice("Attached \(added) item\(added == 1 ? "" : "s").")
        } else if attachments.count >= 5 {
            // already notified
        } else {
            setComposerNotice("Already attached.")
        }
    }

    private func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    private func setComposerNotice(_ text: String) {
        composerNotice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if self.composerNotice == text {
                self.composerNotice = nil
            }
        }
    }

    // MARK: - MIME Type

    private static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "txt": return "text/plain"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "md": return "text/markdown"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Pending Attachment

private struct PendingAttachment: Identifiable {
    let id = UUID()
    let url: URL
    var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
    var normalizedPath: String { url.standardizedFileURL.path }
    var icon: String {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()),
           type.conforms(to: .image) {
            return "photo"
        }
        return "doc"
    }
}

// MARK: - Attachment Chip

private struct AttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(attachment.displayName)
                .font(.caption)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(.controlBackgroundColor))
        .clipShape(Capsule())
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer() }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                // Image thumbnails
                if !message.attachments.filter(\.isImage).isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(message.attachments.filter(\.isImage), id: \.id) { att in
                                if let nsImage = NSImage(data: att.data) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 80, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                }

                Text(message.text)
                    .padding(10)
                    .background(message.role == .user ? Color.blue : Color(.controlBackgroundColor))
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if let latency = message.latencyMs {
                    Text("\(latency)ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 400, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .assistant { Spacer() }
        }
    }
}
