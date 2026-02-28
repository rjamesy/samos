import Foundation

/// Describes what the camera currently sees.
struct DescribeCameraViewTool: Tool {
    let name = "describe_camera_view"
    let description = "Describe what the camera currently sees"
    let parameterDescription = "No args"
    let cameraService: CameraService?
    let visionProcessor: VisionProcessor?

    func execute(args: [String: String]) async -> ToolResult {
        guard let camera = cameraService, let vision = visionProcessor else {
            return .failure(tool: name, error: "Camera not available.")
        }
        guard camera.isRunning, let frame = camera.captureFrame() else {
            return .failure(tool: name, error: "Camera is not running. Enable it in settings.")
        }
        do {
            let observations = try await vision.classifyImage(frame)
            let description = vision.describeScene(observations)
            return .success(tool: name, spoken: description)
        } catch {
            return .failure(tool: name, error: "Vision analysis failed: \(error.localizedDescription)")
        }
    }
}

/// Finds specific objects in the camera view.
struct CameraObjectFinderTool: Tool {
    let name = "find_camera_objects"
    let description = "Find specific objects in the camera view"
    let parameterDescription = "Args: object|query (string)"
    let cameraService: CameraService?
    let visionProcessor: VisionProcessor?

    func execute(args: [String: String]) async -> ToolResult {
        let query = args["object"] ?? args["query"] ?? "objects"
        guard let camera = cameraService, let vision = visionProcessor else {
            return .failure(tool: name, error: "Camera not available.")
        }
        guard camera.isRunning, let frame = camera.captureFrame() else {
            return .failure(tool: name, error: "Camera is not running.")
        }
        do {
            let observations = try await vision.classifyImage(frame)
            let queryLower = query.lowercased()
            let matches = observations.filter { $0.identifier.lowercased().contains(queryLower) && $0.confidence > 0.05 }
            if matches.isEmpty {
                return .success(tool: name, spoken: "I don't see any \(query) in the camera view.")
            }
            let descriptions = matches.prefix(5).map { "\($0.identifier) (\(Int($0.confidence * 100))%)" }
            return .success(tool: name, spoken: "Found: \(descriptions.joined(separator: ", ")).")
        } catch {
            return .failure(tool: name, error: "Search failed: \(error.localizedDescription)")
        }
    }
}

/// Checks if a face is visible.
struct CameraFacePresenceTool: Tool {
    let name = "camera_face_presence"
    let description = "Check if a face is visible in the camera"
    let parameterDescription = "No args"
    let cameraService: CameraService?
    let visionProcessor: VisionProcessor?

    func execute(args: [String: String]) async -> ToolResult {
        guard let camera = cameraService, let vision = visionProcessor else {
            return .failure(tool: name, error: "Camera not available.")
        }
        guard camera.isRunning, let frame = camera.captureFrame() else {
            return .failure(tool: name, error: "Camera is not running.")
        }
        do {
            let faces = try await vision.detectFaces(frame)
            if faces.isEmpty {
                return .success(tool: name, spoken: "No faces detected.")
            }
            return .success(tool: name, spoken: "I can see \(faces.count) face\(faces.count == 1 ? "" : "s").")
        } catch {
            return .failure(tool: name, error: "Face detection failed: \(error.localizedDescription)")
        }
    }
}

/// Enrolls a face for recognition.
struct EnrollCameraFaceTool: Tool {
    let name = "enroll_camera_face"
    let description = "Enroll a face for future recognition"
    let parameterDescription = "Args: name (person's name)"
    let cameraService: CameraService?
    let visionProcessor: VisionProcessor?
    let faceEnrollment: FaceEnrollment?

    func execute(args: [String: String]) async -> ToolResult {
        let personName = args["name"] ?? args["person"] ?? ""
        guard !personName.isEmpty else {
            return .failure(tool: name, error: "No name provided for face enrollment")
        }
        guard let camera = cameraService, let vision = visionProcessor, let enrollment = faceEnrollment else {
            return .failure(tool: name, error: "Camera or face enrollment not available.")
        }
        guard camera.isRunning, let frame = camera.captureFrame() else {
            return .failure(tool: name, error: "Camera is not running.")
        }
        do {
            guard let featurePrint = try await vision.generateFeaturePrint(frame) else {
                return .failure(tool: name, error: "Could not generate face feature print.")
            }
            try await enrollment.enroll(name: personName, featurePrint: featurePrint)
            return .success(tool: name, spoken: "Face enrolled for \(personName).")
        } catch {
            return .failure(tool: name, error: "Enrollment failed: \(error.localizedDescription)")
        }
    }
}

/// Recognizes enrolled faces.
struct RecognizeCameraFacesTool: Tool {
    let name = "recognize_camera_faces"
    let description = "Recognize enrolled faces in the camera view"
    let parameterDescription = "No args"
    let cameraService: CameraService?
    let visionProcessor: VisionProcessor?
    let faceEnrollment: FaceEnrollment?

    func execute(args: [String: String]) async -> ToolResult {
        guard let camera = cameraService, let vision = visionProcessor, let enrollment = faceEnrollment else {
            return .failure(tool: name, error: "Camera or face recognition not available.")
        }
        guard camera.isRunning, let frame = camera.captureFrame() else {
            return .failure(tool: name, error: "Camera is not running.")
        }
        do {
            guard let featurePrint = try await vision.generateFeaturePrint(frame) else {
                return .success(tool: name, spoken: "No face detected to recognize.")
            }
            if let (matchName, confidence) = await enrollment.recognize(featurePrint: featurePrint) {
                return .success(tool: name, spoken: "I recognize \(matchName) (\(Int(confidence * 100))% confidence).")
            }
            return .success(tool: name, spoken: "I see a face but don't recognize them from my enrolled list.")
        } catch {
            return .failure(tool: name, error: "Recognition failed: \(error.localizedDescription)")
        }
    }
}

/// Visual Q&A on the camera view (escalates to GPT vision).
struct CameraVisualQATool: Tool {
    let name = "camera_visual_qa"
    let description = "Answer questions about what the camera sees"
    let parameterDescription = "Args: question (string)"
    let cameraService: CameraService?
    let gptVisionClient: GPTVisionClient?

    func execute(args: [String: String]) async -> ToolResult {
        let question = args["question"] ?? args["q"] ?? "What do you see?"
        guard let camera = cameraService, let gpt = gptVisionClient else {
            return .failure(tool: name, error: "Camera or GPT Vision not available.")
        }
        guard camera.isRunning, let frame = camera.captureFrame() else {
            return .failure(tool: name, error: "Camera is not running.")
        }
        guard let base64 = CameraService.pixelBufferToJPEGBase64(frame) else {
            return .failure(tool: name, error: "Could not encode camera frame.")
        }
        do {
            let answer = try await gpt.analyze(imageBase64: base64, prompt: question)
            return .success(tool: name, spoken: answer)
        } catch {
            return .failure(tool: name, error: "Visual Q&A failed: \(error.localizedDescription)")
        }
    }
}

/// Escalates to GPT for complex visual analysis.
struct CameraGPTVisionTool: Tool {
    let name = "camera_gpt_vision"
    let description = "Use GPT vision for complex visual analysis of the camera view"
    let parameterDescription = "Args: question|prompt (string)"
    let cameraService: CameraService?
    let gptVisionClient: GPTVisionClient?

    func execute(args: [String: String]) async -> ToolResult {
        let prompt = args["question"] ?? args["prompt"] ?? "Describe this scene in detail."
        guard let camera = cameraService, let gpt = gptVisionClient else {
            return .failure(tool: name, error: "Camera or GPT Vision not available.")
        }
        guard camera.isRunning, let frame = camera.captureFrame() else {
            return .failure(tool: name, error: "Camera is not running.")
        }
        guard let base64 = CameraService.pixelBufferToJPEGBase64(frame) else {
            return .failure(tool: name, error: "Could not encode camera frame.")
        }
        do {
            let analysis = try await gpt.analyze(imageBase64: base64, prompt: prompt)
            return .success(tool: name, spoken: analysis)
        } catch {
            return .failure(tool: name, error: "GPT vision analysis failed: \(error.localizedDescription)")
        }
    }
}

/// Detects emotions from facial expressions.
struct DetectEmotionsTool: Tool {
    let name = "detect_emotions"
    let description = "Detect emotions from facial expressions in the camera view"
    let parameterDescription = "No args"
    let cameraService: CameraService?
    let visionProcessor: VisionProcessor?
    let emotionDetector: EmotionDetector?

    func execute(args: [String: String]) async -> ToolResult {
        guard let camera = cameraService, let vision = visionProcessor, let detector = emotionDetector else {
            return .failure(tool: name, error: "Camera or emotion detection not available.")
        }
        guard camera.isRunning, let frame = camera.captureFrame() else {
            return .failure(tool: name, error: "Camera is not running.")
        }
        do {
            let faces = try await vision.detectFaceLandmarks(frame)
            if faces.isEmpty {
                return .success(tool: name, spoken: "No faces detected for emotion analysis.")
            }
            let emotions = detector.detectEmotions(from: faces)
            if let primary = emotions.first {
                let others = emotions.dropFirst().prefix(2).map { "\($0.emotion.rawValue) (\(Int($0.confidence * 100))%)" }
                var response = "Primary emotion: \(primary.emotion.rawValue) (\(Int(primary.confidence * 100))% confidence)."
                if !others.isEmpty {
                    response += " Also detecting: \(others.joined(separator: ", "))."
                }
                return .success(tool: name, spoken: response)
            }
            return .success(tool: name, spoken: "Could not determine emotions.")
        } catch {
            return .failure(tool: name, error: "Emotion detection failed: \(error.localizedDescription)")
        }
    }
}

/// Takes an inventory snapshot of visible objects.
struct CameraInventorySnapshotTool: Tool {
    let name = "camera_inventory_snapshot"
    let description = "Take an inventory snapshot of visible objects"
    let parameterDescription = "No args"
    let cameraService: CameraService?
    let visionProcessor: VisionProcessor?

    func execute(args: [String: String]) async -> ToolResult {
        guard let camera = cameraService, let vision = visionProcessor else {
            return .failure(tool: name, error: "Camera not available.")
        }
        guard camera.isRunning, let frame = camera.captureFrame() else {
            return .failure(tool: name, error: "Camera is not running.")
        }
        do {
            let observations = try await vision.classifyImage(frame)
            let items = observations
                .filter { $0.confidence > 0.05 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(15)
                .map { "\($0.identifier): \(Int($0.confidence * 100))%" }

            if items.isEmpty {
                return .success(tool: name, spoken: "No objects identified in the inventory snapshot.")
            }
            let inventory = items.joined(separator: ", ")
            return .success(tool: name, spoken: "Inventory snapshot: \(inventory).")
        } catch {
            return .failure(tool: name, error: "Inventory snapshot failed: \(error.localizedDescription)")
        }
    }
}

/// Saves a camera observation as a memory note.
struct SaveCameraMemoryNoteTool: Tool {
    let name = "save_camera_memory_note"
    let description = "Save a camera observation as a memory note"
    let parameterDescription = "Args: note (optional override text)"
    let cameraService: CameraService?
    let visionProcessor: VisionProcessor?
    let memoryStore: (any MemoryStoreProtocol)?

    func execute(args: [String: String]) async -> ToolResult {
        let noteOverride = args["note"] ?? args["text"]

        let noteContent: String
        if let override = noteOverride, !override.isEmpty {
            noteContent = override
        } else {
            // Auto-describe from camera
            guard let camera = cameraService, let vision = visionProcessor else {
                return .failure(tool: name, error: "Camera not available.")
            }
            guard camera.isRunning, let frame = camera.captureFrame() else {
                return .failure(tool: name, error: "Camera is not running.")
            }
            do {
                let observations = try await vision.classifyImage(frame)
                noteContent = "Camera observation: " + vision.describeScene(observations)
            } catch {
                return .failure(tool: name, error: "Could not describe scene: \(error.localizedDescription)")
            }
        }

        guard let store = memoryStore else {
            return .failure(tool: name, error: "Memory store not available.")
        }
        do {
            let _ = try await store.addMemory(type: .note, content: noteContent, source: "camera")
            return .success(tool: name, spoken: "Camera note saved.")
        } catch {
            return .failure(tool: name, error: "Failed to save note: \(error.localizedDescription)")
        }
    }
}
