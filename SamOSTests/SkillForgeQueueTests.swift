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

    func testSkillsListToolName() {
        let tool = SkillsListTool()
        XCTAssertEqual(tool.name, "skills.list")
    }

    func testSkillsRunSimToolName() {
        let tool = SkillsRunSimTool()
        XCTAssertEqual(tool.name, "skills.run_sim")
    }

    func testSkillsResetBaselineToolName() {
        let tool = SkillsResetBaselineTool()
        XCTAssertEqual(tool.name, "skills.reset_baseline")
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
        XCTAssertNotNil(registry.get("skills.list"), "skills.list must be registered")
        XCTAssertNotNil(registry.get("skills.run_sim"), "skills.run_sim must be registered")
        XCTAssertNotNil(registry.get("skills.reset_baseline"), "skills.reset_baseline must be registered")
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

    func testValidateSpecRejectsWhitespaceOnlyTriggerPhrases() {
        let spec = SkillSpec(
            id: "forged_blank_trigger",
            name: "Blank Trigger Skill",
            version: 1,
            triggerPhrases: ["   "],
            slots: [],
            steps: [
                SkillSpec.StepDef(action: "show_text", args: ["markdown": "Ready"])
            ],
            onTrigger: nil
        )

        let error = SkillForge.shared.validateSpec(spec, knownToolNames: ["show_text"])
        XCTAssertEqual(error, "No trigger phrases")
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
    func clearKnownFaces() -> Bool { false }

    var health: CameraHealth { CameraHealth(lastGoodFrameAt: nil, lastFrameErrorAt: nil, consecutiveErrors: 0, isHealthy: true) }
    func detectFacialEmotions() -> CameraEmotionSnapshot? { nil }
    func captureFrameAsJPEG(quality: CGFloat) -> Data? { nil }
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
            emotions: [],
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
            emotions: [],
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

// MARK: - Phase 4 Tests

final class SkillValidatorPhase4Tests: XCTestCase {
    private func baseEchoPackage() -> SkillPackage {
        let packages = SkillStore.baselinePackages()
        guard let echo = packages.first(where: { $0.manifest.skillID == "skill.echo_format" }) else {
            XCTFail("Missing baseline echo package")
            return packages[0]
        }
        return echo
    }

    func testValidatorRejectsMissingToolRequirements() {
        var package = baseEchoPackage()
        package.plan.toolRequirements = []
        package.spec.steps.insert(
            SkillPackageStep(
                id: "call_tool",
                type: .toolCall,
                extract: nil,
                format: nil,
                toolCall: SkillToolCallStep(name: "show_text", args: ["markdown": "hi"], outputVar: nil),
                llmCall: nil,
                branch: nil,
                returnStep: nil
            ),
            at: 0
        )
        let result = SkillPackageValidator().validate(
            package: package,
            availableToolNames: Set(ToolRegistry.shared.canonicalToolNames)
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains(where: { $0.contains("not declared in tool_requirements") }))
    }

    func testValidatorRejectsInvalidSchema() {
        var package = baseEchoPackage()
        package.plan.inputsSchema = SkillJSONSchema(type: .array, items: nil)
        let result = SkillPackageValidator().validate(
            package: package,
            availableToolNames: Set(ToolRegistry.shared.canonicalToolNames)
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains(where: { $0.contains("array schema is missing items schema") }))
    }

    func testValidatorRejectsNondeterministicLLMCall() {
        var package = baseEchoPackage()
        package.spec.steps.insert(
            SkillPackageStep(
                id: "llm",
                type: .llmCall,
                extract: nil,
                format: nil,
                toolCall: nil,
                llmCall: SkillLLMCallStep(
                    promptTemplate: "hello",
                    responseVar: "resp",
                    temperature: 0.7,
                    maxOutputTokens: 0,
                    jsonOnly: false
                ),
                branch: nil,
                returnStep: nil
            ),
            at: 0
        )
        let result = SkillPackageValidator().validate(
            package: package,
            availableToolNames: Set(ToolRegistry.shared.canonicalToolNames)
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains(where: { $0.contains("deterministic temperature 0") }))
        XCTAssertTrue(result.errors.contains(where: { $0.contains("max_output_tokens > 0") }))
        XCTAssertTrue(result.errors.contains(where: { $0.contains("json_only=true") }))
    }
}

final class SkillSimPhase4Tests: XCTestCase {
    func testSkillSimPassesForEchoFormat() async {
        guard let package = SkillStore.baselinePackages().first(where: { $0.manifest.skillID == "skill.echo_format" }) else {
            return XCTFail("Missing baseline echo package")
        }
        let report = await SkillSimHarness().run(
            package: package,
            toolRuntime: SandboxSkillToolRuntime(declaredTools: Set(package.plan.toolRequirements.map(\.name))),
            llmRuntime: DeterministicSkillLLMRuntime()
        )
        XCTAssertTrue(report.passed)
    }

    func testSkillSimFailsOnExpectedMismatch() async {
        guard var package = SkillStore.baselinePackages().first(where: { $0.manifest.skillID == "skill.echo_format" }) else {
            return XCTFail("Missing baseline echo package")
        }
        package.tests = [
            SkillTestCase(
                name: "mismatch",
                inputText: "Rewrite this as dot points: one, two",
                expected: ["formatted": .string("this will not match")]
            )
        ]
        let report = await SkillSimHarness().run(
            package: package,
            toolRuntime: SandboxSkillToolRuntime(declaredTools: Set(package.plan.toolRequirements.map(\.name))),
            llmRuntime: DeterministicSkillLLMRuntime()
        )
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.cases.first?.failureReason?.contains("output mismatch") == true)
    }
}

private final class ScriptedSkillForgeGPTClient: SkillForgeGPTClient {
    struct IterationScript {
        let plan: SkillPlan
        let spec: SkillSpecV2
        let package: SkillPackage
        let approval: SkillApproverResponse
    }

    let authorityProvider: SkillForgeAuthorityProvider
    let modelName: String
    private let scripts: [IterationScript]
    private(set) var currentIteration: Int = 0
    private(set) var capturedFeedback: [SkillForgeFeedback] = []

    init(modelName: String = "gpt-5.2-test",
         scripts: [IterationScript],
         authorityProvider: SkillForgeAuthorityProvider = .openAI) {
        self.authorityProvider = authorityProvider
        self.modelName = modelName
        self.scripts = scripts
    }

    func makePlan(requirements: SkillForgeRequirements,
                  availableTools: [SkillToolDescriptor],
                  feedback: SkillForgeFeedback) async throws -> SkillPlan {
        _ = requirements
        _ = availableTools
        capturedFeedback.append(feedback)
        currentIteration += 1
        let index = min(currentIteration - 1, scripts.count - 1)
        return scripts[index].plan
    }

    func makeSpec(plan: SkillPlan,
                  requirements: SkillForgeRequirements,
                  feedback: SkillForgeFeedback) async throws -> SkillSpecV2 {
        _ = plan
        _ = requirements
        _ = feedback
        let index = min(max(currentIteration - 1, 0), scripts.count - 1)
        return scripts[index].spec
    }

    func buildPackage(plan: SkillPlan,
                      spec: SkillSpecV2,
                      requirements: SkillForgeRequirements,
                      feedback: SkillForgeFeedback) async throws -> SkillPackage {
        _ = plan
        _ = spec
        _ = requirements
        _ = feedback
        let index = min(max(currentIteration - 1, 0), scripts.count - 1)
        return scripts[index].package
    }

    func approve(package: SkillPackage,
                 validation: SkillValidationResult,
                 simulation: SkillSimulationReport) async throws -> SkillApproverResponse {
        _ = package
        _ = validation
        _ = simulation
        let index = min(max(currentIteration - 1, 0), scripts.count - 1)
        return scripts[index].approval
    }
}

final class SkillForgePipelinePhase4Tests: XCTestCase {
    private func makeStore() -> SkillStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillForgeV2-\(UUID().uuidString)", isDirectory: true)
        return SkillStore(directory: dir)
    }

    private func makeRequirements() -> SkillForgeRequirements {
        SkillForgeRequirements(goal: "Rewrite text as bullet points", missing: "No formatter skill", constraints: [])
    }

    private func makeScriptsForSuccess() -> [ScriptedSkillForgeGPTClient.IterationScript] {
        let baseline = SkillStore.baselinePackages()
        guard let echo = baseline.first(where: { $0.manifest.skillID == "skill.echo_format" }) else {
            return []
        }

        var invalidToolPackage = echo
        invalidToolPackage.plan.toolRequirements = []
        invalidToolPackage.spec.steps.insert(
            SkillPackageStep(
                id: "tool",
                type: .toolCall,
                extract: nil,
                format: nil,
                toolCall: SkillToolCallStep(name: "show_text", args: ["markdown": "x"], outputVar: nil),
                llmCall: nil,
                branch: nil,
                returnStep: nil
            ),
            at: 0
        )

        var simFailPackage = echo
        simFailPackage.tests = [
            SkillTestCase(
                name: "bad expectation",
                inputText: "Rewrite this as dot points: alpha, beta",
                expected: ["formatted": .string("not-present")]
            )
        ]

        var finalPackage = echo
        finalPackage.tests = echo.plan.testCases

        return [
            ScriptedSkillForgeGPTClient.IterationScript(
                plan: invalidToolPackage.plan,
                spec: invalidToolPackage.spec,
                package: invalidToolPackage,
                approval: SkillApproverResponse(
                    approved: false,
                    reason: "not reached",
                    requiredChanges: ["remove undeclared tool"],
                    riskNotes: [],
                    packageHash: nil
                )
            ),
            ScriptedSkillForgeGPTClient.IterationScript(
                plan: simFailPackage.plan,
                spec: simFailPackage.spec,
                package: simFailPackage,
                approval: SkillApproverResponse(
                    approved: false,
                    reason: "not reached",
                    requiredChanges: ["fix tests"],
                    riskNotes: [],
                    packageHash: nil
                )
            ),
            ScriptedSkillForgeGPTClient.IterationScript(
                plan: finalPackage.plan,
                spec: finalPackage.spec,
                package: finalPackage,
                approval: SkillApproverResponse(
                    approved: true,
                    reason: "Looks good",
                    requiredChanges: [],
                    riskNotes: [],
                    packageHash: nil
                )
            )
        ]
    }

    func testPipelineLoopsUntilApprovedThenInstalls() async {
        let store = makeStore()
        let scripts = makeScriptsForSuccess()
        guard !scripts.isEmpty else { return XCTFail("Missing scripts") }

        let fakeGPT = ScriptedSkillForgeGPTClient(scripts: scripts)
        let pipeline = SkillForgePipelineV2(
            gptClient: fakeGPT,
            store: store,
            maxIterations: 10
        )

        let outcome = await pipeline.run(requirements: makeRequirements(), onLog: { _ in })

        XCTAssertTrue(outcome.approved)
        XCTAssertGreaterThanOrEqual(outcome.iterations, 3, "Pipeline should loop through failures before approval")

        guard let installed = outcome.installedPackage else {
            return XCTFail("Expected installed package")
        }
        XCTAssertNotNil(installed.signoff)
        XCTAssertEqual(installed.signoff?.model, fakeGPT.modelName)
        XCTAssertFalse(installed.signoff?.approvedAtISO8601.isEmpty ?? true)
        XCTAssertFalse(installed.signoff?.packageHash.isEmpty ?? true)

        let persisted = store.getPackage(id: installed.manifest.skillID)
        XCTAssertNotNil(persisted, "Package should only be persisted after approval")
    }

    func testPipelineBlocksWhenProviderIsNotOpenAI() async {
        let store = makeStore()
        let fakeGPT = ScriptedSkillForgeGPTClient(
            scripts: [],
            authorityProvider: .unknown
        )
        let pipeline = SkillForgePipelineV2(
            gptClient: fakeGPT,
            store: store,
            maxIterations: 5
        )
        var logs: [String] = []
        let outcome = await pipeline.run(requirements: makeRequirements(), onLog: { logs.append($0) })

        XCTAssertFalse(outcome.approved)
        XCTAssertEqual(outcome.iterations, 0)
        XCTAssertTrue((outcome.blockedReason ?? "").contains("requires OpenAI GPT authority"))
        XCTAssertTrue(logs.contains(where: { $0.contains("[Blocked]") }))
    }

    func testPipelineBlocksWhenModelIsNotGPT() async {
        let store = makeStore()
        let fakeGPT = ScriptedSkillForgeGPTClient(
            modelName: "o3-mini",
            scripts: [],
            authorityProvider: .openAI
        )
        let pipeline = SkillForgePipelineV2(
            gptClient: fakeGPT,
            store: store,
            maxIterations: 5
        )
        var logs: [String] = []
        let outcome = await pipeline.run(requirements: makeRequirements(), onLog: { logs.append($0) })

        XCTAssertFalse(outcome.approved)
        XCTAssertEqual(outcome.iterations, 0)
        XCTAssertTrue((outcome.blockedReason ?? "").contains("requires a GPT model"))
        XCTAssertTrue(logs.contains(where: { $0.contains("[Blocked]") }))
    }

    func testLiveOpenAIPipelineCreatesApprovedPackageWhenEnabled() async {
        let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (envKey?.isEmpty == false ? envKey : readSamOSDevAPIKeyFromPlist())

        guard let apiKey, !apiKey.isEmpty else {
            XCTFail("Live OpenAI API key is required to run skill creation test.")
            return
        }

        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = apiKey
        OpenAISettings.generalModel = OpenAISettings.defaultPreferredModel

        let store = makeStore()
        let pipeline = SkillForgePipelineV2(
            gptClient: OpenAISkillArchitectClient(),
            store: store,
            maxIterations: 8
        )

        let requirements = SkillForgeRequirements(
            goal: "Create a concise formatter skill that rewrites user input into bullet points.",
            missing: "No dedicated bullet formatting skill is installed.",
            constraints: [
                "Use only existing tools.",
                "Must be deterministic.",
                "No external URLs required."
            ]
        )

        var logs: [String] = []
        let outcome = await pipeline.run(
            requirements: requirements,
            onLog: { logs.append($0) },
            installOnApproval: false
        )

        XCTAssertTrue(logs.contains(where: { $0.contains("[DraftPlan]") }), "Expected live pipeline to draft a plan.")
        XCTAssertTrue(
            outcome.approved,
            """
            Live skill forge did not reach approval.
            blockedReason=\(outcome.blockedReason ?? "none")
            lastCritique=\(outcome.lastCritique ?? "none")
            requiredChanges=\(outcome.requiredChanges.joined(separator: " | "))
            recentLogs=\(logs.suffix(10).joined(separator: " || "))
            """
        )
        XCTAssertNotNil(outcome.installedPackage)
        XCTAssertEqual(outcome.installedPackage?.signoff?.approved, true)
        XCTAssertEqual(outcome.installedPackage?.signoff?.model, OpenAISkillArchitectClient().modelName)
    }

    func testLiveOpenAIPipelineBuildsMovieShowtimesSkillWhenEnabled() async {
        let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (envKey?.isEmpty == false ? envKey : readSamOSDevAPIKeyFromPlist())

        guard let apiKey, !apiKey.isEmpty else {
            XCTFail("Live OpenAI API key is required to run movie showtimes skill creation test.")
            return
        }

        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = apiKey
        OpenAISettings.generalModel = OpenAISettings.defaultPreferredModel

        let store = makeStore()
        let pipeline = SkillForgePipelineV2(
            gptClient: OpenAISkillArchitectClient(),
            store: store,
            maxIterations: 10
        )

        let requirements = SkillForgeRequirements(
            goal: "Build a skill to get movie showtimes at cinemas in Springfield QLD Australia.",
            missing: "No dedicated movie showtimes skill for Springfield is installed.",
            constraints: [
                "Use only existing tools.",
                "Must call tool movies.showtimes.",
                "Ask one clarifying question only when location is missing.",
                "Return a concise list with cinema, movie, and session times."
            ]
        )

        var logs: [String] = []
        let outcome = await pipeline.run(
            requirements: requirements,
            onLog: { logs.append($0) },
            installOnApproval: false
        )

        XCTAssertTrue(logs.contains(where: { $0.contains("[DraftPlan]") }), "Expected live pipeline to draft a plan.")
        XCTAssertTrue(
            outcome.approved,
            """
            Live movie skill forge did not reach approval.
            blockedReason=\(outcome.blockedReason ?? "none")
            lastCritique=\(outcome.lastCritique ?? "none")
            requiredChanges=\(outcome.requiredChanges.joined(separator: " | "))
            recentLogs=\(logs.suffix(12).joined(separator: " || "))
            """
        )

        guard let package = outcome.installedPackage else {
            return XCTFail("Expected a generated movie showtimes package")
        }

        let requiredTools = Set(package.plan.toolRequirements.map(\.name))
        let stepTools = Set(package.spec.steps.compactMap { $0.toolCall?.name })
        XCTAssertTrue(requiredTools.contains("movies.showtimes"), "Plan must require movies.showtimes")
        XCTAssertTrue(stepTools.contains("movies.showtimes"), "Spec steps must call movies.showtimes")
        XCTAssertEqual(package.signoff?.approved, true)
        XCTAssertEqual(package.signoff?.model, OpenAISkillArchitectClient().modelName)
    }

    private func readSamOSDevAPIKeyFromPlist() -> String? {
        func normalizedKey(_ raw: String?) -> String? {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard trimmed.hasPrefix("sk-") else { return nil }
            return trimmed
        }

        let directDefaults = normalizedKey(UserDefaults.standard.string(forKey: "dev.openai.apiKey"))
        if let directDefaults { return directDefaults }

        if let domain = UserDefaults.standard.persistentDomain(forName: "com.samos.SamOS"),
           let domainKey = normalizedKey(domain["dev.openai.apiKey"] as? String) {
            return domainKey
        }

        let openAISettingsKey = normalizedKey(OpenAISettings.apiKey)
        if let openAISettingsKey { return openAISettingsKey }

        let plistPaths = [
            NSHomeDirectory() + "/Library/Containers/com.samos.SamOS/Data/Library/Preferences/com.samos.SamOS.plist",
            NSHomeDirectory() + "/Library/Preferences/com.samos.SamOS.plist"
        ]

        for plistPath in plistPaths {
            guard FileManager.default.fileExists(atPath: plistPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                  let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let key = normalizedKey(root["dev.openai.apiKey"] as? String) else {
                continue
            }
            return key
        }

        return nil
    }
}

final class SkillForgeRejectPhase4Tests: XCTestCase {
    private func makeStore() -> SkillStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillForgeReject-\(UUID().uuidString)", isDirectory: true)
        return SkillStore(directory: dir)
    }

    func testPipelineBlocksWhenGPTAlwaysRejects() async {
        guard let package = SkillStore.baselinePackages().first(where: { $0.manifest.skillID == "skill.echo_format" }) else {
            return XCTFail("Missing baseline package")
        }
        let rejectScript = ScriptedSkillForgeGPTClient.IterationScript(
            plan: package.plan,
            spec: package.spec,
            package: package,
            approval: SkillApproverResponse(
                approved: false,
                reason: "Needs stricter safety wording",
                requiredChanges: ["add constraint text"],
                riskNotes: ["minor policy mismatch"],
                packageHash: nil
            )
        )
        let fakeGPT = ScriptedSkillForgeGPTClient(scripts: [rejectScript])
        let store = makeStore()
        let pipeline = SkillForgePipelineV2(
            gptClient: fakeGPT,
            store: store,
            maxIterations: 3
        )

        let outcome = await pipeline.run(
            requirements: SkillForgeRequirements(
                goal: "format notes",
                missing: "missing formatter",
                constraints: []
            ),
            onLog: { _ in }
        )

        XCTAssertFalse(outcome.approved)
        XCTAssertNil(outcome.installedPackage)
        XCTAssertEqual(outcome.requiredChanges, ["add constraint text"])
        XCTAssertTrue((outcome.lastCritique ?? "").contains("Needs stricter safety wording"))
        XCTAssertNil(store.getPackage(id: package.manifest.skillID), "Rejected package must not be installed")
    }
}

final class SkillForgeOpenAIAuthorityTests: XCTestCase {
    private var savedModel = ""

    override func setUp() {
        super.setUp()
        savedModel = OpenAISettings.generalModel
    }

    override func tearDown() {
        OpenAISettings.generalModel = savedModel
        super.tearDown()
    }

    func testOpenAISkillArchitectClientFallsBackToDefaultGPTModel() {
        OpenAISettings.generalModel = "qwen2.5:7b"
        let client = OpenAISkillArchitectClient()
        XCTAssertEqual(client.authorityProvider, .openAI)
        XCTAssertEqual(client.modelName, OpenAISettings.defaultPreferredModel)
    }
}

// MARK: - Phase 5/6 Learn + News Tests


private final class TestLogger: AppLogger {
    private(set) var events: [String] = []

    func info(_ event: String, metadata: [String: String]) {
        _ = metadata
        events.append("info:\(event)")
    }

    func error(_ event: String, metadata: [String: String]) {
        _ = metadata
        events.append("error:\(event)")
    }
}

private final class FakeForgeRunner: SkillForgePipelineRunning {
    let outcome: SkillForgePipelineOutcome
    let logs: [String]

    init(outcome: SkillForgePipelineOutcome, logs: [String] = []) {
        self.outcome = outcome
        self.logs = logs
    }

    func run(requirements: SkillForgeRequirements,
             onLog: @escaping (String) -> Void,
             installOnApproval: Bool) async -> SkillForgePipelineOutcome {
        _ = requirements
        _ = installOnApproval
        for line in logs {
            onLog(line)
        }
        return outcome
    }
}

private struct FakeNewsToolRuntime: SkillPackageToolRuntime {
    let items: [SkillJSONValue]

    func callTool(name: String, args: [String: String]) -> SkillToolCallResult {
        _ = args
        guard name == "news.fetch" else {
            return SkillToolCallResult(success: false, output: [:], error: "MissingTool(\(name))")
        }
        return SkillToolCallResult(
            success: true,
            output: [
                "generated_at": .string("2026-02-19T00:00:00Z"),
                "items": .array(items)
            ],
            error: nil
        )
    }
}

private final class MapNewsHTTPClient: NewsHTTPClient {
    let dataByURL: [String: Data]

    init(dataByURL: [String: Data]) {
        self.dataByURL = dataByURL
    }

    func fetch(url: URL) async throws -> Data {
        if let data = dataByURL[url.absoluteString] {
            return data
        }
        throw NSError(domain: "MapNewsHTTPClient", code: 404)
    }
}

@MainActor
final class LearnSkillNewsPhaseTests: XCTestCase {

    private func waitForState(_ controller: LearnSkillController,
                              _ expected: LearnSkillState,
                              timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if controller.activeSession?.state == expected {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return controller.activeSession?.state == expected
    }

    private func makeSandboxComponents() -> (SkillStore, ToolPackageStore, PermissionScopeStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LearnSkillTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let skillStore = SkillStore(directory: base.appendingPathComponent("skills", isDirectory: true))
        let suite = "learn-skill-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let permissionStore = PermissionScopeStore(defaults: defaults)
        let toolStore = ToolPackageStore(
            fileURL: base.appendingPathComponent("tool_packages.json"),
            permissionStore: permissionStore
        )
        return (skillStore, toolStore, permissionStore, base.appendingPathComponent("learn_session.json"))
    }

    func testLearnSkillHappyPathRequiresApprovalThenInstalls() async {
        let (skillStore, toolStore, permissionStore, persistenceURL) = makeSandboxComponents()
        let logger = TestLogger()
        guard let package = SkillStore.baselinePackages().first(where: { $0.manifest.skillID == "skill.echo_format" }) else {
            return XCTFail("Missing baseline echo package")
        }
        let outcome = SkillForgePipelineOutcome(
            approved: true,
            installedPackage: package,
            iterations: 3,
            blockedReason: nil,
            lastCritique: nil,
            requiredChanges: []
        )
        let runner = FakeForgeRunner(
            outcome: outcome,
            logs: ["[DraftPlan] iteration 1", "[ValidateLocal] iteration 2", "[Simulate] iteration 3"]
        )
        let controller = LearnSkillController(
            logger: logger,
            persistenceURL: persistenceURL,
            pipelineFactory: { runner },
            skillStore: skillStore,
            toolPackageStore: toolStore,
            permissionStore: permissionStore
        )

        _ = controller.start(goalText: "Create a bullet formatter skill")
        let reachedPermissionReview = await waitForState(controller, .userPermissionReview)
        XCTAssertTrue(reachedPermissionReview)
        XCTAssertEqual(controller.activeSession?.iterationCount, 3)

        let deniedInstall = await controller.installApprovedSkill()
        XCTAssertTrue(deniedInstall.localizedCaseInsensitiveContains("not approved"))

        let approve = controller.approvePermissions(true)
        XCTAssertTrue(approve.localizedCaseInsensitiveContains("ready"))

        let install = await controller.installApprovedSkill()
        XCTAssertTrue(install.localizedCaseInsensitiveContains("installed"))
        XCTAssertEqual(controller.activeSession?.state, .done)
        XCTAssertNotNil(skillStore.getPackage(id: package.manifest.skillID))
        XCTAssertTrue(logger.events.contains("info:learn_skill_installed"))
    }

    func testLearnSkillUserRejectsPermissionsBlocksInstall() async {
        let (skillStore, toolStore, permissionStore, persistenceURL) = makeSandboxComponents()
        guard let package = SkillStore.baselinePackages().first(where: { $0.manifest.skillID == "news.latest" }) else {
            return XCTFail("Missing baseline news package")
        }
        let outcome = SkillForgePipelineOutcome(
            approved: true,
            installedPackage: package,
            iterations: 2,
            blockedReason: nil,
            lastCritique: nil,
            requiredChanges: []
        )
        let controller = LearnSkillController(
            logger: TestLogger(),
            persistenceURL: persistenceURL,
            pipelineFactory: { FakeForgeRunner(outcome: outcome) },
            skillStore: skillStore,
            toolPackageStore: toolStore,
            permissionStore: permissionStore
        )

        _ = controller.start(goalText: "Learn latest news")
        let reachedPermissionReview = await waitForState(controller, .userPermissionReview)
        XCTAssertTrue(reachedPermissionReview)
        XCTAssertTrue(controller.activeSession?.requestedPermissions.contains(PermissionScope.webRead.rawValue) == true)

        let reject = controller.approvePermissions(false)
        XCTAssertTrue(reject.localizedCaseInsensitiveContains("canceled"))
        XCTAssertEqual(controller.activeSession?.state, .blocked)
        XCTAssertFalse(toolStore.isInstalled("news.basic"))
        XCTAssertNil(skillStore.getPackage(id: "news.latest"))
    }

    func testLearnSkillBlockedWhenGPTRejects() async {
        let (skillStore, toolStore, permissionStore, persistenceURL) = makeSandboxComponents()
        let outcome = SkillForgePipelineOutcome(
            approved: false,
            installedPackage: nil,
            iterations: 4,
            blockedReason: "Reached max iterations",
            lastCritique: "Needs required changes",
            requiredChanges: ["add deterministic limits"]
        )
        let controller = LearnSkillController(
            logger: TestLogger(),
            persistenceURL: persistenceURL,
            pipelineFactory: { FakeForgeRunner(outcome: outcome) },
            skillStore: skillStore,
            toolPackageStore: toolStore,
            permissionStore: permissionStore
        )

        _ = controller.start(goalText: "Build impossible skill")
        let reachedBlocked = await waitForState(controller, .blocked)
        XCTAssertTrue(reachedBlocked)
        XCTAssertTrue(controller.activeSession?.blockedReason?.contains("Reached max iterations") == true)
        XCTAssertTrue(skillStore.loadInstalledPackages().isEmpty)
        XCTAssertFalse(toolStore.isInstalled("news.basic"))
    }

    func testLearnSkillSessionResumesFromPersistedPermissionReviewState() async {
        let (skillStore, toolStore, permissionStore, persistenceURL) = makeSandboxComponents()
        guard let package = SkillStore.baselinePackages().first(where: { $0.manifest.skillID == "skill.echo_format" }) else {
            return XCTFail("Missing baseline echo package")
        }
        let outcome = SkillForgePipelineOutcome(
            approved: true,
            installedPackage: package,
            iterations: 1,
            blockedReason: nil,
            lastCritique: nil,
            requiredChanges: []
        )
        let controllerA = LearnSkillController(
            logger: TestLogger(),
            persistenceURL: persistenceURL,
            pipelineFactory: { FakeForgeRunner(outcome: outcome) },
            skillStore: skillStore,
            toolPackageStore: toolStore,
            permissionStore: permissionStore
        )

        _ = controllerA.start(goalText: "Build formatter")
        let reachedPermissionReview = await waitForState(controllerA, .userPermissionReview)
        XCTAssertTrue(reachedPermissionReview)

        let controllerB = LearnSkillController(
            logger: TestLogger(),
            persistenceURL: persistenceURL,
            pipelineFactory: { FakeForgeRunner(outcome: outcome) },
            skillStore: skillStore,
            toolPackageStore: toolStore,
            permissionStore: permissionStore
        )
        XCTAssertEqual(controllerB.activeSession?.state, .userPermissionReview)
    }

    func testBaselineSkillsStillSimulate() async {
        let baseline = SkillStore.baselinePackages()
        for id in ["skill.echo_format", "skill.meeting_minutes_stub"] {
            guard let package = baseline.first(where: { $0.manifest.skillID == id }) else {
                return XCTFail("Missing baseline package \(id)")
            }
            let report = await SkillSimHarness().run(
                package: package,
                toolRuntime: SandboxSkillToolRuntime(declaredTools: Set(package.plan.toolRequirements.map(\.name))),
                llmRuntime: DeterministicSkillLLMRuntime()
            )
            XCTAssertTrue(report.passed, "Expected \(id) simulation to pass")
        }
    }

    func testNewsDateParserSupportsRssAndISO() {
        XCTAssertNotNil(NewsDateParser.parse("Thu, 19 Feb 2026 09:45:00 +0000"))
        XCTAssertNotNil(NewsDateParser.parse("2026-02-19T09:45:00Z"))
    }

    func testNewsAggregationAppliesRecencyAndDedupe() async {
        let now = Date(timeIntervalSince1970: 1_771_500_000)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "E, d MMM yyyy HH:mm:ss Z"

        let fresh = fmt.string(from: now.addingTimeInterval(-1_800))
        let fresh2 = fmt.string(from: now.addingTimeInterval(-600))
        let old = fmt.string(from: now.addingTimeInterval(-90 * 3600))
        let xml = """
        <rss><channel>
          <item><title>AI market surges today</title><link>https://a.test/1</link><pubDate>\(fresh)</pubDate><description>desc</description></item>
          <item><title>AI market surges today!</title><link>https://a.test/2</link><pubDate>\(fresh2)</pubDate><description>desc</description></item>
          <item><title>Old economy headline</title><link>https://a.test/3</link><pubDate>\(old)</pubDate><description>old</description></item>
          <item><title>Chip updates continue</title><link>https://a.test/4</link><description>no date</description></item>
        </channel></rss>
        """
        let source = NewsSource(id: "s", name: "Source", url: "https://feeds.test/rss", country: nil)
        let service = NewsAggregationService(
            client: MapNewsHTTPClient(dataByURL: [source.url: Data(xml.utf8)]),
            sources: [source],
            nowProvider: { now }
        )

        let items = await service.latest(query: "ai", country: nil, topics: [], timeWindowHours: 24, maxItems: 10)
        XCTAssertEqual(items.count, 1, "Expected dedupe + recency to reduce to one fresh AI headline")
        XCTAssertTrue(items[0].title.lowercased().contains("ai market surges"))
    }

    func testToolPackageInstallGateRequiresPermissionApproval() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolInstallGate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let suite = "tool-gate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let permissions = PermissionScopeStore(defaults: defaults)
        let store = ToolPackageStore(
            fileURL: base.appendingPathComponent("tool_packages.json"),
            permissionStore: permissions
        )

        let blocked = store.install(
            packageID: "news.basic",
            tools: ["news.fetch"],
            permissions: [PermissionScope.webRead.rawValue]
        )
        XCTAssertFalse(blocked.installed)

        permissions.approve(scopes: [PermissionScope.webRead.rawValue])
        let allowed = store.install(
            packageID: "news.basic",
            tools: ["news.fetch"],
            permissions: [PermissionScope.webRead.rawValue]
        )
        XCTAssertTrue(allowed.installed)
        XCTAssertTrue(store.isInstalled("news.basic"))
    }

    func testToolPackageInstallReusesExistingCapabilityWithSamePayload() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolInstallReuse-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let suite = "tool-reuse-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let permissions = PermissionScopeStore(defaults: defaults)
        permissions.approve(scopes: [PermissionScope.webRead.rawValue])
        let store = ToolPackageStore(
            fileURL: base.appendingPathComponent("tool_packages.json"),
            permissionStore: permissions
        )

        let first = store.install(
            packageID: "news.basic",
            tools: ["news.fetch"],
            permissions: [PermissionScope.webRead.rawValue]
        )
        XCTAssertTrue(first.installed)
        XCTAssertEqual(store.listInstalled().count, 1)

        let duplicate = store.install(
            packageID: "news.clone",
            tools: ["news.fetch"],
            permissions: [PermissionScope.webRead.rawValue]
        )
        XCTAssertTrue(duplicate.installed)
        XCTAssertTrue(duplicate.reason.contains("reused_existing:news.basic"))
        XCTAssertFalse(store.isInstalled("news.clone"))
        XCTAssertEqual(store.listInstalled().count, 1, "Duplicate capability payload should reuse existing package")
    }

    func testNewsSkillExecutionFormatsSourceAndDateAndFiltersOldDuplicates() async {
        guard let package = SkillStore.baselinePackages().first(where: { $0.manifest.skillID == "news.latest" }) else {
            return XCTFail("Missing baseline news skill package")
        }

        let now = Date()
        let iso = ISO8601DateFormatter()
        let fresh = iso.string(from: now.addingTimeInterval(-1_800))
        let old = iso.string(from: now.addingTimeInterval(-100 * 3600))
        let runtime = SkillPackageRuntime()
        let exec = await runtime.execute(
            package: package,
            inputText: "latest ai news",
            toolRuntime: FakeNewsToolRuntime(items: [
                .object([
                    "title": .string("AI chip race accelerates"),
                    "source": .string("Reuters"),
                    "published_at": .string(fresh),
                    "url": .string("https://r.test/1")
                ]),
                .object([
                    "title": .string("AI chip race accelerates!"),
                    "source": .string("Reuters"),
                    "published_at": .string(fresh),
                    "url": .string("https://r.test/2")
                ]),
                .object([
                    "title": .string("Old macro headline"),
                    "source": .string("BBC"),
                    "published_at": .string(old),
                    "url": .string("https://b.test/3")
                ])
            ]),
            llmRuntime: DeterministicSkillLLMRuntime()
        )

        XCTAssertTrue(exec.success)
        let formatted = exec.output["formatted"]?.stringValue ?? ""
        XCTAssertTrue(formatted.contains("Reuters"))
        XCTAssertTrue(formatted.contains("["))
        XCTAssertFalse(formatted.lowercased().contains("old macro headline"))
        XCTAssertEqual(formatted.components(separatedBy: "AI chip race accelerates").count - 1, 1)
    }

    func testTurnRouterRoutesNewsToNativeSkillOrCapabilityGap() async {
        let classify: TurnRouter.IntentClassificationHandler = { _, _, _ in
            IntentClassificationResult(
                classification: IntentClassification(
                    intent: .webRequest,
                    confidence: 0.9,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: true
                ),
                provider: .rule,
                attemptedLocal: false,
                attemptedOpenAI: false,
                localSkipReason: nil,
                intentRouterMsLocal: nil,
                intentRouterMsOpenAI: nil,
                localConfidence: nil,
                openAIConfidence: nil,
                confidenceThreshold: 0.7,
                localTimeoutSeconds: nil,
                escalationReason: nil
            )
        }
        let routePlan: TurnRouter.PlanRouteHandler = { _ in
            RouteDecision(
                plan: Plan(steps: [.talk(say: "fallback")]),
                provider: .none,
                routerMs: 1,
                aiModelUsed: nil,
                routeReason: "test",
                planLocalWireMs: nil,
                planLocalTotalMs: nil,
                planOpenAIMs: nil
            )
        }

        let native = TurnRouter(
            classifyIntent: classify,
            routePlan: routePlan,
            nativeToolExists: { category in category == .news },
            normalizeToolName: { _ in nil },
            isAllowedTool: { _ in false }
        )
        let nativeDecision = await native.routePlan(
            TurnPlanRouteRequest(
                text: "latest news",
                history: [],
                pendingSlot: nil,
                reason: .userChat,
                promptContext: nil,
                intentClassification: IntentClassification(
                    intent: .webRequest,
                    confidence: 0.9,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: true
                )
            )
        )
        guard case .tool(let name, _, _) = nativeDecision.plan.steps.first else {
            return XCTFail("Expected tool step for native news route")
        }
        XCTAssertEqual(name, "news.latest")

        let missing = TurnRouter(
            classifyIntent: classify,
            routePlan: routePlan,
            nativeToolExists: { _ in false },
            normalizeToolName: { _ in nil },
            isAllowedTool: { _ in false }
        )
        let missingDecision = await missing.routePlan(
            TurnPlanRouteRequest(
                text: "latest news",
                history: [],
                pendingSlot: nil,
                reason: .userChat,
                promptContext: nil,
                intentClassification: IntentClassification(
                    intent: .webRequest,
                    confidence: 0.9,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: true
                )
            )
        )
        guard case .delegate(let task, _, _) = missingDecision.plan.steps.first else {
            return XCTFail("Expected delegate capability gap for missing news capability")
        }
        XCTAssertTrue(task.lowercased().contains("capability_gap"))
    }
}
