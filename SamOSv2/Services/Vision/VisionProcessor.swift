import Foundation
import Vision
import CoreImage

/// Processes camera frames using Apple Vision framework.
final class VisionProcessor: @unchecked Sendable {

    /// Classify objects in an image.
    func classifyImage(_ pixelBuffer: CVPixelBuffer) async throws -> [VNClassificationObservation] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    /// Detect text in an image.
    func recognizeText(_ pixelBuffer: CVPixelBuffer) async throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }

    /// Detect face rectangles.
    func detectFaces(_ pixelBuffer: CVPixelBuffer) async throws -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    /// Detect face landmarks for emotion analysis.
    func detectFaceLandmarks(_ pixelBuffer: CVPixelBuffer) async throws -> [VNFaceObservation] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    /// Generate image feature print for face comparison.
    func generateFeaturePrint(_ pixelBuffer: CVPixelBuffer) async throws -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        return request.results?.first
    }

    /// Build a scene description from classification results.
    func describeScene(_ observations: [VNClassificationObservation], maxItems: Int = 5) -> String {
        let top = observations
            .filter { $0.confidence > 0.1 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxItems)

        if top.isEmpty { return "I can see the camera view but can't identify specific objects." }

        let descriptions = top.map { "\($0.identifier) (\(Int($0.confidence * 100))%)" }
        return "I can see: " + descriptions.joined(separator: ", ")
    }
}
