import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers

struct ChatPaneView: View {
    @EnvironmentObject var appState: AppState
    @State private var inputText = ""
    @State private var attachments: [ComposerAttachment] = []
    @State private var composerNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            // Transcript
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.chatMessages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }

                        if appState.isThinkingIndicatorVisible {
                            ThinkingIndicatorRow()
                                .id("thinking-indicator")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: appState.chatMessages.count) { _, _ in
                    if let last = appState.chatMessages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: appState.isThinkingIndicatorVisible) { _, visible in
                    guard visible else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("thinking-indicator", anchor: .bottom)
                    }
                }
            }

            if appState.pendingSlot != nil {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("Waiting for your reply\u{2026}")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Composer
            VStack(alignment: .leading, spacing: 8) {
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

                ZStack(alignment: .topLeading) {
                    ComposerTextView(text: $inputText) {
                        sendMessage()
                    }
                    .frame(minHeight: 44, maxHeight: 88)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.clear)

                    if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Ask Sam anything…")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .padding(.top, 14)
                            .padding(.leading, 12)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 10) {
                    Menu {
                        Button("Upload File…") {
                            pickFiles()
                        }
                        Button("Upload Photo…") {
                            pickFiles(allowedTypes: [.image])
                        }
                        Button("Paste From Clipboard") {
                            attachFromClipboard()
                        }

                        Divider()

                        Menu("Take Screenshot") {
                            Button("Selection To Clipboard") {
                                takeScreenshot(mode: .selection, target: .clipboard)
                            }
                            Button("Window To Clipboard") {
                                takeScreenshot(mode: .window, target: .clipboard)
                            }
                            Button("Full Screen To Clipboard") {
                                takeScreenshot(mode: .fullScreen, target: .clipboard)
                            }

                            Divider()

                            Button("Selection And Attach") {
                                takeScreenshot(mode: .selection, target: .attachment)
                            }
                            Button("Window And Attach") {
                                takeScreenshot(mode: .window, target: .attachment)
                            }
                            Button("Full Screen And Attach") {
                                takeScreenshot(mode: .fullScreen, target: .attachment)
                            }
                        }

                        Button("Take Photo") {
                            attachCurrentCameraPhoto()
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .help("Add files, photos, or screenshots")

                    Spacer()

                    Button(action: toggleListening) {
                        Image(systemName: appState.isListeningEnabled ? "mic.fill" : "mic")
                            .font(.callout)
                            .foregroundColor(appState.isListeningEnabled ? .accentColor : .secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(appState.isListeningEnabled ? "Stop Listening" : "Start Listening")

                    Button(action: { appState.toggleCamera() }) {
                        Image(systemName: appState.isCameraEnabled ? "video.fill" : "video.slash")
                            .font(.callout)
                            .foregroundColor(appState.isCameraEnabled ? .accentColor : .secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(appState.isCameraEnabled ? "Turn Camera Off" : "Turn Camera On")

                    Button(action: sendMessage) {
                        ZStack {
                            Circle()
                                .fill(canSend ? Color.black : Color.secondary.opacity(0.28))
                                .frame(width: 30, height: 30)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send")
                }

                if let composerNotice {
                    Text(composerNotice)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func sendMessage() {
        let text = composedMessage()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inputText = ""
        attachments.removeAll()
        composerNotice = nil
        appState.send(text)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private func composedMessage() -> String {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return trimmedInput }

        let lines = attachments.map { attachment in
            let path = attachment.url.path
            let label = attachment.displayName.replacingOccurrences(of: "\n", with: " ")
            return "- \(label): \(path)"
        }
        let attachmentBlock = "Attached items:\n" + lines.joined(separator: "\n")

        if trimmedInput.isEmpty {
            return attachmentBlock
        }
        return "\(trimmedInput)\n\n\(attachmentBlock)"
    }

    private func toggleListening() {
        if appState.isListeningEnabled {
            appState.stopListening()
        } else {
            appState.startListening()
        }
    }

    private func pickFiles(allowedTypes: [UTType]? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let allowedTypes, !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes
        }

        if panel.runModal() == .OK {
            addAttachments(panel.urls, source: .file)
        }
    }

    private func attachFromClipboard() {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            addAttachments(urls, source: .clipboard)
            return
        }

        if let tiffData = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiffData),
           let png = image.pngData {
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("samos_clipboard_\(UUID().uuidString).png")
            do {
                try png.write(to: fileURL)
                addAttachments([fileURL], source: .clipboard)
            } catch {
                setComposerNotice("Couldn't attach clipboard image.")
            }
            return
        }

        if let raw = pasteboard.string(forType: .string) {
            let clipped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clipped.isEmpty else {
                setComposerNotice("Clipboard is empty.")
                return
            }

            if FileManager.default.fileExists(atPath: clipped) {
                addAttachments([URL(fileURLWithPath: clipped)], source: .clipboard)
                return
            }

            if !inputText.isEmpty {
                inputText += "\n"
            }
            inputText += clipped
            setComposerNotice("Pasted text from clipboard.")
            return
        }

        setComposerNotice("Nothing attachable found in clipboard.")
    }

    private enum ScreenshotMode {
        case selection
        case window
        case fullScreen
    }

    private enum ScreenshotTarget {
        case clipboard
        case attachment
    }

    private func takeScreenshot(mode: ScreenshotMode, target: ScreenshotTarget) {
        let outputURL: URL? = {
            guard target == .attachment else { return nil }
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("samos_screenshot_\(UUID().uuidString).png")
        }()

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

            var args: [String] = []
            switch mode {
            case .selection:
                args.append("-i")
            case .window:
                args.append("-iw")
            case .fullScreen:
                break
            }

            if target == .clipboard {
                args.append("-c")
            } else if let outputURL {
                args.append(outputURL.path)
            }

            process.arguments = args

            do {
                try process.run()
                process.waitUntilExit()
                let success = process.terminationStatus == 0
                DispatchQueue.main.async {
                    if success {
                        if let outputURL, target == .attachment {
                            self.addAttachments([outputURL], source: .screenshot)
                        } else {
                            self.setComposerNotice("Screenshot copied to clipboard.")
                        }
                    } else {
                        self.setComposerNotice("Screenshot cancelled.")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.setComposerNotice("Couldn't start screenshot capture.")
                }
            }
        }
    }

    private func attachCurrentCameraPhoto() {
        if !appState.isCameraEnabled {
            appState.startCamera()
            setComposerNotice("Camera turned on. Tap Take Photo again in a moment.")
            return
        }

        guard let preview = appState.cameraPreviewImage,
              let png = preview.pngData else {
            setComposerNotice("No camera frame yet. Try again in a second.")
            return
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("samos_camera_photo_\(UUID().uuidString).png")
        do {
            try png.write(to: fileURL)
            addAttachments([fileURL], source: .camera)
        } catch {
            setComposerNotice("Couldn't save camera photo.")
        }
    }

    private func addAttachments(_ urls: [URL], source: ComposerAttachmentSource) {
        guard !urls.isEmpty else { return }

        let existing = Set(attachments.map(\.normalizedPath))
        var added = 0

        for url in urls {
            let normalized = url.standardizedFileURL.path
            guard !existing.contains(normalized),
                  !attachments.contains(where: { $0.normalizedPath == normalized }) else {
                continue
            }
            attachments.append(ComposerAttachment(url: url, source: source))
            added += 1
        }

        if added > 0 {
            setComposerNotice("Attached \(added) item\(added == 1 ? "" : "s").")
        } else {
            setComposerNotice("Those items are already attached.")
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
}

private enum ComposerAttachmentSource: String {
    case file
    case clipboard
    case screenshot
    case camera
}

private struct ComposerAttachment: Identifiable {
    let id: UUID
    let url: URL
    let source: ComposerAttachmentSource

    init(id: UUID = UUID(), url: URL, source: ComposerAttachmentSource) {
        self.id = id
        self.url = url
        self.source = source
    }

    var displayName: String {
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? url.path : name
    }

    var normalizedPath: String {
        url.standardizedFileURL.path
    }

    var icon: String {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()),
           type.conforms(to: .image) {
            return "photo"
        }
        return "doc"
    }
}

private struct AttachmentChip: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(attachment.displayName)
                .font(.caption)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(Capsule())
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = context.coordinator.onSubmit
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 2, height: 8)
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        let onSubmit: () -> Void
        weak var textView: SubmitTextView?

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self._text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
        }
    }
}

private final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn {
            let modifiers = event.modifierFlags.intersection([.shift, .option, .control, .command])
            if modifiers.isEmpty || modifiers == [.command] {
                onSubmit?()
                return
            }
        }
        super.keyDown(with: event)
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

struct ThinkingIndicatorRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Thinking…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .cornerRadius(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Thinking indicator")
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage
    @State private var copied = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(message.text)
                    .font(.body)
                    .padding(10)
                    .background(bubbleColor)
                    .foregroundColor(textColor)
                    .cornerRadius(12)
                    .opacity(message.isEphemeral ? 0.72 : 1.0)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Button(action: copyMessageText) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help(copied ? "Copied" : "Copy message")

                    if copied {
                        Text("Copied")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if message.llmProvider == .openai {
                    if let mode = message.assistantResponseMode {
                        Text(mode.shortLabel)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(mode.pipelineLabel)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("OpenAI")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if let latencyMs = message.latencyMs {
                    Text(latencyLabel(latencyMs))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if message.usedLocalKnowledge {
                    Text("Local knowledge used")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if message.usedMemory {
                    Text("Memory used")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Sam"
        case .system: return "System"
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant:
            if message.usedLocalKnowledge { return .blue.opacity(0.85) }
            if message.llmProvider == .openai { return .red.opacity(0.85) }
            return Color(nsColor: .controlBackgroundColor)
        case .system: return Color.yellow.opacity(0.2)
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user: return .white
        case .assistant where message.usedLocalKnowledge: return .white
        case .assistant where message.llmProvider == .openai: return .white
        default: return .primary
        }
    }

    private func latencyLabel(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000.0
        return String(format: "%.3fs (%dms)", seconds, max(0, ms))
    }

    private func copyMessageText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            copied = false
        }
    }
}
