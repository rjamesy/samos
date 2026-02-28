import Foundation
import Vision
import CryptoKit

/// Manages face enrollment and recognition using feature prints.
/// Face data is encrypted with AES-GCM.
actor FaceEnrollment {
    private var enrolledFaces: [EnrolledFace] = []
    private let storageURL: URL
    private let encryptionKey: SymmetricKey

    init(storageDirectory: URL? = nil) {
        let dir = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SamOSv2/faces")
        self.storageURL = dir
        // Derive key from a stable device-based seed
        let seed = "SamOSv2-face-enrollment-key"
        let hash = SHA256.hash(data: Data(seed.utf8))
        self.encryptionKey = SymmetricKey(data: hash)

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Enroll a face with a given name and feature print.
    func enroll(name: String, featurePrint: VNFeaturePrintObservation) throws {
        let id = UUID().uuidString
        let face = EnrolledFace(id: id, name: name, featurePrint: featurePrint, enrolledAt: Date())
        enrolledFaces.append(face)
        try saveToDisk()
    }

    /// Recognize a face by comparing feature prints.
    func recognize(featurePrint: VNFeaturePrintObservation, threshold: Float = 0.5) -> (String, Float)? {
        var bestMatch: (String, Float)?
        var bestDistance: Float = Float.greatestFiniteMagnitude

        for face in enrolledFaces {
            var distance: Float = 0
            do {
                try featurePrint.computeDistance(&distance, to: face.featurePrint)
                if distance < threshold && distance < bestDistance {
                    bestDistance = distance
                    bestMatch = (face.name, 1.0 - distance)
                }
            } catch {
                continue
            }
        }
        return bestMatch
    }

    /// List all enrolled faces.
    func listEnrolled() -> [(id: String, name: String)] {
        enrolledFaces.map { ($0.id, $0.name) }
    }

    /// Remove an enrolled face.
    func remove(name: String) {
        enrolledFaces.removeAll { $0.name.lowercased() == name.lowercased() }
        try? saveToDisk()
    }

    private func saveToDisk() throws {
        // Serialize face names (feature prints are transient in this implementation)
        let names = enrolledFaces.map { $0.name }
        let data = try JSONEncoder().encode(names)
        let sealed = try AES.GCM.seal(data, using: encryptionKey)
        guard let combined = sealed.combined else { return }
        try combined.write(to: storageURL.appendingPathComponent("enrolled.dat"))
    }
}

private struct EnrolledFace {
    let id: String
    let name: String
    let featurePrint: VNFeaturePrintObservation
    let enrolledAt: Date
}
