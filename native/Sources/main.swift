import AppKit
import SceneKit
import VRMKit
import VRMSceneKit

// --- Constants ---
let GATEWAY_URL = "http://100.124.74.30:18789" // Klaus via Tailscale
let GATEWAY_TOKEN = "72c8c16f713df093b8151224d680256215036273738fa283"
let WINDOW_WIDTH: CGFloat = 420
let WINDOW_HEIGHT: CGFloat = 680
// Global hotkey: Cmd+Shift+K (keyCode 40)

// --- Animation State Machine ---
enum AvatarState: String {
    case idle
    case listening   // user is typing
    case thinking    // waiting for response
    case speaking    // streaming response text
    case reacting    // just finished speaking
}

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
    var bubbleScrollView: NSScrollView!
    var bubbleContainer: NSView!
    var thinkingIndicator: NSView!
    var statusItem: NSStatusItem!
    var isThinking = false

    // Animation state
    var avatarState: AvatarState = .idle
    var breathingSpeed: TimeInterval = 3.5
    var jawBone: SCNNode?
    var jawBaseRotation: SCNVector4 = SCNVector4(0, 0, 0, 1)

    // Conversation memory
    var conversationHistory: [[String: String]] = []
    var chatMessages: [ChatMessage] = []
    var bubbleHideTimer: DispatchWorkItem?

    // Streaming
    var streamingText = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menubar app
        NSApp.setActivationPolicy(.accessory)

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

        // Menubar icon
        setupMenubar()

        // Global hotkey: Cmd+Shift+K
        setupGlobalHotkey()

        window.center()
        window.makeKeyAndOrderFront(nil)

        // Activate app
        NSApp.activate(ignoringOtherApps: true)

        // System prompt for conversation context
        conversationHistory.append([
            "role": "system",
            "content": "You are Klaus, a wolf AI assistant. You're appearing as a 3D avatar on the user's desktop. Keep responses concise (1-3 sentences) since they appear in a small chat bubble. Be helpful, sharp, and slightly playful. You're Maxwell's AI companion running on his Mac Mini."
        ])
    }

    // --- Menubar ---
    func setupMenubar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "K"
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Klaus", action: #selector(toggleWindow), keyEquivalent: "k"))
        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func clearHistory() {
        conversationHistory.removeAll()
        chatMessages.removeAll()
        // Re-add system prompt
        conversationHistory.append([
            "role": "system",
            "content": "You are Klaus, a wolf AI assistant. You're appearing as a 3D avatar on the user's desktop. Keep responses concise (1-3 sentences) since they appear in a small chat bubble. Be helpful, sharp, and slightly playful. You're Maxwell's AI companion running on his Mac Mini."
        ])
        bubbleContainer.isHidden = true
    }

    // --- Global Hotkey ---
    func setupGlobalHotkey() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Cmd+Shift+K
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 40 {
                DispatchQueue.main.async {
                    self?.toggleWindow()
                }
            }
        }
        // Also monitor local events (when app is focused)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 40 {
                DispatchQueue.main.async {
                    self?.toggleWindow()
                }
                return nil
            }
            // Escape to hide
            if event.keyCode == 53 {
                self?.window.orderOut(nil)
                return nil
            }
            return event
        }
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

        // Scrollable text
        bubbleScrollView = NSScrollView(frame: NSRect(x: 16, y: 8, width: WINDOW_WIDTH - 72, height: 64))
        bubbleScrollView.hasVerticalScroller = true
        bubbleScrollView.hasHorizontalScroller = false
        bubbleScrollView.drawsBackground = false
        bubbleScrollView.autoresizingMask = [.width, .height]
        bubbleScrollView.scrollerStyle = .overlay

        chatBubble = NSTextView(frame: bubbleScrollView.bounds)
        chatBubble.isEditable = false
        chatBubble.isSelectable = true
        chatBubble.drawsBackground = false
        chatBubble.textColor = .white
        chatBubble.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        chatBubble.textContainerInset = NSSize(width: 0, height: 4)
        chatBubble.isVerticallyResizable = true
        chatBubble.textContainer?.widthTracksTextView = true
        bubbleScrollView.documentView = chatBubble
        bubbleContainer.addSubview(bubbleScrollView)

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

    // --- Animation State Machine ---
    func transitionTo(_ newState: AvatarState) {
        guard newState != avatarState else { return }
        let oldState = avatarState
        avatarState = newState

        guard let rootNode = vrmNode else { return }

        switch newState {
        case .idle:
            applyBreathingAnimation(to: rootNode, speed: 3.5, amplitude: 1.0)
            stopJawAnimation()

        case .listening:
            // Subtle head tilt — curious
            applyBreathingAnimation(to: rootNode, speed: 3.0, amplitude: 0.8)
            if let head = findBone("mixamorig:Head", in: rootNode) {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.4
                head.eulerAngles.z += 0.06  // slight tilt
                SCNTransaction.commit()
            }

        case .thinking:
            // Faster breathing, lean forward slightly
            applyBreathingAnimation(to: rootNode, speed: 2.0, amplitude: 1.3)
            if let spine = findBone("mixamorig:Spine1", in: rootNode) {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.5
                spine.eulerAngles.x += 0.04  // lean forward
                SCNTransaction.commit()
            }

        case .speaking:
            // Normal breathing, jaw animation
            applyBreathingAnimation(to: rootNode, speed: 3.5, amplitude: 1.0)
            startJawAnimation()

        case .reacting:
            // Brief head nod then back to idle
            if let head = findBone("mixamorig:Head", in: rootNode) {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.3
                head.eulerAngles.x += 0.08
                SCNTransaction.commit()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    SCNTransaction.begin()
                    SCNTransaction.animationDuration = 0.3
                    head.eulerAngles.x -= 0.08
                    SCNTransaction.commit()
                }
            }
            // Return to idle after reaction
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.transitionTo(.idle)
            }
        }

        // Reset head tilt from listening when leaving that state
        if oldState == .listening && newState != .listening {
            if let head = findBone("mixamorig:Head", in: rootNode) {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.3
                head.eulerAngles.z -= 0.06
                SCNTransaction.commit()
            }
        }
        // Reset spine lean from thinking when leaving that state
        if oldState == .thinking && newState != .thinking {
            if let spine = findBone("mixamorig:Spine1", in: rootNode) {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.3
                spine.eulerAngles.x -= 0.04
                SCNTransaction.commit()
            }
        }
    }

    // --- Jaw Animation (speaking) ---
    func startJawAnimation() {
        guard let rootNode = vrmNode,
              let jaw = findBone("mixamorig:Jaw", in: rootNode) ?? findBone("mixamorig:Head", in: rootNode) else { return }

        let baseRot = jaw.presentation.rotation
        let animation = CAKeyframeAnimation(keyPath: "rotation")
        animation.duration = 0.25
        animation.repeatCount = .infinity
        animation.autoreverses = true

        let openAmount: CGFloat = 0.08
        let closed = NSValue(scnVector4: baseRot)
        let open = NSValue(scnVector4: SCNVector4(
            baseRot.x + openAmount,
            baseRot.y,
            baseRot.z,
            baseRot.w + openAmount
        ))
        animation.values = [closed, open, closed]
        animation.keyTimes = [0, 0.4, 1.0]
        animation.calculationMode = .cubic

        jaw.addAnimation(animation, forKey: "jaw_speak")
    }

    func stopJawAnimation() {
        guard let rootNode = vrmNode else { return }
        if let jaw = findBone("mixamorig:Jaw", in: rootNode) ?? findBone("mixamorig:Head", in: rootNode) {
            jaw.removeAnimation(forKey: "jaw_speak")
        }
    }

    // --- Chat ---
    @objc func sendMessage() {
        let text = chatField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        chatField.stringValue = ""
        chatMessages.append(ChatMessage(text: text, isUser: true, timestamp: Date()))
        conversationHistory.append(["role": "user", "content": text])

        showThinking(true)
        transitionTo(.thinking)

        // Send to Klaus gateway with streaming
        Task {
            do {
                try await streamFromKlaus()
            } catch {
                await MainActor.run {
                    showThinking(false)
                    transitionTo(.reacting)
                    showBubble("connection lost — \(error.localizedDescription)")
                }
            }
        }
    }

    func streamFromKlaus() async throws {
        let url = URL(string: "\(GATEWAY_URL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(GATEWAY_TOKEN)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": "anthropic/claude-sonnet-4-6",
            "messages": conversationHistory.map { $0 as [String: Any] },
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, httpResponse) = try await URLSession.shared.bytes(for: request)

        guard let resp = httpResponse as? HTTPURLResponse, resp.statusCode == 200 else {
            let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "Klaus", code: statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(statusCode)"
            ])
        }

        await MainActor.run {
            showThinking(false)
            streamingText = ""
            transitionTo(.speaking)
            showBubble("")
        }

        // Parse SSE stream
        var buffer = ""
        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                let data = String(line.dropFirst(6))
                if data == "[DONE]" { break }

                if let jsonData = data.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    buffer += content
                    let captured = buffer
                    await MainActor.run {
                        streamingText = captured
                        updateBubbleText(captured)
                    }
                }
            }
        }

        // Finalize
        let finalText = buffer
        await MainActor.run {
            chatMessages.append(ChatMessage(text: finalText, isUser: false, timestamp: Date()))
            conversationHistory.append(["role": "assistant", "content": finalText])

            // Trim history if too long (keep system + last 20 messages)
            if conversationHistory.count > 22 {
                let system = conversationHistory[0]
                conversationHistory = [system] + Array(conversationHistory.suffix(20))
            }

            transitionTo(.reacting)
        }
    }

    // Fallback non-streaming (if stream fails)
    func sendToKlaus(_ message: String) async throws -> String {
        let url = URL(string: "\(GATEWAY_URL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(GATEWAY_TOKEN)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": "anthropic/claude-sonnet-4-6",
            "messages": conversationHistory.map { $0 as [String: Any] },
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

    func updateBubbleText(_ text: String) {
        chatBubble.string = text

        // Resize bubble to fit streaming content
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

        // Scroll to bottom as text streams in
        chatBubble.scrollToEndOfDocument(nil)
    }

    func showBubble(_ text: String) {
        // Cancel any pending hide timer
        bubbleHideTimer?.cancel()

        chatBubble.string = text

        // Resize bubble to fit content
        let maxWidth = WINDOW_WIDTH - 72
        let font = chatBubble.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let displayText = text.isEmpty ? " " : text
        let textSize = (displayText as NSString).boundingRect(
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
        bubbleContainer.alphaValue = 1
        bubbleContainer.isHidden = false

        // Auto-hide after 30 seconds (longer for readability)
        let timer = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.5
                self?.bubbleContainer.animator().alphaValue = 0
            }) {
                self?.bubbleContainer.isHidden = true
                self?.bubbleContainer.alphaValue = 1
            }
        }
        bubbleHideTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timer)
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

            // Cache jaw bone reference
            jawBone = findBone("mixamorig:Jaw", in: sceneNode)

            // Dump bone names for debugging
            var dump = "=== VRM NODE NAMES ===\n"
            sceneNode.enumerateChildNodes { node, _ in
                if let name = node.name {
                    let hasGeo = node.geometry != nil ? " [MESH]" : ""
                    dump += "  \(name)\(hasGeo)\n"
                }
            }
            dump += "=== END ===\n"
            try? dump.write(toFile: "/tmp/klaus-bones.txt", atomically: true, encoding: .utf8)

            applyIdlePose(to: sceneNode)
            applyBreathingAnimation(to: sceneNode, speed: 3.5, amplitude: 1.0)

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

    func applyBreathingAnimation(to rootNode: SCNNode, speed: TimeInterval, amplitude: CGFloat) {
        // Remove existing breathing animations
        let breathingBoneNames = [
            "mixamorig:Spine1", "mixamorig:Spine2", "mixamorig:Spine",
            "mixamorig:Neck", "mixamorig:Head",
            "mixamorig:LeftShoulder", "mixamorig:RightShoulder",
            "mixamorig:Hips"
        ]
        for name in breathingBoneNames {
            if let bone = findBone(name, in: rootNode) {
                bone.removeAnimation(forKey: "breathing")
                bone.removeAnimation(forKey: "breathing_pos")
            }
        }

        // Bone configs with amplitude scaling
        let breathingBones: [(name: String, amp: CGFloat, phase: CGFloat, axis: SCNVector3)] = [
            ("mixamorig:Spine1",        0.015 * amplitude, 0.0, SCNVector3(1, 0, 0)),
            ("mixamorig:Spine2",        0.010 * amplitude, 0.2, SCNVector3(1, 0, 0)),
            ("mixamorig:Spine",         0.005 * amplitude, 0.0, SCNVector3(0, 1, 0)),
            ("mixamorig:Neck",          0.006 * amplitude, 0.3, SCNVector3(1, 0, 0)),
            ("mixamorig:Head",          0.008 * amplitude, 0.4, SCNVector3(1, 0, 0)),
            ("mixamorig:LeftShoulder",  0.010 * amplitude, 0.0, SCNVector3(0, 0, 1)),
            ("mixamorig:RightShoulder", -0.010 * amplitude, 0.0, SCNVector3(0, 0, 1)),
        ]

        for entry in breathingBones {
            guard let bone = findBone(entry.name, in: rootNode) else { continue }

            let baseRotation = bone.presentation.rotation
            let amp = entry.amp
            let phase = entry.phase
            let axis = entry.axis

            let animation = CAKeyframeAnimation(keyPath: "rotation")
            animation.duration = speed
            animation.repeatCount = .infinity
            animation.calculationMode = .cubic

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
            posAnim.duration = speed
            posAnim.repeatCount = .infinity
            posAnim.calculationMode = .cubic

            let steps = 90
            var values: [NSValue] = []
            var keyTimes: [NSNumber] = []
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let breath = CGFloat(sin(t * .pi * 2)) * 0.004 * amplitude
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
        rootNode.eulerAngles.y = .pi

        // Arms down from T-pose
        if let leftArm = findBone("mixamorig:LeftArm", in: rootNode) {
            leftArm.eulerAngles.z += 1.1
            leftArm.eulerAngles.x += 0.15
        }
        if let rightArm = findBone("mixamorig:RightArm", in: rootNode) {
            rightArm.eulerAngles.z += -1.1
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
        return false  // Keep running in menubar
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
if CommandLine.arguments.contains("--qa") {
    // Run QA tests headless — no window, no runloop
    let qa = QARunner()
    let allPassed = qa.run()
    exit(allPassed ? 0 : 1)
} else {
    // Check for existing instance
    let myPID = ProcessInfo.processInfo.processIdentifier
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", "KlausAvatar"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let pids = (String(data: data, encoding: .utf8) ?? "")
        .split(separator: "\n")
        .compactMap { Int32($0) }
        .filter { $0 != myPID }
    if !pids.isEmpty {
        print("Klaus Avatar already running (PID \(pids[0])). Bringing to front.")
        // Could use distributed notifications to signal existing instance
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
