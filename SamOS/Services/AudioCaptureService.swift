import AVFoundation
import Foundation
import AppKit
import Vision
import CoreImage

/// Captures microphone audio with a lightweight tap (no conversion or file I/O in the callback).
/// After silence-based endpoint detection, converts accumulated samples to a 16 kHz mono PCM16 WAV offline.
final class AudioCaptureService {

    // MARK: - Callbacks

    var onSessionComplete: ((URL) -> Void)?
    var onError: ((Error) -> Void)?
    var onSpeechDetected: (() -> Void)?

    // MARK: - State

    private(set) var isCapturing = false

    // MARK: - Private

    private var engine: AVAudioEngine?
    private var hardwareFormat: AVAudioFormat?

    /// Raw Float32 samples from channel 0 at hardware sample rate.
    /// Only written by the tap callback; only read after the engine is stopped.
    private var capturedSamples: [Float] = []

    /// Whether we have detected speech (RMS above threshold) at least once.
    private var speechDetected = false
    /// Timestamp of the last buffer that was above the silence threshold.
    private var lastSpeechTime: Date?
    /// Guards against duplicate finishCapture calls from the tap.
    private var finishDispatched = false

    // MARK: - Errors

    enum CaptureError: Error, LocalizedError {
        case engineSetupFailed(String)
        case alreadyCapturing
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .engineSetupFailed(let msg): return "Audio engine setup failed: \(msg)"
            case .alreadyCapturing: return "Already capturing audio"
            case .conversionFailed: return "Failed to convert captured audio to WAV"
            }
        }
    }

    // MARK: - Public API

    func startCapture() throws {
        guard !isCapturing else { throw CaptureError.alreadyCapturing }

        // Safety net: ensure TTS is stopped before capture starts (dispatches to MainActor)
        Task { @MainActor in TTSService.shared.stopSpeaking() }

        speechDetected = false
        lastSpeechTime = nil
        finishDispatched = false
        capturedSamples = []

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0 else {
            throw CaptureError.engineSetupFailed("No audio input available")
        }
        self.hardwareFormat = hwFormat

        // Pre-allocate for ~30 seconds at hardware rate (avoids reallocations in the tap)
        capturedSamples.reserveCapacity(Int(hwFormat.sampleRate) * 30)

        let thresholdDB = M2Settings.silenceThresholdDB
        let silenceDurationMs = M2Settings.silenceDurationMs

        // Ultra-lightweight tap: only copies samples + computes RMS. No conversion, no file I/O.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.processTap(buffer, thresholdDB: thresholdDB, silenceDurationMs: silenceDurationMs)
        }

        try engine.start()
        isCapturing = true
    }

    /// Idempotent hard stop — removes tap, stops engine, releases resources.
    func stopEngineHard() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Stops capture. If `discard` is true, drops all captured audio.
    func stopCapture(discard: Bool = false) {
        guard isCapturing else { return }
        stopEngineHard()
        isCapturing = false
        speechDetected = false
        lastSpeechTime = nil
        finishDispatched = false
        if discard {
            capturedSamples = []
            hardwareFormat = nil
        }
    }

    // MARK: - Tap Callback (KEEP LIGHTWEIGHT — no allocations, no conversion, no file I/O, no logging)

    private func processTap(
        _ buffer: AVAudioPCMBuffer,
        thresholdDB: Float,
        silenceDurationMs: Int
    ) {
        guard let floatData = buffer.floatChannelData, buffer.frameLength > 0 else { return }

        let count = Int(buffer.frameLength)
        let samples = floatData[0]

        // Accumulate raw samples (channel 0 only)
        capturedSamples.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))

        // Fast RMS in dB
        var sumSquares: Float = 0
        for i in 0..<count {
            let s = samples[i]
            sumSquares += s * s
        }
        let rms = sqrtf(sumSquares / Float(count))
        let rmsDB: Float = rms > 0 ? 20 * log10f(rms) : -100

        if rmsDB > thresholdDB {
            if !speechDetected {
                speechDetected = true
                DispatchQueue.main.async { [weak self] in
                    self?.onSpeechDetected?()
                }
            }
            lastSpeechTime = Date()
        }

        // After speech detected, check for silence timeout
        if speechDetected, let lastSpeech = lastSpeechTime {
            let elapsed = Date().timeIntervalSince(lastSpeech) * 1000
            if elapsed >= Double(silenceDurationMs) && !finishDispatched {
                finishDispatched = true
                DispatchQueue.main.async { [weak self] in
                    self?.finishCapture()
                }
            }
        }
    }

    // MARK: - Finish Capture (main thread → offline conversion)

    private func finishCapture() {
        guard isCapturing else { return }

        // Stop engine first — guarantees no more tap callbacks after this returns
        stopCapture(discard: false)

        // Convert accumulated samples to WAV on a background thread
        let samples = capturedSamples
        let hwFormat = hardwareFormat
        capturedSamples = []

        let onComplete = onSessionComplete
        let onError = onError
        Task.detached(priority: .userInitiated) {
            do {
                let url = try AudioCaptureService.writeWAVOffline(samples: samples, hardwareFormat: hwFormat)
                await MainActor.run {
                    onComplete?(url)
                }
            } catch {
                await MainActor.run {
                    onError?(error)
                }
            }
        }
    }

    // MARK: - Offline WAV Conversion

    /// Converts hardware-rate Float32 samples to a 16 kHz mono PCM16 WAV file.
    /// Runs on a background thread — no audio engine required.
    static func writeWAVOffline(samples: [Float], hardwareFormat: AVAudioFormat?) throws -> URL {
        guard let hwFormat = hardwareFormat, !samples.isEmpty else {
            throw CaptureError.conversionFailed
        }

        // Source: mono Float32 at hardware sample rate
        let monoHWFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: monoHWFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        samples.withUnsafeBufferPointer { src in
            sourceBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)

        // Target: 16 kHz mono PCM16
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!

        guard let converter = AVAudioConverter(from: monoHWFormat, to: targetFormat) else {
            throw CaptureError.conversionFailed
        }

        let ratio = 16000.0 / hwFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(ceil(Double(samples.count) * ratio))
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount)!

        var inputProvided = false
        var convError: NSError?
        converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if inputProvided {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputProvided = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard convError == nil else { throw CaptureError.conversionFailed }

        // Write to temp WAV file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("samos_capture_\(UUID().uuidString).wav")
        let file = try AVAudioFile(
            forWriting: tempURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try file.write(from: outputBuffer)

        return tempURL
    }
}

struct CameraSceneDescription {
    let summary: String
    let labels: [String]
    let recognizedText: [String]
    let capturedAt: Date

    func markdown() -> String {
        let time = DateFormatter.localizedString(from: capturedAt, dateStyle: .none, timeStyle: .medium)
        var lines: [String] = [
            "# Camera View",
            "",
            "- Captured: \(time)",
            "",
            "## Summary",
            summary
        ]

        if !labels.isEmpty {
            lines.append("")
            lines.append("## Detected Labels")
            for label in labels {
                lines.append("- \(label)")
            }
        }

        if !recognizedText.isEmpty {
            lines.append("")
            lines.append("## Visible Text")
            for text in recognizedText {
                lines.append("- \(text)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

struct CameraLabelPrediction {
    let label: String
    let confidence: Float
}

struct CameraFacePresence {
    let count: Int
}

struct CameraFaceEnrollmentResult {
    enum Status {
        case success
        case invalidName
        case cameraOff
        case noFrame
        case noFaceDetected
        case unsupported
    }

    let status: Status
    let enrolledName: String?
    let samplesForName: Int
    let totalKnownNames: Int
    let capturedAt: Date?
}

struct CameraRecognizedFaceMatch {
    let name: String
    let confidence: Float
    let distance: Float
}

struct CameraFaceRecognitionResult {
    let capturedAt: Date
    let detectedFaces: Int
    let matches: [CameraRecognizedFaceMatch]
    let unknownFaces: Int
    let enrolledNames: [String]
}

struct CameraFrameAnalysis {
    let labels: [CameraLabelPrediction]
    let recognizedText: [String]
    let faces: CameraFacePresence
    let capturedAt: Date
}

protocol CameraVisionProviding: AnyObject {
    var isRunning: Bool { get }
    var latestFrameAt: Date? { get }
    func start() throws
    func stop()
    func latestPreviewImage() -> NSImage?
    func describeCurrentScene() -> CameraSceneDescription?
    func currentAnalysis() -> CameraFrameAnalysis?
    func enrollFace(name: String) -> CameraFaceEnrollmentResult
    func recognizeKnownFaces() -> CameraFaceRecognitionResult?
    func knownFaceNames() -> [String]
}

extension CameraVisionProviding {
    func currentAnalysis() -> CameraFrameAnalysis? { nil }
    func enrollFace(name: String) -> CameraFaceEnrollmentResult {
        _ = name
        return CameraFaceEnrollmentResult(
            status: .unsupported,
            enrolledName: nil,
            samplesForName: 0,
            totalKnownNames: 0,
            capturedAt: nil
        )
    }
    func recognizeKnownFaces() -> CameraFaceRecognitionResult? { nil }
    func knownFaceNames() -> [String] { [] }
}

enum CameraVisionError: LocalizedError {
    case unauthorized
    case noCameraDevice
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Camera access denied. Enable camera access in System Settings."
        case .noCameraDevice:
            return "No camera device is available."
        case .configurationFailed(let reason):
            return "Camera setup failed: \(reason)"
        }
    }
}

final class CameraVisionService: NSObject, CameraVisionProviding, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = CameraVisionService()

    var onFrameUpdated: ((NSImage, Date) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.samos.camera.session")
    private let outputQueue = DispatchQueue(label: "com.samos.camera.output")
    private let stateQueue = DispatchQueue(label: "com.samos.camera.state", attributes: .concurrent)
    private let recognitionQueue = DispatchQueue(label: "com.samos.camera.face.recognition")
    private let analysisQueue = DispatchQueue(label: "com.samos.camera.analysis.cache")
    private let profileStore: FaceProfileStore
    private let ciContext = CIContext()
    private let videoOutput = AVCaptureVideoDataOutput()

    private var didConfigure = false
    private var _isRunning = false
    private var latestImage: CGImage?
    private var latestPreview: NSImage?
    private var _latestFrameAt: Date?
    private var lastStoredAt = Date.distantPast
    private var enrolledFacePrints: [String: [VNFeaturePrintObservation]] = [:]
    private var enrolledFaceNames: [String: String] = [:]
    private var cachedAnalysis: CameraFrameAnalysis?
    private var cachedAnalysisAt: Date?
    private let faceRecognitionThreshold: Float = 0.36

    private override init() {
        self.profileStore = .shared
        super.init()
        restorePersistedFaceProfiles()
    }

    var isRunning: Bool {
        stateQueue.sync { _isRunning }
    }

    var latestFrameAt: Date? {
        stateQueue.sync { _latestFrameAt }
    }

    func latestPreviewImage() -> NSImage? {
        stateQueue.sync { latestPreview }
    }

    func start() throws {
        guard CameraPermission.currentStatus == .granted else {
            throw CameraVisionError.unauthorized
        }

        var startError: Error?
        sessionQueue.sync {
            do {
                try configureIfNeeded()
                if !session.isRunning {
                    session.startRunning()
                }
                setRunning(true)
            } catch {
                startError = error
            }
        }

        if let startError {
            throw startError
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.setRunning(false)
        }
    }

    func describeCurrentScene() -> CameraSceneDescription? {
        guard let analysis = currentAnalysis() else {
            return nil
        }

        let labels = analysis.labels
            .prefix(5)
            .map { "\($0.label) (\(Int(($0.confidence * 100).rounded()))%)" }
        let visibleText = analysis.recognizedText.prefix(3).map { $0 }

        let summary = buildSummary(
            labels: Array(labels),
            visibleText: Array(visibleText),
            faceCount: analysis.faces.count,
            capturedAt: analysis.capturedAt
        )
        return CameraSceneDescription(
            summary: summary,
            labels: Array(labels),
            recognizedText: Array(visibleText),
            capturedAt: analysis.capturedAt
        )
    }

    func currentAnalysis() -> CameraFrameAnalysis? {
        guard let snapshot = latestFrameSnapshot() else {
            return nil
        }
        let frame = snapshot.image
        let capturedAt = snapshot.capturedAt

        if let cached = analysisQueue.sync(execute: { () -> CameraFrameAnalysis? in
            guard let cachedAnalysis, let cachedAnalysisAt, cachedAnalysisAt == capturedAt else {
                return nil
            }
            return cachedAnalysis
        }) {
            return cached
        }

        let labels = classifyDetailed(frame).prefix(10).map { $0 }
        let text = recognizeText(frame).prefix(6).map { $0 }
        let faces = detectFaceCount(frame)

        let analysis = CameraFrameAnalysis(
            labels: Array(labels),
            recognizedText: Array(text),
            faces: CameraFacePresence(count: faces),
            capturedAt: capturedAt
        )
        analysisQueue.sync {
            cachedAnalysis = analysis
            cachedAnalysisAt = capturedAt
        }
        return analysis
    }

    func knownFaceNames() -> [String] {
        recognitionQueue.sync {
            enrolledFaceNames.values.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        }
    }

    func enrollFace(name: String) -> CameraFaceEnrollmentResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CameraFaceEnrollmentResult(
                status: .invalidName,
                enrolledName: nil,
                samplesForName: 0,
                totalKnownNames: knownFaceNames().count,
                capturedAt: nil
            )
        }
        guard isRunning else {
            return CameraFaceEnrollmentResult(
                status: .cameraOff,
                enrolledName: trimmed,
                samplesForName: 0,
                totalKnownNames: knownFaceNames().count,
                capturedAt: nil
            )
        }
        guard let snapshot = latestFrameSnapshot() else {
            return CameraFaceEnrollmentResult(
                status: .noFrame,
                enrolledName: trimmed,
                samplesForName: 0,
                totalKnownNames: knownFaceNames().count,
                capturedAt: nil
            )
        }
        let frame = snapshot.image
        let capturedAt = snapshot.capturedAt

        let faceSamples = extractFaceFeaturePrints(frame)
        guard let primary = faceSamples.max(by: { faceArea($0.boundingBox) < faceArea($1.boundingBox) }) else {
            return CameraFaceEnrollmentResult(
                status: .noFaceDetected,
                enrolledName: trimmed,
                samplesForName: 0,
                totalKnownNames: knownFaceNames().count,
                capturedAt: capturedAt
            )
        }

        let key = trimmed.lowercased()
        let counters = recognitionQueue.sync { () -> (samples: Int, total: Int) in
            var samples = enrolledFacePrints[key] ?? []
            samples.append(primary.observation)
            if samples.count > 12 {
                samples = Array(samples.suffix(12))
            }
            enrolledFacePrints[key] = samples
            enrolledFaceNames[key] = trimmed
            return (samples.count, enrolledFaceNames.count)
        }
        persistFaceProfiles()

        return CameraFaceEnrollmentResult(
            status: .success,
            enrolledName: trimmed,
            samplesForName: counters.samples,
            totalKnownNames: counters.total,
            capturedAt: capturedAt
        )
    }

    func recognizeKnownFaces() -> CameraFaceRecognitionResult? {
        guard let snapshot = latestFrameSnapshot() else {
            return nil
        }
        let frame = snapshot.image
        let capturedAt = snapshot.capturedAt

        let samples = extractFaceFeaturePrints(frame)
        let registry = recognitionQueue.sync {
            (prints: enrolledFacePrints, names: enrolledFaceNames)
        }
        let enrolledNames = registry.names.values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        guard !samples.isEmpty else {
            return CameraFaceRecognitionResult(
                capturedAt: capturedAt,
                detectedFaces: 0,
                matches: [],
                unknownFaces: 0,
                enrolledNames: enrolledNames
            )
        }

        guard !registry.prints.isEmpty else {
            return CameraFaceRecognitionResult(
                capturedAt: capturedAt,
                detectedFaces: samples.count,
                matches: [],
                unknownFaces: samples.count,
                enrolledNames: enrolledNames
            )
        }

        var matches: [CameraRecognizedFaceMatch] = []
        var unknownCount = 0

        for sample in samples {
            guard let best = bestFaceMatch(
                for: sample.observation,
                registry: registry.prints,
                names: registry.names
            ) else {
                unknownCount += 1
                continue
            }

            if best.distance <= faceRecognitionThreshold {
                let confidence = max(0.0, min(1.0, 1.0 - (best.distance / faceRecognitionThreshold)))
                matches.append(
                    CameraRecognizedFaceMatch(
                        name: best.name,
                        confidence: confidence,
                        distance: best.distance
                    )
                )
            } else {
                unknownCount += 1
            }
        }

        return CameraFaceRecognitionResult(
            capturedAt: capturedAt,
            detectedFaces: samples.count,
            matches: matches.sorted { $0.confidence > $1.confidence },
            unknownFaces: unknownCount,
            enrolledNames: enrolledNames
        )
    }

    private func configureIfNeeded() throws {
        guard !didConfigure else { return }

        guard let camera = AVCaptureDevice.default(for: .video) else {
            throw CameraVisionError.noCameraDevice
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            session.beginConfiguration()

            if session.canSetSessionPreset(.vga640x480) {
                session.sessionPreset = .vga640x480
            }

            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw CameraVisionError.configurationFailed("Could not attach camera input.")
            }
            session.addInput(input)

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

            guard session.canAddOutput(videoOutput) else {
                session.commitConfiguration()
                throw CameraVisionError.configurationFailed("Could not attach camera output.")
            }
            session.addOutput(videoOutput)

            session.commitConfiguration()
            didConfigure = true
        } catch {
            throw CameraVisionError.configurationFailed(error.localizedDescription)
        }
    }

    private func setRunning(_ running: Bool) {
        stateQueue.async(flags: .barrier) {
            self._isRunning = running
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()

        let shouldStore = stateQueue.sync(flags: .barrier) { () -> Bool in
            guard now.timeIntervalSince(lastStoredAt) >= 0.25 else { return false }
            // Reserve this slot immediately to avoid duplicate frame admission between callbacks.
            lastStoredAt = now
            return true
        }
        guard shouldStore else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let preview = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        stateQueue.sync(flags: .barrier) {
            self.latestImage = cgImage
            self.latestPreview = preview
            self._latestFrameAt = now
        }
        analysisQueue.sync {
            self.cachedAnalysis = nil
            self.cachedAnalysisAt = nil
        }

        DispatchQueue.main.async { [weak self] in
            self?.onFrameUpdated?(preview, now)
        }
    }

    private func latestFrameSnapshot() -> (image: CGImage, capturedAt: Date)? {
        stateQueue.sync {
            guard let image = latestImage, let capturedAt = _latestFrameAt else {
                return nil
            }
            return (image, capturedAt)
        }
    }

    private func classifyDetailed(_ image: CGImage) -> [CameraLabelPrediction] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
            let observations = request.results ?? []
            return observations
                .filter { $0.confidence >= 0.22 }
                .prefix(8)
                .map { observation in
                    CameraLabelPrediction(
                        label: readableLabel(observation.identifier),
                        confidence: observation.confidence
                    )
                }
        } catch {
            return []
        }
    }

    private func recognizeText(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.03

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            return observations
                .compactMap { $0.topCandidates(1).first?.string }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
                .filter { !$0.allSatisfy({ $0.isWhitespace }) }
                .prefix(5)
                .map { String($0.prefix(80)) }
        } catch {
            return []
        }
    }

    private func readableLabel(_ raw: String) -> String {
        let first = raw.components(separatedBy: ",").first ?? raw
        let lower = first.replacingOccurrences(of: "_", with: " ").lowercased()
        return lower.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detectFaceCount(_ image: CGImage) -> Int {
        detectFaces(image).count
    }

    private struct FaceFeatureSample {
        let observation: VNFeaturePrintObservation
        let boundingBox: CGRect
    }

    private func extractFaceFeaturePrints(_ image: CGImage) -> [FaceFeatureSample] {
        let faces = detectFaces(image)
        guard !faces.isEmpty else { return [] }

        return faces.compactMap { face in
            guard let print = faceFeaturePrint(from: face, image: image) else { return nil }
            return FaceFeatureSample(observation: print, boundingBox: face.boundingBox)
        }
    }

    private func detectFaces(_ image: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            return request.results ?? []
        } catch {
            return []
        }
    }

    private func faceFeaturePrint(from face: VNFaceObservation, image: CGImage) -> VNFeaturePrintObservation? {
        let crop = denormalizedFaceRect(face.boundingBox, image: image)
        guard crop.width >= 24,
              crop.height >= 24,
              let cropped = image.cropping(to: crop) else {
            return nil
        }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            return nil
        }
    }

    private func denormalizedFaceRect(_ normalized: CGRect, image: CGImage) -> CGRect {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var rect = CGRect(
            x: normalized.origin.x * width,
            y: (1.0 - normalized.origin.y - normalized.height) * height,
            width: normalized.width * width,
            height: normalized.height * height
        )

        let paddingX = rect.width * 0.2
        let paddingY = rect.height * 0.2
        rect = rect.insetBy(dx: -paddingX, dy: -paddingY)
        rect.origin.x = max(0, rect.origin.x)
        rect.origin.y = max(0, rect.origin.y)
        rect.size.width = min(width - rect.origin.x, rect.width)
        rect.size.height = min(height - rect.origin.y, rect.height)

        return rect.integral
    }

    private func bestFaceMatch(
        for observation: VNFeaturePrintObservation,
        registry: [String: [VNFeaturePrintObservation]],
        names: [String: String]
    ) -> (name: String, distance: Float)? {
        var bestDistance = Float.greatestFiniteMagnitude
        var bestName: String?

        for (key, references) in registry {
            let resolvedName = names[key] ?? key
            for reference in references {
                var distance: Float = 0
                do {
                    try observation.computeDistance(&distance, to: reference)
                } catch {
                    continue
                }
                if distance < bestDistance {
                    bestDistance = distance
                    bestName = resolvedName
                }
            }
        }

        guard let bestName else { return nil }
        return (bestName, bestDistance)
    }

    private func faceArea(_ normalizedRect: CGRect) -> CGFloat {
        max(0, normalizedRect.width * normalizedRect.height)
    }

    private func persistFaceProfiles() {
        let snapshot = recognitionQueue.sync { () -> FaceProfileStore.Snapshot in
            let names = enrolledFaceNames
            let prints = enrolledFacePrints.mapValues { observations in
                observations.compactMap { archiveFeaturePrint($0) }
            }
            return FaceProfileStore.Snapshot(names: names, prints: prints)
        }
        _ = profileStore.save(snapshot)
    }

    private func restorePersistedFaceProfiles() {
        let snapshot = profileStore.load()
        guard !snapshot.prints.isEmpty || !snapshot.names.isEmpty else { return }

        var restoredPrints: [String: [VNFeaturePrintObservation]] = [:]
        var restoredNames: [String: String] = [:]

        for (key, dataList) in snapshot.prints {
            let observations = dataList.compactMap { unarchiveFeaturePrint($0) }
            guard !observations.isEmpty else { continue }
            restoredPrints[key] = observations
            if let display = snapshot.names[key] {
                restoredNames[key] = display
            } else {
                restoredNames[key] = key
            }
        }

        recognitionQueue.sync {
            enrolledFacePrints = restoredPrints
            enrolledFaceNames = restoredNames
        }
    }

    private func archiveFeaturePrint(_ observation: VNFeaturePrintObservation) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    private func unarchiveFeaturePrint(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    private func buildSummary(labels: [String], visibleText: [String], faceCount: Int, capturedAt: Date) -> String {
        var parts: [String] = []
        if !labels.isEmpty {
            let top = labels.prefix(3).joined(separator: ", ")
            parts.append("I can see \(top).")
        }
        if faceCount > 0 {
            let noun = faceCount == 1 ? "face" : "faces"
            parts.append("I can detect \(faceCount) \(noun).")
        }
        if !visibleText.isEmpty {
            parts.append("Visible text includes \"\(visibleText.joined(separator: "\", \""))\".")
        }
        if parts.isEmpty {
            parts.append("I can see a live camera frame, but I can't confidently identify specific details yet.")
        }

        let age = max(0, Int(Date().timeIntervalSince(capturedAt)))
        if age >= 3 {
            parts.append("This frame is about \(age) seconds old.")
        }

        return parts.joined(separator: " ")
    }
}
