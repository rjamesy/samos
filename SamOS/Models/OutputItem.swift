import Foundation

struct OutputItem: Identifiable, Equatable {
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

enum OutputKind: String, Codable {
    case markdown
    case image
    case card
}
