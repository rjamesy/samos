import Foundation

/// The kind of content displayed on the output canvas.
enum OutputKind: String, Codable, Sendable {
    case markdown
    case image
    case card
}

/// A single item displayed on the output canvas.
struct OutputItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let ts: Date
    let kind: OutputKind
    let payload: String

    init(id: UUID = UUID(), ts: Date = Date(), kind: OutputKind, payload: String) {
        self.id = id
        self.ts = ts
        self.kind = kind
        self.payload = payload
    }
}
