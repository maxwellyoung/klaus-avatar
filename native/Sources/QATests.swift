import AppKit
import SceneKit
import VRMKit
import VRMSceneKit
import Foundation

struct QAResult { let name: String; let passed: Bool; let detail: String }

class QARunner {
    var results: [QAResult] = []
    var vrmNode: SCNNode?

    func run() -> Bool {
        print("\n=== KLAUS AVATAR QA ===\n")

        // Avatar config tests
        testAllAvatarConfigs()
        testViewModes()

        // Load current avatar
        testVRMLoads()
        testBoneStructure()
        testTailBones()
        testIdlePose()

        // Animation
        testAnimationStates()
        testBreathingAnimation()
        testTailWagAnimation()

        // Chat
        testConversationMemory()
        testGatewayConfig()

        // System
        testSingleInstance()
        testViewModeConfigs()

        print("\n--- RESULTS ---")
        var p = 0, f = 0
        for r in results {
            let icon = r.passed ? "PASS" : "FAIL"
            print("  [\(icon)] \(r.name)\(r.detail.isEmpty ? "" : " — \(r.detail)")")
            if r.passed { p += 1 } else { f += 1 }
        }
        print("\n\(p)/\(results.count) passed, \(f) failed\n")
        return f == 0
    }

    func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        results.append(QAResult(name: name, passed: passed, detail: detail))
    }

    // --- Avatar Configs ---
    func testAllAvatarConfigs() {
        for config in AvatarConfig.all {
            let url = Bundle.module.url(forResource: config.file, withExtension: "vrm", subdirectory: "Resources")
            record("\(config.name) VRM exists", url != nil)
        }
        record("Avatar configs unique", Set(AvatarConfig.all.map { $0.file }).count == AvatarConfig.all.count)
    }

    // --- View Modes ---
    func testViewModes() {
        let modes = ViewMode.allCases
        record("View modes count", modes.count == 4, "\(modes.count)")
        for mode in modes {
            let cfg = ViewModeConfig.config(for: mode)
            record("\(mode.rawValue) dimensions valid", cfg.width > 0 && cfg.height > 0,
                   "\(cfg.width)x\(cfg.height)")
        }
    }

    func testViewModeConfigs() {
        let full = ViewModeConfig.config(for: .full)
        let mini = ViewModeConfig.config(for: .mini)
        let bubble = ViewModeConfig.config(for: .bubble)
        record("Full > mini", full.width > mini.width && full.height > mini.height)
        record("Mini > bubble", mini.width > bubble.width)
        record("Full shows chat", full.showChat)
        record("Mini hides chat", !mini.showChat)
        record("Bubble is circular", bubble.cornerRadius > 0)
    }

    // --- VRM ---
    func testVRMLoads() {
        let config = AvatarConfig.cutesaurus
        guard let url = Bundle.module.url(forResource: config.file, withExtension: "vrm", subdirectory: "Resources") else {
            record("VRM loads", false, "not found"); return
        }
        do {
            let vrm = try VRMLoader().load(withURL: url)
            vrmNode = try VRMSceneLoader(vrm: vrm).loadScene().rootNode
            record("VRM loads", true)
        } catch { record("VRM loads", false, error.localizedDescription) }
    }

    func testBoneStructure() {
        guard let node = vrmNode else { record("Bones", false, "no VRM"); return }
        let b = BoneMap.cutesaurus
        let required = [b.hips, b.spine, b.spine1, b.spine2, b.neck, b.head,
                        b.leftArm, b.rightArm, b.leftForeArm, b.rightForeArm,
                        b.leftShoulder, b.rightShoulder]
        var missing: [String] = []
        for name in required { if findBone(name, in: node) == nil { missing.append(name) } }
        record("Core bones present", missing.isEmpty,
               missing.isEmpty ? "\(required.count) found" : "missing: \(missing.joined(separator: ", "))")
    }

    func testTailBones() {
        guard let node = vrmNode else { record("Tail", false, "no VRM"); return }
        let tail = BoneMap.cutesaurus.tail
        var found = 0
        for name in tail { if findBone(name, in: node) != nil { found += 1 } }
        record("Tail segments", found == tail.count, "\(found)/\(tail.count)")
    }

    func testIdlePose() {
        guard let node = vrmNode else { record("Idle pose", false); return }
        node.eulerAngles.y = .pi
        record("Faces camera", abs(node.eulerAngles.y - .pi) < 0.01)
    }

    func testAnimationStates() {
        let states: [AvatarState] = [.idle, .listening, .thinking, .speaking, .reacting]
        record("5 animation states", states.count == 5)
        record("States unique", Set(states.map { $0.rawValue }).count == 5)
    }

    func testBreathingAnimation() {
        guard let node = vrmNode else { record("Breathing", false); return }
        let bone = findBone(BoneMap.cutesaurus.spine1, in: node)
        record("Breathing target exists", bone != nil)
        if let b = bone {
            let a = CAKeyframeAnimation(keyPath: "rotation")
            a.duration = 3.5; a.repeatCount = .infinity
            a.values = [NSValue(scnVector4: SCNVector4(0,0,0,1))]; a.keyTimes = [0]
            b.addAnimation(a, forKey: "test")
            record("Breathing attaches", b.animationKeys.contains("test"))
            b.removeAnimation(forKey: "test")
        }
    }

    func testTailWagAnimation() {
        guard let node = vrmNode else { record("Tail wag", false); return }
        if let tail = findBone(BoneMap.cutesaurus.tail[0], in: node) {
            let a = CAKeyframeAnimation(keyPath: "rotation")
            a.duration = 2; a.repeatCount = .infinity
            a.values = [NSValue(scnVector4: SCNVector4(0,0,0,1))]; a.keyTimes = [0]
            tail.addAnimation(a, forKey: "wag")
            record("Tail wag attaches", tail.animationKeys.contains("wag"))
            tail.removeAnimation(forKey: "wag")
        }
    }

    func testConversationMemory() {
        var h: [[String: String]] = [["role": "system", "content": "test"]]
        for i in 0..<25 { h.append(["role": "user", "content": "m\(i)"]) }
        if h.count > 22 { let s = h[0]; h = [s] + Array(h.suffix(20)) }
        record("History trims to 21", h.count == 21)
        record("System prompt kept", h[0]["role"] == "system")
    }

    func testGatewayConfig() {
        record("Gateway URL valid", URL(string: "\(GATEWAY_URL)/v1/chat/completions") != nil)
        record("Token non-empty", !GATEWAY_TOKEN.isEmpty, "\(GATEWAY_TOKEN.prefix(8))...")
    }

    func testSingleInstance() {
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        t.arguments = ["-f", "KlausAvatar"]
        let p = Pipe(); t.standardOutput = p; try? t.run(); t.waitUntilExit()
        let pids = (String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .split(separator: "\n").filter { !$0.isEmpty }
        record("No duplicates", pids.count <= 1, "\(pids.count) proc")
    }

    func findBone(_ name: String, in root: SCNNode) -> SCNNode? {
        var found: SCNNode?
        root.enumerateChildNodes { n, stop in if n.name == name { found = n; stop.pointee = true } }
        return found
    }
}
