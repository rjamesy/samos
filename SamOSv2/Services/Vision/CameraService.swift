import Foundation
import AVFoundation
import AppKit

/// Manages AVCaptureSession for camera access.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let queue = DispatchQueue(label: "com.samosv2.camera")
    private let lock = NSLock()
    private(set) var isRunning = false
    private var _latestFrame: CVPixelBuffer?

    var latestFrame: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return _latestFrame
    }

    func start() throws {
        guard !isRunning else { return }

        let session = AVCaptureSession()
        session.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw CameraError.noDevice
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(output)

        self.session = session
        self.videoOutput = output
        self.isRunning = true

        queue.async { session.startRunning() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.session?.stopRunning()
            self?.session = nil
            self?.isRunning = false
        }
    }

    func captureFrame() -> CVPixelBuffer? {
        latestFrame
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        _latestFrame = pixelBuffer
        lock.unlock()
    }

    // MARK: - Pixel Buffer → Base64 Helper

    static func pixelBufferToJPEGBase64(_ buffer: CVPixelBuffer, quality: CGFloat = 0.8) -> String? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return nil }
        return jpegData.base64EncodedString()
    }
}

enum CameraError: Error, LocalizedError {
    case noDevice
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noDevice: return "No camera device available"
        case .cannotAddInput: return "Cannot add camera input"
        case .cannotAddOutput: return "Cannot add camera output"
        }
    }
}
