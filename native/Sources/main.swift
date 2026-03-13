import AppKit
import SceneKit
import VRMKit
import VRMSceneKit
import WebKit

// --- Constants ---
let GATEWAY_URL = "http://100.124.74.30:18789" // Klaus via Tailscale
let GATEWAY_TOKEN = "72c8c16f713df093b8151224d680256215036273738fa283"
let WINDOW_WIDTH: CGFloat = 420
let WINDOW_HEIGHT: CGFloat = 680

// --- Chat Message ---
struct ChatMessage {
    let text: String
    let isUser: Bool
    let timestamp: Date
}

// --- Main App Delegate ---
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var sceneView: SCNView!
    var vrmNode: SCNNode?
    var chatField: NSTextField!
    var chatBubble: NSTextView!
    var bubbleContainer: NSView!
    var thinkingIndicator: NSView!
    var isThinking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Transparent floating window
        let rect = NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_HEIGHT)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Content view
        let contentView = NSView(frame: rect)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = .clear
        window.contentView = contentView

        // Background — dark gradient
        let bgView = GradientView(frame: rect)
        bgView.autoresizingMask = [.width, .height]
        contentView.addSubview(bgView)

        // SceneKit View — transparent background
        let sceneRect = NSRect(x: 0, y: 80, width: WINDOW_WIDTH, height: WINDOW_HEIGHT - 140)
        sceneView = SCNView(frame: sceneRect)
        sceneView.backgroundColor = .clear
        sceneView.antialiasingMode = .multisampling4X
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = false
        sceneView.autoresizingMask = [.width, .height]
        contentView.addSubview(sceneView)

        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        sceneView.scene = scene

        setupScene(scene)
        loadVRM(scene: scene)

        // Chat bubble (above avatar)
        setupChatBubble(in: contentView)

        // Input field (bottom)
        setupInputField(in: contentView)

        // Title bar area
        setupTitleBar(in: contentView)

        window.center()
        window.makeKeyAndOrderFront(nil)

        // Activate app
        NSApp.activate(ignoringOtherApps: true)
    }

    func setupScene(_ scene: SCNScene) {
        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 28
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 100
        cameraNode.position = SCNVector3(0, 1.1, 2.8)
        cameraNode.look(at: SCNVector3(0, 0.9, 0))
        scene.rootNode.addChildNode(cameraNode)

        // Key light — warm from top right
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.color = NSColor(white: 1.0, alpha: 1.0)
        keyLight.intensity = 1000
        keyLight.castsShadow = true
        keyLight.shadowMapSize = CGSize(width: 2048, height: 2048)
        keyLight.shadowMode = .deferred
        keyLight.shadowRadius = 3
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.position = SCNVector3(2, 3, 2)
        keyNode.look(at: SCNVector3(0, 1, 0))
        scene.rootNode.addChildNode(keyNode)

        // Fill — cool blue from left
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.color = NSColor(red: 0.4, green: 0.5, blue: 0.8, alpha: 1.0)
        fillLight.intensity = 300
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.position = SCNVector3(-3, 1.5, 0)
        fillNode.look(at: SCNVector3(0, 1, 0))
        scene.rootNode.addChildNode(fillNode)

        // Rim — backlight
        let rimLight = SCNLight()
        rimLight.type = .directional
        rimLight.color = NSColor(white: 1.0, alpha: 1.0)
        rimLight.intensity = 500
        let rimNode = SCNNode()
        rimNode.light = rimLight
        rimNode.position = SCNVector3(0, 2, -3)
        rimNode.look(at: SCNVector3(0, 1, 0))
        scene.rootNode.addChildNode(rimNode)

        // Ambient
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = NSColor(white: 0.12, alpha: 1.0)
        ambientLight.intensity = 250
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        // Ground shadow catcher
        let ground = SCNFloor()
        ground.reflectivity = 0.02
        ground.firstMaterial?.diffuse.contents = NSColor(white: 0.02, alpha: 0.5)
        ground.firstMaterial?.transparency = 0.3
        let groundNode = SCNNode(geometry: ground)
        scene.rootNode.addChildNode(groundNode)
    }

    func setupChatBubble(in parent: NSView) {
        // Container
        bubbleContainer = NSView(frame: NSRect(x: 20, y: WINDOW_HEIGHT - 140, width: WINDOW_WIDTH - 40, height: 80))
        bubbleContainer.wantsLayer = true
        bubbleContainer.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        bubbleContainer.layer?.cornerRadius = 16
        bubbleContainer.layer?.borderColor = NSColor(white: 0.25, alpha: 0.5).cgColor
        bubbleContainer.layer?.borderWidth = 0.5
        bubbleContainer.autoresizingMask = [.width, .minYMargin]
        bubbleContainer.isHidden = true
        parent.addSubview(bubbleContainer)

        // Text
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 8, width: WINDOW_WIDTH - 72, height: 64))
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]

        chatBubble = NSTextView(frame: scrollView.bounds)
        chatBubble.isEditable = false
        chatBubble.isSelectable = true
        chatBubble.drawsBackground = false
        chatBubble.textColor = .white
        chatBubble.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        chatBubble.textContainerInset = NSSize(width: 0, height: 4)
        scrollView.documentView = chatBubble
        bubbleContainer.addSubview(scrollView)

        // Thinking dots
        thinkingIndicator = NSView(frame: NSRect(x: 20, y: WINDOW_HEIGHT - 140, width: 60, height: 30))
        thinkingIndicator.wantsLayer = true
        thinkingIndicator.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        thinkingIndicator.layer?.cornerRadius = 15
        thinkingIndicator.isHidden = true
        thinkingIndicator.autoresizingMask = [.minYMargin]
        parent.addSubview(thinkingIndicator)

        // Three dots
        for i in 0..<3 {
            let dot = NSView(frame: NSRect(x: 12 + CGFloat(i) * 14, y: 10, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor(white: 0.5, alpha: 1.0).cgColor
            dot.layer?.cornerRadius = 4
            thinkingIndicator.addSubview(dot)

            // Pulse animation
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.3, 1.0, 0.3]
            pulse.keyTimes = [0, 0.5, 1.0]
            pulse.duration = 1.2
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(i) * 0.2
            dot.layer?.add(pulse, forKey: "pulse")
        }
    }

    func setupInputField(in parent: NSView) {
        // Input container
        let inputContainer = NSView(frame: NSRect(x: 20, y: 20, width: WINDOW_WIDTH - 40, height: 44))
        inputContainer.wantsLayer = true
        inputContainer.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.9).cgColor
        inputContainer.layer?.cornerRadius = 22
        inputContainer.layer?.borderColor = NSColor(white: 0.2, alpha: 0.6).cgColor
        inputContainer.layer?.borderWidth = 0.5
        inputContainer.autoresizingMask = [.width]
        parent.addSubview(inputContainer)

        // Text field
        chatField = NSTextField(frame: NSRect(x: 16, y: 8, width: WINDOW_WIDTH - 72, height: 28))
        chatField.isBordered = false
        chatField.drawsBackground = false
        chatField.textColor = .white
        chatField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        chatField.placeholderString = "Ask Klaus anything..."
        chatField.placeholderAttributedString = NSAttributedString(
            string: "Ask Klaus anything...",
            attributes: [
                .foregroundColor: NSColor(white: 0.4, alpha: 1.0),
                .font: NSFont.systemFont(ofSize: 13, weight: .regular)
            ]
        )
        chatField.focusRingType = .none
        chatField.cell?.sendsActionOnEndEditing = false
        chatField.target = self
        chatField.action = #selector(sendMessage)
        chatField.autoresizingMask = [.width]
        inputContainer.addSubview(chatField)

        // Send icon
        let sendButton = NSButton(frame: NSRect(x: WINDOW_WIDTH - 72, y: 8, width: 28, height: 28))
        sendButton.isBordered = false
        sendButton.title = "↑"
        sendButton.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        sendButton.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        sendButton.target = self
        sendButton.action = #selector(sendMessage)
        sendButton.autoresizingMask = [.minXMargin]
        inputContainer.addSubview(sendButton)
    }

    func setupTitleBar(in parent: NSView) {
        // Drag handle / title
        let titleBar = NSView(frame: NSRect(x: 0, y: WINDOW_HEIGHT - 32, width: WINDOW_WIDTH, height: 32))
        titleBar.autoresizingMask = [.width, .minYMargin]
        parent.addSubview(titleBar)

        let title = NSTextField(labelWithString: "KLAUS")
        title.frame = NSRect(x: 0, y: 6, width: WINDOW_WIDTH, height: 20)
        title.alignment = .center
        title.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        title.textColor = NSColor(white: 0.4, alpha: 1.0)
        title.autoresizingMask = [.width]
        titleBar.addSubview(title)
    }

    // --- Chat ---
    @objc func sendMessage() {
        let text = chatField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        chatField.stringValue = ""
        showThinking(true)

        // Send to Klaus gateway
        Task {
            do {
                let response = try await sendToKlaus(text)
                await MainActor.run {
                    showThinking(false)
                    showBubble(response)
                }
            } catch {
                await MainActor.run {
                    showThinking(false)
                    showBubble("connection lost — \(error.localizedDescription)")
                }
            }
        }
    }

    func sendToKlaus(_ message: String) async throws -> String {
        let url = URL(string: "\(GATEWAY_URL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(GATEWAY_TOKEN)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": "anthropic/claude-sonnet-4-6",
            "messages": [
                ["role": "user", "content": message]
            ],
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, httpResponse) = try await URLSession.shared.data(for: request)

        guard let resp = httpResponse as? HTTPURLResponse, resp.statusCode == 200 else {
            let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "Klaus", code: statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(statusCode)"
            ])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let messageObj = choices?.first?["message"] as? [String: Any]
        let content = messageObj?["content"] as? String

        return content ?? "(no response)"
    }

    func showThinking(_ show: Bool) {
        isThinking = show
        thinkingIndicator.isHidden = !show
        if show {
            bubbleContainer.isHidden = true
        }
    }

    func showBubble(_ text: String) {
        chatBubble.string = text

        // Resize bubble to fit content
        let maxWidth = WINDOW_WIDTH - 72
        let font = chatBubble.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let textSize = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: 400),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font]
        )
        let bubbleHeight = max(40, min(textSize.height + 24, 200))

        bubbleContainer.frame = NSRect(
            x: 20,
            y: WINDOW_HEIGHT - 60 - bubbleHeight,
            width: WINDOW_WIDTH - 40,
            height: bubbleHeight
        )
        bubbleContainer.isHidden = false

        // Auto-hide after 15 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self?.bubbleContainer.animator().alphaValue = 0
            }) {
                self?.bubbleContainer.isHidden = true
                self?.bubbleContainer.alphaValue = 1
            }
        }
    }

    // --- VRM Loading ---
    func loadVRM(scene: SCNScene) {
        guard let vrmURL = Bundle.module.url(forResource: "wolfman", withExtension: "vrm", subdirectory: "Resources") else {
            print("wolfman.vrm not found in bundle")
            return
        }
        loadVRMFromPath(vrmURL.path, scene: scene)
    }

    func loadVRMFromPath(_ path: String, scene: SCNScene) {
        do {
            let vrm = try VRMLoader().load(withURL: URL(fileURLWithPath: path))
            let sceneNode = try VRMSceneLoader(vrm: vrm).loadScene().rootNode

            let (_, maxBound) = sceneNode.boundingBox
            let height = maxBound.y
            let targetHeight: CGFloat = 1.6
            let scale = targetHeight / CGFloat(height)
            sceneNode.scale = SCNVector3(scale, scale, scale)
            sceneNode.position = SCNVector3(0, 0, 0)

            scene.rootNode.addChildNode(sceneNode)
            self.vrmNode = sceneNode

            print("VRM loaded — height: \(height), scale: \(scale)")

            // Dump all node names to file for debugging
            var dump = "=== VRM NODE NAMES ===\n"
            sceneNode.enumerateChildNodes { node, _ in
                if let name = node.name {
                    let hasGeo = node.geometry != nil ? " [MESH]" : ""
                    dump += "  \(name)\(hasGeo)\n"
                }
            }
            dump += "=== END ===\n"
            try? dump.write(toFile: "/tmp/klaus-bones.txt", atomically: true, encoding: .utf8)

            applyProceduralBreathing(to: sceneNode)

        } catch {
            print("VRM error: \(error)")
        }
    }

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

    func applyProceduralBreathing(to rootNode: SCNNode) {
        // First, bring arms down from T-pose to natural idle
        applyIdlePose(to: rootNode)

        // Bone name → (amplitude, phase, axis) for breathing
        let breathingBones: [(name: String, amp: CGFloat, phase: CGFloat, axis: SCNVector3)] = [
            ("mixamorig:Spine1",        0.015, 0.0, SCNVector3(1, 0, 0)),  // chest — primary breath
            ("mixamorig:Spine2",        0.010, 0.2, SCNVector3(1, 0, 0)),  // upper chest
            ("mixamorig:Spine",         0.005, 0.0, SCNVector3(0, 1, 0)),  // spine sway
            ("mixamorig:Neck",          0.006, 0.3, SCNVector3(1, 0, 0)),  // neck
            ("mixamorig:Head",          0.008, 0.4, SCNVector3(1, 0, 0)),  // head bob
            ("mixamorig:LeftShoulder",  0.010, 0.0, SCNVector3(0, 0, 1)),  // shoulders rise
            ("mixamorig:RightShoulder", -0.010, 0.0, SCNVector3(0, 0, 1)),
        ]

        let duration: TimeInterval = 3.5  // slightly slower = calmer wolf

        for entry in breathingBones {
            guard let bone = findBone(entry.name, in: rootNode) else { continue }

            let baseRotation = bone.presentation.rotation
            let amp = entry.amp
            let phase = entry.phase
            let axis = entry.axis

            let animation = CAKeyframeAnimation(keyPath: "rotation")
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.calculationMode = .cubic  // smooth interpolation

            let steps = 90
            var values: [NSValue] = []
            var keyTimes: [NSNumber] = []

            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let breath = CGFloat(sin((t * .pi * 2) + Double(phase)))
                let angle = breath * amp

                let rotation = SCNVector4(
                    baseRotation.x + axis.x * angle,
                    baseRotation.y + axis.y * angle,
                    baseRotation.z + axis.z * angle,
                    baseRotation.w + angle
                )
                values.append(NSValue(scnVector4: rotation))
                keyTimes.append(NSNumber(value: t))
            }

            animation.values = values
            animation.keyTimes = keyTimes
            bone.addAnimation(animation, forKey: "breathing")
        }

        // Hips — subtle vertical bob
        if let hips = findBone("mixamorig:Hips", in: rootNode) {
            let basePos = hips.presentation.position
            let posAnim = CAKeyframeAnimation(keyPath: "position")
            posAnim.duration = duration
            posAnim.repeatCount = .infinity
            posAnim.calculationMode = .cubic

            let steps = 90
            var values: [NSValue] = []
            var keyTimes: [NSNumber] = []
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let breath = CGFloat(sin(t * .pi * 2)) * 0.004
                values.append(NSValue(scnVector3: SCNVector3(basePos.x, basePos.y + breath, basePos.z)))
                keyTimes.append(NSNumber(value: t))
            }
            posAnim.values = values
            posAnim.keyTimes = keyTimes
            hips.addAnimation(posAnim, forKey: "breathing_pos")
        }
    }

    func applyIdlePose(to rootNode: SCNNode) {
        // Rotate entire model to face camera
        rootNode.eulerAngles.y = .pi  // 180 degrees — face forward

        // Arms down from T-pose (reverse direction from before)
        if let leftArm = findBone("mixamorig:LeftArm", in: rootNode) {
            leftArm.eulerAngles.z += 1.1   // rotate DOWN
            leftArm.eulerAngles.x += 0.15
        }
        if let rightArm = findBone("mixamorig:RightArm", in: rootNode) {
            rightArm.eulerAngles.z += -1.1  // rotate DOWN (opposite side)
            rightArm.eulerAngles.x += 0.15
        }

        // Forearms — slight bend at elbow
        if let leftForeArm = findBone("mixamorig:LeftForeArm", in: rootNode) {
            leftForeArm.eulerAngles.y += -0.3
        }
        if let rightForeArm = findBone("mixamorig:RightForeArm", in: rootNode) {
            rightForeArm.eulerAngles.y += 0.3
        }

        // Slight head tilt
        if let head = findBone("mixamorig:Head", in: rootNode) {
            head.eulerAngles.x += 0.05
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// --- Gradient Background ---
class GradientView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let gradient = NSGradient(colors: [
            NSColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 0.95),
            NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 0.95),
            NSColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 0.98),
        ])
        gradient?.draw(in: bounds, angle: 270)

        // Subtle border
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor(white: 0.15, alpha: 0.5).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

// --- Launch ---
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
