import AppKit
import SceneKit
import VRMKit
import VRMSceneKit

// --- Gateway ---
let GATEWAY_URL = "http://100.124.74.30:18789"
let GATEWAY_TOKEN = "72c8c16f713df093b8151224d680256215036273738fa283"

// ============================================================
// MARK: - Avatar Config (swap-and-play)
// ============================================================

struct BoneMap {
    let hips, spine, spine1, spine2: String
    let neck, head: String
    let leftShoulder, rightShoulder: String
    let leftArm, rightArm: String
    let leftForeArm, rightForeArm: String
    let tail: [String] // empty if no tail

    static let cutesaurus = BoneMap(
        hips: "Hips", spine: "Spine", spine1: "Spine1", spine2: "Spine2",
        neck: "Neck", head: "Head",
        leftShoulder: "LeftShoulder", rightShoulder: "RightShoulder",
        leftArm: "LeftArm", rightArm: "RightArm",
        leftForeArm: "LeftForeArm", rightForeArm: "RightForeArm",
        tail: ["tail01", "tail02", "tail03", "tail04"]
    )

    static let wolfman = BoneMap(
        hips: "mixamorig:Hips", spine: "mixamorig:Spine",
        spine1: "mixamorig:Spine1", spine2: "mixamorig:Spine2",
        neck: "mixamorig:Neck", head: "mixamorig:Head",
        leftShoulder: "mixamorig:LeftShoulder", rightShoulder: "mixamorig:RightShoulder",
        leftArm: "mixamorig:LeftArm", rightArm: "mixamorig:RightArm",
        leftForeArm: "mixamorig:LeftForeArm", rightForeArm: "mixamorig:RightForeArm",
        tail: []
    )
}

struct AvatarConfig {
    let name: String
    let file: String           // resource name without .vrm
    let bones: BoneMap
    let scale: CGFloat         // target height
    let armRelax: CGFloat      // how much to lower arms from T-pose
    let cameraY: CGFloat       // camera look-at Y
    let cameraZ: CGFloat       // camera distance
    let fov: CGFloat
    let personality: String    // system prompt flavor

    static let cutesaurus = AvatarConfig(
        name: "CuteSaurus", file: "cutesaurus", bones: .cutesaurus,
        scale: 1.4, armRelax: 0.3, cameraY: 0.7, cameraZ: 2.4, fov: 30,
        personality: "a cute dinosaur"
    )

    static let wolfman = AvatarConfig(
        name: "Wolfman", file: "wolfman", bones: .wolfman,
        scale: 1.6, armRelax: 1.1, cameraY: 0.9, cameraZ: 2.8, fov: 28,
        personality: "a wolf"
    )

    static let all: [AvatarConfig] = [.cutesaurus, .wolfman]
}

// ============================================================
// MARK: - View Mode
// ============================================================

enum ViewMode: String, CaseIterable {
    case full       // full window with chat
    case compact    // smaller, chat hidden
    case mini       // tiny floating head
    case bubble     // just a circle avatar, click to expand
}

struct ViewModeConfig {
    let width: CGFloat
    let height: CGFloat
    let showChat: Bool
    let showBubble: Bool
    let cornerRadius: CGFloat

    static func config(for mode: ViewMode) -> ViewModeConfig {
        switch mode {
        case .full:    return ViewModeConfig(width: 320, height: 420, showChat: true, showBubble: true, cornerRadius: 0)
        case .compact: return ViewModeConfig(width: 240, height: 300, showChat: false, showBubble: true, cornerRadius: 0)
        case .mini:    return ViewModeConfig(width: 140, height: 160, showChat: false, showBubble: false, cornerRadius: 0)
        case .bubble:  return ViewModeConfig(width: 80, height: 80, showChat: false, showBubble: false, cornerRadius: 40)
        }
    }
}

// ============================================================
// MARK: - Animation State
// ============================================================

enum AvatarState: String {
    case idle, listening, thinking, speaking, reacting
}

struct ChatMessage {
    let text: String
    let isUser: Bool
    let timestamp: Date
}

// ============================================================
// MARK: - Window subclasses
// ============================================================

class FloatingPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class ClickThroughSCNView: SCNView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class DragView: NSView {
    var onRightClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Double-click cycles view mode
            NotificationCenter.default.post(name: .cycleViewMode, object: nil)
        } else {
            window?.performDrag(with: event)
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

extension Notification.Name {
    static let cycleViewMode = Notification.Name("cycleViewMode")
}

// ============================================================
// MARK: - App Delegate
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: FloatingPanel!
    var sceneView: SCNView!
    var vrmNode: SCNNode?
    var chatField: NSTextField!
    var chatBubble: NSTextView!
    var bubbleScrollView: NSScrollView!
    var bubbleContainer: NSView!
    var inputContainer: NSView!
    var thinkingIndicator: NSView!
    var dragView: DragView!
    var statusItem: NSStatusItem!

    var currentAvatar: AvatarConfig = .cutesaurus
    var currentMode: ViewMode = .full
    var avatarState: AvatarState = .idle
    var isThinking = false
    var pinned = true  // always on top

    var conversationHistory: [[String: String]] = []
    var chatMessages: [ChatMessage] = []
    var bubbleHideTimer: DispatchWorkItem?
    var streamingText = ""

    var scene: SCNScene!
    var cameraNode: SCNNode!

    // ---- Launch ----
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let cfg = ViewModeConfig.config(for: currentMode)
        let rect = NSRect(x: 0, y: 0, width: cfg.width, height: cfg.height)
        window = FloatingPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: rect)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = .clear
        window.contentView = contentView

        // Drag + right-click region
        dragView = DragView(frame: NSRect(x: 0, y: 56, width: cfg.width, height: cfg.height - 56))
        dragView.autoresizingMask = [.width, .height]
        dragView.onRightClick = { [weak self] in self?.showContextMenu() }
        contentView.addSubview(dragView)

        // SceneKit
        sceneView = ClickThroughSCNView(frame: NSRect(x: 0, y: 50, width: cfg.width, height: cfg.height - 50))
        sceneView.backgroundColor = .clear
        sceneView.antialiasingMode = .multisampling4X
        sceneView.allowsCameraControl = false
        sceneView.autoenablesDefaultLighting = false
        sceneView.autoresizingMask = [.width, .height]
        contentView.addSubview(sceneView)

        scene = SCNScene()
        scene.background.contents = NSColor.clear
        sceneView.scene = scene

        setupLighting()
        loadAvatar(currentAvatar)

        setupChatBubble(in: contentView)
        setupInputField(in: contentView)
        setupMenubar()
        setupGlobalHotkey()

        NotificationCenter.default.addObserver(self, selector: #selector(cycleViewMode),
                                               name: .cycleViewMode, object: nil)

        // Position bottom-right
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - cfg.width - 20
            window.setFrameOrigin(NSPoint(x: x, y: screen.visibleFrame.minY + 20))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(chatField)

        resetSystemPrompt()
    }

    func resetSystemPrompt() {
        let first = conversationHistory.first(where: { $0["role"] == "system" })
        if first != nil { conversationHistory.removeAll(where: { $0["role"] == "system" }) }
        conversationHistory.insert([
            "role": "system",
            "content": "You are Klaus, \(currentAvatar.personality) AI assistant on the user's desktop. Keep responses concise (1-3 sentences). Be helpful, sharp, slightly playful. You're Maxwell's AI companion on Mac Mini."
        ], at: 0)
    }

    // ============================================================
    // MARK: - View Modes
    // ============================================================

    @objc func cycleViewMode() {
        let modes = ViewMode.allCases
        let idx = modes.firstIndex(of: currentMode) ?? 0
        let next = modes[(idx + 1) % modes.count]
        setViewMode(next)
    }

    func setViewMode(_ mode: ViewMode) {
        currentMode = mode
        let cfg = ViewModeConfig.config(for: mode)

        // Animate window resize
        let origin = window.frame.origin
        let newFrame = NSRect(x: origin.x, y: origin.y, width: cfg.width, height: cfg.height)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        }

        inputContainer?.isHidden = !cfg.showChat
        bubbleContainer?.isHidden = !cfg.showBubble || bubbleContainer.isHidden
        thinkingIndicator?.isHidden = !cfg.showBubble || !isThinking

        if cfg.cornerRadius > 0 {
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.cornerRadius = cfg.cornerRadius
            window.contentView?.layer?.masksToBounds = true
        } else {
            window.contentView?.layer?.cornerRadius = 0
            window.contentView?.layer?.masksToBounds = false
        }

        // Adjust camera for mode
        let av = currentAvatar
        switch mode {
        case .full, .compact:
            cameraNode?.position = SCNVector3(0, av.cameraY + 0.2, av.cameraZ)
            cameraNode?.look(at: SCNVector3(0, av.cameraY, 0))
            cameraNode?.camera?.fieldOfView = av.fov
        case .mini:
            // Close-up on head
            cameraNode?.position = SCNVector3(0, av.cameraY + 0.35, 1.4)
            cameraNode?.look(at: SCNVector3(0, av.cameraY + 0.25, 0))
            cameraNode?.camera?.fieldOfView = 22
        case .bubble:
            cameraNode?.position = SCNVector3(0, av.cameraY + 0.35, 1.0)
            cameraNode?.look(at: SCNVector3(0, av.cameraY + 0.3, 0))
            cameraNode?.camera?.fieldOfView = 18
        }

        if cfg.showChat { window.makeFirstResponder(chatField) }
    }

    // ============================================================
    // MARK: - Avatar Swapping
    // ============================================================

    func swapAvatar(_ config: AvatarConfig) {
        // Remove old VRM
        vrmNode?.removeFromParentNode()
        vrmNode = nil
        currentAvatar = config
        loadAvatar(config)
        resetSystemPrompt()
        setViewMode(currentMode) // re-apply camera
    }

    func loadAvatar(_ config: AvatarConfig) {
        guard let url = Bundle.module.url(forResource: config.file, withExtension: "vrm", subdirectory: "Resources") else {
            print("\(config.file).vrm not found")
            return
        }
        do {
            let vrm = try VRMLoader().load(withURL: url)
            let node = try VRMSceneLoader(vrm: vrm).loadScene().rootNode
            let (_, max) = node.boundingBox
            let s = config.scale / CGFloat(max.y)
            node.scale = SCNVector3(s, s, s)
            node.position = SCNVector3(0, 0, 0)
            scene.rootNode.addChildNode(node)
            vrmNode = node

            // Dump bones
            var dump = "=== \(config.name) BONES ===\n"
            node.enumerateChildNodes { n, _ in
                if let name = n.name { dump += "  \(name)\(n.geometry != nil ? " [MESH]" : "")\n" }
            }
            try? dump.write(toFile: "/tmp/klaus-bones.txt", atomically: true, encoding: .utf8)

            applyIdlePose(to: node, config: config)
            applyBreathingAnimation(to: node, speed: 3.5, amplitude: 1.0)
            if !config.bones.tail.isEmpty {
                applyTailWag(to: node, speed: 2.0, amplitude: 0.15)
            }
        } catch {
            print("VRM error: \(error)")
        }
    }

    // ============================================================
    // MARK: - Context Menu (right-click abilities)
    // ============================================================

    func showContextMenu() {
        let menu = NSMenu()

        // View modes
        let viewMenu = NSMenu()
        for mode in ViewMode.allCases {
            let item = NSMenuItem(title: mode.rawValue.capitalized, action: #selector(selectViewMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = mode == currentMode ? .on : .off
            viewMenu.addItem(item)
        }
        let viewItem = NSMenuItem(title: "View Mode", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        // Avatar swap
        let avatarMenu = NSMenu()
        for av in AvatarConfig.all {
            let item = NSMenuItem(title: av.name, action: #selector(selectAvatar(_:)), keyEquivalent: "")
            item.representedObject = av.file
            item.state = av.file == currentAvatar.file ? .on : .off
            avatarMenu.addItem(item)
        }
        let avatarItem = NSMenuItem(title: "Avatar", action: nil, keyEquivalent: "")
        avatarItem.submenu = avatarMenu
        menu.addItem(avatarItem)

        menu.addItem(NSMenuItem.separator())

        // Pin toggle
        let pinItem = NSMenuItem(title: pinned ? "Unpin (not always on top)" : "Pin (always on top)",
                                 action: #selector(togglePin), keyEquivalent: "")
        menu.addItem(pinItem)

        // Opacity
        let opacityMenu = NSMenu()
        for pct in [100, 80, 60, 40, 20] {
            let item = NSMenuItem(title: "\(pct)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = pct
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(NSMenuItem.separator())

        // Quick actions
        menu.addItem(NSMenuItem(title: "Summarize Clipboard", action: #selector(summarizeClipboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "What time is it?", action: #selector(askTime), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Motivate me", action: #selector(motivateMe), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: ""))

        // Show menu at mouse location
        let loc = NSEvent.mouseLocation
        let winLoc = window.convertPoint(fromScreen: loc)
        menu.popUp(positioning: nil, at: winLoc, in: window.contentView)
    }

    @objc func selectViewMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = ViewMode(rawValue: raw) {
            setViewMode(mode)
        }
    }

    @objc func selectAvatar(_ sender: NSMenuItem) {
        if let file = sender.representedObject as? String,
           let config = AvatarConfig.all.first(where: { $0.file == file }) {
            swapAvatar(config)
        }
    }

    @objc func togglePin() {
        pinned.toggle()
        window.level = pinned ? .floating : .normal
    }

    @objc func setOpacity(_ sender: NSMenuItem) {
        let alpha = CGFloat(sender.tag) / 100.0
        window.alphaValue = alpha
    }

    @objc func summarizeClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            showBubble("Nothing on clipboard")
            return
        }
        let truncated = String(text.prefix(2000))
        quickSend("Summarize this in 1-2 sentences: \(truncated)")
    }

    @objc func askTime() {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, d MMMM yyyy 'at' h:mm a"
        showBubble(fmt.string(from: Date()))
        transitionTo(.reacting)
    }

    @objc func motivateMe() {
        quickSend("Give me a short, punchy motivational one-liner. No fluff.")
    }

    func quickSend(_ message: String) {
        conversationHistory.append(["role": "user", "content": message])
        showThinking(true)
        transitionTo(.thinking)
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

    // ============================================================
    // MARK: - Menubar
    // ============================================================

    func setupMenubar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "K"
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show/Hide Klaus", action: #selector(toggleWindow), keyEquivalent: "k"))

        let modeMenu = NSMenu()
        for mode in ViewMode.allCases {
            let item = NSMenuItem(title: mode.rawValue.capitalized, action: #selector(selectViewMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "View Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let avatarMenu = NSMenu()
        for av in AvatarConfig.all {
            let item = NSMenuItem(title: av.name, action: #selector(selectAvatar(_:)), keyEquivalent: "")
            item.representedObject = av.file
            avatarMenu.addItem(item)
        }
        let avatarItem = NSMenuItem(title: "Switch Avatar", action: nil, keyEquivalent: "")
        avatarItem.submenu = avatarMenu
        menu.addItem(avatarItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Summarize Clipboard", action: #selector(summarizeClipboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(chatField)
        }
    }

    @objc func clearHistory() {
        conversationHistory.removeAll()
        chatMessages.removeAll()
        resetSystemPrompt()
        bubbleContainer.isHidden = true
    }

    // ============================================================
    // MARK: - Global Hotkey
    // ============================================================

    func setupGlobalHotkey() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 40 {
                DispatchQueue.main.async { self?.toggleWindow() }
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 40 {
                DispatchQueue.main.async { self?.toggleWindow() }
                return nil
            }
            if event.keyCode == 53 { self?.window.orderOut(nil); return nil }
            return event
        }
    }

    // ============================================================
    // MARK: - Scene Setup
    // ============================================================

    func setupLighting() {
        cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = currentAvatar.fov
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 100
        cameraNode.position = SCNVector3(0, currentAvatar.cameraY + 0.2, currentAvatar.cameraZ)
        cameraNode.look(at: SCNVector3(0, currentAvatar.cameraY, 0))
        scene.rootNode.addChildNode(cameraNode)

        func addLight(_ type: SCNLight.LightType, color: NSColor, intensity: CGFloat,
                      pos: SCNVector3, shadow: Bool = false) {
            let light = SCNLight()
            light.type = type
            light.color = color
            light.intensity = intensity
            if shadow {
                light.castsShadow = true
                light.shadowMapSize = CGSize(width: 2048, height: 2048)
                light.shadowMode = .deferred
                light.shadowRadius = 4
            }
            let node = SCNNode()
            node.light = light
            node.position = pos
            if type != .ambient { node.look(at: SCNVector3(0, 0.8, 0)) }
            scene.rootNode.addChildNode(node)
        }

        addLight(.directional, color: NSColor(red: 1, green: 0.95, blue: 0.9, alpha: 1),
                 intensity: 1200, pos: SCNVector3(2, 3, 2), shadow: true)
        addLight(.directional, color: NSColor(red: 0.5, green: 0.6, blue: 0.9, alpha: 1),
                 intensity: 400, pos: SCNVector3(-3, 1.5, 1))
        addLight(.directional, color: NSColor(red: 1, green: 0.9, blue: 0.8, alpha: 1),
                 intensity: 600, pos: SCNVector3(0, 2, -3))
        addLight(.ambient, color: NSColor(red: 0.18, green: 0.16, blue: 0.2, alpha: 1),
                 intensity: 350, pos: SCNVector3(0, 0, 0))
    }

    // ============================================================
    // MARK: - UI Setup
    // ============================================================

    func setupChatBubble(in parent: NSView) {
        let cfg = ViewModeConfig.config(for: currentMode)
        let bubbleY = cfg.height * 0.65
        bubbleContainer = NSView(frame: NSRect(x: 10, y: bubbleY, width: cfg.width - 20, height: 80))
        bubbleContainer.wantsLayer = true
        bubbleContainer.layer?.cornerRadius = 12

        let blur = NSVisualEffectView(frame: bubbleContainer.bounds)
        blur.blendingMode = .behindWindow
        blur.material = .hudWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        bubbleContainer.addSubview(blur)
        bubbleContainer.autoresizingMask = [.width, .minYMargin]
        bubbleContainer.isHidden = true
        parent.addSubview(bubbleContainer)

        bubbleScrollView = NSScrollView(frame: NSRect(x: 12, y: 6, width: cfg.width - 44, height: 68))
        bubbleScrollView.hasVerticalScroller = true
        bubbleScrollView.drawsBackground = false
        bubbleScrollView.autoresizingMask = [.width, .height]
        bubbleScrollView.scrollerStyle = .overlay

        chatBubble = NSTextView(frame: bubbleScrollView.bounds)
        chatBubble.isEditable = false
        chatBubble.isSelectable = true
        chatBubble.drawsBackground = false
        chatBubble.textColor = .white
        chatBubble.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        chatBubble.textContainerInset = NSSize(width: 0, height: 2)
        chatBubble.isVerticallyResizable = true
        chatBubble.textContainer?.widthTracksTextView = true
        bubbleScrollView.documentView = chatBubble
        bubbleContainer.addSubview(bubbleScrollView)

        let dotsY = cfg.height * 0.67
        thinkingIndicator = NSView(frame: NSRect(x: 10, y: dotsY, width: 56, height: 26))
        thinkingIndicator.wantsLayer = true
        thinkingIndicator.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        thinkingIndicator.layer?.cornerRadius = 13
        thinkingIndicator.isHidden = true
        thinkingIndicator.autoresizingMask = [.minYMargin]
        parent.addSubview(thinkingIndicator)

        for i in 0..<3 {
            let dot = NSView(frame: NSRect(x: 10 + CGFloat(i) * 14, y: 9, width: 7, height: 7))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
            dot.layer?.cornerRadius = 3.5
            thinkingIndicator.addSubview(dot)
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.3, 1.0, 0.3]; pulse.keyTimes = [0, 0.5, 1.0]
            pulse.duration = 1.2; pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(i) * 0.2
            dot.layer?.add(pulse, forKey: "pulse")
        }
    }

    func setupInputField(in parent: NSView) {
        let cfg = ViewModeConfig.config(for: currentMode)
        inputContainer = NSView(frame: NSRect(x: 10, y: 10, width: cfg.width - 20, height: 40))
        inputContainer.wantsLayer = true
        inputContainer.layer?.cornerRadius = 20

        let blur = NSVisualEffectView(frame: inputContainer.bounds)
        blur.blendingMode = .behindWindow; blur.material = .hudWindow; blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.wantsLayer = true; blur.layer?.cornerRadius = 20; blur.layer?.masksToBounds = true
        inputContainer.addSubview(blur)
        inputContainer.autoresizingMask = [.width]
        parent.addSubview(inputContainer)

        chatField = NSTextField(frame: NSRect(x: 14, y: 6, width: cfg.width - 58, height: 28))
        chatField.isBordered = false; chatField.drawsBackground = false
        chatField.textColor = .white; chatField.font = NSFont.systemFont(ofSize: 13)
        chatField.placeholderAttributedString = NSAttributedString(
            string: "Ask Klaus...",
            attributes: [.foregroundColor: NSColor(white: 0.45, alpha: 1), .font: NSFont.systemFont(ofSize: 13)]
        )
        chatField.focusRingType = .none
        chatField.cell?.sendsActionOnEndEditing = false
        chatField.target = self; chatField.action = #selector(sendMessage)
        chatField.autoresizingMask = [.width]
        inputContainer.addSubview(chatField)

        let btn = NSButton(frame: NSRect(x: cfg.width - 48, y: 6, width: 28, height: 28))
        btn.isBordered = false; btn.title = "↑"
        btn.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        btn.contentTintColor = NSColor(white: 0.5, alpha: 1)
        btn.target = self; btn.action = #selector(sendMessage)
        btn.autoresizingMask = [.minXMargin]
        inputContainer.addSubview(btn)
    }

    // ============================================================
    // MARK: - Animation
    // ============================================================

    func transitionTo(_ newState: AvatarState) {
        guard newState != avatarState else { return }
        let old = avatarState; avatarState = newState
        guard let root = vrmNode else { return }
        let b = currentAvatar.bones

        switch newState {
        case .idle:
            applyBreathingAnimation(to: root, speed: 3.5, amplitude: 1.0)
            if !b.tail.isEmpty { applyTailWag(to: root, speed: 2.0, amplitude: 0.15) }
            stopJawAnimation()

        case .listening:
            applyBreathingAnimation(to: root, speed: 3.0, amplitude: 0.8)
            if !b.tail.isEmpty { applyTailWag(to: root, speed: 1.2, amplitude: 0.25) }
            animateBone(b.head, in: root, dx: -0.03, dz: 0.08, dur: 0.4)

        case .thinking:
            applyBreathingAnimation(to: root, speed: 2.0, amplitude: 1.4)
            if !b.tail.isEmpty { applyTailWag(to: root, speed: 3.0, amplitude: 0.08) }
            animateBone(b.spine1, in: root, dx: 0.05, dur: 0.5)
            animateBone(b.head, in: root, dx: 0.06, dur: 0.6)

        case .speaking:
            applyBreathingAnimation(to: root, speed: 3.5, amplitude: 1.0)
            if !b.tail.isEmpty { applyTailWag(to: root, speed: 1.0, amplitude: 0.3) }
            startJawAnimation()

        case .reacting:
            if !b.tail.isEmpty { applyTailWag(to: root, speed: 0.6, amplitude: 0.4) }
            // Bounce
            if let hips = findBone(b.hips, in: root) {
                let baseY = hips.position.y
                SCNTransaction.begin(); SCNTransaction.animationDuration = 0.15
                hips.position.y = baseY - 0.03; SCNTransaction.commit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    SCNTransaction.begin(); SCNTransaction.animationDuration = 0.3
                    SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
                    hips.position.y = baseY; SCNTransaction.commit()
                }
            }
            animateBone(b.head, in: root, dx: 0.1, dur: 0.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.animateBone(b.head, in: root, dx: -0.1, dur: 0.3)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.transitionTo(.idle)
            }
        }

        // Undo listening
        if old == .listening && newState != .listening {
            animateBone(b.head, in: root, dx: 0.03, dz: -0.08, dur: 0.3)
        }
        // Undo thinking
        if old == .thinking && newState != .thinking {
            animateBone(b.spine1, in: root, dx: -0.05, dur: 0.3)
            animateBone(b.head, in: root, dx: -0.06, dur: 0.3)
        }
    }

    func animateBone(_ name: String, in root: SCNNode, dx: CGFloat = 0, dy: CGFloat = 0, dz: CGFloat = 0, dur: TimeInterval) {
        guard let bone = findBone(name, in: root) else { return }
        SCNTransaction.begin(); SCNTransaction.animationDuration = dur
        bone.eulerAngles.x += CGFloat(dx)
        bone.eulerAngles.y += CGFloat(dy)
        bone.eulerAngles.z += CGFloat(dz)
        SCNTransaction.commit()
    }

    func applyTailWag(to root: SCNNode, speed: TimeInterval, amplitude: CGFloat) {
        for (i, name) in currentAvatar.bones.tail.enumerated() {
            guard let bone = findBone(name, in: root) else { continue }
            bone.removeAnimation(forKey: "tail_wag")
            let base = bone.presentation.rotation
            let segAmp = amplitude * (1.0 + CGFloat(i) * 0.4)
            let phase = CGFloat(i) * 0.4
            let anim = CAKeyframeAnimation(keyPath: "rotation")
            anim.duration = speed; anim.repeatCount = .infinity; anim.calculationMode = .cubic
            var vals: [NSValue] = []; var keys: [NSNumber] = []
            for j in 0...60 {
                let t = Double(j) / 60.0
                let w = CGFloat(sin((t * .pi * 2) + Double(phase))) * segAmp
                vals.append(NSValue(scnVector4: SCNVector4(base.x, base.y + w, base.z, base.w + abs(w) * 0.5)))
                keys.append(NSNumber(value: t))
            }
            anim.values = vals; anim.keyTimes = keys
            bone.addAnimation(anim, forKey: "tail_wag")
        }
    }

    func startJawAnimation() {
        guard let root = vrmNode, let head = findBone(currentAvatar.bones.head, in: root) else { return }
        let base = head.presentation.rotation
        let anim = CAKeyframeAnimation(keyPath: "rotation")
        anim.duration = 0.3; anim.repeatCount = .infinity; anim.autoreverses = true
        let a: CGFloat = 0.06
        anim.values = [
            NSValue(scnVector4: base),
            NSValue(scnVector4: SCNVector4(base.x + a, base.y, base.z, base.w + a)),
            NSValue(scnVector4: base)
        ]
        anim.keyTimes = [0, 0.45, 1.0]; anim.calculationMode = .cubic
        head.addAnimation(anim, forKey: "jaw_speak")
    }

    func stopJawAnimation() {
        guard let root = vrmNode, let head = findBone(currentAvatar.bones.head, in: root) else { return }
        head.removeAnimation(forKey: "jaw_speak")
    }

    // ============================================================
    // MARK: - Chat
    // ============================================================

    @objc func sendMessage() {
        let text = chatField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatField.stringValue = ""
        chatMessages.append(ChatMessage(text: text, isUser: true, timestamp: Date()))
        conversationHistory.append(["role": "user", "content": text])
        showThinking(true); transitionTo(.thinking)
        Task {
            do { try await streamFromKlaus() } catch {
                await MainActor.run {
                    showThinking(false); transitionTo(.reacting)
                    showBubble("connection lost — \(error.localizedDescription)")
                }
            }
        }
    }

    func streamFromKlaus() async throws {
        let url = URL(string: "\(GATEWAY_URL)/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(GATEWAY_TOKEN)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "anthropic/claude-sonnet-4-6",
            "messages": conversationHistory.map { $0 as [String: Any] },
            "stream": true
        ] as [String: Any])

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "Klaus", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }

        await MainActor.run {
            showThinking(false); streamingText = ""
            transitionTo(.speaking); showBubble("")
        }

        var buffer = ""
        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                let d = String(line.dropFirst(6))
                if d == "[DONE]" { break }
                if let jd = d.data(using: .utf8),
                   let j = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
                   let ch = j["choices"] as? [[String: Any]],
                   let delta = ch.first?["delta"] as? [String: Any],
                   let c = delta["content"] as? String {
                    buffer += c
                    let cap = buffer
                    await MainActor.run { streamingText = cap; updateBubbleText(cap) }
                }
            }
        }
        let final = buffer
        await MainActor.run {
            chatMessages.append(ChatMessage(text: final, isUser: false, timestamp: Date()))
            conversationHistory.append(["role": "assistant", "content": final])
            if conversationHistory.count > 22 {
                let sys = conversationHistory[0]
                conversationHistory = [sys] + Array(conversationHistory.suffix(20))
            }
            transitionTo(.reacting)
        }
    }

    func showThinking(_ show: Bool) {
        isThinking = show
        thinkingIndicator.isHidden = !show
        if show { bubbleContainer.isHidden = true }
    }

    func updateBubbleText(_ text: String) {
        chatBubble.string = text
        let cfg = ViewModeConfig.config(for: currentMode)
        let maxW = cfg.width - 44
        let font = chatBubble.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let sz = (text as NSString).boundingRect(with: NSSize(width: maxW, height: 300), options: [.usesLineFragmentOrigin], attributes: [.font: font])
        let h = max(36, min(sz.height + 20, 160))
        let top = cfg.height * 0.65 + 80
        bubbleContainer.frame = NSRect(x: 10, y: top - h, width: cfg.width - 20, height: h)
        chatBubble.scrollToEndOfDocument(nil)
    }

    func showBubble(_ text: String) {
        bubbleHideTimer?.cancel()
        chatBubble.string = text
        let cfg = ViewModeConfig.config(for: currentMode)
        let maxW = cfg.width - 44
        let font = chatBubble.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let display = text.isEmpty ? " " : text
        let sz = (display as NSString).boundingRect(with: NSSize(width: maxW, height: 300), options: [.usesLineFragmentOrigin], attributes: [.font: font])
        let h = max(36, min(sz.height + 20, 160))
        let top = cfg.height * 0.65 + 80
        bubbleContainer.frame = NSRect(x: 10, y: top - h, width: cfg.width - 20, height: h)
        bubbleContainer.alphaValue = 1; bubbleContainer.isHidden = false

        let timer = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.5; self?.bubbleContainer.animator().alphaValue = 0
            }) { self?.bubbleContainer.isHidden = true; self?.bubbleContainer.alphaValue = 1 }
        }
        bubbleHideTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timer)
    }

    // ============================================================
    // MARK: - Helpers
    // ============================================================

    func findBone(_ name: String, in root: SCNNode) -> SCNNode? {
        var found: SCNNode?
        root.enumerateChildNodes { n, stop in
            if n.name == name { found = n; stop.pointee = true }
        }
        return found
    }

    func applyBreathingAnimation(to root: SCNNode, speed: TimeInterval, amplitude: CGFloat) {
        let b = currentAvatar.bones
        let names = [b.spine1, b.spine2, b.spine, b.neck, b.head, b.leftShoulder, b.rightShoulder, b.hips]
        for name in names {
            findBone(name, in: root)?.removeAnimation(forKey: "breathing")
            findBone(name, in: root)?.removeAnimation(forKey: "breathing_pos")
        }

        let configs: [(String, CGFloat, CGFloat, SCNVector3)] = [
            (b.spine1,  0.018 * amplitude, 0.0, SCNVector3(1,0,0)),
            (b.spine2,  0.012 * amplitude, 0.2, SCNVector3(1,0,0)),
            (b.spine,   0.006 * amplitude, 0.0, SCNVector3(0,1,0)),
            (b.neck,    0.008 * amplitude, 0.3, SCNVector3(1,0,0)),
            (b.head,    0.010 * amplitude, 0.4, SCNVector3(1,0,0)),
            (b.leftShoulder,  0.012 * amplitude, 0.0, SCNVector3(0,0,1)),
            (b.rightShoulder, -0.012 * amplitude, 0.0, SCNVector3(0,0,1)),
        ]
        for (name, amp, phase, axis) in configs {
            guard let bone = findBone(name, in: root) else { continue }
            let base = bone.presentation.rotation
            let anim = CAKeyframeAnimation(keyPath: "rotation")
            anim.duration = speed; anim.repeatCount = .infinity; anim.calculationMode = .cubic
            var vals: [NSValue] = []; var keys: [NSNumber] = []
            for i in 0...60 {
                let t = Double(i) / 60.0
                let a = CGFloat(sin((t * .pi * 2) + Double(phase))) * amp
                vals.append(NSValue(scnVector4: SCNVector4(base.x+axis.x*a, base.y+axis.y*a, base.z+axis.z*a, base.w+a)))
                keys.append(NSNumber(value: t))
            }
            anim.values = vals; anim.keyTimes = keys
            bone.addAnimation(anim, forKey: "breathing")
        }

        if let hips = findBone(b.hips, in: root) {
            let base = hips.presentation.position
            let anim = CAKeyframeAnimation(keyPath: "position")
            anim.duration = speed; anim.repeatCount = .infinity; anim.calculationMode = .cubic
            var vals: [NSValue] = []; var keys: [NSNumber] = []
            for i in 0...60 {
                let t = Double(i) / 60.0
                let bob = CGFloat(sin(t * .pi * 2)) * 0.005 * amplitude
                vals.append(NSValue(scnVector3: SCNVector3(base.x, base.y + bob, base.z)))
                keys.append(NSNumber(value: t))
            }
            anim.values = vals; anim.keyTimes = keys
            hips.addAnimation(anim, forKey: "breathing_pos")
        }
    }

    func applyIdlePose(to root: SCNNode, config: AvatarConfig) {
        root.eulerAngles.y = .pi
        let b = config.bones
        if let la = findBone(b.leftArm, in: root) {
            la.eulerAngles.z += CGFloat(config.armRelax)
            la.eulerAngles.x += CGFloat(0.1)
        }
        if let ra = findBone(b.rightArm, in: root) {
            ra.eulerAngles.z -= CGFloat(config.armRelax)
            ra.eulerAngles.x += CGFloat(0.1)
        }
        if let lf = findBone(b.leftForeArm, in: root) { lf.eulerAngles.y -= CGFloat(0.2) }
        if let rf = findBone(b.rightForeArm, in: root) { rf.eulerAngles.y += CGFloat(0.2) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// ============================================================
// MARK: - Launch
// ============================================================

if CommandLine.arguments.contains("--qa") {
    let qa = QARunner()
    exit(qa.run() ? 0 : 1)
} else {
    let myPID = ProcessInfo.processInfo.processIdentifier
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", "KlausAvatar"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run(); task.waitUntilExit()
    let pids = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        .split(separator: "\n").compactMap { Int32($0) }.filter { $0 != myPID }
    if !pids.isEmpty { print("Already running (PID \(pids[0]))."); exit(0) }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
