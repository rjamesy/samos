import Foundation

/// OpenAI text-embedding-3-small client with in-memory LRU cache.
final class OpenAIEmbeddingClient: @unchecked Sendable {
    private let settings: any SettingsStoreProtocol
    private var cache: [String: [Float]] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheSize = 200
    private let lock = NSLock()

    init(settings: any SettingsStoreProtocol) {
        self.settings = settings
    }

    /// Generate an embedding vector for the given text.
    func embed(_ text: String) async throws -> [Float] {
        // Check cache
        lock.lock()
        if let cached = cache[text] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let apiKey = settings.string(forKey: SettingsKey.openaiAPIKey), !apiKey.isEmpty else {
            throw LLMError.apiKeyMissing
        }

        let url = URL(string: "https://api.openai.com/v1/embeddings")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": "text-embedding-3-small",
            "input": text
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LLMError.invalidResponse("Embedding API HTTP \(statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let first = dataArray.first,
              let embedding = first["embedding"] as? [Double] else {
            throw LLMError.invalidResponse("Could not parse embedding response")
        }

        let vector = embedding.map { Float($0) }

        // Cache the result
        lock.lock()
        if cache.count >= maxCacheSize, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cache[text] = vector
        cacheOrder.append(text)
        lock.unlock()

        return vector
    }

    /// Compute cosine similarity between two vectors.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }
}
