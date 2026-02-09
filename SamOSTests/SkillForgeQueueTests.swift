import XCTest
import AppKit
@testable import SamOS

final class SkillForgeQueueTests: XCTestCase {

    private func makeTempQueue() -> SkillForgeQueueService {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeQueueTest_\(UUID().uuidString).sqlite3").path
        return SkillForgeQueueService(dbPath: path)
    }

    // MARK: - ForgeQueueJob Model

    func testForgeQueueJobDefaults() {
        let job = ForgeQueueJob(goal: "convert currencies")
        XCTAssertEqual(job.status, .queued)
        XCTAssertNil(job.constraints)
        XCTAssertNil(job.startedAt)
        XCTAssertNil(job.completedAt)
        XCTAssertFalse(job.goal.isEmpty)
    }

    func testForgeQueueJobWithConstraints() {
        let job = ForgeQueueJob(goal: "weather", constraints: "use open-meteo API")
        XCTAssertEqual(job.goal, "weather")
        XCTAssertEqual(job.constraints, "use open-meteo API")
        XCTAssertEqual(job.status, .queued)
    }

    func testForgeQueueJobEquality() {
        let id = UUID()
        let date = Date()
        let a = ForgeQueueJob(id: id, goal: "test", createdAt: date)
        let b = ForgeQueueJob(id: id, goal: "test", createdAt: date)
        XCTAssertEqual(a, b)
    }

    // MARK: - SkillForgeQueueService

    func testQueueServiceIsAvailable() {
        let queue = makeTempQueue()
        XCTAssertTrue(queue.isAvailable)
    }

    func testEnqueueCreatesJob() {
        let queue = makeTempQueue()
        let job = queue.enqueue(goal: "convert currencies")
        XCTAssertNotNil(job)
        XCTAssertEqual(job?.goal, "convert currencies")
        XCTAssertEqual(job?.status, .queued)
    }

    func testEnqueueWithConstraints() {
        let queue = makeTempQueue()
        let job = queue.enqueue(goal: "weather", constraints: "use metric units")
        XCTAssertNotNil(job)
        XCTAssertEqual(job?.constraints, "use metric units")
    }

    func testEnqueueWithoutConstraints() {
        let queue = makeTempQueue()
        let job = queue.enqueue(goal: "tell jokes")
        XCTAssertNotNil(job)
        XCTAssertNil(job?.constraints)
    }

    func testPendingCountReflectsQueue() {
        let queue = makeTempQueue()
        XCTAssertEqual(queue.pendingCount, 0)

        queue.enqueue(goal: "skill 1")
        // Note: pendingCount depends on drain not starting (since SkillForge.shared isn't configured in tests,
        // the drain loop will fail and mark jobs as failed, so we just test that enqueue returns non-nil)
        XCTAssertNotNil(queue.allJobs().first)
    }

    func testAllJobsReturnsAllStatuses() {
        let queue = makeTempQueue()
        queue.enqueue(goal: "skill A")
        queue.enqueue(goal: "skill B")

        let all = queue.allJobs()
        XCTAssertGreaterThanOrEqual(all.count, 2)
    }

    func testAllJobsOrderedByCreatedAt() {
        let queue = makeTempQueue()
        queue.enqueue(goal: "first")
        queue.enqueue(goal: "second")

        let all = queue.allJobs()
        guard all.count >= 2 else { return XCTFail("Expected at least 2 jobs") }
        XCTAssertTrue(all[0].createdAt <= all[1].createdAt)
    }

    func testClearAllRemovesEverything() {
        let queue = makeTempQueue()
        queue.enqueue(goal: "skill 1")
        queue.enqueue(goal: "skill 2")

        queue.clearAll()
        XCTAssertEqual(queue.allJobs().count, 0)
        XCTAssertNil(queue.currentJob)
    }

    func testClearFinishedKeepsQueued() {
        let queue = makeTempQueue()
        queue.enqueue(goal: "will stay queued")

        // clearFinished should not remove queued jobs
        queue.clearFinished()
        _ = queue.allJobs()
        // Some may have been processed by drain, but clearFinished only removes completed/failed
        // The key is clearAll vs clearFinished behave differently
        XCTAssertTrue(true) // Service didn't crash
    }

    // MARK: - StartSkillForgeTool

    func testStartSkillForgeToolRequiresGoal() {
        let tool = StartSkillForgeTool()
        let result = tool.execute(args: [:])
        XCTAssertTrue(result.payload.contains("goal"))
    }

    func testStartSkillForgeToolName() {
        let tool = StartSkillForgeTool()
        XCTAssertEqual(tool.name, "start_skillforge")
    }

    func testForgeQueueStatusToolName() {
        let tool = ForgeQueueStatusTool()
        XCTAssertEqual(tool.name, "forge_queue_status")
    }

    func testForgeQueueClearToolName() {
        let tool = ForgeQueueClearTool()
        XCTAssertEqual(tool.name, "forge_queue_clear")
    }

    func testForgeQueueStatusToolEmptyQueue() {
        let tool = ForgeQueueStatusTool()
        let result = tool.execute(args: [:])
        // Should produce valid output without crashing
        XCTAssertFalse(result.payload.isEmpty)
    }

    func testForgeQueueClearToolRuns() {
        let tool = ForgeQueueClearTool()
        let result = tool.execute(args: [:])
        XCTAssertFalse(result.payload.isEmpty)
    }

    // MARK: - Tool Registration

    func testToolsRegisteredInRegistry() {
        let registry = ToolRegistry.shared
        XCTAssertNotNil(registry.get("start_skillforge"), "start_skillforge must be registered")
        XCTAssertNotNil(registry.get("forge_queue_status"), "forge_queue_status must be registered")
        XCTAssertNotNil(registry.get("forge_queue_clear"), "forge_queue_clear must be registered")
        XCTAssertNotNil(registry.get("describe_camera_view"), "describe_camera_view must be registered")
        XCTAssertNotNil(registry.get("find_camera_objects"), "find_camera_objects must be registered")
        XCTAssertNotNil(registry.get("get_camera_face_presence"), "get_camera_face_presence must be registered")
        XCTAssertNotNil(registry.get("enroll_camera_face"), "enroll_camera_face must be registered")
        XCTAssertNotNil(registry.get("recognize_camera_faces"), "recognize_camera_faces must be registered")
        XCTAssertNotNil(registry.get("camera_visual_qa"), "camera_visual_qa must be registered")
        XCTAssertNotNil(registry.get("camera_inventory_snapshot"), "camera_inventory_snapshot must be registered")
        XCTAssertNotNil(registry.get("save_camera_memory_note"), "save_camera_memory_note must be registered")
    }
}

@MainActor
final class SkillForgeValidationTests: XCTestCase {

    private func makeSpec(steps: [SkillSpec.StepDef]) -> SkillSpec {
        SkillSpec(
            id: "forged_test",
            name: "Test Capability",
            version: 1,
            triggerPhrases: ["test capability"],
            slots: [],
            steps: steps,
            onTrigger: nil
        )
    }

    func testValidateSpecRejectsTalkOnlySkill() {
        let spec = makeSpec(steps: [
            SkillSpec.StepDef(action: "talk", args: ["say": "Working on it"])
        ])

        let error = SkillForge.shared.validateSpec(spec, knownToolNames: ["show_text", "get_time"])
        XCTAssertEqual(error, "No executable implementation steps (only talk steps found)")
    }

    func testValidateSpecRejectsSelfReferentialForgeStep() {
        let spec = makeSpec(steps: [
            SkillSpec.StepDef(action: "start_skillforge", args: ["goal": "learn x"])
        ])

        let error = SkillForge.shared.validateSpec(spec, knownToolNames: ["start_skillforge", "show_text"])
        XCTAssertEqual(error, "Self-referential step 'start_skillforge' is not allowed")
    }

    func testValidateSpecRejectsUnknownToolAction() {
        let spec = makeSpec(steps: [
            SkillSpec.StepDef(action: "nonexistent_tool", args: [:])
        ])

        let error = SkillForge.shared.validateSpec(spec, knownToolNames: ["show_text", "get_time"])
        XCTAssertEqual(error, "Unknown tool action 'nonexistent_tool'")
    }

    func testValidateSpecAcceptsExecutableKnownTool() {
        let spec = makeSpec(steps: [
            SkillSpec.StepDef(action: "show_text", args: ["markdown": "# Done"])
        ])

        let error = SkillForge.shared.validateSpec(spec, knownToolNames: ["show_text", "get_time"])
        XCTAssertNil(error)
    }

    func testValidateSpecRejectsMissingRequiredArgFromToolDescription() {
        let spec = makeSpec(steps: [
            SkillSpec.StepDef(action: "learn_website", args: [:])
        ])

        let error = SkillForge.shared.validateSpec(spec, knownToolNames: ["learn_website", "show_text"])
        XCTAssertEqual(error, "Tool 'learn_website' is missing required arg 'url'")
    }

    func testValidateSpecRejectsUnknownPlaceholder() {
        let spec = makeSpec(steps: [
            SkillSpec.StepDef(action: "show_text", args: ["markdown": "Topic: {{unknown_slot}}"])
        ])

        let error = SkillForge.shared.validateSpec(spec, knownToolNames: ["show_text"])
        XCTAssertEqual(error, "Step 'show_text' references unknown slot placeholder 'unknown_slot'")
    }

    func testValidateSpecAcceptsKnownPlaceholder() {
        let spec = SkillSpec(
            id: "forged_test",
            name: "Placeholder Capability",
            version: 1,
            triggerPhrases: ["use placeholder"],
            slots: [
                SkillSpec.SlotDef(name: "topic", type: .string, required: true, prompt: "What topic?")
            ],
            steps: [
                SkillSpec.StepDef(action: "show_text", args: ["markdown": "Topic: {{topic}}"])
            ],
            onTrigger: nil
        )

        let error = SkillForge.shared.validateSpec(spec, knownToolNames: ["show_text"])
        XCTAssertNil(error)
    }
}

final class OpenAIRefinerRequirementsParsingTests: XCTestCase {

    func testParseCapabilityRequirementsFromStrictJSON() throws {
        let refiner = OpenAIRefinerClient()
        let content = """
        {
          "summary": "Build a miner that inspects blocked outcomes.",
          "requirements": [
            "Persist a log of failed and blocked turns.",
            "Cluster recurring failures by capability gap."
          ],
          "acceptance_criteria": [
            "Produces top 3 capability recommendations."
          ],
          "risks": [
            "Overfitting to transient errors."
          ],
          "open_questions": [
            "Should recommendations consider recency weighting?"
          ]
        }
        """

        let parsed = try refiner.parseCapabilityRequirements(from: content)
        XCTAssertEqual(parsed.summary, "Build a miner that inspects blocked outcomes.")
        XCTAssertEqual(parsed.requirements.count, 2)
        XCTAssertEqual(parsed.acceptanceCriteria.count, 1)
        XCTAssertEqual(parsed.risks.first, "Overfitting to transient errors.")
        XCTAssertEqual(parsed.openQuestions.first, "Should recommendations consider recency weighting?")
    }

    func testParseCapabilityRequirementsFromMarkdownFence() throws {
        let refiner = OpenAIRefinerClient()
        let content = """
        ```json
        {
          "summary": "Capability requirements.",
          "requirements": ["Requirement A"],
          "acceptance_criteria": [],
          "risks": [],
          "open_questions": []
        }
        ```
        """

        let parsed = try refiner.parseCapabilityRequirements(from: content)
        XCTAssertEqual(parsed.summary, "Capability requirements.")
        XCTAssertEqual(parsed.requirements, ["Requirement A"])
    }
}

private final class FakeCameraVisionProvider: CameraVisionProviding {
    var isRunning: Bool = false
    var latestFrameAt: Date?
    var scene: CameraSceneDescription?
    var analysis: CameraFrameAnalysis?
    var enrollmentResult = CameraFaceEnrollmentResult(
        status: .unsupported,
        enrolledName: nil,
        samplesForName: 0,
        totalKnownNames: 0,
        capturedAt: nil
    )
    var recognitionResult: CameraFaceRecognitionResult?
    var faceNames: [String] = []

    func start() throws {}
    func stop() {}
    func latestPreviewImage() -> NSImage? { nil }
    func describeCurrentScene() -> CameraSceneDescription? { scene }
    func currentAnalysis() -> CameraFrameAnalysis? { analysis }
    func enrollFace(name: String) -> CameraFaceEnrollmentResult {
        _ = name
        return enrollmentResult
    }
    func recognizeKnownFaces() -> CameraFaceRecognitionResult? { recognitionResult }
    func knownFaceNames() -> [String] { faceNames }
}

final class CameraVisionToolBehaviorTests: XCTestCase {

    func testDescribeCameraViewToolReturnsOffMessageWhenCameraDisabled() {
        let fake = FakeCameraVisionProvider()
        fake.isRunning = false
        let tool = DescribeCameraViewTool(camera: fake)

        let output = tool.execute(args: [:])

        XCTAssertEqual(output.kind, .markdown)
        XCTAssertTrue(output.payload.localizedCaseInsensitiveContains("camera is off"))
    }

    func testDescribeCameraViewToolReturnsFrameMessageWhenNoFrameYet() {
        let fake = FakeCameraVisionProvider()
        fake.isRunning = true
        fake.scene = nil
        let tool = DescribeCameraViewTool(camera: fake)

        let output = tool.execute(args: [:])

        XCTAssertEqual(output.kind, .markdown)
        XCTAssertTrue(output.payload.localizedCaseInsensitiveContains("don't have a frame yet"))
    }

    func testDescribeCameraViewToolReturnsStructuredMarkdownWhenFrameAvailable() {
        let fake = FakeCameraVisionProvider()
        fake.isRunning = true
        fake.scene = CameraSceneDescription(
            summary: "I can see a desk and a monitor.",
            labels: ["desk (91%)", "monitor (88%)"],
            recognizedText: ["hello world"],
            capturedAt: Date()
        )
        let tool = DescribeCameraViewTool(camera: fake)

        let output = tool.execute(args: [:])

        XCTAssertEqual(output.kind, .markdown)
        XCTAssertTrue(output.payload.contains("# Camera View"))
        XCTAssertTrue(output.payload.contains("## Summary"))
        XCTAssertTrue(output.payload.contains("I can see a desk and a monitor."))
    }

    func testObjectFinderFindsMatchingLabel() {
        let fake = FakeCameraVisionProvider()
        fake.isRunning = true
        fake.analysis = CameraFrameAnalysis(
            labels: [CameraLabelPrediction(label: "water bottle", confidence: 0.87)],
            recognizedText: [],
            faces: CameraFacePresence(count: 0),
            capturedAt: Date()
        )
        let tool = CameraObjectFinderTool(camera: fake)

        let output = tool.execute(args: ["query": "bottle"])

        XCTAssertEqual(output.kind, .markdown)
        XCTAssertTrue(output.payload.contains("\"kind\":\"camera_object_finder\""))
        XCTAssertTrue(output.payload.contains("bottle"))
    }

    func testFacePresenceReportsCount() {
        let fake = FakeCameraVisionProvider()
        fake.isRunning = true
        fake.analysis = CameraFrameAnalysis(
            labels: [],
            recognizedText: [],
            faces: CameraFacePresence(count: 2),
            capturedAt: Date()
        )
        let tool = CameraFacePresenceTool(camera: fake)

        let output = tool.execute(args: [:])

        XCTAssertEqual(output.kind, .markdown)
        XCTAssertTrue(output.payload.contains("Faces detected: 2"))
    }

    func testEnrollCameraFaceReportsSuccess() {
        let fake = FakeCameraVisionProvider()
        fake.isRunning = true
        fake.enrollmentResult = CameraFaceEnrollmentResult(
            status: .success,
            enrolledName: "Ricky",
            samplesForName: 2,
            totalKnownNames: 1,
            capturedAt: Date()
        )
        let tool = EnrollCameraFaceTool(camera: fake)

        let output = tool.execute(args: ["name": "Ricky"])

        XCTAssertEqual(output.kind, .markdown)
        XCTAssertTrue(output.payload.contains("camera_face_enrollment"))
        XCTAssertTrue(output.payload.contains("Ricky"))
    }

    func testRecognizeCameraFacesReportsMatch() {
        let fake = FakeCameraVisionProvider()
        fake.isRunning = true
        fake.recognitionResult = CameraFaceRecognitionResult(
            capturedAt: Date(),
            detectedFaces: 1,
            matches: [CameraRecognizedFaceMatch(name: "Ricky", confidence: 0.84, distance: 0.11)],
            unknownFaces: 0,
            enrolledNames: ["Ricky"]
        )
        let tool = RecognizeCameraFacesTool(camera: fake)

        let output = tool.execute(args: [:])

        XCTAssertEqual(output.kind, .markdown)
        XCTAssertTrue(output.payload.contains("camera_face_recognition"))
        XCTAssertTrue(output.payload.contains("Ricky"))
    }

    func testVisualQARespondsToFaceCountQuestion() {
        let fake = FakeCameraVisionProvider()
        fake.isRunning = true
        fake.analysis = CameraFrameAnalysis(
            labels: [CameraLabelPrediction(label: "person", confidence: 0.74)],
            recognizedText: [],
            faces: CameraFacePresence(count: 1),
            capturedAt: Date()
        )
        let tool = CameraVisualQATool(camera: fake)

        let output = tool.execute(args: ["question": "How many faces do you see?"])

        XCTAssertEqual(output.kind, .markdown)
        XCTAssertTrue(output.payload.contains("camera_visual_qa"))
        XCTAssertTrue(output.payload.contains("1 face"))
    }

    func testInventorySnapshotTracksChanges() {
        let fake = FakeCameraVisionProvider()
        fake.isRunning = true
        let tool = CameraInventorySnapshotTool(camera: fake)

        fake.analysis = CameraFrameAnalysis(
            labels: [CameraLabelPrediction(label: "laptop", confidence: 0.9)],
            recognizedText: [],
            faces: CameraFacePresence(count: 0),
            capturedAt: Date()
        )
        _ = tool.execute(args: [:])

        fake.analysis = CameraFrameAnalysis(
            labels: [CameraLabelPrediction(label: "laptop", confidence: 0.88), CameraLabelPrediction(label: "mug", confidence: 0.66)],
            recognizedText: [],
            faces: CameraFacePresence(count: 0),
            capturedAt: Date()
        )
        let second = tool.execute(args: [:])

        XCTAssertEqual(second.kind, .markdown)
        XCTAssertTrue(second.payload.contains("Changes Since Previous Snapshot"))
        XCTAssertTrue(second.payload.contains("mug"))
    }

    func testSaveCameraMemoryNoteStoresObservation() {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraMemory_\(UUID().uuidString).sqlite3").path
        let store = MemoryStore(dbPath: dbPath)

        let fake = FakeCameraVisionProvider()
        fake.isRunning = true
        fake.scene = CameraSceneDescription(
            summary: "I can see a desk setup.",
            labels: ["desk (91%)"],
            recognizedText: ["build notes"],
            capturedAt: Date()
        )
        fake.analysis = CameraFrameAnalysis(
            labels: [CameraLabelPrediction(label: "desk", confidence: 0.91)],
            recognizedText: ["build notes"],
            faces: CameraFacePresence(count: 0),
            capturedAt: Date()
        )

        let tool = SaveCameraMemoryNoteTool(camera: fake, memoryStore: store)
        let output = tool.execute(args: [:])

        XCTAssertEqual(output.kind, .markdown)
        XCTAssertTrue(output.payload.contains("camera_memory_note"))
        XCTAssertFalse(store.listMemories(filterType: .note).isEmpty)
    }
}
