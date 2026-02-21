# Camera Vision Enhancement Plan for Sam

## Consulted: GPT-5.2 (gpt-5.2-chat-latest)

---

## Current State (What Already Exists)

Sam has a comprehensive camera system built on Apple's Vision framework:

| Capability | Status | Framework |
|:-----------|:-------|:----------|
| Camera capture (VGA 640x480) | Done | AVFoundation |
| Object classification | Done | VNClassifyImageRequest |
| Text recognition (OCR) | Done | VNRecognizeTextRequest |
| Face detection | Done | VNDetectFaceRectanglesRequest |
| Face recognition (enrollment) | Done | VNGenerateImageFeaturePrintRequest |
| Face profile encryption | Done | AES-GCM + SQLite |
| Identity state machine | Done | FaceGreetingManager |
| Camera health monitoring | Done | CameraHealthMonitor |
| 8 camera tools registered | Done | ToolRegistry |
| Inventory snapshots | Done | CameraInventorySnapshotTool |
| Visual Q&A | Done | CameraVisualQATool |

---

## Just Implemented (This Session)

### 1. Facial Emotion Detection
- **File:** `AudioCaptureService.swift`
- **Method:** `VNDetectFaceLandmarksRequest` → geometric heuristic classifier
- **Emotions:** happy, sad, angry, surprised, neutral, confused
- **How:** Analyzes mouth curvature, eye openness, eyebrow position from landmark points
- **Tool:** `detect_emotions` — returns emotion readings for each face with confidence
- **Integration:** Automatically included in `describeCurrentScene()` when faces present

### 2. GPT-5.2 Vision Escalation
- **File:** `ToolRegistry.swift`
- **Tool:** `camera_gpt_vision` — captures frame as JPEG, base64 encodes, prepares for GPT-5.2 vision API
- **Use case:** Complex questions like "what is she wearing?", "what's happening in the room?", "describe the scene in detail"
- **Local context enriched:** Includes local Vision analysis alongside the frame

### 3. Frame Capture API
- **Method:** `captureFrameAsJPEG(quality:)` on CameraVisionService
- **Returns:** JPEG Data ready for base64 encoding and API transmission

---

## Phase 2: Clothing Detection (Recommended Next)

### Approach: GPT-5.2 Vision API
Apple's Vision framework has no clothing detection. Options:

**Option A (Recommended): GPT-5.2 Vision API**
- Already have `captureFrameAsJPEG()`
- Send frame + prompt: "Describe what each person is wearing in detail"
- Most accurate, zero model management, works immediately
- Cost: ~$0.01 per frame analysis

**Option B: Custom CoreML Model (YOLOv8)**
- Train/convert YOLOv8 model for apparel detection
- Labels: shirt, jacket, dress, hat, glasses, pants, shoes
- Runs locally on Neural Engine
- Requires model training/conversion effort

### Implementation
```swift
// In TurnOrchestrator+Vision.swift
// When user asks about clothing, route to camera_gpt_vision with clothing-specific prompt
```

---

## Phase 3: Enhanced Scene Understanding

### 3A. Scene Classification
- Already have `VNClassifyImageRequest` returning object labels
- Enhancement: Group labels into scene types (office, kitchen, outdoor, meeting)
- Map to contextual understanding: "looks like a work setting" vs "casual at home"

### 3B. Activity Recognition
- Use temporal analysis: compare consecutive frames to detect movement patterns
- Person entering/leaving, sitting down, standing up, gesturing
- Integrate with TheoryOfMind: infer engagement, distraction, stress

### 3C. Continuous Passive Awareness (Low Power Mode)
- 1 FPS processing (vs current 4 FPS)
- Face detection + basic classification only
- Fire events on significant changes:
  - New person enters / person leaves
  - Emotion shift (happy → sad)
  - Scene change (stood up, left desk)
- No GPT calls in passive mode

---

## Phase 4: Deep Intelligence Integration

### 4A. Visual Memory
```swift
struct VisualMemoryEntry {
    let timestamp: Date
    let people: [String]           // recognized names
    let emotions: [String]         // detected emotions
    let sceneContext: String        // "working at desk"
    let clothing: [String]         // "blue hoodie, jeans"
    let significance: Double       // 0-1 importance
}
```
- Store in SemanticMemoryStore as visual episodes
- Tag with `["visual", "camera"]`
- Sam can recall: "Last time I saw John, he looked tired"

### 4B. TheoryOfMind + Vision
- Feed facial emotion into TheoryOfMind engine
- Combine voice tone (AffectMetadata) + facial expression + conversation context
- Multi-modal emotion understanding: "You sound calm but you look stressed"

### 4C. Proactive Visual Awareness
- Sam notices things without being asked:
  - "You look tired today — rough night?"
  - "I see you've got your jacket on — heading out?"
  - "New haircut? Looks great!"
- Gated by confidence threshold and social appropriateness

---

## Architecture Overview

```
AVCaptureSession (640x480, 4 FPS)
    |
    v
CameraVisionService
    |-- VNClassifyImageRequest (objects/scene)
    |-- VNRecognizeTextRequest (OCR)
    |-- VNDetectFaceRectanglesRequest (face detection)
    |-- VNGenerateImageFeaturePrintRequest (face recognition)
    |-- VNDetectFaceLandmarksRequest (emotion detection) ← NEW
    |
    v
CameraSceneDescription (unified output)
    |-- labels, text, faces, emotions ← ENHANCED
    |
    v
Tools Layer
    |-- describe_camera_view
    |-- camera_visual_qa
    |-- find_camera_objects
    |-- detect_emotions ← NEW
    |-- camera_gpt_vision ← NEW
    |-- get_camera_face_presence
    |-- enroll_camera_face
    |-- recognize_camera_faces
    |-- camera_inventory_snapshot
    |-- save_camera_memory_note
    |
    v
GPT-5.2 Vision Escalation (complex queries)
    |-- captureFrameAsJPEG() → base64 → GPT API
    |-- Clothing, scene narrative, activity recognition
    |
    v
Intelligence Integration
    |-- TheoryOfMind (social context from visual cues)
    |-- EmotionalIntelligence (multi-modal: voice + face)
    |-- SemanticMemory (visual episode storage)
```

---

## Privacy

- All Vision framework processing is local (on-device)
- GPT-5.2 vision only when user explicitly asks complex questions
- Face embeddings encrypted at rest (AES-GCM)
- Clear purple camera indicator in status bar
- No frames stored to disk (processed in memory only)

---

## Implementation Priority

1. **Done:** Facial emotion detection + GPT vision tool ← This session
2. **Next:** Wire GPT-5.2 vision API call (actual HTTP request with image)
3. **Next:** Visual memory entries (store what Sam sees)
4. **Later:** Continuous passive awareness mode
5. **Later:** Activity recognition from temporal analysis
6. **Later:** Proactive visual observations
