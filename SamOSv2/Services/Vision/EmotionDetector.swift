import Foundation
import Vision

/// Detects emotions from facial landmarks using geometric analysis.
final class EmotionDetector {

    enum Emotion: String, CaseIterable {
        case happy, sad, angry, surprised, neutral, fearful, disgusted
    }

    struct EmotionResult {
        let emotion: Emotion
        let confidence: Float
    }

    /// Analyze emotions from face landmark observations.
    func detectEmotions(from faces: [VNFaceObservation]) -> [EmotionResult] {
        guard let face = faces.first, let landmarks = face.landmarks else {
            return [EmotionResult(emotion: .neutral, confidence: 0.5)]
        }

        var scores: [Emotion: Float] = [:]

        // Analyze mouth shape
        if let outerLips = landmarks.outerLips, let innerLips = landmarks.innerLips {
            let mouthOpenness = calculateMouthOpenness(outerLips: outerLips, innerLips: innerLips)
            let mouthWidth = calculateMouthWidth(outerLips: outerLips)

            if mouthOpenness > 0.15 && mouthWidth > 0.3 {
                scores[.happy] = Float(mouthOpenness + mouthWidth) * 0.8
            }
            if mouthOpenness > 0.25 {
                scores[.surprised] = Float(mouthOpenness) * 1.2
            }
            if mouthWidth < 0.15 {
                scores[.sad] = 0.6
            }
        }

        // Analyze eyebrow position
        if let leftBrow = landmarks.leftEyebrow, let rightBrow = landmarks.rightEyebrow {
            let browRaise = calculateBrowRaise(leftBrow: leftBrow, rightBrow: rightBrow)
            if browRaise > 0.1 {
                scores[.surprised, default: 0] += Float(browRaise) * 0.5
            }
        }

        // Analyze eye openness
        if let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye {
            let eyeOpenness = calculateEyeOpenness(leftEye: leftEye, rightEye: rightEye)
            if eyeOpenness > 0.15 {
                scores[.surprised, default: 0] += Float(eyeOpenness) * 0.3
            }
            if eyeOpenness < 0.05 {
                scores[.angry, default: 0] += 0.4
            }
        }

        // Default to neutral if no strong signals
        if scores.isEmpty {
            scores[.neutral] = 0.7
        }

        // Normalize and return sorted results
        let maxScore = scores.values.max() ?? 1.0
        return scores.map { EmotionResult(emotion: $0.key, confidence: $0.value / maxScore) }
            .sorted { $0.confidence > $1.confidence }
    }

    private func calculateMouthOpenness(outerLips: VNFaceLandmarkRegion2D, innerLips: VNFaceLandmarkRegion2D) -> Double {
        let outerPoints = outerLips.normalizedPoints
        let innerPoints = innerLips.normalizedPoints
        guard outerPoints.count >= 6, innerPoints.count >= 4 else { return 0 }

        let topOuter = Double(outerPoints[3].y)
        let bottomOuter = Double(outerPoints[9 % outerPoints.count].y)
        return abs(topOuter - bottomOuter)
    }

    private func calculateMouthWidth(outerLips: VNFaceLandmarkRegion2D) -> Double {
        let points = outerLips.normalizedPoints
        guard points.count >= 2 else { return 0 }
        let left = Double(points[0].x)
        let right = Double(points[points.count / 2].x)
        return abs(right - left)
    }

    private func calculateBrowRaise(leftBrow: VNFaceLandmarkRegion2D, rightBrow: VNFaceLandmarkRegion2D) -> Double {
        let leftPoints = leftBrow.normalizedPoints
        let rightPoints = rightBrow.normalizedPoints
        guard !leftPoints.isEmpty, !rightPoints.isEmpty else { return 0 }

        let leftAvgY = leftPoints.reduce(0.0) { $0 + Double($1.y) } / Double(leftPoints.count)
        let rightAvgY = rightPoints.reduce(0.0) { $0 + Double($1.y) } / Double(rightPoints.count)
        return (leftAvgY + rightAvgY) / 2.0
    }

    private func calculateEyeOpenness(leftEye: VNFaceLandmarkRegion2D, rightEye: VNFaceLandmarkRegion2D) -> Double {
        func eyeHeight(_ points: [CGPoint]) -> Double {
            guard points.count >= 4 else { return 0 }
            let top = Double(points[1].y)
            let bottom = Double(points[3 % points.count].y)
            return abs(top - bottom)
        }
        return (eyeHeight(leftEye.normalizedPoints) + eyeHeight(rightEye.normalizedPoints)) / 2.0
    }
}
