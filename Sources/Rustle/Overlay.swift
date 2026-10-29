import AppKit
import SpriteKit

/// A transparent, click-through window covering one display, running its own leaf scene.
@MainActor
final class ScreenOverlay {
    let displayID: CGDirectDisplayID
    let window: NSWindow
    let view: SKView
    let scene: LeafScene

    init(screen: NSScreen, art: LeafTextures, audio: CrunchAudio) {
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let frame = screen.frame

        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.setFrame(frame, display: false)

        view = SKView(frame: CGRect(origin: .zero, size: frame.size))
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        view.shouldCullNonVisibleNodes = true
        view.preferredFramesPerSecond = 60
        window.contentView = view

        let usableTop = screen.visibleFrame.maxY - frame.minY
        scene = LeafScene(size: frame.size, origin: frame.origin, usableTop: usableTop, art: art, audio: audio)
    }

    func show() {
        view.presentScene(scene)
        window.orderFrontRegardless()
    }

    func close() {
        view.presentScene(nil)
        window.orderOut(nil)
        window.close()
    }
}

/// Owns one overlay per display and keeps them in step with the preferences, power state and windows.
@MainActor
final class OverlayController {
    private let prefs: Preferences
    private let audio: CrunchAudio
    private let tools: ToolController
    private let tracker = WindowTracker()
    private let power = PowerMonitor()
    private var overlays: [ScreenOverlay] = []
    private var textures: [CGFloat: LeafTextures] = [:]
    private var spaceChangedAt: TimeInterval = -100
    private var rebuildScheduled = false
    private var layoutSignature = ""
    private let environment = ProcessInfo.processInfo.environment
    private let launchTime = CACurrentMediaTime()

    init(prefs: Preferences, audio: CrunchAudio, tools: ToolController) {
        self.prefs = prefs
        self.audio = audio
        self.tools = tools
        tracker.onUpdate = { [weak self] windows in self?.windowsChanged(windows) }
        power.onChange = { [weak self] in self?.apply() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChangedAt = CACurrentMediaTime() }
        }
        rebuild()
    }

    /// Pushes the current preferences to every display.
    func apply() {
        let behind = prefs.behindWindows
        let level = behind
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            // Above app windows, just under the Dock, so the Dock sits in front of the pile.
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        let settings = SceneSettings(fall: prefs.leafFall, breeze: prefs.breeze, accumulate: prefs.accumulate,
                                     windClears: prefs.windClears && prefs.accumulate,
                                     onWindows: prefs.leavesOnWindows && !behind,
                                     savePower: power.savesPower)
        audio.isEnabled = prefs.crunchSound
        for overlay in overlays {
            overlay.window.level = level
            overlay.window.sharingType = prefs.showInScreenshots ? .readOnly : .none
            overlay.scene.crunchEnabled = prefs.crunchSound
            overlay.scene.apply(settings)
            overlay.view.isPaused = power.isSuspended
        }
        if settings.onWindows && !power.isSuspended {
            tracker.start()
        } else {
            tracker.stop()
        }
    }

    func clearLeaves() {
        for overlay in overlays { overlay.scene.clearAll() }
    }

    /// A tool was picked up or put away: the scenes need frames to follow it.
    func toolChanged() {
        if tools.equipped != .blower { audio.blower(level: 0, pan: 0) }
        guard !power.isSuspended else { return }
        for overlay in overlays { overlay.view.isPaused = false }
    }

    private func windowsChanged(_ windows: [TrackedWindow]) {
        let windows = fakeWindows() + windows
        for overlay in overlays { overlay.scene.updateWindows(windows, spaceChangedAt: spaceChangedAt) }
    }

    /// RUSTLE_FAKE_WINDOWS adds two pretend windows on the main display: a still one, and one in front
    /// of it that is "dragged" to the right 25 s after launch.
    private func fakeWindows() -> [TrackedWindow] {
        guard environment["RUSTLE_FAKE_WINDOWS"] != nil, let screen = NSScreen.screens.first?.frame else { return [] }
        let dragged = CACurrentMediaTime() - launchTime > 25
        let front = CGRect(x: screen.width * (dragged ? 0.62 : 0.42), y: screen.height * 0.25,
                           width: screen.width * 0.3, height: screen.height * 0.4)
        let back = CGRect(x: screen.width * 0.12, y: screen.height * 0.3,
                          width: screen.width * 0.4, height: screen.height * 0.42)
        return [TrackedWindow(id: -2, frame: front), TrackedWindow(id: -1, frame: back)]
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.rebuildScheduled = false
                self?.rebuild()
            }
        }
    }

    /// Display wake and other reconfigurations post screen-change notifications too;
    /// only an actual layout change is worth starting the piles over.
    private func currentLayoutSignature() -> String {
        NSScreen.screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber ?? 0
            return "\(id):\(screen.frame):\(screen.visibleFrame.maxY):\(screen.backingScaleFactor)"
        }.joined(separator: "|")
    }

    private func rebuild() {
        let signature = currentLayoutSignature()
        guard signature != layoutSignature else { return }
        layoutSignature = signature
        // Tool windows cover the old displays; put the tool away.
        tools.equip(.none)
        for overlay in overlays { overlay.close() }
        overlays = NSScreen.screens.map { screen in
            let scale = screen.backingScaleFactor
            let art = textures[scale] ?? LeafTextures(scale: scale)
            textures[scale] = art
            let overlay = ScreenOverlay(screen: screen, art: art, audio: audio)
            overlay.scene.toolProvider = { [weak tools] in tools?.input ?? ToolInput() }
            configureForTesting(overlay.scene, frame: screen.frame)
            return overlay
        }
        for overlay in overlays { overlay.show() }
        apply()
        if let count = environment["RUSTLE_PREFILL"].flatMap(Int.init) {
            for overlay in overlays { overlay.scene.prefill(count) }
        }
    }

    /// Debug hooks, driven by environment variables:
    /// RUSTLE_SNAPSHOT=/path/prefix writes PNG frames, RUSTLE_FAKE_CURSOR sweeps a virtual cursor
    /// through the pile, RUSTLE_PREFILL=n starts with n leaves on the ground, RUSTLE_FAKE_TOOL=rake|blower
    /// uses that tool with the fake cursor (pressed for 8 s out of every 12).
    private func configureForTesting(_ scene: LeafScene, frame: CGRect) {
        if let prefix = environment["RUSTLE_SNAPSHOT"] {
            scene.snapshotPrefix = "\(prefix)-\(Int(frame.minX))"
        }
        let fakeTool = environment["RUSTLE_FAKE_TOOL"].map { $0 == "blower" ? EquippedTool.blower : .rake }
        if environment["RUSTLE_FAKE_CURSOR"] != nil {
            let start = CACurrentMediaTime() + 10
            scene.cursorProvider = {
                let t = CACurrentMediaTime() - start
                guard t > 0 else { return CGPoint(x: frame.midX, y: frame.maxY - 5) }
                let y = fakeTool == .blower ? 110 + 30 * CGFloat(sin(t * 1.3)) : 22 + 16 * CGFloat(sin(t * 3.1))
                return CGPoint(x: frame.minX + frame.width * (0.5 + 0.42 * CGFloat(sin(t * 0.9))), y: frame.minY + y)
            }
            if let fakeTool {
                scene.toolProvider = {
                    let t = CACurrentMediaTime() - start
                    return ToolInput(tool: fakeTool, pressed: t > 0 && t.truncatingRemainder(dividingBy: 12) < 8,
                                     facing: cos(t * 0.9) >= 0 ? 1 : -1)
                }
            }
        }
    }
}
