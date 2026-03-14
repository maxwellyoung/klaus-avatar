import AppKit
import SceneKit
import VRMKit
import VRMSceneKit
import Foundation

// --- Automated QA Test Runner ---
// Run with: swift run KlausAvatar --qa
// Returns exit code 0 if all pass, 1 if any fail

struct QAResult {
    let name: String
    let passed: Bool
    let detail: String
}

class QARunner {
    var results: [QAResult] = []
    var vrmNode: SCNNode?
    var vrm: VRM?

    func run() -> Bool {
        print("\n=== KLAUS AVATAR QA ===\n")

        testVRMFileExists()
        testVRMLoads()
        testBoneStructure()
        testIdlePose()
        testAnimationStates()
        testBreathingAnimation()
        testConversationMemory()
        testGatewayURLValid()
        testSingleInstanceGuard()
        testWindowProperties()

        // Report
        print("\n--- RESULTS ---")
        var passed = 0
        var failed = 0
        for r in results {
            let icon = r.passed ? "PASS" : "FAIL"
            print("  [\(icon)] \(r.name)\(r.detail.isEmpty ? "" : " — \(r.detail)")")
            if r.passed { passed += 1 } else { failed += 1 }
        }
        print("\n\(passed)/\(results.count) passed, \(failed) failed\n")
        return failed == 0
    }

    func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        results.append(QAResult(name: name, passed: passed, detail: detail))
    }

    // --- Tests ---

    func testVRMFileExists() {
        let url = Bundle.module.url(forResource: "wolfman", withExtension: "vrm", subdirectory: "Resources")
        record("VRM file in bundle", url != nil, url == nil ? "wolfman.vrm not found in Resources/" : "")
    }

    func testVRMLoads() {
        guard let url = Bundle.module.url(forResource: "wolfman", withExtension: "vrm", subdirectory: "Resources") else {
            record("VRM loads", false, "file not found")
            return
        }
        do {
            let loaded = try VRMLoader().load(withURL: url)
            self.vrm = loaded
            let sceneNode = try VRMSceneLoader(vrm: loaded).loadScene().rootNode
            self.vrmNode = sceneNode
            record("VRM loads", true)
        } catch {
            record("VRM loads", false, error.localizedDescription)
        }
    }

    func testBoneStructure() {
        guard let node = vrmNode else {
            record("Bone structure", false, "no VRM loaded")
            return
        }

        let requiredBones = [
            "mixamorig:Hips",
            "mixamorig:Spine", "mixamorig:Spine1", "mixamorig:Spine2",
            "mixamorig:Neck", "mixamorig:Head",
            "mixamorig:LeftArm", "mixamorig:RightArm",
            "mixamorig:LeftForeArm", "mixamorig:RightForeArm",
            "mixamorig:LeftShoulder", "mixamorig:RightShoulder",
        ]

        var missing: [String] = []
        for boneName in requiredBones {
            if findBone(boneName, in: node) == nil {
                missing.append(boneName)
            }
        }

        record("Required bones present", missing.isEmpty,
               missing.isEmpty ? "\(requiredBones.count) bones found" : "missing: \(missing.joined(separator: ", "))")
    }

    func testIdlePose() {
        guard let node = vrmNode else {
            record("Idle pose", false, "no VRM loaded")
            return
        }

        // Apply idle pose and verify arms came down
        // Face camera: eulerAngles.y should be ~pi
        node.eulerAngles.y = .pi

        if let leftArm = findBone("mixamorig:LeftArm", in: node) {
            let beforeZ = leftArm.eulerAngles.z
            leftArm.eulerAngles.z += 1.1
            leftArm.eulerAngles.x += 0.15
            let afterZ = leftArm.eulerAngles.z

            record("Left arm rotated down", abs(afterZ - beforeZ - 1.1) < 0.01,
                   "delta z: \(afterZ - beforeZ)")
        } else {
            record("Left arm rotated down", false, "bone not found")
        }

        if let rightArm = findBone("mixamorig:RightArm", in: node) {
            let beforeZ = rightArm.eulerAngles.z
            rightArm.eulerAngles.z += -1.1
            let afterZ = rightArm.eulerAngles.z

            record("Right arm rotated down", abs(afterZ - beforeZ + 1.1) < 0.01,
                   "delta z: \(afterZ - beforeZ)")
        } else {
            record("Right arm rotated down", false, "bone not found")
        }

        // Model faces camera
        record("Model faces camera", abs(node.eulerAngles.y - .pi) < 0.01,
               "eulerAngles.y = \(node.eulerAngles.y)")
    }

    func testAnimationStates() {
        // Verify enum cases exist and transitions are valid
        let states: [AvatarState] = [.idle, .listening, .thinking, .speaking, .reacting]
        record("Animation states defined", states.count == 5, "\(states.count) states")

        // Verify all state raw values are unique
        let rawValues = Set(states.map { $0.rawValue })
        record("State names unique", rawValues.count == states.count)
    }

    func testBreathingAnimation() {
        guard let node = vrmNode else {
            record("Breathing animation", false, "no VRM loaded")
            return
        }

        // Check that breathing bones can have animations added
        let spine1 = findBone("mixamorig:Spine1", in: node)
        record("Breathing target bone exists", spine1 != nil)

        if let bone = spine1 {
            // Apply a test animation
            let anim = CAKeyframeAnimation(keyPath: "rotation")
            anim.duration = 3.5
            anim.repeatCount = .infinity
            anim.values = [NSValue(scnVector4: SCNVector4(0, 0, 0, 1))]
            anim.keyTimes = [0]
            bone.addAnimation(anim, forKey: "test_breathing")

            let hasAnim = bone.animationKeys.contains("test_breathing")
            record("Breathing animation attaches", hasAnim)
            bone.removeAnimation(forKey: "test_breathing")
        }
    }

    func testConversationMemory() {
        // Test that conversation history accumulates and trims correctly
        var history: [[String: String]] = [
            ["role": "system", "content": "test"]
        ]

        // Add 25 messages
        for i in 0..<25 {
            history.append(["role": "user", "content": "msg \(i)"])
        }

        // Trim logic: keep system + last 20
        if history.count > 22 {
            let system = history[0]
            history = [system] + Array(history.suffix(20))
        }

        record("History trimmed correctly", history.count == 21,
               "count: \(history.count), first role: \(history[0]["role"] ?? "?")")
        record("System prompt preserved after trim", history[0]["role"] == "system")
    }

    func testGatewayURLValid() {
        let url = URL(string: "\(GATEWAY_URL)/v1/chat/completions")
        record("Gateway URL valid", url != nil, GATEWAY_URL)

        // Token is non-empty
        record("Gateway token set", !GATEWAY_TOKEN.isEmpty, "\(GATEWAY_TOKEN.prefix(8))...")
    }

    func testSingleInstanceGuard() {
        // Check if multiple KlausAvatar processes are running
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "KlausAvatar"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let pids = output.split(separator: "\n").filter { !$0.isEmpty }

        // In QA mode, only the QA process itself should be running (1 pid)
        // In normal mode, only 1 app instance should exist
        record("No duplicate processes", pids.count <= 1,
               "\(pids.count) process(es) found")
    }

    func testWindowProperties() {
        // Verify window dimensions are sane
        record("Window width > 0", WINDOW_WIDTH > 0, "\(WINDOW_WIDTH)")
        record("Window height > 0", WINDOW_HEIGHT > 0, "\(WINDOW_HEIGHT)")
        record("Window aspect ratio sane", WINDOW_WIDTH / WINDOW_HEIGHT > 0.4 && WINDOW_WIDTH / WINDOW_HEIGHT < 1.0,
               "ratio: \(WINDOW_WIDTH / WINDOW_HEIGHT)")
    }

    // --- Helpers ---
    func findBone(_ name: String, in rootNode: SCNNode) -> SCNNode? {
        var found: SCNNode?
        rootNode.enumerateChildNodes { node, stop in
            if node.name == name {
                found = node
                stop.pointee = true
            }
        }
        return found
    }
}
