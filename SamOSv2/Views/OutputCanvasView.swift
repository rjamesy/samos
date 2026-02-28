import SwiftUI

struct OutputCanvasView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if appState.outputItems.isEmpty {
                    ContentUnavailableView {
                        Label("Output Canvas", systemImage: "doc.richtext")
                    } description: {
                        Text("Tool results and rich content will appear here.")
                    }
                } else {
                    ForEach(appState.outputItems) { item in
                        outputView(for: item)
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func outputView(for item: OutputItem) -> some View {
        switch item.kind {
        case .markdown:
            Text(item.payload)
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

        case .image:
            if let url = URL(string: item.payload) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    case .failure:
                        Label("Failed to load image", systemImage: "exclamationmark.triangle")
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(maxHeight: 400)
            }

        case .card:
            VStack(alignment: .leading, spacing: 8) {
                Text(item.payload)
                    .textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 2)
        }
    }
}
