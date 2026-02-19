#if DEBUG
import SwiftUI

struct DebugPanelView: View {
    @ObservedObject private var store = DebugLogStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Text("Debug")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: { store.togglePause() }) {
                    Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10))
                        .foregroundColor(store.isPaused ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(store.isPaused ? "Resume Capture" : "Pause Capture")

                Button(action: copyText) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy as Text")

                Button(action: exportJSON) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy as JSON")

                Button(action: { store.clear() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Log")

                Text("\(store.entries.count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            // Affect / Tone snapshot
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "heart.text.square")
                        .font(.system(size: 9))
                        .foregroundColor(.pink)
                    Text("Affect:")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(store.latestAffect)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.primary)
                }
                if !store.latestToneProfile.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text("Tone:")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(store.latestToneProfile)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            Divider()

            // Category filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    FilterChip(label: "All", icon: "line.3.horizontal.decrease.circle",
                               isSelected: store.filterCategory == nil,
                               color: .secondary) {
                        store.filterCategory = nil
                    }
                    ForEach(DebugEntryCategory.allCases) { category in
                        FilterChip(label: category.shortLabel,
                                   icon: category.iconName,
                                   isSelected: store.filterCategory == category,
                                   color: category.tintColor) {
                            store.filterCategory = store.filterCategory == category ? nil : category
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }

            Divider()

            // Entry list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(store.filteredEntries) { entry in
                            DebugEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: store.entries.count) { _, _ in
                    guard !store.isPaused else { return }
                    if let last = store.filteredEntries.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func copyText() {
        let text = store.exportText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportJSON() {
        let json = store.exportJSON()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }
}

// MARK: - Debug Entry Row

private struct DebugEntryRow: View {
    let entry: DebugEntry
    @State private var isExpanded = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: entry.category.iconName)
                    .font(.system(size: 9))
                    .foregroundColor(entry.category.tintColor)
                    .frame(width: 12)

                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)

                Text(entry.title)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if let ms = entry.durationMs {
                    Text("\(ms)ms")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(3)
                }

                Spacer()
            }

            Text(entry.summary)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(isExpanded ? nil : 1)

            if isExpanded, let detail = entry.detail {
                Text(detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .textSelection(.enabled)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(entry.category == .error ? Color.red.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.detail != nil {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
        }
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isSelected ? color.opacity(0.8) : color.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}
#endif
